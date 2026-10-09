/*
 * rules.vala — .desktop 健康检查规则引擎
 *
 * 关键约束：BOM / CRLF / 非法编码会让 GKeyFile 直接解析失败，
 * 此时必须先做字节级预处理才能读到内容、列出问题。
 * 因此 check() 分为「字节体检」和「语义检查」两段。
 */
namespace RuleSet {

    public enum Severity {
        FATAL,    // 🔴 文件整体无效
        SERIOUS,  // 🔴 规范违反或功能失效
        WARNING,  // 🟡 体验问题
        NOTICE    // ⚪ 建议项
    }

    public const string SEV_FATAL   = "严重";
    public const string SEV_SERIOUS = "严重";
    public const string SEV_WARNING = "警告";
    public const string SEV_NOTICE  = "提示";

    public class Problem {
        public string id = "";           // D001 / E001 / I001 …
        public Severity severity;
        public string title = "";
        public string current = "";      // 当前值，展示用
        public string fixed = "";        // 修复后值，展示用
        public bool   applyable = true;  // 是否可自动修
        public bool   needs_confirm = false; // 必须用户确认（Hidden/NoDisplay）

        public Problem (string id, Severity sev, string title) {
            this.id = id;
            this.severity = sev;
            this.title = title;
        }

        public string severity_label () {
            switch (severity) {
                case Severity.FATAL:   return SEV_FATAL;
                case Severity.SERIOUS: return SEV_SERIOUS;
                case Severity.WARNING: return SEV_WARNING;
                default:               return SEV_NOTICE;
            }
        }

        public string severity_color () {
            switch (severity) {
                case Severity.FATAL:
                case Severity.SERIOUS: return "#e74c3c";
                case Severity.WARNING: return "#e5a00d";
                default:               return "#95a5a6";
            }
        }
    }

    public class Result {
        public Problem[] problems = {};
        public int fatal_count = 0;
        public int serious_count = 0;

        public bool has_any () { return problems.length > 0; }
    }

    /* ── 字节级体检 ──────────────────────────────────────────────── */

    public class ByteReport {
        public bool has_bom = false;
        public bool has_crlf = false;
        public bool bad_utf8 = false;
        public bool missing_group = false;
        public bool missing_type = false;
        public bool bad_version = false;
        public string version_raw = "";
        public int version_value = 0;
    }

    /** 直接读字节，不经过 GKeyFile，因为解析前文件可能已经坏掉 */
    public static ByteReport byte_inspect (string path) {
        var r = new ByteReport ();
        string data;
        try {
            GLib.FileUtils.get_contents (path, out data);
        } catch {
            return r;
        }

        // BOM: EF BB BF
        if (data.length >= 3
            && (uint8) data[0] == 0xEF
            && (uint8) data[1] == 0xBB
            && (uint8) data[2] == 0xBF)
            r.has_bom = true;

        // CRLF
        if (data.contains ("\r\n"))
            r.has_crlf = true;

        // UTF-8 合法性
        string body = r.has_bom ? data.substring (3) : data;
        if (!is_valid_utf8 (body))
            r.bad_utf8 = true;

        // 组头（去 BOM 后）
        string text = r.has_bom ? body : data;
        foreach (string line in text.split ("\n")) {
            string t = line.strip ();
            if (t == "" || t.has_prefix ("#"))
                continue;
            r.missing_group = true;
            break;
        }
        if (!r.missing_group) {
            foreach (string line in text.split ("\n")) {
                string t = line.strip ();
                if (t.has_prefix ("[") && t.has_suffix ("]")) {
                    if (t == "[Desktop Entry]")
                        r.missing_group = false;
                    break;
                }
            }
        }

        // Version
        foreach (string line in text.split ("\n")) {
            string t = line.strip ();
            if (t.has_prefix ("Version=")) {
                r.version_raw = t.substring ("Version=".length).strip ();
                double v;
                if (double.try_parse (r.version_raw, out v)) {
                    r.version_value = (int) (v * 100);
                    if (v > 1.5)
                        r.bad_version = true;
                } else {
                    r.bad_version = true;
                }
                break;
            }
        }

        return r;
    }

