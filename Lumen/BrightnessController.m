// Copyright (c) Anish Athalye (me@anishathalye.com)
// Released under GPLv3. See the included LICENSE.txt for details

#import "BrightnessController.h"
#import "IgnoreListController.h"
#import "LumenDisplay.h"
#import "Model.h"
#import "Constants.h"
#import "util.h"
#import <IOKit/graphics/IOGraphicsLib.h>
#import <IOKit/i2c/IOI2CInterface.h>
#import <ApplicationServices/ApplicationServices.h>
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <os/log.h>

extern int DisplayServicesGetBrightness(CGDirectDisplayID display, float *brightness);
extern int DisplayServicesSetBrightness(CGDirectDisplayID display, float brightness);

typedef CFTypeRef IOAVService;
extern IOAVService IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVService service, uint32_t chipAddress, uint32_t offset, void *outputBuffer, uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVService service, uint32_t chipAddress, uint32_t dataAddress, void *inputBuffer, uint32_t inputBufferSize);
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display);
extern void CGSServiceForDisplayNumber(CGDirectDisplayID display, io_service_t *service);

static NSString * const LumenBrightnessErrorDomain = @"com.anishathalye.lumen.brightness";
static NSUInteger const LumenMaxDebugEvents = 50;

static os_log_t LumenDebugLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.anishathalye.lumen", "debug");
    });
    return log;
}

@protocol LumenBrightnessBackend <NSObject>

@property (nonatomic, copy, readonly) NSString *name;

- (BOOL)canControlDisplay:(LumenDisplay *)display;
- (float)brightnessForDisplay:(LumenDisplay *)display error:(NSError **)error;
- (BOOL)setBrightness:(float)brightness forDisplay:(LumenDisplay *)display error:(NSError **)error;

@optional
- (NSString *)failureReasonForDisplay:(LumenDisplay *)display;

@end

@interface DisplayServicesBrightnessBackend : NSObject <LumenBrightnessBackend>
@end

@class LumenDDCMapping;

@interface ExternalDisplayBrightnessBackend : NSObject <LumenBrightnessBackend>

@property (nonatomic, strong) NSMutableDictionary<NSString *, LumenDDCMapping *> *mappingsByDisplayKey;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *failuresByDisplayKey;

@end

@interface LumenDDCMapping : NSObject

@property (nonatomic, assign) BOOL arm64;
@property (nonatomic, assign) IOAVService avService;
@property (nonatomic, assign) io_service_t framebuffer;
@property (nonatomic, assign) IOOptionBits replyTransactionType;
@property (nonatomic, assign) UInt16 maxBrightness;
@property (nonatomic, copy) NSString *failureReason;

@end

@interface LumenDisplayState : NSObject

@property (nonatomic, assign) float lastSet;
@property (nonatomic, assign) float lastAssigned;
@property (nonatomic, assign) BOOL noticed;
@property (nonatomic, assign) float lastNoticed;
@property (nonatomic, assign) NSTimeInterval lastAutoBrightnessTime;
@property (nonatomic, assign) NSTimeInterval lastManualChangeTime;
@property (nonatomic, assign) BOOL shouldIgnoreOutput;
@property (nonatomic, copy) NSString *captureStatus;
@property (nonatomic, assign) BOOL captureActive;
@property (nonatomic, assign) float latestLightness;
@property (nonatomic, assign) NSTimeInterval latestLightnessTime;
@property (nonatomic, assign) NSTimeInterval lastLightnessLogTime;
@property (nonatomic, assign) BOOL canReadBrightness;
@property (nonatomic, assign) BOOL canSetBrightness;
@property (nonatomic, assign) float latestBrightness;
@property (nonatomic, assign) NSTimeInterval latestBrightnessTime;
@property (nonatomic, assign) float latestTargetBrightness;
@property (nonatomic, assign) NSTimeInterval latestTargetTime;
@property (nonatomic, assign) float lastWrittenBrightness;
@property (nonatomic, assign) NSTimeInterval lastWriteTime;
@property (nonatomic, copy) NSString *lastWriteError;
@property (nonatomic, copy) NSString *lastReadError;
@property (nonatomic, copy) NSString *lastAction;
@property (nonatomic, copy) NSString *lastActionReason;
@property (nonatomic, copy) NSString *lastLearnEvent;
@property (nonatomic, assign) NSTimeInterval lastLearnTime;
@property (nonatomic, assign) float lastManualOverrideOldBrightness;
@property (nonatomic, assign) float lastManualOverrideNewBrightness;
@property (nonatomic, assign) float lastManualOverrideDelta;
@property (nonatomic, copy) NSString *lastTrainingDecision;
@property (nonatomic, assign) BOOL seededFromLegacyModel;

@end

@implementation LumenDisplayState

- (instancetype)init {
    self = [super init];
    if (self) {
        self.lastSet = -1; // force initial observation, preserving old single-display behavior
        self.lastAssigned = -1;
        self.noticed = NO;
        self.lastNoticed = 0;
        self.lastAutoBrightnessTime = 0;
        self.lastManualChangeTime = 0;
        self.shouldIgnoreOutput = NO;
        self.captureStatus = @"no capture";
        self.captureActive = NO;
        self.latestLightness = -1;
        self.latestLightnessTime = 0;
        self.lastLightnessLogTime = 0;
        self.canReadBrightness = NO;
        self.canSetBrightness = NO;
        self.latestBrightness = -1;
        self.latestBrightnessTime = 0;
        self.latestTargetBrightness = -1;
        self.latestTargetTime = 0;
        self.lastWrittenBrightness = -1;
        self.lastWriteTime = 0;
        self.lastWriteError = @"";
        self.lastReadError = @"";
        self.lastAction = @"waiting";
        self.lastActionReason = @"waiting for capture";
        self.lastLearnEvent = @"none";
        self.lastLearnTime = 0;
        self.lastManualOverrideOldBrightness = -1;
        self.lastManualOverrideNewBrightness = -1;
        self.lastManualOverrideDelta = 0;
        self.lastTrainingDecision = @"none";
        self.seededFromLegacyModel = NO;
    }
    return self;
}

@end

@interface BrightnessController () <SCStreamDelegate, SCStreamOutput>

@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong, readwrite) NSArray<LumenDisplay *> *activeDisplays;
@property (nonatomic, strong, readwrite) NSMutableDictionary<NSString *, NSNumber *> *currentLightnessByDisplayKey;
@property (nonatomic, strong) NSMutableDictionary<NSString *, SCStream *> *streamsByDisplayKey;
@property (nonatomic, strong) NSMutableDictionary<NSValue *, NSString *> *displayKeyByStream;
@property (nonatomic, strong) NSMutableDictionary<NSString *, LumenDisplayState *> *displayStatesByKey;
@property (nonatomic, strong) NSMutableArray<NSDictionary<NSString *, id> *> *debugEvents;
@property (nonatomic, strong) NSArray<id<LumenBrightnessBackend>> *brightnessBackends;
@property (nonatomic, strong) Model *model;
@property (nonatomic, assign) BOOL displayCallbackRegistered;
@property (nonatomic, assign) NSUInteger displayConfigurationGeneration;

/**
 Maintains the list of ignored applications.
 */
@property (nonatomic, strong) IgnoreListController *ignoreList;

/**
 Maintains the last frontmost application (other than Lumen).
 */
@property (nonatomic, strong) NSString *lastActiveAppURLString;

- (void)reloadDisplaysAndStreams;
- (void)stopCaptureStreams;
- (void)processLightness:(double)lightness forDisplay:(LumenDisplay *)display;
- (double)computeLightnessFromSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)addDebugEvent:(NSString *)event display:(LumenDisplay *)display;
- (void)addSkippedDecisionEventForDisplay:(LumenDisplay *)display
                                    state:(LumenDisplayState *)state
                                lightness:(double)lightness
                                   target:(float)target
                        currentBrightness:(float)currentBrightness
                                   reason:(NSString *)reason;
- (void)setAction:(NSString *)action reason:(NSString *)reason display:(LumenDisplay *)display state:(LumenDisplayState *)state;
- (NSDictionary<NSString *, id> *)debugDictionaryForDisplay:(LumenDisplay *)display;
- (NSString *)brightnessFailureReasonForDisplay:(LumenDisplay *)display;
- (NSString *)shortDisplayKey:(NSString *)stableKey;
- (NSString *)roleForDisplay:(LumenDisplay *)display;
- (NSString *)formattedTime:(NSTimeInterval)timestamp;

@end

