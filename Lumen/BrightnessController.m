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
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <os/log.h>
#import <os/signpost.h>

extern int DisplayServicesGetBrightness(CGDirectDisplayID display, float *brightness);
extern int DisplayServicesSetBrightness(CGDirectDisplayID display, float brightness);

typedef CFTypeRef IOAVService;
extern IOAVService IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVService service, uint32_t chipAddress, uint32_t offset, void *outputBuffer, uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVService service, uint32_t chipAddress, uint32_t dataAddress, void *inputBuffer, uint32_t inputBufferSize);
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display);
extern void CGSServiceForDisplayNumber(CGDirectDisplayID display, io_service_t *service);

static NSString * const LumenBrightnessErrorDomain = @"com.anishathalye.lumen.brightness";
static NSString * const LumenPerformanceSignpostsEnabledKey = @"performanceSignpostsEnabled";
static void *LumenControllerQueueKey = &LumenControllerQueueKey;
static NSUInteger const LumenMaxDebugEvents = 50;
static NSTimeInterval const LumenOwnWriteReadbackDebounce = 2.0;
static NSTimeInterval const LumenNoisyDebugEventInterval = 5.0;
static NSTimeInterval const LumenDebugSnapshotVisibleInterval = 1.0;
static NSTimeInterval const LumenDebugSnapshotLogInterval = 5.0;
static NSTimeInterval const LumenDDCMinimumCommandInterval = 0.35;
static NSTimeInterval const LumenDDCSlowCommandThreshold = 1.5;
static NSTimeInterval const LumenDDCDegradedCooldown = 5.0;
static float const LumenDDCSafeMinimumBrightness = 0.05f;
static float const LumenOverlayDefaultMaxAlpha = 0.70f;
static float const LumenMaximumDimmingLimit = 0.70f;
static float const LumenOverlayMinimumPerceivedBrightness = 0.30f;
static float const LumenOverlayDefaultDarkLStar = 25.0f;
static float const LumenOverlayDefaultBrightLStar = 90.0f;
static float const LumenOverlayDefaultDarkBrightness = 1.00f;
static float const LumenOverlayDefaultBrightBrightness = 0.55f;
static float const LumenOverlayManualStep = 0.05f;
static NSTimeInterval const LumenOverlayTransitionDuration = 0.18;
static NSString * const LumenOverlayAlphaAnimationKey = @"lumenOverlayAlpha";
static NSTimeInterval const LumenOverlayScreenshotHideDuration = 10.0;
static NSString * const LumenExternalSoftwareDimmingEnabledKey = @"externalSoftwareDimmingEnabled";
static NSTimeInterval const LumenActiveSampleInterval = 0.5;
static NSTimeInterval const LumenIdleSampleInterval = 1.0;
static NSTimeInterval const LumenStableSampleAfter = 4.0;
static NSTimeInterval const LumenForceControlInterval = 3.0;
static NSTimeInterval const LumenForcedHeavyAnalysisInterval = 8.0;
static double const LumenLightnessDeltaThreshold = 0.5;
static double const LumenCheapChangeThreshold = 0.03;
static float const LumenOverlayAlphaDeltaThreshold = 0.005f;
static double const LumenDefaultSamplingFPS = 12.0;
static double const LumenMinimumSamplingFPS = 0.2;
static double const LumenMaximumSamplingFPS = 16.0;
static double const LumenCaptureFPS = 16.0;
static NSUInteger const LumenCheapFingerprintGridWidth = 32;
static NSUInteger const LumenCheapFingerprintGridHeight = 18;
static NSUInteger const LumenLightnessSampleGridWidth = 80;
static NSUInteger const LumenLightnessSampleGridHeight = 45;

static os_log_t LumenDebugLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.anishathalye.lumen", "debug");
    });
    return log;
}

static os_log_t LumenPerformanceLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.anishathalye.lumen", "performance");
    });
    return log;
}

static BOOL LumenPerformanceSignpostsEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        enabled = [[NSUserDefaults standardUserDefaults] boolForKey:LumenPerformanceSignpostsEnabledKey];
    });
    return enabled;
}

@interface LumenOverlayPanel : NSPanel
@end

@implementation LumenOverlayPanel

- (BOOL)canBecomeKeyWindow {
    return NO;
}

- (BOOL)canBecomeMainWindow {
    return NO;
}

- (BOOL)acceptsFirstResponder {
    return NO;
}

@end

@protocol LumenBrightnessBackend <NSObject>

@property (nonatomic, copy, readonly) NSString *name;

- (BOOL)canControlDisplay:(LumenDisplay *)display;
- (float)brightnessForDisplay:(LumenDisplay *)display error:(NSError **)error;
- (BOOL)setBrightness:(float)brightness forDisplay:(LumenDisplay *)display error:(NSError **)error;

@optional
- (BOOL)canSetDisplay:(LumenDisplay *)display;
- (BOOL)canReadDisplay:(LumenDisplay *)display;
- (NSString *)failureReasonForDisplay:(LumenDisplay *)display;
- (NSDictionary<NSString *, id> *)debugInfoForDisplay:(LumenDisplay *)display;
- (BOOL)shouldReadBackAfterWrite;
- (BOOL)supportsManualBrightnessLearning;
- (void)synchronizeActiveDisplays:(NSArray<LumenDisplay *> *)displays;
- (void)shutdown;

@end

@interface DisplayServicesBrightnessBackend : NSObject <LumenBrightnessBackend>
@end

@interface LumenSoftwareOverlayState : NSObject

@property (nonatomic, assign) CGDirectDisplayID displayID;
@property (nonatomic, copy) NSString *displayKey;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, assign) CGRect frame;
@property (nonatomic, assign) float targetBrightness;
@property (nonatomic, assign) float desiredOverlayAlpha;
@property (nonatomic, assign) float appliedOverlayAlpha;
@property (nonatomic, assign) BOOL overlayEnabled;
@property (nonatomic, assign) BOOL temporarilyHiddenForScreenshot;
@property (nonatomic, assign) NSTimeInterval hiddenUntilTimestamp;
@property (nonatomic, copy) NSString *hiddenReason;
@property (nonatomic, assign) NSTimeInterval lastUpdateTime;
@property (nonatomic, assign) NSUInteger overlayUpdatesSkipped;
@property (nonatomic, assign) NSTimeInterval lastOverlayUpdateDuration;
@property (nonatomic, assign) NSTimeInterval lastOverlayTransitionDuration;
@property (nonatomic, assign) NSUInteger overlayTransitionAnimationCount;
@property (nonatomic, assign) NSUInteger overlayTransitionCancelledCount;
@property (nonatomic, assign) NSUInteger transitionGeneration;
@property (nonatomic, assign) BOOL overlayWindowVisible;
@property (nonatomic, assign) NSInteger overlayWindowLevel;
@property (nonatomic, strong) NSPanel *panel;

@end

@interface LumenPendingSample : NSObject

@property (nonatomic, strong) id sampleBufferObject;
@property (nonatomic, assign) NSTimeInterval arrivalTime;

@end

@implementation LumenPendingSample
@end

@interface SoftwareOverlayBrightnessBackend : NSObject <LumenBrightnessBackend>

@property (nonatomic, strong) NSMutableDictionary<NSString *, LumenSoftwareOverlayState *> *statesByDisplayKey;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) float maxOverlayAlpha;
@property (nonatomic, copy) void (^debugUpdateHandler)(void);

- (void)setEnabled:(BOOL)enabled;
- (void)temporarilyHideForScreenshot;
- (void)restoreOverlays;
- (void)setOverlayAlpha:(float)alpha forState:(LumenSoftwareOverlayState *)state final:(BOOL)final;

@end

@class LumenDDCMapping;

@interface ExternalDisplayBrightnessBackend : NSObject <LumenBrightnessBackend>

@property (nonatomic, strong) NSMutableDictionary<NSString *, LumenDDCMapping *> *mappingsByDisplayKey;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *failuresByDisplayKey;
@property (nonatomic, strong) dispatch_queue_t ddcQueue;
@property (nonatomic, copy) void (^debugUpdateHandler)(void);

- (BOOL)reserveDDCCommand:(NSString *)command mapping:(LumenDDCMapping *)mapping error:(NSError **)error;
- (void)finishDDCCommand:(NSString *)command mapping:(LumenDDCMapping *)mapping success:(BOOL)success error:(NSError *)commandError startedAt:(NSTimeInterval)startedAt;
- (void)notifyDebugStateChanged;

@end

@interface LumenDDCMapping : NSObject

@property (nonatomic, assign) BOOL arm64;
@property (nonatomic, assign) IOAVService avService;
@property (nonatomic, assign) io_service_t framebuffer;
@property (nonatomic, assign) IOOptionBits replyTransactionType;
@property (nonatomic, assign) UInt16 maxBrightness;
@property (nonatomic, copy) NSString *failureReason;
@property (nonatomic, copy) NSString *backendState;
@property (nonatomic, assign) NSTimeInterval lastCommandTime;
@property (nonatomic, assign) BOOL commandInFlight;
@property (nonatomic, assign) BOOL rateLimited;
@property (nonatomic, assign) NSUInteger skippedInFlightCount;
@property (nonatomic, assign) NSUInteger skippedRateLimitCount;
@property (nonatomic, assign) NSTimeInterval degradedUntil;
@property (nonatomic, copy) NSString *degradedReason;
@property (nonatomic, assign) NSTimeInterval lastReadAttemptTimestamp;
@property (nonatomic, assign) NSTimeInterval lastReadSuccessTimestamp;
@property (nonatomic, assign) NSTimeInterval lastReadDuration;
@property (nonatomic, copy) NSString *lastReadError;
@property (nonatomic, assign) NSUInteger consecutiveReadFailures;
@property (nonatomic, assign) NSTimeInterval lastWriteAttemptTimestamp;
@property (nonatomic, assign) NSTimeInterval lastWriteSuccessTimestamp;
@property (nonatomic, assign) NSTimeInterval lastWriteDuration;
@property (nonatomic, copy) NSString *lastWriteError;
@property (nonatomic, assign) NSUInteger consecutiveWriteFailures;
@property (nonatomic, assign) float lastRequestedBrightness;
@property (nonatomic, assign) float lastAppliedBrightness;
@property (nonatomic, assign) BOOL clampApplied;

@end

@interface LumenDisplayState : NSObject

@property (nonatomic, assign) float lastSet;
@property (nonatomic, assign) BOOL hasValidBrightnessBaseline;
@property (nonatomic, assign) float brightnessBaseline;
@property (nonatomic, assign) NSTimeInterval brightnessBaselineTime;
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
@property (nonatomic, assign) NSTimeInterval lastDecisionTime;
@property (nonatomic, copy) NSString *lastLearnEvent;
@property (nonatomic, assign) NSTimeInterval lastLearnTime;
@property (nonatomic, assign) float lastManualOverrideOldBrightness;
@property (nonatomic, assign) float lastManualOverrideNewBrightness;
@property (nonatomic, assign) float lastManualOverrideDelta;
@property (nonatomic, copy) NSString *lastTrainingDecision;
@property (nonatomic, assign) BOOL seededFromLegacyModel;
@property (nonatomic, assign) NSTimeInterval lastBaselineEventTime;
@property (nonatomic, assign) NSTimeInterval lastIgnoredManualEventTime;
@property (nonatomic, assign) NSUInteger droppedSampleCount;
@property (nonatomic, assign) NSUInteger captureCallbackCount;
@property (nonatomic, assign) NSUInteger acceptedSampleCount;
@property (nonatomic, assign) NSTimeInterval lastCaptureCallbackTimestamp;
@property (nonatomic, assign) NSTimeInterval lastAcceptedSampleTimestamp;
@property (nonatomic, assign) NSTimeInterval captureRateWindowStart;
@property (nonatomic, assign) NSUInteger captureRateWindowCount;
@property (nonatomic, assign) NSTimeInterval acceptedRateWindowStart;
@property (nonatomic, assign) NSUInteger acceptedRateWindowCount;
@property (nonatomic, assign) double captureRate;
@property (nonatomic, assign) double acceptedSampleRate;
@property (nonatomic, assign) NSTimeInterval lastLightnessComputeDuration;
@property (nonatomic, assign) NSTimeInterval lastHeavyAnalysisDuration;
@property (nonatomic, assign) NSTimeInterval lastCheapFingerprintDuration;
@property (nonatomic, assign) NSTimeInterval lastSampleProcessingDuration;
@property (nonatomic, assign) NSTimeInterval lastControllerQueueWaitDuration;
@property (nonatomic, assign) NSTimeInterval lastFullControlTime;
@property (nonatomic, assign) NSTimeInterval lastHeavyAnalysisTime;
@property (nonatomic, assign) NSTimeInterval lightnessStableSince;
@property (nonatomic, assign) double lastCheapChangeDelta;
@property (nonatomic, assign) NSUInteger coalescedFrameCount;
@property (nonatomic, assign) NSUInteger heavyAnalysisSkippedCount;
@property (nonatomic, copy) NSString *lastSkippedEventSignature;
@property (nonatomic, assign) NSTimeInterval lastSkippedEventTime;
@property (nonatomic, assign) NSUInteger skippedEventRepeatCount;
@property (nonatomic, copy) NSString *cachedLearnedPointsSummary;
@property (nonatomic, assign) NSTimeInterval cachedLearnedPointsSummaryTime;

@end

@implementation LumenDisplayState

