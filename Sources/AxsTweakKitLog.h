#pragma once

#import <Foundation/Foundation.h>
#import <os/log.h>

// The build defines APELIN_PACKAGE_ID and APELIN_BUILD_ID. The fallbacks keep
// a manual build (scripts/build.sh without the defines) readable in Console
// instead of failing to compile.
#ifndef APELIN_PACKAGE_ID
#define APELIN_PACKAGE_ID "com.axs.axstweakkit"
#endif
#ifndef APELIN_BUILD_ID
#define APELIN_BUILD_ID "unversioned"
#endif

// One logger per process, subsystem = package id, so `apelin_log_read
// subsystem com.axs.axstweakkit` and `apelin_package_confirm_loaded` find
// every line this tweak writes.
static inline os_log_t AxsTweakKitLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create(APELIN_PACKAGE_ID, "tweak");
    });
    return log;
}

#define AxsTweakKitLogDefault(...) os_log(AxsTweakKitLog(), __VA_ARGS__)
#define AxsTweakKitLogInfo(...) os_log_info(AxsTweakKitLog(), __VA_ARGS__)
#define AxsTweakKitLogError(...) os_log_error(AxsTweakKitLog(), __VA_ARGS__)

// The marker apelin_package_confirm_loaded matches against its build id.
// Logged once, from the constructor. A literal with no format specifier and
// no %{public}: the whole line is one string, nothing gets redacted.
#define AxsTweakKitLogLoadedMarker() \
    os_log(AxsTweakKitLog(), "ApelinLoaded " APELIN_BUILD_ID)