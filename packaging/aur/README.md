# AUR 打包文件

这个目录是 [AUR](https://aur.archlinux.org/packages/appimage-manager-gtk) 包的源文件。
AUR 仓库里只放四个文件，其余一律不放（准则要求，二进制和构建产物会被删号处理）。

| 文件 | 作用 |
|---|---|
| `PKGBUILD` | 构建脚本 |
| `.SRCINFO` | 元数据，AUR 网站靠它显示版本和依赖 |
| `LICENSE` | **0BSD**。授权的是 PKGBUILD 本身，不是这个软件 |
| `.gitignore` | 白名单式，只放行上面几个 |

## 为什么包名带 `-gtk`

AUR 上 `appimage-manager` 这个名字虽然**数据库里查不到**（网页 404、RPC 返回
0 条），但它的 **git 仓库还在**，归另一个人：

```
提交    4deef98 "Initial commit"
作者    Alexis Lopez Zubieta <contact@azubieta.net>
日期    2020-08-03
上游    https://github.com/AppImageCrafters/appimage-manager   （Go 写的同名 CLI）
```

那个项目后来改名成了 `appimage-cli-tool`，AUR 上也换了名字，旧仓库没清干净。
后果是：仓库能 clone、**推送一律被拒** —— clone 是只读的，写权限只给原主人。

所以换成了 `appimage-manager-gtk`：既避开那个残留仓库，也说明这是 **GTK 版**，
和那个 Go 的命令行工具不是一回事。

> 如果哪天 AUR 把残留仓库清掉了，这个名字是可以搬回去的 ——
> 但要重新发布两个包，而且已经装过 `-gtk` 的用户不会自动跟着迁移，
> 所以除非有别的理由，没必要折腾。

## 为什么要放 0BSD 的 LICENSE

这是 AUR 的硬性规定（[RFC 40](https://rfc.archlinux.page/0040-license-package-sources/)）：

> 为仓库添加 `LICENSE` 文件，建议使用 0BSD 许可证……缺少许可证或使用与 0BSD
> 不同许可证的软件包**不允许**被加入到官方软件源中。

注意它和**软件本身**的许可证（GPL-3.0-or-later）是两回事 —— 后者由
`package()` 装到 `/usr/share/licenses/appimage-manager/`。

## 发布

前置条件：该版本的 GitHub Release **已经发布**（PKGBUILD 要从 Release 下载源码包
并写死校验和，Release 不存在的话 URL 就是死链）。

### 路线 A：GitHub Actions（推荐）

手动触发 **Actions → Publish to AUR → Run workflow**。

选这条的理由：

- `.SRCINFO` 必须由 `makepkg` 生成，而 `makepkg` 只有 Arch 有。本地开发机
  不是 Arch，只能用 `scripts/gen-srcinfo.sh` 替代，格式对不对当场验证不了。
  Actions 里起的是 `archlinux:base-devel` 容器，用的是真 `makepkg`。
- 私钥存在仓库 Secrets 里，不需要配到任何一台开发机上。
- 推之前会先 **`makepkg -s` 真构建一遍**，把「校验和填错」「源码包下不来」
  「build/package 坏了」这类问题挡在推送之前 —— 这些错如果推到 AUR，
  是**所有 Arch 用户**装的时候才炸。

需要配一次性 Secret：

```
设置 → Secrets and variables → Actions → New repository secret
  名称：AUR_SSH_PRIVATE_KEY
  值：  AUR 专用私钥的全文（含 BEGIN / END 两行）
```

workflow 里有两个输入：`version`（留空则读 `src/version.vala`）和
`dry_run`（只验证不推送）。

### 路线 B：本地脚本

```bash
# 1. 确认 src/version.vala 里的版本号已经对应上要发布的 tag
# 2. 发布 Release：先推 main 触发 CI，绿了再打 tag
# 3. 跑脚本
scripts/publish-aur.sh
```

脚本会：确认 Release 存在 → 从 `SHA256SUMS` 取源码包哈希 → 填进 PKGBUILD →
生成 `.SRCINFO` → 克隆 AUR 仓库 → **显式设置本地 git 身份** → 推送到 `master`。

只想看过程不推送：`AUR_DRY_RUN=1 scripts/publish-aur.sh`

本地脚本用的是**你这台机器上的私钥**，所以得先把 AUR 的 SSH 配好（见上一节）。
本机没有 `makepkg` 时它会退回 `scripts/gen-srcinfo.sh`，那种情况下建议先用
路线 A 的 `dry_run` 跑一次，让 CI 用真 `makepkg` 验证格式。

## 首次提交前的一次性准备

准则要求为 AUR 单独生成密钥，不要复用旧的（出问题可以直接弃用）：

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_aur -C "aur"
```

公钥粘到 AUR 的 *My Account* → *SSH Public Key*，然后：

```
# ~/.ssh/config
Host aur.archlinux.org
  IdentityFile ~/.ssh/id_aur
  User aur
```

首次 `git clone ssh://aur@aur.archlinux.org/appimage-manager.git` 会报
`warning: You appear to have cloned an empty repository` —— 这是预期的，
clone 一个还不存在的 pkgbase 就是在创建它。

## 几个容易踩的点

**`.SRCINFO` 必须和 PKGBUILD 一致。** 任何元数据变动（尤其 `pkgver`）之后都要
重新生成，否则 AUR 页面不会更新，而且推送可能被拒。

```bash
makepkg --printsrcinfo > .SRCINFO     # Arch 上
scripts/gen-srcinfo.sh > .SRCINFO     # 没有 makepkg 时（CI 会验证两者一致）
```

**只能推 `master` 分支。** 本地分支叫别的名字要先改名。

**推送前设本地 git 身份**，用 `cd` 进这个仓库之后单独设 —— 提交会公开署名，
而且推送后很难修改。

**不要自动化更新。** 准则明确说了自动更新 PKGBUILD 的风险自负，
出问题的账号和包可能被无预警删掉。上游依赖或许可证变了得有人看一眼，
所以这里只提供手动触发的脚本。
