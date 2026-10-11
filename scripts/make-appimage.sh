#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 DarkLord-W
#
# make-appimage.sh — 手工打包便携 AppImage（runtime + squashfs）
#
# 本机没有 appimagetool，也不允许联网，所以不走常规打包工具链：
# 类型 2 的 AppImage 本质上就是「ELF runtime ++ squashfs 镜像」，
# 分别准备好这两半，再用 cat 拼起来即可。
#
# runtime 的来源（按优先级）：
#   1. $RUNTIME                         直接指定的 runtime 文件
#   2. runtime/appimage-runtime-x86_64  仓库内缓存（抽一次，长期复用，
#                                       旁边的 .offset 记录其长度）
#   3. 从现成 AppImage 里现场抽取：
#        $APPMGR_RUNTIME_SOURCE
#        ~/Desktop/audit/dl/*.AppImage
#        /tmp/*.AppImage
#
# 抽取方法（重要，别再用「扫第一个 hsqs」的土办法）：
#   runtime 自己的代码里恰好含有 hsqs 字节（例如 cmp eax, 0x73717368），
#   按「第一个 hsqs 的位置」去截会截出一个残废的 runtime —— 看着能启动，
#   但在 --appimage-extract 时随机段错误。权威做法是让源 AppImage 的
#   runtime 自报偏移：`源.AppImage --appimage-offset`，那正是 runtime 的长度。
#   截出来之后还会做一次回环验证（拼一段最小 squashfs，要求偏移一致
#   且 --appimage-extract 成功），截断的 runtime 过不了这一关。
#
# 用法：
#   bash scripts/make-appimage.sh
#   RUNTIME=/path/to/runtime bash scripts/make-appimage.sh
#   APPMGR_RUNTIME_SOURCE=/path/to/某.AppImage bash scripts/make-appimage.sh
#
set -euo pipefail

# ── 路径与参数 ───────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$ROOT_DIR/data"
BIN="$ROOT_DIR/appimage-manager"
RUNTIME_CACHE="$ROOT_DIR/runtime/appimage-runtime-x86_64"
DIST_DIR="$ROOT_DIR/dist"

# 版本号：优先 make 传进来的 $VERSION，否则读 src/version.vala
VERSION="${VERSION:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(sed -n 's/.*APPMGR_VERSION[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$ROOT_DIR/src/version.vala" | head -n 1)"
fi
[ -n "$VERSION" ] || VERSION="1.0.0"

# ── 临时工作区 ───────────────────────────────────────────────────────
# 尊重 $TMPDIR；本机预置了 /tmp/opencode，优先用它
WORK_ROOT="${TMPDIR:-/tmp}"
if [ -d /tmp/opencode ]; then
    WORK_ROOT="/tmp/opencode"
fi
[ -d "$WORK_ROOT" ] || WORK_ROOT="/tmp"

WORK_DIR="$(mktemp -d "$WORK_ROOT/appimage-manager-build.XXXXXX")"
APPDIR="$WORK_DIR/AppDir"
SQUASH="$WORK_DIR/appdir.squashfs"

# 无论成功失败都清掉半成品 AppDir，绝不留在临时目录里
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ── 小工具 ───────────────────────────────────────────────────────────

# 完整性体检：ELF 头部声明的大小必须和文件实际大小对得上。
# 被截断的 runtime（比如按假阳性的 hsqs 截出来的 32605 字节货色）
# 头部里的 e_shoff 仍然指向 188392 附近，这里一算就能识破。
elf_complete() {
    python3 - "$1" <<'PY'
import os, struct, sys

path = sys.argv[1]
size = os.path.getsize(path)
with open(path, "rb") as fh:
    hdr = fh.read(4096)
if len(hdr) < 64 or hdr[:4] != b"\x7fELF" or hdr[4] != 2:
    sys.exit(1)

e_phoff, = struct.unpack_from("<Q", hdr, 0x20)
e_shoff, = struct.unpack_from("<Q", hdr, 0x28)
e_phentsize, e_phnum = struct.unpack_from("<HH", hdr, 0x36)
e_shentsize, e_shnum = struct.unpack_from("<HH", hdr, 0x3A)

elf_end = e_shoff + e_shnum * e_shentsize
with open(path, "rb") as fh:
    for i in range(e_phnum):
        fh.seek(e_phoff + i * e_phentsize)
        ph = fh.read(e_phentsize)
        if len(ph) < 0x28:
            break
        (p_type,) = struct.unpack_from("<I", ph, 0)
        (p_offset,) = struct.unpack_from("<Q", ph, 0x08)
        (p_filesz,) = struct.unpack_from("<Q", ph, 0x20)
        if p_type == 1:
            elf_end = max(elf_end, p_offset + p_filesz)

# 裸 runtime：ELF 声明的大小就是文件大小（允许 ≤64 KiB 的对齐填充）
sys.exit(0 if 0 < elf_end <= size <= elf_end + 65536 else 1)
PY
}

