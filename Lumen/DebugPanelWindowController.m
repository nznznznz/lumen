// Copyright (c) Anish Athalye (me@anishathalye.com)
// Released under GPLv3. See the included LICENSE.txt for details

#import "DebugPanelWindowController.h"
#import "BrightnessController.h"
#import "Constants.h"
#import <math.h>
#import <os/log.h>

NSString * const LumenDebugPanelVisibilityChangedNotification = @"LumenDebugPanelVisibilityChangedNotification";

static os_log_t LumenDebugPanelLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.anishathalye.lumen", "debug-panel");
    });
    return log;
}

static const CGFloat LumenDebugMetricColumnWidth = 170.0;
static const CGFloat LumenDebugDisplayColumnWidth = 280.0;
static const CGFloat LumenDebugRowHeight = 22.0;
static const CGFloat LumenDebugGridPadding = 12.0;
static const CGFloat LumenDebugGridColumnSpacing = 10.0;
static const CGFloat LumenDebugGridRowSpacing = 2.0;
static NSTimeInterval const LumenDebugPanelRefreshInterval = 1.0;

@interface LumenDebugGridDocumentView : NSView
@end

@implementation LumenDebugGridDocumentView

- (BOOL)isFlipped {
    return YES;
}

@end

@interface DebugPanelWindowController () <NSWindowDelegate>

@property (nonatomic, weak) BrightnessController *brightnessController;
@property (nonatomic, strong) NSScrollView *gridScrollView;
@property (nonatomic, strong) NSGridView *gridView;
@property (nonatomic, strong) NSButton *debugCopyButton;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) NSArray<NSDictionary<NSString *, NSString *> *> *metrics;
@property (nonatomic, copy) NSString *lastRenderedSnapshotToken;
@property (nonatomic, strong) NSArray<NSString *> *renderedDisplayKeys;
@property (nonatomic, strong) NSArray<NSString *> *renderedMetricKeys;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *valueFieldsByCellKey;
@property (nonatomic, assign) BOOL loggedMissingSnapshot;

@end

@implementation DebugPanelWindowController