static void LumenDisplayReconfigurationCallback(CGDirectDisplayID display,
                                                CGDisplayChangeSummaryFlags flags,
                                                void *userInfo) {
    BrightnessController *controller = (__bridge BrightnessController *)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        os_log_info(LumenDebugLog(), "Display reconfiguration display=%{public}u flags=%{public}u", display, flags);
        [controller reloadDisplaysAndStreams];
    });
}

@implementation LumenDDCMapping

- (void)dealloc {
    if (_avService) {
        CFRelease(_avService);
    }
    if (_framebuffer) {
        IOObjectRelease(_framebuffer);
    }
}

@end

static UInt8 LumenDDCChecksum(UInt8 seed, UInt8 *data, NSUInteger length) {
    UInt8 checksum = seed;
    for (NSUInteger i = 0; i < length; i++) {
        checksum ^= data[i];
    }
    return checksum;
}

static NSError *LumenBrightnessError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:LumenBrightnessErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"brightness backend failed"}];
}

static BOOL LumenIsArm64(void) {
#if defined(__arm64__)
    return YES;
#else
    return NO;
#endif
}

static NSNumber *LumenNumberFromDictionary(NSDictionary *dictionary, const char *key) {
    id value = dictionary[@(key)];
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

@implementation DisplayServicesBrightnessBackend

- (NSString *)name {
    return @"DisplayServices";
}

- (BOOL)canControlDisplay:(LumenDisplay *)display {
    float level = 1.0f;
    return DisplayServicesGetBrightness(display.displayID, &level) == 0;
}

- (float)brightnessForDisplay:(LumenDisplay *)display error:(NSError **)error {
    float level = 1.0f;
    int result = DisplayServicesGetBrightness(display.displayID, &level);
    if (result != 0) {
        if (error) {
            *error = [NSError errorWithDomain:LumenBrightnessErrorDomain
                                         code:result
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"DisplayServicesGetBrightness failed for display %u", display.displayID]}];
        }
        return 0;
    }
    return level;
}

- (BOOL)setBrightness:(float)brightness forDisplay:(LumenDisplay *)display error:(NSError **)error {
    int result = DisplayServicesSetBrightness(display.displayID, brightness);
    if (result != 0) {
        if (error) {
            *error = [NSError errorWithDomain:LumenBrightnessErrorDomain
                                         code:result
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"DisplayServicesSetBrightness failed for display %u", display.displayID]}];
        }
        return NO;
    }
    return YES;
}

@end

@implementation ExternalDisplayBrightnessBackend

// Minimal DDC/CI backend adapted from MonitorControl's MIT-licensed
// IntelDDC.swift and Arm64DDC.swift packet/mapping approach.
// Copyright (c) 2017 MonitorControl contributors.

static UInt8 const LumenDDCVCPBrightness = 0x10;
static UInt8 const LumenIntelDDCWriteAddress = 0x6E;
static UInt8 const LumenIntelDDCReadAddress = 0x6F;
static UInt8 const LumenDDCSubAddress = 0x51;
static UInt8 const LumenArmDDC7BitAddress = 0x37;

- (instancetype)init {
    self = [super init];
    if (self) {
        self.mappingsByDisplayKey = [NSMutableDictionary new];
        self.failuresByDisplayKey = [NSMutableDictionary new];
    }
    return self;
}

- (NSString *)name {
    return @"DDC-CI";
}

- (BOOL)canControlDisplay:(LumenDisplay *)display {
    if (display.builtin) {
        return NO;
    }

    NSError *error = nil;
    LumenDDCMapping *mapping = [self mappingForDisplay:display error:&error];
    if (!mapping) {
        self.failuresByDisplayKey[display.stableKey] = error.localizedDescription ?: @"no DDC/CI service found";
        return NO;
    }

    UInt16 current = 0;
    UInt16 maximum = 0;
    if (![self readBrightnessCurrent:&current maximum:&maximum mapping:mapping error:&error]) {
        self.failuresByDisplayKey[display.stableKey] = error.localizedDescription ?: @"brightness command unsupported";
        [self.mappingsByDisplayKey removeObjectForKey:display.stableKey];
        return NO;
    }

    mapping.maxBrightness = maximum > 0 ? maximum : 100;
    self.failuresByDisplayKey[display.stableKey] = @"";
    return YES;
}

- (float)brightnessForDisplay:(LumenDisplay *)display error:(NSError **)error {
    LumenDDCMapping *mapping = [self mappingForDisplay:display error:error];
    if (!mapping) {
        return 0;
    }

    UInt16 current = 0;
    UInt16 maximum = 0;
    if (![self readBrightnessCurrent:&current maximum:&maximum mapping:mapping error:error]) {
        [self.mappingsByDisplayKey removeObjectForKey:display.stableKey];
        return 0;
    }

    mapping.maxBrightness = maximum > 0 ? maximum : 100;
    return MIN(1.0f, MAX(0.0f, (float)current / (float)mapping.maxBrightness));
}

- (BOOL)setBrightness:(float)brightness forDisplay:(LumenDisplay *)display error:(NSError **)error {
    LumenDDCMapping *mapping = [self mappingForDisplay:display error:error];
    if (!mapping) {
        return NO;
    }

    UInt16 maximum = mapping.maxBrightness > 0 ? mapping.maxBrightness : 100;
    UInt16 value = (UInt16)lroundf(MIN(1.0f, MAX(0.0f, brightness)) * (float)maximum);
    if (![self writeBrightness:value mapping:mapping error:error]) {
        [self.mappingsByDisplayKey removeObjectForKey:display.stableKey];
        return NO;
    }
    return YES;
}

- (NSString *)failureReasonForDisplay:(LumenDisplay *)display {
    NSString *reason = self.failuresByDisplayKey[display.stableKey];
    return reason.length > 0 ? reason : nil;
}

- (LumenDDCMapping *)mappingForDisplay:(LumenDisplay *)display error:(NSError **)error {
    LumenDDCMapping *cached = self.mappingsByDisplayKey[display.stableKey];
    if (cached) {
        return cached;
    }

    LumenDDCMapping *mapping = LumenIsArm64() ? [self armMappingForDisplay:display error:error] : [self intelMappingForDisplay:display error:error];
    if (mapping) {
        self.mappingsByDisplayKey[display.stableKey] = mapping;
        os_log_info(LumenDebugLog(),
                    "DDC backend selected display=%{public}@ key=%{public}@ path=%{public}@",
                    display.displayName,
                    display.stableKey.length > 8 ? [display.stableKey substringFromIndex:display.stableKey.length - 8] : display.stableKey,
                    mapping.arm64 ? @"IOAVService" : @"IOI2C");
    }
    return mapping;
}

- (LumenDDCMapping *)intelMappingForDisplay:(LumenDisplay *)display error:(NSError **)error {
    io_service_t framebuffer = 0;
    CGSServiceForDisplayNumber(display.displayID, &framebuffer);
    if (!framebuffer) {
        framebuffer = [self framebufferByDisplayPropertiesForDisplay:display];
    }
    if (!framebuffer) {
        if (error) {
            *error = LumenBrightnessError(-10, @"no DDC/CI framebuffer service found");
        }
        return nil;
    }

    IOItemCount busCount = 0;
    if (IOFBGetI2CInterfaceCount(framebuffer, &busCount) != KERN_SUCCESS || busCount < 1) {
        IOObjectRelease(framebuffer);
        if (error) {
            *error = LumenBrightnessError(-11, @"DDC/CI framebuffer has no I2C bus");
        }
        return nil;
    }

    IOOptionBits transactionType = [self supportedIntelReplyTransactionType];
    if (transactionType == 0) {
        IOObjectRelease(framebuffer);
        if (error) {
            *error = LumenBrightnessError(-12, @"backend unavailable on this hardware: no DDC reply transaction type");
        }
        return nil;
    }

    LumenDDCMapping *mapping = [LumenDDCMapping new];
    mapping.arm64 = NO;
    mapping.framebuffer = framebuffer;
    mapping.replyTransactionType = transactionType;
    mapping.maxBrightness = 100;
    return mapping;
}

- (io_service_t)framebufferByDisplayPropertiesForDisplay:(LumenDisplay *)display {
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t status = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(IOFRAMEBUFFER_CONFORMSTO), &iterator);
    if (status != KERN_SUCCESS) {
        return 0;
    }

    io_service_t matched = 0;
    io_service_t service = 0;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        NSDictionary *dictionary = CFBridgingRelease(IODisplayCreateInfoDictionary(service, kIODisplayOnlyPreferredName));
        NSNumber *vendor = LumenNumberFromDictionary(dictionary, kDisplayVendorID);
        NSNumber *product = LumenNumberFromDictionary(dictionary, kDisplayProductID);
        NSNumber *serial = LumenNumberFromDictionary(dictionary, kDisplaySerialNumber);
        if (vendor.unsignedIntValue == CGDisplayVendorNumber(display.displayID) &&
            product.unsignedIntValue == CGDisplayModelNumber(display.displayID) &&
            serial.unsignedIntValue == CGDisplaySerialNumber(display.displayID)) {
            matched = service;
            break;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return matched;
}

