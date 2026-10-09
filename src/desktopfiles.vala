/*
 * desktopfiles.vala — .desktop 条目的解析、匹配、生成与删除
 *
 * 这里是本工具与 XDG 启动器体系交互的核心。
 */
namespace DesktopFiles {

    /* ── 标记键 ──────────────────────────────────────────────────── */

    public const string MARKER_BOOL = "X-AppImage-Manager";
    public const string MARKER_PATH = "X-AppImage-Manager-Path";
    public const string MARKER_VERSION = "X-AppImage-Manager-Version";

    /* ── Exec 字段解析 ───────────────────────────────────────────── */

    /**
     * 从 Exec= 中抽取实际可执行文件的路径。
     *
     * 需要处理：
     *   - sh -c "foo" / bash wrapper.sh  → 递归取脚本路径
     *   - 双引号包裹 → 反转义
     *   - 字段码 %f %U %i %c %k %d %n %v %m → 剥除
     *   - ~ 展开、realpath 规范化
     */
    public string? extract_exec_path (string exec_line) {
        if (exec_line == null)
            return null;

        string s = exec_line.strip ();
        if (s == "")
            return null;

        // 剥掉字段码（字面 %% 表示一个真正的 %）
        var sb = new GLib.StringBuilder ();
        for (int i = 0; i < s.length; i++) {
            if (s[i] == '%' && i + 1 < s.length) {
                if (s[i + 1] == '%') {
                    sb.append_c ('%');
                    i++;
                    continue;
                }
                // 字段码：跳过 % 及其后一个字符
                i++;
                continue;
            }
            sb.append_c (s[i]);
        }
        s = sb.str.strip ();
        if (s == "")
            return null;

        // 取引号包裹的整段
        if (s.has_prefix ("\"")) {
            int close = s.index_of_char ('"', 1);
            if (close > 0) {
                s = s.substring (1, close - 1);
                s = s.replace ("\\\"", "\"").replace ("\\\\", "\\")
                     .replace ("\\$", "$").replace ("\\`", "`");
            } else {
                s = s.substring (1);
            }
        } else {
            // 未加引号：按空白切分取第一段
            int sp = s.index_of_char (' ');
            if (sp > 0)
                s = s.substring (0, sp);
        }

        s = s.strip ();
        if (s == "")
            return null;

        return AppPath.canonical (s);
    }

    /** 把任意路径转成合法的 Exec 参数（引号 + 转义 + %% 字面量） */
    public string build_exec_arg (string path) {
        string s = path
            .replace ("\\", "\\\\")
            .replace ("\"", "\\\"")
            .replace ("$", "\\$")
            .replace ("`", "\\`")
            .replace ("%", "%%");
        return "\"" + s + "\"";
    }

    /** 检测 Exec 是否指向包装脚本而非 AppImage 本体 */
    public bool exec_is_wrapper (string exec_line) {
        if (exec_line == null)
            return false;
        string s = exec_line.strip ().down ();
        string[] wrappers = { "sh ", "bash ", "dash ", "zsh ", "python", "perl ", "env " };
        if (s.has_prefix ("/bin/") || s.has_prefix ("/usr/bin/")) {
            int sp = s.last_index_of_char ('/');
            if (sp >= 0) {
                string bin = s.substring (sp + 1);
                string[] names = { "sh", "bash", "dash", "zsh", "python", "python3", "perl", "env" };
                foreach (string n in names)
                    if (bin.has_prefix (n))
                        return true;
            }
        }
        foreach (string w in wrappers)
            if (s.has_prefix (w))
                return true;
        return false;
    }

    /* ── 条目模型 ────────────────────────────────────────────────── */

    public class Entry : GLib.Object {
        public string file_path;          // .desktop 的绝对路径
        public string basename;
        public bool   parse_ok = false;   // 能否被 GKeyFile 解析
        public string parse_error = "";

        public string name = "";
        public string generic_name = "";
        public string comment = "";
        public string exec_line = "";
        public string try_exec = "";
        public string icon = "";
        public string categories = "";
        public string terminal = "";
        public string startup_wm_class = "";
        public string type = "";
        public string version = "";
        public string no_display = "";
        public string hidden = "";
        public string actions = "";

        public string marker_path = "";   // X-AppImage-Manager-Path
        public bool   is_managed = false; // 带标记

