#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 DarkLord-W
#
# publish-aur.sh — 把 packaging/aur*/ 里的内容发布到 AUR
#
# 用法:
#   scripts/publish-aur.sh                    # 两个包都发，版本号读 src/version.vala
#   scripts/publish-aur.sh 1.2.3              # 指定版本
#   scripts/publish-aur.sh 1.2.3 src          # 只发源码包
#   scripts/publish-aur.sh 1.2.3 bin          # 只发 -bin 包
#   AUR_DRY_RUN=1 scripts/publish-aur.sh      # 准备好但不提交不推送
#   AUR_STAGE=/tmp/stage scripts/publish-aur.sh   # 只准备到目录，完全不碰 AUR
#
# 发的是两个包（AUR 上互相冲突，用户二选一）：
#   appimage-manager      源码构建：要装 vala，编译约 1 分钟，会跑 258 项自测
#   appimage-manager-bin  AppImage 解包：秒装，只依赖 gtk3 + json-glib
#
# AUR_STAGE 是给 .github/workflows/publish-aur.yml 用的。**必须先填校验和
# 再构建**：仓库里的 PKGBUILD 留的是全零占位符，拿它直接 `makepkg -s`
# 必在校验和那一关失败。所以 workflow 先用这个模式准备出一份填好的
# PKGBUILD，在真 Arch 容器里构建两个包，全绿了才走推送。
#
# 前置条件（AUR 提交准则要求）：
#   1. 该版本的 GitHub Release 已经发布 —— 源包和 SHA256SUMS 都在上面
#   2. 已经把 SSH 公钥加到 AUR 账号（My Account → SSH Public Key）
#   3. 本机 git 能通过 ssh://aur@aur.archlinux.org 访问
#
# 关于 .SRCINFO：正规生成方式是 makepkg --printsrcinfo，只有 Arch 上有。
# 本脚本优先用它；没有就用 scripts/gen-srcinfo.sh。CI 的 aur-check job
# 会在 archlinux 容器里用真 makepkg 做逐字节对比，保证两者一致。
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

REPO_URL="https://github.com/DarkLord-W/appimage-manager"
REPO_SLUG="${REPO_URL#https://github.com/}"
DRY_RUN="${AUR_DRY_RUN:-}"
STAGE_DIR="${AUR_STAGE:-}"

# pkgbase:源目录:Release 里对应的资产名（要拿它的哈希）
ALL_PKGS=(
    "appimage-manager:packaging/aur:appimage-manager-VER-src.tar.gz"
    "appimage-manager-bin:packaging/aur-bin:AppImage-Manager-VER-x86_64.AppImage"
)

die () { echo "  ✗ $*" >&2; exit 1; }
say () { echo "  $*"; }

# ── 参数 ─────────────────────────────────────────────────────────────────────
VERSION=""
WANT="both"
for arg in "$@"; do
    case "$arg" in
        src) WANT="src" ;;
        bin) WANT="bin" ;;
        *)   VERSION="$arg" ;;
    esac
done
if [ -z "$VERSION" ]; then
    VERSION="$(sed -n 's/.*APPMGR_VERSION[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
               src/version.vala | head -n 1)"
    [ -n "$VERSION" ] || die "读不出 src/version.vala 里的 APPMGR_VERSION"
fi
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || die "版本号格式不对：'$VERSION'（应形如 1.2.3）"
say "版本 $VERSION，发布范围 $WANT"
[ -n "$STAGE_DIR" ] && say "只准备到 $STAGE_DIR，不碰 AUR"

# ── 取 SHA256SUMS ────────────────────────────────────────────────────────────
#
# 标准地址是 releases/download/…，但那要连 github.com，国内网络经常连不上
# （这个项目的开发机上就是这样，直连直接超时）。api.github.com 通常能通，
# 而且是同一个域名的另一套接口，取到的是同一份文件 —— 所以直连失败就退回 API。
# 有 GITHUB_TOKEN 的话带上，未认证限额是 60 次/小时。
api_curl () {
    local url="$1" accept="${2:-application/vnd.github+json}"
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsSL --retry 2 --connect-timeout 15 \
             -H "Accept: $accept" -H "Authorization: Bearer $GITHUB_TOKEN" "$url"
    else
        curl -fsSL --retry 2 --connect-timeout 15 -H "Accept: $accept" "$url"
    fi
}