# runtime 体检：存在、可执行、ELF 魔数、体积像样（≥10 KiB）、ELF 完整
runtime_ok() {
    local f="$1"
    [ -f "$f" ] || return 1
    [ -x "$f" ] || return 1
    [ "$(stat -c%s "$f" 2>/dev/null || echo 0)" -ge 10240 ] || return 1
    [ "$(head -c 4 "$f")" = $'\x7fELF' ] || return 1
    elf_complete "$f"
}

# 回环验证 —— 真正能抓出「截断 runtime」的检查：
# 拿 runtime 拼一个只含一个文件的最小 AppImage，要求
#   * --appimage-offset 报出的偏移 == runtime 实际大小
#   * --appimage-extract 退出码为 0 且能原样还原出那个文件
runtime_roundtrip_ok() {
    local runtime="$1"
    local expected="${2:-$(stat -c%s "$runtime")}"
    local probe="$WORK_DIR/rtprobe"

    rm -rf "$probe"
    mkdir -p "$probe/dir"
    printf 'probe\n' > "$probe/dir/probe.txt"

    if ! mksquashfs "$probe/dir" "$probe/fs.squashfs" \
            -root-owned -noappend -comp gzip -b 128K -no-progress >/dev/null 2>&1; then
        return 1
    fi

    cat "$runtime" "$probe/fs.squashfs" > "$probe/probe.AppImage"
    chmod +x "$probe/probe.AppImage"

    local reported
    if ! reported="$(timeout 15 "$probe/probe.AppImage" --appimage-offset 2>/dev/null)"; then
        return 1
    fi
    reported="$(printf '%s' "$reported" | tr -d '[:space:]')"
    [ "$reported" = "$expected" ] || return 1

    # 反向验证：解包也必须成功（截断的 runtime 恰好在这里崩）
    if ! (
        cd "$probe" || exit 1
        rm -rf squashfs-root
        timeout 30 ./probe.AppImage --appimage-extract >/dev/null 2>&1 || exit 1
        [ -f squashfs-root/probe.txt ] || exit 1
    ); then
        return 1
    fi

    rm -rf "$probe"
    return 0
}

# 从类型 2 AppImage 里截出头部 runtime；成功返回 0，并写下 .offset 记录长度
extract_runtime() {
    local src="$1" dest="$2"
    local size=""

    # 首选：runtime 自报 squashfs 起点，那正是 runtime 的准确长度
    if size="$(timeout 15 "$src" --appimage-offset 2>/dev/null)"; then
        size="$(printf '%s' "$size" | tr -d '[:space:]')"
        case "$size" in
            ''|*[!0-9]*) size="" ;;
        esac
    else
        size=""
    fi

    # 兜底（源不支持 --appimage-offset 时）：解析 ELF 头部算出 ELF 末尾，
    # 并要求其后紧跟一个「结构可信」的 squashfs superblock，而不是随便一个 hsqs
    if [ -z "$size" ]; then
        size="$(python3 - "$src" <<'PY'
import struct, sys

BLOCK_SIZES = (4096, 8192, 16384, 32768, 65536,
               131072, 262144, 524288, 1048576)

src = sys.argv[1]
try:
    with open(src, "rb") as fh:
        hdr = fh.read(4096)
    if len(hdr) < 64 or hdr[:4] != b"\x7fELF" or hdr[4] != 2:
        sys.exit(1)

    e_phoff, = struct.unpack_from("<Q", hdr, 0x20)
    e_shoff, = struct.unpack_from("<Q", hdr, 0x28)
    e_phentsize, e_phnum = struct.unpack_from("<HH", hdr, 0x36)
    e_shentsize, e_shnum = struct.unpack_from("<HH", hdr, 0x3A)

    elf_end = e_shoff + e_shnum * e_shentsize
    with open(src, "rb") as fh:
        for i in range(e_phnum):
            fh.seek(e_phoff + i * e_phentsize)
            ph = fh.read(e_phentsize)
            if len(ph) < 0x28:
                break
            (p_type,) = struct.unpack_from("<I", ph, 0)
            (p_offset,) = struct.unpack_from("<Q", ph, 0x08)
            (p_filesz,) = struct.unpack_from("<Q", ph, 0x20)
            if p_type == 1:
                elf_end = max(elf_end, p_offset + p_filesz)

    # squashfs 通常正好跟在 ELF 末尾；容忍少量对齐填充，向后找 1 MiB
    with open(src, "rb") as fh:
        fh.seek(elf_end)
        window = fh.read(1024 * 1024)

    for i in range(max(0, len(window) - 32)):
        if window[i:i + 4] != b"hsqs":
            continue
        (inodes,) = struct.unpack_from("<I", window, i + 4)
        (block_size,) = struct.unpack_from("<I", window, i + 12)
        (major,) = struct.unpack_from("<H", window, i + 28)
        if inodes > 0 and block_size in BLOCK_SIZES and major == 4:
            print(elf_end + i)
            break
    else:
        sys.exit(1)