- (IOOptionBits)supportedIntelReplyTransactionType {
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t status = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("IOFramebufferI2CInterface"), &iterator);
    if (status != KERN_SUCCESS) {
        return 0;
    }

    IOOptionBits transactionType = 0;
    io_service_t service = 0;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        CFMutableDictionaryRef properties = NULL;
        if (IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS && properties) {
            NSDictionary *dictionary = CFBridgingRelease(properties);
            NSNumber *types = dictionary[@(kIOI2CTransactionTypesKey)];
            uint64_t value = types.unsignedLongLongValue;
            if ((value & (1ULL << kIOI2CDDCciReplyTransactionType)) != 0) {
                transactionType = kIOI2CDDCciReplyTransactionType;
            } else if ((value & (1ULL << kIOI2CSimpleTransactionType)) != 0) {
                transactionType = kIOI2CSimpleTransactionType;
            }
        }
        IOObjectRelease(service);
        if (transactionType != 0) {
            break;
        }
    }
    IOObjectRelease(iterator);
    return transactionType;
}

- (LumenDDCMapping *)armMappingForDisplay:(LumenDisplay *)display error:(NSError **)error {
    NSArray<NSDictionary<NSString *, id> *> *candidates = [self armServiceCandidates];
    NSUInteger externalDisplayCount = [self externalDisplayCount];
    NSMutableArray<NSDictionary<NSString *, id> *> *ranked = [NSMutableArray new];
    NSInteger bestScore = 0;

    for (NSDictionary *candidate in candidates) {
        NSInteger score = [self armCandidate:candidate scoreForDisplay:display];
        if (score == 0 && externalDisplayCount == 1 && candidates.count == 1) {
            score = 1;
        }
        if (score > 0) {
            NSMutableDictionary *rankedCandidate = [candidate mutableCopy];
            rankedCandidate[@"score"] = @(score);
            [ranked addObject:rankedCandidate];
            bestScore = MAX(bestScore, score);
        }
    }

    NSArray *best = [ranked filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *candidate, NSDictionary *bindings) {
        return [candidate[@"score"] integerValue] == bestScore;
    }]];
    if (best.count == 0) {
        if (error) {
            *error = LumenBrightnessError(-20, @"no DDC/CI IOAVService found");
        }
        return nil;
    }
    if (best.count > 1) {
        if (error) {
            *error = LumenBrightnessError(-21, @"ambiguous display mapping for DDC/CI IOAVService");
        }
        return nil;
    }

    LumenDDCMapping *mapping = best.firstObject[@"mapping"];
    mapping.arm64 = YES;
    mapping.maxBrightness = 100;
    return mapping;
}

- (NSUInteger)externalDisplayCount {
    uint32_t count = 0;
    if (CGGetActiveDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) {
        return 0;
    }
    CGDirectDisplayID displayIDs[count];
    if (CGGetActiveDisplayList(count, displayIDs, &count) != kCGErrorSuccess) {
        return 0;
    }
    NSUInteger external = 0;
    for (uint32_t i = 0; i < count; i++) {
        if (!CGDisplayIsBuiltin(displayIDs[i])) {
            external++;
        }
    }
    return external;
}

- (NSArray<NSDictionary<NSString *, id> *> *)armServiceCandidates {
    NSMutableArray<NSDictionary<NSString *, id> *> *candidates = [NSMutableArray new];
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (!root) {
        return candidates;
    }

    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IORegistryEntryCreateIterator(root, kIOServicePlane, kIORegistryIterateRecursively, &iterator) != KERN_SUCCESS) {
        IOObjectRelease(root);
        return candidates;
    }

    NSMutableDictionary<NSString *, id> *currentDisplay = [NSMutableDictionary new];
    io_service_t entry = 0;
    NSUInteger serviceLocation = 0;
    while ((entry = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        io_name_t name;
        if (IORegistryEntryGetName(entry, name) != KERN_SUCCESS) {
            IOObjectRelease(entry);
            continue;
        }
        NSString *entryName = @(name);
        if ([entryName containsString:@"AppleCLCD2"] || [entryName containsString:@"IOMobileFramebufferShim"]) {
            currentDisplay = [[self armDisplayPropertiesForEntry:entry] mutableCopy];
            serviceLocation++;
            currentDisplay[@"serviceLocation"] = @(serviceLocation);
        } else if ([entryName containsString:@"DCPAVServiceProxy"]) {
            NSString *location = [self stringProperty:@"Location" entry:entry recursive:YES];
            if ([location isEqualToString:@"External"]) {
                IOAVService service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry);
                if (service) {
                    LumenDDCMapping *mapping = [LumenDDCMapping new];
                    mapping.avService = service;
                    NSMutableDictionary *candidate = currentDisplay ? [currentDisplay mutableCopy] : [NSMutableDictionary new];
                    candidate[@"mapping"] = mapping;
                    [candidates addObject:candidate];
                }
            }
        }
        IOObjectRelease(entry);
    }

    IOObjectRelease(iterator);
    IOObjectRelease(root);
    return candidates;
}

- (NSDictionary<NSString *, id> *)armDisplayPropertiesForEntry:(io_service_t)entry {
    NSMutableDictionary *properties = [NSMutableDictionary new];
    NSString *edidUUID = [self stringProperty:@"EDID UUID" entry:entry recursive:YES];
    if (edidUUID.length > 0) {
        properties[@"edidUUID"] = edidUUID;
    }

    io_string_t path;
    if (IORegistryEntryGetPath(entry, kIOServicePlane, path) == KERN_SUCCESS) {
        properties[@"ioDisplayLocation"] = @(path);
    }

    NSDictionary *displayAttributes = [self dictionaryProperty:@"DisplayAttributes" entry:entry recursive:YES];
    NSDictionary *productAttributes = displayAttributes[@"ProductAttributes"];
    if ([productAttributes isKindOfClass:[NSDictionary class]]) {
        if ([productAttributes[@"ProductName"] isKindOfClass:[NSString class]]) {
            properties[@"productName"] = productAttributes[@"ProductName"];
        }
        if ([productAttributes[@"SerialNumber"] isKindOfClass:[NSNumber class]]) {
            properties[@"serialNumber"] = productAttributes[@"SerialNumber"];
        }
    }
    return properties;
}

- (NSInteger)armCandidate:(NSDictionary<NSString *, id> *)candidate scoreForDisplay:(LumenDisplay *)display {
    NSDictionary *displayInfo = CFBridgingRelease(CoreDisplay_DisplayCreateInfoDictionary(display.displayID));
    NSInteger score = 0;
    NSString *candidateLocation = candidate[@"ioDisplayLocation"];
    NSString *displayLocation = displayInfo[@(kIODisplayLocationKey)];
    if (candidateLocation.length > 0 && [candidateLocation isEqualToString:displayLocation]) {
        score += 10;
    }

    NSString *candidateName = candidate[@"productName"];
    NSDictionary *displayProductName = displayInfo[@"DisplayProductName"];
    NSString *localizedDisplayName = [displayProductName isKindOfClass:[NSDictionary class]] ? (displayProductName[@"en_US"] ?: displayProductName.allValues.firstObject) : nil;
    if (candidateName.length > 0 && localizedDisplayName.length > 0 &&
        [candidateName caseInsensitiveCompare:localizedDisplayName] == NSOrderedSame) {
        score += 1;
    }

    NSNumber *candidateSerial = candidate[@"serialNumber"];
    NSNumber *displaySerial = LumenNumberFromDictionary(displayInfo, kDisplaySerialNumber);
    if (candidateSerial && displaySerial && candidateSerial.longLongValue == displaySerial.longLongValue) {
        score += 1;
    }
    return score;
}

- (NSString *)stringProperty:(NSString *)property entry:(io_service_t)entry recursive:(BOOL)recursive {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry,
                                                      (__bridge CFStringRef)property,
                                                      kCFAllocatorDefault,
                                                      recursive ? kIORegistryIterateRecursively : 0);
    if (!value) {
        return nil;
    }
    id object = CFBridgingRelease(value);
    return [object isKindOfClass:[NSString class]] ? object : nil;
}

- (NSDictionary *)dictionaryProperty:(NSString *)property entry:(io_service_t)entry recursive:(BOOL)recursive {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry,
                                                      (__bridge CFStringRef)property,
                                                      kCFAllocatorDefault,
                                                      recursive ? kIORegistryIterateRecursively : 0);
    if (!value) {
        return nil;
    }
    id object = CFBridgingRelease(value);
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

