/*
 * store.vala — 数据模型
 *
 * AppEntry 把「扫描到的 AppImage」和「已存在的 .desktop」关联起来，
 * 并计算二维状态（匹配状态 × 健康状态）。
 */
public enum MatchState {
    NEW,          // 未匹配：新发现
    REGISTERED,   // 已匹配，且由本工具管理
    EXTERNAL,     // 已匹配，但不是本工具创建
    BROKEN        // 已匹配，但 AppImage 文件已消失
}

public enum HealthState {
    UNKNOWN,
    HEALTHY,      // 无问题
    IMPROVABLE,   // 可优化（有可修复项）
    CORRUPT       // 损坏（有致命项）
}

public enum FixMode {
    CONSERVATIVE,   // 保守：只改明确坏掉的
    ENRICH,         // 补全：保守 + 补齐缺失字段
    REBUILD         // 重建：整体替换，自定义字段需逐条勾选
}

public class AppEntry : GLib.Object {
    // ── AppImage 侧 ──────────────────────────────────────────────
    public string path = "";             // AppImage 绝对路径
    public string basename = "";
    public string display_name = "";     // 展示名
    public uint64 size = 0;
    public int64 mtime = 0;

    // ── 元数据（来自 AppImage 内部）──────────────────────────────
    public string meta_name = "";
    public string generic_name = "";
    public string comment = "";
    public string categories = "";
    public string startup_wm_class = "";
    public string mimetype = "";

    // ── 图标 ─────────────────────────────────────────────────────
    public string? icon_path = null;     // 缓存中的图标绝对路径
    public bool   icon_extracted = false;

    // ── 桌面条目侧 ───────────────────────────────────────────────
    public DesktopFiles.Entry? entry = null;
    public MatchState match = MatchState.NEW;
    public HealthState health = HealthState.UNKNOWN;

    // ── 健康检查结果 ─────────────────────────────────────────────
    public RuleSet.Problem[] problems = {};
    public string validate_error = "";

    // ── UI 辅助 ──────────────────────────────────────────────────
    public string? row_icon = null;      // 供 TreeView 用的小尺寸缓存

    public AppEntry (string path) {
        this.path = AppPath.canonical (path);
        this.basename = GLib.Path.get_basename (path);
        this.display_name = AppPath.display_name_from_file (basename);
        this.meta_name = display_name;
    }

    public string get_best_name () {
        if (entry != null && entry.name != "")
            return entry.name;
        if (meta_name != "")
            return meta_name;
        return display_name;
    }

    public string get_slug () {
        return AppPath.slugify (basename);
    }

    public string get_icon_display () {
        if (icon_path != null && AppPath.exists (icon_path))
            return icon_path;
        return "";
    }

    public bool is_actionable () {
        return match != MatchState.BROKEN;
    }

    public string get_status_text () {
        if (match == MatchState.BROKEN)
            return I18n.s ("失效");

        // 「外部创建」优先于健康度展示。
        //
        // 理由：它是最需要用户动作的状态 —— 条目还没纳入管理，修复和
        // 失效检测都用不上，用户该做的是「认领」。之前健康度把它盖住了，
        // 一个有问题但未被管理的外部条目会显示成「可优化 N」，用户根本
        // 看不出它其实可以认领（这正是「认领好像没做」的观感来源）。
        // 有问题就把数量附在后面，两个信息都不丢。
        if (match == MatchState.EXTERNAL)
            return problems.length > 0
                ? I18n.s ("外部 · %d").printf (problems.length)
                : I18n.s ("外部");

        // 已纳入管理的条目，健康度才是首要信息
        if (health == HealthState.CORRUPT)
            return I18n.s ("损坏");
        if (health == HealthState.IMPROVABLE)
            return I18n.s ("可优化 %d").printf (problems.length);
        if (match == MatchState.REGISTERED)
            return I18n.s ("已创建");
        return I18n.s ("新发现");
    }

    public Gdk.Pixbuf? get_thumbnail (int size) {
        if (icon_path != null && AppPath.exists (icon_path)) {
            try {
                return new Gdk.Pixbuf.from_file_at_scale (icon_path, size, size, true);
            } catch {}
        }
        return null;
    }
}

