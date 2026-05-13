// Copyright (c) Anish Athalye (me@anishathalye.com)
// Released under GPLv3. See the included LICENSE.txt for details

#import "DebugPanelWindowController.h"
#import "BrightnessController.h"
#import "Constants.h"

NSString * const LumenDebugPanelVisibilityChangedNotification = @"LumenDebugPanelVisibilityChangedNotification";

@interface DebugPanelWindowController () <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>

@property (nonatomic, weak) BrightnessController *brightnessController;
@property (nonatomic, strong) NSTableView *displayTable;
@property (nonatomic, strong) NSTextView *detailTextView;
@property (nonatomic, strong) NSTextView *eventTextView;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) NSArray<NSDictionary<NSString *, id> *> *displaySnapshots;
@property (nonatomic, strong) NSArray<NSDictionary<NSString *, id> *> *eventSnapshots;
@property (nonatomic, copy) NSString *selectedDisplayKey;

@end

@implementation DebugPanelWindowController

- (instancetype)initWithBrightnessController:(BrightnessController *)brightnessController {
    NSRect frame = NSMakeRect(200, 200, 920, 520);
    NSString *savedFrame = [[NSUserDefaults standardUserDefaults] stringForKey:DEFAULTS_DEBUG_PANEL_FRAME];
    if (savedFrame.length > 0) {
        frame = NSRectFromString(savedFrame);
    }

    NSPanel *panel = [[NSPanel alloc] initWithContentRect:frame
                                                styleMask:(NSWindowStyleMaskTitled |
                                                           NSWindowStyleMaskClosable |
                                                           NSWindowStyleMaskResizable |
                                                           NSWindowStyleMaskMiniaturizable)
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    panel.title = @"Lumen Debug";
    panel.level = NSFloatingWindowLevel;
    panel.hidesOnDeactivate = NO;
    panel.releasedWhenClosed = NO;
    panel.minSize = NSMakeSize(700, 380);

    self = [super initWithWindow:panel];
    if (self) {
        self.brightnessController = brightnessController;
        self.displaySnapshots = @[];
        self.eventSnapshots = @[];
        panel.delegate = self;
        [self buildUI];
    }
    return self;
}

- (void)showPanel {
    [self refresh:nil];
    [self.window makeKeyAndOrderFront:nil];
    [self startRefreshTimer];
    [self notifyVisibilityChanged];
}

- (void)hidePanel {
    [self.window orderOut:nil];
    [self stopRefreshTimer];
    [self saveFrame];
    [self notifyVisibilityChanged];
}

- (void)buildUI {
    NSView *contentView = self.window.contentView;

    NSStackView *root = [[NSStackView alloc] initWithFrame:contentView.bounds];
    root.orientation = NSUserInterfaceLayoutOrientationVertical;
    root.spacing = 8;
    root.edgeInsets = NSEdgeInsetsMake(10, 10, 10, 10);
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:root];

    [NSLayoutConstraint activateConstraints:@[
        [root.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor],
        [root.topAnchor constraintEqualToAnchor:contentView.topAnchor],
        [root.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor],
    ]];

    NSScrollView *tableScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    tableScrollView.hasVerticalScroller = YES;
    tableScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.displayTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.displayTable.delegate = self;
    self.displayTable.dataSource = self;
    self.displayTable.usesAlternatingRowBackgroundColors = YES;
    self.displayTable.headerView = [[NSTableHeaderView alloc] initWithFrame:NSZeroRect];
    [self addColumn:@"display" title:@"Display" width:180];
    [self addColumn:@"role" title:@"Role" width:105];
    [self addColumn:@"lightness" title:@"Lightness" width:80];
    [self addColumn:@"brightness" title:@"Brightness" width:85];
    [self addColumn:@"target" title:@"Target" width:70];
    [self addColumn:@"action" title:@"Action" width:140];
    [self addColumn:@"actionReason" title:@"Skip Reason" width:180];
    [self addColumn:@"model" title:@"Model" width:105];
    [self addColumn:@"lastLearn" title:@"Last Learn" width:135];
    tableScrollView.documentView = self.displayTable;
    [root addArrangedSubview:tableScrollView];
    [tableScrollView.heightAnchor constraintEqualToConstant:150].active = YES;

    NSSplitView *splitView = [[NSSplitView alloc] initWithFrame:NSZeroRect];
    splitView.vertical = NO;
    splitView.dividerStyle = NSSplitViewDividerStyleThin;
    splitView.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextView *detailTextView = nil;
    NSTextView *eventTextView = nil;
    NSScrollView *detailScrollView = [self scrollViewForTextView:&detailTextView];
    NSScrollView *eventScrollView = [self scrollViewForTextView:&eventTextView];
    self.detailTextView = detailTextView;
    self.eventTextView = eventTextView;
    [splitView addSubview:detailScrollView];
    [splitView addSubview:eventScrollView];
    [root addArrangedSubview:splitView];

    NSButton *copyButton = [NSButton buttonWithTitle:@"Copy Debug State"
                                             target:self
                                             action:@selector(copyDebugState:)];
    copyButton.bezelStyle = NSBezelStyleRounded;
    [root addArrangedSubview:copyButton];
}

