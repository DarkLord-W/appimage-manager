# AppImage Manager

一个用 **Vala + GTK3** 写的 AppImage 桌面集成管理器。扫描你指定的目录，把 AppImage 变成规范的 `.desktop` 启动器，并持续维护它们的健康状态。

编译产物是**单个原生二进制**，拷到任何装了 GTK3 的 Linux 上都能直接跑。

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
- 失效与孤儿清理

### 事务与回滚
- 两阶段提交（WAL），每步操作可追溯
- 崩溃恢复：启动时检测未完成的事务，可一键回滚
- 追加式修复历史，任何时候都能还原
- 备份保留策略（默认 30 天 / 200 个事务）

---

## 界面

```
┌ HeaderBar ───────────────────────────────────────────────────────────┐
│ ☰  AppImage Manager                   [🔍 搜索…] [⟳]        ─ □ ✕    │
│    3 个目录 · 12 个 AppImage · 5 个待创建                             │
├ 目录条 ──────────────────────────────────────────────────────────────┤
│ 📁 ~/Applications ✕   📁 /opt/appimages ✕       [+ 添加目录]        │
├ 操作条【常驻 · 批量】───────────────────────────────────────────────┤
│ [全部▾]  ☐全选  已勾选 3 项  │ ⚡创建 🔧修复 🔗认领 🖼图标 🗑删除     │
├ 列表 ────────────────────────────────────────────────────────────────┤
│  ☐ │ 🎨 │ 名称      │ 大小   │ 状态     │ 路径                      │
│  ☑ │ 🎨 │ Krita     │ 291 MB │ ●新发现  │ /opt/appimages/krita…     │
│                                              ┌────────────────────┐ │
│                                              │选中 1│✎编辑 ▶测试  │ │
│                                              │ 📂目录 ⧉复制路径   │ │
│                                              └────────────────────┘ │
├ InfoBar ─────────────────────────────────────────────────────────────┤
```

### 三种操作入口

| 入口 | 覆盖范围 | 何时出现 |
|---|---|---|
| **常驻操作条** | 批量（创建/修复/认领/图标/删除） | 永远可见 |
| **浮动操作条** | 单条（编辑/测试/打开目录/复制路径） | 选中行时 |
| **右键菜单** | 全部 8 项 | 右键任意行 |

### 目标选择规则

**勾选优先，无勾选时回退到行选中。** 两种习惯都能用：

- 想批量处理 → 勾选若干行（或点「全选」）→ 点常驻操作条
- 想处理单条 → 点一行 → 用浮动操作条或右键菜单

按钮按目标状态动态启用/禁用，禁用的按钮 **tooltip 会说明原因**（例如「勾选的条目都已经有启动器了」）。

### 快捷键

| 键 | 动作 | | 键 | 动作 |
|---|---|---|---|---|
| `Ctrl+R` / `F5` | 重新扫描 | | `Enter` | 创建 / 认领 / 编辑（按状态） |
| `Ctrl+A` | 全选 | | `Delete` | 删除选中的启动器 |
| `Ctrl+F` | 聚焦搜索框 | | `Esc` | 关闭 InfoBar |
| `Ctrl+,` | 设置 | | 双击 | 未创建 → 创建；已创建 → 编辑 |

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

### 构建

```bash
make          # 产出 ./appimage-manager
make run      # 编译并运行
```

### 安装

```bash
sudo make install              # 默认装到 /usr/local
make install PREFIX=$HOME/.local   # 或者装到用户目录
```

安装内容：
- `$PREFIX/bin/appimage-manager`
- `$PREFIX/share/applications/appimage-manager.desktop`
- `$PREFIX/share/icons/hicolor/256x256/apps/appimage-manager.png`

卸载：`sudo make uninstall`

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
├── wizard.vala         首次运行向导
├── pill.vala           状态药丸的自定义渲染器
├── store.vala          数据模型，二维状态（匹配 × 健康）
├── config.vala         GKeyFile 配置持久化
├── scanner.vala        递归扫描 + 魔数校验
├── appimage.vala       --appimage-extract 元数据与图标提取
├── desktopfiles.vala   条目解析、Exec 转义、原子写、校验
├── rules.vala          28 条健康检查规则引擎
├── repair.vala         三级修复模式、diff 生成、事务化执行
├── journal.vala        WAL 两阶段事务、崩溃恢复
├── backup.vala         备份存储、追加式历史、还原
└── paths.vala          XDG 路径解析、文件操作兼容层
data/
├── style.css           GTK3 样式表（主题自适应）
└── appimage-manager.desktop.in
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

- AppImage 的 `--appimage-extract` 需要文件有执行权限；本工具会自动 `chmod +x`，但对 `/opt`、`/media` 下的文件可能需要管理员权限，届时会跳过并提示
- 图标提取和解包不支持加密或分段（`.part`）的 AppImage
- 不管理 `~/.local/share/applications` 之外的启动器目录

---

## 许可证

MIT