    /** 手工 UTF-8 合法性校验：vapi 里没有 GLib.Converter，改用字节级规则 */
    private static bool is_valid_utf8 (string s) {
        int i = 0;
        int n = s.length;
        while (i < n) {
            uint8 b = (uint8) s[i];
            int extra;
            uint32 cp;
            if (b < 0x80) { i++; continue; }
            else if ((b & 0xE0) == 0xC0) { extra = 1; cp = b & 0x1F; }
            else if ((b & 0xF0) == 0xE0) { extra = 2; cp = b & 0x0F; }
            else if ((b & 0xF8) == 0xF0) { extra = 3; cp = b & 0x07; }
            else return false;

            if (i + extra >= n)
                return false;

            for (int k = 1; k <= extra; k++) {
                uint8 c = (uint8) s[i + k];
                if ((c & 0xC0) != 0x80)
                    return false;
                cp = (cp << 6) | (uint32) (c & 0x3F);
            }
            // 拒绝过长编码、代理区与越界码点
            if (extra == 1 && cp < 0x80) return false;
            if (extra == 2 && cp < 0x800) return false;
            if (extra == 3 && cp < 0x10000) return false;
            if (cp > 0x10FFFF) return false;
            if (cp >= 0xD800 && cp <= 0xDFFF) return false;
            i += extra + 1;
        }
        return true;
    }

    /* ── 完整检查 ────────────────────────────────────────────────── */