- (instancetype)initWithBrightnessController:(BrightnessController *)brightnessController {
    NSRect frame = NSMakeRect(200, 200, 1000, 520);
    NSString *savedFrame = [[NSUserDefaults standardUserDefaults] stringForKey:DEFAULTS_DEBUG_PANEL_FRAME];
    if (savedFrame.length > 0) {
        frame = NSRectFromString(savedFrame);
    }
    frame.size.width = MAX(frame.size.width, 1000);
    frame.size.height = MAX(frame.size.height, 520);

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
    panel.minSize = NSMakeSize(720, 360);

    self = [super initWithWindow:panel];
    if (self) {
        self.brightnessController = brightnessController;
        self.metrics = [self defaultMetrics];
        panel.delegate = self;
        [self buildUI];
    }
    return self;
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)defaultMetrics {
    return @[
        @{@"title": @"Role", @"key": @"role"},
        @{@"title": @"Backend", @"key": @"backend"},
        @{@"title": @"Control Method", @"key": @"controlMethod"},
        @{@"title": @"Backend State", @"key": @"backendState"},
        @{@"title": @"Capture", @"key": @"capture"},
        @{@"title": @"Sampling Mode", @"key": @"samplingMode"},
        @{@"title": @"Max Analysis FPS", @"key": @"maxAnalysisFPS"},
        @{@"title": @"Effective Analysis FPS", @"key": @"effectiveAnalysisFPS"},
        @{@"title": @"Last Accepted Sample Age", @"key": @"lastAcceptedSampleAge"},
        @{@"title": @"Dropped Frames", @"key": @"droppedFrames"},
        @{@"title": @"Coalesced Frames", @"key": @"coalescedFrames"},
        @{@"title": @"Cheap Change Delta", @"key": @"cheapChangeDelta"},
        @{@"title": @"Last Heavy Analysis Duration", @"key": @"lastHeavyAnalysisDuration"},
        @{@"title": @"Heavy Analyses Skipped", @"key": @"heavyAnalysesSkipped"},
        @{@"title": @"Forced Refresh Interval", @"key": @"forcedRefreshInterval"},
        @{@"title": @"Capture Rate", @"key": @"captureRate"},
        @{@"title": @"Accepted Sample Rate", @"key": @"acceptedSampleRate"},
        @{@"title": @"Dropped Samples", @"key": @"droppedSampleCount"},
        @{@"title": @"Last Lightness Compute Duration", @"key": @"lastLightnessComputeDuration"},
        @{@"title": @"Last Control Loop Duration", @"key": @"lastControlLoopDuration"},
        @{@"title": @"Debug Refresh Rate", @"key": @"debugRefreshRate"},
        @{@"title": @"Last Debug Render Duration", @"key": @"debugPanelLastRenderDuration"},
        @{@"title": @"Lightness L*", @"key": @"lightnessLStar"},
        @{@"title": @"Lightness", @"key": @"lightness"},
        @{@"title": @"Brightness", @"key": @"brightness"},
        @{@"title": @"Hardware Brightness", @"key": @"hardwareBrightness"},
        @{@"title": @"Target", @"key": @"target"},
        @{@"title": @"Target Perceived Brightness", @"key": @"overlayTargetBrightness"},
        @{@"title": @"Overlay Enabled", @"key": @"overlayEnabled"},
        @{@"title": @"Overlay Alpha", @"key": @"overlayAlpha"},
        @{@"title": @"Overlay Desired Alpha", @"key": @"overlayDesiredAlpha"},
        @{@"title": @"Overlay Applied Alpha", @"key": @"overlayAppliedAlpha"},
        @{@"title": @"Overlay Updates Skipped", @"key": @"overlayUpdatesSkipped"},
        @{@"title": @"Last Overlay Update Duration", @"key": @"lastOverlayUpdateDuration"},
        @{@"title": @"Temporarily Hidden", @"key": @"overlayTemporarilyHidden"},
        @{@"title": @"Hidden Reason", @"key": @"overlayHiddenReason"},
        @{@"title": @"Hidden Until", @"key": @"overlayHiddenUntil"},
        @{@"title": @"Screenshot Safe Mode", @"key": @"screenshotSafeMode"},
        @{@"title": @"Window Sharing Type", @"key": @"overlayWindowSharingType"},
        @{@"title": @"Ignores Mouse Events", @"key": @"overlayIgnoresMouseEvents"},
        @{@"title": @"Can Become Key/Main", @"key": @"overlayCanBecomeKeyMain"},
        @{@"title": @"Action", @"key": @"action"},
        @{@"title": @"Reason", @"key": @"actionReason"},
        @{@"title": @"Can read brightness", @"key": @"canReadBrightness"},
        @{@"title": @"Can set brightness", @"key": @"canSetBrightness"},
        @{@"title": @"Controllable", @"key": @"controllable"},
        @{@"title": @"Manual Learning", @"key": @"manualLearningAvailable"},
        @{@"title": @"Overlay Calibration Samples", @"key": @"overlayCalibrationSamples"},
        @{@"title": @"Overlay Learned Points", @"key": @"overlayLearnedPoints"},
        @{@"title": @"Overlay Included In Capture", @"key": @"overlayIncludedInCapture"},
        @{@"title": @"Screenshot Hidden State", @"key": @"screenshotHiddenState"},
        @{@"title": @"Model", @"key": @"model"},
        @{@"title": @"Samples", @"key": @"modelSampleCount"},
        @{@"title": @"Learned Points", @"key": @"learnedPoints"},
        @{@"title": @"Last Learn", @"key": @"lastLearn"},
        @{@"title": @"Training", @"key": @"trainingDecision"},
        @{@"title": @"Last Read Error", @"key": @"lastReadError"},
        @{@"title": @"Last Write Error", @"key": @"lastWriteError"},
        @{@"title": @"Read Failures", @"key": @"readFailures"},
        @{@"title": @"Write Failures", @"key": @"writeFailures"},
        @{@"title": @"Command In Flight", @"key": @"commandInFlight"},
        @{@"title": @"DDC State", @"key": @"ddcBackendState"},
        @{@"title": @"DDC Rate Limited", @"key": @"ddcRateLimited"},
        @{@"title": @"Last DDC Read Duration", @"key": @"lastDDCReadDuration"},
        @{@"title": @"Last DDC Write Duration", @"key": @"lastDDCWriteDuration"},
        @{@"title": @"Display ID", @"key": @"displayID"},
        @{@"title": @"Debug Key", @"key": @"debugKey"},
    ];
}

