// Copyright (c) Anish Athalye (me@anishathalye.com)
// Released under GPLv3. See the included LICENSE.txt for details

#import "AppDelegate.h"
#import "Constants.h"
#import "BrightnessController.h"
#import "stats.h"
#import "IgnoreListWindowController.h"
#import "DebugPanelWindowController.h"

@interface AppDelegate ()

@property (strong, nonatomic) IBOutlet NSMenu *statusMenu;
@property (strong, nonatomic) IBOutlet NSMenuItem *toggle;
@property (strong, nonatomic) NSStatusItem *statusItem;
@property (strong, nonatomic) BrightnessController *brightnessController;
@property (nonatomic, strong) NSTimer *statsTimer;
@property (nonatomic, strong) NSTimer *displayStatusTimer;
@property (strong, nonatomic) NSMenuItem *displayStatusMenuItem;
@property (strong, nonatomic) NSMenuItem *debugPanelMenuItem;
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
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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
    [self updateDebugPanelMenuItem];
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
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:DEFAULTS_DEBUG_PANEL_VISIBLE];
    [self updateDebugPanelMenuItem];
}

- (void)hideDebugPanel {
    [self.debugPanelWC hidePanel];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:DEFAULTS_DEBUG_PANEL_VISIBLE];
    [self updateDebugPanelMenuItem];
}

- (void)debugPanelVisibilityChanged:(NSNotification *)notification {
    BOOL visible = self.debugPanelWC.window.visible;
    [[NSUserDefaults standardUserDefaults] setBool:visible forKey:DEFAULTS_DEBUG_PANEL_VISIBLE];
    [self updateDebugPanelMenuItem];
}

- (void)updateDebugPanelMenuItem {
    BOOL visible = self.debugPanelWC.window.visible;
    self.debugPanelMenuItem.title = visible ? @"Hide Debug Panel" : @"Show Debug Panel";
    self.debugPanelMenuItem.state = visible ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)displayStatusTick:(NSTimer *)timer {
    [self updateDisplayStatusMenu];
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
        [menu addItem:item];
    }
}

- (NSString *)formattedStatusNumber:(id)value {
    if (![value isKindOfClass:[NSNumber class]] || [value floatValue] < 0) {
        return @"?";
    }
    return [NSString stringWithFormat:@"%.2f", [value floatValue]];
}

@end