- (BOOL)readBrightnessCurrent:(UInt16 *)current maximum:(UInt16 *)maximum mapping:(LumenDDCMapping *)mapping error:(NSError **)error {
    if (mapping.arm64) {
        return [self armReadCommand:LumenDDCVCPBrightness current:current maximum:maximum mapping:mapping error:error];
    }
    return [self intelReadCommand:LumenDDCVCPBrightness current:current maximum:maximum mapping:mapping error:error];
}

- (BOOL)writeBrightness:(UInt16)value mapping:(LumenDDCMapping *)mapping error:(NSError **)error {
    if (mapping.arm64) {
        return [self armWriteCommand:LumenDDCVCPBrightness value:value mapping:mapping error:error];
    }
    return [self intelWriteCommand:LumenDDCVCPBrightness value:value mapping:mapping error:error];
}

- (BOOL)intelSendRequest:(IOI2CRequest *)request mapping:(LumenDDCMapping *)mapping {
    IOItemCount busCount = 0;
    if (IOFBGetI2CInterfaceCount(mapping.framebuffer, &busCount) != KERN_SUCCESS) {
        return NO;
    }
    for (IOOptionBits bus = 0; bus < busCount; bus++) {
        io_service_t interface = 0;
        if (IOFBCopyI2CInterfaceForBus(mapping.framebuffer, bus, &interface) != KERN_SUCCESS) {
            continue;
        }
        IOI2CConnectRef connect = NULL;
        BOOL success = NO;
        if (IOI2CInterfaceOpen(interface, 0, &connect) == KERN_SUCCESS) {
            success = IOI2CSendRequest(connect, 0, request) == KERN_SUCCESS && request->result == KERN_SUCCESS;
            IOI2CInterfaceClose(connect, 0);
        }
        IOObjectRelease(interface);
        if (success) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)intelReadCommand:(UInt8)command current:(UInt16 *)current maximum:(UInt16 *)maximum mapping:(LumenDDCMapping *)mapping error:(NSError **)error {
    UInt8 data[5] = {LumenDDCSubAddress, 0x82, 0x01, command, 0};
    data[4] = LumenDDCChecksum(LumenIntelDDCWriteAddress, data, 4);
    UInt8 reply[11] = {0};

    IOI2CRequest request = {0};
    request.commFlags = 0;
    request.sendAddress = LumenIntelDDCWriteAddress;
    request.sendTransactionType = kIOI2CSimpleTransactionType;
    request.sendBuffer = (vm_address_t)data;
    request.sendBytes = sizeof(data);
    request.minReplyDelay = 10;
    request.replyAddress = LumenIntelDDCReadAddress;
    request.replySubAddress = LumenDDCSubAddress;
    request.replyTransactionType = mapping.replyTransactionType;
    request.replyBuffer = (vm_address_t)reply;
    request.replyBytes = sizeof(reply);

    usleep(10000);
    if (![self intelSendRequest:&request mapping:mapping]) {
        if (error) {
            *error = LumenBrightnessError(-30, @"DDC/CI brightness read failed");
        }
        return NO;
    }

    if (reply[10] != LumenDDCChecksum(0x50, reply, 10) || reply[2] != 0x02 || reply[3] != 0x00) {
        if (error) {
            *error = LumenBrightnessError(-31, reply[3] != 0x00 ? @"brightness command unsupported" : @"DDC/CI brightness read returned invalid data");
        }
        return NO;
    }

    *maximum = ((UInt16)reply[6] << 8) | reply[7];
    *current = ((UInt16)reply[8] << 8) | reply[9];
    if (*maximum == 0) {
        if (error) {
            *error = LumenBrightnessError(-32, @"DDC/CI brightness read returned zero maximum");
        }
        return NO;
    }
    return YES;
}

- (BOOL)intelWriteCommand:(UInt8)command value:(UInt16)value mapping:(LumenDDCMapping *)mapping error:(NSError **)error {
    UInt8 data[7] = {LumenDDCSubAddress, 0x84, 0x03, command, (UInt8)(value >> 8), (UInt8)(value & 0xff), 0};
    data[6] = LumenDDCChecksum(LumenIntelDDCWriteAddress, data, 6);

    BOOL success = NO;
    for (NSUInteger i = 0; i < 2; i++) {
        IOI2CRequest request = {0};
        request.commFlags = 0;
        request.sendAddress = LumenIntelDDCWriteAddress;
        request.sendTransactionType = kIOI2CSimpleTransactionType;
        request.sendBuffer = (vm_address_t)data;
        request.sendBytes = sizeof(data);
        request.replyTransactionType = kIOI2CNoTransactionType;
        request.replyBytes = 0;
        usleep(10000);
        success = [self intelSendRequest:&request mapping:mapping] || success;
    }
    if (!success && error) {
        *error = LumenBrightnessError(-33, @"DDC/CI brightness write failed");
    }
    return success;
}

- (BOOL)armReadCommand:(UInt8)command current:(UInt16 *)current maximum:(UInt16 *)maximum mapping:(LumenDDCMapping *)mapping error:(NSError **)error {
    UInt8 packet[5] = {0x82, 0x01, command, 0, 0};
    packet[3] = LumenDDCChecksum(LumenArmDDC7BitAddress << 1, packet, 3);
    UInt8 reply[11] = {0};

    BOOL success = NO;
    for (NSUInteger attempt = 0; attempt < 5 && !success; attempt++) {
        usleep(10000);
        IOReturn writeResult = IOAVServiceWriteI2C(mapping.avService, LumenArmDDC7BitAddress, LumenDDCSubAddress, packet, 4);
        usleep(50000);
        IOReturn readResult = IOAVServiceReadI2C(mapping.avService, LumenArmDDC7BitAddress, 0, reply, sizeof(reply));
        success = writeResult == KERN_SUCCESS && readResult == KERN_SUCCESS && reply[10] == LumenDDCChecksum(0x50, reply, 10);
        if (!success) {
            usleep(20000);
        }
    }
    if (!success || reply[2] != 0x02 || reply[3] != 0x00) {
        if (error) {
            *error = LumenBrightnessError(-40, reply[3] != 0x00 ? @"brightness command unsupported" : @"DDC/CI brightness read failed");
        }
        return NO;
    }

    *maximum = ((UInt16)reply[6] << 8) | reply[7];
    *current = ((UInt16)reply[8] << 8) | reply[9];
    if (*maximum == 0) {
        if (error) {
            *error = LumenBrightnessError(-41, @"DDC/CI brightness read returned zero maximum");
        }
        return NO;
    }
    return YES;
}

- (BOOL)armWriteCommand:(UInt8)command value:(UInt16)value mapping:(LumenDDCMapping *)mapping error:(NSError **)error {
    UInt8 packet[6] = {0x84, 0x03, command, (UInt8)(value >> 8), (UInt8)(value & 0xff), 0};
    packet[5] = LumenDDCChecksum((LumenArmDDC7BitAddress << 1) ^ LumenDDCSubAddress, packet, 5);

    BOOL success = NO;
    for (NSUInteger attempt = 0; attempt < 5 && !success; attempt++) {
        for (NSUInteger cycle = 0; cycle < 2; cycle++) {
            usleep(10000);
            success = IOAVServiceWriteI2C(mapping.avService, LumenArmDDC7BitAddress, LumenDDCSubAddress, packet, sizeof(packet)) == KERN_SUCCESS || success;
        }
        if (!success) {
            usleep(20000);
        }
    }
    if (!success && error) {
        *error = LumenBrightnessError(-42, @"DDC/CI brightness write failed");
    }
    return success;
}

@end

@implementation BrightnessController

- (id)init {
    self = [super init];
    if (self) {
        self.activeDisplays = @[];
        self.currentLightnessByDisplayKey = [NSMutableDictionary new];
        self.streamsByDisplayKey = [NSMutableDictionary new];
        self.displayKeyByStream = [NSMutableDictionary new];
        self.displayStatesByKey = [NSMutableDictionary new];
        self.debugEvents = [NSMutableArray new];
        self.brightnessBackends = @[[DisplayServicesBrightnessBackend new],
                                    [ExternalDisplayBrightnessBackend new]];
        self.model = [Model new];
        self.ignoreList = [[IgnoreListController alloc] init];
        self.lastActiveAppURLString = @"";
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)isRunning {
    return self.running;
}

- (void)start {
    [self stop];
    self.running = YES;
    if (!self.displayCallbackRegistered) {
        CGDisplayRegisterReconfigurationCallback(LumenDisplayReconfigurationCallback, (__bridge void *)self);
        self.displayCallbackRegistered = YES;
    }
    [self reloadDisplaysAndStreams];
}

- (void)stop {
    self.running = NO;
    if (self.displayCallbackRegistered) {
        CGDisplayRemoveReconfigurationCallback(LumenDisplayReconfigurationCallback, (__bridge void *)self);
        self.displayCallbackRegistered = NO;
    }
    [self stopCaptureStreams];
}

- (void)reloadDisplaysAndStreams {
    if (!self.running) {
        return;
    }

    self.displayConfigurationGeneration++;
    NSUInteger generation = self.displayConfigurationGeneration;
    [self stopCaptureStreams];

    NSArray<LumenDisplay *> *displays = [LumenDisplay activeDisplays];
    NSMutableDictionary<NSString *, LumenDisplayState *> *states = [NSMutableDictionary new];
    for (LumenDisplay *display in displays) {
        LumenDisplayState *state = self.displayStatesByKey[display.stableKey] ?: [LumenDisplayState new];
        id<LumenBrightnessBackend> backend = [self backendForDisplay:display];
        display.brightnessControllable = backend != nil;
        display.brightnessBackendName = backend ? backend.name : @"unsupported";
        state.canReadBrightness = backend != nil;
        state.canSetBrightness = backend != nil;

        if (display.brightnessControllable) {
            NSUInteger beforeSampleCount = [self.model debugSampleCountForDisplayKey:display.stableKey];
            [self.model ensureModelForDisplayKey:display.stableKey seedWithLegacyDefaults:display.builtin];
            NSUInteger afterSampleCount = [self.model debugSampleCountForDisplayKey:display.stableKey];
            if (display.builtin && beforeSampleCount == 0 && afterSampleCount > 0) {
                state.seededFromLegacyModel = YES;
                [self addDebugEvent:[NSString stringWithFormat:@"model seeded from legacy global data (%lu samples)", (unsigned long)afterSampleCount]
                            display:display];
            }
        } else {
            NSString *failureReason = [self brightnessFailureReasonForDisplay:display] ?: @"unsupported brightness backend";
            state.lastReadError = failureReason;
            [self setAction:@"skipped: unsupported brightness backend" reason:@"unsupported brightness backend" display:display state:state];
            [self addDebugEvent:[NSString stringWithFormat:@"brightness unsupported: %@", failureReason] display:display];
            os_log_info(LumenDebugLog(),
                        "Brightness unsupported display=%{public}@ key=%{public}@ id=%{public}u reason=%{public}@",
                        display.displayName,
                        [self shortDisplayKey:display.stableKey],
                        display.displayID,
                        failureReason);
        }

        states[display.stableKey] = state;
        [self addDebugEvent:[NSString stringWithFormat:@"display discovered (%@, backend %@)",
                             [self roleForDisplay:display],
                             display.brightnessBackendName]
                    display:display];
        os_log_info(LumenDebugLog(),
                    "Display discovered name=%{public}@ role=%{public}@ key=%{public}@ backend=%{public}@ controllable=%{public}@",
                    display.displayName,
                    [self roleForDisplay:display],
                    [self shortDisplayKey:display.stableKey],
                    display.brightnessBackendName,
                    display.brightnessControllable ? @"YES" : @"NO");
    }
    self.activeDisplays = displays;
    self.displayStatesByKey = states;

    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.running || generation != self.displayConfigurationGeneration) {
                return;
            }
            if (error) {
                os_log_error(LumenDebugLog(), "ScreenCaptureKit content unavailable: %{public}@", error.localizedDescription);
                for (LumenDisplay *display in self.activeDisplays) {
                    LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
                    state.captureStatus = @"content unavailable";
                    [self setAction:@"skipped: no capture" reason:@"skipped no screen capture permission" display:display state:state];
                    [self addDebugEvent:[NSString stringWithFormat:@"screen capture unavailable: %@", error.localizedDescription] display:display];
                }
                return;
            }

            NSMutableDictionary<NSNumber *, SCDisplay *> *captureDisplaysByID = [NSMutableDictionary new];
            for (SCDisplay *captureDisplay in content.displays) {
                captureDisplaysByID[@(captureDisplay.displayID)] = captureDisplay;
            }

            for (LumenDisplay *display in self.activeDisplays) {
                SCDisplay *captureDisplay = captureDisplaysByID[@(display.displayID)];
                if (!captureDisplay) {
                    LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
                    state.captureStatus = @"no capture display";
                    [self setAction:@"skipped: no capture" reason:@"skipped display asleep/disconnected" display:display state:state];
                    [self addDebugEvent:@"ScreenCaptureKit display unavailable" display:display];
                    os_log_error(LumenDebugLog(),
                                 "ScreenCaptureKit display unavailable name=%{public}@ key=%{public}@ id=%{public}u",
                                 display.displayName,
                                 [self shortDisplayKey:display.stableKey],
                                 display.displayID);
                    continue;
                }
                [self startCaptureForDisplay:display captureDisplay:captureDisplay generation:generation];
            }
        });
    }];
}

