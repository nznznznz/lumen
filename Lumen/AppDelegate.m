// Copyright (c) Anish Athalye (me@anishathalye.com)
// Released under GPLv3. See the included LICENSE.txt for details

#import "AppDelegate.h"
#import "Constants.h"
#import "BrightnessController.h"
#import "stats.h"
#import "IgnoreListWindowController.h"
#import "DebugPanelWindowController.h"
#import <math.h>

@interface AppDelegate ()

@property (strong, nonatomic) IBOutlet NSMenu *statusMenu;
@property (strong, nonatomic) IBOutlet NSMenuItem *toggle;
@property (strong, nonatomic) NSStatusItem *statusItem;
@property (strong, nonatomic) BrightnessController *brightnessController;
@property (nonatomic, strong) NSTimer *statsTimer;
@property (nonatomic, strong) NSTimer *displayStatusTimer;
@property (strong, nonatomic) NSMenuItem *displayStatusMenuItem;
@property (strong, nonatomic) NSMenuItem *debugPanelMenuItem;
@property (strong, nonatomic) NSMenuItem *disableExternalOverlaysMenuItem;
@property (strong, nonatomic) NSMenuItem *enableExternalOverlaysMenuItem;
@property (strong, nonatomic) NSMenuItem *resetExternalOverlayCalibrationMenuItem;
@property (strong, nonatomic) NSMenuItem *hideExternalOverlaysForScreenshotMenuItem;
@property (strong, nonatomic) NSMenuItem *restoreExternalOverlaysMenuItem;
@property (strong, nonatomic) NSMenuItem *resetCalibrationMenuItem;
@property (strong, nonatomic) NSMenuItem *samplingRateMenuItem;
@property (strong, nonatomic) NSMenuItem *adaptiveSamplingMenuItem;
@property (strong, nonatomic) NSArray<NSMenuItem *> *samplingRateItems;
@property (strong, nonatomic) IgnoreListWindowController *ignoreListWC;
@property (strong, nonatomic) DebugPanelWindowController *debugPanelWC;

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
		self.statusItem.button.image = [NSImage imageNamed:@"StatusBarIcon"];
    [self.statusItem setMenu:self.statusMenu];

    self.brightnessController = [BrightnessController new];
    [self.brightnessController start];
    [self.toggle setTitle:STOP];
    [self setupDisplayStatusMenu];
    [self setupDebugPanelMenu];

    send_stats(TELEMETRY_RETRIES);
    self.statsTimer = [NSTimer scheduledTimerWithTimeInterval:TELEMETRY_INTERVAL
                                                  target:self
                                                selector:@selector(statsTick:)
                                                userInfo:nil
                                                 repeats:YES];
    self.displayStatusTimer = [NSTimer scheduledTimerWithTimeInterval:2
                                                               target:self
                                                             selector:@selector(displayStatusTick:)
                                                             userInfo:nil
                                                              repeats:YES];
    [self updateDisplayStatusMenu];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(debugPanelVisibilityChanged:)
                                                 name:LumenDebugPanelVisibilityChangedNotification
                                               object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                           selector:@selector(workspaceApplicationActivated:)
                                                               name:NSWorkspaceDidActivateApplicationNotification
                                                             object:nil];
    if ([[NSUserDefaults standardUserDefaults] boolForKey:DEFAULTS_DEBUG_PANEL_VISIBLE]) {
        [self showDebugPanel];
    }
}

- (void)statsTick:(NSTimer *)timer {
    send_stats(TELEMETRY_RETRIES);
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    [self.displayStatusTimer invalidate];
    [self.statsTimer invalidate];
    [self.brightnessController stop];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
}

- (IBAction)menuActionQuit:(id)sender {
    [NSApp terminate:self];
}

- (IBAction)menuActionToggle:(id)sender {
    if (self.brightnessController.isRunning) {
        [self.brightnessController stop];
        [self.toggle setTitle:START];
    } else {
        [self.brightnessController start];
        [self.toggle setTitle:STOP];
    }
}