- (instancetype)init {
    self = [super init];
    if (self) {
        self.lastSet = -1; // force initial observation, preserving old single-display behavior
        self.hasValidBrightnessBaseline = NO;
        self.brightnessBaseline = -1;
        self.brightnessBaselineTime = 0;
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
        self.lastDecisionTime = 0;
        self.lastLearnEvent = @"none";
        self.lastLearnTime = 0;
        self.lastManualOverrideOldBrightness = -1;
        self.lastManualOverrideNewBrightness = -1;
        self.lastManualOverrideDelta = 0;
        self.lastTrainingDecision = @"none";
        self.seededFromLegacyModel = NO;
        self.lastBaselineEventTime = 0;
        self.lastIgnoredManualEventTime = 0;
        self.droppedSampleCount = 0;
        self.captureCallbackCount = 0;
        self.acceptedSampleCount = 0;
        self.lastCaptureCallbackTimestamp = 0;
        self.lastAcceptedSampleTimestamp = 0;
        self.captureRateWindowStart = 0;
        self.captureRateWindowCount = 0;
        self.acceptedRateWindowStart = 0;
        self.acceptedRateWindowCount = 0;
        self.captureRate = 0;
        self.acceptedSampleRate = 0;
        self.lastLightnessComputeDuration = 0;
        self.lastHeavyAnalysisDuration = 0;
        self.lastCheapFingerprintDuration = 0;
        self.lastSampleProcessingDuration = 0;
        self.lastControllerQueueWaitDuration = 0;
        self.lastFullControlTime = 0;
        self.lastHeavyAnalysisTime = 0;
        self.lightnessStableSince = 0;
        self.lastCheapChangeDelta = 0;
        self.coalescedFrameCount = 0;
        self.heavyAnalysisSkippedCount = 0;
        self.lastSkippedEventSignature = @"";
        self.lastSkippedEventTime = 0;
        self.skippedEventRepeatCount = 0;
        self.cachedLearnedPointsSummary = @"";
        self.cachedLearnedPointsSummaryTime = 0;
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
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *lastAcceptedSampleTimeByDisplayKey;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *lastHeavyAnalysisTimeByDisplayKey;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *lastCheapFingerprintTimeByDisplayKey;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *deferredDroppedSampleCountsByDisplayKey;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *targetSampleIntervalByDisplayKey;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *cheapFingerprintByDisplayKey;
@property (nonatomic, strong) NSMutableDictionary<NSString *, LumenPendingSample *> *pendingSamplesByDisplayKey;
@property (nonatomic, strong) NSMutableArray<NSDictionary<NSString *, id> *> *debugEvents;
@property (nonatomic, strong) NSArray<id<LumenBrightnessBackend>> *brightnessBackends;
@property (nonatomic, strong) SoftwareOverlayBrightnessBackend *softwareOverlayBackend;
@property (nonatomic, strong) ExternalDisplayBrightnessBackend *ddcBackend;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *> *overlayCalibrationPointsByDisplayKey;
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
@property (nonatomic, strong) dispatch_queue_t controllerQueue;
@property (nonatomic, strong) dispatch_queue_t sampleQueue;
@property (nonatomic, strong) dispatch_queue_t snapshotQueue;
@property (nonatomic, strong) NSMutableSet<NSString *> *processingSampleDisplayKeys;
@property (nonatomic, strong) NSDictionary<NSString *, id> *latestDebugSnapshot;
@property (nonatomic, assign) NSUInteger debugSnapshotVersion;
@property (nonatomic, assign) NSUInteger debugSnapshotRequestCount;
@property (nonatomic, assign) NSUInteger debugSnapshotSkippedCount;
@property (nonatomic, assign) NSTimeInterval lastDebugSnapshotUpdateTime;
@property (nonatomic, assign) NSTimeInterval lastDebugSnapshotLogTime;
@property (nonatomic, assign) BOOL debugSnapshotDirty;
@property (nonatomic, assign) NSTimeInterval lastControlLoopDuration;
@property (nonatomic, assign) NSTimeInterval snapshotGenerationDuration;
@property (nonatomic, assign) NSTimeInterval debugPanelLastRenderDuration;
@property (nonatomic, assign) double configuredSamplingFPS;
@property (nonatomic, assign) BOOL adaptiveSampling;
@property (atomic, assign) float maximumDimming;

- (void)reloadDisplaysAndStreams;
- (void)stopCaptureStreams;
- (void)processLightness:(double)lightness forDisplay:(LumenDisplay *)display;
- (void)updateDebugSnapshot;
- (void)updateDebugSnapshotForced:(BOOL)force;
- (void)updateDebugSnapshotAfterSample;
- (NSArray<SCRunningApplication *> *)applicationsToExcludeFromCaptureContent:(SCShareableContent *)content;
- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer displayKey:(NSString *)displayKey arrivedAt:(NSTimeInterval)sampleArrivedAt processingReserved:(BOOL)processingReserved;
- (void)handleIncomingSampleBuffer:(CMSampleBufferRef)sampleBuffer displayKey:(NSString *)displayKey arrivedAt:(NSTimeInterval)sampleArrivedAt;
- (void)finishProcessingSampleForDisplayKey:(NSString *)displayKey;
- (BOOL)reserveSampleProcessingForDisplayKey:(NSString *)displayKey sampleBuffer:(CMSampleBufferRef)sampleBuffer arrivedAt:(NSTimeInterval)sampleArrivedAt;
- (NSTimeInterval)minimumAnalysisIntervalForDisplayKey:(NSString *)displayKey;
- (void)recordDeferredDroppedSampleForDisplayKey:(NSString *)displayKey;
- (void)drainDeferredDroppedSamplesForDisplayKey:(NSString *)displayKey state:(LumenDisplayState *)state atTime:(NSTimeInterval)time;
- (NSData *)cheapFingerprintFromSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (double)cheapDeltaFromFingerprint:(NSData *)fingerprint previousFingerprint:(NSData *)previousFingerprint;
- (double)computeLightnessFromSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)recordCaptureCallbackForState:(LumenDisplayState *)state atTime:(NSTimeInterval)time dropped:(BOOL)dropped;
- (void)recordAcceptedSampleForState:(LumenDisplayState *)state atTime:(NSTimeInterval)time;
- (void)addDebugEvent:(NSString *)event display:(LumenDisplay *)display;
- (void)addSkippedDecisionEventForDisplay:(LumenDisplay *)display
                                    state:(LumenDisplayState *)state
                                lightness:(double)lightness
                                   target:(float)target
                        currentBrightness:(float)currentBrightness
                                   reason:(NSString *)reason;
- (void)initialiseBrightnessBaseline:(float)brightness display:(LumenDisplay *)display state:(LumenDisplayState *)state time:(NSTimeInterval)time;
- (void)markManualOverrideIgnored:(NSString *)decision display:(LumenDisplay *)display state:(LumenDisplayState *)state time:(NSTimeInterval)time;
- (BOOL)isOwnWriteReadback:(float)brightness state:(LumenDisplayState *)state time:(NSTimeInterval)time;
- (void)setAction:(NSString *)action reason:(NSString *)reason display:(LumenDisplay *)display state:(LumenDisplayState *)state;
- (NSDictionary<NSString *, id> *)debugDictionaryForDisplay:(LumenDisplay *)display;
- (NSString *)brightnessFailureReasonForDisplay:(LumenDisplay *)display;
- (BOOL)supportsManualBrightnessLearningForDisplay:(LumenDisplay *)display;
- (BOOL)isSoftwareOverlayDisplay:(LumenDisplay *)display;
- (float)brightnessByApplyingMaximumDimming:(float)brightness;
- (float)overlayTargetBrightnessForLightness:(float)lightness displayKey:(NSString *)displayKey;
- (void)observeOverlayOutput:(float)output forInput:(float)input displayKey:(NSString *)displayKey;
- (void)restoreOverlayCalibrationDefaults;
- (void)synchronizeOverlayCalibrationDefaults;
- (NSString *)overlayLearnedPointsSummaryForDisplayKey:(NSString *)displayKey;
- (NSString *)shortDisplayKey:(NSString *)stableKey;
- (NSString *)roleForDisplay:(LumenDisplay *)display;
- (NSString *)formattedTime:(NSTimeInterval)timestamp;

@end

static void LumenDisplayReconfigurationCallback(CGDirectDisplayID display,
                                                CGDisplayChangeSummaryFlags flags,
                                                void *userInfo) {
    BrightnessController *controller = (__bridge BrightnessController *)userInfo;
    dispatch_async(controller.controllerQueue, ^{
        os_log_info(LumenDebugLog(), "Display reconfiguration display=%{public}u flags=%{public}u", display, flags);
        [controller reloadDisplaysAndStreams];
    });
}

@implementation LumenDDCMapping

- (instancetype)init {
    self = [super init];
    if (self) {
        self.maxBrightness = 100;
        self.failureReason = @"";
        self.backendState = @"DDC-CI set-only";
        self.lastCommandTime = 0;
        self.commandInFlight = NO;
        self.rateLimited = NO;
        self.skippedInFlightCount = 0;
        self.skippedRateLimitCount = 0;
        self.degradedUntil = 0;
        self.degradedReason = @"";
        self.lastReadAttemptTimestamp = 0;
        self.lastReadSuccessTimestamp = 0;
        self.lastReadDuration = 0;
        self.lastReadError = @"";
        self.consecutiveReadFailures = 0;
        self.lastWriteAttemptTimestamp = 0;
        self.lastWriteSuccessTimestamp = 0;
        self.lastWriteDuration = 0;
        self.lastWriteError = @"";
        self.consecutiveWriteFailures = 0;
        self.lastRequestedBrightness = -1;
        self.lastAppliedBrightness = -1;
        self.clampApplied = NO;
    }
    return self;
}

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

static float LumenClampFloat(float value, float minimum, float maximum) {
    return MIN(maximum, MAX(minimum, value));
}

static double LumenClampDouble(double value, double minimum, double maximum) {
    return MIN(maximum, MAX(minimum, value));
}

static float LumenClampMaximumDimming(float maximumDimming) {
    return LumenClampFloat(maximumDimming, 0.0f, LumenMaximumDimmingLimit);
}

static float LumenMinimumBrightnessForMaximumDimming(float maximumDimming) {
    return 1.0f - LumenClampMaximumDimming(maximumDimming);
}

static float LumenOverlayAlphaForBrightness(float brightness, float maxOverlayAlpha) {
    float safeTarget = LumenClampFloat(brightness, LumenMinimumBrightnessForMaximumDimming(maxOverlayAlpha), 1.0f);
    return LumenClampFloat(1.0f - safeTarget, 0.0f, LumenClampMaximumDimming(maxOverlayAlpha));
}

static float LumenOverlayPointValue(NSDictionary<NSString *, NSNumber *> *point, NSString *key) {
    NSNumber *value = point[key];
    return [value isKindOfClass:[NSNumber class]] ? value.floatValue : 0.0f;
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
    if (!display.builtin) {
        return NO;
    }
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

@implementation LumenSoftwareOverlayState
@end

@implementation SoftwareOverlayBrightnessBackend

- (instancetype)init {
    self = [super init];
    if (self) {
        self.statesByDisplayKey = [NSMutableDictionary new];
        self.enabled = [[NSUserDefaults standardUserDefaults] objectForKey:LumenExternalSoftwareDimmingEnabledKey] ? [[NSUserDefaults standardUserDefaults] boolForKey:LumenExternalSoftwareDimmingEnabledKey] : YES;
        NSNumber *savedMaximumDimming = [[NSUserDefaults standardUserDefaults] objectForKey:DEFAULTS_MAXIMUM_DIMMING];
        self.maxOverlayAlpha = savedMaximumDimming ? LumenClampMaximumDimming(savedMaximumDimming.floatValue) : LumenOverlayDefaultMaxAlpha;
    }
    return self;
}

- (NSString *)name {
    return @"Software Overlay";
}

- (void)setMaxOverlayAlpha:(float)maxOverlayAlpha {
    float clamped = LumenClampMaximumDimming(maxOverlayAlpha);
    NSArray<LumenSoftwareOverlayState *> *states = nil;
    @synchronized (self) {
        if (fabsf(_maxOverlayAlpha - clamped) < 0.0005f) {
            _maxOverlayAlpha = clamped;
            return;
        }
        _maxOverlayAlpha = clamped;
        states = self.statesByDisplayKey.allValues;
        for (LumenSoftwareOverlayState *state in states) {
            state.desiredOverlayAlpha = LumenOverlayAlphaForBrightness(state.targetBrightness, _maxOverlayAlpha);
        }
    }
    for (LumenSoftwareOverlayState *state in states) {
        [self applyOverlayState:state remove:NO];
    }
    [self notifyDebugStateChanged];
}

- (BOOL)canControlDisplay:(LumenDisplay *)display {
    return self.enabled && !display.builtin;
}

- (BOOL)canSetDisplay:(LumenDisplay *)display {
    return [self canControlDisplay:display];
}

- (BOOL)canReadDisplay:(LumenDisplay *)display {
    return [self canControlDisplay:display];
}

- (BOOL)supportsManualBrightnessLearning {
    return NO;
}

- (BOOL)shouldReadBackAfterWrite {
    return NO;
}

- (float)brightnessForDisplay:(LumenDisplay *)display error:(NSError **)error {
    if (![self canControlDisplay:display]) {
        if (error) {
            *error = LumenBrightnessError(-50, self.enabled ? @"software overlay unsupported for built-in display" : @"external software dimming disabled");
        }
        return NAN;
    }

    @synchronized (self) {
        LumenSoftwareOverlayState *state = [self stateForDisplayLocked:display create:YES];
        return 1.0f - state.desiredOverlayAlpha;
    }
}

- (BOOL)setBrightness:(float)brightness forDisplay:(LumenDisplay *)display error:(NSError **)error {
    if (![self canControlDisplay:display]) {
        if (error) {
            *error = LumenBrightnessError(-51, self.enabled ? @"software overlay unsupported for built-in display" : @"external software dimming disabled");
        }
        return NO;
    }

    float overlayAlpha = LumenOverlayAlphaForBrightness(brightness, self.maxOverlayAlpha);
    __block LumenSoftwareOverlayState *state = nil;
    @synchronized (self) {
        state = [self stateForDisplayLocked:display create:YES];
        state.displayID = display.displayID;
        state.displayKey = display.stableKey ?: @"";
        state.displayName = display.displayName ?: @"";
        state.targetBrightness = brightness;
        if (fabsf(state.desiredOverlayAlpha - overlayAlpha) < LumenOverlayAlphaDeltaThreshold &&
            !state.temporarilyHiddenForScreenshot &&
            CGRectEqualToRect(state.frame, display.bounds)) {
            state.overlayUpdatesSkipped++;
            state.overlayEnabled = self.enabled;
            state.lastUpdateTime = [NSDate timeIntervalSinceReferenceDate];
            return YES;
        }
        state.frame = display.bounds;
        state.desiredOverlayAlpha = overlayAlpha;
        state.overlayEnabled = self.enabled;
        state.lastUpdateTime = [NSDate timeIntervalSinceReferenceDate];
    }

    [self applyOverlayState:state remove:NO];
    return YES;
}

- (NSString *)failureReasonForDisplay:(LumenDisplay *)display {
    if (display.builtin) {
        return nil;
    }
    return self.enabled ? nil : @"external software dimming disabled";
}

- (NSDictionary<NSString *, id> *)debugInfoForDisplay:(LumenDisplay *)display {
    if (display.builtin) {
        return @{};
    }

    @synchronized (self) {
        LumenSoftwareOverlayState *state = self.statesByDisplayKey[display.stableKey];
        float desiredAlpha = state ? state.desiredOverlayAlpha : 0.0f;
        float appliedAlpha = state ? state.appliedOverlayAlpha : 0.0f;
        float target = state ? state.targetBrightness : 1.0f;
        BOOL temporarilyHidden = state && state.temporarilyHiddenForScreenshot;
        NSString *hiddenReason = state.hiddenReason.length > 0 ? state.hiddenReason : @"";
        NSTimeInterval hiddenUntil = state ? state.hiddenUntilTimestamp : 0;
        NSString *hiddenUntilText = hiddenUntil > 0 ? [NSString stringWithFormat:@"%.0fs remaining", MAX(0.0, hiddenUntil - [NSDate timeIntervalSinceReferenceDate])] : @"";
        return @{@"controlMethod": self.enabled ? @"Software Overlay" : @"Software Overlay Disabled",
                 @"backendState": self.enabled ? @"software overlay active" : @"software overlay disabled",
                 @"overlayEnabled": @(self.enabled),
                 @"overlayAlpha": @(appliedAlpha),
                 @"overlayDesiredAlpha": @(desiredAlpha),
                 @"overlayAppliedAlpha": @(appliedAlpha),
                 @"overlayMaxAlpha": @(self.maxOverlayAlpha),
                 @"overlayTargetBrightness": @(target),
                 @"overlayTemporarilyHidden": @(temporarilyHidden),
                 @"overlayHiddenReason": hiddenReason,
                 @"overlayHiddenUntil": hiddenUntilText,
                 @"manualLearningAvailable": @"overlay controls only",
                 @"overlayIncludedInCapture": @"own Lumen app excluded; NSWindowSharingNone set",
                 @"screenshotHiddenState": temporarilyHidden ? @"hidden for screenshot" : @"normal",
                 @"screenshotSafeMode": temporarilyHidden ? @"hidden" : @"armed",
                 @"overlayWindowSharingType": @"NSWindowSharingNone",
                 @"overlayIgnoresMouseEvents": @YES,
                 @"overlayCanBecomeKey": @NO,
                 @"overlayCanBecomeMain": @NO,
                 @"overlayWindowVisible": @(state ? state.overlayWindowVisible : NO),
                 @"overlayWindowLevel": @(state ? state.overlayWindowLevel : 0),
                 @"overlayUpdatesSkipped": @(state ? state.overlayUpdatesSkipped : 0),
                 @"lastOverlayUpdateDuration": @(state ? state.lastOverlayUpdateDuration : 0),
                 @"lastOverlayTransitionDuration": @(state ? state.lastOverlayTransitionDuration : 0),
                 @"overlayTransitionAnimationCount": @(state ? state.overlayTransitionAnimationCount : 0),
                 @"overlayTransitionCancelledCount": @(state ? state.overlayTransitionCancelledCount : 0),
                 @"hardwareBrightness": @"unreadable"};
    }
}

- (void)synchronizeActiveDisplays:(NSArray<LumenDisplay *> *)displays {
    NSMutableSet<NSString *> *activeExternalKeys = [NSMutableSet new];
    for (LumenDisplay *display in displays) {
        if (display.builtin) {
            continue;
        }
        [activeExternalKeys addObject:display.stableKey];
        @synchronized (self) {
            LumenSoftwareOverlayState *state = [self stateForDisplayLocked:display create:YES];
            state.displayID = display.displayID;
            state.displayKey = display.stableKey ?: @"";
            state.displayName = display.displayName ?: @"";
            state.frame = display.bounds;
        }
    }

    NSMutableArray<LumenSoftwareOverlayState *> *removedStates = [NSMutableArray new];
    NSMutableArray<LumenSoftwareOverlayState *> *updatedStates = [NSMutableArray new];
    @synchronized (self) {
        for (NSString *displayKey in self.statesByDisplayKey.allKeys) {
            LumenSoftwareOverlayState *state = self.statesByDisplayKey[displayKey];
            if (![activeExternalKeys containsObject:displayKey]) {
                [removedStates addObject:state];
                [self.statesByDisplayKey removeObjectForKey:displayKey];
            } else {
                [updatedStates addObject:state];
            }
        }
    }

    for (LumenSoftwareOverlayState *state in removedStates) {
        [self applyOverlayState:state remove:YES];
    }
    for (LumenSoftwareOverlayState *state in updatedStates) {
        [self applyOverlayState:state remove:NO];
    }
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:LumenExternalSoftwareDimmingEnabledKey];

    NSArray<LumenSoftwareOverlayState *> *states = nil;
    @synchronized (self) {
        states = self.statesByDisplayKey.allValues;
        for (LumenSoftwareOverlayState *state in states) {
            state.overlayEnabled = enabled;
            if (!enabled) {
                state.appliedOverlayAlpha = 0.0f;
            }
        }
    }
    for (LumenSoftwareOverlayState *state in states) {
        [self applyOverlayState:state remove:!enabled];
    }
    [self notifyDebugStateChanged];
}

- (void)temporarilyHideForScreenshot {
    NSTimeInterval hiddenUntil = [NSDate timeIntervalSinceReferenceDate] + LumenOverlayScreenshotHideDuration;
    NSArray<LumenSoftwareOverlayState *> *states = nil;
    @synchronized (self) {
        states = self.statesByDisplayKey.allValues;
        for (LumenSoftwareOverlayState *state in states) {
            state.temporarilyHiddenForScreenshot = YES;
            state.hiddenUntilTimestamp = hiddenUntil;
            state.hiddenReason = @"hidden for screenshot";
            state.appliedOverlayAlpha = 0.0f;
        }
    }
    for (LumenSoftwareOverlayState *state in states) {
        [self applyOverlayState:state remove:NO];
    }
    [self notifyDebugStateChanged];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LumenOverlayScreenshotHideDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        NSArray<LumenSoftwareOverlayState *> *restoreStates = nil;
        @synchronized (self) {
            restoreStates = self.statesByDisplayKey.allValues;
            for (LumenSoftwareOverlayState *state in restoreStates) {
                if (state.temporarilyHiddenForScreenshot && state.hiddenUntilTimestamp <= now) {
                    state.temporarilyHiddenForScreenshot = NO;
                    state.hiddenUntilTimestamp = 0;
                    state.hiddenReason = @"";
                }
            }
        }
        for (LumenSoftwareOverlayState *state in restoreStates) {
            [self applyOverlayState:state remove:NO];
        }
        [self notifyDebugStateChanged];
    });
}