- (void)startCaptureForDisplay:(LumenDisplay *)display
                captureDisplay:(SCDisplay *)captureDisplay
                     generation:(NSUInteger)generation {
    SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
    config.width = MAX(1, captureDisplay.width / LINEAR_SUBSAMPLE);
    config.height = MAX(1, captureDisplay.height / LINEAR_SUBSAMPLE);
    config.minimumFrameInterval = CMTimeMake(1, FRAME_RATE);
    config.pixelFormat = kCVPixelFormatType_32BGRA;
    config.showsCursor = NO;
    config.capturesAudio = NO;

    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:captureDisplay excludingWindows:@[]];
    SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
    if (!stream) {
        LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
        state.captureStatus = @"stream creation failed";
        [self setAction:@"skipped: no capture" reason:@"skipped no screen capture permission" display:display state:state];
        [self addDebugEvent:@"capture stream creation failed" display:display];
        return;
    }

    NSError *streamError = nil;
    [stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_get_main_queue() error:&streamError];
    if (streamError) {
        LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
        state.captureStatus = @"stream output failed";
        [self setAction:@"skipped: no capture" reason:@"skipped no screen capture permission" display:display state:state];
        [self addDebugEvent:[NSString stringWithFormat:@"capture output failed: %@", streamError.localizedDescription] display:display];
        return;
    }

    NSValue *streamKey = [NSValue valueWithNonretainedObject:stream];
    self.streamsByDisplayKey[display.stableKey] = stream;
    self.displayKeyByStream[streamKey] = display.stableKey;

    [stream startCaptureWithCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.running || generation != self.displayConfigurationGeneration) {
                return;
            }
            if (error) {
                LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
                state.captureStatus = @"capture failed";
                state.captureActive = NO;
                [self setAction:@"skipped: no capture" reason:@"skipped no screen capture permission" display:display state:state];
                [self addDebugEvent:[NSString stringWithFormat:@"capture failed: %@", error.localizedDescription] display:display];
                os_log_error(LumenDebugLog(),
                             "Capture failed display=%{public}@ key=%{public}@ error=%{public}@",
                             display.displayName,
                             [self shortDisplayKey:display.stableKey],
                             error.localizedDescription);
            } else {
                LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
                state.captureStatus = @"active";
                state.captureActive = YES;
                [self addDebugEvent:@"capture active" display:display];
                os_log_info(LumenDebugLog(),
                            "Capture active display=%{public}@ key=%{public}@",
                            display.displayName,
                            [self shortDisplayKey:display.stableKey]);
            }
        });
    }];
}

- (void)stopCaptureStreams {
    for (NSString *displayKey in self.streamsByDisplayKey) {
        SCStream *stream = self.streamsByDisplayKey[displayKey];
        [stream stopCaptureWithCompletionHandler:^(NSError *error) {
            if (error) {
                os_log_error(LumenDebugLog(),
                             "Capture stop failed key=%{public}@ error=%{public}@",
                             [self shortDisplayKey:displayKey],
                             error.localizedDescription);
            }
        }];
        LumenDisplayState *state = self.displayStatesByKey[displayKey];
        state.captureStatus = @"stopped";
        state.captureActive = NO;
    }
    [self.streamsByDisplayKey removeAllObjects];
    [self.displayKeyByStream removeAllObjects];
}

