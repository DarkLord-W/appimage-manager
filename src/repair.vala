/*
 * repair.vala — 修复执行与差异生成
 *
 * 事务流程见 journal.vala。本文件负责：
 *   1. 按 FixMode 计算修复后的内容（在内存中，不落盘）
 *   2. 生成 unified diff 供 UI 预览
 *   3. 执行修复（串行、原子写、逐项更新 journal）
 */
public class RepairPlan : GLib.Object {
    public AppEntry app;
    public DesktopFiles.Entry entry;

    public FixMode mode = FixMode.CONSERVATIVE;
    public bool[] selected = {};          // 与 problems 等长

    // 附加选项
    public bool rename_file = false;
    public bool claim = false;             // 是否顺便认领
    public bool rewrite_exec = true;       // 是否重写 Exec
    public bool fix_wrapper = true;        // 是否把包装脚本改为直接指向本体

    public string new_basename = "";
    public string proposed_content = "";
    public string original_content = "";

    public RuleSet.Problem[] problems = {};
    public string[] rules_fired = {};
    public string[] preserve_keys = {};
    public string[] drop_keys = {};

    public RepairPlan (AppEntry app, DesktopFiles.Entry entry) {
        this.app = app;
        this.entry = entry;
    }

    public bool any_selected () {
        for (int i = 0; i < selected.length; i++)
            if (selected[i]) return true;
        return false;
    }

    /** 需要重命名时的目标文件名 */
    public string target_basename () {
        return rename_file ? new_basename : GLib.Path.get_basename (entry.file_path);
    }

    public string target_path () {
        return GLib.Path.build_filename (AppPath.applications_dir (), target_basename ());
    }
}

namespace Repair {

    /* ── 内容生成 ────────────────────────────────────────────────── */

    /**
     * 读取原始内容并做字节级修复，得到规范化文本。
     * 这是所有后续处理的基础。
     */
    private static string load_normalized (string path) {
        string data;
        if (!GLib.FileUtils.get_contents (path, out data))
            return "";

        // 去 BOM
        if (data.length >= 3
            && (uint8) data[0] == 0xEF
            && (uint8) data[1] == 0xBB
            && (uint8) data[2] == 0xBF)
            data = data.substring (3);

        // CRLF → LF
        data = data.replace ("\r\n", "\n").replace ("\r", "\n");

        return data;
    }

    /** 解析成有序的键值结构，便于保序改写 */
    private class Doc : GLib.Object {
        public string group = "Desktop Entry";
        public GLib.Array<string> order;          // "group/key"
        public GLib.HashTable<string, string> values;
        public GLib.Array<string> extra_groups;   // 除 Desktop Entry 外的组原文

        construct {
            order = new GLib.Array<string> ();
            values = new GLib.HashTable<string, string> (GLib.str_hash, GLib.str_equal);
            extra_groups = new GLib.Array<string> ();
        }

        public string get (string group, string key, string fallback = "") {
            return values.contains ("%s/%s".printf (group, key))
                ? values.lookup ("%s/%s".printf (group, key)) : fallback;
        }

        public bool has (string group, string key) {
            return values.contains ("%s/%s".printf (group, key));
        }

        public void set (string group, string key, string value) {
            string k = "%s/%s".printf (group, key);
            if (!values.contains (k))
                order.append_val (k);
            values.insert (k, value);
        }

        public void remove (string group, string key) {
            string k = "%s/%s".printf (group, key);
            if (values.contains (k))
                values.remove (k);
        }

        public string to_text () {
            var sb = new GLib.StringBuilder ();
            sb.append ("[Desktop Entry]\n");
            foreach (string k in order) {
                if (!k.has_prefix ("Desktop Entry/"))
                    continue;
                string key = k.substring ("Desktop Entry/".length);
                sb.append ("%s=%s\n".printf (key, values.lookup (k)));
            }
            foreach (string g in extra_groups) {
                sb.append ("\n");
                sb.append (g);
                sb.append ("\n");
            }
            return sb.str;
        }
    }

    /** 把原文解析成保序文档结构 */
    private static Doc parse_doc (string text) {
        var doc = new Doc ();
        string current_group = "";
        bool in_main = false;

        foreach (string raw in text.split ("\n")) {
            string line = raw.strip ();
            if (line == "")
                continue;

            if (line.has_prefix ("[") && line.has_suffix ("]")) {
                current_group = line.substring (1, line.length - 2);
                if (current_group == "Desktop Entry") {
                    in_main = true;
                } else {
                    in_main = false;
                    // 整个组原样保留（Desktop Action 等用户自定义内容）
                    doc.extra_groups.append_val (collect_group (text, current_group));
                }
                continue;
            }

            if (line.has_prefix ("#"))
                continue;

            if (!in_main)
                continue;

            int eq = line.index_of_char ('=');
            if (eq <= 0)
                continue;

            string key = line.substring (0, eq).strip ();
            string val = line.substring (eq + 1);
            // 去重：保留最后一次出现
            doc.set ("Desktop Entry", key, val);
        }

        return doc;
    }

