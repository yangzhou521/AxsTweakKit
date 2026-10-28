// SPDX-License-Identifier: MIT
//
// ApelinBootstrap.h — spell a bootstrap path the way your own compiled
// code must open it, on both roothide and rootless, from one source.
//
// Your tweak or tool runs with Apple's ABI (not vroot), so it opens files
// at their real kernel path. A bootstrap path such as
//   /Library/MobileSubstrate/DynamicLibraries/X.dylib
// is NOT that: on rootless it is under /var/jb, on roothide under the
// randomly named jbroot this image was loaded from. ApelinBootstrapPath()
// makes it absolute. A SYSTEM path — /System, /usr/lib/libSystem.B.dylib,
// /var/mobile/Library/Preferences, an app container — is already real:
// pass it as it is, never through ApelinBootstrapPath().
//
// This is what roothide's jbroot() and rootless's ROOT_PATH_NS() do; it is
// here so the one source builds for both without libroothide or libroot.
// The build defines APELIN_BOOTSTRAP_ROOTHIDE or APELIN_BOOTSTRAP_ROOTLESS.
#pragma once

#import <Foundation/Foundation.h>
#import <dlfcn.h>

// The bootstrap's root as the kernel spells it, or nil if it cannot be
// found (roothide, no .jbroot- ancestor). Cached for the process; do not
// persist it — roothide renames the jbroot at every jailbreak.
static inline NSString *_Nullable ApelinBootstrapRoot(void) {
#ifdef APELIN_BOOTSTRAP_ROOTHIDE
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const char anchor = 0;
        Dl_info info;
        if (dladdr(&anchor, &info) == 0 || info.dli_fname == NULL) {
            return;
        }
        NSArray<NSString *> *parts =
            [@(info.dli_fname) componentsSeparatedByString:@"/"];
        for (NSUInteger i = 0; i < parts.count; i++) {
            if ([parts[i] hasPrefix:@".jbroot-"]) {
                root = [[parts subarrayWithRange:NSMakeRange(0, i + 1)]
                    componentsJoinedByString:@"/"];
                break;
            }
        }
    });
    return root;
#else
    return @"/var/jb";
#endif
}

// A bootstrap path (/Library/..., /usr/bin/x) as your code must open it.
// Nil only when the roothide root cannot be found; handle it.
static inline NSString *_Nullable ApelinBootstrapPath(NSString *_Nonnull path) {
    NSString *root = ApelinBootstrapRoot();
    return root == nil ? nil : [root stringByAppendingString:path];
}