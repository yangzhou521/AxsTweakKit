#import "AxsTweakKitPrefsStore.h"
#import "AxsTweakKitPreferences.h"

static NSString *const AxsTweakKitPrefsStoreErrorDomain = @"com.axs.axstweakkit";

@implementation AxsTweakKitPrefsStore

+ (NSDictionary *)axsTweakKitValues {
    NSString *path = AxsTweakKitPreferencesPath();
    NSDictionary *values = path.length > 0 ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    if ([values isKindOfClass:[NSDictionary class]]) {
        return values;
    }
    // Compatibility read, not a second writable location: values an earlier
    // build stored through cfprefsd are visible until the file exists.
    NSUserDefaults *defaults =
        [[NSUserDefaults alloc] initWithSuiteName:AxsTweakKitPreferencesDomain];
    NSDictionary *persisted = [defaults persistentDomainForName:AxsTweakKitPreferencesDomain];
    return [persisted isKindOfClass:[NSDictionary class]] ? persisted : @{};
}

+ (BOOL)axsTweakKitWriteValue:(id)value forKey:(NSString *)key error:(NSError **)error {
    NSString *path = AxsTweakKitPreferencesPath();
    if (key.length == 0 || path.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:AxsTweakKitPrefsStoreErrorDomain code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"偏好设置路径或键无效。"}];
        }
        return NO;
    }

    NSFileManager *manager = [NSFileManager defaultManager];
    NSMutableDictionary *values = nil;

    if ([manager fileExistsAtPath:path]) {
        NSData *existing = [NSData dataWithContentsOfFile:path options:0 error:error];
        if (existing == nil) {
            return NO;
        }
        id decoded = [NSPropertyListSerialization propertyListWithData:existing
                                                              options:NSPropertyListMutableContainers
                                                               format:NULL
                                                                error:error];
        if (![decoded isKindOfClass:[NSDictionary class]]) {
            if (error && *error == nil) {
                *error = [NSError errorWithDomain:AxsTweakKitPrefsStoreErrorDomain code:2
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                        @"偏好设置文件不是字典，未覆盖。"}];
            }
            return NO;
        }
        values = [decoded mutableCopy];
    } else {
        values = [[self axsTweakKitValues] mutableCopy];
    }

    if (value != nil) {
        values[key] = value;
    } else {
        [values removeObjectForKey:key];
    }

    if (![manager createDirectoryAtPath:[path stringByDeletingLastPathComponent]
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:error]) {
        return NO;
    }

    NSData *data = [NSPropertyListSerialization dataWithPropertyList:values
                                                             format:NSPropertyListBinaryFormat_v1_0
                                                            options:0
                                                              error:error];
    if (data == nil || ![data writeToFile:path options:NSDataWritingAtomic error:error]) {
        return NO;
    }

    // Mirror the whole snapshot so cfprefsd cannot flush stale unrelated keys.
    NSUserDefaults *defaults =
        [[NSUserDefaults alloc] initWithSuiteName:AxsTweakKitPreferencesDomain];
    [defaults setPersistentDomain:values forName:AxsTweakKitPreferencesDomain];
    [defaults synchronize];

    // Signal only; the tweak re-reads the file it just saw replaced.
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)AxsTweakKitPreferencesNotification,
                                         NULL, NULL, true);
    return YES;
}

@end