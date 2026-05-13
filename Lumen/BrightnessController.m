// Copyright (c) Anish Athalye (me@anishathalye.com)
// Released under GPLv3. See the included LICENSE.txt for details

#import "BrightnessController.h"
#import "IgnoreListController.h"
#import "LumenDisplay.h"
#import "Model.h"
#import "Constants.h"
#import "util.h"
#import <IOKit/graphics/IOGraphicsLib.h>
#import <ApplicationServices/ApplicationServices.h>
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

extern int DisplayServicesGetBrightness(CGDirectDisplayID display, float *brightness);
extern int DisplayServicesSetBrightness(CGDirectDisplayID display, float brightness);

static NSString * const LumenBrightnessErrorDomain = @"com.anishathalye.lumen.brightness";

@protocol LumenBrightnessBackend <NSObject>

@property (nonatomic, copy, readonly) NSString *name;

- (BOOL)canControlDisplay:(LumenDisplay *)display;
- (float)brightnessForDisplay:(LumenDisplay *)display error:(NSError **)error;
- (BOOL)setBrightness:(float)brightness forDisplay:(LumenDisplay *)display error:(NSError **)error;

@end

@interface DisplayServicesBrightnessBackend : NSObject <LumenBrightnessBackend>
@end

@interface ExternalDisplayBrightnessBackend : NSObject <LumenBrightnessBackend>
@end

@interface LumenDisplayState : NSObject

@property (nonatomic, assign) float lastSet;
@property (nonatomic, assign) float lastAssigned;
@property (nonatomic, assign) BOOL noticed;
@property (nonatomic, assign) float lastNoticed;
@property (nonatomic, assign) NSTimeInterval lastAutoBrightnessTime;
@property (nonatomic, assign) NSTimeInterval lastManualChangeTime;
@property (nonatomic, assign) BOOL shouldIgnoreOutput;

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

@end

static void LumenDisplayReconfigurationCallback(CGDirectDisplayID display,
                                                CGDisplayChangeSummaryFlags flags,
                                                void *userInfo) {
    BrightnessController *controller = (__bridge BrightnessController *)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"Display reconfiguration callback display=%u flags=%u", display, flags);
        [controller reloadDisplaysAndStreams];
    });
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

// TODO: add a DDC/CI implementation here when the project has a documented
// local backend. This intentionally does not call MonitorControl internals.

- (NSString *)name {
    return @"ExternalDisplayBrightnessBackend";
}

- (BOOL)canControlDisplay:(LumenDisplay *)display {
    return NO;
}

- (float)brightnessForDisplay:(LumenDisplay *)display error:(NSError **)error {
    if (error) {
        *error = [NSError errorWithDomain:LumenBrightnessErrorDomain
                                     code:-1
                                 userInfo:@{NSLocalizedDescriptionKey: @"No external DDC/CI backend is implemented yet"}];
    }
    return 0;
}

- (BOOL)setBrightness:(float)brightness forDisplay:(LumenDisplay *)display error:(NSError **)error {
    if (error) {
        *error = [NSError errorWithDomain:LumenBrightnessErrorDomain
                                     code:-1
                                 userInfo:@{NSLocalizedDescriptionKey: @"No external DDC/CI backend is implemented yet"}];
    }
    return NO;
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
        id<LumenBrightnessBackend> backend = [self backendForDisplay:display];
        display.brightnessControllable = backend != nil;
        display.brightnessBackendName = backend ? backend.name : @"unsupported";

        if (display.brightnessControllable) {
            [self.model ensureModelForDisplayKey:display.stableKey seedWithLegacyDefaults:display.builtin];
        } else {
            NSLog(@"Brightness unsupported for display '%@' key=%@ id=%u",
                  display.displayName,
                  display.stableKey,
                  display.displayID);
        }

        states[display.stableKey] = self.displayStatesByKey[display.stableKey] ?: [LumenDisplayState new];
        NSLog(@"Display '%@' key=%@ uses brightness backend %@",
              display.displayName,
              display.stableKey,
              display.brightnessBackendName);
    }
    self.activeDisplays = displays;
    self.displayStatesByKey = states;

    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.running || generation != self.displayConfigurationGeneration) {
                return;
            }
            if (error) {
                NSLog(@"Error getting shareable content: %@", error);
                return;
            }

            NSMutableDictionary<NSNumber *, SCDisplay *> *captureDisplaysByID = [NSMutableDictionary new];
            for (SCDisplay *captureDisplay in content.displays) {
                captureDisplaysByID[@(captureDisplay.displayID)] = captureDisplay;
            }

            for (LumenDisplay *display in self.activeDisplays) {
                SCDisplay *captureDisplay = captureDisplaysByID[@(display.displayID)];
                if (!captureDisplay) {
                    NSLog(@"Could not find ScreenCaptureKit display for '%@' key=%@ id=%u",
                          display.displayName,
                          display.stableKey,
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
        NSLog(@"Could not create capture stream for display '%@' key=%@", display.displayName, display.stableKey);
        return;
    }

    NSError *streamError = nil;
    [stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_get_main_queue() error:&streamError];
    if (streamError) {
        NSLog(@"Error adding stream output for display '%@' key=%@: %@",
              display.displayName,
              display.stableKey,
              streamError);
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
                NSLog(@"Error starting capture for display '%@' key=%@: %@", display.displayName, display.stableKey, error);
            } else {
                NSLog(@"Screen capture started for display '%@' key=%@", display.displayName, display.stableKey);
            }
        });
    }];
}