- (NSScrollView *)scrollViewForTextView:(NSTextView **)textViewPointer {
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = YES;
    NSTextView *textView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    textView.editable = NO;
    textView.selectable = YES;
    textView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    textView.textContainerInset = NSMakeSize(6, 6);
    scrollView.documentView = textView;
    *textViewPointer = textView;
    return scrollView;
}

- (void)addColumn:(NSString *)identifier title:(NSString *)title width:(CGFloat)width {
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
    column.title = title;
    column.width = width;
    column.minWidth = 55;
    [self.displayTable addTableColumn:column];
}

- (void)startRefreshTimer {
    if (self.refreshTimer) {
        return;
    }
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                         target:self
                                                       selector:@selector(refresh:)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)stopRefreshTimer {
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)refresh:(NSTimer *)timer {
    NSDictionary *snapshot = [self.brightnessController debugSnapshot];
    NSArray *displays = snapshot[@"displays"];
    NSArray *events = snapshot[@"events"];
    self.displaySnapshots = [displays isKindOfClass:[NSArray class]] ? displays : @[];
    self.eventSnapshots = [events isKindOfClass:[NSArray class]] ? events : @[];

    if (!self.selectedDisplayKey && self.displaySnapshots.count > 0) {
        self.selectedDisplayKey = self.displaySnapshots[0][@"key"];
    }
    [self.displayTable reloadData];
    [self updateSelection];
    [self updateDetailText];
    [self updateEventText];
}

- (void)updateSelection {
    NSInteger selectedIndex = -1;
    for (NSUInteger i = 0; i < self.displaySnapshots.count; i++) {
        if ([self.displaySnapshots[i][@"key"] isEqualToString:self.selectedDisplayKey]) {
            selectedIndex = (NSInteger)i;
            break;
        }
    }
    if (selectedIndex >= 0 && self.displayTable.selectedRow != selectedIndex) {
        [self.displayTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)selectedIndex] byExtendingSelection:NO];
    }
}

- (void)updateDetailText {
    NSDictionary *display = [self selectedDisplaySnapshot];
    if (!display) {
        self.detailTextView.string = @"No display selected";
        return;
    }

    NSArray<NSString *> *lines = @[
        [self detailLine:@"stable display key" value:display[@"key"]],
        [self detailLine:@"debug key" value:display[@"debugKey"]],
        [self detailLine:@"CGDirectDisplayID" value:display[@"displayID"]],
        [self detailLine:@"bounds/frame" value:display[@"bounds"]],
        [self detailLine:@"scale factor" value:[self formattedNumber:display[@"scaleFactor"] digits:2]],
        [self detailLine:@"capture status" value:display[@"captureStatus"]],
        [self detailLine:@"brightness backend" value:display[@"backend"]],
        [self detailLine:@"can read brightness" value:[self yesNo:display[@"canReadBrightness"]]],
        [self detailLine:@"can set brightness" value:[self yesNo:display[@"canSetBrightness"]]],
        [self detailLine:@"last read brightness" value:[self formattedNumber:display[@"lastReadBrightness"] digits:3]],
        [self detailLine:@"last written brightness" value:[self formattedNumber:display[@"lastWrittenBrightness"] digits:3]],
        [self detailLine:@"last write timestamp" value:[self formattedTime:display[@"lastWriteTimestamp"]]],
        [self detailLine:@"last write error" value:[self dashIfEmpty:display[@"lastWriteError"]]],
        [self detailLine:@"current lightness" value:[self formattedNumber:display[@"lightness"] digits:3]],
        [self detailLine:@"current lightness L*" value:[self formattedNumber:display[@"lightnessLStar"] digits:2]],
        [self detailLine:@"current predicted brightness" value:[self formattedNumber:display[@"target"] digits:3]],
        [self detailLine:@"model sample count" value:display[@"modelSampleCount"]],
        [self detailLine:@"prediction mode" value:@"nearest learned point"],
        [self detailLine:@"learned range" value:display[@"modelRange"]],
        [self detailLine:@"nearest learned points" value:display[@"learnedPoints"]],
        [self detailLine:@"last manual override timestamp" value:[self formattedTime:display[@"lastManualOverrideTimestamp"]]],
        [self detailLine:@"last manual override delta" value:[self formattedNumber:display[@"manualDelta"] digits:3]],
        [self detailLine:@"last training decision" value:display[@"trainingDecision"]],
        [self detailLine:@"last action reason" value:display[@"actionReason"]],
        [self detailLine:@"last read error" value:[self dashIfEmpty:display[@"lastReadError"]]],
    ];
    self.detailTextView.string = [lines componentsJoinedByString:@"\n"];
}

