// Copyright (c) Anish Athalye (me@anishathalye.com)
// Released under GPLv3. See the included LICENSE.txt for details

#import <Foundation/Foundation.h>

@class LumenDisplay;

@interface BrightnessController : NSObject

@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, strong, readonly) NSArray<LumenDisplay *> *activeDisplays;
@property (nonatomic, strong, readonly) NSDictionary<NSString *, NSNumber *> *currentLightnessByDisplayKey;

- (void)start;
- (void)stop;

- (BOOL)canControlBrightnessForDisplay:(LumenDisplay *)display;
- (float)brightnessForDisplay:(LumenDisplay *)display error:(NSError **)error;
- (BOOL)setBrightness:(float)brightness forDisplay:(LumenDisplay *)display error:(NSError **)error;
- (NSArray<NSDictionary<NSString *, id> *> *)displayDebugStatuses;
- (NSDictionary<NSString *, id> *)debugSnapshot;
- (NSString *)debugSnapshotText;
- (void)recordDebugPanelRenderDuration:(NSTimeInterval)duration;
- (void)resetLearnedCalibrationForDebug;
- (BOOL)externalSoftwareDimmingEnabled;
- (void)setExternalSoftwareDimmingEnabled:(BOOL)enabled;
- (void)resetExternalOverlayCalibration;
- (void)temporarilyHideExternalOverlaysForScreenshot;
- (void)restoreExternalOverlays;
- (NSArray<NSDictionary<NSString *, id> *> *)externalOverlayControlTargets;
- (void)adjustOverlayForDisplayKey:(NSString *)displayKey brighter:(BOOL)brighter;
- (void)learnCurrentOverlayForDisplayKey:(NSString *)displayKey;
- (void)resetOverlayCalibrationForDisplayKey:(NSString *)displayKey;
- (double)samplingFPS;
- (void)setSamplingFPS:(double)fps;
- (NSString *)samplingModeName;
- (BOOL)adaptiveSamplingEnabled;
- (void)setAdaptiveSamplingEnabled:(BOOL)enabled;

@end
