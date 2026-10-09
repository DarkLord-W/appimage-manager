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
python3 - "$SANDBOX/icons/perfect.png" <<'PY'
import gi, sys, cairo
gi.require_version('Gtk','3.0')
import cairo
surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, 64, 64)
cr = cairo.Context(surf)
cr.set_source_rgb(0.2, 0.7, 0.5)
cr.arc(32, 32, 26, 0, 6.2832)
cr.fill()
surf.write_to_png(sys.argv[1])
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
