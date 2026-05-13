// Copyright (c) Anish Athalye (me@anishathalye.com)
// Released under GPLv3. See the included LICENSE.txt for details

#import "DebugPanelWindowController.h"
#import "BrightnessController.h"
#import "Constants.h"
#import <math.h>

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
@property (nonatomic, strong) NSArray<NSString *> *metricLabels;
@property (nonatomic, assign) NSUInteger lastRenderedSnapshotVersion;

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
        self.metricLabels = @[@"Role",
                              @"Lightness",
                              @"Brightness",
                              @"Target",
                              @"Backend",
                              @"Backend State",
                              @"Action",
                              @"Reason",
                              @"Model",
                              @"Training State",
                              @"Last Learn",
                              @"DDC Failures",
                              @"DDC Command",
                              @"DDC Rate Limit",
                              @"DDC Clamp",
                              @"DDC Degraded",
                              @"Last Read Error",
                              @"Last Write Error",
                              @"Control Loop",
                              @"Snapshot",
                              @"Dropped Samples"];
        self.lastRenderedSnapshotVersion = NSUIntegerMax;
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
    tableScrollView.hasHorizontalScroller = YES;
    tableScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.displayTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.displayTable.delegate = self;
    self.displayTable.dataSource = self;
    self.displayTable.usesAlternatingRowBackgroundColors = YES;
    self.displayTable.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
    self.displayTable.rowHeight = 44;
    self.displayTable.headerView = [[NSTableHeaderView alloc] initWithFrame:NSZeroRect];
    [self addColumn:@"metric" title:@"Metric" width:180];
    tableScrollView.documentView = self.displayTable;
    [root addArrangedSubview:tableScrollView];
    [tableScrollView.heightAnchor constraintEqualToConstant:250].active = YES;

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
    column.resizingMask = NSTableColumnUserResizingMask;
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
    NSTimeInterval renderStartedAt = [NSDate timeIntervalSinceReferenceDate];
    NSDictionary *snapshot = [self.brightnessController debugSnapshot];
    NSUInteger version = [snapshot[@"version"] unsignedIntegerValue];
    if (version == self.lastRenderedSnapshotVersion) {
        return;
    }
    self.lastRenderedSnapshotVersion = version;

    NSArray *displays = snapshot[@"displays"];
    NSArray *events = snapshot[@"events"];
    self.displaySnapshots = [displays isKindOfClass:[NSArray class]] ? displays : @[];
    self.eventSnapshots = [events isKindOfClass:[NSArray class]] ? events : @[];

    if (!self.selectedDisplayKey && self.displaySnapshots.count > 0) {
        self.selectedDisplayKey = self.displaySnapshots[0][@"key"];
    }
    [self rebuildDisplayColumnsIfNeeded];
    [self.displayTable reloadData];
    [self updateDetailText];
    [self updateEventText];
    [self.brightnessController recordDebugPanelRenderDuration:[NSDate timeIntervalSinceReferenceDate] - renderStartedAt];
}

- (void)rebuildDisplayColumnsIfNeeded {
    NSUInteger expectedCount = self.displaySnapshots.count + 1;
    if (self.displayTable.tableColumns.count == expectedCount) {
        BOOL unchanged = YES;
        for (NSUInteger i = 0; i < self.displaySnapshots.count; i++) {
            NSTableColumn *column = self.displayTable.tableColumns[i + 1];
            NSString *expectedIdentifier = [NSString stringWithFormat:@"display-%lu", (unsigned long)i];
            NSString *expectedTitle = [self displayColumnTitle:self.displaySnapshots[i]];
            if (![column.identifier isEqualToString:expectedIdentifier] || ![column.title isEqualToString:expectedTitle]) {
                unchanged = NO;
                break;
            }
        }
        if (unchanged) {
            return;
        }
    }

    while (self.displayTable.tableColumns.count > 1) {
        [self.displayTable removeTableColumn:self.displayTable.tableColumns.lastObject];
    }

    for (NSUInteger i = 0; i < self.displaySnapshots.count; i++) {
        [self addColumn:[NSString stringWithFormat:@"display-%lu", (unsigned long)i]
                  title:[self displayColumnTitle:self.displaySnapshots[i]]
                  width:260];
    }
}

