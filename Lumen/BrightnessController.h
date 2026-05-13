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

@end
