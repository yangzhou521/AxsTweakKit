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

## NotesReadOnly — `com.unknown.notesreadonly` (备忘录只读)

A second product lives in this workspace: a MobileNotes-only tweak (`NotesReadOnly/`)
plus its cloud build, added because this device has no toolchain (see above).

- Source `NotesReadOnly/Sources/NotesReadOnly.m`, filter `NotesReadOnly/Support/NotesReadOnly.plist`
  (`Filter/Bundles = com.apple.mobilenotes`), build `.github/workflows/notesreadonly.yml`
  → `scripts/build-notesreadonly.sh` (same clang + ldid + dpkg-deb shape as `scripts/build.sh`).
- 1.0.7 (shipped by someone else) was arm64e-only, so A11 never loaded it. **Every
  roothide build here must carry arm64 as well as arm64e** — 1.0.8 has both.
- 1.0.8 is built, published and verified on this device (2026-10-29). Release asset:
  `https://github.com/yangzhou521/AxsTweakKit/releases/download/notesreadonly-v1.0.8/com.unknown.notesreadonly_1.0.8_iphoneos-arm64e.deb`
  (sha256 `02d39c7a447e10bb55443f2e0686c719ef688ab93a438bd26cf88a58865f829d`).
- Install from the device only through irisin-cli, and only with the real-root path
  (`/rootfs/…`); the jbroot spelling is not found:
  `irisin-cli install --yes --json /rootfs/var/mobile/Documents/<deb>` (as root).
- Then, and this is the step that is easy to get wrong: **relaunch the target** so the
  dylib is mapped, then look for the diagnostics the tweak writes on load.
  `icli app kill com.apple.mobilenotes --force` (kill needs `--force`),
  `icli app launch com.apple.mobilenotes`, then
  `icli prefs read com.apple.mobilenotes NotesReadOnlyDiagnostics`. Expected:
  `v1.0.8;hooks=25;classes=ICTextView,ICBaseTextView,NoteHTMLEditorView,UITextView;menu=item;locked=0`.
  Missing diagnostics almost always means the process was never restarted, not that the
  tweak failed to inject. Second channel, same string, inside the Notes container:
  `Documents/NotesReadOnlyDiagnostics.txt`.
- UI: in a note the toggle sits in the `•••` menu (`menu=item`); on the folders screen
  there is no right item carrying a menu, so the fallback appends its own `只读` button
  (`bar`). The switch is `NotesReadOnlyEnabled`, default `NO`.
- `icli prefs read <domain> <key>` takes the key positionally (`--key` is rejected).

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
  attaches both debs to a v1.0.0 Release on manual runs. Run history:
  - runs 1–6 (commits 547f461, d0d32e6, a78a661, 979469b) all failed at
    Build Package: first `-lsubstrate` cannot resolve, then, once substrate
    was fixed, `_CGRectGetWidth` / `_CGRectGetHeight` / `_CGRectZero`
    undefined — the headerless SDK's `UIKit.tbd` does not reexport
    CoreGraphics (Foundation still reexports CoreFoundation, so the dylib's
    `CFNotificationCenter*` was fine).
  - run 7 (ec684ef, 2026-10-28) is GREEN on both matrix legs: the fixes are
    `-Ftheos/vendor/lib -framework CydiaSubstrate` for substrate and
    `-framework CoreGraphics` on both products (`$FRAMEWORKS` in
    `scripts/build.sh`, `frameworks` in `Docs/apelin-project.tweak.json`).
    Do not drop CoreGraphics to "fix" a link; any further CGRect/CG use needs
    it too.
  - No Release exists yet: the release job runs only on `workflow_dispatch`,
    so publishing v1.0.0 takes one manual "Run workflow" on master. A push
    run only builds (artifacts are downloadable, Release is not created).
  - Re-running an old failed run rebuilds that run's old commit and fails
    identically. Always "Run workflow" on master instead. The Build Package
    step now prints the commit and a sha256 of `scripts/build.sh`, so a log
    says which tree it came from.

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