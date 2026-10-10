# AppImage Manager

一个用 **Vala + GTK3** 写的 AppImage 桌面集成管理器。扫描你指定的目录，把 AppImage 变成规范的 `.desktop` 启动器，并持续维护它们的健康状态。

编译产物是**单个原生二进制**，拷到任何装了 GTK3 的 Linux 上都能直接跑。

## 下载

| 格式 | 适合谁 |
|---|---|
| `AppImage-Manager-*-x86_64.AppImage` | 免安装，赋可执行权限后双击即用 |
| `appimage-manager-*-linux-x86_64.tar.gz` | 想免安装、又要能进应用菜单 |
| `appimage-manager_*_amd64.deb` | Debian / Ubuntu / Kali / Mint |
| `appimage-manager-*.x86_64.rpm` | Fedora / RHEL / openSUSE |
| `appimage-manager-*.pkg.tar.zst` | Arch / Manjaro |

从 [Releases](https://github.com/DarkLord-W/appimage-manager/releases) 下载。

原生二进制与 AppImage 都**依赖系统的 GTK3**（桌面发行版基本都有）。用
deb / rpm / arch 包时依赖会被自动声明并装好。

---

## 功能

### 扫描
- 多个扫描目录，递归子目录
- 按扩展名初筛 + **ELF 魔数 + AppImage "AI" 魔数**双重校验，剔除改成 `.AppImage` 后缀的假货
- 扫描结果与 `~/.local/share/applications` 里的现有条目自动关联

### 创建启动器
- 从 AppImage 内部提取真实元数据：`Name` / `Comment` / `Categories` / `StartupWMClass` / `MimeType`
- 提取内置图标（`.DirIcon` 优先，其次最大尺寸的 png/svg），缩放后缓存到 `hicolor`
- `Exec` 字段按 XDG 规范**完整转义**（空格加引号、字面 `%` 写成 `%%`、shell 元字符转义）
- 写入前用 `desktop-file-validate` 校验，校验不过则回滚
- 原子写入（临时文件 + `fsync` + `rename`），桌面环境永远读不到半截文件

### 健康检查（28 条规则）
对已有的 `.desktop` 做体检，按严重度分四级：

| 级别 | 例子 |
|---|---|
| 🔴 致命 | 缺少 `[Desktop Entry]` 组头、UTF-8 BOM、CRLF 行尾、编码非法字节 |
| 🔴 严重 | `Version=` 超范围、`Exec=` 未转义、`Exec=` 指向不存在的文件、`Type=` 错误、重复键、悬空 `Actions=` 引用 |
| 🟡 警告 | `Icon=` 丢失、缺 `Categories=`、缺 `StartupWMClass=`、`Terminal=true`、文件名不规范 |
| ⚪ 提示 | 缺 `GenericName=`、缺 `TryExec=`、未被本工具管理 |

### 修复（三级模式）
- **保守** — 只改明确坏掉的，已存在字段一个字节不动
- **补全** — 保守 + 补齐缺失的标准字段（只补，不覆盖）
- **重建** — 用 AppImage 元数据整体替换，自定义字段需逐条勾选保留

每个问题都显示「当前值 / 修复值」，改动前有 unified diff 预览。

### 反向管理
- 删除启动器（删除前自动备份）
- 编辑 `Name` / `Comment` / `Categories` / `Exec` / `Icon`
- **认领**：把第三方或手工创建的 `.desktop` 纳入管理，只追加 `X-AppImage-Manager-*` 标记键，原有内容不动
- **用内置元数据补全**：解包 AppImage，读它内置 `.desktop` 里的真实
  名称 / 描述 / 分类 / 图标，补全已有的启动器。只替换 AppImage 里
  确实写了的字段，且只重写值真的变了的那几行 —— 注释、空行、原始空格
  写法、`[Desktop Action …]` 附加组全部逐字节保留。写前先备份并记入
  事务，随时可从「修复历史」还原
- 失效与孤儿清理

### 保真原则

凡是改写用户 `.desktop` 的操作（认领、修复、补全），都只动**确认要改
的那几行**，其余逐字节保留：

- 注释和空行原样留下
- `Name = Foo` 这种带空格的非标准写法不会被「规范化」掉
- `[Desktop Action …]` 等附加组完整保留
- 幂等：同一个操作重复执行不会反复叠加内容

走「解析成键值再整体序列化」的老路会把这些全都吃掉 —— 认领一个精心
写好的启动器，结果注释没了、附加组整组消失，与「只追加两行标记」的
承诺直接矛盾。所以这类操作一律走字节级插入 / 行级最小改写。

### 事务与回滚
- 两阶段提交（WAL），每步操作可追溯
- 崩溃恢复：启动时检测未完成的事务，可一键回滚
- 追加式修复历史，任何时候都能还原
- 备份保留策略（默认 30 天 / 200 个事务）

---

## 界面

```
┌ 原生标题栏（由窗口管理器绘制）──────────────────────────────────────┐
├ 文件(F)  编辑(E)  视图(V)  工具(T)  帮助(H) ────────────────────────┤
├ [⟳ 重新扫描]  [🔍 搜索…]              3 个目录 · 12 个 AppImage … ──┤
├ 📁 ~/Applications ✕   📁 /opt/apps ✕            [+ 添加目录] ───────┤
├ [全部▾] ☐全选  已勾选 3 项 │ ⚡创建 🔧修复 🔗认领 🖼图标 🗑删除 ───────┤
├ 列表 ──────────────────────────────────────────────────────────────┤
│  ☐ │ 🖼 │ 名称 │ 大小 │ 状态 │ 路径                                 │
│                                                       ┌──────────┐ │
│                                                       │✎编辑 ▶测试│ │
│                                                       │📂目录 ⧉复制│ │
│                                                       └──────────┘ │
├ InfoBar ───────────────────────────────────────────────────────────┤
```

用**原生窗口标题栏**，不做自绘 —— 自绘标题栏在第三方 GTK 主题下容易把
最小化/最大化画成空白圆圈，交给窗口管理器就不会。

### 菜单

| 菜单 | 项目 |
|---|---|
| 文件 | 添加扫描目录 `Ctrl+D` · 打开启动器目录 · 打开配置目录 · 退出 `Ctrl+Q` |
| 编辑 | 全选 `Ctrl+A` · 取消选择 · 创建启动器 `Ctrl+N` · 修复选中项 · 认领 · 删除 `Delete` |
| 视图 | 重新扫描 `F5` · 过滤（全部/新发现/已创建/外部/失效/可优化） · 最大化 `F11` |
| 工具 | 健康检查 · 修复历史 · 失效与孤儿清理 · 用内置元数据补全所选启动器 · 设置 `Ctrl+,` |
| 帮助 | 键盘快捷键 `F1` · 关于 |

### 三种操作入口

| 入口 | 覆盖范围 | 何时出现 |
|---|---|---|
| **常驻操作条** | 批量（创建/修复/认领/图标/删除） | 永远可见 |
| **浮动操作条** | 单条（编辑/测试/打开目录/复制路径） | 选中行时 |
| **右键菜单** | 全部 8 项 | 右键任意行 |

目标选择规则：**勾选优先，无勾选时回退到行选中**。按钮按状态动态启用，
禁用时 tooltip 说明原因。

### 创建启动器

点「⚡ 创建」弹对话框，预填启发式信息后由你确认：

- **名称** 从文件名推导（`Obsidian-1.5.3-x86_64.AppImage` → `Obsidian`）
- **命令** 已按 XDG 规范转义
- **图标** 默认空，点「选择…」挑一个（会复制进图标缓存）
- **分类** 可编辑下拉，按关键词给建议（`krita` → `Graphics;`）
- 右侧**实时预览**最终写入的 `.desktop` 内容

批量时逐个弹，可以「跳过」单条或勾「之后都用默认值」一键过完。

**图标不自动提取，元数据不自动解包。** 主流程上是纯字符串操作，毫秒级
完成、不可能卡死。需要更完整的元数据时，点对话框里的
「尝试提取内置元数据」—— 它带 60 秒硬超时、可随时取消、失败会清理干净
并告诉你原因。

### 首次运行

没有弹窗向导。主窗口直接打开，显示空状态引导：

```
              还没有添加扫描目录
   添加一个目录，程序会扫描其中的 AppImage，
   并帮你创建规范的桌面启动器

        [ 添加目录… ]   [ 看看常见位置 ]
```

「看看常见位置」会列出 `~/Applications`、`~/apps` 等，可勾选并直接创建
不存在的目录。

### 快捷键

| 键 | 动作 | | 键 | 动作 |
|---|---|---|---|---|
| `F5` / `Ctrl+R` | 重新扫描 | | `Enter` | 创建 / 认领 / 编辑 |
| `Ctrl+A` | 全选 | | `Delete` | 删除选中的启动器 |
| `Ctrl+F` | 聚焦搜索 | | `F11` | 最大化 / 还原 |
| `Ctrl+N` | 创建启动器 | | `F1` | 快捷键说明 |
| `Ctrl+D` | 添加扫描目录 | | `Ctrl+Q` | 退出 |
| `Ctrl+,` | 设置 | | 双击条目 | 未创建→创建；已创建→编辑 |

窗口最小 **620 × 400**，窄窗口下操作条自动变横向滚动。

没有「全屏」—— 只有「最大化」。真全屏在 X11 下由窗口管理器负责撤掉
全部装饰，标题栏和最小化/最大化/关闭三个按钮会一起消失，用起来像是
按钮坏了。最大化占满屏幕但保留标题栏，那才是实际想要的效果。
双击标题栏、或按窗口管理器的快捷键（xfwm4 是 `Super+↑`）也能最大化，
菜单里的勾选会跟着同步。

---

## 编译

### 依赖

```bash
# Debian / Ubuntu / Kali
sudo apt install valac libgtk-3-dev libjson-glib-dev pkg-config

# Fedora
sudo dnf install vala gtk3-devel json-glib-devel pkgconfig

# Arch
sudo pacman -S vala gtk3 json-glib pkgconf
```

版本要求：Vala ≥ 0.48，GTK ≥ 3.24。

跑测试还需要（界面自动化用）：

```bash
sudo apt install desktop-file-utils xvfb xfwm4 xdotool imagemagick xclip
```

```bash
make selftest        # 240 项引擎自测，不依赖图形环境
tests/ui-test.sh     # 20 步界面自动化，需要上面那套工具
```

CI 上也是跑这两条 —— 缺工具时 `ui-test.sh` 会跳过并退 0，所以本地
没装全也不会误判为失败。

### 构建

```bash
make          # 产出 ./appimage-manager
make run      # 编译并运行
```

### 安装

```bash
sudo make install                  # 默认装到 /usr/local
make install PREFIX=$HOME/.local   # 或者装到用户目录
```

安装内容：
- `$PREFIX/bin/appimage-manager`
- `$PREFIX/share/applications/appimage-manager.desktop`
- `$PREFIX/share/icons/hicolor/256x256/apps/appimage-manager.png`

卸载：`sudo make uninstall`

### 免安装运行（打包成 AppImage）

```bash
make appimage
# → dist/AppImage-Manager-1.0.0-x86_64.AppImage   （约 496 KiB）
```

产出一个自包含的 AppImage，`chmod +x` 后双击即可运行，不需要安装到
任何系统目录。

体积只有几百 KB，是因为它**不打包 GTK**，运行时用系统的 GTK3 ——
所以目标机需要已装 GTK3（桌面发行版基本都有）。要完全自包含得把整个
GTK 栈打进去，体积会涨到 100 MB 以上，还要处理 glibc 版本兼容，
对这个工具不划算。

打包不需要联网，也不需要 `appimagetool`：脚本从本机已有的任意
type-2 AppImage 里取出运行时，配上系统自带的 `mksquashfs` 自己拼装。

运行时按以下顺序找，第一个可用的胜出：

1. `RUNTIME=/path/to/runtime` 环境变量
2. 仓库里的 `runtime/appimage-runtime-x86_64`（首次成功后缓存于此）
3. 从本机现成的 AppImage 里提取：`$APPMGR_RUNTIME_SOURCE`、然后
   `~/Desktop/audit/dl/*.AppImage`、然后 `/tmp/*.AppImage`

取运行时长度用的是 AppImage **自己报告的** `--appimage-offset`，不是
去文件里搜 `hsqs` 魔数 —— 运行时自己的代码里就含有那 4 个字节，直接搜
会命中假阳性，截出一个「能启动但 `--appimage-extract` 段错误」的残废
运行时。每个候选运行时都要通过「重建后自报偏移一致 + 解包退出码为 0」
的往返校验才会被采用。

`dist/` 和 `runtime/` 已在 `.gitignore` 里。

### 打成 deb / rpm / arch 包

```bash
# .desktop 里有 @PREFIX@ 占位符要替换，而 nfpm 不做替换，
# 所以先用 make install 把替换后的文件暂存到 build/pkg
make install DESTDIR=build/pkg PREFIX=/usr

cd packaging
/tmp/nfpm package --config nfpm.yaml --packager deb      --target ../dist
/tmp/nfpm package --config nfpm.yaml --packager rpm      --target ../dist
/tmp/nfpm package --config nfpm.yaml --packager archlinux --target ../dist
```

用 [nfpm](https://nfpm.goreleaser.com/) 而非 `debian/rules` + `.spec` +
`PKGBUILD` 三套文件：一处配置生成三种包，各系的依赖名不同（GTK3 在 deb
上叫 `libgtk-3-0`、新版还是 `libgtk-3-0t64`，rpm 与 arch 上叫 `gtk3`），
统一维护比三份文件可靠。

配置在 `packaging/nfpm.yaml`，改依赖只改那里。

---

## 文件位置

| 用途 | 路径 |
|---|---|
| 配置 | `~/.config/appimage-manager/config.ini` |
| 启动器（写入目标） | `~/.local/share/applications/` |
| 图标缓存 | `~/.local/share/icons/hicolor/<尺寸>/apps/` |
| 事务日志 | `~/.local/share/appimage-manager/journal/` |
| 备份与历史 | `~/.local/share/appimage-manager/history/` |
| 提取临时区 | `~/.cache/appimage-manager/extract/` |

启动器目录遵守 XDG 规范（`$XDG_DATA_HOME`），在菜单搜索顺序里**优先于** `/usr/share/applications`，所以用户级安装的启动器会覆盖系统级的同名条目。

---

## 项目结构

```
src/
├── main.vala           应用入口，Gtk.Application 装配
├── window.vala         主窗口：列表、目录条、浮动操作条、InfoBar
├── dialogs.vala        编辑器 / 修复 / 认领 / 清理 / 设置 / 历史 / 进度
├── menubar.vala        传统菜单栏
├── prefill.vala        从文件名 / AppImage 推导预填值
├── pill.vala           状态药丸的自定义渲染器
├── store.vala          数据模型，二维状态（匹配 × 健康）
├── config.vala         GKeyFile 配置持久化
├── scanner.vala        递归扫描 + 魔数校验
├── appimage.vala       --appimage-extract 元数据与图标提取
├── desktopfiles.vala   条目解析、Exec 转义、原子写、校验
├── rules.vala          28 条健康检查规则引擎
├── repair.vala         三级修复模式、diff 生成、字节级改写、事务化执行
├── journal.vala        WAL 两阶段事务、崩溃恢复
├── backup.vala         备份存储、追加式历史、还原
├── version.vala        版本号
└── paths.vala          XDG 路径解析、文件操作兼容层
data/
├── style.css           GTK3 样式表（主题自适应）
├── appimage-manager.png            应用图标
├── appimage-manager.desktop.in     安装版 .desktop 模板
└── appimage-manager-appimage.desktop.in   AppImage 内嵌版 .desktop 模板
scripts/
└── make-appimage.sh    离线打包成 AppImage（取运行时 + mksquashfs + 拼装）
tests/
├── selftest.vala       引擎自测（不依赖 GUI）
├── ui-test.sh          Xvfb + xdotool 的界面自动化测试
└── make-fixtures.sh    生成测试用假 AppImage 与 21 个畸形 .desktop
```

---

## 设计要点

**状态是二维的。** 「匹配状态」（新发现 / 已创建 / 外部 / 失效）和「健康状态」（健康 / 可优化 / 损坏）是正交的两个维度，所以状态药丸会同时反映两者。

**慢操作绝不阻塞 UI。** 图标提取要解包 AppImage（单个几十到几百 MB），放在后台线程池里跑，带可取消的进度条。`.desktop` 写入是毫秒级的，同步执行。

**事务边界压到最短。** 并发全部放在事务之前（图标提取），事务内只做纯文件操作。

**写入永远原子。** 临时文件 → `fsync` → `rename`。最坏情况是「部分文件已修、部分未修」，永远不会是「文件损坏」。

**任何自动修复都可逆。** 修复前备份原文件，历史是追加式的，还原本身也是一条新记录。

---

## 已知限制

- AppImage 的 `--appimage-extract` 需要文件有执行权限。**本工具绝不擅自
  改动你的 AppImage**：遇到没有执行位的文件会弹窗询问，默认选项是不
  改动文件。对 `/opt`、`/media` 下的文件可能需要管理员权限，届时加执行
  位会失败，会如实告知而不是假装成功
- 解包可能很慢（大 AppImage 要几十秒到几分钟），超时可配（默认 60 秒，
  范围 5–600），且随时可取消。取消或超时会强杀子进程，不留后台残留
- 图标提取和解包不支持加密或分段（`.part`）的 AppImage
- 不管理 `~/.local/share/applications` 之外的启动器目录；放在别处的
  启动器可以认领，但扫描不会看到它（认领时会就此询问）
- 打包出的 AppImage 依赖系统的 GTK3，不做 GTK 全量打包（详见「免安装
  运行」一节）

---

## 许可证

MIT
