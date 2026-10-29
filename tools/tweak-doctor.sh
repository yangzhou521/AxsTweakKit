#!/bin/bash
# tweak-doctor —— 隐根（roothide）/ A11 设备上「插件装了不生效」的体检脚本
#
# 用法：
#   bash tools/tweak-doctor.sh                 # 体检已注入的 /usr/lib/TweakInject
#   bash tools/tweak-doctor.sh /某目录         # 体检任意目录（递归找 *.dylib）
#   bash tools/tweak-doctor.sh --deb 包.deb    # 先 dpkg-deb -x 解开再体检
#   bash tools/tweak-doctor.sh --issues        # 只列有问题的行
#   bash tools/tweak-doctor.sh --arch arm64e   # A12+ 设备：要求有 arm64e 片
#   bash tools/tweak-doctor.sh --paths         # 追加打印每个 dylib 的真实依赖表
#
# 三大硬伤（照顺序查，绝大多数「装了没反应」都在这三条里）：
#   1) 架构：本机（A11 / iPhone 8·X / iOS 15-16）userland 全是 arm64，CPU 也不支持 arm64e，
#      所以「只有 arm64e 片」的 dylib = 装上了但永远不注入：没日志、没入口、不报错。
#      通用二进制（arm64 + arm64e）才既能在 A11 载 arm64 片、又能在 A12+ 载 arm64e 片。
#   2) 依赖路径：LC_LOAD_DYLIB 里写成绝对 /.jbroot/…（真实根没有 .jbroot）或写死 /var/jb
#      而设备上没建这条软链，dyld 就解析不到库；@loader_path/.jbroot/… 才是随包走的写法。
#   3) filter：plist 里的 bundle id 必须等于目标 App 的 CFBundleIdentifier，且装完要重启该进程。
#
# 依赖用真正的 load command 解析（不是 grep 字符串），所以不会把 LC_ID_DYLIB 或普通字符串误判。
# 只读：脚本只打印结论，不动任何文件。

set -u

WANT_ARCH="arm64"
DIR=""
DEB=""
ONLY_ISSUES=0
SHOW_PATHS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --deb) DEB="$2"; shift 2 ;;
        --arch) WANT_ARCH="$2"; shift 2 ;;
        --issues) ONLY_ISSUES=1; shift ;;
        --paths) SHOW_PATHS=1; shift ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) DIR="$1"; shift ;;
    esac
done

if [ -n "$DEB" ]; then
    [ -f "$DEB" ] || { echo "找不到 $DEB"; exit 1; }
    DIR="$(mktemp -d /tmp/tweak-doctor.XXXXXX)"
    echo "== 解开 $(basename "$DEB") → $DIR"
    dpkg-deb -x "$DEB" "$DIR" || exit 1
fi
[ -n "$DIR" ] || DIR="/usr/lib/TweakInject"
[ -d "$DIR" ] || { echo "找不到目录 $DIR"; exit 1; }

u32be() { echo $(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 )); }
u32le() { echo $(( $4 * 16777216 + $3 * 65536 + $2 * 256 + $1 )); }

has_arch() {  # has_arch "arm64+arm64e" arm64 —— 逐片精确比较，避免 arm64e 被 arm64 前缀蒙对
    local list="$1" want="$2" s
    for s in $(echo "$list" | tr '+' ' '); do
        [ "$s" = "$want" ] && return 0
    done
    return 1
}

cpu_name() {  # cputype cpusubtype → 架构名
    local ct="$1" st="$2" base
    case "$ct" in
        16777228) base="arm64" ;;
        12)       base="armv7" ;;
        16777223) base="x86_64" ;;
        7)        base="i386" ;;
        *)        base="cpu$ct" ;;
    esac
    if [ "$base" = "arm64" ]; then
        case "$st" in
            0|1)          echo "arm64" ;;
            2|2147483650) echo "arm64e" ;;
            *)            echo "arm64(st$st)" ;;
        esac
    else
        echo "$base"
    fi
}

