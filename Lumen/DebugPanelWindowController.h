// Copyright (c) Anish Athalye (me@anishathalye.com)
// Released under GPLv3. See the included LICENSE.txt for details

#import <Cocoa/Cocoa.h>

@class BrightnessController;

extern NSString * const LumenDebugPanelVisibilityChangedNotification;

@interface DebugPanelWindowController : NSWindowController

- (instancetype)initWithBrightnessController:(BrightnessController *)brightnessController;
- (void)showPanel;
- (void)hidePanel;

@end