- (void)buildUI {
    NSView *contentView = self.window.contentView;

    self.gridScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.gridScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.gridScrollView.hasVerticalScroller = YES;
    self.gridScrollView.hasHorizontalScroller = YES;
    self.gridScrollView.autohidesScrollers = YES;
    self.gridScrollView.borderType = NSBezelBorder;
    [contentView addSubview:self.gridScrollView];

    self.debugCopyButton = [NSButton buttonWithTitle:@"Copy Debug State"
                                              target:self
                                              action:@selector(copyDebugState:)];
    self.debugCopyButton.bezelStyle = NSBezelStyleRounded;
    self.debugCopyButton.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:self.debugCopyButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.gridScrollView.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:10],
        [self.gridScrollView.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-10],
        [self.gridScrollView.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:10],
        [self.gridScrollView.bottomAnchor constraintEqualToAnchor:self.debugCopyButton.topAnchor constant:-8],

        [self.debugCopyButton.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:10],
        [self.debugCopyButton.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-10],
    ]];

    [self renderPlaceholder:@"No debug snapshot yet"];
}

- (void)showPanel {
    self.lastRenderedSnapshotToken = nil;
    [self refreshFromLatestSnapshot];
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

- (void)startRefreshTimer {
    if (self.refreshTimer) {
        return;
    }
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:LumenDebugPanelRefreshInterval
                                                         target:self
                                                       selector:@selector(refreshTimerFired:)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)stopRefreshTimer {
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)refreshTimerFired:(NSTimer *)timer {
    [self refreshFromLatestSnapshot];
}

- (void)refreshFromLatestSnapshot {
    NSDictionary *snapshot = [self.brightnessController debugSnapshot];
    NSString *token = [self tokenForSnapshot:snapshot];
    if ([token isEqualToString:self.lastRenderedSnapshotToken]) {
        return;
    }
    self.lastRenderedSnapshotToken = token;
    NSTimeInterval renderStartedAt = [NSDate timeIntervalSinceReferenceDate];

    if (snapshot.count == 0) {
        if (!self.loggedMissingSnapshot) {
            self.loggedMissingSnapshot = YES;
            os_log_debug(LumenDebugPanelLog(), "No debug snapshot yet");
        }
        [self renderPlaceholder:@"No debug snapshot yet"];
        [self.brightnessController recordDebugPanelRenderDuration:[NSDate timeIntervalSinceReferenceDate] - renderStartedAt];
        return;
    }

    NSArray *displays = snapshot[@"displays"];
    if (![displays isKindOfClass:[NSArray class]] || displays.count == 0) {
        os_log_debug(LumenDebugPanelLog(), "Debug snapshot contains no displays");
        [self renderPlaceholder:@"No displays in debug snapshot"];
        [self.brightnessController recordDebugPanelRenderDuration:[NSDate timeIntervalSinceReferenceDate] - renderStartedAt];
        return;
    }

    [self renderGridWithDisplays:displays];
    [self.brightnessController recordDebugPanelRenderDuration:[NSDate timeIntervalSinceReferenceDate] - renderStartedAt];
    os_log_debug(LumenDebugPanelLog(),
                 "Debug panel refreshed displayCount=%{public}lu metricCount=%{public}lu",
                 (unsigned long)displays.count,
                 (unsigned long)self.metrics.count);
}

- (NSString *)tokenForSnapshot:(NSDictionary *)snapshot {
    if (![snapshot isKindOfClass:[NSDictionary class]] || snapshot.count == 0) {
        return @"empty";
    }

    id version = snapshot[@"version"];
    if (version) {
        return [NSString stringWithFormat:@"version:%@", version];
    }

    id generatedAt = snapshot[@"generatedAt"];
    NSArray *displays = [snapshot[@"displays"] isKindOfClass:[NSArray class]] ? snapshot[@"displays"] : @[];
    return [NSString stringWithFormat:@"generated:%@ displays:%lu hash:%lu",
            generatedAt ?: @"none",
            (unsigned long)displays.count,
            (unsigned long)snapshot.hash];
}

- (void)renderPlaceholder:(NSString *)message {
    NSTextField *label = [self makeValueLabel:message];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    label.textColor = [NSColor secondaryLabelColor];
    label.frame = NSMakeRect(LumenDebugGridPadding, LumenDebugGridPadding, 360, 24);

    LumenDebugGridDocumentView *container = [[LumenDebugGridDocumentView alloc] initWithFrame:NSMakeRect(0, 0, 420, 48)];
    [container addSubview:label];
    self.gridScrollView.documentView = container;
    self.gridView = nil;
    self.renderedDisplayKeys = nil;
    self.renderedMetricKeys = nil;
    self.valueFieldsByCellKey = nil;
    [self resizeDocumentViewForGridContentSize:NSMakeSize(420, 48) scrollToTop:YES];
}

- (void)renderGridWithDisplays:(NSArray *)displays {
    NSArray<NSString *> *displayKeys = [self displayKeysForDisplays:displays];
    NSArray<NSString *> *metricKeys = [self metricKeys];

    if (self.gridView &&
        [displayKeys isEqualToArray:self.renderedDisplayKeys] &&
        [metricKeys isEqualToArray:self.renderedMetricKeys]) {
        [self updateGridValuesWithDisplays:displays displayKeys:displayKeys];
        return;
    }

    [self rebuildGridWithDisplays:displays displayKeys:displayKeys metricKeys:metricKeys];
}

- (void)rebuildGridWithDisplays:(NSArray *)displays
                    displayKeys:(NSArray<NSString *> *)displayKeys
                      metricKeys:(NSArray<NSString *> *)metricKeys {
    NSMutableArray<NSArray<NSView *> *> *rows = [NSMutableArray new];
    NSMutableDictionary<NSString *, NSTextField *> *valueFieldsByCellKey = [NSMutableDictionary new];

    NSMutableArray<NSView *> *headerRow = [NSMutableArray new];
    [headerRow addObject:[self makeHeaderLabel:@"Metric"]];
    for (NSUInteger displayIndex = 0; displayIndex < displays.count; displayIndex++) {
        NSDictionary *display = displays[displayIndex];
        NSTextField *header = [self makeHeaderLabel:[self displayNameForDisplay:display]];
        NSString *debugKey = [self stringOrDash:display[@"debugKey"]];
        if (![debugKey isEqualToString:@"—"]) {
            header.toolTip = debugKey;
        }
        [headerRow addObject:header];
    }
    [rows addObject:headerRow];

    for (NSDictionary<NSString *, NSString *> *metric in self.metrics) {
        NSString *metricKey = metric[@"key"];
        NSMutableArray<NSView *> *row = [NSMutableArray new];
        [row addObject:[self makeMetricLabel:metric[@"title"]]];
        for (NSUInteger displayIndex = 0; displayIndex < displays.count; displayIndex++) {
            NSDictionary *display = displays[displayIndex];
            NSString *displayKey = displayKeys[displayIndex];
            NSString *value = [self valueForMetric:metricKey displaySnapshot:display];
            NSTextField *field = [self makeValueLabel:value];
            [self updateLabel:field withValue:value];
            valueFieldsByCellKey[[self cellKeyForMetricKey:metricKey displayKey:displayKey]] = field;
            [row addObject:field];
        }
        [rows addObject:row];
    }

    NSGridView *gridView = [NSGridView gridViewWithViews:rows];
    gridView.translatesAutoresizingMaskIntoConstraints = NO;
    gridView.rowSpacing = LumenDebugGridRowSpacing;
    gridView.columnSpacing = LumenDebugGridColumnSpacing;
    gridView.xPlacement = NSGridCellPlacementLeading;
    gridView.yPlacement = NSGridCellPlacementCenter;

    for (NSInteger column = 0; column < gridView.numberOfColumns; column++) {
        NSGridColumn *gridColumn = [gridView columnAtIndex:column];
        gridColumn.xPlacement = NSGridCellPlacementLeading;
        gridColumn.width = column == 0 ? LumenDebugMetricColumnWidth : LumenDebugDisplayColumnWidth;
    }
    for (NSInteger row = 0; row < gridView.numberOfRows; row++) {
        NSGridRow *gridRow = [gridView rowAtIndex:row];
        gridRow.yPlacement = NSGridCellPlacementCenter;
        gridRow.height = LumenDebugRowHeight;
    }

    LumenDebugGridDocumentView *documentView = [[LumenDebugGridDocumentView alloc] initWithFrame:NSMakeRect(0, 0, 1, 1)];
    [documentView addSubview:gridView];
    [NSLayoutConstraint activateConstraints:@[
        [gridView.leadingAnchor constraintEqualToAnchor:documentView.leadingAnchor constant:LumenDebugGridPadding],
        [gridView.topAnchor constraintEqualToAnchor:documentView.topAnchor constant:LumenDebugGridPadding],
    ]];

    self.gridView = gridView;
    self.renderedDisplayKeys = displayKeys;
    self.renderedMetricKeys = metricKeys;
    self.valueFieldsByCellKey = valueFieldsByCellKey;
    self.gridScrollView.documentView = documentView;
    [self resizeDocumentViewForCurrentGrid];
}

- (void)updateGridValuesWithDisplays:(NSArray *)displays displayKeys:(NSArray<NSString *> *)displayKeys {
    [NSAnimationContext beginGrouping];
    NSAnimationContext.currentContext.duration = 0.0;
    NSAnimationContext.currentContext.allowsImplicitAnimation = NO;

    for (NSUInteger displayIndex = 0; displayIndex < displays.count; displayIndex++) {
        NSDictionary *display = displays[displayIndex];
        NSString *displayKey = displayKeys[displayIndex];
        for (NSDictionary<NSString *, NSString *> *metric in self.metrics) {
            NSString *metricKey = metric[@"key"];
            NSTextField *field = self.valueFieldsByCellKey[[self cellKeyForMetricKey:metricKey displayKey:displayKey]];
            if (!field) {
                continue;
            }
            [self updateLabel:field withValue:[self valueForMetric:metricKey displaySnapshot:display]];
        }
    }

    [NSAnimationContext endGrouping];
}

- (void)updateLabel:(NSTextField *)label withValue:(NSString *)value {
    NSString *text = value.length > 0 ? value : @"—";
    if (![label.stringValue isEqualToString:text]) {
        label.stringValue = text;
    }
    label.toolTip = (text.length > 0 && ![text isEqualToString:@"—"]) ? text : nil;
}

- (void)resizeDocumentViewForCurrentGrid {
    if (!self.gridView) {
        return;
    }

    CGFloat width = (LumenDebugGridPadding * 2.0) + LumenDebugMetricColumnWidth;
    width += self.renderedDisplayKeys.count * LumenDebugDisplayColumnWidth;
    width += self.renderedDisplayKeys.count * LumenDebugGridColumnSpacing;

    CGFloat height = (LumenDebugGridPadding * 2.0);
    height += (self.renderedMetricKeys.count + 1) * LumenDebugRowHeight;
    height += self.renderedMetricKeys.count * LumenDebugGridRowSpacing;
    [self resizeDocumentViewForGridContentSize:NSMakeSize(width, height) scrollToTop:YES];
}

- (void)resizeDocumentViewForGridContentSize:(NSSize)contentSize scrollToTop:(BOOL)scrollToTop {
    NSView *documentView = self.gridScrollView.documentView;
    if (!documentView) {
        return;
    }

    NSSize clipSize = self.gridScrollView.contentView.bounds.size;
    CGFloat width = MAX(contentSize.width, clipSize.width);
    CGFloat height = MAX(contentSize.height, clipSize.height);
    documentView.frame = NSMakeRect(0, 0, width, height);
    if (scrollToTop) {
        [self.gridScrollView.contentView scrollToPoint:NSZeroPoint];
        [self.gridScrollView reflectScrolledClipView:self.gridScrollView.contentView];
    }
}

- (NSArray<NSString *> *)displayKeysForDisplays:(NSArray *)displays {
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithCapacity:displays.count];
    for (NSDictionary *display in displays) {
        [keys addObject:[self structureKeyForDisplay:display]];
    }
    return keys;
}