- (void)stopCaptureStreams {
    for (NSString *displayKey in self.streamsByDisplayKey) {
        SCStream *stream = self.streamsByDisplayKey[displayKey];
        [stream stopCaptureWithCompletionHandler:^(NSError *error) {
            if (error) {
                NSLog(@"Error stopping capture for display key %@: %@", displayKey, error);
            }
        }];
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

        float preferredBrightness = [self.ignoreList preferredBrightnessForURLString:activeAppURLString].floatValue;
        LumenDisplay *primaryDisplay = [self primaryControllableDisplay];
        if ([activeAppURLString isEqualToString:self.lastActiveAppURLString] && primaryDisplay) {
            NSError *brightnessError = nil;
            float currentBrightness = [self brightnessForDisplay:primaryDisplay error:&brightnessError];
            if (!brightnessError && fabs(currentBrightness - preferredBrightness) > CHANGE_NOTICE) {
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
                    NSLog(@"Ignored-app brightness restore failed for display '%@' key=%@: %@",
                          display.displayName,
                          display.stableKey,
                          setError.localizedDescription);
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
    if (!display.brightnessControllable) {
        return;
    }

    LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
    if (!state) {
        return;
    }

    NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];

    NSError *brightnessError = nil;
    float setPoint = [self brightnessForDisplay:display error:&brightnessError];
    if (brightnessError) {
        NSLog(@"Brightness read failed for display '%@' key=%@: %@",
              display.displayName,
              display.stableKey,
              brightnessError.localizedDescription);
        display.brightnessControllable = NO;
        display.brightnessBackendName = @"unsupported";
        return;
    }

    if (state.noticed || fabsf(state.lastSet - setPoint) > CHANGE_NOTICE) {
        if (!state.noticed) {
            state.noticed = YES;
            state.lastNoticed = setPoint;
            state.lastManualChangeTime = currentTime;
            return;
        }
        if (fabsf(setPoint - state.lastNoticed) > CHANGE_NOTICE) {
            state.lastNoticed = setPoint;
            state.lastManualChangeTime = currentTime;
            return;
        } else if (currentTime - state.lastManualChangeTime < DEBOUNCE_DELAY) {
            return;
        } else if (state.shouldIgnoreOutput) {
            state.shouldIgnoreOutput = NO;
        } else {
            [self.model observeOutput:setPoint forInput:lightness displayKey:display.stableKey];
            NSLog(@"Manual brightness override trained display '%@' key=%@ lightness=%.2f brightness=%.3f",
                  display.displayName,
                  display.stableKey,
                  lightness,
                  setPoint);
            state.noticed = NO;
        }
    }

    if (currentTime - state.lastAutoBrightnessTime < DEBOUNCE_DELAY) {
        return;
    }

    float brightness = [self.model predictFromInput:lightness displayKey:display.stableKey];
    if (brightness == state.lastAssigned) {
        return;
    }

    NSError *setError = nil;
    if ([self setBrightness:brightness forDisplay:display updateState:YES error:&setError]) {
        state.lastAssigned = brightness;
        state.lastAutoBrightnessTime = currentTime;
        NSLog(@"Set brightness for display '%@' key=%@ lightness=%.2f brightness=%.3f",
              display.displayName,
              display.stableKey,
              lightness,
              brightness);
    } else {
        NSLog(@"Brightness write failed for display '%@' key=%@: %@",
              display.displayName,
              display.stableKey,
              setError.localizedDescription);
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

    if (updateState) {
        LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
        NSError *readBackError = nil;
        float readBack = [backend brightnessForDisplay:display error:&readBackError];
        if (!readBackError) {
            state.lastSet = readBack;
        } else {
            state.lastSet = brightness;
        }
    }
    return YES;
}

- (NSArray<NSDictionary<NSString *, id> *> *)displayDebugStatuses {
    NSMutableArray<NSDictionary<NSString *, id> *> *statuses = [NSMutableArray new];
    for (LumenDisplay *display in self.activeDisplays) {
        NSError *brightnessError = nil;
        float brightness = display.brightnessControllable ? [self brightnessForDisplay:display error:&brightnessError] : 0;
        NSNumber *lightness = self.currentLightnessByDisplayKey[display.stableKey] ?: @(-1);
        [statuses addObject:@{@"name": display.displayName ?: @"",
                              @"key": display.stableKey ?: @"",
                              @"displayID": @(display.displayID),
                              @"builtin": @(display.builtin),
                              @"controllable": @(display.brightnessControllable && !brightnessError),
                              @"backend": display.brightnessBackendName ?: @"unsupported",
                              @"lightness": lightness,
                              @"brightness": brightnessError ? @(-1) : @(brightness),
                              @"learned": @([self.model hasLearnedDataForDisplayKey:display.stableKey])}];
    }
    return statuses;
}

- (id<LumenBrightnessBackend>)backendForDisplay:(LumenDisplay *)display {
    for (id<LumenBrightnessBackend> backend in self.brightnessBackends) {
        if ([backend canControlDisplay:display]) {
            return backend;
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
        return;
    }

    [(NSMutableDictionary *)self.currentLightnessByDisplayKey setObject:@(lightness) forKey:display.stableKey];
    NSLog(@"Lightness for display '%@' key=%@: %.2f", display.displayName, display.stableKey, lightness);

    if ([self checkIgnoreList]) {
        return;
    }

    [self processLightness:lightness forDisplay:display];
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    if (error) {
        NSLog(@"Stream stopped with error: %@", error);
    }
    NSString *displayKey = self.displayKeyByStream[[NSValue valueWithNonretainedObject:stream]];
    if (displayKey) {
        [self.streamsByDisplayKey removeObjectForKey:displayKey];
        [self.displayKeyByStream removeObjectForKey:[NSValue valueWithNonretainedObject:stream]];
    }
}

@end
