# AUR 打包文件：`appimage-manager-gtk-bin`

这个目录是 [AUR](https://aur.archlinux.org/packages/appimage-manager-gtk-bin) 上
`-bin` 包的源文件。AUR 仓库里只放四个文件，其余一律不放（准则要求，二进制和
构建产物会被删号处理）：

| 文件 | 作用 |
|---|---|
| `PKGBUILD` | 构建脚本 |
| `.SRCINFO` | 元数据，AUR 网站靠它显示版本和依赖 |
| `LICENSE` | **0BSD**。授权的是 PKGBUILD 本身，不是这个软件 |
| `.gitignore` | 白名单式，只放行上面几个 |

发布流程、首次提交前的一次性准备（生成 AUR 专用密钥、配 SSH、公钥传到 AUR）、
以及几个容易踩的点，全都写在 [`packaging/aur/README.md`](../aur/README.md) 里，
两个包**完全一样**，这里不重复一遍 —— 两份文档抄来抄去，改了一处漏一处。

## 它和源码版是什么关系

两个包并存，装的是同一个程序，所以**互相冲突**，用户二选一：

```
provides=('appimage-manager-gtk')
conflicts=('appimage-manager-gtk')
```

| | `appimage-manager-gtk` | `appimage-manager-gtk-bin` |
|---|---|---|
| 源 | Release 里的源码包 | Release 里的 AppImage |
| 装的时候 | 拖 `vala` + `pkgconf`（约 100 MB），编译约 1 分钟 | 秒级，只解包 |
| 跑不跑自测 | 跑 258 项引擎自测 | 不跑 —— 自测是构建期的事 |
| 运行时依赖 | `gtk3` `json-glib` | **完全相同** |
| 装出来的文件树 | 逐路径一致，`licenses/` 下的目录名跟着包名 | |

两个包的**文件树**一样，但二进制不逐字节相同 —— 一个是 CI 上用 Ubuntu 的
编译器编的，一个是用户机器上的 valac/gcc 编的，BuildID 都对不上。这是正常的，
不是打包出了错。

用 `provides` + `conflicts` 而不是 `replaces`：准则里 `replaces` 是给
**软件包改名**用的（让 pacman 自动换掉旧包），这里只是同一个软件的不同来源，
用户应该自己选，不该被悄悄替换。

**`-bin` 后缀是准则的硬性要求**，原文：

> Packages that use prebuilt deliverables, when the sources are available,
> **must use the `-bin` suffix**.

源码包就在旁边，所以合规。名字里的 `-gtk` 则是因为 AUR 上 `appimage-manager`
被一个残留的 git 仓库占着，推送一律被拒 —— 原委见
[`packaging/aur/README.md`](../aur/README.md)。

（AUR 上另有 400 多个包用 `-appimage` 后缀，但那是民间惯例，准则里一次都没
提过。而且那些包大多是**把 `.AppImage` 文件原样装进去**再软链到 `/usr/bin`；
我们这个是把 AppImage 解包成普通文件树，用 `-appimage` 反而会让人装完去找一个
根本不存在的 `.AppImage` 文件。）

## 关键设计：解包，而不是装 AppImage 本身

`package()` 里跑的是 `--appimage-extract`，不是把 `.AppImage` 丢进 `/usr/bin`。

直接把 AppImage 装进去的话，用户**每次运行都要 FUSE 挂载**，包就得依赖
`fuse2` —— 而那是 AppImage 这个**格式**的开销，程序本身根本不需要它。
解出来按正常目录结构装，既没有 `fuse2` 依赖，也没有每次启动的挂载开销。

三处不能照搬 AppImage 的东西：

**`.desktop` 的 `Exec`。** AppImage 里那份写的是 `Exec=AppRun %U`，而 `AppRun`
是 AppImage 内部的启动器，正常安装之后那个文件不存在。`package()` 里用 `sed`
把它改成 `/usr/bin/appimage-manager`，**其余字段照抄**。

不自己写一份完整的 `.desktop`：AppImage 里那份本来就是从仓库的
`data/appimage-manager.desktop.in` 模板生成的，抄一份出来就有了两个真相来源，
将来改模板必然会漏掉这个。尤其是 `StartupWMClass=appimage-manager` ——
它必须和程序里 `set_wmclass()` 的 class 字段一致，否则任务栏图标会退回通用占位图。

**许可证全文。** GPL-3.0 要求分发二进制时附带许可证全文。AppImage 里有
（`make install` 装的，AppImage 内的路径是
`usr/share/licenses/appimage-manager/LICENSE`），直接取过来，装进包的
`usr/share/licenses/$pkgname/`。取不到就**报错退出**，不静默少一个文件。

**图标。** 装到 `hicolor/256x256/apps/`，靠名字 `appimage-manager` 让主题索引
去找，和源码版一致。

## 一个前提：AppImage 里必须有 LICENSE

`package()` 会检查 AppImage 里有没有许可证文件，没有就直接失败。这个检查是
故意的 —— 老版本的 `make-appimage.sh` 不装许可证，用它打出来的包会**静默地**
少一个文件，而 GPL 合规问题不该靠肉眼发现。

所以：**v1.1.0 之前的 AppImage 不能用来构建这个包**。那时两个地方都缺 ——
`Makefile` 的 `install` 目标没装许可证，而 AppImage 的 AppDir 又是
`make-appimage.sh` 手工拼的、根本不走 `make install`。v1.1.0 起两处都补上了。