    /** 抓取某个完整组的原文（保留注释与顺序） */
    /**
     * 抓取某个完整组的原文（含组头，保留顺序）。
     *
     * 注意必须带上 `[Group Name]` 这一行 —— 否则 to_text 拼接回去时
     * 组内容会变成主组里的孤儿键，Desktop Action 就废了。
     */
    private static string collect_group (string text, string group_name) {
        var sb = new GLib.StringBuilder ();
        bool inside = false;
        foreach (string raw in text.split ("\n")) {
            string line = raw.strip ();
            if (line.has_prefix ("[") && line.has_suffix ("]")) {
                string g = line.substring (1, line.length - 2);
                if (g == group_name) {
                    inside = true;
                    sb.append (line).append ("\n");   // ← 带上组头
                    continue;
                }
                if (inside)
                    break;
            }
            if (inside)
                sb.append (line).append ("\n");
        }
        return sb.str.strip ();
    }

    /* ── 生成修复后的内容 ────────────────────────────────────────── */

    public static string build_repaired (RepairPlan plan) {
        string original = load_normalized (plan.entry.file_path);
        plan.original_content = original;
        var doc = parse_doc (original);
        var fired = new GenericArray<string> ();
        string DE = "Desktop Entry";

        // 收集被勾选的问题 id
        var on = new GLib.HashTable<string, bool> (GLib.str_hash, GLib.str_equal);
        for (int i = 0; i < plan.problems.length && i < plan.selected.length; i++)
            if (plan.selected[i])
                on.insert (plan.problems[i].id, true);

        bool fires (string id) { return on.contains (id); }

        /* ── 🔴 致命 / 严重 ─────────────────────────────────── */

        // D001 缺组头 → parse_doc 已保证以 [Desktop Entry] 开头
        if (fires ("D001")) fired.add ("D001");

        // D005 Type
        if (fires ("D005") || doc.get (DE, "Type") != "Application") {
            if (fires ("D005")) {
                doc.set (DE, "Type", "Application");
                fired.add ("D005");
            }
        } else if (!doc.has (DE, "Type")) {
            doc.set (DE, "Type", "Application");
        }

        // E001 Version
        if (fires ("E001")) {
            doc.set (DE, "Version", "1.5");
            fired.add ("E001");
        } else if (doc.has (DE, "Version")) {
            string v = doc.get (DE, "Version").strip ();
            double d;
            if (!double.try_parse (v, out d) || d > 1.5)
                doc.set (DE, "Version", "1.5");
        } else {
            doc.set (DE, "Version", "1.5");
        }

        // E002/E003/E004/E005/E006 Exec
        bool exec_broken = fires ("E002") || fires ("E003")
                        || fires ("E004") || fires ("E005") || fires ("E006");
        bool want_rewrite = exec_broken
            && (plan.rewrite_exec
                || fires ("E002") || fires ("E003")
                || (fires ("E006") && plan.fix_wrapper));

        if (want_rewrite) {
            string exec = DesktopFiles.build_exec_arg (plan.app.path);
            if (doc.has (DE, "Exec") && doc.get (DE, "Exec").contains ("%U"))
                exec += " %U";
            else if (doc.has (DE, "Exec") && doc.get (DE, "Exec").contains ("%F"))
                exec += " %F";
            else
                exec += " %U";
            doc.set (DE, "Exec", exec);
            string[] exec_rules = { "E002", "E003", "E004", "E005", "E006" };
            foreach (string id in exec_rules)
                if (fires (id))
                    fired.add (id);
        }

        // E007 Name
        if (fires ("E007")) {
            doc.set (DE, "Name", plan.app.get_best_name ());
            fired.add ("E007");
        } else if (!doc.has (DE, "Name")) {
            doc.set (DE, "Name", plan.app.get_best_name ());
        }

        // E009 悬空 Actions
        if (fires ("E009")) {
            doc.remove (DE, "Actions");
            fired.add ("E009");
        }

        // I005 Terminal
        if (fires ("I005")) {
            doc.set (DE, "Terminal", "false");
            fired.add ("I005");
        }

        // I006 / I007 需要用户确认才改
        if (fires ("I006")) {
            doc.set (DE, "Hidden", "false");
            fired.add ("I006");
        }
        if (fires ("I007")) {
            doc.set (DE, "NoDisplay", "false");
            fired.add ("I007");
        }

        /* ── 补全模式：只补缺失，不覆盖已有 ─────────────────── */

        // 语义：勾选 = 用户明确要求修这一项，与模式无关 —— 否则勾了 3 个
        // 「缺失字段」问题、点「修复 3 项」，在保守模式下却什么都没改，
        // 按钮数字与实际行为对不上。
        //
        // 模式只决定「勾选项之外」还做什么：
        //   保守 —— 只改勾选的
        //   补全 —— 勾选的之外，再给所有缺失的标准字段补上默认值
        //   重建 —— 整体重新生成
        bool enrich = plan.mode == FixMode.ENRICH
                   || plan.mode == FixMode.REBUILD;

        if (fires ("I001") || (enrich && !doc.has (DE, "Icon"))) {
            string icon = plan.app.icon_path ?? "";
            if (icon != "") {
                doc.set (DE, "Icon", icon);
                fired.add ("I001");
            }
        }
        if ((fires ("I002") || enrich) && !doc.has (DE, "Categories")) {
            doc.set (DE, "Categories", plan.app.categories != ""
                ? plan.app.categories : "Utility;");
            fired.add ("I002");
        }
        if ((fires ("I003") || enrich) && !doc.has (DE, "StartupWMClass")) {
            doc.set (DE, "StartupWMClass", plan.app.startup_wm_class != ""
                ? plan.app.startup_wm_class : plan.app.get_best_name ());
            fired.add ("I003");
        }
        if (fires ("I004") || (enrich && !doc.has (DE, "Comment") && plan.app.comment != "")) {
            doc.set (DE, "Comment", plan.app.comment);
            fired.add ("I004");
        }
        if ((fires ("I010") || enrich) && !doc.has (DE, "TryExec")) {
            doc.set (DE, "TryExec", plan.app.path);
            fired.add ("I010");
        }
        if (fires ("C001") || (enrich && !doc.has (DE, "GenericName"))) {
            doc.set (DE, "GenericName", plan.app.generic_name != ""
                ? plan.app.generic_name : plan.app.get_best_name ());
            fired.add ("C001");
        }

        /* ── 重建模式：整体替换 ─────────────────────────────── */

        if (plan.mode == FixMode.REBUILD) {
            var fresh = parse_doc (DesktopFiles.build_content (
                plan.app.path,
                plan.app.get_best_name (),
                plan.app.generic_name,
                plan.app.comment,
                plan.app.icon_path ?? "",
                plan.app.categories != "" ? plan.app.categories : "Utility;",
                plan.app.startup_wm_class != "" ? plan.app.startup_wm_class
                    : plan.app.get_best_name (),
                plan.app.mimetype,
                true, "%U"));

            // 用户勾选要保留的键
            foreach (string key in plan.preserve_keys) {
                string val = doc.get (DE, key);
                if (val != "")
                    fresh.set (DE, key, val);
            }
            doc = fresh;
            fired.add ("REBUILD");
        }

        /* ── 通用补齐 ──────────────────────────────────────── */

        if (!doc.has (DE, "StartupNotify"))
            doc.set (DE, "StartupNotify", "true");

        /* ── 认领：只在末尾追加标记，不动其它 ─────────────────── */

        if (plan.claim) {
            doc.set (DE, DesktopFiles.MARKER_BOOL, "true");
            doc.set (DE, DesktopFiles.MARKER_PATH, plan.app.path);
            doc.set (DE, DesktopFiles.MARKER_VERSION, APPMGR_VERSION);
            fired.add ("C004");
        } else if (doc.get (DE, DesktopFiles.MARKER_BOOL) == "true") {
            // 已认领的保持标记
            doc.set (DE, DesktopFiles.MARKER_PATH, plan.app.path);
        }

        plan.rules_fired = fired.steal ();

        // 重建模式本就承诺「整体重新生成」，走序列化；
        // 其它模式只把真正变化的行写回去，注释/空行/其它组逐字节保留。
        plan.proposed_content = (plan.mode == FixMode.REBUILD)
            ? doc.to_text ()
            : patch_original (original, doc);
        return plan.proposed_content;
    }

