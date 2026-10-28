#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "AxsTweakKitConfig.h"
#import "AxsTweakKitLog.h"

// Hook skeleton. Plain Objective-C with MSHookMessageEx — no Logos, no .xm.
//
// Every hook here:
//   * keeps its function, its saved original and its globals `static`, so it
//     never collides with another tweak in SpringBoard;
//   * names anything added to a system class with the AxsTweakKit prefix;
//   * calls the original, and does nothing else while `enabled` is off.
//
// The filter beside this dylib limits it to com.apple.springboard; a class
// this file hooks must exist there.

#pragma mark - SpringBoard: launch

typedef void (*AxsTweakKitApplicationDidFinishLaunchingIMP)(id, SEL, id);

static AxsTweakKitApplicationDidFinishLaunchingIMP
    AxsTweakKitOriginalApplicationDidFinishLaunching = NULL;

static void AxsTweakKitHookedApplicationDidFinishLaunching(id self, SEL _cmd, id application) {
    if (AxsTweakKitOriginalApplicationDidFinishLaunching != NULL) {
        AxsTweakKitOriginalApplicationDidFinishLaunching(self, _cmd, application);
    }

    // Read the snapshot; never the file, never defaults, on this path.
    AxsTweakKitConfig *config = [AxsTweakKitConfig axsTweakKitSharedConfig];
    if (![config axsTweakKitEnabled]) {
        return;  // Off means the original behaviour and nothing else.
    }

    // The plugin's launch work goes here. The line below is the skeleton's
    // own proof that the hook ran with a live snapshot; keep or replace it.
    AxsTweakKitLogDefault("AxsTweakKit launch hook ran, intensity %.2f",
                          [config axsTweakKitIntensity]);
}

#pragma mark - Installation

static void AxsTweakKitInstallHooks(void) {
    Class springBoard = objc_getClass("SpringBoard");
    if (springBoard == Nil) {
        AxsTweakKitLogError("AxsTweakKit: SpringBoard class not found, hooks not installed");
        return;
    }

    MSHookMessageEx(springBoard, @selector(applicationDidFinishLaunching:),
                    (IMP)AxsTweakKitHookedApplicationDidFinishLaunching,
                    (IMP *)&AxsTweakKitOriginalApplicationDidFinishLaunching);

    // The next hook looks like this — narrowest method that produces the
    // behaviour, original called, snapshot read, `enabled` respected:
    //
    //   typedef void (*AxsTweakKitFooIMP)(id, SEL, id);
    //   static AxsTweakKitFooIMP AxsTweakKitOriginalFoo = NULL;
    //   static void AxsTweakKitHookedFoo(id self, SEL _cmd, id argument) {
    //       if (AxsTweakKitOriginalFoo != NULL) AxsTweakKitOriginalFoo(self, _cmd, argument);
    //       if (![[AxsTweakKitConfig axsTweakKitSharedConfig] axsTweakKitEnabled]) return;
    //       // ... the tweak's work ...
    //   }
    //   MSHookMessageEx(objc_getClass("SomeClass"), @selector(foo:),
    //                   (IMP)AxsTweakKitHookedFoo, (IMP *)&AxsTweakKitOriginalFoo);
    //
    // A class method hooks the metaclass:
    //   MSHookMessageEx(object_getClass(objc_getClass("SomeClass")), @selector(foo),
    //                   (IMP)AxsTweakKitHookedFoo, (IMP *)&AxsTweakKitOriginalFoo);
}

#pragma mark - Startup

__attribute__((constructor)) static void AxsTweakKitInitialize(void) {
    @autoreleasepool {
        // Heard by apelin_package_confirm_loaded while it listens.
        AxsTweakKitLogLoadedMarker();

        // Snapshot first, so the hooked code below only ever reads memory.
        [AxsTweakKitConfig axsTweakKitSharedConfig];

        AxsTweakKitInstallHooks();
    }
}