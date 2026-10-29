#!/bin/sh
#
# AxsDualSlice —— 双切片（arm64 + arm64e）deb 的构建脚本。
#
# 形状与 scripts/build-notesreadonly.sh 一致（那份在本机与 CI 上都跑通过）：
# clang 直编，不依赖 Theos 的构建规则；只跑在 CI 的 macOS runner 上。
# 开发机是 iPhone10,1（A11），没有可用工具链，**不要在本机跑**。
#
# 用法（仓库根目录）：
#   sh scripts/build-dualslice.sh            # roothide：arm64 + arm64e（装本机的那一份）
#   sh scripts/build-dualslice.sh rootless   # rootless：arm64（未在设备上验证过）
#
# 环境变量：
#   THEOS               theos 检出目录（默认 ./theos）
#   SDKROOT             headerless iPhoneOS SDK（默认 $THEOS/sdks/iPhoneOS16.5.sdk）
#   APELIN_PACKAGE_DIR  .deb 输出目录（默认 packages）
#
set -eu

# ── 包身份：换项目时只改这一段 ────────────────────────────────────────
PRODUCT=AxsDualSliceTweak          # 产物 dylib 名，必须等于 Sources/<名>.m 的文件名
PACKAGE_ID=com.example.axsdualslice
VERSION=1.0.0
NAME_ZH=双切片示例
DESCRIPTION=双切片（arm64 + arm64e）示例插件：演示「一站一槽」钩子结构与加载诊断。
MAINTAINER=changeme
MIN_IOS=16.0
# ───────────────────────────────────────────────────────────────────

cd "$(dirname "$0")/.."

KIND=${1:-roothide}
case "$KIND" in
  roothide)
    # A11 用户态是 arm64：只出 arm64e 的 dylib 在任何进程里都不会被加载（1.0.7 的教训）。
    ARCHS="arm64 arm64e"
    ARCH_TAG=iphoneos-arm64e
    # 安装路径与 roothide 上其它 tweak 一致（/Library/MobileSubstrate/DynamicLibraries 是指向
    # /usr/lib/TweakInject 的软链），install name 走 .jbroot 相对形式。
    INSTALL_NAME="@loader_path/.jbroot/usr/lib/TweakInject/$PRODUCT.dylib"
    WANTED_SUBSTRATE="@loader_path/.jbroot/usr/lib/libsubstrate.dylib"
    ;;
  rootless)
    ARCHS="arm64"
    ARCH_TAG=iphoneos-arm64
    INSTALL_NAME="@loader_path/../../usr/lib/TweakInject/$PRODUCT.dylib"
    WANTED_SUBSTRATE="@loader_path/../libsubstrate.dylib"
    echo "build-dualslice.sh: 警告：rootless 腿没有被任何设备验证过（本模板只在 roothide/A11 上验过）" >&2
    ;;
  *)
    echo "usage: $0 [roothide|rootless]" >&2
    exit 2
    ;;
esac

THEOS=${THEOS:-theos}
SDKROOT=${SDKROOT:-$THEOS/sdks/iPhoneOS16.5.sdk}
OUTDIR=${APELIN_PACKAGE_DIR:-packages}

if [ ! -d "$SDKROOT" ]; then
  echo "build-dualslice.sh: SDK not found: $SDKROOT" >&2
  exit 2
fi
if [ ! -d "$THEOS/vendor/include" ]; then
  echo "build-dualslice.sh: $THEOS/vendor/include missing (submodules not checked out?)" >&2
  exit 2
fi
if [ ! -f "Sources/$PRODUCT.m" ]; then
  echo "build-dualslice.sh: Sources/$PRODUCT.m not found (PRODUCT must match the file name)" >&2
  exit 2
fi

# substrate：$THEOS/lib 里没有它，vendor/lib/libsubstrate.tbd 只是一行指向框架的指针。
if [ -d "$THEOS/vendor/lib/CydiaSubstrate.framework" ]; then
  SUBSTRATE_LDFLAGS="-F$THEOS/vendor/lib -framework CydiaSubstrate"
else
  SUBSTRATE_LDFLAGS="-lsubstrate"
fi

SHARED_FLAGS="-fobjc-arc -fvisibility=hidden -miphoneos-version-min=$MIN_IOS \
-isysroot $SDKROOT -O2 -I$THEOS/vendor/include"
# 该 SDK 的 UIKit.tbd 不 reexport CoreGraphics（Foundation 仍 reexport CoreFoundation），
# 凡用到 CGRect… 必须显式列出来，别为了"修"链接把它去掉。
FRAMEWORKS="-framework Foundation -framework UIKit -framework CoreGraphics"