    /**
     * 把算好的改动应用到原文上，只重写真正变化的行。
     *
     * 原先一律走 doc.to_text() 整体序列化，那会把注释和空行都吃掉 ——
     * 而保守模式承诺的是「只改明确坏掉的字段」。用户精心写的注释不该
     * 因为一次修复就消失。
     *
     * 规则：
     *   · 组头、其它组、注释、空行 → 原样输出
     *   · Main 组里值没变的键 → 原样输出（保留原始写法与空格）
     *   · 值变了的键 → 重写成 key=新值
     *   · 被删掉的键（例如悬空的 Actions=）→ 丢弃
     *   · 新增的键 → 补在 Main 组末尾
     */
    private static string patch_original (string original, Doc doc) {
        bool ends_nl = original.has_suffix ("\n");
        var lines = new GenericArray<string> ();
        foreach (string l in original.split ("\n"))
            lines.add (l);
        if (ends_nl && lines.length > 0 && lines[lines.length - 1] == "")
            lines.remove_index (lines.length - 1);

        var out = new GLib.StringBuilder ();
        var seen = new GLib.HashTable<string, bool> (GLib.str_hash, GLib.str_equal);
        bool in_main = false;

        // Main 组里的空行先攒着不输出。等遇到下一个非空行（或组结束）再放出去，
        // 这样新增的键会插在组尾空行**之前**，空行继续充当与下一个组的分隔 ——
        // 和 append_markers 的处理保持一致。否则新键会孤零零地落在空行后面。
        var pending_blanks = new GLib.StringBuilder ();

        // Main 组结束时，把 doc 里有、原文里没有的键补上
        void flush_added () {
            foreach (string k in doc.order) {
                if (!k.has_prefix ("Desktop Entry/"))
                    continue;
                string key = k.substring ("Desktop Entry/".length);
                if (seen.contains (key))
                    continue;
                out.append ("%s=%s\n".printf (key, doc.values.lookup (k)));
            }
        }

        void flush_blanks () {
            if (pending_blanks.len > 0) {
                out.append (pending_blanks.str);
                pending_blanks.erase ();
            }
        }

        for (uint i = 0; i < lines.length; i++) {
            string line = lines[i];
            string t = line.strip ();

            if (t.has_prefix ("[") && t.has_suffix ("]")) {
                if (in_main) {
                    flush_added ();
                    flush_blanks ();
                    in_main = false;
                }
                out.append (line).append_c ('\n');
                if (t == "[Desktop Entry]")
                    in_main = true;
                continue;
            }

            if (!in_main) {
                // 其它组的内容，或文件头部的注释 —— 原样保留
                out.append (line).append_c ('\n');
                continue;
            }

            // Main 组内的行
            if (t == "" || t.has_prefix ("#")) {
                pending_blanks.append (line).append_c ('\n');   // 攒着，稍后放
                continue;
            }

            flush_blanks ();
            int eq = t.index_of_char ('=');
            if (eq <= 0) {
                out.append (line).append_c ('\n');
                continue;
            }

            string key = t.substring (0, eq).strip ();
            seen.insert (key, true);

            string full = "Desktop Entry/" + key;
            if (!doc.values.contains (full))
                continue;   // 这个键被修复删掉了

            // 直接和「原始值」比：doc.values 里存的就是原行 '=' 之后的部分，
            // 所以未改动的键会逐字符相等，从而连 "Name = Foo" 这种带空格的
            // 写法都能原样保留。不要重新拼 key=value 再比 —— 那会把
            // 值里的前导空格算成差异，白白重写一行。
            string newval = doc.values.lookup (full);
            string orig_val = t.substring (eq + 1);
            if (newval == orig_val)
                out.append (line).append_c ('\n');   // 没变 → 保留原写法
            else
                out.append ("%s=%s\n".printf (key, newval));   // 变了 → 重写
        }

        if (in_main) {
            flush_added ();
            flush_blanks ();
        }

        string result = out.str;
        if (!ends_nl && result.has_suffix ("\n"))
            result = result.substring (0, result.length - 1);
        return result;
    }