except (OSError, struct.error):
    sys.exit(1)
PY
)" || size=""
    fi

    case "$size" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$size" -ge 10240 ] || return 1

    head -c "$size" "$src" > "$dest" || { rm -f "$dest"; return 1; }
    chmod +x "$dest" 2>/dev/null || true
    runtime_ok "$dest" || { rm -f "$dest"; return 1; }
    printf '%s\n' "$size" > "$dest.offset"
    return 0
}

# ── 1) 主程序必须已构建 ──────────────────────────────────────────────

if [ ! -x "$BIN" ]; then
    echo "主程序尚未构建，先执行 make …"
    make -C "$ROOT_DIR"
fi
if [ ! -x "$BIN" ]; then
    echo "错误：$BIN 不存在或不可执行，请先运行 make" >&2
    exit 1
fi

# ── 2) 定位 runtime ──────────────────────────────────────────────────

RUNTIME_FILE=""
mkdir -p "$(dirname "$RUNTIME_CACHE")"

# 2.1) $RUNTIME 直接指定
if [ -n "${RUNTIME:-}" ]; then
    if runtime_ok "$RUNTIME" && runtime_roundtrip_ok "$RUNTIME"; then
        RUNTIME_FILE="$RUNTIME"
        echo "runtime: 使用 \$RUNTIME=$RUNTIME（已过回环验证）"
    elif extract_runtime "$RUNTIME" "$RUNTIME_CACHE"; then
        if runtime_roundtrip_ok "$RUNTIME_CACHE"; then
            RUNTIME_FILE="$RUNTIME_CACHE"
            echo "runtime: 已从 \$RUNTIME=$RUNTIME 抽出 runtime（$(stat -c%s "$RUNTIME_CACHE") 字节）并缓存"
        else
            echo "警告：从 $RUNTIME 抽出的 runtime 未过回环验证，弃用" >&2
            rm -f "$RUNTIME_CACHE" "$RUNTIME_CACHE.offset"
        fi
    else
        echo "警告：RUNTIME=$RUNTIME 不是可用 runtime，也不像类型 2 AppImage" >&2
    fi
fi

# 2.2) 仓库内缓存（连同 .offset 里的长度一起重验）
if [ -z "$RUNTIME_FILE" ] && [ -f "$RUNTIME_CACHE" ]; then
    CACHED_SIZE="$(stat -c%s "$RUNTIME_CACHE" 2>/dev/null || echo 0)"
    RECORDED_SIZE=""
    if [ -f "$RUNTIME_CACHE.offset" ]; then
        RECORDED_SIZE="$(head -n 1 "$RUNTIME_CACHE.offset" | tr -d '[:space:]')"
    fi
    if runtime_ok "$RUNTIME_CACHE" \
        && { [ -z "$RECORDED_SIZE" ] || [ "$RECORDED_SIZE" = "$CACHED_SIZE" ]; } \
        && runtime_roundtrip_ok "$RUNTIME_CACHE" "$CACHED_SIZE"; then
        RUNTIME_FILE="$RUNTIME_CACHE"
        echo "runtime: 复用缓存 $RUNTIME_CACHE（${CACHED_SIZE} 字节，已过回环验证）"
    else
        echo "runtime: 缓存无效（长度对不上或未过回环验证），删除后重新抽取"
        rm -f "$RUNTIME_CACHE" "$RUNTIME_CACHE.offset"
    fi
fi

