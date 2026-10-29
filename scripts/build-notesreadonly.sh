#!/bin/sh
#
# NotesReadOnly — 「备忘录只读」插件的构建脚本（roothide 包）。
#
# 这是 scripts/build.sh 的精简版：clang 直编，不依赖 Theos 的构建规则，只跑在 CI 的
# macOS runner 上。本机（iPhone10,1 / A11 / 16.7.16）没有可用工具链，**不要在本机跑**。
#
# 关键点：
#   * arm64 与 arm64e 各编一次再 lipo —— A11 的用户态是 arm64，只有 arm64e 切片的 dylib
#     根本不会被加载（这就是 1.0.7 那个包完全没生效的原因）。
#   * SDK 用 headerless 的 $THEOS/sdks/iPhoneOS16.5.sdk，私有头来自 $THEOS/vendor/include，
#     substrate 用 $THEOS/vendor/lib 里预编的 CydiaSubstrate.framework。
#   * 该 SDK 的 UIKit.tbd 不 reexport CoreGraphics，凡用到 CGRect… 必须显式
#     -framework CoreGraphics（这里保留，省得以后再踩）。
#
# 用法（仓库根目录）:   sh scripts/build-notesreadonly.sh
#
# 环境变量：
#   THEOS               theos 检出目录（默认 ./theos）
#   SDKROOT             headerless iPhoneOS SDK（默认 $THEOS/sdks/iPhoneOS16.5.sdk）
#   APELIN_PACKAGE_DIR  .deb 输出目录（默认 packages）
#
set -eu

# ---- 包身份：刻意与坏掉的 1.0.7 同名，就地升级替换 ----
PACKAGE_ID=com.unknown.notesreadonly
VERSION=1.0.8
PRODUCT=NotesReadOnly
MIN_IOS=16.0
ARCHS="arm64 arm64e"
ARCH_TAG=iphoneos-arm64e

cd "$(dirname "$0")/.."

THEOS=${THEOS:-theos}
SDKROOT=${SDKROOT:-$THEOS/sdks/iPhoneOS16.5.sdk}
OUTDIR=${APELIN_PACKAGE_DIR:-packages}

if [ ! -d "$SDKROOT" ]; then
  echo "build-notesreadonly.sh: SDK not found: $SDKROOT" >&2
  exit 2
fi
if [ ! -d "$THEOS/vendor/include" ]; then
  echo "build-notesreadonly.sh: $THEOS/vendor/include missing (submodules not checked out?)" >&2
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
FRAMEWORKS="-framework Foundation -framework UIKit -framework CoreGraphics"
# 自己的 install name 也走 .jbroot 相对形式，跟 roothide 里其它 tweak 一致。
INSTALL_NAME="@loader_path/.jbroot/usr/lib/TweakInject/$PRODUCT.dylib"
# 生效中的 tweak（0HelloMemoryStatus）就是这个形状；下面会核对，不是就改过来。
WANTED_SUBSTRATE="@loader_path/.jbroot/usr/lib/libsubstrate.dylib"

BUILD=build/notesreadonly
DY="$BUILD/out/$PRODUCT.dylib"

echo "build-notesreadonly.sh: $PACKAGE_ID $VERSION / $(uname -s) $(uname -m)"
echo "build-notesreadonly.sh: SDKROOT=$SDKROOT"
echo "build-notesreadonly.sh: THEOS=$THEOS"

rm -rf "$BUILD/thin" "$BUILD/out" "$BUILD/stage"
mkdir -p "$BUILD/thin" "$BUILD/out" "$BUILD/stage"

for arch in $ARCHS; do
  mkdir -p "$BUILD/thin/$arch"
  echo "build-notesreadonly.sh: compiling $arch"
  # shellcheck disable=SC2086
  clang -dynamiclib -arch "$arch" $SHARED_FLAGS $FRAMEWORKS $SUBSTRATE_LDFLAGS \
      -install_name "$INSTALL_NAME" \
      "NotesReadOnly/Sources/$PRODUCT.m" \
      -o "$BUILD/thin/$arch/$PRODUCT.dylib"
done