    /* ── 认领：字节级追加标记键 ──────────────────────────────────── */

    /**
     * 在 [Desktop Entry] 组的末尾追加三个标记键，原文其余部分逐字节保留。
     *
     * 为什么不走 Doc 往返：那条路径会把注释、空行都过滤掉，还会把
     * [Desktop Action ...] 之类的附加组整组丢弃。而认领的承诺是
     * 「原有内容一个字节都不改，只追加标记」—— 用户带着一个精心写好的
     * .desktop 过来，不该因为被接管就掉内容。
     *
     * 插入位置：[Desktop Entry] 之后第一个以 '[' 开头的行之前；
     *           没有后续组就插在文件末尾。
     * 幂等：先移除已有的标记键行，再追加，重复认领不会越叠越多。
     */
    public static string append_markers (string original, string appimage_path) {
        bool ends_with_newline = original.has_suffix ("\n");

        var lines = new GenericArray<string> ();
        foreach (string l in original.split ("\n"))
            lines.add (l);

        // split 会把结尾换行变成一个空尾巴，去掉它，最后再补回来
        if (ends_with_newline && lines.length > 0
            && lines[lines.length - 1] == "")
            lines.remove_index (lines.length - 1);

        // 1) 定位 [Desktop Entry] 组
        int de_start = -1;
        for (uint i = 0; i < lines.length; i++) {
            string t = lines[i].strip ();
            if (t == "[Desktop Entry]") {
                de_start = (int) i;
                break;
            }
        }

        // 2) 组的结束：下一个以 '[' 开头的行；没有就是文件末尾
        int de_end = (int) lines.length;   // 半开区间
        if (de_start >= 0) {
            for (uint i = (uint) de_start + 1; i < lines.length; i++) {
                string t = lines[i].strip ();
                if (t.has_prefix ("[")) {
                    de_end = (int) i;
                    break;
                }
            }
        }

        // 3) 去掉组内已存在的标记键（幂等），同时找到插入点
        var kept = new GenericArray<string> ();
        int insert_at = -1;   // 在 kept 里插入的位置

        for (int i = 0; i < lines.length; i++) {
            if (de_start >= 0 && i >= de_start && i < de_end) {
                string t = lines[i].strip ();
                if (t.has_prefix (DesktopFiles.MARKER_BOOL + "=")
                 || t.has_prefix (DesktopFiles.MARKER_PATH + "=")
                 || t.has_prefix (DesktopFiles.MARKER_VERSION + "="))
                    continue;   // 丢弃旧的标记行，稍后统一追加
            }

            kept.add (lines[i]);

            // 记录组尾位置
            if (de_start >= 0 && i == de_end - 1)
                insert_at = (int) kept.length;
        }

        if (insert_at < 0) {
            // 没找到 [Desktop Entry]，或它正好是文件最后一行 → 追加到末尾
            insert_at = (int) kept.length;
        } else {
            // 组尾若有空行，把标记插在空行之前 —— 让标记紧跟最后一个键，
            // 空行继续充当与下一个组之间的分隔，读起来更自然。
            while (insert_at > 0 && kept[insert_at - 1].strip () == "")
                insert_at--;
        }

        // 4) 插入标记键
        kept.insert (insert_at, DesktopFiles.MARKER_VERSION + "=" + APPMGR_VERSION);
        kept.insert (insert_at, DesktopFiles.MARKER_PATH + "=" + appimage_path);
        kept.insert (insert_at, DesktopFiles.MARKER_BOOL + "=true");

        // 5) 拼回去，保持原来的结尾换行状态
        string joined = string.joinv ("\n", kept.steal ());
        return ends_with_newline ? joined + "\n" : joined;
    }