public class Store : GLib.Object {

    /* ── 过滤判定（纯函数，可独立测试）────────────────────────────
     *
     * 刻意放在这里而不是界面里：界面那段曾经往 4 字节的枚举里读
     * 8 字节的对象指针，破坏栈，一选过滤器就崩。判定逻辑与取值
     * 分离之后，界面只剩「取 AppEntry → 调这个」，没有类型转换的
     * 空间，而且全部路径都能被自测覆盖。
     */

    /** filter_mode: 0=全部 1=新发现 2=已创建 3=外部 4=失效 5=可优化 */
    public static bool matches_filter (AppEntry e, int filter_mode,
                                       string query = "") {
        if (e == null)
            return false;

        // 状态过滤
        switch (filter_mode) {
            case 0: break;   // 全部
            case 1:
                if (e.match != MatchState.NEW) return false; break;
            case 2:
                if (e.match != MatchState.REGISTERED) return false; break;
            case 3:
                if (e.match != MatchState.EXTERNAL) return false; break;
            case 4:
                if (e.match != MatchState.BROKEN) return false; break;
            case 5:
                if (e.health != HealthState.IMPROVABLE
                 && e.health != HealthState.CORRUPT) return false;
                break;
            default:
                break;   // 未知模式当「全部」，宁可多显示不可全空
        }

        // 搜索：名称 / 文件名 / 完整路径，大小写不敏感
        string q = query.strip ().down ();
        if (q != "") {
            if (!e.get_best_name ().down ().contains (q)
                && !e.basename.down ().contains (q)
                && !e.path.down ().contains (q))
                return false;
        }

        return true;
    }

    public GLib.List<AppEntry> entries;
    public AppConfig config;

    private GLib.List<DesktopFiles.Entry> all_desktop;
    public DesktopFiles.Entry[] broken_entries = {};

    public signal void changed ();

    construct {
        entries = new GLib.List<AppEntry> ();
        all_desktop = new GLib.List<DesktopFiles.Entry> ();
        broken_entries = {};
    }

    public Store (AppConfig cfg) {
        config = cfg;
    }

    /** 清空并重新扫描 */
    public void rescan () {
        entries = new GLib.List<AppEntry> ();
        all_desktop = new GLib.List<DesktopFiles.Entry> ();

        // 1) 扫描 AppImage
        string[] dirs = config.scan_dirs ();
        var result = Scanner.scan (dirs, config.recursive ());

        foreach (string p in result.found) {
            var e = new AppEntry (p);

            var info = AppPath.file_lstat (p);
            if (info != null) {
                e.size = (uint64) info.get_size ();
                e.mtime = (int64) info.get_attribute_uint64 ("time::modified");
            }

            // 缓存图标命中则直接挂上，不用解包
            string slug = e.get_slug ();
            string[] icon_exts = { "png", "svg", "xpm" };
            foreach (string ext in icon_exts) {
                string cand = config.cached_icon_path (slug, ext);
                if (AppPath.exists (cand)) {
                    e.icon_path = cand;
                    e.icon_extracted = true;
                    break;
                }
            }
            entries.append (e);
        }

        // 2) 扫描已有 .desktop
        string apps_dir = AppPath.applications_dir ();
        if (AppPath.is_dir (apps_dir)) {
            foreach (var de in DesktopFiles.scan_directory (apps_dir))
                all_desktop.append (de);
        }

        // 3) 关联
        match_entries ();

        // 4) 健康检查
        health_check ();

        changed ();
    }