    public static Result check (DesktopFiles.Entry e, AppEntry app) {
        var res = new Result ();
        var probs = new GenericArray<Problem> ();

        var br = byte_inspect (e.file_path);

        /* ── 🔴 致命 ─────────────────────────────────────────── */

        if (br.has_bom) {
            var p = new Problem ("D002", Severity.FATAL, "UTF-8 with BOM");
            p.current = "EF BB BF " + preview_hex (e.file_path);
            p.fixed = "剥离 BOM（3 字节）";
            probs.add (p);
        }

        if (br.bad_utf8) {
            var p = new Problem ("D004", Severity.FATAL, "编码非法字节");
            p.current = preview_hex (e.file_path);
            p.fixed = "转码为 UTF-8";
            probs.add (p);
        }

        if (br.has_crlf) {
            var p = new Problem ("D003", Severity.FATAL, "CRLF 行尾");
            p.current = "含 \\r\\n";
            p.fixed = "全量转换为 LF";
            probs.add (p);
        }

        if (br.missing_group) {
            var p = new Problem ("D001", Severity.FATAL, "缺少 [Desktop Entry] 组头");
            p.current = "首个有效行不是组声明";
            p.fixed = "在文件最前插入 [Desktop Entry]";
            probs.add (p);
        }

        if (!e.parse_ok) {
            var p = new Problem ("D000", Severity.FATAL, "文件无法解析");
            p.current = e.parse_error;
            p.fixed = "无法自动修复，建议完全重建";
            p.applyable = false;
            probs.add (p);
        }

        if (e.type == "" || e.type != "Application") {
            var p = new Problem ("D005", Severity.FATAL, "Type= 缺失或值错误");
            p.current = e.type == "" ? "（缺失）" : e.type;
            p.fixed = "Type=Application";
            probs.add (p);
        }

        /* ── 🔴 严重 ─────────────────────────────────────────── */

        if (br.bad_version) {
            var p = new Problem ("E001", Severity.SERIOUS, "Version= 超出规范支持范围");
            p.current = "Version=%s".printf (br.version_raw);
            p.fixed = "Version=1.5";
            probs.add (p);
        }

        if (e.exec_line == "") {
            var p = new Problem ("E002", Severity.SERIOUS, "Exec= 缺失");
            p.current = "（缺失）";
            p.fixed = DesktopFiles.build_exec_arg (app.path) + " %U";
            probs.add (p);
        } else {
            string extracted = e.exec_target ?? "";

            if (!extracted.has_prefix ("/") && extracted != "") {
                var p = new Problem ("E003", Severity.SERIOUS, "Exec= 指向无法解析的路径");
                p.current = e.exec_line;
                p.fixed = DesktopFiles.build_exec_arg (app.path) + " %U";
                probs.add (p);
            } else if (extracted != "" && !AppPath.exists (extracted)) {
                var p = new Problem ("E003", Severity.SERIOUS, "Exec= 指向的文件不存在");
                p.current = "Exec=%s  ✗".printf (e.exec_line);
                p.fixed = DesktopFiles.build_exec_arg (app.path) + " %U";
                probs.add (p);
            }

            // 转义问题
            if (needs_escape (e.exec_line, extracted)) {
                var p = new Problem ("E004", Severity.SERIOUS, "Exec 路径未加引号或未转义");
                p.current = "Exec=%s".printf (e.exec_line);
                p.fixed = DesktopFiles.build_exec_arg (app.path) + " %U";
                probs.add (p);
            }

            // 字面 %
            if (has_literal_percent (e.exec_line)) {
                var p = new Problem ("E005", Severity.SERIOUS, "Exec 含未转义的字面 %");
                p.current = "Exec=%s".printf (e.exec_line);
                p.fixed = DesktopFiles.build_exec_arg (app.path) + " %U";
                probs.add (p);
            }

            // 包装脚本
            if (DesktopFiles.exec_is_wrapper (e.exec_line)) {
                var p = new Problem ("E006", Severity.SERIOUS, "Exec 指向包装脚本而非 AppImage");
                p.current = "Exec=%s".printf (e.exec_line);
                p.fixed = DesktopFiles.build_exec_arg (app.path) + " %U";
                probs.add (p);
            }
        }

        if (e.name == "") {
            var p = new Problem ("E007", Severity.SERIOUS, "Name= 缺失");
            p.current = "（缺失）";
            p.fixed = app.get_best_name ();
            probs.add (p);
        }

        if (has_duplicate_keys (e.file_path)) {
            var p = new Problem ("E008", Severity.SERIOUS, "存在重复键");
            p.current = "同名键在同组内出现多次";
            p.fixed = "保留最后一次出现";
            probs.add (p);
        }

        if (e.actions != "" && has_dangling_action (e)) {
            var p = new Problem ("E009", Severity.SERIOUS, "Actions= 引用了不存在的组");
            p.current = "Actions=%s".printf (e.actions);
            p.fixed = "移除该键";
            probs.add (p);
        }

        if (!e.basename.has_suffix (".desktop")) {
            var p = new Problem ("E010", Severity.SERIOUS, "文件后缀错误");
            p.current = e.basename;
            p.fixed = "%s.desktop".printf (AppPath.slugify (e.basename));
            probs.add (p);
        }

        /* ── 🟡 警告 ─────────────────────────────────────────── */

        if (e.icon == "") {
            var p = new Problem ("I001", Severity.WARNING, "Icon= 缺失");
            p.current = "（缺失）";
            p.fixed = "从 AppImage 提取 → 缓存至 %s".printf (AppPath.shorten (AppPath.cache_dir ()));
            probs.add (p);
        } else if (e.icon.has_prefix ("/") && !AppPath.exists (e.icon)) {
            var p = new Problem ("I001", Severity.WARNING, "Icon 指向的文件不存在");
            p.current = "Icon=%s  ✗".printf (e.icon);
            p.fixed = "从 AppImage 提取并缓存";
            probs.add (p);
        }

        if (e.categories == "") {
            var p = new Problem ("I002", Severity.WARNING, "缺少 Categories=");
            p.current = "（缺失）";
            p.fixed = "Categories=%s".printf (
                app.categories != "" ? app.categories : "Utility;");
            probs.add (p);
        }

        if (e.startup_wm_class == "") {
            var p = new Problem ("I003", Severity.WARNING, "缺少 StartupWMClass");
            p.current = "（缺失）";
            p.fixed = "StartupWMClass=%s".printf (
                app.startup_wm_class != "" ? app.startup_wm_class : app.get_best_name ());
            probs.add (p);
        }

        if (e.comment == "") {
            var p = new Problem ("I004", Severity.WARNING, "缺少 Comment=");
            p.current = "（缺失）";
            p.fixed = app.comment != "" ? app.comment : "由 AppImage 提取";
            probs.add (p);
        }

        if (e.terminal.down () == "true") {
            var p = new Problem ("I005", Severity.WARNING, "Terminal=true 但看起来是 GUI 应用");
            p.current = "Terminal=true";
            p.fixed = "Terminal=false";
            probs.add (p);
        }

        if (e.hidden.down () == "true") {
            var p = new Problem ("I006", Severity.WARNING, "Hidden=true 会让菜单不显示该条目");
            p.current = "Hidden=true";
            p.fixed = "Hidden=false（需你确认，可能是故意的）";
            p.needs_confirm = true;
            probs.add (p);
        }

        if (e.no_display.down () == "true") {
            var p = new Problem ("I007", Severity.WARNING, "NoDisplay=true 会让菜单不显示该条目");
            p.current = "NoDisplay=true";
            p.fixed = "NoDisplay=false（需你确认，可能是故意的）";
            p.needs_confirm = true;
            probs.add (p);
        }

        string slug = AppPath.slugify (e.basename.replace (".desktop", ""));
        if (e.basename != "%s.desktop".printf (slug)) {
            var p = new Problem ("I008", Severity.WARNING, "文件名不规范");
            p.current = e.basename;
            p.fixed = "%s.desktop".printf (slug);
            probs.add (p);
        }

        if (e.try_exec == "") {
            var p = new Problem ("I010", Severity.WARNING, "缺少 TryExec=");
            p.current = "（缺失）";
            p.fixed = app.path;
            probs.add (p);
        }

        /* ── ⚪ 提示 ─────────────────────────────────────────── */

        if (e.generic_name == "") {
            var p = new Problem ("C001", Severity.NOTICE, "缺少 GenericName=");
            p.current = "（缺失）";
            p.fixed = app.generic_name != "" ? app.generic_name : app.get_best_name ();
            probs.add (p);
        }

        if (!e.is_managed) {
            var p = new Problem ("C004", Severity.NOTICE, "未被本工具管理（缺少标记键）");
            p.current = "无 %s".printf (DesktopFiles.MARKER_PATH);
            p.fixed = "认领后追加标记键";
            p.applyable = false;
            probs.add (p);
        }

        /* ── 汇总 ───────────────────────────────────────────── */

        foreach (var p in probs) {
            if (p.severity == Severity.FATAL || p.severity == Severity.SERIOUS)
                res.fatal_count++;
            else if (p.severity == Severity.WARNING)
                res.serious_count++;
        }
        res.problems = probs.steal ();
        return res;
    }

