// Copyright (c) Anish Athalye (me@anishathalye.com)
// Released under GPLv3. See the included LICENSE.txt for details

#import "Model.h"
#import "Constants.h"
#import "util.h"
#import "NSArray+Functional.h"

@interface XYPoint : NSObject

@property float x;
@property float y;

- (id)initWithX:(float)x andY:(float)y;

@end

@implementation XYPoint

- (id)initWithX:(float)x andY:(float)y {
    self = [super init];
    if (self) {
        self.x = x;
        self.y = y;
    }
    return self;
}

- (NSDictionary *)asDictionary {
    return @{@"x": [NSNumber numberWithFloat:self.x],
             @"y": [NSNumber numberWithFloat:self.y]};
}

- (id)initWithDictionary:(NSDictionary *)dictionary {
    self = [super init];
    if (self && [dictionary isKindOfClass:[NSDictionary class]]) {
        NSNumber *x = [dictionary objectForKey:@"x"];
        if ([x isKindOfClass:[NSNumber class]]) {
            self.x = [x floatValue];
        }
        NSNumber *y = [dictionary objectForKey:@"y"];
        if ([y isKindOfClass:[NSNumber class]]) {
            self.y = [y floatValue];
        }
    }
    return self;
}

@end

@interface Model ()

@property (nonatomic, strong) NSMutableArray *points;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<XYPoint *> *> *pointsByDisplayKey;
@property (nonatomic, strong) NSArray<XYPoint *> *legacySeedPoints;

@end

@implementation Model

- (id)init {
    self = [super init];
    if (self) {
        self.points = [NSMutableArray new];
        self.pointsByDisplayKey = [NSMutableDictionary new];
        self.legacySeedPoints = @[];
        [self restoreDefaults];
    }
    return self;
}

- (void)observeOutput:(float)output forInput:(float)input {
    [self observeOutput:output forInput:input points:self.points];
    [self synchronizeDefaults];
}

- (float)predictFromInput:(float)input {
    return [self predictFromInput:input points:self.points];
}

