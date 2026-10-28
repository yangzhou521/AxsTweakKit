#import "AxsTweakKitConfig.h"
#import "AxsTweakKitPreferences.h"

#include <math.h>

// Read-only settings for the injected dylib.
//
// The panel is the single writer of the preference file; this class only
// reads it. There is deliberately no NSUserDefaults / CFPreferences access
// here: cfprefsd is not touched from a constructor, and no default value is
// ever persisted.

@interface AxsTweakKitConfig ()
@property (atomic, copy) NSDictionary *axsTweakKitSnapshot;
@property (nonatomic, strong) dispatch_queue_t axsTweakKitReloadQueue;
- (void)axsTweakKitReloadNow;
@end

static void AxsTweakKitPreferencesDidChange(CFNotificationCenterRef center, void *observer,
                                            CFStringRef name, const void *object,
                                            CFDictionaryRef userInfo) {
    AxsTweakKitConfig *config = (__bridge AxsTweakKitConfig *)observer;
    [config axsTweakKitReload];
}

@implementation AxsTweakKitConfig

+ (instancetype)axsTweakKitSharedConfig {
    static AxsTweakKitConfig *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[AxsTweakKitConfig alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _axsTweakKitReloadQueue =
            dispatch_queue_create("com.axs.axstweakkit.config", DISPATCH_QUEUE_SERIAL);
        // First read is synchronous: hooks installed after the constructor
        // already see the saved values.
        _axsTweakKitSnapshot = AxsTweakKitReadPreferences();

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, AxsTweakKitPreferencesDidChange,
            (__bridge CFStringRef)AxsTweakKitPreferencesNotification, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        // Close the window between that first read and the observer above.
        dispatch_async(_axsTweakKitReloadQueue, ^{
            [self axsTweakKitReloadNow];
        });
    }
    return self;
}

- (void)axsTweakKitReload {
    dispatch_async(self.axsTweakKitReloadQueue, ^{
        [self axsTweakKitReloadNow];
    });
}

// Always on the serial reload queue.
- (void)axsTweakKitReloadNow {
    self.axsTweakKitSnapshot = AxsTweakKitReadPreferences();
    // Local notification for views that need to redraw; the Darwin
    // notification itself is the signal between processes.
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:AxsTweakKitPreferencesNotification object:self];
    });
}

- (BOOL)axsTweakKitEnabled {
    return [self axsTweakKitBoolForKey:@"enabled" defaultValue:NO];
}

- (double)axsTweakKitIntensity {
    double value = [self axsTweakKitDoubleForKey:@"intensity" defaultValue:0.5];
    // UI clamping is not validation: clamp again where the value is used.
    return fmin(1.0, fmax(0.0, value));
}

- (BOOL)axsTweakKitBoolForKey:(NSString *)key defaultValue:(BOOL)defaultValue {
    id value = key.length > 0 ? self.axsTweakKitSnapshot[key] : nil;
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : defaultValue;
}

- (double)axsTweakKitDoubleForKey:(NSString *)key defaultValue:(double)defaultValue {
    id value = key.length > 0 ? self.axsTweakKitSnapshot[key] : nil;
    double number = [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : defaultValue;
    return isfinite(number) ? number : defaultValue;
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end