        public string? exec_target = null;// 从 Exec 解析出的可执行路径

        /** 本条目关联到的 AppImage 绝对路径，由 store 填充 */
        public string? bound_appimage = null;

        public bool has_group () { return group_names.length > 0; }

        /* vapi 里 Array/ManagedArray 均无 contains()，只能手写遍历 */
        public bool has_group_named (string name) {
            var arr = group_names.data;
            for (int i = 0; i < arr.length; i++) {
                if (arr[i] == name)
                    return true;
            }
            return false;
        }

        public GLib.Array<string> group_names;

        construct {
            group_names = new GLib.Array<string> ();
        }
    }

    /**
     * 解析单个 .desktop 文件。
     *
     * 注意：BOM / CRLF / 非法编码会导致 GKeyFile 直接抛错，
     * 这类文件必须由 rules.vala 先做字节级预处理才能读到内容。
     */
    public Entry? parse (string path) {
        var e = new Entry ();
        e.file_path = path;
        e.basename = GLib.Path.get_basename (path);

        string data;
        try {
            GLib.FileUtils.get_contents (path, out data);
        } catch (GLib.Error err) {
            e.parse_error = err.message;
            return e;
        }

        var kf = new GLib.KeyFile ();
        try {
            kf.load_from_data (data, data.length, GLib.KeyFileFlags.KEEP_COMMENTS);
            e.parse_ok = true;
        } catch (GLib.Error err) {
            e.parse_error = err.message;
            return e;
        }

        string grp = "Desktop Entry";
        e.name              = get_or (kf, grp, "Name", "");
        e.generic_name      = get_or (kf, grp, "GenericName", "");
        e.comment           = get_or (kf, grp, "Comment", "");
        e.exec_line         = get_or (kf, grp, "Exec", "");
        e.try_exec          = get_or (kf, grp, "TryExec", "");
        e.icon              = get_or (kf, grp, "Icon", "");
        e.categories        = get_or (kf, grp, "Categories", "");
        e.terminal          = get_or (kf, grp, "Terminal", "");
        e.startup_wm_class  = get_or (kf, grp, "StartupWMClass", "");
        e.type              = get_or (kf, grp, "Type", "");
        e.version           = get_or (kf, grp, "Version", "");
        e.no_display        = get_or (kf, grp, "NoDisplay", "");
        e.hidden            = get_or (kf, grp, "Hidden", "");
        e.actions           = get_or (kf, grp, "Actions", "");
        e.marker_path       = get_or (kf, grp, MARKER_PATH, "");

        e.is_managed = (get_or (kf, grp, MARKER_BOOL, "") == "true")
                    || e.marker_path != "";

        e.exec_target = extract_exec_path (e.exec_line);

        // 记录存在的所有组名，供规则引擎判断悬空 Actions 引用
        try {
            foreach (string g in kf.get_groups ())
                e.group_names.append_val (g);
        } catch {}

        return e;
    }

    private string get_or (GLib.KeyFile kf, string grp, string key, string fallback) {
        try {
            return kf.get_string (grp, key);
        } catch {
            return fallback;
        }
    }

    /* ── 目录扫描与反向映射 ──────────────────────────────────────── */

    /** 扫描 applications 目录下所有 .desktop 文件 */
    public Entry[] scan_directory (string dir) {
        var list = new GenericArray<Entry> ();

        try {
            var de = GLib.Dir.open (dir, 0);
            string? name;
            while ((name = de.read_name ()) != null) {
                if (!name.has_suffix (".desktop"))
                    continue;
                string full = GLib.Path.build_filename (dir, name);
                if (!GLib.FileUtils.test (full, GLib.FileTest.IS_REGULAR))
                    continue;
                var e = parse (full);
                if (e != null)
                    list.add (e);
            }
        } catch {
            return list.steal ();
        }

        // 排序保证 UI 顺序稳定
        list.sort ((x, y) => strcmp (x.basename, y.basename));
        return list.steal ();
    }