- (NSString *)displayColumnTitle:(NSDictionary *)display {
    NSString *name = [self stringValue:display[@"display"]];
    NSString *debugKey = [self stringValue:display[@"debugKey"]];
    if (debugKey.length > 0 && ![debugKey isEqualToString:@"-"]) {
        return [NSString stringWithFormat:@"%@ [%@]", name, debugKey];
    }
    return name;
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
        [self detailLine:@"backend state" value:display[@"backendState"]],
        [self detailLine:@"can read brightness" value:[self yesNo:display[@"canReadBrightness"]]],
        [self detailLine:@"can set brightness" value:[self yesNo:display[@"canSetBrightness"]]],
        [self detailLine:@"DDC command in flight" value:[self yesNo:display[@"ddcCommandInFlight"]]],
        [self detailLine:@"DDC rate limited" value:[self yesNo:display[@"ddcRateLimited"]]],
        [self detailLine:@"DDC skipped in flight" value:display[@"ddcSkippedInFlightCount"]],
        [self detailLine:@"DDC skipped rate limit" value:display[@"ddcSkippedRateLimitCount"]],
        [self detailLine:@"DDC read failures" value:display[@"ddcConsecutiveReadFailures"]],
        [self detailLine:@"DDC write failures" value:display[@"ddcConsecutiveWriteFailures"]],
        [self detailLine:@"DDC last read attempt" value:[self formattedTime:display[@"ddcLastReadAttemptTimestamp"]]],
        [self detailLine:@"DDC last read success" value:[self formattedTime:display[@"ddcLastReadSuccessTimestamp"]]],
        [self detailLine:@"DDC last read duration" value:[self formattedSeconds:display[@"ddcLastReadDuration"]]],
        [self detailLine:@"DDC last read error" value:[self dashIfEmpty:display[@"ddcLastReadError"]]],
        [self detailLine:@"DDC last write attempt" value:[self formattedTime:display[@"ddcLastWriteAttemptTimestamp"]]],
        [self detailLine:@"DDC last write success" value:[self formattedTime:display[@"ddcLastWriteSuccessTimestamp"]]],
        [self detailLine:@"DDC last write duration" value:[self formattedSeconds:display[@"ddcLastWriteDuration"]]],
        [self detailLine:@"DDC last write error" value:[self dashIfEmpty:display[@"ddcLastWriteError"]]],
        [self detailLine:@"DDC degraded reason" value:[self dashIfEmpty:display[@"ddcDegradedReason"]]],
        [self detailLine:@"DDC clamp applied" value:[self yesNo:display[@"ddcClampApplied"]]],
        [self detailLine:@"DDC applied brightness" value:[self formattedNumber:display[@"ddcLastAppliedBrightness"] digits:3]],
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
        [self detailLine:@"last decision timestamp" value:[self formattedTime:display[@"actionTimestamp"]]],
        [self detailLine:@"last control-loop duration" value:[self formattedSeconds:display[@"lastControlLoopDuration"]]],
        [self detailLine:@"snapshot generation duration" value:[self formattedSeconds:display[@"snapshotGenerationDuration"]]],
        [self detailLine:@"debug panel render duration" value:[self formattedSeconds:display[@"debugPanelLastRenderDuration"]]],
        [self detailLine:@"dropped/coalesced samples" value:display[@"droppedSampleCount"]],
        [self detailLine:@"last read error" value:[self dashIfEmpty:display[@"lastReadError"]]],
        [self detailLine:@"has valid brightness baseline" value:[self yesNo:display[@"hasValidBrightnessBaseline"]]],
        [self detailLine:@"brightness baseline" value:[self formattedNumber:display[@"brightnessBaseline"] digits:3]],
        [self detailLine:@"brightness baseline timestamp" value:[self formattedTime:display[@"brightnessBaselineTimestamp"]]],
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
    if (![value isKindOfClass:[NSNumber class]] || isnan([value floatValue]) || [value floatValue] < 0) {
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

- (NSString *)formattedSeconds:(id)value {
    if (![value isKindOfClass:[NSNumber class]] || [value doubleValue] <= 0) {
        return @"-";
    }
    return [NSString stringWithFormat:@"%.3fs", [value doubleValue]];
}

- (void)copyDebugState:(id)sender {
    NSDictionary *snapshot = [self.brightnessController debugSnapshot];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:snapshot
                                                           options:NSJSONWritingPrettyPrinted
                                                             error:&error];
        NSString *text = jsonData && !error ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] : [snapshot description];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
            [pasteboard clearContents];
            [pasteboard setString:text forType:NSPasteboardTypeString];
        });
    });
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.metricLabels.count;
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
        field.lineBreakMode = NSLineBreakByWordWrapping;
        field.usesSingleLineMode = NO;
        field.maximumNumberOfLines = 2;
    }

    NSString *identifier = tableColumn.identifier;
    if ([identifier isEqualToString:@"metric"]) {
        field.font = [NSFont boldSystemFontOfSize:11];
        field.stringValue = self.metricLabels[(NSUInteger)row];
    } else {
        field.font = [NSFont systemFontOfSize:11];
        NSUInteger displayIndex = [self displayIndexForColumnIdentifier:identifier];
        if (displayIndex == NSNotFound || displayIndex >= self.displaySnapshots.count) {
            field.stringValue = @"-";
        } else {
            NSDictionary *display = self.displaySnapshots[displayIndex];
            field.stringValue = [self valueForMetric:self.metricLabels[(NSUInteger)row] display:display];
        }
    }
    return field;
}

