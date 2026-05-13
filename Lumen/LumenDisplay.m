// Copyright (c) Anish Athalye (me@anishathalye.com)
// Released under GPLv3. See the included LICENSE.txt for details

#import "LumenDisplay.h"
#import <AppKit/AppKit.h>
#import <IOKit/graphics/IOGraphicsLib.h>

@implementation LumenDisplay

+ (NSArray<LumenDisplay *> *)activeDisplays {
    uint32_t displayCount = 0;
    CGError countError = CGGetActiveDisplayList(0, NULL, &displayCount);
    if (countError != kCGErrorSuccess || displayCount == 0) {
        NSLog(@"Display discovery failed while counting active displays: %d", countError);
        return @[];
    }

    CGDirectDisplayID displayIDs[displayCount];
    CGError listError = CGGetActiveDisplayList(displayCount, displayIDs, &displayCount);
    if (listError != kCGErrorSuccess) {
        NSLog(@"Display discovery failed while listing active displays: %d", listError);
        return @[];
    }

    NSMutableArray<LumenDisplay *> *displays = [NSMutableArray arrayWithCapacity:displayCount];
    for (uint32_t i = 0; i < displayCount; i++) {
        CGDirectDisplayID displayID = displayIDs[i];
        NSString *stableKey = [self stableKeyForDisplayID:displayID];
        NSString *displayName = [self displayNameForDisplayID:displayID];
        BOOL builtin = CGDisplayIsBuiltin(displayID);
        CGRect bounds = CGDisplayBounds(displayID);

        LumenDisplay *display = [[LumenDisplay alloc] initWithDisplayID:displayID
                                                              stableKey:stableKey
                                                            displayName:displayName
                                                                builtin:builtin
                                                                 bounds:bounds];
        [displays addObject:display];
        NSLog(@"Discovered display name='%@' id=%u key=%@ builtin=%@ bounds=%@",
              display.displayName,
              display.displayID,
              display.stableKey,
              display.builtin ? @"YES" : @"NO",
              NSStringFromRect(NSRectFromCGRect(display.bounds)));
    }

    return displays;
}

- (instancetype)initWithDisplayID:(CGDirectDisplayID)displayID
                        stableKey:(NSString *)stableKey
                      displayName:(NSString *)displayName
                          builtin:(BOOL)builtin
                           bounds:(CGRect)bounds {
    self = [super init];
    if (self) {
        _displayID = displayID;
        _stableKey = [stableKey copy];
        _displayName = [displayName copy];
        _builtin = builtin;
        _bounds = bounds;
        _brightnessControllable = NO;
        _brightnessBackendName = @"unsupported";
    }
    return self;
}

+ (NSString *)stableKeyForDisplayID:(CGDirectDisplayID)displayID {
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(displayID);
    if (uuid) {
        CFStringRef uuidString = CFUUIDCreateString(kCFAllocatorDefault, uuid);
        CFRelease(uuid);
        if (uuidString) {
            return CFBridgingRelease(uuidString);
        }
    }

    uint32_t vendor = CGDisplayVendorNumber(displayID);
    uint32_t model = CGDisplayModelNumber(displayID);
    uint32_t serial = CGDisplaySerialNumber(displayID);
    return [NSString stringWithFormat:@"vendor-%u-model-%u-serial-%u-display-%u",
            vendor,
            model,
            serial,
            displayID];
}

+ (NSString *)displayNameForDisplayID:(CGDirectDisplayID)displayID {
    for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *screenDisplayID = screen.deviceDescription[@"NSScreenNumber"];
        if (screenDisplayID && screenDisplayID.unsignedIntValue == displayID) {
            if (screen.localizedName.length > 0) {
                return screen.localizedName;
            }
        }
    }

    if (CGDisplayIsBuiltin(displayID)) {
        return @"Built-in Display";
    }

    return [NSString stringWithFormat:@"Display %u", displayID];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p name='%@' id=%u key=%@ builtin=%@ controllable=%@ backend=%@>",
            NSStringFromClass([self class]),
            self,
            self.displayName,
            self.displayID,
            self.stableKey,
            self.builtin ? @"YES" : @"NO",
            self.brightnessControllable ? @"YES" : @"NO",
            self.brightnessBackendName];
}

@end
