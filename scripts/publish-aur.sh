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
#   appimage-manager-gtk      源码构建：要装 vala，编译约 1 分钟，会跑 258 项自测
#   appimage-manager-gtk-bin  AppImage 解包：秒装，只依赖 gtk3 + json-glib
#
# 为什么带 -gtk：AUR 上 appimage-manager 这个名字被一个残留的 git 仓库占着
# （AppImageCrafters 的 Go 版同名程序，包已删、仓库没清，推送一律被拒）。
# -bin 后缀是准则的硬性要求（"prebuilt deliverables ... must use the -bin
# suffix"），-gtk 则把它和那个 Go CLI 区分开。
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
AUR_GIT_BASE="${AUR_GIT_BASE:-ssh://aur@aur.archlinux.org}"
DRY_RUN="${AUR_DRY_RUN:-}"
STAGE_DIR="${AUR_STAGE:-}"

# pkgbase:源目录:Release 里对应的资产名（要拿它的哈希）
#
# 为什么叫 -gtk：AUR 上 appimage-manager 这个名字被一个**残留的 git 仓库**
# 占着 —— AppImageCrafters 的 Go 版同名程序（2020-08-03 的 Initial commit，
# 作者 azubieta），它后来改名 appimage-cli-tool，AUR 上换了名字，但旧仓库
# 没清干净。aurweb 数据库里查不到那个包（网页 404、RPC 0 条），可仓库还在
# 且归原主人，推送一律被拒。-gtk 既避开了它，也说明这是 GTK 版，
# 和那个 Go CLI 不是一回事。
ALL_PKGS=(
    "appimage-manager-gtk:packaging/aur:appimage-manager-VER-src.tar.gz"
    "appimage-manager-gtk-bin:packaging/aur-bin:AppImage-Manager-VER-x86_64.AppImage"
)

die () { echo "  ✗ $*" >&2; exit 1; }
say () { echo "  $*"; }

# 临时目录统一登记，脚本退出时（正常结束或中途出错）一起清掉。
#
# 用 EXIT trap 而不是「subshell + `|| rc=$?` 事后清理」：
# bash 会对 `||` 左边整个列表**禁用 errexit**，于是 subshell 里任何一步
# 失败（git push 被拒、git commit 出错）都只是继续往下执行，最后那句
# `say "✓ 已发布"` 返回 0，脚本以为成功了。这个坑真踩过 —— 推送被拒，
# 日志里却是「✓ 已发布」，白排查两轮。在 subshell 里补 `set -e` 也没用，
# 那个抑制标志会继承进去。详见 push_one。
CLEANUP_DIRS=()
cleanup_dirs () {
    local d
    for d in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do
        rm -rf "$d"
    done
}
trap cleanup_dirs EXIT

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

    local work
    work="$(mktemp -d)"
    CLEANUP_DIRS+=("$work")

    say "克隆 AUR 仓库 $pkgbase"
    # AUR_GIT_BASE 可覆盖，是为了能拿一个本地裸仓库把「预检 → 提交 → 推送 →
    # 回读校验」整条链路真跑一遍，不用往真的 AUR 推东西。
    if ! git clone --quiet "$AUR_GIT_BASE/$pkgbase.git" \
            "$work/$pkgbase" 2>"$work/err"; then
        sed 's/^/      /' "$work/err" >&2
        die "克隆 $pkgbase 失败。检查 SSH 配置和 AUR 账号

  ssh -T aur@aur.archlinux.org   # 应回 'Successfully authenticated'"
    fi

    cd "$work/$pkgbase"

    # ── 预检：远端那个仓库是不是我们的 ──────────────────────────────────
    #
    # AUR 上会留下「已删除包的 git 仓库」：aurweb 数据库里查不到（网页 404、
    # RPC 返回 0 条），但仓库还在、归原主人 —— clone 得到、推送被拒。
    # 没有这一步的话，要等最后 push 才炸，而 push 被拒的原因（不是你的仓库）
    # 在报错里并不明显。看一眼远端已有提交的作者就能提前说清楚。
    #
    # 这不是假想：appimage-manager 就撞上了（AppImageCrafters 的 Go 版同名
    # 程序，2020 年的 Initial commit，包已删、仓库没清）。
    if git rev-parse --verify -q origin/master >/dev/null 2>&1; then
        local foreign
        # || true 不能省：署名全是我们的时 grep 返回 1，pipefail 下这个赋值
        # 会失败，set -e 直接把脚本掐断 —— 表现是「一切正常但什么都没发生」。
        foreign="$(git log --format='%ae' origin/master \
                   | grep -vx "42199147+DarkLord-W@users.noreply.github.com" \
                   | head -1 || true)"
        if [ -n "$foreign" ]; then
            echo "  远端已有提交历史，且不是本项目的署名："
            git log --format='      %h  %ad  %an <%ae>  %s' --date=short \
                origin/master | head -5
            die "$pkgbase: 这个 pkgbase 的 git 仓库不是我们的（作者 $foreign）。

  AUR 上常见这种情况：包已经删了、网站查不到，但 git 仓库没清干净，
  推送一定会被拒。两条路：
    · 向 AUR 申请删除残留仓库（#archlinux-aur 或 aur-general 邮件列表）
    · 换一个 pkgbase 名字"
        fi
    fi

    # 准则只收 master 分支。空仓库时 HEAD 本来就指向 master，
    # 这一行主要是防 clone 下来停在别的分支上。
    git checkout -q -B master 2>/dev/null || true

    prepare_one "$pkgbase" "$PROJECT_DIR/$srcdir" \
                "${asset//VER/$VERSION}" "$work/$pkgbase"

    # 准则要求仓库里只放 PKGBUILD / .SRCINFO / LICENSE / .gitignore
    # 这几个文件（外加 .git 本身）。混进别的会被删号处理。
    local extra
    extra="$(ls -A | grep -vxE '\.git|PKGBUILD|\.SRCINFO|LICENSE|\.gitignore' || true)"
    [ -z "$extra" ] || die "$pkgbase: 工作目录里有不该提交的东西：