- (NSArray<NSString *> *)metricKeys {
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithCapacity:self.metrics.count];
    for (NSDictionary<NSString *, NSString *> *metric in self.metrics) {
        [keys addObject:metric[@"key"] ?: @""];
    }
    return keys;
}

- (NSString *)structureKeyForDisplay:(NSDictionary *)display {
    NSString *identity = [self nonEmptyString:display[@"debugKey"]];
    if (!identity) {
        identity = [self nonEmptyString:display[@"displayID"]];
    }
    if (!identity) {
        identity = [self displayNameForDisplay:display];
    }
    return [NSString stringWithFormat:@"%@|%@", identity ?: @"display", [self displayNameForDisplay:display]];
}

- (NSString *)cellKeyForMetricKey:(NSString *)metricKey displayKey:(NSString *)displayKey {
    return [NSString stringWithFormat:@"%@\n%@", metricKey ?: @"", displayKey ?: @""];
}

- (NSString *)displayNameForDisplay:(NSDictionary *)display {
    NSString *name = [self nonEmptyString:display[@"name"]];
    if (!name) {
        name = [self nonEmptyString:display[@"display"]];
    }
    if (!name) {
        id displayID = display[@"displayID"];
        if (displayID) {
            name = [NSString stringWithFormat:@"Display %@", displayID];
        }
    }
    if (!name) {
        name = [self nonEmptyString:display[@"debugKey"]];
    }
    return name ?: @"Display";
}