- (void)restoreOverlays {
    NSArray<LumenSoftwareOverlayState *> *states = nil;
    @synchronized (self) {
        states = self.statesByDisplayKey.allValues;
        for (LumenSoftwareOverlayState *state in states) {
            state.temporarilyHiddenForScreenshot = NO;
            state.hiddenUntilTimestamp = 0;
            state.hiddenReason = @"";
        }
    }
    for (LumenSoftwareOverlayState *state in states) {
        [self applyOverlayState:state remove:NO];
    }
    [self notifyDebugStateChanged];
}

- (void)shutdown {
    NSArray<LumenSoftwareOverlayState *> *states = nil;
    @synchronized (self) {
        states = self.statesByDisplayKey.allValues;
        [self.statesByDisplayKey removeAllObjects];
    }
    for (LumenSoftwareOverlayState *state in states) {
        [self applyOverlayState:state remove:YES];
    }
}

- (LumenSoftwareOverlayState *)stateForDisplayLocked:(LumenDisplay *)display create:(BOOL)create {
    LumenSoftwareOverlayState *state = self.statesByDisplayKey[display.stableKey];
    if (!state && create) {
        state = [LumenSoftwareOverlayState new];
        state.displayID = display.displayID;
        state.displayKey = display.stableKey ?: @"";
        state.displayName = display.displayName ?: @"";
        state.frame = display.bounds;
        state.targetBrightness = 1.0f;
        state.desiredOverlayAlpha = 0.0f;
        state.appliedOverlayAlpha = 0.0f;
        state.overlayEnabled = self.enabled;
        state.temporarilyHiddenForScreenshot = NO;
        state.hiddenUntilTimestamp = 0;
        state.hiddenReason = @"";
        state.overlayUpdatesSkipped = 0;
        state.lastOverlayUpdateDuration = 0;
        state.lastOverlayTransitionDuration = 0;
        state.overlayTransitionAnimationCount = 0;
        state.overlayTransitionCancelledCount = 0;
        state.transitionGeneration = 0;
        state.overlayWindowVisible = NO;
        state.overlayWindowLevel = 0;
        self.statesByDisplayKey[display.stableKey] = state;
    }
    return state;
}

- (void)applyOverlayState:(LumenSoftwareOverlayState *)state remove:(BOOL)remove {
    if (!state) {
        return;
    }

    void (^updateWindow)(void) = ^{
        NSTimeInterval startedAt = [NSDate timeIntervalSinceReferenceDate];
        BOOL signpostsEnabled = LumenPerformanceSignpostsEnabled();
        os_signpost_id_t signpostID = OS_SIGNPOST_ID_INVALID;
        if (signpostsEnabled) {
            signpostID = os_signpost_id_generate(LumenPerformanceLog());
            os_signpost_interval_begin(LumenPerformanceLog(), signpostID, "Overlay Update", "display=%{public}@", state.displayName ?: state.displayKey);
        }
        BOOL hidden = state.temporarilyHiddenForScreenshot;
        state.overlayEnabled = self.enabled;
        float targetAlpha = (self.enabled && !hidden && !remove) ? state.desiredOverlayAlpha : 0.0f;

        if (remove || !self.enabled || hidden) {
            state.transitionGeneration++;
            if ([state.panel.contentView.layer animationForKey:LumenOverlayAlphaAnimationKey]) {
                state.overlayTransitionCancelledCount++;
            }
            [state.panel.contentView.layer removeAnimationForKey:LumenOverlayAlphaAnimationKey];
            [self setOverlayAlpha:0.0f forState:state final:YES];
            [state.panel orderOut:nil];
            state.overlayWindowVisible = NO;
            state.overlayWindowLevel = state.panel.level;
            if (remove) {
                [state.panel close];
                state.panel = nil;
            }
            state.lastOverlayUpdateDuration = [NSDate timeIntervalSinceReferenceDate] - startedAt;
            if (signpostsEnabled) {
                os_signpost_interval_end(LumenPerformanceLog(), signpostID, "Overlay Update", "duration=%{public}.6f", state.lastOverlayUpdateDuration);
            }
            return;
        }

        if (!state.panel) {
            LumenOverlayPanel *panel = [[LumenOverlayPanel alloc] initWithContentRect:NSRectFromCGRect(state.frame)
                                                                            styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel)
                                                                              backing:NSBackingStoreBuffered
                                                                                defer:NO];
            panel.opaque = NO;
            panel.backgroundColor = [NSColor clearColor];
            panel.ignoresMouseEvents = YES;
            panel.hidesOnDeactivate = NO;
            panel.releasedWhenClosed = NO;
            panel.hasShadow = NO;
            panel.sharingType = NSWindowSharingNone;
            panel.excludedFromWindowsMenu = YES;
            panel.level = CGWindowLevelForKey(kCGOverlayWindowLevelKey);
            panel.collectionBehavior = (NSWindowCollectionBehaviorCanJoinAllSpaces |
                                        NSWindowCollectionBehaviorStationary |
                                        NSWindowCollectionBehaviorFullScreenAuxiliary |
                                        NSWindowCollectionBehaviorIgnoresCycle);
            [panel setAccessibilityElement:NO];

            NSView *contentView = [[NSView alloc] initWithFrame:NSRectFromCGRect(state.frame)];
            contentView.wantsLayer = YES;
            [contentView setAccessibilityElement:NO];
            panel.contentView = contentView;
            state.panel = panel;
        }

        if (!CGRectEqualToRect(NSRectToCGRect(state.panel.frame), state.frame)) {
            [state.panel setFrame:NSRectFromCGRect(state.frame) display:NO];
            state.panel.contentView.frame = NSMakeRect(0, 0, state.frame.size.width, state.frame.size.height);
        }
        state.overlayWindowLevel = state.panel.level;

        CALayer *presentationLayer = state.panel.contentView.layer.presentationLayer;
        if (presentationLayer.backgroundColor) {
            state.appliedOverlayAlpha = (float)CGColorGetAlpha(presentationLayer.backgroundColor);
        }
        CALayer *overlayLayer = state.panel.contentView.layer;
        if ([overlayLayer animationForKey:LumenOverlayAlphaAnimationKey]) {
            state.overlayTransitionCancelledCount++;
        }
        [overlayLayer removeAnimationForKey:LumenOverlayAlphaAnimationKey];

        if (state.appliedOverlayAlpha <= 0.001f && targetAlpha <= 0.001f) {
            [self setOverlayAlpha:0.0f forState:state final:YES];
            state.lastOverlayUpdateDuration = [NSDate timeIntervalSinceReferenceDate] - startedAt;
            if (signpostsEnabled) {
                os_signpost_interval_end(LumenPerformanceLog(), signpostID, "Overlay Update", "duration=%{public}.6f", state.lastOverlayUpdateDuration);
            }
            return;
        }

        float startAlpha = state.appliedOverlayAlpha;
        float delta = targetAlpha - startAlpha;
        if (fabsf(delta) <= LumenOverlayAlphaDeltaThreshold) {
            [self setOverlayAlpha:targetAlpha forState:state final:YES];
            state.lastOverlayUpdateDuration = [NSDate timeIntervalSinceReferenceDate] - startedAt;
            if (signpostsEnabled) {
                os_signpost_interval_end(LumenPerformanceLog(), signpostID, "Overlay Update", "duration=%{public}.6f", state.lastOverlayUpdateDuration);
            }
            return;
        }

        NSUInteger generation = ++state.transitionGeneration;
        float clampedTargetAlpha = LumenClampFloat(targetAlpha, 0.0f, self.maxOverlayAlpha);
        state.overlayTransitionAnimationCount++;
        state.lastOverlayTransitionDuration = LumenOverlayTransitionDuration;
        state.appliedOverlayAlpha = clampedTargetAlpha;

        if (clampedTargetAlpha > 0.001f && !state.panel.visible) {
            [state.panel orderFrontRegardless];
            state.overlayWindowVisible = state.panel.visible;
            state.overlayWindowLevel = state.panel.level;
        }

        NSColor *startColor = [NSColor colorWithCalibratedWhite:0.0 alpha:LumenClampFloat(startAlpha, 0.0f, self.maxOverlayAlpha)];
        NSColor *targetColor = [NSColor colorWithCalibratedWhite:0.0 alpha:clampedTargetAlpha];

        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        overlayLayer.backgroundColor = targetColor.CGColor;
        [CATransaction commit];

        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"backgroundColor"];
        animation.fromValue = (__bridge id)startColor.CGColor;
        animation.toValue = (__bridge id)targetColor.CGColor;
        animation.duration = LumenOverlayTransitionDuration;
        animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        animation.removedOnCompletion = YES;
        [overlayLayer addAnimation:animation forKey:LumenOverlayAlphaAnimationKey];

        if (clampedTargetAlpha <= 0.001f) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LumenOverlayTransitionDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (state.transitionGeneration != generation || state.appliedOverlayAlpha > 0.001f) {
                    return;
                }
                [state.panel orderOut:nil];
                state.overlayWindowVisible = NO;
                state.overlayWindowLevel = state.panel.level;
            });
        }
        state.lastOverlayUpdateDuration = [NSDate timeIntervalSinceReferenceDate] - startedAt;
        if (signpostsEnabled) {
            os_signpost_interval_end(LumenPerformanceLog(), signpostID, "Overlay Update", "duration=%{public}.6f", state.lastOverlayUpdateDuration);
        }
    };

    if ([NSThread isMainThread]) {
        updateWindow();
    } else {
        dispatch_async(dispatch_get_main_queue(), updateWindow);
    }
}

- (void)setOverlayAlpha:(float)alpha forState:(LumenSoftwareOverlayState *)state final:(BOOL)final {
    float clampedAlpha = LumenClampFloat(alpha, 0.0f, self.maxOverlayAlpha);
    state.appliedOverlayAlpha = clampedAlpha;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    state.panel.contentView.layer.backgroundColor = [[NSColor colorWithCalibratedWhite:0.0 alpha:clampedAlpha] CGColor];
    [CATransaction commit];
    if (clampedAlpha <= 0.001f) {
        if (final) {
            [state.panel orderOut:nil];
            state.overlayWindowVisible = NO;
        }
    } else {
        if (!state.panel.visible) {
            [state.panel orderFrontRegardless];
        }
        state.overlayWindowVisible = state.panel.visible;
        state.overlayWindowLevel = state.panel.level;
    }
}