# ---------- 1. 切片表 ----------

slices_of() {  # 打印 "架构 偏移" 每行一个
    local f="$1" hex n step i a ct st off
    hex="$(od -An -tx1 -j0 -N4 "$f" | tr -d ' \n')"
    case "$hex" in
        cafebabe|cafebabf)
            step=20; [ "$hex" = "cafebabf" ] && step=32
            n=$(u32be $(od -An -tu1 -v -j4 -N4 "$f"))
            [ "$n" -gt 16 ] && n=16
            a=($(od -An -tu1 -v -j8 -N $(( n * step )) "$f"))
            for (( i = 0; i < n; i++ )); do
                ct=$(u32be "${a[@]:i*step:4}")
                st=$(u32be "${a[@]:i*step+4:4}")
                if [ "$step" = 32 ]; then
                    off=$(u32be "${a[@]:i*step+12:4}")       # uint64 高 4 字节在 8..11
                else
                    off=$(u32be "${a[@]:i*step+8:4}")
                fi
                echo "$(cpu_name "$ct" "$st") $off"
            done
            ;;
        cffaedfe|cefaedfe|feedfacf|feedface)
            a=($(od -An -tu1 -v -j4 -N8 "$f"))
            [ "${#a[@]}" -eq 8 ] || { echo "不是Mach-O 0"; return 0; }
            if [ "$hex" = cffaedfe ] || [ "$hex" = cefaedfe ]; then
                echo "$(cpu_name $(u32le "${a[@]:0:4}") $(u32le "${a[@]:4:4}")) 0"
            else
                echo "$(cpu_name $(u32be "${a[@]:0:4}") $(u32be "${a[@]:4:4}")) 0"
            fi
            ;;
        *) echo "不是Mach-O 0" ;;
    esac
}

# ---------- 2. load command 解析（取 arm64 片，没有就取第一片） ----------

# 打印： ID|LOAD|WEAK|REEXPORT|RPATH  路径
load_of() {
    local f="$1" sl off hex a i cmd size nameoff b j c s first
    local ncmds sizeofcmds nbytes LOAD_OFF=""
    first=""
    while read -r sl off; do
        [ -n "$first" ] || first="$off"
        if [ "$sl" = "$WANT_ARCH" ] || [ "$sl" = "arm64" ]; then
            LOAD_OFF="$off"; break
        fi
    done <<EOF
$(slices_of "$f")
EOF
    off="${LOAD_OFF:-$first}"
    hex="$(od -An -tx1 -j "$off" -N4 "$f" | tr -d ' \n')"
    case "$hex" in
        cffaedfe|cefaedfe) : ;;        # 64/32 位小端：ncmds、sizeofcmds 都在头 +16
        *) return 0 ;;
    esac
    # od 必须带 -v：不加它时连续相同的行会被压成一个 "*"，那个 "*" 也成了数组元素，
    # 后面的字节偏移全部错位（第一段之后就读到 0，循环 break，什么都解析不出来）。
    a=($(od -An -tu1 -v -j $(( off + 16 )) -N 8 "$f"))
    [ "${#a[@]}" -eq 8 ] || return 0
    ncmds=$(u32le "${a[@]:0:4}")
    sizeofcmds=$(u32le "${a[@]:4:4}")
    [ "$ncmds" -gt 0 ] || return 0
    [ "$sizeofcmds" -ge 8 ] || return 0
    a=($(od -An -tu1 -v -j $(( off + 32 )) -N "$sizeofcmds" "$f" 2>/dev/null))
    nbytes=${#a[@]}
    [ "$nbytes" -ge 8 ] || return 0
    i=0
    while [ $(( i + 8 )) -le "$nbytes" ]; do   # i 是 load command 区内的字节偏移，不是命令条数
        cmd=$(u32le "${a[@]:i:4}")
        size=$(u32le "${a[@]:i+4:4}")
        [ "$size" -ge 8 ] || break
        [ $(( i + size )) -le "$nbytes" ] || break
        case "$cmd" in
            13)                 nameoff=$(u32le "${a[@]:i+8:4}"); s=ID ;;
            12)                 nameoff=$(u32le "${a[@]:i+8:4}"); s=LOAD ;;
            2147483672)         nameoff=$(u32le "${a[@]:i+8:4}"); s=WEAK ;;      # LC_LOAD_WEAK_DYLIB
            2147483679)         nameoff=$(u32le "${a[@]:i+8:4}"); s=REEXPORT ;;  # LC_REEXPORT_DYLIB
            2147483676)         nameoff=$(u32le "${a[@]:i+8:4}"); s=RPATH ;;     # LC_RPATH（路径在同一个位置）
            *) i=$(( i + size )); continue ;;
        esac
        j=$(( i + nameoff )); c=""
        if [ "$nameoff" -lt 8 ] || [ "$nameoff" -ge "$size" ]; then i=$(( i + size )); continue; fi
        while [ "$j" -lt $(( i + size )) ]; do
            b="${a[j]}"
            [ "$b" = 0 ] && break
            printf -v c "%s\\$(printf '%03o' "$b")" "$c"
            j=$(( j + 1 ))
        done
        printf '%s %s\n' "$s" "$c"
        i=$(( i + size ))
    done
}