    /**
     * 建立 AppImage 路径 → 条目 的反向索引，用于匹配。
     * 同时也索引 MARKER_PATH，优先使用。
     */
    public GLib.HashTable<string, Entry>? build_index (Entry[] entries) {
        var map = new GLib.HashTable<string, Entry> (GLib.str_hash, GLib.str_equal);
        foreach (var e in entries) {
            if (e.marker_path != "" && !map.contains (e.marker_path)) {
                e.bound_appimage = e.marker_path;
                map.insert (e.marker_path, e);
                continue;
            }
            if (e.exec_target != null && e.exec_target != "" && !map.contains (e.exec_target)) {
                e.bound_appimage = e.exec_target;
                map.insert (e.exec_target, e);
            }
        }
        return map;
    }

    /** 找到目标 slug 已占用的文件名，返回可用的新名 */
    public string unique_desktop_name (string slug, Entry[] existing, string exclude_path) {
        string name0 = "%s.desktop".printf (slug);
        var taken = new GenericArray<string> ();
        foreach (var e in existing) {
            if (e.file_path == exclude_path)
                continue;
            taken.add (e.basename);
        }

        if (!taken_has (taken, name0))
            return name0;

        for (int i = 2; i <= 50; i++) {
            string candidate = "%s-%d.desktop".printf (slug, i);
            if (!taken_has (taken, candidate))
                return candidate;
        }
        // 兜底：路径哈希
        string h = "%08x".printf (AppPath.canonical (exclude_path).hash ());
        return "%s-%s.desktop".printf (slug, h.substring (h.length - 8));
    }

    private static bool taken_has (GenericArray<string> taken, string name) {
        for (int i = 0; i < taken.length; i++) {
            if (taken.get ((uint) i) == name)
                return true;
        }
        return false;
    }

    /* ── 生成 ────────────────────────────────────────────────────── */

    /** 从 AppImage 元数据组装 .desktop 内容 */
    public string build_content (string path,
                                 string name,
                                 string generic_name,
                                 string comment,
                                 string icon_path,
                                 string categories,
                                 string startup_wm_class,
                                 string mimetype,
                                 bool write_marker,
                                 string field_code) {

        var sb = new GLib.StringBuilder ();
        sb.append ("[Desktop Entry]\n");
        sb.append ("Type=Application\n");
        sb.append ("Version=1.5\n");
        sb.append ("Name=%s\n".printf (escape_value (name)));

        if (generic_name != "")
            sb.append ("GenericName=%s\n".printf (escape_value (generic_name)));
        if (comment != "")
            sb.append ("Comment=%s\n".printf (escape_value (comment)));

        string exec = build_exec_arg (path);
        if (field_code != "")
            exec += " " + field_code;
        sb.append ("Exec=%s\n".printf (exec));
        sb.append ("TryExec=%s\n".printf (path));

        if (icon_path != "")
            sb.append ("Icon=%s\n".printf (icon_path));

        sb.append ("Terminal=false\n");
        sb.append ("StartupNotify=true\n");

        if (startup_wm_class != "")
            sb.append ("StartupWMClass=%s\n".printf (escape_value (startup_wm_class)));
        if (categories != "")
            sb.append ("Categories=%s\n".printf (categories));
        if (mimetype != "")
            sb.append ("MimeType=%s\n".printf (mimetype));

        if (write_marker) {
            sb.append ("%s=true\n".printf (MARKER_BOOL));
            sb.append ("%s=%s\n".printf (MARKER_PATH, path));
            sb.append ("%s=%s\n".printf (MARKER_VERSION, APPMGR_VERSION));
        }

        return sb.str;
    }

    /** desktop 文件的值字段转义：反斜杠、换行、分号（列表值） */
    private string escape_value (string v) {
        return v
            .replace ("\\", "\\\\")
            .replace ("\n", "\\n")
            .replace (";", "\\;");
    }

    /* ── 写入（原子）──────────────────────────────────────────────── */

    /**
     * 原子写入：先写临时文件 + fsync，再 rename。
     * 保证桌面环境永远读不到半截文件。
     */
    public static void write_atomic (string path, string content, out string? error) {
        error = null;
        string tmp = "%s.tmp%u".printf (path, (uint) (GLib.get_real_time () % 1000000));
        try {
            // 先落临时文件，再 rename —— 同分区上 rename 是原子操作
            GLib.FileUtils.set_contents (tmp, content);
        } catch (GLib.Error e) {
            error = "写入临时文件失败: %s".printf (e.message);
            return;
        }

        if (GLib.FileUtils.rename (tmp, path) != 0) {
            AppPath.file_remove (tmp);
            error = "重命名失败: %s → %s".printf (AppPath.shorten (tmp), AppPath.shorten (path));
            return;
        }
        sync_dir (GLib.Path.get_dirname (path));
    }