- (void)notifyDebugStateChanged {
    if (self.debugUpdateHandler) {
        self.debugUpdateHandler();
    }
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
        self.ddcQueue = dispatch_queue_create("com.anishathalye.lumen.ddc", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (NSString *)name {
    return @"DDC-CI";
}

- (BOOL)canControlDisplay:(LumenDisplay *)display {
    return [self canSetDisplay:display];
}

- (BOOL)canSetDisplay:(LumenDisplay *)display {
    if (display.builtin) {
        return NO;
    }

    NSError *error = nil;
    LumenDDCMapping *mapping = [self mappingForDisplay:display error:&error];
    if (!mapping) {
        @synchronized (self) {
            self.failuresByDisplayKey[display.stableKey] = error.localizedDescription ?: @"no DDC/CI service found";
        }
        return NO;
    }

    @synchronized (self) {
        self.failuresByDisplayKey[display.stableKey] = @"";
    }
    return YES;
}

- (BOOL)canReadDisplay:(LumenDisplay *)display {
    LumenDDCMapping *mapping = nil;
    @synchronized (self) {
        mapping = self.mappingsByDisplayKey[display.stableKey];
    }
    @synchronized (mapping) {
        return mapping && mapping.lastReadSuccessTimestamp > 0;
    }
}

- (float)brightnessForDisplay:(LumenDisplay *)display error:(NSError **)error {
    LumenDDCMapping *mapping = [self mappingForDisplay:display error:error];
    if (!mapping) {
        return NAN;
    }

    if (error) {
        *error = LumenBrightnessError(-30, @"DDC/CI brightness read unavailable without blocking");
    }
    return NAN;
}

- (BOOL)setBrightness:(float)brightness forDisplay:(LumenDisplay *)display error:(NSError **)error {
    LumenDDCMapping *mapping = [self mappingForDisplay:display error:error];
    if (!mapping) {
        return NO;
    }

    float appliedBrightness = MIN(1.0f, MAX(LumenDDCSafeMinimumBrightness, brightness));
    UInt16 maximum = 100;
    @synchronized (mapping) {
        mapping.lastRequestedBrightness = brightness;
        mapping.clampApplied = fabsf(appliedBrightness - brightness) > FLT_EPSILON;
        maximum = mapping.maxBrightness > 0 ? mapping.maxBrightness : 100;
    }
    UInt16 value = (UInt16)lroundf(appliedBrightness * (float)maximum);
    if (![self writeBrightness:value mapping:mapping error:error]) {
        return NO;
    }
    @synchronized (mapping) {
        mapping.lastAppliedBrightness = appliedBrightness;
    }
    return YES;
}

- (NSString *)failureReasonForDisplay:(LumenDisplay *)display {
    NSString *reason = nil;
    @synchronized (self) {
        reason = self.failuresByDisplayKey[display.stableKey];
    }
    return reason.length > 0 ? reason : nil;
}

- (BOOL)shouldReadBackAfterWrite {
    return NO;
}

- (NSDictionary<NSString *, id> *)debugInfoForDisplay:(LumenDisplay *)display {
    LumenDDCMapping *mapping = nil;
    NSString *failure = nil;
    @synchronized (self) {
        mapping = self.mappingsByDisplayKey[display.stableKey];
        failure = self.failuresByDisplayKey[display.stableKey] ?: @"";
    }
    if (!mapping) {
        return @{@"backendState": failure.length > 0 ? [NSString stringWithFormat:@"unsupported: %@", failure] : @"unsupported",
                 @"ddcCanReadBrightness": @NO,
                 @"ddcCanSetBrightness": @NO,
                 @"ddcCommandInFlight": @NO,
                 @"ddcRateLimited": @NO,
                 @"ddcSkippedInFlightCount": @0,
                 @"ddcSkippedRateLimitCount": @0,
                 @"ddcLastReadDuration": @0,
                 @"ddcLastWriteDuration": @0,
                 @"ddcConsecutiveReadFailures": @0,
                 @"ddcConsecutiveWriteFailures": @0,
                 @"ddcLastReadError": failure,
                 @"ddcLastWriteError": @""};
    }

    @synchronized (mapping) {
        return @{@"backendState": mapping.backendState ?: @"DDC-CI",
                 @"ddcCanReadBrightness": @(mapping.lastReadSuccessTimestamp > 0),
                 @"ddcCanSetBrightness": @YES,
                 @"ddcLastReadAttemptTimestamp": @(mapping.lastReadAttemptTimestamp),
                 @"ddcLastReadSuccessTimestamp": @(mapping.lastReadSuccessTimestamp),
                 @"ddcLastReadDuration": @(mapping.lastReadDuration),
                 @"ddcLastReadError": mapping.lastReadError ?: @"",
                 @"ddcLastWriteAttemptTimestamp": @(mapping.lastWriteAttemptTimestamp),
                 @"ddcLastWriteSuccessTimestamp": @(mapping.lastWriteSuccessTimestamp),
                 @"ddcLastWriteDuration": @(mapping.lastWriteDuration),
                 @"ddcLastWriteError": mapping.lastWriteError ?: @"",
                 @"ddcConsecutiveReadFailures": @(mapping.consecutiveReadFailures),
                 @"ddcConsecutiveWriteFailures": @(mapping.consecutiveWriteFailures),
                 @"ddcCommandInFlight": @(mapping.commandInFlight),
                 @"ddcRateLimited": @(mapping.rateLimited),
                 @"ddcSkippedInFlightCount": @(mapping.skippedInFlightCount),
                 @"ddcSkippedRateLimitCount": @(mapping.skippedRateLimitCount),
                 @"ddcDegradedUntil": @(mapping.degradedUntil),
                 @"ddcDegradedReason": mapping.degradedReason ?: @"",
                 @"ddcLastRequestedBrightness": @(mapping.lastRequestedBrightness),
                 @"ddcLastAppliedBrightness": @(mapping.lastAppliedBrightness),
                 @"ddcClampApplied": @(mapping.clampApplied)};
    }
}

- (LumenDDCMapping *)mappingForDisplay:(LumenDisplay *)display error:(NSError **)error {
    @synchronized (self) {
        LumenDDCMapping *cached = self.mappingsByDisplayKey[display.stableKey];
        if (cached) {
            return cached;
        }
    }

    LumenDDCMapping *mapping = LumenIsArm64() ? [self armMappingForDisplay:display error:error] : [self intelMappingForDisplay:display error:error];
    if (mapping) {
        @synchronized (self) {
            self.mappingsByDisplayKey[display.stableKey] = mapping;
        }
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
    if (![self reserveDDCCommand:@"read" mapping:mapping error:error]) {
        [self notifyDebugStateChanged];
        return NO;
    }

    dispatch_async(self.ddcQueue, ^{
        NSTimeInterval startedAt = [NSDate timeIntervalSinceReferenceDate];
        os_log_debug(LumenDebugLog(), "DDC read start");
        UInt16 readCurrent = 0;
        UInt16 readMaximum = 0;
        NSError *readError = nil;
        BOOL success = mapping.arm64 ? [self armReadCommand:LumenDDCVCPBrightness current:&readCurrent maximum:&readMaximum mapping:mapping error:&readError] : [self intelReadCommand:LumenDDCVCPBrightness current:&readCurrent maximum:&readMaximum mapping:mapping error:&readError];
        @synchronized (mapping) {
            if (success) {
                mapping.maxBrightness = readMaximum > 0 ? readMaximum : 100;
                mapping.lastAppliedBrightness = MIN(1.0f, MAX(0.0f, (float)readCurrent / (float)mapping.maxBrightness));
            }
        }
        [self finishDDCCommand:@"read" mapping:mapping success:success error:readError startedAt:startedAt];
    });
    return YES;
}

- (BOOL)writeBrightness:(UInt16)value mapping:(LumenDDCMapping *)mapping error:(NSError **)error {
    if (![self reserveDDCCommand:@"write" mapping:mapping error:error]) {
        [self notifyDebugStateChanged];
        return NO;
    }

    dispatch_async(self.ddcQueue, ^{
        NSTimeInterval startedAt = [NSDate timeIntervalSinceReferenceDate];
        os_log_debug(LumenDebugLog(), "DDC write start");
        NSError *writeError = nil;
        BOOL success = mapping.arm64 ? [self armWriteCommand:LumenDDCVCPBrightness value:value mapping:mapping error:&writeError] : [self intelWriteCommand:LumenDDCVCPBrightness value:value mapping:mapping error:&writeError];
        [self finishDDCCommand:@"write" mapping:mapping success:success error:writeError startedAt:startedAt];
    });
    return YES;
}

- (BOOL)reserveDDCCommand:(NSString *)command mapping:(LumenDDCMapping *)mapping error:(NSError **)error {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    @synchronized (mapping) {
        if ([command isEqualToString:@"write"] && mapping.degradedUntil > now) {
            mapping.lastWriteError = mapping.degradedReason.length > 0 ? mapping.degradedReason : @"DDC-CI backend degraded";
            mapping.backendState = @"DDC-CI degraded";
            if (error) {
                *error = LumenBrightnessError(-34, mapping.lastWriteError);
            }
            return NO;
        }

        if (mapping.commandInFlight) {
            mapping.skippedInFlightCount++;
            NSString *message = @"skipped: DDC command in flight";
            if ([command isEqualToString:@"read"]) {
                mapping.lastReadError = message;
            } else {
                mapping.lastWriteError = message;
            }
            mapping.backendState = message;
            if (error) {
                *error = LumenBrightnessError(-35, message);
            }
            return NO;
        }

        NSTimeInterval elapsed = now - mapping.lastCommandTime;
        mapping.rateLimited = elapsed > 0 && elapsed < LumenDDCMinimumCommandInterval;
        if (mapping.rateLimited) {
            mapping.skippedRateLimitCount++;
            NSString *message = @"skipped: DDC command rate limited";
            if ([command isEqualToString:@"read"]) {
                mapping.lastReadError = message;
            } else {
                mapping.lastWriteError = message;
            }
            mapping.backendState = message;
            if (error) {
                *error = LumenBrightnessError(-36, message);
            }
            return NO;
        }

        mapping.commandInFlight = YES;
        mapping.rateLimited = NO;
        if ([command isEqualToString:@"read"]) {
            mapping.lastReadAttemptTimestamp = now;
        } else {
            mapping.lastWriteAttemptTimestamp = now;
        }
        return YES;
    }
}

- (void)finishDDCCommand:(NSString *)command mapping:(LumenDDCMapping *)mapping success:(BOOL)success error:(NSError *)commandError startedAt:(NSTimeInterval)startedAt {
    NSTimeInterval finishedAt = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval duration = finishedAt - startedAt;
    @synchronized (mapping) {
        mapping.commandInFlight = NO;
        mapping.lastCommandTime = finishedAt;
        if ([command isEqualToString:@"read"]) {
            mapping.lastReadDuration = duration;
            if (success) {
                mapping.lastReadSuccessTimestamp = finishedAt;
                mapping.lastReadError = @"";
                mapping.consecutiveReadFailures = 0;
                mapping.backendState = duration > LumenDDCSlowCommandThreshold ? @"DDC-CI read/write slow" : @"DDC-CI read/write";
            } else {
                mapping.lastReadError = commandError.localizedDescription ?: @"DDC/CI brightness read failed";
                mapping.consecutiveReadFailures++;
                mapping.backendState = @"DDC-CI set-only";
            }
        } else {
            mapping.lastWriteDuration = duration;
            if (success) {
                mapping.lastWriteSuccessTimestamp = finishedAt;
                mapping.lastWriteError = @"";
                mapping.consecutiveWriteFailures = 0;
                mapping.backendState = duration > LumenDDCSlowCommandThreshold ? @"DDC-CI set-only slow" : @"DDC-CI set-only";
            } else {
                mapping.lastWriteError = commandError.localizedDescription ?: @"DDC/CI brightness write failed";
                mapping.consecutiveWriteFailures++;
                mapping.backendState = @"DDC-CI transient failure";
            }
        }

        if (duration > LumenDDCSlowCommandThreshold || (!success && [command isEqualToString:@"write"])) {
            mapping.degradedUntil = finishedAt + LumenDDCDegradedCooldown;
            mapping.degradedReason = [NSString stringWithFormat:@"DDC-CI %@ %@ (%.3fs)",
                                      command,
                                      success ? @"slow" : @"failed",
                                      duration];
            mapping.backendState = @"DDC-CI degraded";
        }
    }

    os_log_debug(LumenDebugLog(),
                 "DDC %{public}@ end success=%{public}@ duration=%{public}.3f",
                 command,
                 success ? @"YES" : @"NO",
                 duration);
    [self notifyDebugStateChanged];
}

- (void)notifyDebugStateChanged {
    if (self.debugUpdateHandler) {
        self.debugUpdateHandler();
    }
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

@synthesize maximumDimming = _maximumDimming;

- (id)init {
    self = [super init];
    if (self) {
        self.activeDisplays = @[];
        self.currentLightnessByDisplayKey = [NSMutableDictionary new];
        self.streamsByDisplayKey = [NSMutableDictionary new];
        self.displayKeyByStream = [NSMutableDictionary new];
        self.displayStatesByKey = [NSMutableDictionary new];
        self.lastAcceptedSampleTimeByDisplayKey = [NSMutableDictionary new];
        self.lastHeavyAnalysisTimeByDisplayKey = [NSMutableDictionary new];
        self.lastCheapFingerprintTimeByDisplayKey = [NSMutableDictionary new];
        self.deferredDroppedSampleCountsByDisplayKey = [NSMutableDictionary new];
        self.targetSampleIntervalByDisplayKey = [NSMutableDictionary new];
        self.cheapFingerprintByDisplayKey = [NSMutableDictionary new];
        self.pendingSamplesByDisplayKey = [NSMutableDictionary new];
        self.debugEvents = [NSMutableArray new];
        self.controllerQueue = dispatch_queue_create("com.anishathalye.lumen.controller", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(self.controllerQueue, LumenControllerQueueKey, LumenControllerQueueKey, NULL);
        self.sampleQueue = dispatch_queue_create("com.anishathalye.lumen.samples", DISPATCH_QUEUE_CONCURRENT);
        self.snapshotQueue = dispatch_queue_create("com.anishathalye.lumen.snapshot", DISPATCH_QUEUE_CONCURRENT);
        self.processingSampleDisplayKeys = [NSMutableSet new];
        self.debugSnapshotRequestCount = 0;
        self.debugSnapshotSkippedCount = 0;
        self.lastDebugSnapshotUpdateTime = 0;
        self.lastDebugSnapshotLogTime = 0;
        self.debugSnapshotDirty = YES;
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        double savedFPS = [defaults doubleForKey:DEFAULTS_SAMPLING_FPS];
        if ([defaults objectForKey:DEFAULTS_SAMPLING_PRESETS_MIGRATED] == nil && savedFPS > 0) {
            if (fabs(savedFPS - 0.5) < 0.01) {
                savedFPS = 4.0;
            } else if (fabs(savedFPS - 1.0) < 0.01) {
                savedFPS = 8.0;
            } else if (fabs(savedFPS - 2.0) < 0.01 || fabs(savedFPS - 4.0) < 0.01) {
                savedFPS = 12.0;
            }
            [defaults setDouble:savedFPS forKey:DEFAULTS_SAMPLING_FPS];
            [defaults setBool:YES forKey:DEFAULTS_SAMPLING_PRESETS_MIGRATED];
        }
        self.configuredSamplingFPS = savedFPS > 0 ? LumenClampDouble(savedFPS, LumenMinimumSamplingFPS, LumenMaximumSamplingFPS) : LumenDefaultSamplingFPS;
        NSNumber *savedMaximumDimming = [defaults objectForKey:DEFAULTS_MAXIMUM_DIMMING];
        _maximumDimming = savedMaximumDimming ? LumenClampMaximumDimming(savedMaximumDimming.floatValue) : LumenOverlayDefaultMaxAlpha;
        if ([defaults objectForKey:DEFAULTS_ADAPTIVE_SAMPLING_ENABLED] == nil) {
            self.adaptiveSampling = YES;
            [defaults setBool:YES forKey:DEFAULTS_ADAPTIVE_SAMPLING_ENABLED];
        } else {
            self.adaptiveSampling = [defaults boolForKey:DEFAULTS_ADAPTIVE_SAMPLING_ENABLED];
        }
        self.latestDebugSnapshot = @{@"running": @NO,
                                     @"version": @0,
                                     @"generatedAt": @([NSDate timeIntervalSinceReferenceDate]),
                                     @"displays": @[],
                                     @"events": @[]};
        SoftwareOverlayBrightnessBackend *softwareOverlayBackend = [SoftwareOverlayBrightnessBackend new];
        ExternalDisplayBrightnessBackend *ddcBackend = [ExternalDisplayBrightnessBackend new];
        __weak typeof(self) weakSelf = self;
        softwareOverlayBackend.debugUpdateHandler = ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            dispatch_async(strongSelf.controllerQueue, ^{
                [strongSelf updateDebugSnapshot];
            });
        };
        ddcBackend.debugUpdateHandler = ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            dispatch_async(strongSelf.controllerQueue, ^{
                [strongSelf updateDebugSnapshot];
            });
        };
        self.softwareOverlayBackend = softwareOverlayBackend;
        self.softwareOverlayBackend.maxOverlayAlpha = self.maximumDimming;
        self.ddcBackend = ddcBackend;
        self.brightnessBackends = @[[DisplayServicesBrightnessBackend new],
                                    softwareOverlayBackend,
                                    ddcBackend];
        self.overlayCalibrationPointsByDisplayKey = [NSMutableDictionary new];
        [self restoreOverlayCalibrationDefaults];
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

- (double)samplingFPS {
    return self.configuredSamplingFPS > 0 ? self.configuredSamplingFPS : LumenDefaultSamplingFPS;
}

- (void)setSamplingFPS:(double)fps {
    double clamped = LumenClampDouble(fps, LumenMinimumSamplingFPS, LumenMaximumSamplingFPS);
    self.configuredSamplingFPS = clamped;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[NSUserDefaults standardUserDefaults] setDouble:clamped forKey:DEFAULTS_SAMPLING_FPS];
    });
    @synchronized (self.lastAcceptedSampleTimeByDisplayKey) {
        [self.targetSampleIntervalByDisplayKey removeAllObjects];
    }
    dispatch_async(self.controllerQueue, ^{
        [self updateDebugSnapshot];
    });
}

- (NSString *)samplingModeName {
    double fps = [self samplingFPS];
    if (fabs(fps - 4.0) < 0.01) {
        return @"Low";
    }
    if (fabs(fps - 8.0) < 0.01) {
        return @"Medium";
    }
    if (fabs(fps - 12.0) < 0.01) {
        return @"High";
    }
    if (fabs(fps - 16.0) < 0.01) {
        return @"Ultra";
    }
    return @"Custom";
}

- (BOOL)adaptiveSamplingEnabled {
    return self.adaptiveSampling;
}

- (void)setAdaptiveSamplingEnabled:(BOOL)enabled {
    self.adaptiveSampling = enabled;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:DEFAULTS_ADAPTIVE_SAMPLING_ENABLED];
    });
    @synchronized (self.lastAcceptedSampleTimeByDisplayKey) {
        [self.targetSampleIntervalByDisplayKey removeAllObjects];
    }
    dispatch_async(self.controllerQueue, ^{
        [self updateDebugSnapshot];
    });
}

- (float)maximumDimming {
    float maximumDimming = _maximumDimming;
    return LumenClampMaximumDimming(maximumDimming);
}

- (float)maximumDimmingLimit {
    return LumenMaximumDimmingLimit;
}

- (void)setMaximumDimming:(float)maximumDimming {
    float clamped = LumenClampMaximumDimming(maximumDimming);
    _maximumDimming = clamped;
    self.softwareOverlayBackend.maxOverlayAlpha = clamped;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[NSUserDefaults standardUserDefaults] setFloat:clamped forKey:DEFAULTS_MAXIMUM_DIMMING];
    });
    dispatch_async(self.controllerQueue, ^{
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        for (LumenDisplay *display in self.activeDisplays) {
            LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
            if (!state || !display.brightnessControllable) {
                continue;
            }
            float sourceTarget = state.latestTargetBrightness;
            if (state.latestLightness > 0) {
                sourceTarget = [self isSoftwareOverlayDisplay:display] ? [self overlayTargetBrightnessForLightness:(float)state.latestLightness displayKey:display.stableKey] : [self.model predictFromInput:state.latestLightness displayKey:display.stableKey];
            }
            if (sourceTarget < 0) {
                continue;
            }
            float cappedTarget = [self brightnessByApplyingMaximumDimming:sourceTarget];
            if (state.lastAssigned >= 0 && fabsf(cappedTarget - state.lastAssigned) <= CHANGE_NOTICE) {
                continue;
            }
            NSError *error = nil;
            if ([self setBrightness:cappedTarget forDisplay:display updateState:!([self isSoftwareOverlayDisplay:display]) error:&error]) {
                state.latestTargetBrightness = cappedTarget;
                state.latestTargetTime = now;
                state.lastAssigned = cappedTarget;
                state.lastAutoBrightnessTime = now;
                state.lastWriteError = @"";
                [self setAction:[NSString stringWithFormat:@"maximum dimming %.0f%%", clamped * 100.0f]
                         reason:@"maximum dimming changed"
                        display:display
                          state:state];
            } else {
                state.lastWriteError = error.localizedDescription ?: @"maximum dimming apply failed";
            }
        }
        [self updateDebugSnapshot];
    });
}

- (void)start {
    [self stop];
    self.running = YES;
    if (!self.displayCallbackRegistered) {
        CGDisplayRegisterReconfigurationCallback(LumenDisplayReconfigurationCallback, (__bridge void *)self);
        self.displayCallbackRegistered = YES;
    }
    dispatch_async(self.controllerQueue, ^{
        [self reloadDisplaysAndStreams];
    });
}

- (void)stop {
    self.running = NO;
    if (self.displayCallbackRegistered) {
        CGDisplayRemoveReconfigurationCallback(LumenDisplayReconfigurationCallback, (__bridge void *)self);
        self.displayCallbackRegistered = NO;
    }
    [self.softwareOverlayBackend shutdown];
    dispatch_async(self.controllerQueue, ^{
        [self stopCaptureStreams];
        for (id<LumenBrightnessBackend> backend in self.brightnessBackends) {
            if ([backend respondsToSelector:@selector(shutdown)]) {
                [backend shutdown];
            }
        }
        [self updateDebugSnapshot];
    });
}