- (BOOL)checkIgnoreList {
    NSString *lumenBundleString = [NSBundle mainBundle].bundleURL.absoluteString.stringByStandardizingPath;
    NSRunningApplication *activeApplication = [NSWorkspace sharedWorkspace].frontmostApplication;
    NSString *activeAppURLString = activeApplication.bundleURL.absoluteString.stringByStandardizingPath;
    BOOL isLumenActive = NO;
    BOOL skip = NO;

    if ([activeAppURLString isEqualToString:lumenBundleString]) {
        isLumenActive = YES;
        if ([self.ignoreList containsURLString:self.lastActiveAppURLString]) {
            return YES;
        }
    }

    if ([self.ignoreList containsURLString:activeAppURLString]) {
        for (LumenDisplayState *state in self.displayStatesByKey.allValues) {
            state.shouldIgnoreOutput = YES;
        }
        for (LumenDisplay *display in self.activeDisplays) {
            LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
            [self setAction:@"skipped: ignored app" reason:@"skipped ignored app" display:display state:state];
            state.lastTrainingDecision = @"ignored app";
        }

        float preferredBrightness = [self.ignoreList preferredBrightnessForURLString:activeAppURLString].floatValue;
        LumenDisplay *primaryDisplay = [self primaryControllableDisplay];
        if ([activeAppURLString isEqualToString:self.lastActiveAppURLString] && primaryDisplay) {
            NSError *brightnessError = nil;
            float currentBrightness = [self brightnessForDisplay:primaryDisplay error:&brightnessError];
            if (!brightnessError && fabs(currentBrightness - preferredBrightness) > CHANGE_NOTICE) {
                LumenDisplayState *state = self.displayStatesByKey[primaryDisplay.stableKey];
                state.latestBrightness = currentBrightness;
                state.latestBrightnessTime = [NSDate timeIntervalSinceReferenceDate];
                state.canReadBrightness = YES;
                [self.ignoreList setPreferredBrightness:@(currentBrightness) forURLString:activeAppURLString];
            }
        } else if (preferredBrightness > -1) {
            for (LumenDisplay *display in self.activeDisplays) {
                if (!display.brightnessControllable) {
                    continue;
                }
                NSError *setError = nil;
                [self setBrightness:preferredBrightness forDisplay:display updateState:YES error:&setError];
                if (setError) {
                    [self addDebugEvent:[NSString stringWithFormat:@"ignored-app brightness restore failed: %@", setError.localizedDescription] display:display];
                }
            }
        }

        skip = YES;
    }

    if (!isLumenActive) {
        self.lastActiveAppURLString = activeAppURLString;
    }

    return skip;
}

- (void)processLightness:(double)lightness forDisplay:(LumenDisplay *)display {
    LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
    if (!state) {
        return;
    }

    NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
    float brightness = [self.model predictFromInput:lightness displayKey:display.stableKey];
    state.latestTargetBrightness = brightness;
    state.latestTargetTime = currentTime;

    if (!display.brightnessControllable) {
        [self setAction:@"skipped: unsupported brightness backend" reason:@"unsupported brightness backend" display:display state:state];
        state.lastTrainingDecision = @"not trained: unsupported brightness backend";
        [self addSkippedDecisionEventForDisplay:display
                                          state:state
                                      lightness:lightness
                                         target:brightness
                              currentBrightness:state.latestBrightness
                                         reason:@"unsupported brightness backend"];
        return;
    }

    NSError *brightnessError = nil;
    float setPoint = [self brightnessForDisplay:display error:&brightnessError];
    if (brightnessError) {
        state.canReadBrightness = NO;
        state.lastReadError = brightnessError.localizedDescription ?: @"brightness read failed";
        [self setAction:@"skipped: unreadable brightness" reason:@"unreadable brightness" display:display state:state];
        [self addSkippedDecisionEventForDisplay:display
                                          state:state
                                      lightness:lightness
                                         target:brightness
                              currentBrightness:state.latestBrightness
                                         reason:@"unreadable brightness"];
        [self addDebugEvent:[NSString stringWithFormat:@"brightness read failed: %@", state.lastReadError] display:display];
        os_log_error(LumenDebugLog(),
                     "Brightness read failed display=%{public}@ key=%{public}@ error=%{public}@",
                     display.displayName,
                     [self shortDisplayKey:display.stableKey],
                     state.lastReadError);
        display.brightnessControllable = NO;
        display.brightnessBackendName = @"unsupported";
        return;
    }
    state.canReadBrightness = YES;
    state.lastReadError = @"";
    state.latestBrightness = setPoint;
    state.latestBrightnessTime = currentTime;

    if (state.noticed || fabsf(state.lastSet - setPoint) > CHANGE_NOTICE) {
        if (!state.noticed) {
            state.noticed = YES;
            state.lastManualOverrideOldBrightness = state.lastSet;
            state.lastManualOverrideNewBrightness = setPoint;
            state.lastManualOverrideDelta = state.lastSet >= 0 ? setPoint - state.lastSet : 0;
            state.lastNoticed = setPoint;
            state.lastManualChangeTime = currentTime;
            state.lastTrainingDecision = @"pending: manual override debounce";
            [self setAction:@"skipped: debounce" reason:@"debounce" display:display state:state];
            [self addSkippedDecisionEventForDisplay:display
                                              state:state
                                          lightness:lightness
                                             target:brightness
                                  currentBrightness:setPoint
                                             reason:@"debounce"];
            [self addDebugEvent:[NSString stringWithFormat:@"manual override detected %.3f -> %.3f",
                                 state.lastManualOverrideOldBrightness,
                                 setPoint]
                        display:display];
            return;
        }
        if (fabsf(setPoint - state.lastNoticed) > CHANGE_NOTICE) {
            state.lastManualOverrideNewBrightness = setPoint;
            state.lastManualOverrideDelta = state.lastManualOverrideOldBrightness >= 0 ? setPoint - state.lastManualOverrideOldBrightness : 0;
            state.lastNoticed = setPoint;
            state.lastManualChangeTime = currentTime;
            state.lastTrainingDecision = @"pending: manual override changing";
            [self setAction:@"skipped: debounce" reason:@"debounce" display:display state:state];
            [self addSkippedDecisionEventForDisplay:display
                                              state:state
                                          lightness:lightness
                                             target:brightness
                                  currentBrightness:setPoint
                                             reason:@"debounce"];
            return;
        } else if (currentTime - state.lastManualChangeTime < DEBOUNCE_DELAY) {
            state.lastTrainingDecision = @"pending: manual override debounce";
            [self setAction:@"skipped: debounce" reason:@"debounce" display:display state:state];
            [self addSkippedDecisionEventForDisplay:display
                                              state:state
                                          lightness:lightness
                                             target:brightness
                                  currentBrightness:setPoint
                                             reason:@"debounce"];
            return;
        } else if (state.shouldIgnoreOutput) {
            state.shouldIgnoreOutput = NO;
            state.noticed = NO;
            state.lastTrainingDecision = @"ignored: self-write or ignored app";
            state.lastLearnEvent = [NSString stringWithFormat:@"ignored %.3f @ %@", setPoint, [self formattedTime:currentTime]];
            [self addDebugEvent:@"manual-looking change ignored" display:display];
        } else {
            [self.model observeOutput:setPoint forInput:lightness displayKey:display.stableKey];
            state.lastLearnTime = currentTime;
            state.lastManualOverrideNewBrightness = setPoint;
            state.lastManualOverrideDelta = state.lastManualOverrideOldBrightness >= 0 ? setPoint - state.lastManualOverrideOldBrightness : 0;
            state.lastLearnEvent = [NSString stringWithFormat:@"manual %.3f @ %@", setPoint, [self formattedTime:currentTime]];
            state.lastTrainingDecision = @"trained: manual override";
            [self addDebugEvent:[NSString stringWithFormat:@"model trained manual brightness %.3f at L*=%.2f", setPoint, lightness]
                        display:display];
            os_log_info(LumenDebugLog(),
                        "Model trained display=%{public}@ key=%{public}@ lightness=%{public}.2f brightness=%{public}.3f delta=%{public}.3f",
                        display.displayName,
                        [self shortDisplayKey:display.stableKey],
                        lightness,
                        setPoint,
                        state.lastManualOverrideDelta);
            state.noticed = NO;
        }
    } else {
        state.lastTrainingDecision = @"not trained: no manual override";
    }

    if (currentTime - state.lastAutoBrightnessTime < DEBOUNCE_DELAY) {
        [self setAction:@"skipped: debounce" reason:@"debounce" display:display state:state];
        [self addSkippedDecisionEventForDisplay:display
                                          state:state
                                      lightness:lightness
                                         target:brightness
                              currentBrightness:setPoint
                                         reason:@"debounce"];
        return;
    }

    if (brightness == state.lastAssigned) {
        [self setAction:@"unchanged" reason:@"unchanged within tolerance" display:display state:state];
        [self addSkippedDecisionEventForDisplay:display
                                          state:state
                                      lightness:lightness
                                         target:brightness
                              currentBrightness:setPoint
                                         reason:@"unchanged"];
        return;
    }

    NSError *setError = nil;
    if ([self setBrightness:brightness forDisplay:display updateState:YES error:&setError]) {
        state.canSetBrightness = YES;
        state.lastWriteError = @"";
        state.lastWrittenBrightness = brightness;
        state.lastWriteTime = currentTime;
        state.lastAssigned = brightness;
        state.lastAutoBrightnessTime = currentTime;
        [self setAction:[NSString stringWithFormat:@"set %.3f", brightness] reason:@"set" display:display state:state];
        [self addDebugEvent:[NSString stringWithFormat:@"brightness set %.3f", brightness] display:display];
        os_log_info(LumenDebugLog(),
                    "Brightness set display=%{public}@ key=%{public}@ lightness=%{public}.2f target=%{public}.3f",
                    display.displayName,
                    [self shortDisplayKey:display.stableKey],
                    lightness,
                    brightness);
    } else {
        state.canSetBrightness = NO;
        state.lastWriteError = setError.localizedDescription ?: @"brightness write failed";
        [self setAction:@"skipped: write failed" reason:@"write failed" display:display state:state];
        [self addSkippedDecisionEventForDisplay:display
                                          state:state
                                      lightness:lightness
                                         target:brightness
                              currentBrightness:setPoint
                                         reason:@"write failed"];
        [self addDebugEvent:[NSString stringWithFormat:@"brightness write failed: %@", state.lastWriteError] display:display];
        os_log_error(LumenDebugLog(),
                     "Brightness write failed display=%{public}@ key=%{public}@ target=%{public}.3f error=%{public}@",
                     display.displayName,
                     [self shortDisplayKey:display.stableKey],
                     brightness,
                     state.lastWriteError);
        display.brightnessControllable = NO;
        display.brightnessBackendName = @"unsupported";
    }
}