    /**
     * 认领时的最小改写。
     *
     * 与 append_markers 同源：只动需要改的那两行（Exec / TryExec），
     * 其余行 —— 注释、空行、原始写法、[Desktop Action ...] 等附加组 ——
     * 逐字节保留。最后在 [Desktop Entry] 组末尾追加标记键。
     *
     * 之前认领走的是「逐行重建」，即使只改一个 Exec 也会把注释、空行、
     * 附加组全部吃掉，与对话框上「原有内容保留」的说法不符。
     *
     * @param rewrite_exec true = 把 Exec 重写成本 AppImage 的规范形式
     * @param ensure_tryexec true = 顺带补一行 TryExec（已有则只更新值）
     */
    public static string claim_rewrite (string original,
                                        string appimage_path,
                                        bool rewrite_exec,
                                        bool ensure_tryexec) {
        bool ends_nl = original.has_suffix ("\n");
        var src = new GenericArray<string> ();
        foreach (string l in original.split ("\n"))
            src.add (l);
        if (ends_nl && src.length > 0 && src[src.length - 1] == "")
            src.remove_index (src.length - 1);

        // [Desktop Entry] 组的范围（半开区间）
        int de_start = -1;
        for (uint i = 0; i < src.length; i++) {
            if (src[i].strip () == "[Desktop Entry]") {
                de_start = (int) i;
                break;
            }
        }
        int de_end = (int) src.length;
        if (de_start >= 0) {
            for (uint i = (uint) de_start + 1; i < src.length; i++) {
                if (src[i].strip ().has_prefix ("[")) {
                    de_end = (int) i;
                    break;
                }
            }
        }

        string new_exec = DesktopFiles.build_exec_arg (appimage_path) + " %U";
        bool saw_tryexec = false;

        // 逐行处理，放进结果数组
        var out_lines = new GenericArray<string> ();
        for (int i = 0; i < src.length; i++) {
            string line = src[i];

            if (de_start < 0 || i < de_start || i >= de_end) {
                out_lines.add (line);      // 组外：文件头注释、其它组 → 原样
                continue;
            }

            string t = line.strip ();
            if (t == "" || t.has_prefix ("#")) {
                out_lines.add (line);      // 空行、注释 → 原样
                continue;
            }

            int eq = t.index_of_char ('=');
            if (eq <= 0) {
                out_lines.add (line);
                continue;
            }

            string key = t.substring (0, eq).strip ();

            // 旧的标记键一律丢弃，稍后统一追加，保证幂等
            if (key == DesktopFiles.MARKER_BOOL
             || key == DesktopFiles.MARKER_PATH
             || key == DesktopFiles.MARKER_VERSION)
                continue;

            if (key == "Exec" && rewrite_exec) {
                out_lines.add ("Exec=" + new_exec);
                continue;
            }

            if (key == "TryExec" && ensure_tryexec) {
                saw_tryexec = true;
                out_lines.add ("TryExec=" + appimage_path);
                continue;
            }

            out_lines.add (line);
        }

        // 找 [Desktop Entry] 组在结果里的结尾：下一个组头，或末尾；
        // 组尾的空行要留在标记之后，继续充当与下一组的分隔。
        int insert_at = (int) out_lines.length;
        for (uint i = 0; i < out_lines.length; i++) {
            if (out_lines[i].strip ().has_prefix ("[")
                && out_lines[i].strip () != "[Desktop Entry]") {
                insert_at = (int) i;
                break;
            }
        }
        while (insert_at > 0 && out_lines[insert_at - 1].strip () == "")
            insert_at--;

        // 从后往前插，保持顺序
        out_lines.insert (insert_at, DesktopFiles.MARKER_VERSION
                                     + "=" + APPMGR_VERSION);
        out_lines.insert (insert_at, DesktopFiles.MARKER_PATH + "=" + appimage_path);
        out_lines.insert (insert_at, DesktopFiles.MARKER_BOOL + "=true");
        if (ensure_tryexec && !saw_tryexec)
            out_lines.insert (insert_at, "TryExec=" + appimage_path);

        string result = string.joinv ("\n", out_lines.steal ());
        return ends_nl ? result + "\n" : result;
    }

