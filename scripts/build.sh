#!/bin/sh
#
# AxsTweakKit — builds one bootstrap's .deb without Theos.
#
# This is the scripted form of the README's steps: clang, ldid and dpkg-deb
# from the prepared toolchain, one package written into $APELIN_PACKAGE_DIR
# (or ./build). It is NOT verified on this device — see README.
#
# Run it from the project root:   sh scripts/build.sh
# One bootstrap at a time:        APELIN_BOOTSTRAP=rootless sh scripts/build.sh
#
# Environment it honours:
#   APELIN_BOOTSTRAP      roothide (default) or rootless
#   APELIN_PACKAGE_DIR    where the .deb goes (default ./build)
#   APELIN_BUILD_ID       the marker id compiled in (default: a timestamp)
#   APELIN_CONFIGURATION  debug (default) or release
#   SDKROOT               used as -isysroot when set
#   SUBSTRATE_CFLAGS      extra flags that put substrate.h on the include path
#   SUBSTRATE_LDFLAGS     how substrate is linked (default -lsubstrate)
#   PREFS_LDFLAGS         overrides the private-framework search path
#
set -eu

# ---- identity: keep in step with Docs/apelin-project.tweak.json ----
PACKAGE_ID=com.axs.axstweakkit
VERSION=1.0.0
TWEAK_NAME=AxsTweakKit
PREFS_NAME=AxsTweakKitPrefs
MIN_IOS=16.0

cd "$(dirname "$0")/.."

BOOTSTRAP=${APELIN_BOOTSTRAP:-roothide}
CONFIGURATION=${APELIN_CONFIGURATION:-debug}
BUILD_ID=${APELIN_BUILD_ID:-$(date +%Y%m%d%H%M%S)}
OUTDIR=${APELIN_PACKAGE_DIR:-build}

case "$BOOTSTRAP" in
  roothide)
    # A11 and earlier need an arm64 slice in the dylib; the package tag stays
    # iphoneos-arm64e.
    ARCHS="arm64 arm64e"
    BOOTSTRAP_DEFINE=APELIN_BOOTSTRAP_ROOTHIDE
    PREFIX=""
    ARCH=iphoneos-arm64e
    ;;
  rootless)
    ARCHS="arm64 arm64e"
    BOOTSTRAP_DEFINE=APELIN_BOOTSTRAP_ROOTLESS
    PREFIX=/var/jb
    ARCH=iphoneos-arm64
    ;;
  *)
    echo "build.sh: unknown APELIN_BOOTSTRAP '$BOOTSTRAP'" >&2
    exit 2
    ;;
esac
ARCH=${APELIN_ARCHITECTURE:-$ARCH}

SYSROOT_FLAG=""
if [ -n "${SDKROOT:-}" ]; then
  SYSROOT_FLAG="-isysroot $SDKROOT"
fi

OPT="-O0 -g"
if [ "$CONFIGURATION" = "release" ]; then
  OPT="-O2"
fi

SUBSTRATE_CFLAGS=${SUBSTRATE_CFLAGS:-}
SUBSTRATE_LDFLAGS=${SUBSTRATE_LDFLAGS:--lsubstrate}

PREFS_LDFLAGS=${PREFS_LDFLAGS:-}
if [ -z "$PREFS_LDFLAGS" ] && [ -n "${SDKROOT:-}" ] &&
   [ -d "$SDKROOT/System/Library/PrivateFrameworks/Preferences.framework" ]; then
  PREFS_LDFLAGS="-F$SDKROOT/System/Library/PrivateFrameworks"
fi

SHARED_FLAGS="-fobjc-arc -fvisibility=hidden -miphoneos-version-min=$MIN_IOS \
-I Shared -I Prefs $SYSROOT_FLAG $OPT \
-DAPELIN_PACKAGE_ID=\"$PACKAGE_ID\" -DAPELIN_BUILD_ID=\"$BUILD_ID\" \
-D$BOOTSTRAP_DEFINE=1"

echo "build.sh: $BOOTSTRAP / $CONFIGURATION / $BUILD_ID"

rm -rf build/thin build/out build/stage
mkdir -p build/thin build/out build/stage

for arch in $ARCHS; do
  mkdir -p "build/thin/$arch"

  # The tweak: a dylib, injected by substrate into SpringBoard only.
  # shellcheck disable=SC2086
  clang -dynamiclib -arch "$arch" $SHARED_FLAGS $SUBSTRATE_CFLAGS \
      -framework Foundation -framework UIKit \
      $SUBSTRATE_LDFLAGS \
      Sources/*.m \
      -o "build/thin/$arch/$TWEAK_NAME.dylib"

  # The pane: a loadable bundle whose principal class is the list controller.
  # shellcheck disable=SC2086
  clang -bundle -arch "$arch" $SHARED_FLAGS $PREFS_LDFLAGS \
      -framework Foundation -framework UIKit -framework Preferences \
      Prefs/*.m \
      -o "build/thin/$arch/$PREFS_NAME"
done

lipo -create build/thin/*/"$TWEAK_NAME.dylib" -output "build/out/$TWEAK_NAME.dylib"
lipo -create build/thin/*/"$PREFS_NAME" -output "build/out/$PREFS_NAME"

# Unsigned code does not load; the installer signs nothing for you.
ldid -S "build/out/$TWEAK_NAME.dylib"
ldid -S "build/out/$PREFS_NAME"

STAGE=build/stage
BUNDLE="$STAGE$PREFIX/Library/PreferenceBundles/$PREFS_NAME.bundle"
mkdir -p "$STAGE$PREFIX/Library/MobileSubstrate/DynamicLibraries" \
         "$BUNDLE" \
         "$STAGE$PREFIX/Library/PreferenceLoader/Preferences" \
         "$STAGE/DEBIAN"

cp "build/out/$TWEAK_NAME.dylib" \
   "$STAGE$PREFIX/Library/MobileSubstrate/DynamicLibraries/$TWEAK_NAME.dylib"
cp Support/AxsTweakKit.plist \
   "$STAGE$PREFIX/Library/MobileSubstrate/DynamicLibraries/$TWEAK_NAME.plist"
cp "build/out/$PREFS_NAME" "$BUNDLE/$PREFS_NAME"
cp Prefs/Resources/Info.plist "$BUNDLE/Info.plist"
cp Prefs/Resources/AxsTweakKitRoot.plist "$BUNDLE/AxsTweakKitRoot.plist"
cp Prefs/Resources/AxsTweakKitPrefs.plist \
   "$STAGE$PREFIX/Library/PreferenceLoader/Preferences/$PREFS_NAME.plist"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PACKAGE_ID
Name: $TWEAK_NAME
Version: $VERSION
Architecture: $ARCH
Author: Axs
Section: Tweaks
Depends: mobilesubstrate, preferenceloader
Description: Axs 约定风格的插件脚手架：hook 骨架、只读配置快照、设置面板与自定义滑条。
EOF

mkdir -p "$OUTDIR"
DEB="$OUTDIR/${PACKAGE_ID}_${VERSION}_${ARCH}.deb"
dpkg-deb -b --root-owner-group "$STAGE" "$DEB"
echo "build.sh: wrote $DEB"