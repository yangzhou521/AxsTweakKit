# AGENTS.md — AxsTweakKit

## What this is

Source-only scaffold for a SpringBoard tweak plus its Settings pane, written to the
Axs conventions (prefixed names, one config writer, read-only snapshot in the tweak)
in the Apelin form (Objective-C + MSHookMessageEx, no Theos, no Logos).

Package id / preferences domain: `com.axs.axstweakkit`, version `1.0.0`.

## Build state — read this before touching anything

This device (iPhone10,1, A11, iOS 16.7.16, roothide) cannot install any Command Line
Tools: every release Apple offers needs `FEAT_LRCPC`, which A11 lacks. There is no
toolchain, so **`apelin_project_build` fails here and nothing has ever been compiled**.

Do not try to build, install, respring or confirm-loaded in this project on this device,
and do not change the environment to make a build possible. Say plainly that the source
is uncompiled and unverified.

## Why there is no build description in apelin-project.json

`apelin-project.json` here is Apelin's **workspace manifest** (`kind: workspace`,
`buildSystem: external`). Apelin checks it strictly and a workspace only runs one
`external.script`; tweak `products` / `package` members do not belong in it.

- The paste-ready tweak build description is `Docs/apelin-project.tweak.json`.
- `scripts/build.sh` is the scripted equivalent (clang + ldid + dpkg-deb), unverified.
- To drive the script from Apelin, add `"external": {"script": "scripts/build.sh",
  "interpreter": "sh", "arguments": []}` to the manifest, on a machine with a toolchain.

## Layout

- `Sources/` — dylib: config snapshot, log + marker, hook skeleton. Filtered to
  `com.apple.springboard` only.
- `Prefs/` — preference bundle: `PSListController` subclass, store (the only writer),
  custom slider cell, resources.
- `Shared/` — headers both products include (`headerSearchPaths: ["Shared"]`).
- `Support/AxsTweakKit.plist` — filter plist for `scripts/build.sh` only; an Apelin
  build uses `package.tweakFilter` instead and must not ship this file too.
- `.github/workflows/build.yml` — cloud build for this device: runs
  `scripts/build.sh` for roothide and rootless on a macOS runner (roothide/theos
  headers + theos/sdks iPhoneOS16.5, no Theos build system), uploads artifacts,
  attaches both debs to a v1.0.0 Release on manual runs. Two failed manual runs
  so far, both fixed and still unverified:
  - run 2: both legs failed at Build Package — `-lsubstrate` cannot resolve,
    because `$THEOS/lib` has no substrate and `vendor/lib/libsubstrate.tbd` is
    only a one-line pointer. Fixed to link `-Ftheos/vendor/lib -framework
    CydiaSubstrate` and to copy the fork's dyld flags (roothide install_name;
    rootless rpaths, on dylib and bundle).
  - run 3: compile passed, link failed for arm64 on `_CGRectGetWidth`,
    `_CGRectGetHeight`, `_CGRectZero` from `Prefs/AxsTweakKitSliderCell.m`.
    The headerless iPhoneOS16.5 SDK's `UIKit.tbd` does not reexport
    CoreGraphics, while Foundation still reexports CoreFoundation (the dylib's
    `CFNotificationCenter*` linked fine), so only CoreGraphics is listed by
    hand: `$FRAMEWORKS` in `scripts/build.sh` and `frameworks` in
    `Docs/apelin-project.tweak.json`, on both products. Any further CGRect/CG
    use needs it too; do not drop it to "fix" a link. Unverified until a run
    with this tree passes.

## Invariants

- Domain, notification name and file path live in `Shared/AxsTweakKitPreferences.h`;
  changing one means changing all three consistently.
- The pane writes; the tweak reads. No default value is ever persisted, and
  `enabled == NO` means the original behaviour only.
- Every class, file, C function and added selector carries `AxsTweakKit` / `axsTweakKit_`.
  Hook functions, saved originals and globals stay `static`.
- roothide: no `/var/jb`, no hard-coded jbroot. Package paths stay logical
  (`/Library/…`); code that opens a bootstrap file goes through
  `ApelinBootstrapPath()`.
- roothide builds carry an arm64 slice as well as arm64e (A11 userland is arm64);
  the package tag stays `iphoneos-arm64e`.