- (NSUInteger)displayIndexForColumnIdentifier:(NSString *)identifier {
    if (![identifier hasPrefix:@"display-"]) {
        return NSNotFound;
    }
    NSInteger index = [[identifier substringFromIndex:@"display-".length] integerValue];
    return index >= 0 ? (NSUInteger)index : NSNotFound;
}

- (NSString *)valueForMetric:(NSString *)metric display:(NSDictionary *)display {
    if ([metric isEqualToString:@"Role"]) {
        return [self stringValue:display[@"role"]];
    }
    if ([metric isEqualToString:@"Lightness"]) {
        return [self formattedNumber:display[@"lightness"] digits:3];
    }
    if ([metric isEqualToString:@"Brightness"]) {
        if (![display[@"canReadBrightness"] boolValue] ||
            ![display[@"brightness"] isKindOfClass:[NSNumber class]] ||
            [display[@"brightness"] floatValue] < 0 ||
            isnan([display[@"brightness"] floatValue])) {
            return @"unreadable";
        }
        return [self formattedNumber:display[@"brightness"] digits:3];
    }
    if ([metric isEqualToString:@"Target"]) {
        return [self formattedNumber:display[@"target"] digits:3];
    }
    if ([metric isEqualToString:@"Backend"]) {
        return [self stringValue:display[@"backend"]];
    }
    if ([metric isEqualToString:@"Backend State"]) {
        return [self stringValue:display[@"backendState"]];
    }
    if ([metric isEqualToString:@"Action"]) {
        return [self stringValue:display[@"action"]];
    }
    if ([metric isEqualToString:@"Reason"]) {
        return [self stringValue:display[@"actionReason"]];
    }
    if ([metric isEqualToString:@"Model"]) {
        return [self stringValue:display[@"model"]];
    }
    if ([metric isEqualToString:@"Training State"]) {
        return [self stringValue:display[@"trainingDecision"]];
    }
    if ([metric isEqualToString:@"Last Learn"]) {
        return [self stringValue:display[@"lastLearn"]];
    }
    if ([metric isEqualToString:@"DDC Failures"]) {
        NSString *readFailures = [self stringValue:display[@"ddcConsecutiveReadFailures"]];
        NSString *writeFailures = [self stringValue:display[@"ddcConsecutiveWriteFailures"]];
        return [NSString stringWithFormat:@"read %@, write %@", readFailures, writeFailures];
    }
    if ([metric isEqualToString:@"DDC Command"]) {
        return [NSString stringWithFormat:@"in flight: %@",
                [self yesNo:display[@"ddcCommandInFlight"]]];
    }
    if ([metric isEqualToString:@"DDC Rate Limit"]) {
        return [NSString stringWithFormat:@"limited: %@, skipped %@",
                [self yesNo:display[@"ddcRateLimited"]],
                [self stringValue:display[@"ddcSkippedRateLimitCount"]]];
    }
    if ([metric isEqualToString:@"DDC Clamp"]) {
        if (![display[@"ddcClampApplied"] boolValue]) {
            return @"no";
        }
        return [NSString stringWithFormat:@"yes, applied %@",
                [self formattedNumber:display[@"ddcLastAppliedBrightness"] digits:3]];
    }
    if ([metric isEqualToString:@"DDC Degraded"]) {
        return [self dashIfEmpty:display[@"ddcDegradedReason"]];
    }
    if ([metric isEqualToString:@"Last Read Error"]) {
        return [self dashIfEmpty:display[@"lastReadError"]];
    }
    if ([metric isEqualToString:@"Last Write Error"]) {
        return [self dashIfEmpty:display[@"lastWriteError"]];
    }
    if ([metric isEqualToString:@"Control Loop"]) {
        return [self formattedSeconds:display[@"lastControlLoopDuration"]];
    }
    if ([metric isEqualToString:@"Snapshot"]) {
        return [self formattedSeconds:display[@"snapshotGenerationDuration"]];
    }
    if ([metric isEqualToString:@"Dropped Samples"]) {
        return [self stringValue:display[@"droppedSampleCount"]];
    }
    return @"-";
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger column = self.displayTable.clickedColumn;
    if (column > 0 && column - 1 < (NSInteger)self.displaySnapshots.count) {
        self.selectedDisplayKey = self.displaySnapshots[(NSUInteger)(column - 1)][@"key"];
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
    NSString *frame = NSStringFromRect(self.window.frame);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[NSUserDefaults standardUserDefaults] setObject:frame
                                                  forKey:DEFAULTS_DEBUG_PANEL_FRAME];
    });
}

- (void)notifyVisibilityChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:LumenDebugPanelVisibilityChangedNotification
                                                        object:self];
}

@end