is_system_lib() {  # 系统库在 dyld 共享缓存里，磁盘上没有，不算错
    case "$1" in
        /System/Library/Frameworks/*|/System/Library/PrivateFrameworks/*|\
        /usr/lib/libSystem.*|/usr/lib/libobjc.*|/usr/lib/libc++*|/usr/lib/libz.*|/usr/lib/libxpc*|\
        /usr/lib/libMobileGestalt*|/usr/lib/libIOReport*|/usr/lib/libAccessibility*|/usr/lib/libswift*|\
        /usr/lib/libsqlite3*|/usr/lib/libbz2*|/usr/lib/libxml2*|/usr/lib/libedit*|/usr/lib/libiconv*|\
        /usr/lib/libcharset*|/usr/lib/libncurses*|/usr/lib/swift/*|/usr/lib/system/*) return 0 ;;
        *) return 1 ;;
    esac
}

bundles_of() {
    [ -f "$1" ] || return 0
    tr '<>' '\n\n' < "$1" \
        | grep -E '^[A-Za-z0-9_.-]+(\.[A-Za-z0-9_.-]+)+_?$' \
        | grep -viE '^(com\.apple\.dt|www\.apple\.com|apple\.com)$' \
        | sort -u
}

# ---------- 主循环 ----------

echo "== 体检目录：$DIR"
echo "== 判据：dylib 必须含 [$WANT_ARCH] 片；依赖路径必须能在本命名空间解析"
echo

find "$DIR" -type f -name '*.dylib' | sort | {
    total=0; bad=0; warn=0
    while read -r f; do
        name="$(basename "$f")"
        plist="${f%.dylib}.plist"
        total=$(( total + 1 ))

        sl="$(slices_of "$f" | awk '{print $1}' | tr '\n' '+' | sed 's/+$//')"
        size="$(stat -c%s "$f" 2>/dev/null || echo '?')"
        verdict="OK  "; notes=""

        case "$sl" in
            *) if has_arch "$sl" "$WANT_ARCH"; then : ; else
                   verdict="BAD "; notes="只有 $sl 片，本机加载不了 → 装了也不会生效"
               fi ;;
        esac

        # 依赖与坏路径
        badpaths=""; missdeps=""; idpath=""; nload=0
        while read -r kind p; do
            [ -n "$kind" ] || continue
            case "$kind" in
                ID) idpath="$p" ;;
                LOAD|WEAK|REEXPORT|RPATH)
                    nload=$(( nload + 1 ))
                    case "$p" in
                        /.jbroot/*)
                            # 越狱命名空间里 /.jbroot -> . 是存在的（shell 里能 cat 到），
                            # 但真实根 /rootfs 下没有 .jbroot，这种绝对路径不可移植：
                            # 换成 @loader_path/.jbroot/… 才随包成立。
                            badpaths="$badpaths $p(绝对隐根路径)" ;;
                        /var/jb/*)  [ -e "$p" ] || badpaths="$badpaths $p(不存在)" ;;
                        @loader_path/*) [ -e "$(dirname "$f")/${p#@loader_path/}" ] || missdeps="$missdeps $p" ;;
                        @executable_path/*|@rpath/*) : ;;
                        /*) { is_system_lib "$p" || [ -e "$p" ] || [ -f "/rootfs${p}" ]; } || missdeps="$missdeps $p" ;;
                    esac
                    ;;
            esac
        done <<EOF
$(load_of "$f")
EOF

        if [ -n "$badpaths" ]; then
            if [ "$verdict" = "OK  " ]; then verdict="WARN"; fi
            notes="$notes | 绝对坏路径:$badpaths"
        fi
        if [ -n "$missdeps" ]; then
            if [ "$verdict" = "OK  " ]; then verdict="WARN"; fi
            notes="$notes | 依赖解析不到:$missdeps"
        fi

        if [ "$verdict" = "BAD " ]; then
            bad=$(( bad + 1 ))
        elif [ "$verdict" = "WARN" ]; then
            warn=$(( warn + 1 ))
        elif [ ! -f "$plist" ]; then
            verdict="WARN"; notes="$notes | 没有同名 .plist，不会被注入（多是被其它插件 dlopen 的库）"
            warn=$(( warn + 1 ))
        fi

        if [ "$ONLY_ISSUES" = 1 ] && [ "$verdict" = "OK  " ]; then continue; fi

        fbs="$(bundles_of "$plist" | tr '\n' ',' | sed 's/,$//')"
        [ -n "$fbs" ] || fbs="(无 filter)"
        printf '[%s] %-38s %-20s %9s B  filter=%s\n' "$verdict" "$name" "$sl" "$size" "$fbs"
        [ -n "$notes" ] && printf '        ↳%s\n' "$notes"
        if [ "$SHOW_PATHS" = 1 ]; then
            printf '        ↳ ID=%s\n' "$idpath"
            load_of "$f" | sed 's/^/          /'
        fi
    done
    echo
    echo "== 合计 $total 个 dylib：BAD $bad，WARN $warn"
}

echo
echo "== 环境速查"
printf '  注入目录      '; ls -ld /Library/MobileSubstrate/DynamicLibraries 2>/dev/null | sed 's#.*DynamicLibraries#DynamicLibraries#'
printf '  substrate     '; ls -l /usr/lib/libsubstrate.dylib 2>/dev/null | sed 's#.*libsubstrate#libsubstrate#'
printf '  /var/jb       '; (ls -ld /var/jb 2>/dev/null | sed 's#.* /#/#') || echo "不存在"
if [ -e /.jbroot ]; then echo "  /.jbroot      存在（真实根里的绝对 /.jbroot 引用才可能解析）"
else echo "  /.jbroot      不存在 → 任何绝对 /.jbroot/… 的依赖都是坏的，要改成 @loader_path/.jbroot/…"; fi
echo "  已停用        $(ls "$DIR"/*.disabled 2>/dev/null | sed 's#.*/##' | tr '\n' ' ')"
echo "  roothidepatch $(ls "$DIR"/*.roothidepatch 2>/dev/null | wc -l | tr -d ' ') 个"
echo
echo "排查顺序：1) 有没有 BAD 行（架构硬伤）"
echo "          2) 有没有 WARN 行（坏路径 / 缺 plist / 依赖解析不到）"
echo "          3) 目标 App 的 CFBundleIdentifier 与 filter 是否一致"
echo "          4) 装完是否重启过目标进程（没重启看不到任何效果）"
echo "          5) 插件自己的日志/诊断（icli prefs read <domain> <key>）"