$(printf '%s\n' "$extra" | sed 's/^/      /')"

    # 少了 .SRCINFO，aurweb 不会登记这个包：git 层推送会成功，但网页一直
    # 404 —— 比推送被拒更难查，因为推送的返回码是 0。
    [ -s .SRCINFO ] || die "$pkgbase: .SRCINFO 缺失或为空"

    # 提交会用全局 git 身份署名，而且推送后很难修改 ——
    # 所以这里显式设成本机的身份，不依赖全局配置。
    git config user.name  "DarkLord-W"
    git config user.email "42199147+DarkLord-W@users.noreply.github.com"

    git add -A
    echo "  将要提交："
    git status --short | sed 's/^/      /'

    if [ -n "$DRY_RUN" ]; then
        say "AUR_DRY_RUN=1，停在这里（临时目录随脚本退出一起删掉）"
        cd "$PROJECT_DIR"
        return 0
    fi
    if git diff --cached --quiet; then
        say "和 AUR 上现有的内容一致，无需提交"
        cd "$PROJECT_DIR"
        return 0
    fi
    if git rev-parse --verify -q HEAD >/dev/null; then
        git commit -q -m "upstream release v$VERSION"
    else
        git commit -q -m "initial upload: $pkgbase $VERSION"
    fi
    say "已提交：$(git log --oneline -1)"

    say "推送…"
    git push origin master

    # 回读校验：`git push` 返回 0 只说明客户端没报错，真正的产物是远端
    # 那个 ref。直接问远端要答案，不靠猜。
    local local_head remote_head
    local_head="$(git rev-parse HEAD)"
    remote_head="$(git ls-remote --heads origin master 2>/dev/null \
                   | awk '{print $1}' || true)"
    if [ "$remote_head" != "$local_head" ]; then
        die "$pkgbase: 推送后回读不一致 —— 本地 ${local_head:0:8}，远端 ${remote_head:0:12}。
  推送没有真正落地，AUR 上不会有这个包。"
    fi

    say "✓ $pkgbase 已发布（远端 master ${local_head:0:8}）"
    cd "$PROJECT_DIR"
}

# ── 逐个包处理 ───────────────────────────────────────────────────────────────
for entry in "${ALL_PKGS[@]}"; do
    pkgbase="${entry%%:*}"
    rest="${entry#*:}"
    srcdir="${rest%%:*}"
    asset="${rest#*:}"

    case "$WANT" in
        src) [ "$pkgbase" = "appimage-manager-gtk" ]     || continue ;;
        bin) [ "$pkgbase" = "appimage-manager-gtk-bin" ] || continue ;;
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
    say "  https://aur.archlinux.org/packages/appimage-manager-gtk"
    say "  https://aur.archlinux.org/packages/appimage-manager-gtk-bin"
fi
