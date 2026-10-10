/*
 * paths.vala — XDG 路径解析与 AppImage 路径工具
 *
 * 集中处理所有路径相关逻辑，避免散落在各模块里。
 */
namespace AppPath {

    /* ── 文件操作兼容层 ─────────────────────────────────────────── */
    /*
     * 发行版打包的 glib vapi 里缺少一部分便利函数
     * （FileUtils.copy / query_info / lstat / mkdir_with_parents），
     * 这里统一用 GIO 或底层 GLib 补齐，调用方不必关心差异。
     *
     * 注意：gio 的类型在本发行版的 vapi 里被放进了 GLib 命名空间
     * （GLib.File / GLib.FileInfo / GLib.FileCopyFlags …），
     * 并没有独立的 Gio 命名空间。
     */

    public static void file_copy (string src, string dest, bool overwrite = true) throws GLib.Error {
        var s = GLib.File.new_for_path (src);
        var d = GLib.File.new_for_path (dest);
        var flags = overwrite
            ? GLib.FileCopyFlags.OVERWRITE
            : GLib.FileCopyFlags.NONE;
        s.copy (d, flags, null, null);
    }

    public static GLib.FileInfo? file_query (string path, bool follow = true) {
        try {
            var f = GLib.File.new_for_path (path);
            var flags = follow
                ? GLib.FileQueryInfoFlags.NONE
                : GLib.FileQueryInfoFlags.NOFOLLOW_SYMLINKS;
            return f.query_info ("standard::*,unix::mode,time::modified", flags, null);
        } catch {
            return null;
        }
    }

    /** 不跟随软链接地查询；返回 null 表示路径查不到（不存在 / 无权限） */
    public static GLib.FileInfo? file_lstat (string path) {
        return file_query (path, false);
    }

    public static int64 file_size (string path) {
        var info = file_query (path, false);
        return info == null ? 0 : (int64) info.get_size ();
    }

    public static bool file_is_executable (string path) {
        var info = file_query (path, false);
        if (info == null)
            return false;
        return (info.get_attribute_uint32 ("unix::mode") & 0100) != 0;
    }

    public static bool file_chmod_exec (string path) {
        var info = file_query (path, false);
        if (info == null)
            return false;
        uint32 mode = info.get_attribute_uint32 ("unix::mode");
        mode |= 0755;
        return GLib.FileUtils.chmod (path, (int) mode) == 0;
    }

    public static void file_remove (string path) {
        GLib.FileUtils.unlink (path);
    }

    public static bool dir_create (string path, int mode = 0755) {
        return GLib.DirUtils.create_with_parents (path, mode) == 0;
    }

    /* ── XDG 标准目录 ───────────────────────────────────────────── */

    /** $XDG_DATA_HOME/applications —— 本工具唯一写入的启动器目录 */
    public string applications_dir () {
        return GLib.Path.build_filename (GLib.Environment.get_user_data_dir (), "applications");
    }

    /** $XDG_DATA_HOME/icons/hicolor */
    public string icons_hicolor_dir () {
        return GLib.Path.build_filename (GLib.Environment.get_user_data_dir (), "icons", "hicolor");
    }

    public string cache_dir () {
        return GLib.Path.build_filename (GLib.Environment.get_user_cache_dir (), "appimage-manager");
    }

    public string config_dir () {
        return GLib.Path.build_filename (GLib.Environment.get_user_config_dir (), "appimage-manager");
    }

    public string data_root () {
        return GLib.Path.build_filename (GLib.Environment.get_user_data_dir (), "appimage-manager");
    }

    public string config_file () {
        return GLib.Path.build_filename (config_dir (), "config.ini");
    }

    /** 提取过程中的临时工作区 */
    public string tmp_extract_dir () {
        return GLib.Path.build_filename (cache_dir (), "extract");
    }

    /* ── 路径规范化 ─────────────────────────────────────────────── */

    /**
     * 规范化用于比对的路径：展开 ~、转绝对路径、消解 . 与 ..、解析软链接。
     *
     * 解析不出软链接（例如指向不存在的目标）时退回已完成前几步的绝对路径。
     */
    public string canonical (string path) {
        if (path == null || path == "")
            return "";

        // 展开 ~ 后再消解 . / ..，relative_to 为空表示相对当前目录
        string abs = GLib.Filename.canonicalize (expand_tilde (path), null);
        return resolve_symlinks (abs);
    }