- (BOOL)canControlBrightnessForDisplay:(LumenDisplay *)display {
    return [self backendForDisplay:display] != nil;
}

- (float)brightnessForDisplay:(LumenDisplay *)display error:(NSError **)error {
    id<LumenBrightnessBackend> backend = [self backendForDisplay:display];
    if (!backend) {
        if (error) {
            *error = [NSError errorWithDomain:LumenBrightnessErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"No brightness backend supports this display"}];
        }
        return 0;
    }
    return [backend brightnessForDisplay:display error:error];
}

- (BOOL)setBrightness:(float)brightness forDisplay:(LumenDisplay *)display error:(NSError **)error {
    return [self setBrightness:brightness forDisplay:display updateState:NO error:error];
}

- (BOOL)setBrightness:(float)brightness
           forDisplay:(LumenDisplay *)display
          updateState:(BOOL)updateState
                error:(NSError **)error {
    id<LumenBrightnessBackend> backend = [self backendForDisplay:display];
    if (!backend) {
        if (error) {
            *error = [NSError errorWithDomain:LumenBrightnessErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"No brightness backend supports this display"}];
        }
        return NO;
    }

    if (![backend setBrightness:brightness forDisplay:display error:error]) {
        return NO;
    }

    LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
    state.canSetBrightness = YES;
    state.lastWriteError = @"";
    state.lastWrittenBrightness = brightness;
    state.lastWriteTime = [NSDate timeIntervalSinceReferenceDate];

    if (updateState) {
        NSError *readBackError = nil;
        float readBack = [backend brightnessForDisplay:display error:&readBackError];
        if (!readBackError) {
            state.lastSet = readBack;
            state.latestBrightness = readBack;
            state.latestBrightnessTime = [NSDate timeIntervalSinceReferenceDate];
            state.canReadBrightness = YES;
        } else {
            state.lastSet = brightness;
            state.lastReadError = readBackError.localizedDescription ?: @"brightness readback failed";
        }
    }
    return YES;
}

- (NSArray<NSDictionary<NSString *, id> *> *)displayDebugStatuses {
    NSMutableArray<NSDictionary<NSString *, id> *> *statuses = [NSMutableArray new];
    for (LumenDisplay *display in self.activeDisplays) {
        [statuses addObject:[self debugDictionaryForDisplay:display]];
    }
    return statuses;
}

- (NSDictionary<NSString *, id> *)debugSnapshot {
    NSMutableArray *displays = [NSMutableArray new];
    for (LumenDisplay *display in self.activeDisplays) {
        [displays addObject:[self debugDictionaryForDisplay:display]];
    }

    return @{@"running": @(self.running),
             @"generatedAt": @([NSDate timeIntervalSinceReferenceDate]),
             @"displays": displays,
             @"events": self.debugEvents.copy};
}

- (NSString *)debugSnapshotText {
    NSDictionary *snapshot = [self debugSnapshot];
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:snapshot
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&error];
    if (jsonData && !error) {
        return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    }
    return [snapshot description];
}

- (NSDictionary<NSString *, id> *)debugDictionaryForDisplay:(LumenDisplay *)display {
    LumenDisplayState *state = self.displayStatesByKey[display.stableKey] ?: [LumenDisplayState new];
    NSUInteger sampleCount = [self.model debugSampleCountForDisplayKey:display.stableKey];
    BOOL learned = [self.model hasLearnedDataForDisplayKey:display.stableKey];
    NSString *modelState = learned ? [NSString stringWithFormat:@"%lu samples", (unsigned long)sampleCount] : @"no data";
    if (state.seededFromLegacyModel) {
        modelState = [modelState stringByAppendingString:@" seeded"];
    }

    CGFloat scaleFactor = 0;
    for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *screenDisplayID = screen.deviceDescription[@"NSScreenNumber"];
        if (screenDisplayID && screenDisplayID.unsignedIntValue == display.displayID) {
            scaleFactor = screen.backingScaleFactor;
            break;
        }
    }

    float normalizedLightness = state.latestLightness >= 0 ? state.latestLightness / 100.0 : -1;
    return @{@"name": display.displayName ?: @"",
             @"display": display.displayName ?: @"",
             @"key": display.stableKey ?: @"",
             @"debugKey": [self shortDisplayKey:display.stableKey],
             @"displayID": @(display.displayID),
             @"role": [self roleForDisplay:display],
             @"builtin": @(display.builtin),
             @"main": @(display.displayID == CGMainDisplayID()),
             @"bounds": NSStringFromRect(NSRectFromCGRect(display.bounds)),
             @"scaleFactor": @(scaleFactor),
             @"controllable": @(display.brightnessControllable),
             @"backend": display.brightnessBackendName ?: @"unsupported",
             @"captureStatus": state.captureStatus ?: @"unknown",
             @"captureActive": @(state.captureActive),
             @"lightness": @(normalizedLightness),
             @"lightnessLStar": @(state.latestLightness),
             @"lightnessTimestamp": @(state.latestLightnessTime),
             @"brightness": @(state.latestBrightness),
             @"brightnessTimestamp": @(state.latestBrightnessTime),
             @"target": @(state.latestTargetBrightness),
             @"targetTimestamp": @(state.latestTargetTime),
             @"action": state.lastAction ?: @"unknown",
             @"actionReason": state.lastActionReason ?: @"unknown",
             @"model": modelState,
             @"modelSampleCount": @(sampleCount),
             @"modelHasData": @(learned),
             @"learned": @(learned),
             @"modelRange": [self.model debugRangeSummaryForDisplayKey:display.stableKey] ?: @"",
             @"learnedPoints": [self.model debugLearnedPointsSummaryForDisplayKey:display.stableKey] ?: @"",
             @"lastLearn": state.lastLearnEvent ?: @"none",
             @"lastLearnTimestamp": @(state.lastLearnTime),
             @"trainingDecision": state.lastTrainingDecision ?: @"none",
             @"manualOldBrightness": @(state.lastManualOverrideOldBrightness),
             @"manualNewBrightness": @(state.lastManualOverrideNewBrightness),
             @"manualDelta": @(state.lastManualOverrideDelta),
             @"lastManualOverrideTimestamp": @(state.lastManualChangeTime),
             @"canReadBrightness": @(state.canReadBrightness),
             @"canSetBrightness": @(state.canSetBrightness),
             @"lastReadBrightness": @(state.latestBrightness),
             @"lastWrittenBrightness": @(state.lastWrittenBrightness),
             @"lastWriteTimestamp": @(state.lastWriteTime),
             @"lastWriteError": state.lastWriteError ?: @"",
             @"lastReadError": state.lastReadError ?: @""};
}