fetch_sums () {
    local std="$REPO_URL/releases/download/v$VERSION/SHA256SUMS"

    say "取 $std"
    if SUMS="$(curl -fsSL --retry 2 --connect-timeout 15 "$std" 2>/dev/null)" \
       && [ -n "${SUMS:-}" ]; then
        say "直连取到 $(printf '%s\n' "$SUMS" | grep -c .) 条校验和"
        return 0
    fi

    say "直连 github.com 不通，改走 api.github.com"
    command -v python3 >/dev/null 2>&1 \
        || die "退回 API 需要 python3 解析响应，但这台机器上没有"

    local rel asset_url
    rel="$(api_curl "https://api.github.com/repos/$REPO_SLUG/releases/tags/v$VERSION" || true)"
    if [ -z "$rel" ]; then
        rel="$(api_curl "https://api.github.com/repos/$REPO_SLUG/releases/latest" || true)"
    fi
    [ -n "$rel" ] || return 1

    asset_url="$(printf '%s' "$rel" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
for a in d.get("assets", []):
    if a.get("name") == "SHA256SUMS":
        print(a["url"]); break
' || true)"
    if [ -z "$asset_url" ]; then
        say "v$VERSION 的 Release 里没有 SHA256SUMS 资产"
        return 1
    fi

    SUMS="$(api_curl "$asset_url" "application/octet-stream" 2>/dev/null || true)"
    [ -n "${SUMS:-}" ] || return 1
    say "从 API 取到 $(printf '%s\n' "$SUMS" | grep -c .) 条校验和"
}

fetch_sums || die "拿不到 SHA256SUMS —— v$VERSION 的 Release 还没发布？

  AUR 的 PKGBUILD 要从 Release 下载源包并写死校验和，
  所以**必须先发布 GitHub Release**：

      ./appimage-manager-push.sh          # 推 main + 打 tag + 等构建

  等 Release 页面出现资产之后再跑本脚本。"

# ── 准备一个包的文件 ─────────────────────────────────────────────────────────
#
# 把版本号、pkgrel 和从 SHA256SUMS 取到的真校验和填进 PKGBUILD，生成
# .SRCINFO，连 LICENSE 和 .gitignore 一起放到 $4。
prepare_one () {
    local pkgbase="$1" srcdir="$2" asset="$3" dest="$4"

    local sha
    sha="$(printf '%s\n' "$SUMS" | awk -v f="$asset" '$2 == f { print $1 }')"
    [ -n "$sha" ] || die "SHA256SUMS 里没有 $asset。已有条目：
$(printf '%s\n' "$SUMS" | sed 's/^/      /')"

    [ -f "$srcdir/PKGBUILD" ] || die "缺 $srcdir/PKGBUILD"

    mkdir -p "$dest"
    cp "$srcdir/LICENSE"    "$dest/LICENSE"
    cp "$srcdir/.gitignore" "$dest/.gitignore"

    sed -e "s|^pkgver=.*|pkgver=$VERSION|" \
        -e "s|^pkgrel=.*|pkgrel=1|" \
        -e "s|^sha256sums=.*|sha256sums=('$sha')|" \
        "$srcdir/PKGBUILD" > "$dest/PKGBUILD"

    # 只 sed 不验的话，将来 PKGBUILD 的写法一变（比如校验和改成多行数组），
    # sed 会静默匹配不上，然后带着全零占位符推上 AUR —— 那要等所有 Arch
    # 用户装的时候才发现。
    grep -q "^pkgver=$VERSION$" "$dest/PKGBUILD" || die "$pkgbase: pkgver 没写进去"
    grep -qF "$sha" "$dest/PKGBUILD"             || die "$pkgbase: sha256sums 没写进去"

    if command -v makepkg >/dev/null 2>&1; then
        ( cd "$dest" && makepkg --printsrcinfo > .SRCINFO )
        say "$pkgbase: .SRCINFO 由 makepkg 生成"
    else
        "$PROJECT_DIR/scripts/gen-srcinfo.sh" "$dest/PKGBUILD" > "$dest/.SRCINFO"
        say "$pkgbase: .SRCINFO 由 gen-srcinfo.sh 生成（本机没有 makepkg，CI 会验证）"
    fi
    [ -s "$dest/.SRCINFO" ] || die "$pkgbase: .SRCINFO 是空的"

    say "$pkgbase: 源 $(basename "$asset")，sha256 ${sha:0:16}…"
}

