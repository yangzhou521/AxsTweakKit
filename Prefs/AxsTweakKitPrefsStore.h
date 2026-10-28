#pragma once

#import <Foundation/Foundation.h>

// The one writer of the preference file.
//
// Rules, inherited from the Axs conventions:
//   * a value is written to the canonical file only;
//   * a missing file starts empty, it is never seeded from a global
//     dictionaryRepresentation;
//   * an unreadable or malformed file is reported as an error and left alone;
//   * a successful write mirrors the whole snapshot into NSUserDefaults and
//     then posts the package's Darwin notification;
//   * a failed write is shown to the user — the switch must not look saved.
@interface AxsTweakKitPrefsStore : NSObject

+ (NSDictionary *)axsTweakKitValues;
+ (BOOL)axsTweakKitWriteValue:(id)value forKey:(NSString *)key error:(NSError **)error;

@end