lipo -create "$BUILD"/thin/*/"$PRODUCT.dylib" -output "$DY"

# ---- 切片核对：arm64 + arm64e 缺一不可 ----
SLICES=$(lipo -archs "$DY")
echo "build-notesreadonly.sh: slices = $SLICES"
for want in $ARCHS; do
  case " $SLICES " in
    *" $want "*) ;;
    *) echo "build-notesreadonly.sh: missing $want slice in $DY" >&2; exit 4 ;;
  esac
done

# ---- 依赖形状核对：substrate 必须是 .jbroot 相对路径，否则本机解析不到 ----
echo "build-notesreadonly.sh: --- otool -L (before) ---"
otool -L "$DY"
# 注意：依赖名是 CydiaSubstrate（大写 S），匹配必须忽略大小写，否则会误判成"没有 substrate 依赖"。
SUBSTRATE_ENTRY=$(otool -L "$DY" | awk 'tolower($0) ~ /substrate/ {print $1; exit}')
if [ -z "$SUBSTRATE_ENTRY" ]; then
  echo "build-notesreadonly.sh: no substrate dependency at all" >&2
  exit 5
fi
if [ "$SUBSTRATE_ENTRY" != "$WANTED_SUBSTRATE" ]; then
  echo "build-notesreadonly.sh: rewriting $SUBSTRATE_ENTRY -> $WANTED_SUBSTRATE"
  install_name_tool -change "$SUBSTRATE_ENTRY" "$WANTED_SUBSTRATE" "$DY"
fi
# 注意：依赖名是 CydiaSubstrate（大写 S），匹配必须忽略大小写，否则会误判成"没有 substrate 依赖"。
SUBSTRATE_ENTRY=$(otool -L "$DY" | awk 'tolower($0) ~ /substrate/ {print $1; exit}')
if [ "$SUBSTRATE_ENTRY" != "$WANTED_SUBSTRATE" ]; then
  echo "build-notesreadonly.sh: substrate entry is '$SUBSTRATE_ENTRY', wanted '$WANTED_SUBSTRATE'" >&2
  exit 6
fi
echo "build-notesreadonly.sh: --- otool -L (after) ---"
otool -L "$DY"

# 没签名的 dylib 不加载。
ldid -S "$DY"

# ---- 打包 ----
# 安装路径与 1.0.7 一致（也在本机所有已装 tweak 的惯例里）：roothide 上
# /Library/MobileSubstrate/DynamicLibraries 是指向 /usr/lib/TweakInject 的软链，
# 所以物理落点就是 $JBROOT/usr/lib/TweakInject/$PRODUCT.dylib。同名同路径 = 干净的就地升级。
STAGE="$BUILD/stage"
mkdir -p "$STAGE/Library/MobileSubstrate/DynamicLibraries" "$STAGE/DEBIAN"
cp "$DY" "$STAGE/Library/MobileSubstrate/DynamicLibraries/$PRODUCT.dylib"
cp "NotesReadOnly/Support/$PRODUCT.plist" \
   "$STAGE/Library/MobileSubstrate/DynamicLibraries/$PRODUCT.plist"

plutil -lint "$STAGE/Library/MobileSubstrate/DynamicLibraries/$PRODUCT.plist"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PACKAGE_ID
Version: $VERSION
Architecture: $ARCH_TAG
Name: 备忘录只读
Section: Tweaks
Maintainer: unknown
Depends: firmware (>= 16.0), mobilesubstrate
Description: 在备忘录的右上角菜单里加一个只读开关。
EOF

mkdir -p "$OUTDIR"
DEB="$OUTDIR/${PACKAGE_ID}_${VERSION}_${ARCH_TAG}.deb"
dpkg-deb -b --root-owner-group "$STAGE" "$DEB"

echo "build-notesreadonly.sh: --- deb contents ---"
dpkg-deb -c "$DEB"
echo "build-notesreadonly.sh: --- deb control ---"
dpkg-deb -I "$DEB"
echo "build-notesreadonly.sh: sha256 $DEB = $(shasum -a 256 "$DEB" | awk '{print $1}')"
echo "build-notesreadonly.sh: wrote $DEB"