- (IBAction)menuActionIgnoreList:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];

    if (self.ignoreListWC) {
        // refocus if the ignore list window is still around.
        [self.ignoreListWC.window orderFrontRegardless];
    } else {
        self.ignoreListWC = [[IgnoreListWindowController alloc] init];
        [self.ignoreListWC showWindow:nil];
        [self.ignoreListWC.window center];
    }
}

- (void)setupDisplayStatusMenu {
    self.displayStatusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Displays" action:nil keyEquivalent:@""];
    self.displayStatusMenuItem.submenu = [[NSMenu alloc] initWithTitle:@"Displays"];
    [self.statusMenu insertItem:self.displayStatusMenuItem atIndex:2];
}

- (void)setupDebugPanelMenu {
    self.debugPanelMenuItem = [[NSMenuItem alloc] initWithTitle:@"Show Debug Panel"
                                                         action:@selector(menuActionToggleDebugPanel:)
                                                  keyEquivalent:@""];
    self.debugPanelMenuItem.target = self;
    [self.statusMenu insertItem:self.debugPanelMenuItem atIndex:3];
    self.disableExternalOverlaysMenuItem = [[NSMenuItem alloc] initWithTitle:@"Disable External Overlays"
                                                                      action:@selector(menuActionDisableExternalOverlays:)
                                                               keyEquivalent:@""];
    self.disableExternalOverlaysMenuItem.target = self;
    [self.statusMenu insertItem:self.disableExternalOverlaysMenuItem atIndex:4];
    self.enableExternalOverlaysMenuItem = [[NSMenuItem alloc] initWithTitle:@"Enable External Overlays"
                                                                     action:@selector(menuActionEnableExternalOverlays:)
                                                              keyEquivalent:@""];
    self.enableExternalOverlaysMenuItem.target = self;
    [self.statusMenu insertItem:self.enableExternalOverlaysMenuItem atIndex:5];
    self.resetExternalOverlayCalibrationMenuItem = [[NSMenuItem alloc] initWithTitle:@"Reset External Overlay Calibration"
                                                                              action:@selector(menuActionResetExternalOverlayCalibration:)
                                                                       keyEquivalent:@""];
    self.resetExternalOverlayCalibrationMenuItem.target = self;
    [self.statusMenu insertItem:self.resetExternalOverlayCalibrationMenuItem atIndex:6];
    self.hideExternalOverlaysForScreenshotMenuItem = [[NSMenuItem alloc] initWithTitle:@"Hide External Overlays for Screenshot"
                                                                                action:@selector(menuActionHideExternalOverlaysForScreenshot:)
                                                                         keyEquivalent:@"H"];
    self.hideExternalOverlaysForScreenshotMenuItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagShift;
    self.hideExternalOverlaysForScreenshotMenuItem.target = self;
    [self.statusMenu insertItem:self.hideExternalOverlaysForScreenshotMenuItem atIndex:7];
    self.restoreExternalOverlaysMenuItem = [[NSMenuItem alloc] initWithTitle:@"Restore External Overlays"
                                                                      action:@selector(menuActionRestoreExternalOverlays:)
                                                               keyEquivalent:@""];
    self.restoreExternalOverlaysMenuItem.target = self;
    [self.statusMenu insertItem:self.restoreExternalOverlaysMenuItem atIndex:8];
    self.resetCalibrationMenuItem = [[NSMenuItem alloc] initWithTitle:@"Reset Learned Calibration"
                                                               action:@selector(menuActionResetLearnedCalibration:)
                                                        keyEquivalent:@""];
    self.resetCalibrationMenuItem.target = self;
    [self.statusMenu insertItem:self.resetCalibrationMenuItem atIndex:9];
    self.samplingRateMenuItem = [[NSMenuItem alloc] initWithTitle:@"Sampling Rate" action:nil keyEquivalent:@""];
    self.samplingRateMenuItem.submenu = [[NSMenu alloc] initWithTitle:@"Sampling Rate"];
    [self.statusMenu insertItem:self.samplingRateMenuItem atIndex:10];
    [self buildSamplingRateMenu];
    self.adaptiveSamplingMenuItem = [[NSMenuItem alloc] initWithTitle:@"Adaptive Sampling"
                                                               action:@selector(menuActionToggleAdaptiveSampling:)
                                                        keyEquivalent:@""];
    self.adaptiveSamplingMenuItem.target = self;
    [self.statusMenu insertItem:self.adaptiveSamplingMenuItem atIndex:11];
    [self updateDebugPanelMenuItem];
    [self updateExternalOverlayMenuItems];
    [self updateSamplingMenuItems];
}