    /**
     * 目录项 fsync，确保 rename 落盘。
     * 发行版 vapi 未导出 open/fsync，这里退化为尽力而为的空操作；
     * rename 本身已保证桌面环境不会读到半截文件。
     */
    public static void sync_dir (string dir) {
        try {
            AppPath.file_query (dir, false);
        } catch {
            // 仅是落盘优化，失败可忽略
        }
    }

    /* ── 删除 ────────────────────────────────────────────────────── */

    public static bool delete (string path, out string? error) {
        error = null;
        try {
            GLib.File.new_for_path (path).delete (null);
        } catch (GLib.Error e) {
            error = "删除失败: %s (%s)".printf (AppPath.shorten (path), e.message);
            return false;
        }
        sync_dir (GLib.Path.get_dirname (path));
        return true;
    }

    /* ── 缓存刷新 ────────────────────────────────────────────────── */

    public static void refresh_menu (bool update_db) {
        if (update_db) {
            try {
                GLib.Process.spawn_sync (
                    null,
                    { "/usr/bin/update-desktop-database",
                      AppPath.applications_dir () },
                    null, GLib.SpawnFlags.STDOUT_TO_DEV_NULL
                     | GLib.SpawnFlags.STDERR_TO_DEV_NULL,
                    null);
            } catch {}
        }
    }

    public static void refresh_icon_cache (bool update_cache) {
        if (!update_cache)
            return;
        try {
            GLib.Process.spawn_sync (
                null,
                { "/usr/bin/gtk-update-icon-cache", "-f", "-t",
                  AppPath.icons_hicolor_dir () },
                null, GLib.SpawnFlags.STDOUT_TO_DEV_NULL
                 | GLib.SpawnFlags.STDERR_TO_DEV_NULL,
                null);
        } catch {}
    }

    /* ── 校验 ────────────────────────────────────────────────────── */

    /**
     * 运行一个命令并抓取 stdout/stderr。
     *
     * vapi 里的 GLib.SpawnFlags 没有 STDOUT_PIPE / STDERR_PIPE，
     * 因此改用 GSubprocess。
     */
    private static bool run_capture (string[] argv, out string sout, out string serr, out int exit_status) {
        sout = "";
        serr = "";
        exit_status = -1;
        try {
            var proc = new GLib.Subprocess.newv (argv,
                GLib.SubprocessFlags.STDOUT_PIPE | GLib.SubprocessFlags.STDERR_PIPE);
            proc.communicate_utf8 (null, null, out sout, out serr);
            exit_status = proc.get_exit_status ();
            return true;
        } catch {
            return false;
        }
    }

    /**
     * 调用 desktop-file-validate 校验内容。
     * 返回空串表示通过。
     */
    public static string validate_content (string content) {
        string tmp;
        try {
            tmp = DirUtils.make_tmp ("appmgr-validate-XXXXXX.desktop");
        } catch {
            return "";   // 无法建临时文件就跳过校验，不阻塞用户
        }

        try {
            GLib.FileUtils.set_contents (tmp, content);
        } catch {
            AppPath.file_remove (tmp);
            return "";
        }

        string[] argv = { "/usr/bin/desktop-file-validate", tmp };
        string sout, serr;
        int status = -1;
        bool ok = run_capture (argv, out sout, out serr, out status);
        AppPath.file_remove (tmp);
        if (!ok || status == 0)
            return "";

        string msg = (serr ?? "").strip ();
        // 去掉路径前缀，只留诊断信息
        if (msg.contains (tmp))
            msg = msg.replace (tmp, "");
        return msg.replace ("\n", "  ").strip ();
    }

    /** 校验已落盘的文件 */
    public static string validate_file (string path) {
        string[] argv = { "/usr/bin/desktop-file-validate", path };
        string sout, serr;
        int status = -1;
        if (!run_capture (argv, out sout, out serr, out status))
            return "";
        if (status == 0)
            return "";
        return (serr ?? "").strip ();
    }
}