    /** 把每个 AppImage 与对应的 .desktop 条目关联 */
    private void match_entries () {
        // 正向索引：appimage 路径 → entry
        var by_marker = new GLib.HashTable<string, DesktopFiles.Entry> (GLib.str_hash, GLib.str_equal);
        var by_exec = new GLib.HashTable<string, DesktopFiles.Entry> (GLib.str_hash, GLib.str_equal);

        foreach (var d in all_desktop) {
            if (d.marker_path != "" && !by_marker.contains (d.marker_path))
                by_marker.insert (d.marker_path, d);
            if (d.exec_target != null && d.exec_target != "" && !by_exec.contains (d.exec_target))
                by_exec.insert (d.exec_target, d);
        }

        foreach (var e in entries) {
            DesktopFiles.Entry? found = null;

            if (by_marker.contains (e.path))
                found = by_marker.lookup (e.path);
            else if (by_exec.contains (e.path))
                found = by_exec.lookup (e.path);

            if (found == null) {
                e.match = MatchState.NEW;
                e.entry = null;
                continue;
            }

            e.entry = found;
            found.bound_appimage = e.path;
            e.match = found.is_managed ? MatchState.REGISTERED : MatchState.EXTERNAL;
        }
    }

    /** 对所有已关联的条目跑健康检查 */
    private void health_check () {
        foreach (var e in entries) {
            if (e.entry == null) {
                e.health = HealthState.UNKNOWN;
                e.problems = {};
                continue;
            }
            var rs = RuleSet.check (e.entry, e);
            e.problems = rs.problems;
            e.validate_error = DesktopFiles.validate_file (e.entry.file_path);

            if (rs.fatal_count > 0)
                e.health = HealthState.CORRUPT;
            else if (rs.problems.length > 0)
                e.health = HealthState.IMPROVABLE;
            else
                e.health = HealthState.HEALTHY;
        }

        // 反向：已删除 AppImage 的条目 → 失效
        detect_broken ();
    }

    /**
     * 找出 Exec 指向不存在文件的启动器，并把它们也放进列表。
     *
     * 原先只把结果塞进 broken_entries，列表里一份都没有 —— 于是「失效」
     * 这个过滤器永远是空的，用户点进去看到一片空白，也没有任何解释。
     * window.vala 里本来就有 MatchState.BROKEN 的分支（统计、操作条状态），
     * 说明设计上它们本就该出现在列表里，只是这一步没接上。
     */
    private void detect_broken () {
        DesktopFiles.Entry[] broken = {};
        foreach (var d in all_desktop) {
            if (d.bound_appimage != null)
                continue;    // 已经关联上了

            if (d.exec_target == null || d.exec_target == "")
                continue;

            // 扩展名比较要大小写不敏感。scanner 那边用 down() 统一过，
            // 这里原先却硬比 ".appimage"，于是 Foo.APPIMAGE 这种全大写的
            // 启动器失效了也认不出来 —— 夹具里就有这么一个用例。
            bool looks_like_appimage =
                d.exec_target.down ().has_suffix (".appimage");

            // 带本工具标记键的启动器一定是我们的，不管 Exec 写成什么，
            // 只要目标没了就算失效。
            if (!looks_like_appimage && !d.is_managed)
                continue;

            // Exec 目标已消失 → 失效
            if (AppPath.exists (d.exec_target))
                continue;

            broken += d;
        }
        broken_entries = broken;

        // 把它们也放进列表，让「失效」过滤器有东西可显示。
        // 注意这些条目没有对应的 AppImage 文件：size 为 0，缩略图为 null，
        // 界面按 match == BROKEN 分支处理。
        foreach (var d in broken) {
            var e = new AppEntry (d.exec_target);
            e.match = MatchState.BROKEN;
            e.entry = d;
            e.size = 0;
            e.health = HealthState.UNKNOWN;
            if (d.name != "")
                e.meta_name = d.name;
            entries.append (e);
        }
    }

    /* ── 查询辅助 ────────────────────────────────────────────────── */

    public AppEntry? find_by_path (string path) {
        string c = AppPath.canonical (path);
        foreach (var e in entries)
            if (e.path == c)
                return e;
        return null;
    }

    public int count (MatchState m) {
        int n = 0;
        foreach (var e in entries)
            if (e.match == m)
                n++;
        return n;
    }

    public int count_problems () {
        int n = 0;
        foreach (var e in entries)
            n += e.problems.length;
        return n;
    }

    /** 所有与 AppImage 无关的 .desktop */
    public int count_unrelated () {
        int n = 0;
        foreach (var d in all_desktop)
            if (d.bound_appimage == null && !d.is_managed)
                n++;
        return n;
    }
}