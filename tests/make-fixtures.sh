#!/usr/bin/env bash
#
# make-fixtures.sh — 生成测试用的假 AppImage 和各种「不规范的 .desktop」
#
# 用途：验证扫描器、规则引擎、修复流程的真实行为。
# 所有文件都建在沙箱目录里，不碰真实的家目录。
#
#   ./tests/make-fixtures.sh [沙箱目录]      默认 /tmp/appmgr-fixtures
#
set -euo pipefail

SANDBOX="${1:-/tmp/appmgr-fixtures}"

echo "沙箱: $SANDBOX"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"/{apps,desktops,icons}

# ══════════════════════════════════════════════════════════════════
#  1. 造真 AppImage（ELF magic + "AI" magic at offset 8）
# ══════════════════════════════════════════════════════════════════
#
#  偏移 0x00: 7F 45 4C 46     ELF
#  偏移 0x08: 41 49           "AI"

make_appimage () {
    local path="$1"
    local size_kb="${2:-64}"
    printf '\x7f\x45\x4c\x46\x02\x01\x01\x00\x41\x49\x02\x00' > "$path"
    head -c $((size_kb * 1024)) /dev/urandom >> "$path"
    chmod +x "$path"
}

# 正常的 AppImage
make_appimage "$SANDBOX/apps/Obsidian-1.5.3-x86_64.AppImage"        128
make_appimage "$SANDBOX/apps/Krita-5.2.0-x86_64.AppImage"            256
make_appimage "$SANDBOX/apps/Bitwarden-2024.6.2.AppImage"             96
make_appimage "$SANDBOX/apps/GNU_Octave-9.1.0.AppImage"              192

# 文件名含空格和特殊字符（测 Exec 转义）
make_appimage "$SANDBOX/apps/Media Player 2.0.AppImage"               80
make_appimage "$SANDBOX/apps/Foo(Bar) 1.0.AppImage"                   64
make_appimage "$SANDBOX/apps/100% Pure.AppImage"                      64

# 子目录里（测递归扫描）
mkdir -p "$SANDBOX/apps/subdir/nested"
make_appimage "$SANDBOX/apps/subdir/FreeCAD-0.21.AppImage"           128
make_appimage "$SANDBOX/apps/subdir/nested/DeepTool-1.0.AppImage"     64

# 大写扩展名（测大小写不敏感）
make_appimage "$SANDBOX/apps/Uppercase.APPIMAGE"                      48

# 假货：扩展名像但魔数不对（应被剔除）
printf '#!/bin/sh\necho "not an appimage"\n' > "$SANDBOX/apps/Fake-1.0.AppImage"
chmod +x "$SANDBOX/apps/Fake-1.0.AppImage"

# 假货 ELF 但不是 AppImage（无 AI magic）
printf '\x7f\x45\x4c\x46\x02\x01\x01\x00\x00\x00\x00\x00' > "$SANDBOX/apps/PlainElf.AppImage"
head -c 8192 /dev/urandom >> "$SANDBOX/apps/PlainElf.AppImage"
chmod +x "$SANDBOX/apps/PlainElf.AppImage"

# 无执行位（测自动 chmod）
make_appimage "$SANDBOX/apps/NoExecBit-1.0.AppImage"                  64
chmod -x "$SANDBOX/apps/NoExecBit-1.0.AppImage"

# ══════════════════════════════════════════════════════════════════
#  2. 各种「有毛病」的 .desktop
# ══════════════════════════════════════════════════════════════════

D="$SANDBOX/desktops"

# ── D001 缺少 [Desktop Entry] 组头 ────────────────────────────────
cat > "$D/no-group.desktop" <<EOF
Name=No Group
Type=Application
Exec=$SANDBOX/apps/Krita-5.2.0-x86_64.AppImage
EOF

# ── D002 UTF-8 with BOM ──────────────────────────────────────────
printf '\xef\xbb\xbf' > "$D/bom.desktop"
cat >> "$D/bom.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=BOM Entry
Exec=$SANDBOX/apps/Obsidian-1.5.3-x86_64.AppImage
EOF

# ── D003 CRLF 行尾 ───────────────────────────────────────────────
printf '[Desktop Entry]\r\nType=Application\r\nName=CRLF Entry\r\nExec=%s\r\n' \
    "$SANDBOX/apps/Bitwarden-2024.6.2.AppImage" > "$D/crlf.desktop"

# ── D005 Type 错误 ───────────────────────────────────────────────
cat > "$D/bad-type.desktop" <<EOF
[Desktop Entry]
Type=Link
Name=Bad Type
Exec=$SANDBOX/apps/GNU_Octave-9.1.0.AppImage
EOF

