// Copyright (c) Anish Athalye (me@anishathalye.com)
// Released under GPLv3. See the included LICENSE.txt for details

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface LumenDisplay : NSObject

@property (nonatomic, assign, readonly) CGDirectDisplayID displayID;
@property (nonatomic, copy, readonly) NSString *stableKey;
@property (nonatomic, copy, readonly) NSString *displayName;
@property (nonatomic, assign, readonly) BOOL builtin;
@property (nonatomic, assign, readonly) CGRect bounds;
@property (nonatomic, assign) BOOL brightnessControllable;
@property (nonatomic, copy) NSString *brightnessBackendName;

+ (NSArray<LumenDisplay *> *)activeDisplays;

- (instancetype)initWithDisplayID:(CGDirectDisplayID)displayID
                        stableKey:(NSString *)stableKey
                      displayName:(NSString *)displayName
                          builtin:(BOOL)builtin
                           bounds:(CGRect)bounds;

@end