- (void)buildSamplingRateMenu {
    NSMenu *menu = self.samplingRateMenuItem.submenu;
    [menu removeAllItems];
    NSArray<NSDictionary<NSString *, id> *> *items = @[
        @{@"title": @"Low Power: 0.5 fps", @"fps": @0.5},
        @{@"title": @"Balanced: 1 fps", @"fps": @1.0},
        @{@"title": @"Responsive: 2 fps", @"fps": @2.0},
        @{@"title": @"High: 4 fps", @"fps": @4.0},
    ];
    NSMutableArray<NSMenuItem *> *rateItems = [NSMutableArray new];
    for (NSDictionary<NSString *, id> *itemInfo in items) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:itemInfo[@"title"]
                                                      action:@selector(menuActionSetSamplingRate:)
                                               keyEquivalent:@""];
        item.target = self;
        item.representedObject = itemInfo[@"fps"];
        [menu addItem:item];
        [rateItems addObject:item];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *customItem = [[NSMenuItem alloc] initWithTitle:@"Custom..."
                                                        action:@selector(menuActionSetCustomSamplingRate:)
                                                 keyEquivalent:@""];
    customItem.target = self;
    [menu addItem:customItem];
    self.samplingRateItems = rateItems.copy;
}

- (IBAction)menuActionToggleDebugPanel:(id)sender {
    if (self.debugPanelWC.window.visible) {
        [self hideDebugPanel];
    } else {
        [self showDebugPanel];
    }
}

- (void)showDebugPanel {
    if (!self.debugPanelWC) {
        self.debugPanelWC = [[DebugPanelWindowController alloc] initWithBrightnessController:self.brightnessController];
    }
    [self.debugPanelWC showPanel];
    [self setDebugPanelVisibleDefault:YES];
    [self updateDebugPanelMenuItem];
}

- (void)hideDebugPanel {
    [self.debugPanelWC hidePanel];
    [self setDebugPanelVisibleDefault:NO];
    [self updateDebugPanelMenuItem];
}

- (void)debugPanelVisibilityChanged:(NSNotification *)notification {
    BOOL visible = self.debugPanelWC.window.visible;
    [self setDebugPanelVisibleDefault:visible];
    [self updateDebugPanelMenuItem];
}

- (IBAction)menuActionDisableExternalOverlays:(id)sender {
    [self.brightnessController setExternalSoftwareDimmingEnabled:NO];
    [self updateExternalOverlayMenuItems];
}

- (IBAction)menuActionEnableExternalOverlays:(id)sender {
    [self.brightnessController setExternalSoftwareDimmingEnabled:YES];
    [self updateExternalOverlayMenuItems];
}

- (IBAction)menuActionResetExternalOverlayCalibration:(id)sender {
    [self.brightnessController resetExternalOverlayCalibration];
}

- (IBAction)menuActionHideExternalOverlaysForScreenshot:(id)sender {
    [self.brightnessController temporarilyHideExternalOverlaysForScreenshot];
}

- (IBAction)menuActionRestoreExternalOverlays:(id)sender {
    [self.brightnessController restoreExternalOverlays];
}

- (void)setDebugPanelVisibleDefault:(BOOL)visible {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[NSUserDefaults standardUserDefaults] setBool:visible forKey:DEFAULTS_DEBUG_PANEL_VISIBLE];
    });
}