# ── E001 Version 超范围 ──────────────────────────────────────────
cat > "$D/bad-version.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=2.0
Name=Bad Version
Exec=$SANDBOX/apps/Obsidian-1.5.3-x86_64.AppImage
EOF

# ── E003/E004/E005 Exec 各种坏法 ─────────────────────────────────
cat > "$D/exec-unquoted.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Media Player
Exec=$SANDBOX/apps/Media Player 2.0.AppImage
Icon=multimedia-player
Categories=AudioVideo;
EOF

cat > "$D/exec-missing.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Gone App
Exec=/nonexistent/path/Gone-1.0.AppImage %U
Icon=application-x-executable
Categories=Utility;
EOF

cat > "$D/exec-wrapper.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Wrapped
Exec=sh -c "$SANDBOX/apps/Krita-5.2.0-x86_64.AppImage"
Icon=krita
Categories=Graphics;
EOF

cat > "$D/exec-percent.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=100 Percent
Exec=$SANDBOX/apps/100% Pure.AppImage
Icon=unknown
Categories=Utility;
EOF

# ── E007 Name 缺失 ───────────────────────────────────────────────
cat > "$D/no-name.desktop" <<EOF
[Desktop Entry]
Type=Application
Exec=$SANDBOX/apps/FreeCAD-0.21.AppImage
EOF

# ── E008 重复键 ──────────────────────────────────────────────────
cat > "$D/dup-keys.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=First Name
Name=Second Name
Exec=$SANDBOX/apps/Obsidian-1.5.3-x86_64.AppImage
EOF

# ── E009 悬空 Actions 引用 ───────────────────────────────────────
cat > "$D/dangling-actions.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Dangling
Exec=$SANDBOX/apps/Krita-5.2.0-x86_64.AppImage
Actions=NewWindow;MissingAction;
Categories=Graphics;
EOF

# ── I001 Icon 指向不存在的文件 ───────────────────────────────────
cat > "$D/icon-missing.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Icon Missing
Exec=$SANDBOX/apps/Bitwarden-2024.6.2.AppImage
Icon=/usr/share/icons/does-not-exist.png
Categories=Utility;
EOF

# ── I005 Terminal=true ───────────────────────────────────────────
cat > "$D/terminal-true.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Terminal True
Exec=$SANDBOX/apps/GNU_Octave-9.1.0.AppImage
Terminal=true
Icon=utilities-terminal
Categories=Education;Science;
EOF

# ── I006 Hidden=true（需用户确认，不应自动改）─────────────────────
cat > "$D/hidden-true.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Hidden Entry
Exec=$SANDBOX/apps/Uppercase.APPIMAGE
Hidden=true
Icon=application-x-executable
Categories=Utility;
EOF

# ── I006+ 文件名不规范 ───────────────────────────────────────────
cat > "$D/This Is A Messy Name.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Messy
Exec=$SANDBOX/apps/subdir/FreeCAD-0.21.AppImage
Icon=freecad
Categories=Graphics;Engineering;
EOF

# ── 完全健康的条目（不应报任何问题）───────────────────────────────
cat > "$D/perfect.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.5
Name=Perfect Entry
GenericName=Perfect
Comment=A perfectly well-formed desktop entry
Exec="$SANDBOX/apps/Obsidian-1.5.3-x86_64.AppImage" %U
TryExec=$SANDBOX/apps/Obsidian-1.5.3-x86_64.AppImage
Icon=$SANDBOX/icons/perfect.png
Terminal=false
StartupNotify=true
StartupWMClass=Perfect Entry
Categories=Office;Utility;
X-AppImage-Manager=true
X-AppImage-Manager-Path=$SANDBOX/apps/Obsidian-1.5.3-x86_64.AppImage
EOF

# ── 失效条目：指向已不存在的 AppImage ────────────────────────────
cat > "$D/broken.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Broken Launcher
Exec=$SANDBOX/apps/DeletedLongAgo-0.1.AppImage %U
TryExec=$SANDBOX/apps/DeletedLongAgo-0.1.AppImage
Icon=application-x-executable
Categories=Utility;
EOF

# ── 外部创建（无标记键，但 Exec 指向真实 AppImage）────────────────
cat > "$D/external.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=External Entry
Comment=Created by some other tool
Exec=$SANDBOX/apps/Krita-5.2.0-x86_64.AppImage %U
Icon=krita
Categories=Graphics;
Terminal=false
EOF

# ── 保留组测试：带 Desktop Action ────────────────────────────────
cat > "$D/with-actions.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.5
Name=With Actions
Comment=Has a desktop action group that must be preserved
Exec="$SANDBOX/apps/Krita-5.2.0-x86_64.AppImage" %U
Icon=krita
Terminal=false
StartupNotify=true
StartupWMClass=krita
Categories=Graphics;
Actions=NewWindow;
X-Custom-User-Key=must-survive

