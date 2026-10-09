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

        bool enrich = plan.mode == FixMode.ENRICH
                   || plan.mode == FixMode.REBUILD;

        if (enrich && fires ("I001")) {
            string icon = plan.app.icon_path ?? "";
            if (icon != "") {
                doc.set (DE, "Icon", icon);
                fired.add ("I001");
            }
        }
        if (enrich && fires ("I002") && !doc.has (DE, "Categories")) {
            doc.set (DE, "Categories", plan.app.categories != ""
                ? plan.app.categories : "Utility;");
            fired.add ("I002");
        }
        if (enrich && fires ("I003") && !doc.has (DE, "StartupWMClass")) {
            doc.set (DE, "StartupWMClass", plan.app.startup_wm_class != ""
                ? plan.app.startup_wm_class : plan.app.get_best_name ());
            fired.add ("I003");
        }
        if (enrich && fires ("I004") && !doc.has (DE, "Comment") && plan.app.comment != "") {
            doc.set (DE, "Comment", plan.app.comment);
            fired.add ("I004");
        }
        if (enrich && fires ("I010") && !doc.has (DE, "TryExec")) {
            doc.set (DE, "TryExec", plan.app.path);
            fired.add ("I010");
        }
        if (enrich && fires ("C001") && !doc.has (DE, "GenericName")) {
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
        plan.proposed_content = doc.to_text ();
        return plan.proposed_content;
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

        var items = new GenericArray<Journal.Item> ();
        int idx = 0;

        foreach (var app in apps) {
            // 已经有条目就跳过
            if (app.entry != null) {
                res.skipped++;
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