- (IBAction)menuActionResetLearnedCalibration:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Reset learned calibration?";
    alert.informativeText = @"This clears displayCalibrationPoints and calibrationPoints from Lumen defaults. Brightness baselines will be reinitialised from fresh display reads.";
    [alert addButtonWithTitle:@"Reset"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }

    [self.brightnessController resetLearnedCalibrationForDebug];
    [self updateDisplayStatusMenu];
}

- (void)updateDebugPanelMenuItem {
    BOOL visible = self.debugPanelWC.window.visible;
    self.debugPanelMenuItem.title = visible ? @"Hide Debug Panel" : @"Show Debug Panel";
    self.debugPanelMenuItem.state = visible ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)updateExternalOverlayMenuItems {
    BOOL enabled = [self.brightnessController externalSoftwareDimmingEnabled];
    self.disableExternalOverlaysMenuItem.enabled = enabled;
    self.enableExternalOverlaysMenuItem.enabled = !enabled;
    self.disableExternalOverlaysMenuItem.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.enableExternalOverlaysMenuItem.state = enabled ? NSControlStateValueOff : NSControlStateValueOn;
}

- (void)updateSamplingMenuItems {
    double currentFPS = [self.brightnessController samplingFPS];
    for (NSMenuItem *item in self.samplingRateItems) {
        double fps = [item.representedObject doubleValue];
        item.state = fabs(currentFPS - fps) < 0.01 ? NSControlStateValueOn : NSControlStateValueOff;
    }
    self.samplingRateMenuItem.title = [NSString stringWithFormat:@"Sampling Rate: %@", [self.brightnessController samplingModeName]];
    self.adaptiveSamplingMenuItem.state = [self.brightnessController adaptiveSamplingEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
}

- (IBAction)menuActionSetSamplingRate:(NSMenuItem *)sender {
    [self.brightnessController setSamplingFPS:[sender.representedObject doubleValue]];
    [self updateSamplingMenuItems];
}

- (IBAction)menuActionSetCustomSamplingRate:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Custom sampling FPS";
    alert.informativeText = @"Enter a maximum analysis rate from 0.2 to 4 fps.";
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 180, 24)];
    input.stringValue = [NSString stringWithFormat:@"%.2f", [self.brightnessController samplingFPS]];
    alert.accessoryView = input;
    [alert addButtonWithTitle:@"Set"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }
    double fps = input.doubleValue;
    if (fps <= 0) {
        return;
    }
    [self.brightnessController setSamplingFPS:fps];
    [self updateSamplingMenuItems];
}

- (IBAction)menuActionToggleAdaptiveSampling:(id)sender {
    [self.brightnessController setAdaptiveSamplingEnabled:![self.brightnessController adaptiveSamplingEnabled]];
    [self updateSamplingMenuItems];
}

- (void)displayStatusTick:(NSTimer *)timer {
    if ([self screenshotUIIsRunning]) {
        [self.brightnessController temporarilyHideExternalOverlaysForScreenshot];
    }
    [self updateExternalOverlayMenuItems];
    [self updateSamplingMenuItems];
    [self updateDisplayStatusMenu];
}

- (void)workspaceApplicationActivated:(NSNotification *)notification {
    NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];
    NSString *bundleIdentifier = application.bundleIdentifier ?: @"";
    NSString *name = application.localizedName ?: @"";
    if ([bundleIdentifier isEqualToString:@"com.apple.screenshot"] ||
        [bundleIdentifier isEqualToString:@"com.apple.screencapture"] ||
        [name caseInsensitiveCompare:@"Screenshot"] == NSOrderedSame ||
        [name rangeOfString:@"screencapture" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        [self.brightnessController temporarilyHideExternalOverlaysForScreenshot];
    }
}