    /* ── 按键改写：只动指定键，其余逐字节保留 ─────────────────────── */

    /**
     * 把 [Desktop Entry] 组里指定键的值替换掉，其余内容逐字节保留。
     *
     * 和 patch_original 是同一套思路，只是入口从「修复计划」换成了
     * 「给我几个键值」：注释、空行、原始写法、[Desktop Action …] 附加组
     * 全都不碰，只重写值确实变了的那几行；原文里没有的键补在组末尾。
     *
     * updates 的键是纯键名（"Name" / "Comment" …），值是新值。
     *
     * 注意：原文若没有 [Desktop Entry] 组，这里改不动任何东西，
     * 会原样返回 —— 调用方应该自己比对前后是否相同来判断有没有生效。
     */
    public static string upsert_keys (string original,
                                      GLib.HashTable<string, string> updates) {
        var doc = parse_doc (original);
        foreach (string k in updates.get_keys ())
            doc.set ("Desktop Entry", k, updates.lookup (k));
        return patch_original (original, doc);
    }

    /* ── 差异生成 ────────────────────────────────────────────────── */

    /**
     * 生成 unified diff（简化版：按行对比，输出 + / - 标记）。
     * 足够 UI 展示，不必实现完整 LCS。
     */
    public static string diff (string before, string after) {
        string[] a = before.split ("\n");
        string[] b = after.split ("\n");

        var sb = new GLib.StringBuilder ();

        // 最长公共前后缀裁剪，减少噪声
        int pre = 0;
        while (pre < a.length && pre < b.length && a[pre] == b[pre])
            pre++;
        int suf = 0;
        while (suf < a.length - pre && suf < b.length - pre
               && a[a.length - 1 - suf] == b[b.length - 1 - suf])
            suf++;

        if (pre > 0) {
            for (int i = 0; i < pre; i++)
                sb.append ("  %s\n".printf (a[i]));
        }

        for (int i = pre; i < a.length - suf; i++)
            sb.append ("- %s\n".printf (a[i]));
        for (int i = pre; i < b.length - suf; i++)
            sb.append ("+ %s\n".printf (b[i]));

        if (suf > 0) {
            sb.append ("  …（%d 行未变）\n".printf (suf));
        }

        return sb.str;
    }

    /* ── 执行 ────────────────────────────────────────────────────── */

    public class ExecResult {
        public int total = 0;
        public int done = 0;
        public int failed = 0;
        public int skipped = 0;
        public string txid = "";
        public string[] messages = {};
        public bool rolled_back = false;
    }

