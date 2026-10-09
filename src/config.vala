/*
 * config.vala — 配置读写（~/.config/appimage-manager/config.ini）
 *
 * 使用 GLib.KeyFile，不引入额外依赖。
 */
public class AppConfig : GLib.Object {

    private GLib.KeyFile kf;
    private string path;

    // ── 默认值 ────────────────────────────────────────────────────
    public const int DEFAULT_ICON_SIZE = 256;
    public const int DEFAULT_RETENTION_DAYS = 30;
    public const int DEFAULT_RETENTION_TX = 200;

    public AppConfig () {
        path = AppPath.config_file ();
        kf = new GLib.KeyFile ();
        if (!load ())
            seed_defaults ();
    }

    private bool load () {
        try {
            kf.load_from_file (path, GLib.KeyFileFlags.KEEP_COMMENTS);
            return true;
        } catch {
            return false;
        }
    }

    /** 首次运行时铺一份默认配置，之后由用户修改 */
    private void seed_defaults () {
        ensure_core_dirs ();
        kf = new GLib.KeyFile ();

        set_bool ("general", "configured", false);
        set_int  ("general", "icon_size", DEFAULT_ICON_SIZE);
        set_bool ("scan", "recursive", true);
        set_bool ("scan", "auto_on_startup", false);
        set_bool ("scan", "ignore_system_dirs", true);

        set_bool ("icons", "custom_icon_dir", false);
        set_string ("icons", "custom_icon_dir_path", "");

        set_bool ("sync", "update_desktop_database", true);
        set_bool ("sync", "update_icon_cache", true);
        set_bool ("sync", "write_managed_marker", true);
        set_bool ("sync", "delete_icon_with_launcher", false);

        set_bool ("repair", "confirm_destructive", true);
        set_int  ("repair", "parallel_extraction", 4);
        set_int  ("repair", "batch_failure_policy", 0); // 0=回滚中止 1=跳过继续

        set_int  ("backup", "retention_days", DEFAULT_RETENTION_DAYS);
        set_int  ("backup", "retention_tx", DEFAULT_RETENTION_TX);
        set_bool ("backup", "enabled", true);

        save ();
    }

    /** 应用需要的基础目录，首次启动时创建 */
    public static void ensure_core_dirs () {
        AppPath.ensure_dir (AppPath.config_dir ());
        AppPath.ensure_dir (AppPath.applications_dir ());
        AppPath.ensure_dir (AppPath.icons_hicolor_dir ());
        AppPath.ensure_dir (AppPath.data_root ());
    }

    // ── 扫描目录 ──────────────────────────────────────────────────

    /** 读所有扫描目录，去重且保留顺序 */
    public string[] scan_dirs () {
        string[] out = {};
        if (!has_key ("scan", "dirs"))
            return out;

        string raw = get_string ("scan", "dirs", "");
        foreach (string d in raw.split (":")) {
            string t = AppPath.canonical (d.strip ());
            if (t != "")
                out += t;
        }
        return out;
    }

    public void set_scan_dirs (string[] dirs) {
        var uniq = new GenericArray<string> ();
        var seen = new GenericArray<string> ();
        foreach (string d in dirs) {
            string t = AppPath.canonical (d);
            if (t == "" || seen.contains (t))
                continue;
            seen.add (t);
            uniq.add (t);
        }
        set_string ("scan", "dirs", string.joinv (":", uniq.to_array ()));
    }

    public void add_scan_dir (string dir) {
        string t = AppPath.canonical (dir);
        if (t == "")
            return;
        var cur = new GenericArray<string> ();
        foreach (string d in scan_dirs ())
            cur.add (d);
        if (!cur.contains (t))
            cur.add (t);
        set_scan_dirs ((owned) cur.to_array ());
    }

    public void remove_scan_dir (string dir) {
        string t = AppPath.canonical (dir);
        var cur = new GenericArray<string> ();
        foreach (string d in scan_dirs ())
            if (d != t)
                cur.add (d);
        set_scan_dirs ((owned) cur.to_array ());
    }

    // ── 通用存取 ──────────────────────────────────────────────────

    private bool has_key (string group, string key) {
        try {
            kf.has_key (group, key);
            return true;
        } catch {
            return false;
        }
    }

    public bool get_bool (string group, string key, bool fallback) {
        try {
            return kf.get_boolean (group, key);
        } catch {
            return fallback;
        }
    }

    public int get_int (string group, string key, int fallback) {
        try {
            return kf.get_integer (group, key);
        } catch {
            return fallback;
        }
    }

    public string get_string (string group, string key, string fallback) {
        try {
            return kf.get_string (group, key);
        } catch {
            return fallback;
        }
    }

    public void set_bool (string group, string key, bool value) {
        kf.set_boolean (group, key, value);
    }

    public void set_int (string group, string key, int value) {
        kf.set_integer (group, key, value);
    }

    public void set_string (string group, string key, string value) {
        kf.set_string (group, key, value);
    }

    // ── 快捷访问 ──────────────────────────────────────────────────

    public bool is_configured () { return get_bool ("general", "configured", false); }
    public void mark_configured () { set_bool ("general", "configured", true); }

    public int icon_size () {
        int s = get_int ("general", "icon_size", DEFAULT_ICON_SIZE);
        if (s != 128 && s != 256 && s != 512)
            s = DEFAULT_ICON_SIZE;
        return s;
    }

    public bool recursive () { return get_bool ("scan", "recursive", true); }
    public bool auto_on_startup () { return get_bool ("scan", "auto_on_startup", false); }

    public string icon_dir () {
        if (get_bool ("icons", "custom_icon_dir", false)) {
            string p = get_string ("icons", "custom_icon_dir_path", "");
            if (p != "")
                return p;
        }
        return GLib.build_filename (AppPath.icons_hicolor_dir (), "%d" + icon_size (), "apps");
    }

    public string cached_icon_path (string slug, string ext) {
        return GLib.build_filename (icon_dir (), "%s.%s".printf (slug, ext));
    }

    public bool should_update_database () { return get_bool ("sync", "update_desktop_database", true); }
    public bool should_update_icon_cache () { return get_bool ("sync", "update_icon_cache", true); }
    public bool write_marker () { return get_bool ("sync", "write_managed_marker", true); }
    public bool delete_icon_with_launcher () { return get_bool ("sync", "delete_icon_with_launcher", false); }

    public int extraction_threads () {
        int n = get_int ("repair", "parallel_extraction", 4);
        if (n < 1) n = 1;
        if (n > 16) n = 16;
        return n;
    }

    public bool rollback_on_failure () {
        return get_int ("repair", "batch_failure_policy", 0) == 0;
    }

    public bool backup_enabled () { return get_bool ("backup", "enabled", true); }

    public int retention_days () { return get_int ("backup", "retention_days", DEFAULT_RETENTION_DAYS); }
    public int retention_tx () { return get_int ("backup", "retention_tx", DEFAULT_RETENTION_TX); }

    // ── 持久化 ────────────────────────────────────────────────────

    public void save () {
        AppPath.ensure_dir (AppPath.config_dir ());
        try {
            string data = kf.to_data ();
            // 原子写，避免读到半截配置
            string tmp = "%s.tmp%u".printf (path, GLib.get_real_time () % 1000000);
            GLib.FileUtils.set_contents (tmp, data);
            GLib.FileUtils.rename (tmp, path);
        } catch (GLib.Error e) {
            warning ("配置保存失败: %s", e.message);
        }
    }
}