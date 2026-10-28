#pragma once

#import <Foundation/Foundation.h>
#import "ApelinBootstrap.h"

// One domain, one file, one Darwin notification, shared by both products.
// The preference bundle is the only writer; the tweak only reads a snapshot.
//
// The domain is the package id and never changes: it ties the panel, the
// tweak and any later migration to the same preferences.

#define AxsTweakKitPreferencesDomain @"com.axs.axstweakkit"
#define AxsTweakKitPreferencesNotification @"com.axs.axstweakkit.preferences-changed"

// AXS_TWEAKKIT_PREFS_IN_JBROOT:
//   0 (default) — the file lives in the system's mobile preferences folder,
//                 which is a SYSTEM path and therefore used as it is on both
//                 bootstraps. Do not run it through ApelinBootstrapPath().
//   1           — the file lives in the bootstrap's own var/mobile tree
//                 (roothide's jbroot()), for a jailbreak whose Settings
//                 process cannot reach the system folder. Set it for BOTH
//                 products together or the two sides read different files.
#ifndef AXS_TWEAKKIT_PREFS_IN_JBROOT
#define AXS_TWEAKKIT_PREFS_IN_JBROOT 0
#endif

static inline NSString *_Nullable AxsTweakKitPreferencesPath(void) {
    NSString *path = @"/var/mobile/Library/Preferences/" AxsTweakKitPreferencesDomain @".plist";
#if AXS_TWEAKKIT_PREFS_IN_JBROOT
    return ApelinBootstrapPath(path);
#else
    return path;
#endif
}

// The read side, used by the tweak and by the panel. A file that is missing,
// unreadable or not a dictionary reads as an empty dictionary: every consumer
// keeps its own coded default and nothing is ever written from a read path.
static inline NSDictionary *_Nonnull AxsTweakKitReadPreferences(void) {
    NSString *path = AxsTweakKitPreferencesPath();
    NSDictionary *values = path.length > 0 ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    return [values isKindOfClass:[NSDictionary class]] ? values : @{};
}