    /**
     * 执行一批修复。
     *
     * @param plans 已生成 proposed_content 的计划
     * @param cfg   配置（备份开关、失败策略）
     */
    public static ExecResult execute (RepairPlan[] plans, AppConfig cfg) {
        var res = new ExecResult ();
        var tx = new Journal.Tx ();
        tx.txid = new_txid ();
        tx.operation = "repair";
        tx.mode = plans.length > 0 ? mode_name (plans[0].mode) : "conservative";
        tx.started_at = now_iso ();

        // ── 备份 ─────────────────────────────────────────────
        var items = new GenericArray<Journal.Item> ();
        if (cfg.backup_enabled ()) {
            foreach (var p in plans) {
                var it = Backup.backup_file (tx, p.entry.file_path);
                items.add (it);
            }
        } else {
            foreach (var p in plans) {
                var it = new Journal.Item ();
                it.orig_path = p.entry.file_path;
                it.new_path = p.entry.file_path;
                it.status = "skipped";
                items.add (it);
            }
        }

        // 补齐 actions
        for (int i = 0; i < plans.length; i++) {
            var acts = new GenericArray<string> ();
            if (cfg.backup_enabled ()) acts.add ("backup");
            if (plans[i].target_basename () != GLib.Path.get_basename (plans[i].entry.file_path))
                acts.add ("rename");
            if (plans[i].claim) acts.add ("claim");
            if (plans[i].rules_fired != null && plans[i].rules_fired.length > 0)
                acts.add ("fix");
            items[i].actions = acts.steal ();
            items[i].rules_fired = plans[i].rules_fired ?? new string[0];
        }

        // steal() 会清空 GenericArray，先留一份数组引用给下面的逐项循环用
        var item_arr = items.steal ();
        tx.set_items (item_arr);
        tx.write_journal ();          // ← WAL 落盘起点

        // ── 逐项提交 ─────────────────────────────────────────
        var msgs = new GenericArray<string> ();
        bool rollback = false;
        int item_idx = 0;

        foreach (var p in plans) {
            if (rollback)
                break;
            if (item_idx >= item_arr.length)
                break;

            int64 t0 = GLib.get_monotonic_time ();
            var it = item_arr[item_idx];
            item_idx++;

            // 目标路径（可能因重命名而不同）
            string target = p.target_path ();

            // 预校验
            string verr = DesktopFiles.validate_content (p.proposed_content);
            if (verr != "") {
                it.status = "failed";
                it.error = "校验未通过: " + verr;
                msgs.add ("%s —— %s".printf (GLib.Path.get_basename (p.entry.file_path), it.error));
                it.duration_ms = (GLib.get_monotonic_time () - t0) / 1000;
                tx.write_journal ();
                res.failed++;
                if (cfg.rollback_on_failure ())
                    rollback = true;
                continue;
            }

            string? werr;
            DesktopFiles.write_atomic (target, p.proposed_content, out werr);
            if (werr != null) {
                it.status = "failed";
                it.error = werr ?? "写入失败";
                msgs.add ("%s —— %s".printf (GLib.Path.get_basename (p.entry.file_path), it.error));
                it.duration_ms = (GLib.get_monotonic_time () - t0) / 1000;
                tx.write_journal ();
                res.failed++;
                if (cfg.rollback_on_failure ())
                    rollback = true;
                continue;
            }

            // 原路径 != 目标路径 → 删除旧的
            if (target != p.entry.file_path) {
                GLib.FileUtils.unlink (p.entry.file_path);
            }

            it.new_path = target;
            it.sha256_after = sha256_of (target);
            it.status = "done";
            it.duration_ms = (GLib.get_monotonic_time () - t0) / 1000;
            tx.write_journal ();
            res.done++;
        }

        res.total = plans.length;
        res.skipped = res.total - res.done - res.failed;

        // ── 回滚 ─────────────────────────────────────────────
        if (rollback && res.done > 0) {
            msgs.add ("发生失败，正在回滚 %d 项…".printf (res.done));
            var rr = Backup.restore (tx, Backup.ConflictPolicy.OVERWRITE);
            foreach (string m in rr.messages)
                msgs.add ("  " + m);
            tx.mark_rolled_back ();
            res.rolled_back = true;
            res.done = 0;
        } else {
            tx.commit ();
        }

        res.txid = tx.txid;
        res.messages = msgs.steal ();
        return res;
    }

    /* ── 事务辅助（本地实现，避免依赖 journal.vala 的内部细节）───────── */

    /** 事务号：YYYYMMDDTHHMMSSZ-<随机尾巴>，与 journal 的排序假设一致 */
    private static string new_txid () {
        string stamp = new GLib.DateTime.now_utc ().format ("%Y%m%dT%H%M%SZ");
        string tail = "%08x".printf (GLib.Random.next_int ());
        return "%s-%s".printf (stamp, tail);
    }

    private static string now_iso () {
        return new GLib.DateTime.now_utc ().format_iso8601 ();
    }

    private static string sha256_of (string path) {
        string data;
        if (!GLib.FileUtils.get_contents (path, out data))
            return "";
        return GLib.Checksum.compute_for_string (GLib.ChecksumType.SHA256, data);
    }

    private static string mode_name (FixMode m) {
        switch (m) {
            case FixMode.CONSERVATIVE: return "conservative";
            case FixMode.ENRICH:       return "enrich";
            default:                   return "rebuild";
        }
    }

    /* ── 创建启动器（新建，不是修复）──────────────────────────────── */

    public class CreateResult {
        public int created = 0;
        public int skipped = 0;
        public int failed = 0;
        public string[] messages = {};
    }