# 2.3) 从候选 AppImage 现场抽取
if [ -z "$RUNTIME_FILE" ]; then
    candidates=()
    if [ -n "${APPMGR_RUNTIME_SOURCE:-}" ]; then
        candidates+=("$APPMGR_RUNTIME_SOURCE")
    fi
    for f in "$HOME/Desktop/audit/dl/"*.AppImage; do
        if [ -f "$f" ]; then
            candidates+=("$f")
        fi
    done
    for f in /tmp/*.AppImage; do
        if [ -f "$f" ]; then
            candidates+=("$f")
        fi
    done

    for cand in "${candidates[@]}"; do
        [ -f "$cand" ] || continue

        # 候选本身就是裸 runtime（比如误把 runtime 传给 APPMGR_RUNTIME_SOURCE）
        if runtime_ok "$cand"; then
            if cp -f "$cand" "$RUNTIME_CACHE" \
                && chmod +x "$RUNTIME_CACHE" \
                && runtime_ok "$RUNTIME_CACHE" \
                && runtime_roundtrip_ok "$RUNTIME_CACHE"; then
                printf '%s\n' "$(stat -c%s "$RUNTIME_CACHE")" > "$RUNTIME_CACHE.offset"
                RUNTIME_FILE="$RUNTIME_CACHE"
                echo "runtime: 已缓存裸 runtime $cand → $RUNTIME_CACHE"
                break
            fi
            continue
        fi

        # 完整 AppImage：截出 runtime，再回环验证
        if extract_runtime "$cand" "$RUNTIME_CACHE"; then
            if runtime_roundtrip_ok "$RUNTIME_CACHE"; then
                RUNTIME_FILE="$RUNTIME_CACHE"
                echo "runtime: 已从 $cand 抽取 runtime（$(stat -c%s "$RUNTIME_CACHE") 字节）到 $RUNTIME_CACHE"
                break
            fi
            echo "runtime: $cand 抽出的 runtime 未过回环验证，跳过"
            rm -f "$RUNTIME_CACHE" "$RUNTIME_CACHE.offset"
            continue
        fi
        echo "runtime: $cand 不是可解析的类型 2 AppImage，跳过"
    done
fi

# 2.4) 还是没有 → 给出三条明路（此时 trap 会把临时目录清干净）
if [ -z "$RUNTIME_FILE" ]; then
    cat >&2 <<'EOF'
错误：找不到可用的 AppImage runtime，无法打包。

三种供给方式（任选其一）：
  1. 直接给出 runtime 文件：
       RUNTIME=/path/to/runtime  bash scripts/make-appimage.sh
  2. 把 runtime 缓存进仓库（只需一次）：
       mkdir -p runtime
       cp /path/to/runtime runtime/appimage-runtime-x86_64
       chmod +x runtime/appimage-runtime-x86_64
  3. 指定任意现成类型 2 AppImage，现场抽取（推荐）：
       APPMGR_RUNTIME_SOURCE=/path/to/某.AppImage  bash scripts/make-appimage.sh
     （默认还会依次尝试 ~/Desktop/audit/dl/*.AppImage 和 /tmp/*.AppImage）

提示：runtime 就是完整 AppImage 头部那段 ELF，长度以该 AppImage 的
      `--appimage-offset` 输出为准；不要扫描 hsqs 魔数，那有假阳性。
EOF
    exit 1
fi

# ── 3) 组装 AppDir ───────────────────────────────────────────────────

echo "AppDir : $APPDIR (临时目录)"
mkdir -p "$APPDIR/usr/bin" \
         "$APPDIR/usr/share/appimage-manager" \
         "$APPDIR/usr/share/icons/hicolor/256x256/apps" \
         "$APPDIR/data"

install -m 0755 "$BIN" \
    "$APPDIR/usr/bin/appimage-manager"
install -m 0644 "$DATA_DIR/style.css" \
    "$APPDIR/usr/share/appimage-manager/style.css"
install -m 0644 "$DATA_DIR/appimage-manager.png" \
    "$APPDIR/appimage-manager.png"
install -m 0644 "$DATA_DIR/appimage-manager.png" \
    "$APPDIR/usr/share/icons/hicolor/256x256/apps/appimage-manager.png"

# 应用按「CWD 下的 data/style.css」回退查找样式表（见 src/window.vala 的 find_css）。
# AppRun 会 cd 到 AppDir 根。这里放一份实体副本而不是软链接：
# paths.vala 的 canonical() 在解析软链接时有所有权缺陷（跨循环迭代后返回悬垂
# 指针），任何经软链接解析的路径都会变成乱码，CSS 就会加载失败。
# 两份 style.css 内容相同，mksquashfs 会自动去重，不增加体积。
install -m 0644 "$DATA_DIR/style.css" "$APPDIR/data/style.css"

sed -e "s|@VERSION@|$VERSION|g" \
    "$DATA_DIR/appimage-manager-appimage.desktop.in" > "$APPDIR/appimage-manager.desktop"
chmod 0644 "$APPDIR/appimage-manager.desktop"

# AppRun：POSIX sh，兼容「runtime 挂载」与「解压后直接跑」两种形态
cat > "$APPDIR/AppRun" <<'SH'
#!/bin/sh
#
# AppRun — AppImage 入口脚本（由 scripts/make-appimage.sh 生成）
#
# 兼容两种运行方式：
#   * 经 runtime 挂载运行 —— $APPDIR 通常已由 runtime 导出
#   * 解压后直接运行     —— 从 $0 推导 AppDir
#
set -eu

if [ -z "${APPDIR:-}" ]; then
    self="$0"
    resolved="$(readlink -f "$0" 2>/dev/null)" || resolved=""
    if [ -n "$resolved" ]; then
        self="$resolved"
    fi
    APPDIR="$(cd "$(dirname "$self")" && pwd)"
fi
export APPDIR

# 让 AppDir 自带的图标与 .desktop 对桌面环境可见（插在最前，不覆盖系统路径）
if [ -n "${XDG_DATA_DIRS:-}" ]; then
    XDG_DATA_DIRS="$APPDIR/usr/share:$XDG_DATA_DIRS"
else
    XDG_DATA_DIRS="$APPDIR/usr/share:/usr/local/share:/usr/share"
fi
export XDG_DATA_DIRS

# 应用从 CWD 的 data/style.css 回退查找样式表；
# AppDir 里的 data/style.css 与 usr/share/appimage-manager/style.css 内容相同
cd "$APPDIR"

# 不捆绑 GTK，也不设 LD_LIBRARY_PATH —— 直接用系统库
exec "$APPDIR/usr/bin/appimage-manager" "$@"
SH
chmod 0755 "$APPDIR/AppRun"

# ── 4) 压制 squashfs 并拼装 ──────────────────────────────────────────

echo "压制 squashfs …"
mksquashfs "$APPDIR" "$SQUASH" -root-owned -noappend -comp gzip -b 128K -no-progress

mkdir -p "$DIST_DIR"
OUT="$DIST_DIR/AppImage-Manager-$VERSION-x86_64.AppImage"
cat "$RUNTIME_FILE" "$SQUASH" > "$OUT"
chmod 0755 "$OUT"

# ── 5) 成品自检：偏移正确 + 能完整解包 ───────────────────────────────

RUNTIME_SIZE="$(stat -c%s "$RUNTIME_FILE")"
REPORTED_OFFSET="$(timeout 15 "$OUT" --appimage-offset 2>/dev/null)" || REPORTED_OFFSET=""
REPORTED_OFFSET="$(printf '%s' "$REPORTED_OFFSET" | tr -d '[:space:]')"

CHECK_DIR="$WORK_DIR/finalcheck"
FAILED=0
if [ "$REPORTED_OFFSET" != "$RUNTIME_SIZE" ]; then
    echo "错误：成品 --appimage-offset 报 $REPORTED_OFFSET，预期 $RUNTIME_SIZE" >&2
    FAILED=1
fi
mkdir -p "$CHECK_DIR"
if ! (
    cd "$CHECK_DIR" || exit 1
    timeout 60 "$OUT" --appimage-extract >/dev/null 2>&1 || exit 1
    [ -f squashfs-root/usr/bin/appimage-manager ] || exit 1
    [ -f squashfs-root/data/style.css ] || exit 1
    [ -x squashfs-root/AppRun ] || exit 1
); then
    echo "错误：成品 --appimage-extract 自检失败" >&2
    FAILED=1
fi
if [ "$FAILED" != 0 ]; then
    rm -f "$OUT"
    echo "已删除有问题的成品：$OUT" >&2
    exit 1
fi

SIZE="$(stat -c%s "$OUT")"
if command -v numfmt >/dev/null 2>&1; then
    HUMAN="$(numfmt --to=iec-i --suffix=B "$SIZE")"
else
    HUMAN="$SIZE 字节"
fi

echo
echo "════════ 完成 ════════"
echo "runtime  : $RUNTIME_FILE（$RUNTIME_SIZE 字节，--appimage-offset 一致）"
echo "AppImage : $OUT"
echo "体积     : $HUMAN ($SIZE 字节)"
echo "自检     : --appimage-extract 通过"
echo "运行     : 已可执行，直接双击；需要菜单项时可用本工具为它创建启动器。"
