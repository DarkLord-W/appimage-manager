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
        // 健康问题优先展示，因为用户更需要知道「哪里坏了」
        if (match == MatchState.BROKEN)
            return "失效";
        if (health == HealthState.CORRUPT)
            return "损坏";
        if (health == HealthState.IMPROVABLE)
            return "可优化 %d".printf (problems.length);
        if (match == MatchState.EXTERNAL)
            return "外部";
        if (match == MatchState.REGISTERED)
            return "已创建";
        return "新发现";
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

    /** 找出 Exec 指向不存在文件的条目 */
    private void detect_broken () {
        DesktopFiles.Entry[] broken = {};
        foreach (var d in all_desktop) {
            if (d.bound_appimage != null)
                continue;    // 已经关联上了
            if (d.exec_target == null || d.exec_target == "")
                continue;
            if (!d.exec_target.has_suffix (".appimage"))
                continue;
            // Exec 目标已消失 → 失效
            if (!AppPath.exists (d.exec_target))
                broken += d;
        }
        broken_entries = broken;
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