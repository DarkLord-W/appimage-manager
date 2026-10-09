/*
 * paths.vala — XDG 路径解析与 AppImage 路径工具
 *
 * 集中处理所有路径相关逻辑，避免散落在各模块里。
 */
namespace AppPath {

    /* ── XDG 标准目录 ───────────────────────────────────────────── */

    /** $XDG_DATA_HOME/applications —— 本工具唯一写入的启动器目录 */
    public string applications_dir () {
        return GLib.build_filenamev (GLib.get_user_data_dir (), "applications");
    }

    /** $XDG_DATA_HOME/icons/hicolor */
    public string icons_hicolor_dir () {
        return GLib.build_filenamev (GLib.get_user_data_dir (), "icons", "hicolor");
    }

    public string cache_dir () {
        return GLib.build_filenamev (GLib.get_user_cache_dir (), "appimage-manager");
    }

    public string config_dir () {
        return GLib.build_filenamev (GLib.get_user_config_dir (), "appimage-manager");
    }

    public string data_root () {
        return GLib.build_filenamev (GLib.get_user_data_dir (), "appimage-manager");
    }

    public string config_file () {
        return GLib.build_filenamev (config_dir (), "config.ini");
    }

    /** 提取过程中的临时工作区 */
    public string tmp_extract_dir () {
        return GLib.build_filenamev (cache_dir (), "extract");
    }

    /* ── 路径规范化 ─────────────────────────────────────────────── */

    /**
     * 规范化用于比对的路径：展开 ~、消解 . 与 ..、解析软链接。
     * 失败时退回展开 ~ 后的绝对路径。
     */
    public string canonical (string path) {
        if (path == null || path == "")
            return "";

        string expanded = expand_tilde (path);

        try {
            var f = GLib.File.new_for_path (expanded);
            return f.get_path ();
        } catch {
            return expanded;
        }
    }

    public string expand_tilde (string path) {
        if (path == null)
            return "";
        if (path == "~")
            return GLib.get_home_dir ();
        if (path.has_prefix ("~/"))
            return GLib.build_filename (GLib.get_home_dir (), path.substring (2));
        return path;
    }

    /** 展示用：把家目录前缀换成 ~ */
    public string shorten (string path) {
        string home = GLib.get_home_dir ();
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
        if (GLib.mkdir_with_parents (path, 0755) != 0)
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

    /* ── slug 生成 ──────────────────────────────────────────────── */

    /**
     * 把任意 AppImage 文件名转成符合规范的文件名 slug：
     * 小写、仅 [a-z0-9.-]、折叠重复分隔符、去掉多余点、超长截断。
     *
     *   Obsidian-1.5.3-x86_64.AppImage → obsidian-1.5.3-x86_64
     */
    public string slugify (string basename) {
        string s = basename.to_lower ();

        // 去掉所有扩展名
        while (s.contains (".")) {
            int idx = s.last_index_of (".");
            if (idx < 0)
                break;
            s = s.substring (0, idx);
            if (s == "")
                break;
        }

        var sb = new GLib.StringBuilder ();
        bool prev_dash = false;
        foreach (unichar c in s) {
            bool ok = (c >= 'a' && c <= 'z')
                   || (c >= '0' && c <= '9')
                   || c == '.' || c == '-' || c == '_';
            if (ok) {
                if (c == '-' || c == '_' || c == '.') {
                    // 折叠连续分隔符，且不允许开头/结尾出现
                    if (prev_dash || sb.len == 0)
                        continue;
                    prev_dash = true;
                } else {
                    prev_dash = false;
                }
                sb.append_c (c);
            } else {
                // 任何其它字符（含空格、汉字、括号）都当作分隔符
                if (!prev_dash && sb.len > 0) {
                    sb.append_c ('-');
                    prev_dash = true;
                }
            }
        }

        string out = sb.str.strip ();
        while (out.has_prefix ("-") || out.has_prefix ("."))
            out = out.substring (1);
        while (out.has_suffix ("-") || out.has_suffix ("."))
            out = out.substring (0, out.length - 1);

        if (out.length > 50)
            out = out.substring (0, 50);
        while (out.has_suffix ("-"))
            out = out.substring (0, out.length - 1);

        return out == "" ? "appimage" : out;
    }

    /** 从文件名提取展示用名称：Obsidian-1.5.3-x86_64.AppImage → Obsidian */
    public string display_name_from_file (string basename) {
        string s = basename;
        while (s.contains (".")) {
            int idx = s.last_index_of (".");
            if (idx < 0)
                break;
            s = s.substring (0, idx);
            if (s == "")
                break;
        }
        // 砍掉结尾的版本号 / 架构后缀
        string[] parts = s.split ("-");
        var kept = new GenericArray<string> ();
        foreach (string p in parts) {
            string t = p.strip ();
            if (t == "")
                continue;
            bool looks_like_tag = false;
            string lower = t.to_lower ();
            // x86_64 / amd64 / aarch64
            if (lower == "x86_64" || lower == "amd64" || lower == "aarch64"
                || lower == "arm64" || lower == "i386" || lower == "x86")
                looks_like_tag = true;
            // 1.2.3 / v1.2.3 / 1.2.3.4
            if (t.length > 0 && (t[0] == 'v' || t[0] == 'V')) {
                string rest = t.substring (1);
                if (rest.length > 0 && rest[0] >= '0' && rest[0] <= '9')
                    looks_like_tag = true;
            }
            foreach (char c in t) {
                if ((c >= '0' && c <= '9') || c == '.') {
                    if (t.length > 0) {
                        // 纯数字/点组成的 token 视为版本号
                    }
                }
            }
            if (!looks_like_tag && kept.size > 0) {
                // 若 token 整体是版本号（只含数字和点，且首个字符是数字）
                bool all_num = true;
                bool first_digit = t.length > 0 && t[0] >= '0' && t[0] <= '9';
                for (int i = 0; i < t.length; i++) {
                    char c = t[i];
                    if (!((c >= '0' && c <= '9') || c == '.')) {
                        all_num = false;
                        break;
                    }
                }
                if (all_num && first_digit)
                    looks_like_tag = true;
            }
            if (!looks_like_tag)
                kept.add (t);
        }

        if (kept.size == 0)
            return s.strip ();

        // 多词合并回带空格的名称
        string result = string.joinv (" ", (owned) kept.to_array ());
        return result.strip ();
    }
}