- (NSTextField *)makeHeaderLabel:(NSString *)text {
    NSTextField *label = [self makeBaseLabel:text];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    return label;
}

- (NSTextField *)makeMetricLabel:(NSString *)text {
    NSTextField *label = [self makeBaseLabel:text];
    label.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    return label;
}

- (NSTextField *)makeValueLabel:(NSString *)text {
    NSTextField *label = [self makeBaseLabel:text];
    label.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    return label;
}

- (NSTextField *)makeBaseLabel:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text ?: @"—"];
    label.textColor = [NSColor labelColor];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.usesSingleLineMode = YES;
    label.alignment = NSTextAlignmentLeft;
    label.maximumNumberOfLines = 1;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [label.widthAnchor constraintGreaterThanOrEqualToConstant:20].active = YES;
    return label;
}

- (NSString *)valueForMetric:(NSString *)metric displaySnapshot:(NSDictionary *)display {
    @try {
        if ([metric isEqualToString:@"capture"]) {
            NSString *status = [self nonEmptyString:display[@"captureStatus"]];
            if (status) {
                return status;
            }
            return [self yesNoOrDash:display[@"captureActive"]];
        }
        if ([metric isEqualToString:@"captureRate"] ||
            [metric isEqualToString:@"acceptedSampleRate"] ||
            [metric isEqualToString:@"maxAnalysisFPS"] ||
            [metric isEqualToString:@"effectiveAnalysisFPS"] ||
            [metric isEqualToString:@"debugRefreshRate"]) {
            if ([metric isEqualToString:@"debugRefreshRate"]) {
                return [self formattedRate:@(1.0 / LumenDebugPanelRefreshInterval)];
            }
            return [self formattedRate:display[metric]];
        }
        if ([metric isEqualToString:@"droppedSampleCount"] ||
            [metric isEqualToString:@"droppedFrames"] ||
            [metric isEqualToString:@"coalescedFrames"] ||
            [metric isEqualToString:@"heavyAnalysesSkipped"] ||
            [metric isEqualToString:@"overlayUpdatesSkipped"]) {
            return [self formattedInteger:display[metric]];
        }
        if ([metric isEqualToString:@"lastLightnessComputeDuration"] ||
            [metric isEqualToString:@"lastHeavyAnalysisDuration"] ||
            [metric isEqualToString:@"lastControlLoopDuration"] ||
            [metric isEqualToString:@"debugPanelLastRenderDuration"] ||
            [metric isEqualToString:@"lastAcceptedSampleAge"] ||
            [metric isEqualToString:@"forcedRefreshInterval"] ||
            [metric isEqualToString:@"lastOverlayUpdateDuration"]) {
            return [self formattedSeconds:display[metric]];
        }
        if ([metric isEqualToString:@"cheapChangeDelta"]) {
            return [self formattedNumber:display[metric] digits:3];
        }
        if ([metric isEqualToString:@"lightnessLStar"]) {
            return [self formattedNumber:display[@"lightnessLStar"] digits:1];
        }
        if ([metric isEqualToString:@"lightness"]) {
            return [self formattedNumber:display[@"lightness"] digits:3];
        }
        if ([metric isEqualToString:@"brightness"]) {
            if (![display[@"canReadBrightness"] boolValue]) {
                return @"unreadable";
            }
            return [self formattedNumber:display[@"brightness"] digits:3];
        }
        if ([metric isEqualToString:@"hardwareBrightness"]) {
            id value = display[@"hardwareBrightness"];
            if ([value isKindOfClass:[NSString class]]) {
                return [self stringOrDash:value];
            }
            return [self formattedNumber:value digits:3];
        }
        if ([metric isEqualToString:@"target"]) {
            return [self formattedNumber:display[@"target"] digits:3];
        }
        if ([metric isEqualToString:@"overlayTargetBrightness"]) {
            return [self formattedNumber:display[@"overlayTargetBrightness"] digits:3];
        }
        if ([metric isEqualToString:@"overlayAlpha"] ||
            [metric isEqualToString:@"overlayDesiredAlpha"] ||
            [metric isEqualToString:@"overlayAppliedAlpha"]) {
            return [self formattedNumber:display[metric] digits:3];
        }
        if ([metric isEqualToString:@"overlayCanBecomeKeyMain"]) {
            NSString *key = [self yesNoOrDash:display[@"overlayCanBecomeKey"]];
            NSString *main = [self yesNoOrDash:display[@"overlayCanBecomeMain"]];
            if ([key isEqualToString:@"—"] && [main isEqualToString:@"—"]) {
                return @"—";
            }
            return [NSString stringWithFormat:@"key %@, main %@", key, main];
        }
        if ([metric isEqualToString:@"manualLearningAvailable"]) {
            return [self stringOrDash:display[metric]];
        }
        if ([metric isEqualToString:@"canReadBrightness"] ||
            [metric isEqualToString:@"canSetBrightness"] ||
            [metric isEqualToString:@"controllable"] ||
            [metric isEqualToString:@"overlayEnabled"] ||
            [metric isEqualToString:@"overlayTemporarilyHidden"] ||
            [metric isEqualToString:@"overlayIgnoresMouseEvents"] ||
            [metric isEqualToString:@"ddcRateLimited"]) {
            return [self yesNoOrDash:display[metric]];
        }
        if ([metric isEqualToString:@"readFailures"]) {
            return [self firstPresentStringFromDisplay:display keys:@[@"consecutiveReadFailures", @"ddcConsecutiveReadFailures"]];
        }
        if ([metric isEqualToString:@"writeFailures"]) {
            return [self firstPresentStringFromDisplay:display keys:@[@"consecutiveWriteFailures", @"ddcConsecutiveWriteFailures"]];
        }
        if ([metric isEqualToString:@"commandInFlight"]) {
            id value = [self firstPresentValueFromDisplay:display keys:@[@"commandInFlight", @"ddcCommandInFlight"]];
            return [self yesNoOrDash:value];
        }
        if ([metric isEqualToString:@"lastDDCReadDuration"]) {
            id value = [self firstPresentValueFromDisplay:display keys:@[@"lastDDCReadDuration", @"ddcLastReadDuration"]];
            return [self formattedSeconds:value];
        }
        if ([metric isEqualToString:@"lastDDCWriteDuration"]) {
            id value = [self firstPresentValueFromDisplay:display keys:@[@"lastDDCWriteDuration", @"ddcLastWriteDuration"]];
            return [self formattedSeconds:value];
        }
        if ([metric isEqualToString:@"lastReadError"] || [metric isEqualToString:@"lastWriteError"]) {
            return [self stringOrDash:display[metric]];
        }
        return [self stringOrDash:display[metric]];
    } @catch (NSException *exception) {
        os_log_debug(LumenDebugPanelLog(),
                     "Debug grid missing/invalid field metric=%{public}@ exception=%{public}@",
                     metric,
                     exception.reason ?: exception.name);
        return @"—";
    }
}