- (void)ensureModelForDisplayKey:(NSString *)displayKey seedWithLegacyDefaults:(BOOL)seedWithLegacyDefaults {
    if (displayKey.length == 0 || self.pointsByDisplayKey[displayKey]) {
        return;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL alreadyMigrated = [defaults boolForKey:DEFAULTS_CALIBRATION_POINTS_MIGRATED];

    if (seedWithLegacyDefaults && !alreadyMigrated && self.legacySeedPoints.count > 0) {
        // Existing Lumen installs had one global model. Seed only the built-in display
        // because that is the old behavior's target and least surprising upgrade path.
        self.pointsByDisplayKey[displayKey] = [[self copyPoints:self.legacySeedPoints] mutableCopy];
        [defaults setBool:YES forKey:DEFAULTS_CALIBRATION_POINTS_MIGRATED];
        NSLog(@"Migrated %lu legacy calibration points to display key %@",
              (unsigned long)self.legacySeedPoints.count,
              displayKey);
        [self synchronizeDefaults];
        return;
    }

    self.pointsByDisplayKey[displayKey] = [NSMutableArray new];
    if (seedWithLegacyDefaults && !alreadyMigrated) {
        [defaults setBool:YES forKey:DEFAULTS_CALIBRATION_POINTS_MIGRATED];
    }
}

- (void)observeOutput:(float)output forInput:(float)input displayKey:(NSString *)displayKey {
    NSMutableArray<XYPoint *> *points = [self pointsForDisplayKey:displayKey];
    [self observeOutput:output forInput:input points:points];
    [self synchronizeDefaults];
}

- (float)predictFromInput:(float)input displayKey:(NSString *)displayKey {
    return [self predictFromInput:input points:[self pointsForDisplayKey:displayKey]];
}

- (BOOL)hasLearnedDataForDisplayKey:(NSString *)displayKey {
    return [self pointsForDisplayKey:displayKey].count > 0;
}

- (void)observeOutput:(float)output forInput:(float)input points:(NSMutableArray<XYPoint *> *)points {
    // add point
    XYPoint *point = [[XYPoint alloc] initWithX:input andY:output];
    [points addObject:point];
    // ensure that they're sorted
    [points sortUsingComparator:^NSComparisonResult(XYPoint *obj1, XYPoint *obj2) {
        float first = obj1.x;
        float second = obj2.x;
        if (first < second) {
            return NSOrderedAscending;
        } else if (first > second) {
            return NSOrderedDescending;
        } else {
            return NSOrderedSame;
        }
    }];
    // get current inserted point
    NSInteger index = [points indexOfObject:point];
    // remove points that are not monotonically nonincreasing / not spaced apart enough
    NSMutableIndexSet *toDelete = [NSMutableIndexSet new];
    float prevx = point.x, prevy = point.y;
    for (NSInteger i = index - 1; i >= 0; i--) {
        XYPoint *p = [points objectAtIndex:i];
        if (p.y < prevy || (prevx - p.x) < MIN_X_SPACING) {
            [toDelete addIndex:i];
        } else {
            prevx = p.x;
            prevy = p.y;
        }
    }
    prevx = point.x;
    prevy = point.y; // reset these
    for (NSInteger i = index + 1; i < points.count; i++) {
        XYPoint *p = [points objectAtIndex:i];
        if (p.y > prevy || (p.x - prevx) < MIN_X_SPACING) {
            [toDelete addIndex:i];
        } else {
            prevx = p.x;
            prevy = p.y;
        }
    }
    [points removeObjectsAtIndexes:toDelete];
}

- (float)predictFromInput:(float)input points:(NSArray<XYPoint *> *)points {
    // nearest neighbor
    float bestdiff = FLT_MAX, besty = DEFAULT_BRIGHTNESS;
    for (XYPoint *p in points) {
        float diff = fabsf(p.x - input);
        if (diff < bestdiff) {
            bestdiff = diff;
            besty = p.y;
        }
    }
    return besty;

    /*
    // find neighbors on left and right
    // and linear interpolate between them

    if (self.points.count == 0) {
        return DEFAULT_BRIGHTNESS;
    }

    XYPoint *first = [self.points firstObject];
    if (input <= first.x) {
        return first.y; // can't interpolate, there's nothing to the left
    }
    NSUInteger index;
    for (index = 1; index < self.points.count; index++) {
        if (input < ((XYPoint *) [self.points objectAtIndex:index]).x) {
            break;
        }
    }
    if (index >= self.points.count) {
        return ((XYPoint *) [self.points lastObject]).y; // can't interpolate, nothing to the right
    }
    // interpolate
    XYPoint *left = [self.points objectAtIndex:(index - 1)];
    XYPoint *right = [self.points objectAtIndex:index];
    return linear_interpolate(left.x, left.y, right.x, right.y, input);
    */
}

- (void)restoreDefaults {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *points = [[defaults arrayForKey:DEFAULTS_CALIBRATION_POINTS] map:^(NSDictionary *point) {
        return [[XYPoint alloc] initWithDictionary:point];
    }];
    if (points) {
        self.points = [points mutableCopy];
        self.legacySeedPoints = [self copyPoints:points];
    }

    NSDictionary *pointsByDisplayKey = [defaults dictionaryForKey:DEFAULTS_DISPLAY_CALIBRATION_POINTS];
    if ([pointsByDisplayKey isKindOfClass:[NSDictionary class]]) {
        for (NSString *displayKey in pointsByDisplayKey) {
            NSArray *encodedPoints = pointsByDisplayKey[displayKey];
            if (![encodedPoints isKindOfClass:[NSArray class]]) {
                continue;
            }
            NSArray *decodedPoints = [encodedPoints map:^(NSDictionary *point) {
                return [[XYPoint alloc] initWithDictionary:point];
            }];
            self.pointsByDisplayKey[displayKey] = [decodedPoints mutableCopy];
        }
    }
}

- (void)synchronizeDefaults {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *encoded = [self.points map:^(XYPoint *point) {
        return [point asDictionary];
    }];
    [defaults setObject:encoded forKey:DEFAULTS_CALIBRATION_POINTS];

    NSMutableDictionary *encodedByDisplayKey = [NSMutableDictionary new];
    for (NSString *displayKey in self.pointsByDisplayKey) {
        NSArray *displayEncoded = [self.pointsByDisplayKey[displayKey] map:^(XYPoint *point) {
            return [point asDictionary];
        }];
        encodedByDisplayKey[displayKey] = displayEncoded;
    }
    [defaults setObject:encodedByDisplayKey forKey:DEFAULTS_DISPLAY_CALIBRATION_POINTS];
}

- (NSMutableArray<XYPoint *> *)pointsForDisplayKey:(NSString *)displayKey {
    if (displayKey.length == 0) {
        return self.points;
    }

    NSMutableArray<XYPoint *> *points = self.pointsByDisplayKey[displayKey];
    if (!points) {
        points = [NSMutableArray new];
        self.pointsByDisplayKey[displayKey] = points;
    }
    return points;
}

- (NSArray<XYPoint *> *)copyPoints:(NSArray<XYPoint *> *)points {
    NSMutableArray<XYPoint *> *copied = [NSMutableArray arrayWithCapacity:points.count];
    for (XYPoint *point in points) {
        [copied addObject:[[XYPoint alloc] initWithX:point.x andY:point.y]];
    }
    return copied;
}

@end