- (void)updateEventText {
    NSMutableArray<NSString *> *lines = [NSMutableArray new];
    for (NSDictionary *event in [self.eventSnapshots reverseObjectEnumerator]) {
        NSString *display = event[@"display"] ?: @"";
        NSString *debugKey = event[@"debugKey"] ?: @"";
        NSString *prefix = display.length > 0 ? [NSString stringWithFormat:@"%@ [%@]", display, debugKey] : @"global";
        NSString *reason = event[@"reason"];
        NSString *decisionSuffix = reason.length > 0 ? [NSString stringWithFormat:@" reason=%@", reason] : @"";
        [lines addObject:[NSString stringWithFormat:@"%@  %@  %@%@",
                          event[@"time"] ?: @"",
                          prefix,
                          event[@"event"] ?: @"",
                          decisionSuffix]];
    }
    self.eventTextView.string = lines.count > 0 ? [lines componentsJoinedByString:@"\n"] : @"No events yet";
}

- (NSDictionary *)selectedDisplaySnapshot {
    for (NSDictionary *display in self.displaySnapshots) {
        if ([display[@"key"] isEqualToString:self.selectedDisplayKey]) {
            return display;
        }
    }
    return self.displaySnapshots.firstObject;
}

- (NSString *)detailLine:(NSString *)key value:(id)value {
    return [NSString stringWithFormat:@"%-32@: %@", key, [self stringValue:value]];
}

- (NSString *)stringValue:(id)value {
    if (!value || value == [NSNull null]) {
        return @"-";
    }
    if ([value isKindOfClass:[NSString class]]) {
        return ((NSString *)value).length > 0 ? value : @"-";
    }
    return [value description];
}

- (NSString *)dashIfEmpty:(id)value {
    NSString *string = [self stringValue:value];
    return string.length > 0 ? string : @"-";
}

- (NSString *)yesNo:(id)value {
    return [value boolValue] ? @"yes" : @"no";
}

- (NSString *)formattedNumber:(id)value digits:(NSUInteger)digits {
    if (![value isKindOfClass:[NSNumber class]] || [value floatValue] < 0) {
        return @"-";
    }
    return [NSString stringWithFormat:[NSString stringWithFormat:@"%%.%luf", (unsigned long)digits], [value floatValue]];
}

- (NSString *)formattedTime:(id)value {
    if (![value isKindOfClass:[NSNumber class]] || [value doubleValue] <= 0) {
        return @"-";
    }
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm:ss";
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSinceReferenceDate:[value doubleValue]]];
}

- (void)copyDebugState:(id)sender {
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setString:[self.brightnessController debugSnapshotText] forType:NSPasteboardTypeString];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.displaySnapshots.count;
}

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)tableColumn
                  row:(NSInteger)row {
    NSTextField *field = [tableView makeViewWithIdentifier:tableColumn.identifier owner:self];
    if (!field) {
        field = [[NSTextField alloc] initWithFrame:NSZeroRect];
        field.identifier = tableColumn.identifier;
        field.bezeled = NO;
        field.drawsBackground = NO;
        field.editable = NO;
        field.selectable = YES;
        field.font = [NSFont systemFontOfSize:11];
        field.lineBreakMode = NSLineBreakByTruncatingTail;
    }

    NSDictionary *display = self.displaySnapshots[(NSUInteger)row];
    NSString *identifier = tableColumn.identifier;
    if ([identifier isEqualToString:@"lightness"] || [identifier isEqualToString:@"brightness"] || [identifier isEqualToString:@"target"]) {
        field.stringValue = [self formattedNumber:display[identifier] digits:3];
    } else {
        field.stringValue = [self stringValue:display[identifier]];
    }
    return field;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = self.displayTable.selectedRow;
    if (row >= 0 && row < (NSInteger)self.displaySnapshots.count) {
        self.selectedDisplayKey = self.displaySnapshots[(NSUInteger)row][@"key"];
        [self updateDetailText];
    }
}

- (BOOL)windowShouldClose:(id)sender {
    [self hidePanel];
    return NO;
}

- (void)windowDidMove:(NSNotification *)notification {
    [self saveFrame];
}

- (void)windowDidResize:(NSNotification *)notification {
    [self saveFrame];
}

- (void)saveFrame {
    [[NSUserDefaults standardUserDefaults] setObject:NSStringFromRect(self.window.frame)
                                              forKey:DEFAULTS_DEBUG_PANEL_FRAME];
}

- (void)notifyVisibilityChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:LumenDebugPanelVisibilityChangedNotification
                                                        object:self];
}

@end