- (id)firstPresentValueFromDisplay:(NSDictionary *)display keys:(NSArray<NSString *> *)keys {
    for (NSString *key in keys) {
        id value = display[key];
        if (value && value != [NSNull null]) {
            return value;
        }
    }
    return nil;
}

- (NSString *)firstPresentStringFromDisplay:(NSDictionary *)display keys:(NSArray<NSString *> *)keys {
    return [self stringOrDash:[self firstPresentValueFromDisplay:display keys:keys]];
}

- (NSString *)yesNoOrDash:(id)value {
    if (!value || value == [NSNull null]) {
        return @"—";
    }
    return [value boolValue] ? @"yes" : @"no";
}

- (NSString *)formattedNumber:(id)value digits:(NSUInteger)digits {
    if (![value isKindOfClass:[NSNumber class]]) {
        return @"—";
    }
    double number = [value doubleValue];
    if (!isfinite(number) || number < 0) {
        return @"—";
    }
    return [NSString stringWithFormat:[NSString stringWithFormat:@"%%.%luf", (unsigned long)digits], number];
}

- (NSString *)formattedSeconds:(id)value {
    NSString *number = [self formattedNumber:value digits:3];
    return [number isEqualToString:@"—"] ? number : [number stringByAppendingString:@"s"];
}

