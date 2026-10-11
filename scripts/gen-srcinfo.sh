#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 DarkLord-W
#
# gen-srcinfo.sh — 从 PKGBUILD 生成 .SRCINFO
#
# 为什么需要它：`.SRCINFO` 的正规生成方式是 `makepkg --printsrcinfo`，但那只
# 有 Arch 上才有。这个脚本用同样的办法 —— **source 一遍 PKGBUILD，再把变量
# 按 makepkg 的格式打出来** —— 所以 ${pkgname} 之类的变量展开、数组都跟
# makepkg 一致，比正则解析 PKGBUILD 可靠得多。
#
# 注意：这个脚本的输出**必须**和真 makepkg 的一致，否则 AUR 会拒收。
# CI 里有一个 job 在 archlinux:base-devel 容器里跑真 makepkg 做对比，
# 不一致就报错 —— 所以这里任何格式改动都会被验证。
#
# 用法: scripts/gen-srcinfo.sh [PKGBUILD 路径] > .SRCINFO
set -euo pipefail

PKGBUILD="${1:-packaging/aur/PKGBUILD}"
[ -f "$PKGBUILD" ] || { echo "找不到 $PKGBUILD" >&2; exit 1; }

# PKGBUILD 里会引用 $srcdir / $pkgdir 之类，source 前先给个占位，
# 免得 set -u 把它们当未定义变量。
srcdir="${srcdir:-/tmp}"
pkgdir="${pkgdir:-/tmp}"
startdir="$(cd "$(dirname "$PKGBUILD")" && pwd)"

# shellcheck disable=SC1090
source "$PKGBUILD"

# makepkg 的默认值：pkgbase 没写就是 pkgname
: "${pkgbase:=$pkgname}"

# 按 `makepkg --printsrcinfo` 的字段顺序输出。顺序是有讲究的：makepkg 按固定
# 顺序写，AUR 那边的对比也按这个顺序，顺序错了 diff 就对不上。
emit () { printf '\t%s = %s\n' "$1" "$2"; }

printf 'pkgbase = %s\n' "$pkgbase"
[ -n "${pkgdesc:-}"  ] && emit pkgdesc  "$pkgdesc"
emit pkgver "$pkgver"
emit pkgrel "$pkgrel"
[ -n "${epoch:-}"    ] && emit epoch "$epoch"
[ -n "${url:-}"      ] && emit url "$url"
[ -n "${install:-}"  ] && emit install "$install"
[ -n "${changelog:-}" ] && emit changelog "$changelog"

# 数组变量用 ${arr[@]+"${arr[@]}"} 展开 —— 这个写法在变量**未定义**时什么都不
# 产生。写成 "${arr[@]:-}" 的话，未定义的数组会展开出一个空字符串，
# 于是输出里会多出 `groups = ` 这种空行，AUR 那边 diff 就对不上了。
emit_arr () {
    local name="$1"; shift
    local x
    for x in ${@+"$@"}; do
        emit "$name" "$x"
    done
}

emit_arr arch         ${arch[@]+"${arch[@]}"}
emit_arr groups       ${groups[@]+"${groups[@]}"}
emit_arr license      ${license[@]+"${license[@]}"}
emit_arr checkdepends ${checkdepends[@]+"${checkdepends[@]}"}
emit_arr makedepends  ${makedepends[@]+"${makedepends[@]}"}
emit_arr depends      ${depends[@]+"${depends[@]}"}
emit_arr optdepends   ${optdepends[@]+"${optdepends[@]}"}
emit_arr provides     ${provides[@]+"${provides[@]}"}
emit_arr conflicts    ${conflicts[@]+"${conflicts[@]}"}
emit_arr replaces     ${replaces[@]+"${replaces[@]}"}
emit_arr backup       ${backup[@]+"${backup[@]}"}
emit_arr options      ${options[@]+"${options[@]}"}
emit_arr source       ${source[@]+"${source[@]}"}
emit_arr noextract    ${noextract[@]+"${noextract[@]}"}

# 完整性校验字段。makepkg 用哪个取决于 PKGBUILD 里写了哪个，
# 本项目只用 sha256sums。
emit_arr sha256sums   ${sha256sums[@]+"${sha256sums[@]}"}

# 每个 pkgname 一段。单包 PKGBUILD 且没有逐包覆盖时，makepkg 只输出一行
# `pkgname = xxx`，后面不跟任何字段。
printf '\n'
printf 'pkgname = %s\n' "$pkgname"