    /**
     * 为一批「新发现」的 AppImage 创建 .desktop。
     * 已存在的会被跳过。
     */
    public static CreateResult create_launchers (
        AppEntry[] apps, AppConfig cfg, Store store) {

        var res = new CreateResult ();
        var msgs = new GenericArray<string> ();
        var tx = new Journal.Tx ();
        tx.txid = new_txid ();
        tx.operation = "create";
        tx.started_at = now_iso ();

        // 目标目录先确保存在：用户可能手工写了 config.ini 跳过首次运行
        // 向导，那样 ensure_core_dirs 就不会被调用。
        AppPath.ensure_dir (AppPath.applications_dir ());

        // 先从磁盘建一张「哪些 AppImage 已经有启动器」的索引。
        //
        // 不能只信 app.entry —— 那是 Store 扫描时的快照，可能过期；
        // 而且手工构造的 AppEntry（比如批量导入）根本没有 entry。
        // 以磁盘为准才能保证幂等。
        var existing = new GLib.HashTable<string, string> (GLib.str_hash, GLib.str_equal);
        foreach (var d in DesktopFiles.scan_directory (AppPath.applications_dir ())) {
            if (d.marker_path != "" && !existing.contains (d.marker_path))
                existing.insert (d.marker_path, d.file_path);
            if (d.exec_target != null && d.exec_target != ""
                && !existing.contains (d.exec_target))
                existing.insert (d.exec_target, d.file_path);
        }

        var items = new GenericArray<Journal.Item> ();
        int idx = 0;

        foreach (var app in apps) {
            // 已经有条目就跳过（先看 Store 快照，再落回磁盘索引）
            if (app.entry != null || existing.contains (app.path)) {
                res.skipped++;
                string nm = app.basename;
                msgs.add ("%s —— 已存在启动器，跳过".printf (nm));
                continue;
            }

            // 目标文件名，避免撞名
            string slug = app.get_slug ();
            string basename = DesktopFiles.unique_desktop_name (slug,
                DesktopFiles.scan_directory (AppPath.applications_dir ()), "");
            string target = GLib.Path.build_filename (AppPath.applications_dir (), basename);

            string content = DesktopFiles.build_content (
                app.path,
                app.meta_name != "" ? app.meta_name : app.display_name,
                app.generic_name,
                app.comment,
                app.icon_path ?? "",
                app.categories != "" ? app.categories : "Utility;",
                app.startup_wm_class != "" ? app.startup_wm_class
                    : (app.meta_name != "" ? app.meta_name : app.display_name),
                app.mimetype,
                cfg.write_marker (),
                "%U");

            string verr = DesktopFiles.validate_content (content);
            if (verr != "") {
                res.failed++;
                msgs.add ("%s —— 校验未通过: %s".printf (app.basename, verr));
                continue;
            }

            var it = new Journal.Item ();
            it.orig_path = target;
            it.new_path = target;
            it.actions = { "fix" };
            it.status = "pending";

            string? werr;
            DesktopFiles.write_atomic (target, content, out werr);
            if (werr != null) {
                res.failed++;
                msgs.add ("%s —— %s".printf (app.basename, werr ?? "写入失败"));
                continue;
            }

            it.status = "done";
            it.sha256_before = "";
            it.sha256_after = sha256_of (target);
            items.add (it);

            res.created++;
            idx++;
        }

        if (items.length == 0) {
            res.messages = msgs.steal ();
            return res;
        }

        tx.set_items (items.steal ());
        tx.write_journal ();
        tx.commit ();

        // 「删除启动器时同时删图标」—— 删完启动器，那个图标就没人引用了。
        //
        // 必须在删除之后做：remove_if_unreferenced 会扫描所有还存在的启动器
        // 确认没人再引用它。删之前扫，这个图标当然还被正在删的那份引用着，
        // 于是永远删不掉。
        //
        // 这里只回收本工具自己缓存目录里、且确实无人引用的图标；用户放在
        // 别处的图标一律不动。批量删除原先根本没接这个设置，于是「删除启动器
        // 时同时删图标」在批量场景下形同虚设（只在编辑对话框里生效）。
        if (cfg.delete_icon_with_launcher ()) {
            foreach (var a in apps)
                if (a.entry != null && a.entry.icon != null)
                    DesktopFiles.remove_if_unreferenced (a.entry.icon);
        }

        DesktopFiles.refresh_menu (cfg.should_update_database ());
        DesktopFiles.refresh_icon_cache (cfg.should_update_icon_cache ());

        res.messages = msgs.steal ();
        return res;
    }

    /* ── 删除 ────────────────────────────────────────────────────── */

    public static CreateResult delete_launchers (AppEntry[] apps, AppConfig cfg) {
        var res = new CreateResult ();
        var msgs = new GenericArray<string> ();
        var tx = new Journal.Tx ();
        tx.txid = new_txid ();
        tx.operation = "delete";
        tx.started_at = now_iso ();

        var items = new GenericArray<Journal.Item> ();

        foreach (var app in apps) {
            if (app.entry == null)
                continue;

            string path = app.entry.file_path;

            if (cfg.backup_enabled ()) {
                var it = Backup.backup_file (tx, path);
                it.actions = { "backup", "delete" };
                items.add (it);

                string? derr;
                if (!DesktopFiles.delete (path, out derr)) {
                    it.status = "failed";
                    it.error = derr ?? "删除失败";
                    res.failed++;
                    msgs.add ("%s —— %s".printf (app.basename, derr ?? ""));
                    continue;
                }
                it.status = "done";
            } else {
                string? derr;
                if (!DesktopFiles.delete (path, out derr)) {
                    res.failed++;
                    msgs.add ("%s —— %s".printf (app.basename, derr ?? ""));
                    continue;
                }
            }
            res.created++;   // 复用计数：实际删除数
        }

        if (items.length > 0) {
            tx.set_items (items.steal ());
            tx.write_journal ();
            tx.commit ();
        }

        DesktopFiles.refresh_menu (cfg.should_update_database ());
        res.messages = msgs.steal ();
        return res;
    }
}