    /* ── 检测辅助 ────────────────────────────────────────────────── */

    /** Exec 是否需要加引号或转义 */
    private static bool needs_escape (string exec_line, string extracted_path) {
        if (exec_line == "" || extracted_path == "")
            return false;
        // 已加引号就不算问题
        if (exec_line.strip ().has_prefix ("\""))
            return false;
        // 路径含空白必须加引号
        for (int i = 0; i < extracted_path.length; i++) {
            if (extracted_path[i] == ' ' || extracted_path[i] == '\t')
                return true;
        }
        // 含 shell 元字符
        for (int i = 0; i < extracted_path.length; i++) {
            if ("\"'`$\\&|;<>*?()[]^{}#~".index_of_char (extracted_path[i]) >= 0)
                return true;
        }
        return false;
    }

    /** 是否存在未转义的字面 % */
    private static bool has_literal_percent (string exec_line) {
        for (int i = 0; i < exec_line.length; i++) {
            if (exec_line[i] != '%')
                continue;
            if (i + 1 >= exec_line.length)
                return true;
            char next = exec_line[i + 1];
            // 合法字段码与 %%
            if (next == '%') { i++; continue; }
            if ("fFuUidDnNvVmck".index_of_char (next) >= 0)
                continue;
            return true;
        }
        return false;
    }

    /** 同组内是否有重复键 */
    private static bool has_duplicate_keys (string path) {
        string data;
        try {
            GLib.FileUtils.get_contents (path, out data);
        } catch {
            return false;
        }
        string current_group = "";
        var seen = new GLib.HashTable<string, bool> (GLib.str_hash, GLib.str_equal);
        foreach (string raw in data.split ("\n")) {
            string line = raw.strip ();
            if (line == "" || line.has_prefix ("#"))
                continue;
            if (line.has_prefix ("[") && line.has_suffix ("]")) {
                current_group = line;
                seen.remove_all ();
                continue;
            }
            int eq = line.index_of_char ('=');
            if (eq <= 0)
                continue;
            string key = "%s/%s".printf (current_group, line.substring (0, eq).strip ());
            if (seen.contains (key))
                return true;
            seen.insert (key, true);
        }
        return false;
    }

    /** GLib.Array<string> 没有 contains，手写线性查找 */
    private static bool has_group (DesktopFiles.Entry e, string name) {
        for (uint i = 0; i < e.group_names.length; i++) {
            if (e.group_names.index (i) == name)
                return true;
        }
        return false;
    }

    /** Actions= 引用的组是否都存在 */
    private static bool has_dangling_action (DesktopFiles.Entry e) {
        foreach (string a in e.actions.split (";")) {
            string t = a.strip ();
            if (t == "")
                continue;
            if (!has_group (e, "Desktop Action " + t))
                return true;
        }
        return false;
    }

    /** 预览文件开头的十六进制字节 */
    private static string preview_hex (string path) {
        try {
            string data;
            if (!GLib.FileUtils.get_contents (path, out data))
                return "（无法读取）";
            var sb = new GLib.StringBuilder ();
            int n = data.length < 16 ? data.length : 16;
            for (int i = 0; i < n; i++)
                sb.append ("%02X ".printf ((uint8) data[i]));
            return sb.str.strip ();
        } catch {
            return "（无法读取）";
        }
    }
}