- (BOOL)screenshotUIIsRunning {
    for (NSRunningApplication *application in [NSWorkspace sharedWorkspace].runningApplications) {
        NSString *bundleIdentifier = application.bundleIdentifier ?: @"";
        NSString *name = application.localizedName ?: @"";
        if ([bundleIdentifier rangeOfString:@"screenshot" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [bundleIdentifier rangeOfString:@"screencapture" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [name rangeOfString:@"Screenshot" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [name rangeOfString:@"screencapture" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [name rangeOfString:@"screencaptureui" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

- (void)updateDisplayStatusMenu {
    NSMenu *menu = self.displayStatusMenuItem.submenu;
    [menu removeAllItems];

    NSArray<NSDictionary<NSString *, id> *> *statuses = [self.brightnessController displayDebugStatuses];
    if (statuses.count == 0) {
        [menu addItemWithTitle:@"No active displays" action:nil keyEquivalent:@""];
        return;
    }

    for (NSDictionary<NSString *, id> *status in statuses) {
        NSString *lightness = [self formattedStatusNumber:status[@"lightness"]];
        NSString *brightness = [self formattedStatusNumber:status[@"brightness"]];
        NSString *title = [NSString stringWithFormat:@"%@%@ | %@ | L* %@ | B %@ | %@",
                           [status[@"builtin"] boolValue] ? @"Built-in: " : @"External: ",
                           status[@"name"],
                           [status[@"controllable"] boolValue] ? status[@"backend"] : @"unsupported",
                           lightness,
                           brightness,
                           [status[@"learned"] boolValue] ? @"learned" : @"default"];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        item.toolTip = [NSString stringWithFormat:@"displayID=%@ key=%@",
                        status[@"displayID"],
                        status[@"key"]];
        if (![status[@"builtin"] boolValue] && [status[@"backend"] isEqualToString:@"Software Overlay"]) {
            item.submenu = [self overlayControlsMenuForDisplayStatus:status];
        }
        [menu addItem:item];
    }
}

- (NSMenu *)overlayControlsMenuForDisplayStatus:(NSDictionary<NSString *, id> *)status {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:status[@"name"] ?: @"External Display"];
    NSString *displayKey = status[@"key"];
    NSArray<NSDictionary<NSString *, NSString *> *> *items = @[
        @{@"title": @"Brighter Overlay", @"action": NSStringFromSelector(@selector(menuActionOverlayBrighter:))},
        @{@"title": @"Darker Overlay", @"action": NSStringFromSelector(@selector(menuActionOverlayDarker:))},
        @{@"title": @"Learn Current Overlay", @"action": NSStringFromSelector(@selector(menuActionOverlayLearnCurrent:))},
        @{@"title": @"Reset Overlay Calibration", @"action": NSStringFromSelector(@selector(menuActionOverlayReset:))},
    ];
    for (NSDictionary<NSString *, NSString *> *itemInfo in items) {
        SEL action = NSSelectorFromString(itemInfo[@"action"]);
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:itemInfo[@"title"] action:action keyEquivalent:@""];
        item.target = self;
        item.representedObject = displayKey;
        [menu addItem:item];
    }
    return menu;
}

- (IBAction)menuActionOverlayBrighter:(NSMenuItem *)sender {
    [self.brightnessController adjustOverlayForDisplayKey:sender.representedObject brighter:YES];
}

- (IBAction)menuActionOverlayDarker:(NSMenuItem *)sender {
    [self.brightnessController adjustOverlayForDisplayKey:sender.representedObject brighter:NO];
}

- (IBAction)menuActionOverlayLearnCurrent:(NSMenuItem *)sender {
    [self.brightnessController learnCurrentOverlayForDisplayKey:sender.representedObject];
}

- (IBAction)menuActionOverlayReset:(NSMenuItem *)sender {
    [self.brightnessController resetOverlayCalibrationForDisplayKey:sender.representedObject];
}

- (NSString *)formattedStatusNumber:(id)value {
    if (![value isKindOfClass:[NSNumber class]] || [value floatValue] < 0) {
        return @"?";
    }
    return [NSString stringWithFormat:@"%.2f", [value floatValue]];
}

@end
