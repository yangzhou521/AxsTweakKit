#pragma once

#import <Foundation/Foundation.h>

// A read-only snapshot of the preference file, shared by every hook in this
// process. Nothing here writes: no defaults are persisted, no file is created,
// and `enabled == NO` means every hook keeps the original behaviour.
//
// The snapshot is re-read when the panel posts the package's Darwin
// notification; hot hooks only ever touch the in-memory dictionary.
@interface AxsTweakKitConfig : NSObject

+ (instancetype)axsTweakKitSharedConfig;

// The shared instance reads the preference file once, synchronously, so a
// hook that runs right after the constructor sees the saved values.

@property (nonatomic, readonly) BOOL axsTweakKitEnabled;      // key "enabled",   default NO
@property (nonatomic, readonly) double axsTweakKitIntensity;  // key "intensity", default 0.5, clamped to [0, 1]

- (BOOL)axsTweakKitBoolForKey:(NSString *)key defaultValue:(BOOL)defaultValue;
- (double)axsTweakKitDoubleForKey:(NSString *)key defaultValue:(double)defaultValue;

// Called by the Darwin notification observer; also safe to call by hand.
- (void)axsTweakKitReload;

@end