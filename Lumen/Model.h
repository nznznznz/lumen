// Copyright (c) Anish Athalye (me@anishathalye.com)
// Released under GPLv3. See the included LICENSE.txt for details

#import <Foundation/Foundation.h>

@interface Model : NSObject

- (void)observeOutput:(float)output forInput:(float)input;
- (float)predictFromInput:(float)input;

- (void)ensureModelForDisplayKey:(NSString *)displayKey seedWithLegacyDefaults:(BOOL)seedWithLegacyDefaults;
- (void)observeOutput:(float)output forInput:(float)input displayKey:(NSString *)displayKey;
- (float)predictFromInput:(float)input displayKey:(NSString *)displayKey;
- (BOOL)hasLearnedDataForDisplayKey:(NSString *)displayKey;
- (NSUInteger)debugSampleCountForDisplayKey:(NSString *)displayKey;
- (NSString *)debugLearnedPointsSummaryForDisplayKey:(NSString *)displayKey;
- (NSString *)debugRangeSummaryForDisplayKey:(NSString *)displayKey;

@end