- (NSString *)formattedRate:(id)value {
    NSString *number = [self formattedNumber:value digits:2];
    return [number isEqualToString:@"—"] ? number : [number stringByAppendingString:@"/s"];
}

- (NSString *)formattedInteger:(id)value {
    if (![value isKindOfClass:[NSNumber class]]) {
        return @"—";
    }
    double number = [value doubleValue];
    if (!isfinite(number) || number < 0) {
        return @"—";
    }
    return [NSString stringWithFormat:@"%lld", [value longLongValue]];
}

- (NSString *)stringOrDash:(id)value {
    NSString *string = [self nonEmptyString:value];
    return string ?: @"—";
}

- (NSString *)nonEmptyString:(id)value {
    if (!value || value == [NSNull null]) {
        return nil;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        double number = [value doubleValue];
        if (!isfinite(number)) {
            return nil;
        }
    }
    NSString *string = [value description];
    return string.length > 0 ? string : nil;
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

- (BOOL)windowShouldClose:(id)sender {
    [self hidePanel];
    return NO;
}

- (void)windowDidMove:(NSNotification *)notification {
    [self saveFrame];
}

- (void)windowDidResize:(NSNotification *)notification {
    if (self.gridView) {
        [self resizeDocumentViewForCurrentGridPreservingScroll];
    }
    [self saveFrame];
}

- (void)resizeDocumentViewForCurrentGridPreservingScroll {
    if (!self.gridView) {
        return;
    }

    CGFloat width = (LumenDebugGridPadding * 2.0) + LumenDebugMetricColumnWidth;
    width += self.renderedDisplayKeys.count * LumenDebugDisplayColumnWidth;
    width += self.renderedDisplayKeys.count * LumenDebugGridColumnSpacing;

    CGFloat height = (LumenDebugGridPadding * 2.0);
    height += (self.renderedMetricKeys.count + 1) * LumenDebugRowHeight;
    height += self.renderedMetricKeys.count * LumenDebugGridRowSpacing;
    [self resizeDocumentViewForGridContentSize:NSMakeSize(width, height) scrollToTop:NO];
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