- (void)reloadDisplaysAndStreams {
    if (!self.running) {
        return;
    }

    self.displayConfigurationGeneration++;
    NSUInteger generation = self.displayConfigurationGeneration;
    [self stopCaptureStreams];

    NSArray<LumenDisplay *> *displays = [LumenDisplay activeDisplays];
    for (id<LumenBrightnessBackend> backend in self.brightnessBackends) {
        if ([backend respondsToSelector:@selector(synchronizeActiveDisplays:)]) {
            [backend synchronizeActiveDisplays:displays];
        }
    }
    NSMutableDictionary<NSString *, LumenDisplayState *> *states = [NSMutableDictionary new];
    for (LumenDisplay *display in displays) {
        LumenDisplayState *state = self.displayStatesByKey[display.stableKey] ?: [LumenDisplayState new];
        id<LumenBrightnessBackend> backend = [self backendForDisplay:display];
        display.brightnessControllable = backend != nil;
        display.brightnessBackendName = backend ? backend.name : @"unsupported";
        if (!backend && !display.builtin && !self.softwareOverlayBackend.enabled) {
            display.brightnessBackendName = @"Software Overlay Disabled";
        }
        state.canReadBrightness = backend != nil && (![backend respondsToSelector:@selector(canReadDisplay:)] || [backend canReadDisplay:display]);
        state.canSetBrightness = backend != nil && (![backend respondsToSelector:@selector(canSetDisplay:)] || [backend canSetDisplay:display]);
        state.hasValidBrightnessBaseline = NO;
        state.noticed = NO;

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
    [self updateDebugSnapshot];

    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(self.controllerQueue, ^{
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
                [self updateDebugSnapshot];
                return;
            }

            NSMutableDictionary<NSNumber *, SCDisplay *> *captureDisplaysByID = [NSMutableDictionary new];
            for (SCDisplay *captureDisplay in content.displays) {
                captureDisplaysByID[@(captureDisplay.displayID)] = captureDisplay;
            }
            NSArray<SCRunningApplication *> *excludedApplications = [self applicationsToExcludeFromCaptureContent:content];

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
                [self startCaptureForDisplay:display captureDisplay:captureDisplay excludedApplications:excludedApplications generation:generation];
            }
            [self updateDebugSnapshot];
        });
    }];
}

- (NSArray<SCRunningApplication *> *)applicationsToExcludeFromCaptureContent:(SCShareableContent *)content {
    NSString *bundleIdentifier = [NSBundle mainBundle].bundleIdentifier;
    if (bundleIdentifier.length == 0) {
        return @[];
    }

    NSMutableArray<SCRunningApplication *> *excludedApplications = [NSMutableArray new];
    for (SCRunningApplication *application in content.applications) {
        if ([application.bundleIdentifier isEqualToString:bundleIdentifier]) {
            [excludedApplications addObject:application];
        }
    }
    if (excludedApplications.count > 0) {
        os_log_info(LumenDebugLog(), "Excluding Lumen application from screen capture");
    }
    return excludedApplications.copy;
}