    /**
     * 解析路径中的软链接（等价于 realpath，但失败时优雅退回）。
     *
     * 逐个路径分量解析，而不是只对整条路径调一次 read_link ——
     * 因为「软链接目录里的普通文件」这种情况，文件自己并不是软链接，
     * 只看它会完全解析不出来（原来就是这么漏的）。
     *
     * 两个都踩过的坑：
     *  1) 只解析最后一级 → 软链接目录下的文件解析不出来。
     *  2) 局部变量必须带初值声明（string t = ""）。只写 `string t;`
     *     时 Vala 把它当借用引用，read_link 返回的字符串随即被释放，
     *     再读 t 就是读已释放内存 —— 实测得到的是乱码。
     *
     * 读不出软链接（不是软链接、或目标不存在）时，该分量原样保留，
     * 所以悬空软链接也能安全返回一个绝对路径。
     */
    private string resolve_symlinks (string path) {
        string cur = path;
        if (!GLib.Path.is_absolute (cur))
            cur = GLib.Filename.canonicalize (cur, null);

        string acc = "/";
        int hops = 0;

        foreach (string part in cur.split ("/")) {
            if (part == "" || part == ".")
                continue;

            if (part == "..") {
                acc = GLib.Path.get_dirname (acc);
                continue;
            }

            string next = GLib.Path.build_filename (acc, part);

            // 这一级可能是软链接，跟着走；链上每一环都可能是软链接
            for (int guard = 0; guard < 40; guard++) {
                string tgt = "";
                try {
                    tgt = GLib.FileUtils.read_link (next);
                } catch {
                    tgt = "";
                }

                if (tgt == "")
                    break;      // 不是软链接 → 这一级定了

                next = GLib.Path.is_absolute (tgt)
                    ? GLib.Filename.canonicalize (tgt, null)
                    : GLib.Filename.canonicalize (
                          GLib.Path.build_filename (acc, tgt), null);

                if (++hops > 40)
                    return cur;    // 疑似成环，放弃
            }

            acc = next;
        }

        return GLib.Filename.canonicalize (acc, null);
    }

    public string expand_tilde (string path) {
        if (path == null)
            return "";
        if (path == "~")
            return GLib.Environment.get_home_dir ();
        if (path.has_prefix ("~/"))
            return GLib.Path.build_filename (GLib.Environment.get_home_dir (), path.substring (2));
        return path;
    }

    /** 展示用：把家目录前缀换成 ~ */
    public string shorten (string path) {
        string home = GLib.Environment.get_home_dir ();
        if (path == null)
            return "";
        if (path == home)
            return "~";
        if (path.has_prefix (home + "/"))
            return "~" + path.substring (home.length);
        return path;
    }

    public bool exists (string path) {
        return path != null && GLib.FileUtils.test (path, GLib.FileTest.EXISTS);
    }

    public bool is_dir (string path) {
        return path != null && GLib.FileUtils.test (path, GLib.FileTest.IS_DIR);
    }

    public bool is_executable (string path) {
        return path != null
            && GLib.FileUtils.test (path, GLib.FileTest.IS_EXECUTABLE);
    }

    /** 递归建目录 */
    public bool ensure_dir (string path) {
        if (path == null || path == "")
            return false;
        if (is_dir (path))
            return true;
        if (GLib.DirUtils.create_with_parents (path, 0755) != 0)
            return false;
        return is_dir (path);
    }

    /* ── 体积格式化 ─────────────────────────────────────────────── */

    public string format_size (uint64 bytes) {
        if (bytes == 0)
            return "—";
        string[] units = { "B", "KB", "MB", "GB", "TB" };
        double v = (double) bytes;
        int u = 0;
        while (v >= 1024.0 && u < units.length - 1) {
            v /= 1024.0;
            u++;
        }
        return u == 0
            ? "%d %s".printf ((int) v, units[u])
            : "%.1f %s".printf (v, units[u]);
    }

    /* ── 扩展名剥离 ─────────────────────────────────────────────── */

    /**
     * 剥掉已知的打包/压缩扩展名链，只剥「认得」的扩展名。
     *
     * 关键点：不能见到点就砍，否则 1.5.3 这样的版本号会被吃掉。
     *
     *   Obsidian-1.5.3-x86_64.AppImage → Obsidian-1.5.3-x86_64
     *   app.AppImage.zsync             → app
     *   tool_linux_amd64.tar.gz        → tool_linux_amd64
     *   My.App.1.0                     → My.App.1.0（不动）
     */
    public string strip_known_extensions (string basename) {
        // 长后缀优先，否则 .tar.gz 会被当成 .gz 剥完还剩 .tar
        string[] known = {
            ".appimage.zsync", ".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst",
            ".appimage", ".zsync", ".zip", ".tgz", ".tar", ".gz", ".xz",
            ".bz2", ".zst", ".7z", ".rar", ".bin", ".run", ".iso",
            ".squashfs", ".deb", ".rpm", ".exe", ".dmg"
        };

        string s = basename;
        bool changed = true;
        while (changed) {
            changed = false;
            string lower = s.down ();
            foreach (string ext in known) {
                if (!lower.has_suffix (ext))
                    continue;

                // 剥完不能什么都不剩
                string stem = s.substring (0, s.length - ext.length);
                if (stem == "")
                    continue;

                s = stem;
                changed = true;
                break;
            }
        }
        return s;
    }

