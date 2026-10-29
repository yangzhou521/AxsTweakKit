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
- **1.0.9 is built, published and verified on this device (2026-10-30).** Release asset:
  `https://github.com/yangzhou521/AxsTweakKit/releases/download/notesreadonly-v1.0.9/com.unknown.notesreadonly_1.0.9_iphoneos-arm64e.deb`
  (装机验证的那一份 sha256 `80851f621da2d7befc9a6c8f9a4756b15b542b122e153e125db1596f49cd6df4`,
  14704 B, fat dylib
  arm64 + arm64e). Built by `Build NotesReadOnly` run #6 on `a69d2d7` (green), installed over
  1.0.8 with irisin-cli over the real-root path. On-device checks after a Notes restart:
  `icli prefs read com.apple.mobilenotes NotesReadOnlyDiagnostics` →
  `v1.0.9;hooks=19;classes=ICTextView,ICBaseTextView,NoteHTMLEditorView,UITextView;menu=bar;…`;
  opening a note no longer crashes (no new MobileNotes crash report at all), and the toggle was
  exercised both ways (menu item on/off → `NotesReadOnlyEnabled`/`locked` follow) with editing
  blocked while read-only is on (no keyboard, system-level `icli input type` does not land) and
  working again with it off. `hooks=19` is the new per-site count; it is not comparable with
  1.0.8's 25 (one wrapper per class×selector, installed only where the class declares the method).
- **1.0.9 fixed a hard crash of 1.0.8**: opening a note killed Notes. 1.0.8 kept one set
  of wrappers plus a shared `(class, selector) → original IMP` table, so when
  `-[ICTextView setEditable:]` did `[super setEditable:]` and landed on the parent's site
  the lookup went by `self`'s class and handed back ICTextView's own "original" — the hook
  again — recursing thousands of frames until the stack blew (`memmove` in
  `AxsNotesReadOnlyOriginalIMP`). 1.0.9 gives every site its own wrapper and its own static
  original slot (`AXS_DEFINE_EDITOR_SITES` over `AXS_FOR_EACH_EDITOR_CLASS`) and installs a
  site only on a class that declares the method (`AxsClassDeclaresMethod`). Never go back
  to one lookup keyed by `object_getClass(self)`; the `super` chain is the whole reason.
- The release asset is **rebuilt by every `Build NotesReadOnly` run**, so its size and sha256
  change even when the source does not: the deb built from `71bff48` (2026-10-30) is 14680 B,
  sha256 `6a2511e064912be779a1bf83b032a36402c659be193e02278a5c60ec750cc6bf`, while what is
  installed and verified on this device is the `80851f…` one above. The workflow now carries a
  `paths` filter (`NotesReadOnly/**`, `scripts/build-notesreadonly.sh`, itself), so a docs-only
  push no longer triggers a rebuild and a re-release.
- Install from the device only through irisin-cli, and only with the real-root path
  (`/rootfs/…`); the jbroot spelling is not found:
  `irisin-cli install --yes --json /rootfs/var/mobile/Documents/<deb>` (as root).
- Then, and this is the step that is easy to get wrong: **relaunch the target** so the
  dylib is mapped, then look for the diagnostics the tweak writes on load.
  `icli app kill com.apple.mobilenotes --force` (kill needs `--force`),
  `icli app launch com.apple.mobilenotes`, then
  `icli prefs read com.apple.mobilenotes NotesReadOnlyDiagnostics`. Expected:
  `v1.0.8;hooks=25;classes=ICTextView,ICBaseTextView,NoteHTMLEditorView,UITextView;menu=item;locked=0`
  — that is the 1.0.8 string; from 1.0.9 the prefix is `v1.0.9` and `hooks` is larger
  (one site per class × selector).
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
  - Since 2026-10-30 the push trigger carries a `paths` filter (`Sources/`,
    `Prefs/`, `Shared/`, the filter plist, `scripts/build.sh`, the manifests,
    itself): the docs-only push of `6a5edef` had cost a full two-leg run for
    nothing. `workflow_dispatch` ignores `paths`, so a manual release is
    unaffected.

## Carrying the know-how (skills, template, naming)

- `Skills/a11-roothide-ondevice/SKILL.md` — a mirror of the on-device Apelin skill
  of the same name (the cloud-build loop, the roothide install/verify steps, the
  hook-structure rules). Keep the two copies in step; the device copy is the one
  Apelin reads.
- `Templates/AxsDualSlice/` — a starter tweak in the same shape as NotesReadOnly:
  dual slice (arm64 + arm64e), 一站一槽 sites, load-time diagnostics, CI with a
  `paths` filter. **Unverified as a package** — nothing has installed it; its
  parts are copied from the two builds that were verified on this device.
- Naming used from here on: **「一站一槽」/ Per-Site Original Slot** for the hook
  structure (R1: each site its own static original-IMP slot; R2: 声明者才挂 /
  Declared-Owner Install), and **「A11 双切片云编译闭环」** for the whole path from
  source to a verified install. 1.0.8's crash is what violating R1 looks like.

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