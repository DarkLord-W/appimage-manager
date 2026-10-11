#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 DarkLord-W
#
# publish-aur.sh — 把 packaging/aur/ 里的内容发布到 AUR
#
# 用法:
#   scripts/publish-aur.sh                    # 版本号从 src/version.vala 读
#   scripts/publish-aur.sh 1.1.0              # 或显式指定
#   AUR_DRY_RUN=1 scripts/publish-aur.sh      # 只准备文件，不提交不推送
#
# 前置条件（AUR 提交准则要求）：
#   1. 该版本的 GitHub Release 已经发布 —— 源码包和它的 SHA256SUMS 都在上面
#   2. 已经把 SSH 公钥加到 AUR 账号（My Account → SSH Public Key）
#   3. 本机 git 能通过 ssh://aur@aur.archlinux.org 访问（~/.ssh/config 配好）
#
# 关于 .SRCINFO：正规生成方式是 makepkg --printsrcinfo，只有 Arch 上有。
# 本脚本优先用它；没有就用 scripts/gen-srcinfo.sh（CI 里有一个 job 在
# archlinux:base-devel 容器里跑真 makepkg 做对比，保证两者输出一致）。
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

PKGNAME=appimage-manager
REPO_URL="https://github.com/DarkLord-W/appimage-manager"
SRC_DIR="$PROJECT_DIR/packaging/aur"
AUR_SSH="ssh://aur@aur.archlinux.org/$PKGNAME.git"
DRY_RUN="${AUR_DRY_RUN:-}"

die () { echo "  ✗ $*" >&2; exit 1; }
say () { echo "  $*"; }

# ── 版本号 ───────────────────────────────────────────────────────────────────
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(sed -n 's/.*APPMGR_VERSION[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
               src/version.vala | head -n 1)"
    [ -n "$VERSION" ] || die "读不出 src/version.vala 里的 APPMGR_VERSION"
fi
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || die "版本号格式不对：'$VERSION'（应形如 1.2.3）"
say "版本 $VERSION"

# ── 源码包必须已经发布，否则 PKGBUILD 里的 URL 是死链 ────────────────────────
SRC_TARBALL="$PKGNAME-$VERSION-src.tar.gz"
SUM_URL="$REPO_URL/releases/download/v$VERSION/SHA256SUMS"
say "取 $SUM_URL"
SUMS="$(curl -fsSL --retry 3 "$SUM_URL" 2>/dev/null)" \
    || die "拿不到 SHA256SUMS —— v$VERSION 的 Release 还没发布？

  AUR 的 PKGBUILD 要从 Release 下载源码包并写死校验和，
  所以**必须先发布 GitHub Release**，流程是：

      git push origin master                 # 触发 CI
      git tag -a v$VERSION -m 'v$VERSION'    # CI 绿了再打 tag
      git push origin v$VERSION              # 触发发布

  等 Release 页面出现 $SRC_TARBALL 之后再跑本脚本。"

SHA="$(echo "$SUMS" | awk -v f="$SRC_TARBALL" '$2 == f { print $1 }')"
[ -n "$SHA" ] || die "SHA256SUMS 里没有 $SRC_TARBALL。已有的条目：
$(echo "$SUMS" | sed 's/^/      /')"
say "源码包 sha256 ${SHA:0:16}…"

# ── 在临时目录里准备 AUR 仓库 ───────────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
say "克隆 AUR 仓库到 $WORK/$PKGNAME"
if ! git clone --quiet "$AUR_SSH" "$WORK/$PKGNAME" 2>"$WORK/clone.err"; then
    if grep -q "empty repository" "$WORK/clone.err" 2>/dev/null; then
        :   # 首次提交，空仓库是预期的
    else
        sed 's/^/      /' "$WORK/clone.err" >&2
        die "克隆失败。检查：
      · SSH 公钥是否已加到 AUR 账号（My Account → SSH Public Key）
      · ~/.ssh/config 里是否配了
            Host aur.archlinux.org
              IdentityFile ~/.ssh/id_aur
              User aur
      · 首次提交前该包名必须还没被别人占用"
    fi
fi
cd "$WORK/$PKGNAME"
# AUR 只接受 master 分支
git checkout -q -B master 2>/dev/null || git checkout -q --orphan master

# ── 写文件（只放准则允许的四样）─────────────────────────────────────────────
cp "$SRC_DIR/LICENSE"    ./LICENSE
cp "$SRC_DIR/.gitignore" ./.gitignore

# PKGBUILD：填进这次真正的版本号和校验和
sed -e "s|^pkgver=.*|pkgver=$VERSION|" \
    -e "s|^pkgrel=.*|pkgrel=1|" \
    -e "s|^sha256sums=.*|sha256sums=('$SHA')|" \
    "$SRC_DIR/PKGBUILD" > ./PKGBUILD

grep -q "^pkgver=$VERSION$" ./PKGBUILD || die "pkgver 没写进去"
grep -q "$SHA" ./PKGBUILD               || die "sha256sums 没写进去"
say "PKGBUILD 已填好 pkgver=$VERSION / pkgrel=1 / sha256sums"

# .SRCINFO：有 makepkg 就用它（权威），否则用生成器
if command -v makepkg >/dev/null 2>&1; then
    ( cd "$WORK/$PKGNAME" && makepkg --printsrcinfo > .SRCINFO )
    say ".SRCINFO 由 makepkg --printsrcinfo 生成"
else
    "$PROJECT_DIR/scripts/gen-srcinfo.sh" "$WORK/$PKGNAME/PKGBUILD" > .SRCINFO
    say ".SRCINFO 由 scripts/gen-srcinfo.sh 生成（本机没有 makepkg）"
    say "  提示：CI 的 aur-check job 会在 archlinux 容器里用真 makepkg"
    say "        做一次对比，确认两者输出一致。"
fi
[ -s .SRCINFO ] || die ".SRCINFO 是空的"

# ── 干净检查：白名单之外的东西一律不许进仓库 ────────────────────────────────
EXTRA="$(ls -A | grep -vxE '\.git|PKGBUILD|\.SRCINFO|LICENSE|\.gitignore' || true)"
[ -z "$EXTRA" ] || die "工作目录里有不该提交的东西：
$(echo "$EXTRA" | sed 's/^/      /')"

# ── 提交 ────────────────────────────────────────────────────────────────────
# 准则警告：提交会用全局 git 身份署名，推送后很难改。AUR 仓库必须显式设。
git config user.name  "DarkLord-W"
git config user.email "42199147+DarkLord-W@users.noreply.github.com"

echo
say "将要提交："
git add -A
git status --short | sed 's/^/      /'

if [ -n "$DRY_RUN" ]; then
    echo
    say "AUR_DRY_RUN=1，停在这里。文件在 $WORK/$PKGNAME（脚本退出后会删）"
    say "想留下来看就中断前先 cp 出去。"
    exit 0
fi

if git diff --cached --quiet; then
    say "没有变化，无需提交"
    exit 0
fi

if git rev-parse --verify HEAD >/dev/null 2>&1; then
    git commit -q -m "upstream release v$VERSION"
else
    git commit -q -m "initial upload: $PKGNAME $VERSION"
fi
say "已提交：$(git log --oneline -1)"

echo
say "推送到 AUR…"
git push --quiet origin master
echo
say "✓ 完成。几分钟后可在 https://aur.archlinux.org/packages/$PKGNAME 看到"