BUILD=build/dualslice
DY="$BUILD/out/$PRODUCT.dylib"

echo "build-dualslice.sh: $PACKAGE_ID $VERSION kind=$KIND archs=$ARCHS"
echo "build-dualslice.sh: $(uname -s) $(uname -m)"
echo "build-dualslice.sh: SDKROOT=$SDKROOT"
echo "build-dualslice.sh: THEOS=$THEOS"

rm -rf "$BUILD/thin" "$BUILD/out" "$BUILD/stage"
mkdir -p "$BUILD/thin" "$BUILD/out" "$BUILD/stage"

for arch in $ARCHS; do
  mkdir -p "$BUILD/thin/$arch"
  echo "build-dualslice.sh: compiling $arch"
  # shellcheck disable=SC2086
  clang -dynamiclib -arch "$arch" $SHARED_FLAGS $FRAMEWORKS $SUBSTRATE_LDFLAGS \
      -install_name "$INSTALL_NAME" \
      "Sources/$PRODUCT.m" \
      -o "$BUILD/thin/$arch/$PRODUCT.dylib"
done

lipo -create "$BUILD"/thin/*/"$PRODUCT.dylib" -output "$DY"

# ---- 切片核对：arm64 + arm64e 缺一不可，缺了就 fail 掉，别把坏包发出去 ----
SLICES=$(lipo -archs "$DY")
echo "build-dualslice.sh: slices = $SLICES"
for want in $ARCHS; do
  case " $SLICES " in
    *" $want "*) ;;
    *) echo "build-dualslice.sh: missing $want slice in $DY" >&2; exit 4 ;;
  esac
done

# ---- 依赖形状核对：substrate 必须是相对安装路径，否则本机解析不到 ----
echo "build-dualslice.sh: --- otool -L (before) ---"
otool -L "$DY"
# 依赖名是 CydiaSubstrate（大写 S）：匹配要忽略大小写，否则会误判成"没有 substrate 依赖"。
SUBSTRATE_ENTRY=$(otool -L "$DY" | awk 'tolower($0) ~ /substrate/ {print $1; exit}')
if [ -z "$SUBSTRATE_ENTRY" ]; then
  echo "build-dualslice.sh: no substrate dependency at all" >&2
  exit 5
fi
if [ "$SUBSTRATE_ENTRY" != "$WANTED_SUBSTRATE" ]; then
  echo "build-dualslice.sh: rewriting $SUBSTRATE_ENTRY -> $WANTED_SUBSTRATE"
  install_name_tool -change "$SUBSTRATE_ENTRY" "$WANTED_SUBSTRATE" "$DY"
fi
SUBSTRATE_ENTRY=$(otool -L "$DY" | awk 'tolower($0) ~ /substrate/ {print $1; exit}')
if [ "$SUBSTRATE_ENTRY" != "$WANTED_SUBSTRATE" ]; then
  echo "build-dualslice.sh: substrate entry is '$SUBSTRATE_ENTRY', wanted '$WANTED_SUBSTRATE'" >&2
  exit 6
fi
echo "build-dualslice.sh: --- otool -L (after) ---"
otool -L "$DY"

# 没签名的 dylib 不加载。
ldid -S "$DY"

# ---- 打包 ----
STAGE="$BUILD/stage"
mkdir -p "$STAGE/Library/MobileSubstrate/DynamicLibraries" "$STAGE/DEBIAN"
cp "$DY" "$STAGE/Library/MobileSubstrate/DynamicLibraries/$PRODUCT.dylib"
cp "Support/$PRODUCT.plist" \
   "$STAGE/Library/MobileSubstrate/DynamicLibraries/$PRODUCT.plist"

plutil -lint "$STAGE/Library/MobileSubstrate/DynamicLibraries/$PRODUCT.plist"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PACKAGE_ID
Version: $VERSION
Architecture: $ARCH_TAG
Name: $NAME_ZH
Section: Tweaks
Maintainer: $MAINTAINER
Depends: firmware (>= $MIN_IOS), mobilesubstrate
Description: $DESCRIPTION
EOF

mkdir -p "$OUTDIR"
DEB="$OUTDIR/${PACKAGE_ID}_${VERSION}_${ARCH_TAG}.deb"
dpkg-deb -b --root-owner-group "$STAGE" "$DEB"

echo "build-dualslice.sh: --- deb contents ---"
dpkg-deb -c "$DEB"
echo "build-dualslice.sh: --- deb control ---"
dpkg-deb -I "$DEB"
echo "build-dualslice.sh: sha256 $DEB = $(shasum -a 256 "$DEB" | awk '{print $1}')"
echo "build-dualslice.sh: wrote $DEB"