    /* ── slug 生成 ──────────────────────────────────────────────── */

    /**
     * 把任意 AppImage 文件名转成符合规范的文件名 slug：
     * 小写、仅 [a-z0-9._-]、折叠重复分隔符、去掉多余点、超长截断。
     *
     *   Obsidian-1.5.3-x86_64.AppImage → obsidian-1.5.3-x86_64
     */
    public string slugify (string basename) {
        string s = strip_known_extensions (basename).down ();

        var sb = new GLib.StringBuilder ();
        bool prev_sep = false;   // 上一个字符是分隔符（'-' '_' '.' 或被丢弃的其它字符）

        int idx = 0;
        unichar c = 0;
        while (s.get_next_char (ref idx, out c)) {
            bool alnum = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
            bool is_sep = (c == '.' || c == '-' || c == '_');

            if (alnum) {
                sb.append_unichar (c);
                prev_sep = false;
                continue;
            }

            if (is_sep) {
                // 折叠连续分隔符；开头的分隔符直接丢弃
                if (prev_sep || sb.len == 0)
                    continue;
                sb.append_unichar (c);
                prev_sep = true;
                continue;
            }

            // 其它字符（空格、汉字、括号…）一律视作分隔符，写成 '-'
            if (!prev_sep && sb.len > 0) {
                sb.append_c ('-');
                prev_sep = true;
            }
        }

        string result = sb.str.strip ();
        while (result.has_prefix ("-") || result.has_prefix (".")
               || result.has_prefix ("_"))
            result = result.substring (1);
        while (result.has_suffix ("-") || result.has_suffix (".")
               || result.has_suffix ("_"))
            result = result.substring (0, result.length - 1);

        if (result.length > 50)
            result = result.substring (0, 50);
        while (result.has_suffix ("-") || result.has_suffix (".")
               || result.has_suffix ("_"))
            result = result.substring (0, result.length - 1);

        return result == "" ? "appimage" : result;
    }

    /**
     * 从文件名提取展示用名称：
     *   Obsidian-1.5.3-x86_64.AppImage → Obsidian
     *   My App-v2.10-amd64.AppImage  → My App
     */
    public string display_name_from_file (string basename) {
        // 只剥已知的打包扩展名，保留版本号里的点
        string s = strip_known_extensions (basename);

        // 砍掉结尾的版本号 / 架构后缀
        string[] parts = s.split ("-");
        string[] kept = {};
        foreach (string raw in parts) {
            string t = raw.strip ();
            if (t == "")
                continue;

            if (is_drop_token (t))
                continue;

            kept += t;
        }

        if (kept.length == 0)
            return trim_edges (s.strip ());

        // 多词合并回带空格的名称
        return trim_edges (string.joinv (" ", kept).strip ());
    }

    /** 去掉首尾的空白与成串的 . - _ 分隔符 */
    private string trim_edges (string text) {
        string r = text.strip ();
        bool changed = true;
        while (changed && r.length > 0) {
            changed = false;
            char first = r[0];
            if (first == '.' || first == '-' || first == '_') {
                r = r.substring (1).strip ();
                changed = true;
            }
            if (r.length > 0) {
                char tail = r[r.length - 1];
                if (tail == '.' || tail == '-' || tail == '_') {
                    r = r.substring (0, r.length - 1).strip ();
                    changed = true;
                }
            }
        }
        return r;
    }

    /** 判断一个 '-' 分隔的片段是否只是版本号 / 架构标记，该丢就丢 */
    private bool is_drop_token (string t) {
        string lower = t.down ();

        // x86_64 / amd64 / aarch64 / arm64 / i386 / x86
        if (lower == "x86_64" || lower == "amd64" || lower == "aarch64"
            || lower == "arm64" || lower == "i386" || lower == "x86")
            return true;

        if (t.length == 0)
            return true;

        // 只含数字和点的 token（1.5.3 / 2024.1）视为版本号
        bool first_digit = t[0] >= '0' && t[0] <= '9';
        if (first_digit) {
            bool all_num = true;
            for (int i = 0; i < t.length; i++) {
                char c = t[i];
                if (!((c >= '0' && c <= '9') || c == '.')) {
                    all_num = false;
                    break;
                }
            }
            if (all_num)
                return true;
        }

        // v1.2.3 / V2 这种前缀式版本号
        if (t[0] == 'v' || t[0] == 'V') {
            string rest = t.substring (1);
            if (rest.length > 0 && rest[0] >= '0' && rest[0] <= '9')
                return true;
        }

        return false;
    }
}