- (void)addDebugEvent:(NSString *)event display:(LumenDisplay *)display {
    if (event.length == 0) {
        return;
    }

    NSMutableDictionary *entry = [@{@"timestamp": @([NSDate timeIntervalSinceReferenceDate]),
                                    @"time": [self formattedTime:[NSDate timeIntervalSinceReferenceDate]],
                                    @"event": event} mutableCopy];
    if (display) {
        entry[@"display"] = display.displayName ?: @"";
        entry[@"key"] = display.stableKey ?: @"";
        entry[@"debugKey"] = [self shortDisplayKey:display.stableKey];
        entry[@"displayID"] = @(display.displayID);
    }
    [self.debugEvents addObject:entry];
    while (self.debugEvents.count > LumenMaxDebugEvents) {
        [self.debugEvents removeObjectAtIndex:0];
    }
}

- (void)addSkippedDecisionEventForDisplay:(LumenDisplay *)display
                                    state:(LumenDisplayState *)state
                                lightness:(double)lightness
                                   target:(float)target
                        currentBrightness:(float)currentBrightness
                                   reason:(NSString *)reason {
    NSString *event = [NSString stringWithFormat:@"decision skipped: %@ lightness %.3f target %.3f%@",
                       reason ?: @"unknown",
                       lightness / 100.0,
                       target,
                       currentBrightness >= 0 ? [NSString stringWithFormat:@" current %.3f", currentBrightness] : @""];
    NSMutableDictionary *entry = [@{@"timestamp": @([NSDate timeIntervalSinceReferenceDate]),
                                    @"time": [self formattedTime:[NSDate timeIntervalSinceReferenceDate]],
                                    @"event": event,
                                    @"action": @"skipped",
                                    @"reason": reason ?: @"unknown",
                                    @"role": [self roleForDisplay:display],
                                    @"lightness": @(lightness / 100.0),
                                    @"lightnessLStar": @(lightness),
                                    @"targetBrightness": @(target)} mutableCopy];
    if (currentBrightness >= 0) {
        entry[@"currentBrightness"] = @(currentBrightness);
    }
    if (display) {
        entry[@"display"] = display.displayName ?: @"";
        entry[@"key"] = display.stableKey ?: @"";
        entry[@"debugKey"] = [self shortDisplayKey:display.stableKey];
        entry[@"displayID"] = @(display.displayID);
    }
    [self.debugEvents addObject:entry];
    while (self.debugEvents.count > LumenMaxDebugEvents) {
        [self.debugEvents removeObjectAtIndex:0];
    }

    os_log_debug(LumenDebugLog(),
                 "Decision skipped display=%{public}@ role=%{public}@ lightness=%{public}.3f target=%{public}.3f current=%{public}.3f reason=%{public}@",
                 display.displayName,
                 [self roleForDisplay:display],
                 lightness / 100.0,
                 target,
                 currentBrightness,
                 reason ?: @"unknown");
}

- (void)setAction:(NSString *)action reason:(NSString *)reason display:(LumenDisplay *)display state:(LumenDisplayState *)state {
    if (!state) {
        return;
    }
    BOOL changed = ![state.lastAction isEqualToString:action] || ![state.lastActionReason isEqualToString:reason];
    state.lastAction = action ?: @"unknown";
    state.lastActionReason = reason ?: @"unknown";
    if (changed) {
        [self addDebugEvent:[NSString stringWithFormat:@"%@ (%@)", state.lastAction, state.lastActionReason]
                    display:display];
    }
}

- (NSString *)shortDisplayKey:(NSString *)stableKey {
    if (stableKey.length <= 8) {
        return stableKey ?: @"";
    }
    return [stableKey substringFromIndex:stableKey.length - 8];
}

- (NSString *)roleForDisplay:(LumenDisplay *)display {
    BOOL main = display.displayID == CGMainDisplayID();
    if (display.builtin && main) {
        return @"Built-in/Main";
    }
    if (display.builtin) {
        return @"Built-in";
    }
    if (main) {
        return @"External/Main";
    }
    return @"External";
}

- (NSString *)formattedTime:(NSTimeInterval)timestamp {
    if (timestamp <= 0) {
        return @"none";
    }
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm:ss";
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSinceReferenceDate:timestamp]];
}

- (id<LumenBrightnessBackend>)backendForDisplay:(LumenDisplay *)display {
    if (display.brightnessControllable && display.brightnessBackendName.length > 0) {
        for (id<LumenBrightnessBackend> backend in self.brightnessBackends) {
            if ([backend.name isEqualToString:display.brightnessBackendName]) {
                return backend;
            }
        }
    }

    for (id<LumenBrightnessBackend> backend in self.brightnessBackends) {
        if ([backend canControlDisplay:display]) {
            return backend;
        }
    }
    return nil;
}

- (NSString *)brightnessFailureReasonForDisplay:(LumenDisplay *)display {
    for (id<LumenBrightnessBackend> backend in self.brightnessBackends) {
        if ([backend respondsToSelector:@selector(failureReasonForDisplay:)]) {
            NSString *reason = [backend failureReasonForDisplay:display];
            if (reason.length > 0) {
                return reason;
            }
        }
    }
    return nil;
}

- (LumenDisplay *)displayForKey:(NSString *)displayKey {
    for (LumenDisplay *display in self.activeDisplays) {
        if ([display.stableKey isEqualToString:displayKey]) {
            return display;
        }
    }
    return nil;
}

- (LumenDisplay *)primaryControllableDisplay {
    for (LumenDisplay *display in self.activeDisplays) {
        if (display.builtin && display.brightnessControllable) {
            return display;
        }
    }
    for (LumenDisplay *display in self.activeDisplays) {
        if (display.brightnessControllable) {
            return display;
        }
    }
    return nil;
}

- (double)computeLightnessFromSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) {
        return 0;
    }

    OSType pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer);
    if (pixelFormat != kCVPixelFormatType_32BGRA) {
        NSLog(@"Unexpected pixel format: %d", (int)pixelFormat);
        return 0;
    }

    CVReturn lockResult = CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    if (lockResult != kCVReturnSuccess) {
        NSLog(@"Failed to lock pixel buffer: %d", lockResult);
        return 0;
    }

    void *baseAddress = CVPixelBufferGetBaseAddress(imageBuffer);
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);

    double lightness = 0;

    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            const unsigned char *pixel = (unsigned char *)baseAddress + (y * bytesPerRow) + (x * 4);
            double l = srgb_to_lightness(pixel[2], pixel[1], pixel[0]);
            lightness += l * l;
        }
    }

    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);

    lightness = sqrt(lightness / (width * height));
    return lightness;
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen) {
        return;
    }

    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!formatDescription) {
        NSLog(@"Sample buffer has no format description");
        return;
    }

    CMMediaType mediaType = CMFormatDescriptionGetMediaType(formatDescription);
    if (mediaType != kCMMediaType_Video) {
        NSLog(@"Non-video sample buffer received, media type: %d", (int)mediaType);
        return;
    }

    NSString *displayKey = self.displayKeyByStream[[NSValue valueWithNonretainedObject:stream]];
    LumenDisplay *display = [self displayForKey:displayKey];
    if (!display) {
        return;
    }

    double lightness = [self computeLightnessFromSampleBuffer:sampleBuffer];
    if (lightness <= 0) {
        LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
        [self setAction:@"skipped: no sample" reason:@"skipped no screen capture permission" display:display state:state];
        return;
    }

    [(NSMutableDictionary *)self.currentLightnessByDisplayKey setObject:@(lightness) forKey:display.stableKey];
    LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
    state.latestLightness = lightness;
    state.latestLightnessTime = [NSDate timeIntervalSinceReferenceDate];
    state.captureActive = YES;
    state.captureStatus = @"active";
    if (state.latestLightnessTime - state.lastLightnessLogTime > 10) {
        state.lastLightnessLogTime = state.latestLightnessTime;
        os_log_debug(LumenDebugLog(),
                     "Lightness display=%{public}@ key=%{public}@ lightness=%{public}.2f",
                     display.displayName,
                     [self shortDisplayKey:display.stableKey],
                     lightness);
    }

    if ([self checkIgnoreList]) {
        return;
    }

    [self processLightness:lightness forDisplay:display];
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    if (error) {
        os_log_error(LumenDebugLog(), "Stream stopped with error: %{public}@", error.localizedDescription);
    }
    NSString *displayKey = self.displayKeyByStream[[NSValue valueWithNonretainedObject:stream]];
    if (displayKey) {
        LumenDisplay *display = [self displayForKey:displayKey];
        LumenDisplayState *state = self.displayStatesByKey[displayKey];
        state.captureActive = NO;
        state.captureStatus = error ? @"stopped with error" : @"stopped";
        [self addDebugEvent:error ? [NSString stringWithFormat:@"capture stopped: %@", error.localizedDescription] : @"capture stopped"
                    display:display];
        [self.streamsByDisplayKey removeObjectForKey:displayKey];
        [self.displayKeyByStream removeObjectForKey:[NSValue valueWithNonretainedObject:stream]];
    }
}

@end
