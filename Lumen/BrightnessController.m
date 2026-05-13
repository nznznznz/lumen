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
#import <os/log.h>

extern int DisplayServicesGetBrightness(CGDirectDisplayID display, float *brightness);
extern int DisplayServicesSetBrightness(CGDirectDisplayID display, float brightness);

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
- (void)setAction:(NSString *)action reason:(NSString *)reason display:(LumenDisplay *)display state:(LumenDisplayState *)state;
- (NSDictionary<NSString *, id> *)debugDictionaryForDisplay:(LumenDisplay *)display;
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
            [self setAction:@"skipped: unsupported" reason:@"skipped unsupported display" display:display state:state];
            [self addDebugEvent:@"brightness unsupported" display:display];
            os_log_info(LumenDebugLog(),
                        "Brightness unsupported display=%{public}@ key=%{public}@ id=%{public}u",
                        display.displayName,
                        [self shortDisplayKey:display.stableKey],
                        display.displayID);
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

    if (!display.brightnessControllable) {
        [self setAction:@"skipped: unsupported" reason:@"skipped unsupported display" display:display state:state];
        state.lastTrainingDecision = @"not trained: unsupported display";
        return;
    }

    NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];

    NSError *brightnessError = nil;
    float setPoint = [self brightnessForDisplay:display error:&brightnessError];
    if (brightnessError) {
        state.canReadBrightness = NO;
        state.lastReadError = brightnessError.localizedDescription ?: @"brightness read failed";
        [self setAction:@"skipped: unreadable" reason:@"skipped brightness unreadable" display:display state:state];
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
            [self setAction:@"skipped: debounce" reason:@"skipped manual override debounce" display:display state:state];
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
            [self setAction:@"skipped: debounce" reason:@"skipped manual override debounce" display:display state:state];
            return;
        } else if (currentTime - state.lastManualChangeTime < DEBOUNCE_DELAY) {
            state.lastTrainingDecision = @"pending: manual override debounce";
            [self setAction:@"skipped: debounce" reason:@"skipped manual override debounce" display:display state:state];
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

    float brightness = [self.model predictFromInput:lightness displayKey:display.stableKey];
    state.latestTargetBrightness = brightness;
    state.latestTargetTime = currentTime;

    if (currentTime - state.lastAutoBrightnessTime < DEBOUNCE_DELAY) {
        [self setAction:@"skipped: debounce" reason:@"skipped automatic debounce" display:display state:state];
        return;
    }

    if (brightness == state.lastAssigned) {
        [self setAction:@"unchanged" reason:@"unchanged within tolerance" display:display state:state];
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
        [self setAction:@"skipped: write failed" reason:@"skipped brightness write failed" display:display state:state];
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