# ── 推一个包到 AUR ───────────────────────────────────────────────────────────
push_one () {
    local pkgbase="$1" srcdir="$2" asset="$3"

    local work rc=0
    work="$(mktemp -d)"

    say "克隆 AUR 仓库 $pkgbase"
    if ! git clone --quiet "ssh://aur@aur.archlinux.org/$pkgbase.git" \
            "$work/$pkgbase" 2>"$work/err"; then
        sed 's/^/      /' "$work/err" >&2
        rm -rf "$work"
        die "克隆 $pkgbase 失败。检查 SSH 配置和 AUR 账号

  ssh -T aur@aur.archlinux.org   # 应回 'Successfully authenticated'"
    fi

    (
        cd "$work/$pkgbase"
        # 准则只收 master 分支。空仓库时 HEAD 本来就指向 master，
        # 这一行主要是防 clone 下来停在别的分支上。
        git checkout -q -B master 2>/dev/null || true

        prepare_one "$pkgbase" "$PROJECT_DIR/$srcdir" \
                    "${asset//VER/$VERSION}" "$work/$pkgbase"

        # 准则要求仓库里只放 PKGBUILD / .SRCINFO / LICENSE / .gitignore
        # 这几个文件（外加 .git 本身）。混进别的会被删号处理。
        extra="$(ls -A | grep -vxE '\.git|PKGBUILD|\.SRCINFO|LICENSE|\.gitignore' || true)"
        [ -z "$extra" ] || die "$pkgbase: 工作目录里有不该提交的东西：
$(printf '%s\n' "$extra" | sed 's/^/      /')"

        # 提交会用全局 git 身份署名，而且推送后很难修改 ——
        # 所以这里显式设成本机的身份，不依赖全局配置。
        git config user.name  "DarkLord-W"
        git config user.email "42199147+DarkLord-W@users.noreply.github.com"

        git add -A
        echo "  将要提交："
        git status --short | sed 's/^/      /'

        if [ -n "$DRY_RUN" ]; then
            say "AUR_DRY_RUN=1，停在这里（临时目录随脚本退出一起删掉）"
            exit 0
        fi
        if git diff --cached --quiet; then
            say "和 AUR 上现有的内容一致，无需提交"
            exit 0
        fi
        if git rev-parse --verify HEAD >/dev/null 2>&1; then
            git commit -q -m "upstream release v$VERSION"
        else
            git commit -q -m "initial upload: $pkgbase $VERSION"
        fi
        say "已提交：$(git log --oneline -1)"
        say "推送…"
        git push --quiet origin master
        say "✓ $pkgbase 已发布"
    ) || rc=$?

    rm -rf "$work"
    return $rc
}

# ── 逐个包处理 ───────────────────────────────────────────────────────────────
for entry in "${ALL_PKGS[@]}"; do
    pkgbase="${entry%%:*}"
    rest="${entry#*:}"
    srcdir="${rest%%:*}"
    asset="${rest#*:}"

    case "$WANT" in
        src) [ "$pkgbase" = "appimage-manager" ]     || continue ;;
        bin) [ "$pkgbase" = "appimage-manager-bin" ] || continue ;;
    esac

    echo
    echo "══ $pkgbase ══"

    if [ -n "$STAGE_DIR" ]; then
        prepare_one "$pkgbase" "$srcdir" "${asset//VER/$VERSION}" "$STAGE_DIR/$pkgbase"
    else
        push_one "$pkgbase" "$srcdir" "$asset"
    fi
done

echo
if [ -n "$STAGE_DIR" ]; then
    say "✓ 已准备到 $STAGE_DIR（没有碰 AUR）"
elif [ -n "$DRY_RUN" ]; then
    say "（AUR_DRY_RUN=1，没有真的推送）"
else
    say "AUR 索引有几秒延迟，刚推完可能还看不到："
    say "  https://aur.archlinux.org/packages/appimage-manager"
    say "  https://aur.archlinux.org/packages/appimage-manager-bin"
fi