[Desktop Action NewWindow]
Name=New Window
Exec="$SANDBOX/apps/Krita-5.2.0-x86_64.AppImage" --new-window
EOF

# ── 一个用于测试「认领」的目标 ───────────────────────────────────
cat > "$D/claim-target.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Claim Me
Exec=/usr/bin/env $SANDBOX/apps/Bitwarden-2024.6.2.AppImage
Icon=bitwarden
Categories=Utility;
Terminal=false
EOF

# ══════════════════════════════════════════════════════════════════
#  3. 图标
# ══════════════════════════════════════════════════════════════════
# 画一个 64x64 的 RGBA 图标：中心实心圆、圆外全透明。
#
# 用 zlib + struct 手写 PNG，不依赖 cairo / PyGObject —— 那两个包在
# GitHub runner 的默认镜像里都没有，会让这一步直接崩
# （实测就是 ModuleNotFoundError: No module named 'cairo'）。
# 这里只需要画一个圆，为它拖两个图形库进来不划算。
#
# alpha 必须保留：图标安装路径要处理的就是带透明通道的 PNG，
# 换成不透明的图会让那条路径测不到真东西。
python3 - "$SANDBOX/icons/perfect.png" <<'PY'
import struct, sys, zlib

W = H = 64
R = 26.0                    # 圆的半径
CX = CY = 32.0              # 圆心
FG = (51, 179, 128, 255)    # 实心圆颜色（原来 cairo 用的 0.2/0.7/0.5）
BG = (0, 0, 0, 0)           # 圆外全透明

def png_chunk(tag, data):
    return (struct.pack('>I', len(data)) + tag + data
            + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))

# 每条扫描线前面要加一个过滤器字节（0 = 不过滤）
raw = bytearray()
for y in range(H):
    raw.append(0)
    for x in range(W):
        dx, dy = x + 0.5 - CX, y + 0.5 - CY
        raw.extend(FG if dx * dx + dy * dy <= R * R else BG)

png = (b'\x89PNG\r\n\x1a\n'
       + png_chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0))
       + png_chunk(b'IDAT', zlib.compress(bytes(raw), 9))
       + png_chunk(b'IEND', b''))

with open(sys.argv[1], 'wb') as f:
    f.write(png)
PY

# 写完立刻读回来验一遍：夹具少了图标或格式不对，后面几步会莫名其妙地
# 失败在别处，不如在这里就拦住。
python3 - "$SANDBOX/icons/perfect.png" <<'PY'
import struct, sys

path = sys.argv[1]
data = open(path, 'rb').read()
problems = []

if data[:8] != b'\x89PNG\r\n\x1a\n':
    problems.append('PNG 魔数不对')

w = h = depth = ctype = None
if len(data) > 33 and data[12:16] == b'IHDR':
    w, h, depth, ctype = struct.unpack('>IIBB', data[16:26])

if (w, h) != (64, 64):
    problems.append('尺寸是 %sx%s，期望 64x64' % (w, h))
if depth != 8:
    problems.append('位深是 %s，期望 8' % depth)
if ctype != 6:
    problems.append('颜色类型是 %s，期望 6（RGBA，必须带 alpha 通道）' % ctype)
# PNG 尾部的 12 字节是 [长度4][IEND4][CRC4]，所以 IEND 落在 -8:-4
if data[-8:-4] != b'IEND':
    problems.append('缺少 IEND 收尾')

if problems:
    for x in problems:
        print('  x 图标夹具不合格：' + x, file=sys.stderr)
    sys.exit(1)

print('  图标夹具 OK：%dx%d RGBA（%d 字节）' % (w, h, len(data)))
PY

# ══════════════════════════════════════════════════════════════════
#  汇总
# ══════════════════════════════════════════════════════════════════
echo
echo "════════ 生成完毕 ════════"
echo "AppImage   : $(find "$SANDBOX/apps" -name '*.AppImage' -o -name '*.APPIMAGE' | wc -l) 个文件"
echo "  其中真品 : 10 个（含 2 个应被剔除的假货）"
echo ".desktop   : $(find "$SANDBOX/desktops" -name '*.desktop' | wc -l) 个文件"
echo "图标       : $SANDBOX/icons/perfect.png"
echo
echo "预期：扫描器应找到 10 个真 AppImage，剔除 2 个假货。"
echo
echo "手工检查命令："
echo "  ls -la $SANDBOX/apps"
echo "  head -c 10 $SANDBOX/apps/Fake-1.0.AppImage | xxd"
echo "  cat $SANDBOX/desktops/perfect.desktop"
