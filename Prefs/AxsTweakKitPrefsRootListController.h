#pragma once

#import <Preferences/PSListController.h>

// The bundle's principal class (Info.plist NSPrincipalClass) and the class the
// PreferenceLoader entry names. It is the only code allowed to write the
// package's preference file.
@interface AxsTweakKitPrefsRootListController : PSListController
@end