- (void)startCaptureForDisplay:(LumenDisplay *)display
                captureDisplay:(SCDisplay *)captureDisplay
           excludedApplications:(NSArray<SCRunningApplication *> *)excludedApplications
                     generation:(NSUInteger)generation {
    SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
    config.width = MAX(1, captureDisplay.width / LINEAR_SUBSAMPLE);
    config.height = MAX(1, captureDisplay.height / LINEAR_SUBSAMPLE);
    double captureFPS = LumenClampDouble([self samplingFPS], LumenMinimumSamplingFPS, LumenCaptureFPS);
    config.minimumFrameInterval = CMTimeMakeWithSeconds(1.0 / captureFPS, 600);
    config.pixelFormat = kCVPixelFormatType_32BGRA;
    config.showsCursor = NO;
    config.capturesAudio = NO;

    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:captureDisplay
                                                 excludingApplications:excludedApplications ?: @[]
                                                      exceptingWindows:@[]];
    SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
    if (!stream) {
        LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
        state.captureStatus = @"stream creation failed";
        [self setAction:@"skipped: no capture" reason:@"skipped no screen capture permission" display:display state:state];
        [self addDebugEvent:@"capture stream creation failed" display:display];
        return;
    }

    NSError *streamError = nil;
    [stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.sampleQueue error:&streamError];
    if (streamError) {
        LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
        state.captureStatus = @"stream output failed";
        [self setAction:@"skipped: no capture" reason:@"skipped no screen capture permission" display:display state:state];
        [self addDebugEvent:[NSString stringWithFormat:@"capture output failed: %@", streamError.localizedDescription] display:display];
        return;
    }

    NSValue *streamKey = [NSValue valueWithNonretainedObject:stream];
    self.streamsByDisplayKey[display.stableKey] = stream;
    @synchronized (self.displayKeyByStream) {
        self.displayKeyByStream[streamKey] = display.stableKey;
    }

    [stream startCaptureWithCompletionHandler:^(NSError *error) {
        dispatch_async(self.controllerQueue, ^{
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
            [self updateDebugSnapshot];
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
    @synchronized (self.displayKeyByStream) {
        [self.displayKeyByStream removeAllObjects];
    }
    @synchronized (self.lastAcceptedSampleTimeByDisplayKey) {
        [self.lastAcceptedSampleTimeByDisplayKey removeAllObjects];
        [self.lastHeavyAnalysisTimeByDisplayKey removeAllObjects];
        [self.lastCheapFingerprintTimeByDisplayKey removeAllObjects];
        [self.deferredDroppedSampleCountsByDisplayKey removeAllObjects];
        [self.targetSampleIntervalByDisplayKey removeAllObjects];
        [self.cheapFingerprintByDisplayKey removeAllObjects];
    }
    @synchronized (self.pendingSamplesByDisplayKey) {
        [self.pendingSamplesByDisplayKey removeAllObjects];
    }
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
            if ([self isSoftwareOverlayDisplay:display]) {
                NSError *setError = nil;
                if ([self setBrightness:1.0f forDisplay:display updateState:NO error:&setError]) {
                    NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
                    state.latestTargetBrightness = 1.0f;
                    state.latestTargetTime = currentTime;
                    state.latestBrightness = 1.0f;
                    state.latestBrightnessTime = currentTime;
                    state.lastAssigned = 1.0f;
                    state.lastAutoBrightnessTime = currentTime;
                    state.lastWriteError = @"";
                    [self setAction:@"overlay cleared" reason:@"ignored app frontmost" display:display state:state];
                } else {
                    state.lastWriteError = setError.localizedDescription ?: @"ignored-app overlay clear failed";
                    [self addDebugEvent:[NSString stringWithFormat:@"ignored-app overlay clear failed: %@", state.lastWriteError] display:display];
                }
            }
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
                if ([self isSoftwareOverlayDisplay:display]) {
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
    float predictedBrightness = [self isSoftwareOverlayDisplay:display] ? [self overlayTargetBrightnessForLightness:(float)lightness displayKey:display.stableKey] : [self.model predictFromInput:lightness displayKey:display.stableKey];
    float brightness = [self brightnessByApplyingMaximumDimming:predictedBrightness];
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

    if (lightness <= 0) {
        state.lastTrainingDecision = @"not trained: no sample";
        [self setAction:@"skipped: no sample" reason:@"no current sample" display:display state:state];
        [self addSkippedDecisionEventForDisplay:display
                                          state:state
                                      lightness:lightness
                                         target:brightness
                              currentBrightness:state.latestBrightness
                                         reason:@"no sample"];
        return;
    }

    NSError *brightnessError = nil;
    float setPoint = [self brightnessForDisplay:display error:&brightnessError];
    if (brightnessError) {
        state.canReadBrightness = NO;
        state.hasValidBrightnessBaseline = NO;
        state.noticed = NO;
        state.lastReadError = brightnessError.localizedDescription ?: @"brightness read failed";
        state.latestBrightness = -1;
        state.latestBrightnessTime = 0;
        state.lastTrainingDecision = @"not trained: brightness unreadable";
        [self addDebugEvent:[NSString stringWithFormat:@"brightness read failed: %@", state.lastReadError] display:display];
        os_log_error(LumenDebugLog(),
                     "Brightness read failed display=%{public}@ key=%{public}@ error=%{public}@",
                     display.displayName,
                     [self shortDisplayKey:display.stableKey],
                     state.lastReadError);

        if (currentTime - state.lastAutoBrightnessTime < DEBOUNCE_DELAY) {
            [self setAction:@"skipped: debounce" reason:@"brightness read unavailable" display:display state:state];
            [self addSkippedDecisionEventForDisplay:display
                                              state:state
                                          lightness:lightness
                                             target:brightness
                                  currentBrightness:-1
                                             reason:@"debounce"];
            return;
        }
        if (state.lastAssigned >= 0 && fabsf(brightness - state.lastAssigned) <= CHANGE_NOTICE) {
            [self setAction:@"skipped: unchanged" reason:@"brightness read unavailable" display:display state:state];
            return;
        }

        NSError *setOnlyError = nil;
        if ([self setBrightness:brightness forDisplay:display updateState:NO error:&setOnlyError]) {
            state.canSetBrightness = YES;
            state.lastWriteError = @"";
            state.lastWrittenBrightness = brightness;
            state.lastWriteTime = currentTime;
            state.lastAssigned = brightness;
            state.lastAutoBrightnessTime = currentTime;
            [self setAction:[NSString stringWithFormat:@"set-only write %.3f", brightness] reason:@"brightness read unavailable" display:display state:state];
            [self addDebugEvent:[NSString stringWithFormat:@"set-only brightness write %.3f; read unavailable", brightness] display:display];
        } else {
            state.canSetBrightness = YES;
            state.lastWriteError = setOnlyError.localizedDescription ?: @"brightness write failed";
            [self setAction:@"skipped: write failed" reason:@"write failed" display:display state:state];
            [self addSkippedDecisionEventForDisplay:display
                                              state:state
                                          lightness:lightness
                                             target:brightness
                                  currentBrightness:-1
                                             reason:@"write failed"];
        }
        return;
    }
    state.canReadBrightness = YES;
    state.lastReadError = @"";
    state.latestBrightness = setPoint;
    state.latestBrightnessTime = currentTime;

    if (![self supportsManualBrightnessLearningForDisplay:display]) {
        state.hasValidBrightnessBaseline = NO;
        state.noticed = NO;
        state.lastTrainingDecision = @"not trained: use overlay Learn Current";

        if (state.lastAssigned >= 0 && fabsf(brightness - state.lastAssigned) <= CHANGE_NOTICE) {
            [self setAction:@"skipped: unchanged" reason:@"overlay unchanged within tolerance" display:display state:state];
            return;
        }

        NSError *setError = nil;
        if ([self setBrightness:brightness forDisplay:display updateState:NO error:&setError]) {
            float overlayAlpha = LumenOverlayAlphaForBrightness(brightness, self.maximumDimming);
            state.canSetBrightness = YES;
            state.lastWriteError = @"";
            state.lastWrittenBrightness = brightness;
            state.lastWriteTime = currentTime;
            state.lastAssigned = brightness;
            state.lastAutoBrightnessTime = currentTime;
            state.latestBrightness = brightness;
            state.latestBrightnessTime = currentTime;
            [self setAction:[NSString stringWithFormat:@"overlay alpha %.3f", overlayAlpha]
                     reason:@"software overlay applied"
                    display:display
                      state:state];
            [self addDebugEvent:[NSString stringWithFormat:@"software overlay alpha %.3f target %.3f", overlayAlpha, brightness]
                        display:display];
        } else {
            state.canSetBrightness = NO;
            state.lastWriteError = setError.localizedDescription ?: @"software overlay update failed";
            [self setAction:@"skipped: overlay failed" reason:@"software overlay update failed" display:display state:state];
            [self addSkippedDecisionEventForDisplay:display
                                              state:state
                                          lightness:lightness
                                             target:brightness
                                  currentBrightness:setPoint
                                             reason:@"overlay failed"];
        }
        return;
    }

    if (!state.hasValidBrightnessBaseline) {
        [self initialiseBrightnessBaseline:setPoint display:display state:state time:currentTime];
    } else if ([self isOwnWriteReadback:setPoint state:state time:currentTime]) {
        state.noticed = NO;
        state.lastSet = setPoint;
        state.brightnessBaseline = setPoint;
        state.brightnessBaselineTime = currentTime;
        [self markManualOverrideIgnored:@"not trained: own write debounce" display:display state:state time:currentTime];
    } else if (state.noticed || fabsf(state.brightnessBaseline - setPoint) > CHANGE_NOTICE) {
        if (!state.noticed) {
            state.noticed = YES;
            state.lastManualOverrideOldBrightness = state.brightnessBaseline;
            state.lastManualOverrideNewBrightness = setPoint;
            state.lastManualOverrideDelta = setPoint - state.brightnessBaseline;
            state.lastNoticed = setPoint;
            state.lastManualChangeTime = currentTime;
            state.lastTrainingDecision = @"not trained: manual override debounce";
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
            state.lastManualOverrideDelta = setPoint - state.lastManualOverrideOldBrightness;
            state.lastNoticed = setPoint;
            state.lastManualChangeTime = currentTime;
            state.lastTrainingDecision = @"not trained: manual override debounce";
            [self setAction:@"skipped: debounce" reason:@"debounce" display:display state:state];
            [self addSkippedDecisionEventForDisplay:display
                                              state:state
                                          lightness:lightness
                                             target:brightness
                                  currentBrightness:setPoint
                                             reason:@"debounce"];
            return;
        } else if (currentTime - state.lastManualChangeTime < DEBOUNCE_DELAY) {
            state.lastTrainingDecision = @"not trained: manual override debounce";
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
            state.lastSet = setPoint;
            state.brightnessBaseline = setPoint;
            state.brightnessBaselineTime = currentTime;
            state.lastTrainingDecision = @"not trained: own write debounce";
            state.lastLearnEvent = [NSString stringWithFormat:@"ignored %.3f @ %@", setPoint, [self formattedTime:currentTime]];
            [self addDebugEvent:@"manual-looking change ignored" display:display];
        } else {
            [self.model observeOutput:setPoint forInput:lightness displayKey:display.stableKey];
            state.lastLearnTime = currentTime;
            state.lastManualOverrideNewBrightness = setPoint;
            state.lastManualOverrideDelta = setPoint - state.lastManualOverrideOldBrightness;
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
            state.lastSet = setPoint;
            state.brightnessBaseline = setPoint;
            state.brightnessBaselineTime = currentTime;
        }
    } else {
        state.noticed = NO;
        state.lastSet = setPoint;
        state.brightnessBaseline = setPoint;
        state.brightnessBaselineTime = currentTime;
        state.lastTrainingDecision = @"not trained: within tolerance";
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

    if (state.lastAssigned >= 0 && fabsf(brightness - state.lastAssigned) <= CHANGE_NOTICE) {
        [self setAction:@"skipped: unchanged" reason:@"unchanged within tolerance" display:display state:state];
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
        state.canSetBrightness = YES;
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
    if (![self supportsManualBrightnessLearningForDisplay:display]) {
        state.latestBrightness = brightness;
        state.latestBrightnessTime = state.lastWriteTime;
        state.lastSet = brightness;
        state.hasValidBrightnessBaseline = NO;
    }

    BOOL shouldReadBack = updateState;
    if ([backend respondsToSelector:@selector(shouldReadBackAfterWrite)]) {
        shouldReadBack = updateState && [backend shouldReadBackAfterWrite];
    }

    if (shouldReadBack) {
        NSError *readBackError = nil;
        float readBack = [backend brightnessForDisplay:display error:&readBackError];
        if (!readBackError) {
            state.lastSet = readBack;
            state.hasValidBrightnessBaseline = YES;
            state.brightnessBaseline = readBack;
            state.brightnessBaselineTime = [NSDate timeIntervalSinceReferenceDate];
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
    NSArray *statuses = [self debugSnapshot][@"displays"];
    return [statuses isKindOfClass:[NSArray class]] ? statuses : @[];
}

- (NSDictionary<NSString *, id> *)debugSnapshot {
    __block NSDictionary *snapshot = nil;
    dispatch_sync(self.snapshotQueue, ^{
        snapshot = self.latestDebugSnapshot ?: @{};
    });
    return snapshot;
}

- (NSString *)debugSnapshotText {
    if (dispatch_get_specific(LumenControllerQueueKey)) {
        [self updateDebugSnapshotForced:YES];
    } else {
        dispatch_sync(self.controllerQueue, ^{
            [self updateDebugSnapshotForced:YES];
        });
    }
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

- (void)recordDebugPanelRenderDuration:(NSTimeInterval)duration {
    dispatch_async(self.controllerQueue, ^{
        self.debugPanelLastRenderDuration = duration;
        dispatch_barrier_async(self.snapshotQueue, ^{
            NSMutableDictionary *snapshot = [self.latestDebugSnapshot mutableCopy] ?: [NSMutableDictionary new];
            snapshot[@"debugPanelLastRenderDuration"] = @(duration);
            self.latestDebugSnapshot = snapshot.copy;
        });
    });
}

- (void)resetLearnedCalibrationForDebug {
    dispatch_async(self.controllerQueue, ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults removeObjectForKey:DEFAULTS_DISPLAY_CALIBRATION_POINTS];
        [defaults removeObjectForKey:DEFAULTS_DISPLAY_OVERLAY_CALIBRATION_POINTS];
        [defaults removeObjectForKey:DEFAULTS_CALIBRATION_POINTS];
        [defaults removeObjectForKey:DEFAULTS_CALIBRATION_POINTS_MIGRATED];
        [defaults synchronize];

        self.model = [Model new];
        [self.overlayCalibrationPointsByDisplayKey removeAllObjects];
        for (LumenDisplay *display in self.activeDisplays) {
            LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
            state.seededFromLegacyModel = NO;
            state.lastLearnEvent = @"none";
            state.lastLearnTime = 0;
            state.lastTrainingDecision = @"not trained: calibration reset";
            [self addDebugEvent:@"learned calibration reset" display:display];
        }
        [self updateDebugSnapshot];
    });
}

- (BOOL)externalSoftwareDimmingEnabled {
    return self.softwareOverlayBackend.enabled;
}

- (void)setExternalSoftwareDimmingEnabled:(BOOL)enabled {
    [self.softwareOverlayBackend setEnabled:enabled];
    dispatch_async(self.controllerQueue, ^{
        for (LumenDisplay *display in self.activeDisplays) {
            if (!display.builtin && [display.brightnessBackendName isEqualToString:self.softwareOverlayBackend.name]) {
                LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
                if (!enabled) {
                    display.brightnessControllable = NO;
                    display.brightnessBackendName = @"unsupported";
                    state.canReadBrightness = NO;
                    state.canSetBrightness = NO;
                    state.hasValidBrightnessBaseline = NO;
                    state.noticed = NO;
                    state.lastTrainingDecision = @"not trained: software overlay disabled";
                    [self setAction:@"skipped: software overlay disabled" reason:@"software overlay disabled" display:display state:state];
                }
            }
        }
        [self reloadDisplaysAndStreams];
    });
}

- (void)resetExternalOverlayCalibration {
    dispatch_async(self.controllerQueue, ^{
        NSMutableArray<NSString *> *externalKeys = [NSMutableArray new];
        for (LumenDisplay *display in self.activeDisplays) {
            if (!display.builtin) {
                [externalKeys addObject:display.stableKey];
                LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
                state.lastLearnEvent = @"none";
                state.lastLearnTime = 0;
                state.lastTrainingDecision = @"not trained: use overlay Learn Current";
                state.lastAssigned = -1;
                [self setAction:@"overlay calibration reset" reason:@"using safe default overlay curve" display:display state:state];
            }
        }
        for (NSString *displayKey in externalKeys) {
            [self.overlayCalibrationPointsByDisplayKey removeObjectForKey:displayKey];
        }
        [self synchronizeOverlayCalibrationDefaults];
        [self updateDebugSnapshot];
    });
}

- (void)temporarilyHideExternalOverlaysForScreenshot {
    [self.softwareOverlayBackend temporarilyHideForScreenshot];
}

- (void)restoreExternalOverlays {
    [self.softwareOverlayBackend restoreOverlays];
}

- (NSArray<NSDictionary<NSString *, id> *> *)externalOverlayControlTargets {
    NSDictionary *snapshot = [self debugSnapshot];
    NSArray *displays = snapshot[@"displays"];
    if (![displays isKindOfClass:[NSArray class]]) {
        return @[];
    }
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *display, NSDictionary *bindings) {
        return ![display[@"builtin"] boolValue] && [display[@"backend"] isEqualToString:self.softwareOverlayBackend.name];
    }];
    return [displays filteredArrayUsingPredicate:predicate];
}

- (void)adjustOverlayForDisplayKey:(NSString *)displayKey brighter:(BOOL)brighter {
    dispatch_async(self.controllerQueue, ^{
        LumenDisplay *display = [self displayForKey:displayKey];
        if (!display || ![self isSoftwareOverlayDisplay:display]) {
            return;
        }
        LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
        float currentBrightness = state.latestBrightness >= 0 ? state.latestBrightness : [self overlayTargetBrightnessForLightness:state.latestLightness displayKey:display.stableKey];
        float adjusted = LumenClampFloat(currentBrightness + (brighter ? LumenOverlayManualStep : -LumenOverlayManualStep),
                                         LumenOverlayMinimumPerceivedBrightness,
                                         1.0f);
        adjusted = [self brightnessByApplyingMaximumDimming:adjusted];
        NSError *error = nil;
        if ([self setBrightness:adjusted forDisplay:display updateState:NO error:&error]) {
            state.latestTargetBrightness = adjusted;
            state.latestTargetTime = [NSDate timeIntervalSinceReferenceDate];
            state.latestBrightness = adjusted;
            state.latestBrightnessTime = state.latestTargetTime;
            state.lastAssigned = adjusted;
            state.lastTrainingDecision = @"not trained: overlay adjusted manually";
            [self setAction:brighter ? @"overlay brighter" : @"overlay darker"
                     reason:@"manual overlay adjustment"
                    display:display
                      state:state];
        } else {
            state.lastWriteError = error.localizedDescription ?: @"overlay adjustment failed";
            [self setAction:@"skipped: overlay adjustment failed" reason:state.lastWriteError display:display state:state];
        }
        [self updateDebugSnapshot];
    });
}

- (void)learnCurrentOverlayForDisplayKey:(NSString *)displayKey {
    dispatch_async(self.controllerQueue, ^{
        LumenDisplay *display = [self displayForKey:displayKey];
        if (!display || ![self isSoftwareOverlayDisplay:display]) {
            return;
        }
        LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
        if (state.latestLightness < 0) {
            state.lastTrainingDecision = @"not trained: no current lightness sample";
            [self setAction:@"skipped: no overlay sample" reason:@"no current lightness sample" display:display state:state];
            [self updateDebugSnapshot];
            return;
        }
        float perceivedBrightness = state.latestBrightness >= 0 ? state.latestBrightness : [self overlayTargetBrightnessForLightness:state.latestLightness displayKey:display.stableKey];
        [self observeOverlayOutput:perceivedBrightness forInput:state.latestLightness displayKey:display.stableKey];
        state.lastLearnTime = [NSDate timeIntervalSinceReferenceDate];
        state.lastLearnEvent = [NSString stringWithFormat:@"overlay %.3f @ %@", perceivedBrightness, [self formattedTime:state.lastLearnTime]];
        state.lastTrainingDecision = @"trained: overlay Learn Current";
        [self setAction:@"overlay learned current" reason:@"explicit overlay calibration" display:display state:state];
        [self updateDebugSnapshot];
    });
}

- (void)resetOverlayCalibrationForDisplayKey:(NSString *)displayKey {
    dispatch_async(self.controllerQueue, ^{
        LumenDisplay *display = [self displayForKey:displayKey];
        if (!display || display.builtin) {
            return;
        }
        [self.overlayCalibrationPointsByDisplayKey removeObjectForKey:displayKey];
        [self synchronizeOverlayCalibrationDefaults];
        LumenDisplayState *state = self.displayStatesByKey[displayKey];
        state.lastLearnEvent = @"none";
        state.lastLearnTime = 0;
        state.lastTrainingDecision = @"not trained: use overlay Learn Current";
        state.lastAssigned = -1;
        [self setAction:@"overlay calibration reset" reason:@"using safe default overlay curve" display:display state:state];
        [self updateDebugSnapshot];
    });
}

- (void)updateDebugSnapshot {
    [self updateDebugSnapshotForced:NO];
}

- (void)updateDebugSnapshotAfterSample {
    self.debugSnapshotDirty = YES;
    [self updateDebugSnapshot];
}

- (void)updateDebugSnapshotForced:(BOOL)force {
    NSTimeInterval startedAt = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval minimumInterval = LumenDebugSnapshotVisibleInterval;
    BOOL shouldRebuild = force || self.lastDebugSnapshotUpdateTime <= 0 || startedAt - self.lastDebugSnapshotUpdateTime >= minimumInterval;
    if (!shouldRebuild) {
        self.debugSnapshotDirty = YES;
        return;
    }
    self.debugSnapshotRequestCount++;

    BOOL signpostsEnabled = LumenPerformanceSignpostsEnabled();
    os_signpost_id_t signpostID = OS_SIGNPOST_ID_INVALID;
    if (signpostsEnabled) {
        signpostID = os_signpost_id_generate(LumenPerformanceLog());
        os_signpost_interval_begin(LumenPerformanceLog(), signpostID, "Debug Snapshot");
    }
    NSMutableArray *displays = [NSMutableArray new];
    for (LumenDisplay *display in self.activeDisplays) {
        [displays addObject:[self debugDictionaryForDisplay:display]];
    }

    self.snapshotGenerationDuration = [NSDate timeIntervalSinceReferenceDate] - startedAt;
    self.lastDebugSnapshotUpdateTime = [NSDate timeIntervalSinceReferenceDate];
    self.debugSnapshotDirty = NO;
    self.debugSnapshotVersion++;
    NSDictionary *snapshot = @{@"running": @(self.running),
                               @"version": @(self.debugSnapshotVersion),
                               @"generatedAt": @([NSDate timeIntervalSinceReferenceDate]),
                               @"lastControlLoopDuration": @(self.lastControlLoopDuration),
                               @"snapshotGenerationDuration": @(self.snapshotGenerationDuration),
                               @"debugPanelLastRenderDuration": @(self.debugPanelLastRenderDuration),
                               @"displays": displays.copy,
                               @"events": self.debugEvents.copy};
    dispatch_barrier_async(self.snapshotQueue, ^{
        self.latestDebugSnapshot = snapshot;
    });
    if (signpostsEnabled) {
        os_signpost_interval_end(LumenPerformanceLog(), signpostID, "Debug Snapshot", "duration=%{public}.6f", self.snapshotGenerationDuration);
    }
    if (self.lastDebugSnapshotUpdateTime - self.lastDebugSnapshotLogTime >= LumenDebugSnapshotLogInterval) {
        self.lastDebugSnapshotLogTime = self.lastDebugSnapshotUpdateTime;
        os_log_debug(LumenDebugLog(),
                     "Snapshot update version=%{public}lu duration=%{public}.3f skipped=%{public}lu",
                     (unsigned long)self.debugSnapshotVersion,
                     self.snapshotGenerationDuration,
                     (unsigned long)self.debugSnapshotSkippedCount);
    }
}

- (NSDictionary<NSString *, id> *)debugDictionaryForDisplay:(LumenDisplay *)display {
    LumenDisplayState *state = self.displayStatesByKey[display.stableKey] ?: [LumenDisplayState new];
    NSUInteger sampleCount = [self.model debugSampleCountForDisplayKey:display.stableKey];
    BOOL learned = [self.model hasLearnedDataForDisplayKey:display.stableKey];
    NSString *modelState = learned ? [NSString stringWithFormat:@"%lu samples", (unsigned long)sampleCount] : @"no data";
    if (state.seededFromLegacyModel) {
        modelState = [modelState stringByAppendingString:@" seeded"];
    }

    float normalizedLightness = state.latestLightness >= 0 ? state.latestLightness / 100.0 : -1;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    double samplingFPS = [self samplingFPS];
    BOOL softwareOverlay = [self isSoftwareOverlayDisplay:display];
    NSUInteger overlaySampleCount = (self.overlayCalibrationPointsByDisplayKey[display.stableKey] ?: @[]).count;
    NSString *overlayPoints = [self overlayLearnedPointsSummaryForDisplayKey:display.stableKey];
    NSString *learnedPoints = @"";
    if (softwareOverlay) {
        sampleCount = overlaySampleCount;
        learned = overlaySampleCount >= 2;
        modelState = overlaySampleCount >= 2 ? [NSString stringWithFormat:@"%lu overlay samples", (unsigned long)overlaySampleCount] : @"overlay default curve";
        learnedPoints = overlayPoints;
    } else {
        if (state.cachedLearnedPointsSummary.length == 0 || now - state.cachedLearnedPointsSummaryTime >= 10.0) {
            state.cachedLearnedPointsSummary = [self.model debugLearnedPointsSummaryForDisplayKey:display.stableKey] ?: @"";
            state.cachedLearnedPointsSummaryTime = now;
        }
        learnedPoints = state.cachedLearnedPointsSummary ?: @"";
    }
    NSMutableDictionary *debug = [@{@"name": display.displayName ?: @"",
                                    @"display": display.displayName ?: @"",
                                    @"key": display.stableKey ?: @"",
                                    @"debugKey": [self shortDisplayKey:display.stableKey],
                                    @"displayID": @(display.displayID),
                                    @"role": [self roleForDisplay:display],
                                    @"builtin": @(display.builtin),
                                    @"main": @(display.displayID == CGMainDisplayID()),
                                    @"bounds": NSStringFromRect(NSRectFromCGRect(display.bounds)),
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
                                    @"actionTimestamp": @(state.lastDecisionTime),
                                    @"lastControlLoopDuration": @(self.lastControlLoopDuration),
                                    @"snapshotGenerationDuration": @(self.snapshotGenerationDuration),
                                    @"debugSnapshotRequests": @(self.debugSnapshotRequestCount),
                                    @"debugSnapshotsSkipped": @(self.debugSnapshotSkippedCount),
                                    @"debugSnapshotDirty": @(self.debugSnapshotDirty),
                                    @"debugPanelLastRenderDuration": @(self.debugPanelLastRenderDuration),
                                    @"samplingMode": [self samplingModeName],
                                    @"adaptiveSamplingEnabled": @(self.adaptiveSampling),
                                    @"maximumDimming": @(self.maximumDimming),
                                    @"maxAnalysisFPS": @(samplingFPS),
                                    @"captureStreamFPS": @(LumenClampDouble(samplingFPS, LumenMinimumSamplingFPS, LumenCaptureFPS)),
                                    @"effectiveAnalysisFPS": @(state.acceptedSampleRate),
                                    @"lastAcceptedSampleAge": @(state.lastAcceptedSampleTimestamp > 0 ? now - state.lastAcceptedSampleTimestamp : -1),
                                    @"forcedRefreshInterval": @(LumenForcedHeavyAnalysisInterval),
                                    @"cheapChangeDelta": @(state.lastCheapChangeDelta),
                                    @"heavyAnalysesSkipped": @(state.heavyAnalysisSkippedCount),
                                    @"lastHeavyAnalysisDuration": @(state.lastHeavyAnalysisDuration),
                                    @"captureCallbackCount": @(state.captureCallbackCount),
                                    @"acceptedSampleCount": @(state.acceptedSampleCount),
                                    @"captureRate": @(state.captureRate),
                                    @"acceptedSampleRate": @(state.acceptedSampleRate),
                                    @"droppedSampleCount": @(state.droppedSampleCount),
                                    @"droppedFrames": @(state.droppedSampleCount),
                                    @"coalescedFrames": @(state.coalescedFrameCount),
                                    @"lastLightnessComputeDuration": @(state.lastLightnessComputeDuration),
                                    @"lastCheapFingerprintDuration": @(state.lastCheapFingerprintDuration),
                                    @"lastSampleProcessingDuration": @(state.lastSampleProcessingDuration),
                                    @"lastControllerQueueWaitDuration": @(state.lastControllerQueueWaitDuration),
                                    @"lastCaptureCallbackTimestamp": @(state.lastCaptureCallbackTimestamp),
                                    @"lastAcceptedSampleTimestamp": @(state.lastAcceptedSampleTimestamp),
                                    @"model": modelState,
                                    @"modelSampleCount": @(sampleCount),
                                    @"modelHasData": @(learned),
                                    @"learned": @(learned),
                                    @"modelRange": @"",
                                    @"learnedPoints": learnedPoints,
                                    @"overlayCalibrationSamples": @(overlaySampleCount),
                                    @"overlayLearnedPoints": overlayPoints,
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
                                    @"hasValidBrightnessBaseline": @(state.hasValidBrightnessBaseline),
                                    @"brightnessBaseline": @(state.brightnessBaseline),
                                    @"brightnessBaselineTimestamp": @(state.brightnessBaselineTime),
                                    @"lastWrittenBrightness": @(state.lastWrittenBrightness),
                                    @"lastWriteTimestamp": @(state.lastWriteTime),
                                    @"lastWriteError": state.lastWriteError ?: @"",
                                    @"lastReadError": state.lastReadError ?: @"",
                                    @"manualLearningAvailable": @([self supportsManualBrightnessLearningForDisplay:display])} mutableCopy];
    id<LumenBrightnessBackend> backend = [self backendForDisplay:display];
    if ([backend respondsToSelector:@selector(debugInfoForDisplay:)]) {
        [debug addEntriesFromDictionary:[backend debugInfoForDisplay:display]];
    } else if (display.brightnessControllable) {
        debug[@"backendState"] = @"read/write";
    } else {
        debug[@"backendState"] = @"unsupported";
    }
    if (!display.builtin && backend != self.ddcBackend && [self.ddcBackend respondsToSelector:@selector(debugInfoForDisplay:)]) {
        NSDictionary<NSString *, id> *ddcDebug = [self.ddcBackend debugInfoForDisplay:display];
        for (NSString *key in ddcDebug) {
            if ([key hasPrefix:@"ddc"] || [key isEqualToString:@"backendState"]) {
                NSString *targetKey = [key isEqualToString:@"backendState"] ? @"ddcBackendState" : key;
                debug[targetKey] = ddcDebug[key];
            }
        }
    }
    return debug;
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
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSString *signature = [NSString stringWithFormat:@"%@|%@|%.3f",
                           display.stableKey ?: @"",
                           reason ?: @"unknown",
                           target];
    if (state &&
        [state.lastSkippedEventSignature isEqualToString:signature] &&
        now - state.lastSkippedEventTime < LumenNoisyDebugEventInterval) {
        state.skippedEventRepeatCount++;
        return;
    }

    NSUInteger repeatCount = state ? state.skippedEventRepeatCount : 0;
    if (state) {
        state.lastSkippedEventSignature = signature;
        state.lastSkippedEventTime = now;
        state.skippedEventRepeatCount = 0;
    }

    NSString *event = [NSString stringWithFormat:@"decision skipped: %@ lightness %.3f target %.3f%@",
                       reason ?: @"unknown",
                       lightness / 100.0,
                       target,
                       currentBrightness >= 0 ? [NSString stringWithFormat:@" current %.3f", currentBrightness] : @""];
    if (repeatCount > 0) {
        event = [event stringByAppendingFormat:@" (repeated %lu)", (unsigned long)repeatCount];
    }
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

- (void)recordCaptureCallbackForState:(LumenDisplayState *)state atTime:(NSTimeInterval)time dropped:(BOOL)dropped {
    if (!state) {
        return;
    }

    state.captureCallbackCount++;
    state.lastCaptureCallbackTimestamp = time;
    if (dropped) {
        state.droppedSampleCount++;
    }

    if (state.captureRateWindowStart <= 0) {
        state.captureRateWindowStart = time;
        state.captureRateWindowCount = 0;
    }
    state.captureRateWindowCount++;
    NSTimeInterval elapsed = time - state.captureRateWindowStart;
    if (elapsed >= 1.0) {
        state.captureRate = (double)state.captureRateWindowCount / elapsed;
    }
    if (elapsed >= 5.0) {
        state.captureRateWindowStart = time;
        state.captureRateWindowCount = 0;
    }
}

- (void)recordAcceptedSampleForState:(LumenDisplayState *)state atTime:(NSTimeInterval)time {
    if (!state) {
        return;
    }

    state.acceptedSampleCount++;
    state.lastAcceptedSampleTimestamp = time;

    if (state.acceptedRateWindowStart <= 0) {
        state.acceptedRateWindowStart = time;
        state.acceptedRateWindowCount = 0;
    }
    state.acceptedRateWindowCount++;
    NSTimeInterval elapsed = time - state.acceptedRateWindowStart;
    if (elapsed >= 1.0) {
        state.acceptedSampleRate = (double)state.acceptedRateWindowCount / elapsed;
    }
    if (elapsed >= 5.0) {
        state.acceptedRateWindowStart = time;
        state.acceptedRateWindowCount = 0;
    }
}

- (void)initialiseBrightnessBaseline:(float)brightness display:(LumenDisplay *)display state:(LumenDisplayState *)state time:(NSTimeInterval)time {
    state.hasValidBrightnessBaseline = YES;
    state.brightnessBaseline = brightness;
    state.brightnessBaselineTime = time;
    state.lastSet = brightness;
    state.noticed = NO;
    state.lastTrainingDecision = @"not trained: baseline initialised";
    state.lastManualOverrideOldBrightness = -1;
    state.lastManualOverrideNewBrightness = brightness;
    state.lastManualOverrideDelta = 0;

    if (time - state.lastBaselineEventTime > LumenNoisyDebugEventInterval) {
        state.lastBaselineEventTime = time;
        [self addDebugEvent:[NSString stringWithFormat:@"brightness baseline initialised %.3f", brightness]
                    display:display];
        os_log_info(LumenDebugLog(),
                    "Brightness baseline initialised display=%{public}@ key=%{public}@ brightness=%{public}.3f",
                    display.displayName,
                    [self shortDisplayKey:display.stableKey],
                    brightness);
    }
}

- (void)markManualOverrideIgnored:(NSString *)decision display:(LumenDisplay *)display state:(LumenDisplayState *)state time:(NSTimeInterval)time {
    state.lastTrainingDecision = decision ?: @"not trained: no valid previous brightness";
    if (time - state.lastIgnoredManualEventTime > LumenNoisyDebugEventInterval) {
        state.lastIgnoredManualEventTime = time;
        [self addDebugEvent:state.lastTrainingDecision display:display];
    }
}

- (BOOL)isOwnWriteReadback:(float)brightness state:(LumenDisplayState *)state time:(NSTimeInterval)time {
    if (state.lastWrittenBrightness < 0 || state.lastWriteTime <= 0) {
        return NO;
    }

    BOOL recentWrite = time - state.lastWriteTime < LumenOwnWriteReadbackDebounce;
    BOOL matchesLastWrite = fabsf(brightness - state.lastWrittenBrightness) <= CHANGE_NOTICE;
    BOOL matchesLastAssigned = state.lastAssigned >= 0 && fabsf(brightness - state.lastAssigned) <= CHANGE_NOTICE;
    return recentWrite || matchesLastWrite || matchesLastAssigned;
}

- (void)setAction:(NSString *)action reason:(NSString *)reason display:(LumenDisplay *)display state:(LumenDisplayState *)state {
    if (!state) {
        return;
    }
    BOOL changed = ![state.lastAction isEqualToString:action] || ![state.lastActionReason isEqualToString:reason];
    state.lastAction = action ?: @"unknown";
    state.lastActionReason = reason ?: @"unknown";
    state.lastDecisionTime = [NSDate timeIntervalSinceReferenceDate];
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
    if (!display.builtin && !self.softwareOverlayBackend.enabled) {
        return nil;
    }

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

- (BOOL)supportsManualBrightnessLearningForDisplay:(LumenDisplay *)display {
    id<LumenBrightnessBackend> backend = [self backendForDisplay:display];
    if ([backend respondsToSelector:@selector(supportsManualBrightnessLearning)]) {
        return [backend supportsManualBrightnessLearning];
    }
    return YES;
}

- (BOOL)isSoftwareOverlayDisplay:(LumenDisplay *)display {
    return display && [display.brightnessBackendName isEqualToString:self.softwareOverlayBackend.name];
}

- (float)brightnessByApplyingMaximumDimming:(float)brightness {
    return LumenClampFloat(brightness, LumenMinimumBrightnessForMaximumDimming(self.maximumDimming), 1.0f);
}

- (float)overlayTargetBrightnessForLightness:(float)lightness displayKey:(NSString *)displayKey {
    NSArray<NSDictionary<NSString *, NSNumber *> *> *points = self.overlayCalibrationPointsByDisplayKey[displayKey] ?: @[];
    if (points.count < 2) {
        float t = 0.0f;
        if (lightness > LumenOverlayDefaultDarkLStar) {
            t = (lightness - LumenOverlayDefaultDarkLStar) / (LumenOverlayDefaultBrightLStar - LumenOverlayDefaultDarkLStar);
        }
        t = LumenClampFloat(t, 0.0f, 1.0f);
        return LumenOverlayDefaultDarkBrightness + ((LumenOverlayDefaultBrightBrightness - LumenOverlayDefaultDarkBrightness) * t);
    }

    NSArray<NSDictionary<NSString *, NSNumber *> *> *sorted = [points sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
        float firstX = LumenOverlayPointValue(first, @"x");
        float secondX = LumenOverlayPointValue(second, @"x");
        if (firstX < secondX) {
            return NSOrderedAscending;
        }
        if (firstX > secondX) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];

    NSDictionary *first = sorted.firstObject;
    NSDictionary *last = sorted.lastObject;
    if (lightness <= LumenOverlayPointValue(first, @"x")) {
        return LumenClampFloat(LumenOverlayPointValue(first, @"y"), LumenOverlayMinimumPerceivedBrightness, 1.0f);
    }
    if (lightness >= LumenOverlayPointValue(last, @"x")) {
        return LumenClampFloat(LumenOverlayPointValue(last, @"y"), LumenOverlayMinimumPerceivedBrightness, 1.0f);
    }

    for (NSUInteger i = 1; i < sorted.count; i++) {
        NSDictionary *right = sorted[i];
        if (lightness <= LumenOverlayPointValue(right, @"x")) {
            NSDictionary *left = sorted[i - 1];
            float leftX = LumenOverlayPointValue(left, @"x");
            float rightX = LumenOverlayPointValue(right, @"x");
            if (fabsf(rightX - leftX) < FLT_EPSILON) {
                return LumenClampFloat(LumenOverlayPointValue(right, @"y"), LumenOverlayMinimumPerceivedBrightness, 1.0f);
            }
            float t = (lightness - leftX) / (rightX - leftX);
            float y = LumenOverlayPointValue(left, @"y") + ((LumenOverlayPointValue(right, @"y") - LumenOverlayPointValue(left, @"y")) * t);
            return LumenClampFloat(y, LumenOverlayMinimumPerceivedBrightness, 1.0f);
        }
    }

    return LumenOverlayDefaultBrightBrightness;
}

- (void)observeOverlayOutput:(float)output forInput:(float)input displayKey:(NSString *)displayKey {
    if (displayKey.length == 0 || !isfinite(output) || !isfinite(input)) {
        return;
    }
    float safeOutput = LumenClampFloat(output, LumenOverlayMinimumPerceivedBrightness, 1.0f);
    NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *points = self.overlayCalibrationPointsByDisplayKey[displayKey];
    if (!points) {
        points = [NSMutableArray new];
        self.overlayCalibrationPointsByDisplayKey[displayKey] = points;
    }
    [points addObject:@{@"x": @(input), @"y": @(safeOutput)}];
    [points sortUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
        float firstX = LumenOverlayPointValue(first, @"x");
        float secondX = LumenOverlayPointValue(second, @"x");
        if (firstX < secondX) {
            return NSOrderedAscending;
        }
        if (firstX > secondX) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];

    NSMutableIndexSet *toDelete = [NSMutableIndexSet new];
    for (NSUInteger i = 1; i < points.count; i++) {
        NSDictionary *left = points[i - 1];
        NSDictionary *right = points[i];
        if (fabsf(LumenOverlayPointValue(right, @"x") - LumenOverlayPointValue(left, @"x")) < MIN_X_SPACING) {
            [toDelete addIndex:i - 1];
        }
    }
    [points removeObjectsAtIndexes:toDelete];
    [self synchronizeOverlayCalibrationDefaults];
}

- (void)restoreOverlayCalibrationDefaults {
    NSDictionary *encodedByDisplayKey = [[NSUserDefaults standardUserDefaults] dictionaryForKey:DEFAULTS_DISPLAY_OVERLAY_CALIBRATION_POINTS];
    if (![encodedByDisplayKey isKindOfClass:[NSDictionary class]]) {
        return;
    }

    for (NSString *displayKey in encodedByDisplayKey) {
        NSArray *encodedPoints = encodedByDisplayKey[displayKey];
        if (![encodedPoints isKindOfClass:[NSArray class]]) {
            continue;
        }
        NSMutableArray *points = [NSMutableArray new];
        for (NSDictionary *point in encodedPoints) {
            NSNumber *x = [point isKindOfClass:[NSDictionary class]] ? point[@"x"] : nil;
            NSNumber *y = [point isKindOfClass:[NSDictionary class]] ? point[@"y"] : nil;
            if ([x isKindOfClass:[NSNumber class]] && [y isKindOfClass:[NSNumber class]]) {
                [points addObject:@{@"x": x, @"y": y}];
            }
        }
        self.overlayCalibrationPointsByDisplayKey[displayKey] = points;
    }
}

- (void)synchronizeOverlayCalibrationDefaults {
    NSMutableDictionary *encodedByDisplayKey = [NSMutableDictionary new];
    for (NSString *displayKey in self.overlayCalibrationPointsByDisplayKey) {
        encodedByDisplayKey[displayKey] = self.overlayCalibrationPointsByDisplayKey[displayKey].copy;
    }
    [[NSUserDefaults standardUserDefaults] setObject:encodedByDisplayKey forKey:DEFAULTS_DISPLAY_OVERLAY_CALIBRATION_POINTS];
}

- (NSString *)overlayLearnedPointsSummaryForDisplayKey:(NSString *)displayKey {
    NSArray<NSDictionary<NSString *, NSNumber *> *> *points = self.overlayCalibrationPointsByDisplayKey[displayKey] ?: @[];
    if (points.count == 0) {
        return @"no data";
    }
    NSMutableArray<NSString *> *summaries = [NSMutableArray new];
    NSUInteger limit = MIN((NSUInteger)3, points.count);
    for (NSUInteger i = 0; i < limit; i++) {
        NSDictionary *point = points[i];
        [summaries addObject:[NSString stringWithFormat:@"L*=%.1f -> %.3f", LumenOverlayPointValue(point, @"x"), LumenOverlayPointValue(point, @"y")]];
    }
    if (points.count > limit) {
        [summaries addObject:@"..."];
    }
    return [summaries componentsJoinedByString:@", "];
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

- (NSTimeInterval)minimumAnalysisIntervalForDisplayKey:(NSString *)displayKey {
    double fps = [self samplingFPS];
    NSTimeInterval configuredInterval = fps > 0 ? 1.0 / fps : 1.0 / LumenDefaultSamplingFPS;
    if (!self.adaptiveSampling) {
        return configuredInterval;
    }

    NSNumber *targetInterval = nil;
    @synchronized (self.lastAcceptedSampleTimeByDisplayKey) {
        targetInterval = self.targetSampleIntervalByDisplayKey[displayKey];
    }
    NSTimeInterval adaptiveInterval = targetInterval.doubleValue;
    if (adaptiveInterval <= 0) {
        adaptiveInterval = configuredInterval;
    }
    return MAX(configuredInterval, adaptiveInterval);
}

- (void)recordDeferredDroppedSampleForDisplayKey:(NSString *)displayKey {
    if (displayKey.length == 0) {
        return;
    }
    @synchronized (self.lastAcceptedSampleTimeByDisplayKey) {
        NSUInteger count = self.deferredDroppedSampleCountsByDisplayKey[displayKey].unsignedIntegerValue;
        self.deferredDroppedSampleCountsByDisplayKey[displayKey] = @(count + 1);
    }
}

- (void)drainDeferredDroppedSamplesForDisplayKey:(NSString *)displayKey state:(LumenDisplayState *)state atTime:(NSTimeInterval)time {
    if (!state || displayKey.length == 0) {
        return;
    }
    NSUInteger count = 0;
    @synchronized (self.lastAcceptedSampleTimeByDisplayKey) {
        count = self.deferredDroppedSampleCountsByDisplayKey[displayKey].unsignedIntegerValue;
        if (count > 0) {
            [self.deferredDroppedSampleCountsByDisplayKey removeObjectForKey:displayKey];
        }
    }
    if (count == 0) {
        return;
    }
    state.captureCallbackCount += count;
    state.droppedSampleCount += count;
    state.lastCaptureCallbackTimestamp = time;
}

- (BOOL)reserveSampleProcessingForDisplayKey:(NSString *)displayKey sampleBuffer:(CMSampleBufferRef)sampleBuffer arrivedAt:(NSTimeInterval)sampleArrivedAt {
    BOOL shouldCoalesce = NO;
    @synchronized (self.processingSampleDisplayKeys) {
        shouldCoalesce = [self.processingSampleDisplayKeys containsObject:displayKey];
        if (!shouldCoalesce) {
            [self.processingSampleDisplayKeys addObject:displayKey];
        }
    }

    if (!shouldCoalesce) {
        return YES;
    }

    LumenPendingSample *pendingSample = [LumenPendingSample new];
    pendingSample.sampleBufferObject = CFBridgingRelease(CFRetain(sampleBuffer));
    pendingSample.arrivalTime = sampleArrivedAt;
    @synchronized (self.pendingSamplesByDisplayKey) {
        self.pendingSamplesByDisplayKey[displayKey] = pendingSample;
    }
    dispatch_async(self.controllerQueue, ^{
        LumenDisplayState *state = self.displayStatesByKey[displayKey];
        [self recordCaptureCallbackForState:state atTime:sampleArrivedAt dropped:NO];
        state.coalescedFrameCount++;
    });
    return NO;
}

- (void)finishProcessingSampleForDisplayKey:(NSString *)displayKey {
    __block LumenPendingSample *pendingSample = nil;
    @synchronized (self.pendingSamplesByDisplayKey) {
        pendingSample = self.pendingSamplesByDisplayKey[displayKey];
        if (pendingSample) {
            [self.pendingSamplesByDisplayKey removeObjectForKey:displayKey];
        }
    }

    if (pendingSample) {
        @synchronized (self.processingSampleDisplayKeys) {
            [self.processingSampleDisplayKeys removeObject:displayKey];
        }
        dispatch_async(self.sampleQueue, ^{
            [self handleIncomingSampleBuffer:(__bridge CMSampleBufferRef)pendingSample.sampleBufferObject
                                   displayKey:displayKey
                                    arrivedAt:pendingSample.arrivalTime];
        });
        return;
    }

    @synchronized (self.processingSampleDisplayKeys) {
        [self.processingSampleDisplayKeys removeObject:displayKey];
    }
}

- (NSData *)cheapFingerprintFromSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) {
        return nil;
    }
    if (CVPixelBufferGetPixelFormatType(imageBuffer) != kCVPixelFormatType_32BGRA) {
        return nil;
    }
    if (CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return nil;
    }

    void *baseAddress = CVPixelBufferGetBaseAddress(imageBuffer);
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    NSUInteger sampleColumns = MIN((NSUInteger)width, LumenCheapFingerprintGridWidth);
    NSUInteger sampleRows = MIN((NSUInteger)height, LumenCheapFingerprintGridHeight);
    if (sampleColumns == 0 || sampleRows == 0) {
        CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
        return nil;
    }

    NSMutableData *fingerprint = [NSMutableData dataWithLength:sampleColumns * sampleRows];
    UInt8 *samples = fingerprint.mutableBytes;
    NSUInteger index = 0;
    for (NSUInteger row = 0; row < sampleRows; row++) {
        size_t y = sampleRows == 1 ? 0 : (size_t)((row * (height - 1) + ((sampleRows - 1) / 2)) / (sampleRows - 1));
        for (NSUInteger column = 0; column < sampleColumns; column++) {
            size_t x = sampleColumns == 1 ? 0 : (size_t)((column * (width - 1) + ((sampleColumns - 1) / 2)) / (sampleColumns - 1));
            const UInt8 *pixel = (UInt8 *)baseAddress + (y * bytesPerRow) + (x * 4);
            samples[index++] = (UInt8)(((NSUInteger)54 * pixel[2] + (NSUInteger)183 * pixel[1] + (NSUInteger)19 * pixel[0]) >> 8);
        }
    }
    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    return fingerprint;
}

- (double)cheapDeltaFromFingerprint:(NSData *)fingerprint previousFingerprint:(NSData *)previousFingerprint {
    if (fingerprint.length == 0 || previousFingerprint.length == 0 || fingerprint.length != previousFingerprint.length) {
        return INFINITY;
    }
    const UInt8 *current = fingerprint.bytes;
    const UInt8 *previous = previousFingerprint.bytes;
    NSUInteger length = fingerprint.length;
    NSUInteger totalDifference = 0;
    for (NSUInteger i = 0; i < length; i++) {
        totalDifference += (NSUInteger)abs((int)current[i] - (int)previous[i]);
    }
    return (double)totalDifference / ((double)length * 255.0);
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
    NSUInteger sampleColumns = MIN((NSUInteger)width, LumenLightnessSampleGridWidth);
    NSUInteger sampleRows = MIN((NSUInteger)height, LumenLightnessSampleGridHeight);
    if (sampleColumns == 0 || sampleRows == 0) {
        CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
        return 0;
    }

    for (NSUInteger row = 0; row < sampleRows; row++) {
        size_t y = sampleRows == 1 ? 0 : (size_t)((row * (height - 1) + ((sampleRows - 1) / 2)) / (sampleRows - 1));
        for (NSUInteger column = 0; column < sampleColumns; column++) {
            size_t x = sampleColumns == 1 ? 0 : (size_t)((column * (width - 1) + ((sampleColumns - 1) / 2)) / (sampleColumns - 1));
            const unsigned char *pixel = (unsigned char *)baseAddress + (y * bytesPerRow) + (x * 4);
            double l = srgb_to_lightness(pixel[2], pixel[1], pixel[0]);
            lightness += l * l;
        }
    }

    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);

    lightness = sqrt(lightness / (sampleColumns * sampleRows));
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

    __block NSString *displayKey = nil;
    @synchronized (self.displayKeyByStream) {
        displayKey = self.displayKeyByStream[[NSValue valueWithNonretainedObject:stream]];
    }
    if (displayKey.length == 0) {
        return;
    }

    NSTimeInterval sampleArrivedAt = [NSDate timeIntervalSinceReferenceDate];
    [self handleIncomingSampleBuffer:sampleBuffer displayKey:displayKey arrivedAt:sampleArrivedAt];
}

- (void)handleIncomingSampleBuffer:(CMSampleBufferRef)sampleBuffer displayKey:(NSString *)displayKey arrivedAt:(NSTimeInterval)sampleArrivedAt {
    if (![self reserveSampleProcessingForDisplayKey:displayKey sampleBuffer:sampleBuffer arrivedAt:sampleArrivedAt]) {
        return;
    }
    [self processSampleBuffer:sampleBuffer displayKey:displayKey arrivedAt:sampleArrivedAt processingReserved:YES];
}

- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer displayKey:(NSString *)displayKey arrivedAt:(NSTimeInterval)sampleArrivedAt processingReserved:(BOOL)processingReserved {
    NSTimeInterval sampleProcessingStartedAt = [NSDate timeIntervalSinceReferenceDate];
    BOOL signpostsEnabled = LumenPerformanceSignpostsEnabled();
    os_signpost_id_t sampleSignpostID = OS_SIGNPOST_ID_INVALID;
    if (signpostsEnabled) {
        sampleSignpostID = os_signpost_id_generate(LumenPerformanceLog());
        os_signpost_interval_begin(LumenPerformanceLog(), sampleSignpostID, "Sample Processing", "displayKey=%{public}@", [self shortDisplayKey:displayKey]);
    }

    NSTimeInterval cheapStartedAt = [NSDate timeIntervalSinceReferenceDate];
    os_signpost_id_t cheapSignpostID = OS_SIGNPOST_ID_INVALID;
    if (signpostsEnabled) {
        cheapSignpostID = os_signpost_id_generate(LumenPerformanceLog());
        os_signpost_interval_begin(LumenPerformanceLog(), cheapSignpostID, "Cheap Fingerprint", "displayKey=%{public}@", [self shortDisplayKey:displayKey]);
    }
    NSData *fingerprint = [self cheapFingerprintFromSampleBuffer:sampleBuffer];
    NSTimeInterval cheapDuration = [NSDate timeIntervalSinceReferenceDate] - cheapStartedAt;
    @synchronized (self.lastAcceptedSampleTimeByDisplayKey) {
        self.lastCheapFingerprintTimeByDisplayKey[displayKey] = @(sampleArrivedAt);
    }
    if (signpostsEnabled) {
        os_signpost_interval_end(LumenPerformanceLog(), cheapSignpostID, "Cheap Fingerprint", "duration=%{public}.6f", cheapDuration);
    }
    __block NSData *previousFingerprint = nil;
    @synchronized (self.lastAcceptedSampleTimeByDisplayKey) {
        previousFingerprint = self.cheapFingerprintByDisplayKey[displayKey];
    }
    double cheapDelta = [self cheapDeltaFromFingerprint:fingerprint previousFingerprint:previousFingerprint];
    BOOL meaningfulChange = !isfinite(cheapDelta) || cheapDelta >= LumenCheapChangeThreshold;

    __block BOOL shouldThrottle = NO;
    @synchronized (self.lastAcceptedSampleTimeByDisplayKey) {
        NSTimeInterval lastAccepted = self.lastAcceptedSampleTimeByDisplayKey[displayKey].doubleValue;
        NSTimeInterval targetInterval = [self minimumAnalysisIntervalForDisplayKey:displayKey];
        shouldThrottle = lastAccepted > 0 && sampleArrivedAt - lastAccepted < targetInterval && !meaningfulChange;
        if (!shouldThrottle) {
            self.lastAcceptedSampleTimeByDisplayKey[displayKey] = @(sampleArrivedAt);
            if (fingerprint) {
                self.cheapFingerprintByDisplayKey[displayKey] = fingerprint;
            }
        }
    }

    if (shouldThrottle) {
        [self recordDeferredDroppedSampleForDisplayKey:displayKey];
        [self finishProcessingSampleForDisplayKey:displayKey];
        if (signpostsEnabled) {
            os_signpost_interval_end(LumenPerformanceLog(), sampleSignpostID, "Sample Processing", "duration=%{public}.6f", [NSDate timeIntervalSinceReferenceDate] - sampleProcessingStartedAt);
        }
        return;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    __block BOOL shouldRunHeavyAnalysis = meaningfulChange || !self.adaptiveSampling;
    __block BOOL forcedRefresh = NO;
    if (!shouldRunHeavyAnalysis) {
        @synchronized (self.lastAcceptedSampleTimeByDisplayKey) {
            NSTimeInterval lastHeavy = self.lastHeavyAnalysisTimeByDisplayKey[displayKey].doubleValue;
            forcedRefresh = lastHeavy <= 0 || now - lastHeavy >= LumenForcedHeavyAnalysisInterval;
            shouldRunHeavyAnalysis = forcedRefresh;
        }
    }

    if (!shouldRunHeavyAnalysis) {
        NSTimeInterval controllerEnqueuedAt = [NSDate timeIntervalSinceReferenceDate];
        dispatch_async(self.controllerQueue, ^{
            NSTimeInterval controllerStartedAt = [NSDate timeIntervalSinceReferenceDate];
            LumenDisplay *display = [self displayForKey:displayKey];
            LumenDisplayState *state = self.displayStatesByKey[displayKey];
            state.lastCheapFingerprintDuration = cheapDuration;
            state.lastControllerQueueWaitDuration = controllerStartedAt - controllerEnqueuedAt;
            state.lastSampleProcessingDuration = controllerStartedAt - sampleProcessingStartedAt;
            [self drainDeferredDroppedSamplesForDisplayKey:displayKey state:state atTime:sampleArrivedAt];
            [self recordCaptureCallbackForState:state atTime:sampleArrivedAt dropped:NO];
            state.lastCheapChangeDelta = isfinite(cheapDelta) ? cheapDelta : 0;
            state.heavyAnalysisSkippedCount++;
            if (display && state) {
                [self setAction:@"sample skipped: content unchanged"
                         reason:@"cheap change below threshold"
                        display:display
                          state:state];
            }
            [self updateDebugSnapshotAfterSample];
            [self finishProcessingSampleForDisplayKey:displayKey];
            if (signpostsEnabled) {
                os_signpost_interval_end(LumenPerformanceLog(), sampleSignpostID, "Sample Processing", "duration=%{public}.6f", state.lastSampleProcessingDuration);
            }
        });
        return;
    }

    NSTimeInterval computeStartedAt = [NSDate timeIntervalSinceReferenceDate];
    os_signpost_id_t heavySignpostID = OS_SIGNPOST_ID_INVALID;
    if (signpostsEnabled) {
        heavySignpostID = os_signpost_id_generate(LumenPerformanceLog());
        os_signpost_interval_begin(LumenPerformanceLog(), heavySignpostID, "Heavy Lightness", "displayKey=%{public}@", [self shortDisplayKey:displayKey]);
    }
    double lightness = [self computeLightnessFromSampleBuffer:sampleBuffer];
    NSTimeInterval computeDuration = [NSDate timeIntervalSinceReferenceDate] - computeStartedAt;
    if (signpostsEnabled) {
        os_signpost_interval_end(LumenPerformanceLog(), heavySignpostID, "Heavy Lightness", "duration=%{public}.6f", computeDuration);
    }
    NSTimeInterval controllerEnqueuedAt = [NSDate timeIntervalSinceReferenceDate];
    dispatch_async(self.controllerQueue, ^{
        NSTimeInterval controllerStartedAt = [NSDate timeIntervalSinceReferenceDate];
        if (!self.running) {
            [self finishProcessingSampleForDisplayKey:displayKey];
            if (signpostsEnabled) {
                os_signpost_interval_end(LumenPerformanceLog(), sampleSignpostID, "Sample Processing", "stopped=1");
            }
            return;
        }
        NSTimeInterval controlStartedAt = [NSDate timeIntervalSinceReferenceDate];
        os_signpost_id_t controlSignpostID = OS_SIGNPOST_ID_INVALID;
        if (signpostsEnabled) {
            controlSignpostID = os_signpost_id_generate(LumenPerformanceLog());
            os_signpost_interval_begin(LumenPerformanceLog(), controlSignpostID, "Control Loop", "displayKey=%{public}@", [self shortDisplayKey:displayKey]);
        }

        LumenDisplay *display = [self displayForKey:displayKey];
        if (display) {
            LumenDisplayState *state = self.displayStatesByKey[display.stableKey];
            state.lastCheapFingerprintDuration = cheapDuration;
            state.lastLightnessComputeDuration = computeDuration;
            state.lastHeavyAnalysisDuration = computeDuration;
            state.lastControllerQueueWaitDuration = controllerStartedAt - controllerEnqueuedAt;
            state.lastCheapChangeDelta = isfinite(cheapDelta) ? cheapDelta : 0;
            [self drainDeferredDroppedSamplesForDisplayKey:displayKey state:state atTime:sampleArrivedAt];
            if (lightness <= 0) {
                if (state.latestLightnessTime <= 0) {
                    state.lastTrainingDecision = @"not trained: no sample";
                    [self setAction:@"skipped: no sample" reason:@"no current sample" display:display state:state];
                }
            } else {
                [(NSMutableDictionary *)self.currentLightnessByDisplayKey setObject:@(lightness) forKey:display.stableKey];
                NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
                [self recordCaptureCallbackForState:state atTime:sampleArrivedAt dropped:NO];
                [self recordAcceptedSampleForState:state atTime:now];
                state.lastHeavyAnalysisTime = now;
                @synchronized (self.lastAcceptedSampleTimeByDisplayKey) {
                    self.lastHeavyAnalysisTimeByDisplayKey[display.stableKey] = @(now);
                }

                double previousLightness = state.latestLightness;
                BOOL hasPreviousLightness = previousLightness >= 0;
                BOOL lightnessChanged = !hasPreviousLightness || fabs(lightness - previousLightness) >= LumenLightnessDeltaThreshold;
                if (!hasPreviousLightness || lightnessChanged) {
                    state.lightnessStableSince = now;
                } else if (state.lightnessStableSince <= 0) {
                    state.lightnessStableSince = now;
                }
                BOOL stable = state.lightnessStableSince > 0 && now - state.lightnessStableSince >= LumenStableSampleAfter;
                @synchronized (self.lastAcceptedSampleTimeByDisplayKey) {
                    self.targetSampleIntervalByDisplayKey[display.stableKey] = @((self.adaptiveSampling && stable) ? LumenIdleSampleInterval : LumenActiveSampleInterval);
                }

                state.latestLightness = lightness;
                state.latestLightnessTime = now;
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

                BOOL shouldRunFullControl = forcedRefresh || lightnessChanged || state.lastFullControlTime <= 0 || now - state.lastFullControlTime >= LumenForceControlInterval;
                if (!shouldRunFullControl) {
                    [self setAction:@"skipped: unchanged" reason:@"lightness unchanged within tolerance" display:display state:state];
                } else if (![self checkIgnoreList]) {
                    state.lastFullControlTime = now;
                    [self processLightness:lightness forDisplay:display];
                }
            }
        }

        self.lastControlLoopDuration = [NSDate timeIntervalSinceReferenceDate] - controlStartedAt;
        LumenDisplayState *finalState = self.displayStatesByKey[displayKey];
        finalState.lastSampleProcessingDuration = [NSDate timeIntervalSinceReferenceDate] - sampleProcessingStartedAt;
        if (signpostsEnabled) {
            os_signpost_interval_end(LumenPerformanceLog(), controlSignpostID, "Control Loop", "duration=%{public}.6f", self.lastControlLoopDuration);
        }
        [self updateDebugSnapshotAfterSample];
        [self finishProcessingSampleForDisplayKey:displayKey];
        if (signpostsEnabled) {
            os_signpost_interval_end(LumenPerformanceLog(), sampleSignpostID, "Sample Processing", "duration=%{public}.6f", finalState.lastSampleProcessingDuration);
        }
    });
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    if (error) {
        os_log_error(LumenDebugLog(), "Stream stopped with error: %{public}@", error.localizedDescription);
    }
    __block NSString *displayKey = nil;
    @synchronized (self.displayKeyByStream) {
        displayKey = self.displayKeyByStream[[NSValue valueWithNonretainedObject:stream]];
    }
    if (displayKey) {
        dispatch_async(self.controllerQueue, ^{
            LumenDisplay *display = [self displayForKey:displayKey];
            LumenDisplayState *state = self.displayStatesByKey[displayKey];
            state.captureActive = NO;
            state.captureStatus = error ? @"stopped with error" : @"stopped";
            [self addDebugEvent:error ? [NSString stringWithFormat:@"capture stopped: %@", error.localizedDescription] : @"capture stopped"
                        display:display];
            [self.streamsByDisplayKey removeObjectForKey:displayKey];
            @synchronized (self.displayKeyByStream) {
                [self.displayKeyByStream removeObjectForKey:[NSValue valueWithNonretainedObject:stream]];
            }
            [self updateDebugSnapshot];
        });
    }
}

@end
