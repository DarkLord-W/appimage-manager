/*
 * journal.vala — 事务日志（WAL）与崩溃恢复
 *
 * 两阶段提交：
 *   PREPARED  →  逐项执行  →  COMMITTED
 *
 * 磁盘上不存在半写状态的文件：每次写入都走 写临时文件 + fsync + rename。
 * 所以崩溃最坏的结果只是「部分已修、部分未修」，而不是「文件损坏」。
 */
namespace Journal {

    public const string STATUS_PREPARED  = "PREPARED";
    public const string STATUS_COMMITTED = "COMMITTED";
    public const string STATUS_ROLLED_BACK = "ROLLED_BACK";
    public const string STATUS_INTERRUPTED = "INTERRUPTED";

    /* ── 目录布局 ────────────────────────────────────────────────── */

    /** 崩溃残留的未完成事务：journal/<txid>.json */
    public string journal_dir () {
        return GLib.Path.build_filename (AppPath.data_root (), "journal");
    }

    /** 已归档的事务：history/<txid>/ */
    public string history_dir () {
        return GLib.Path.build_filename (AppPath.data_root (), "history");
    }

    public string history_tx_dir (string txid) {
        return GLib.Path.build_filename (history_dir (), txid);
    }

    public string index_path () {
        return GLib.Path.build_filename (history_dir (), "index.json");
    }

    /* ── 时间与标识 ──────────────────────────────────────────────── */

    /** txid 以时间戳开头，因此字典序倒序 = 时间倒序 */
    public string new_txid () {
        string stamp = new GLib.DateTime.now_utc ().format ("%Y%m%d-%H%M%S");
        return "%s-%04x".printf (stamp, (uint) (GLib.get_real_time () & 0xffff));
    }

    public string now_iso () {
        return new GLib.DateTime.now_utc ().format_iso8601 ();
    }

    /* ── JSON 辅助 ───────────────────────────────────────────────── */

    /**
     * 最小化的 JSON 字符串转义：反斜杠、引号与控制字符。
     *
     * 必须按**字节**遍历，不能用 s[i]。
     *
     * s[i] 取到的值在赋给 char 后是有符号的，而 char 是有符号 8 位 ——
     * UTF-8 里所有 >= 0x80 的字节（中文、日文、emoji 全都是）都成了负数，
     * 于是 (int) c < 0x20 判定成立，被当成控制字符转义成 \uffffffe5 这种
     * 非法序列。解析回来就是一堆替换字符。
     *
     * 这不是显示问题：崩溃恢复读的正是这份 JSON，路径一旦被破坏，
     * 还原就会找不到文件 —— 而事务日志恰恰是数据安全的最后一道防线。
     */
    private static string esc (string s) {
        if (s == null)
            return "";
        var sb = new GLib.StringBuilder ();
        for (int i = 0; i < s.length; i++) {
            // 关键：用 unichar（无符号）而不是 char（有符号）
            unichar c = s[i];
            if (c == '\\') {
                sb.append ("\\\\");
            } else if (c == '"') {
                sb.append ("\\\"");
            } else if (c == '\n') {
                sb.append ("\\n");
            } else if (c == '\r') {
                sb.append ("\\r");
            } else if (c == '\t') {
                sb.append ("\\t");
            } else if (c < 0x20) {
                sb.append ("\\u%04x".printf ((int) c));
            } else {
                // 非 ASCII 按原字节透传，UTF-8 序列原样保留
                sb.append_c ((char) c);
            }
        }
        return sb.str;
    }

    private static string arr (string[] items) {
        var sb = new GLib.StringBuilder ();
        sb.append_c ('[');
        if (items != null) {
            for (int i = 0; i < items.length; i++) {
                if (i > 0)
                    sb.append_c (',');
                sb.append_c ('"');
                sb.append (esc (items[i]));
                sb.append_c ('"');
            }
        }
        sb.append_c (']');
        return sb.str;
    }

    /* ── 校验和 ──────────────────────────────────────────────────── */

    /** 文件的 SHA-256，分块读取，避免把大文件整个读进内存 */
    public string sha256 (string path) {
        try {
            var ck = new GLib.Checksum (GLib.ChecksumType.SHA256);
            var fis = GLib.File.new_for_path (path).read (null);
            while (true) {
                GLib.Bytes chunk = fis.read_bytes (65536, null);
                uint8[]? data = chunk.get_data ();
                if (data == null || data.length == 0)
                    break;
                ck.update (data, data.length);
                if (chunk.get_size () < 65536)
                    break;
            }
            fis.close (null);
            return ck.get_string ();
        } catch {
            return "";
        }
    }

    public class Item {
        public string orig_path = "";
        public string new_path = "";
        public string backup_path = "";       // 相对 history/<txid>/
        public string sha256_before = "";
        public string sha256_after = "";
        public string[] actions = {};         // backup/fix/rename/extract_icon/claim
        public string[] rules_fired = {};
        public string status = "pending";     // pending / done / failed / skipped
        public string error = "";
        public int64 duration_ms = 0;
    }

    public class Tx : GLib.Object {
        public string txid = "";
        public string operation = "";
        public string mode = "";
        public string status = STATUS_PREPARED;
        public string started_at = "";
        public string finished_at = "";
        public string[] preserve_keys = {};
        public string[] drop_keys = {};
        public Item[] items = {};

        public int total () { return items.length; }

        public int done () {
            int n = 0;
            foreach (var i in items)
                if (i.status == "done") n++;
            return n;
        }

        public int failed () {
            int n = 0;
            foreach (var i in items)
                if (i.status == "failed") n++;
            return n;
        }

        public bool is_done () { return status == STATUS_COMMITTED; }

        public void set_items (Item[] its) {
            items = its;
        }

        /* ── WAL 写入 ─────────────────────────────────────────────── */

        /** 落盘 journal 并 fsync，这是「有据可查」的起点 */
        public void write_journal () {
            AppPath.ensure_dir (journal_dir ());
            string json = serialize ();
            string path = GLib.Path.build_filename (journal_dir (), "%s.json".printf (txid));
            write_fsync (path, json);
        }

        /** 更新单个条目的状态并立即落盘（崩溃时才知道进行到哪） */
        public void update_item (Item it) {
            write_journal ();
        }

        /** 提交：把 journal 挪进 history 并标记 COMMITTED */
        public void commit () {
            status = STATUS_COMMITTED;
            finished_at = now_iso ();
            string tx_dir = history_tx_dir (txid);
            AppPath.ensure_dir (tx_dir);
            write_fsync (GLib.Path.build_filename (tx_dir, "manifest.json"), serialize ());
            unlink (GLib.Path.build_filename (journal_dir (), "%s.json".printf (txid)));
            append_index (this);
        }

        /** 回滚完成 */
        public void mark_rolled_back () {
            status = STATUS_ROLLED_BACK;
            finished_at = now_iso ();
            string tx_dir = history_tx_dir (txid);
            AppPath.ensure_dir (tx_dir);
            write_fsync (GLib.Path.build_filename (tx_dir, "manifest.json"), serialize ());
            unlink (GLib.Path.build_filename (journal_dir (), "%s.json".printf (txid)));
            append_index (this);
        }

        /* ── JSON ─────────────────────────────────────────────────── */

        public string serialize () {
            var items_json = new GenericArray<string> ();
            foreach (var it in items) {
                items_json.add (
                    "{"
                    + "\"orig_path\":\"%s\",".printf (esc (it.orig_path))
                    + "\"new_path\":\"%s\",".printf (esc (it.new_path))
                    + "\"backup_path\":\"%s\",".printf (esc (it.backup_path))
                    + "\"sha256_before\":\"%s\",".printf (esc (it.sha256_before))
                    + "\"sha256_after\":\"%s\",".printf (esc (it.sha256_after))
                    + "\"actions\":%s,".printf (arr (it.actions))
                    + "\"rules_fired\":%s,".printf (arr (it.rules_fired))
                    + "\"status\":\"%s\",".printf (esc (it.status))
                    + "\"error\":\"%s\",".printf (esc (it.error))
                    + "\"duration_ms\":%lld".printf (it.duration_ms)
                    + "}");
            }

            return "{"
                + "\"schema\":1,"
                + "\"txid\":\"%s\",".printf (esc (txid))
                + "\"operation\":\"%s\",".printf (esc (operation))
                + "\"mode\":\"%s\",".printf (esc (mode))
                + "\"status\":\"%s\",".printf (esc (status))
                + "\"started_at\":\"%s\",".printf (esc (started_at))
                + "\"finished_at\":\"%s\",".printf (esc (finished_at))
                + "\"preserve_keys\":%s,".printf (arr (preserve_keys))
                + "\"drop_keys\":%s,".printf (arr (drop_keys))
                + "\"items\":[%s]".printf (string.joinv (",", items_json.steal ()))
                + "}";
        }

        /* ── 反序列化 ─────────────────────────────────────────────── */

        public static Tx? from_json (string json) {
            try {
                var parser = new Json.Parser ();
                if (!parser.load_from_data (json, (ssize_t) json.length))
                    return null;
                Json.Node? root_node = parser.get_root ();
                if (root_node == null)
                    return null;
                var root = root_node.get_object ();
                var tx = new Tx ();
                tx.txid         = root.get_string_member ("txid");
                tx.operation    = root.get_string_member ("operation");
                tx.mode         = root.get_string_member ("mode");
                tx.status       = root.get_string_member ("status");
                tx.started_at   = root.get_string_member ("started_at");
                tx.finished_at  = root.get_string_member ("finished_at");
                tx.preserve_keys = str_array (root, "preserve_keys");
                tx.drop_keys     = str_array (root, "drop_keys");

                var items = new GenericArray<Item> ();
                Json.Array? arr_node = root.get_array_member ("items");
                if (arr_node != null) {
                    for (int i = 0; i < arr_node.get_length (); i++) {
                        var io = arr_node.get_element (i).get_object ();
                        var it = new Item ();
                        it.orig_path     = io.get_string_member ("orig_path");
                        it.new_path      = io.get_string_member ("new_path");
                        it.backup_path   = io.get_string_member ("backup_path");
                        it.sha256_before = io.get_string_member ("sha256_before");
                        it.sha256_after  = io.get_string_member ("sha256_after");
                        it.actions       = str_array (io, "actions");
                        it.rules_fired   = str_array (io, "rules_fired");
                        it.status        = io.get_string_member ("status");
                        it.error         = io.get_string_member ("error");
                        it.duration_ms   = io.get_int_member ("duration_ms");
                        items.add (it);
                    }
                }
                tx.set_items (items.steal ());
                return tx;
            } catch {
                return null;
            }
        }

        private static string[] str_array (Json.Object o, string key) {
            var list = new GenericArray<string> ();
            try {
                if (o.has_member (key)) {
                    Json.Array? a = o.get_array_member (key);
                    if (a != null) {
                        for (int i = 0; i < a.get_length (); i++)
                            list.add (a.get_element (i).get_string ());
                    }
                }
            } catch {}
            return list.steal ();
        }
    }

    /* ── 崩溃恢复 ────────────────────────────────────────────────── */

    /** 找出所有未完成的事务 */
    public static Tx[] pending () {
        var list = new GenericArray<Tx> ();
        string dir = journal_dir ();
        if (!AppPath.is_dir (dir))
            return list.steal ();

        try {
            var de = GLib.Dir.open (dir, 0);
            string? n;
            while ((n = de.read_name ()) != null) {
                if (!n.has_suffix (".json"))
                    continue;
                string path = GLib.Path.build_filename (dir, n);
                string json;
                if (!GLib.FileUtils.get_contents (path, out json))
                    continue;
                var tx = Tx.from_json (json);
                if (tx != null && tx.status != STATUS_COMMITTED)
                    list.add (tx);
            }
        } catch {}

        return list.steal ();
    }

    /** 丢弃一份中断的 journal（保留现状并归档） */
    public static void archive_interrupted (Tx tx) {
        tx.status = STATUS_INTERRUPTED;
        tx.finished_at = now_iso ();
        string tx_dir = history_tx_dir (tx.txid);
        AppPath.ensure_dir (tx_dir);
        write_fsync (GLib.Path.build_filename (tx_dir, "manifest.json"), tx.serialize ());
        unlink (GLib.Path.build_filename (journal_dir (), "%s.json".printf (tx.txid)));
        append_index (tx);
    }

    /* ── 索引 ────────────────────────────────────────────────────── */

    public static void append_index (Tx tx) {
        string existing = "";
        try {
            GLib.FileUtils.get_contents (index_path (), out existing);
        } catch {}

        string entry = ("{\"txid\":\"%s\",\"op\":\"%s\",\"mode\":\"%s\",\"status\":\"%s\",\"at\":\"%s\",\"total\":%d,\"done\":%d}"
            .printf (esc (tx.txid), esc (tx.operation), esc (tx.mode),
                     esc (tx.status), esc (tx.started_at), tx.total (), tx.done ()));

        string all = "[" + entry + "]";
        string body = existing == null ? "" : existing.strip ();
        if (body != "" && body != "[]") {
            if (body.has_prefix ("["))
                body = body.substring (1);
            if (body.has_suffix ("]"))
                body = body.substring (0, body.length - 1);
            all = "[" + entry + "," + body + "]";
        }
        AppPath.ensure_dir (history_dir ());
        write_fsync (index_path (), all);
    }

    /* ── 低层 I/O ────────────────────────────────────────────────── */

    private static void write_fsync (string path, string content) {
        string tmp = "%s.tmp%u".printf (path, (uint) (GLib.get_real_time () % 1000000));
        try {
            GLib.FileUtils.set_contents (tmp, content);
            DesktopFiles.sync_dir (GLib.Path.get_dirname (path));
            if (GLib.FileUtils.rename (tmp, path) != 0) {
                unlink (tmp);
                warning (I18n.s ("journal 重命名失败: %s → %s"), tmp, path);
            }
        } catch (GLib.Error e) {
            warning (I18n.s ("journal 写入失败: %s"), e.message);
            unlink (tmp);
        }
    }

    private static void unlink (string path) {
        if (path == null || path == "")
            return;
        if (GLib.FileUtils.test (path, GLib.FileTest.EXISTS))
            AppPath.file_remove (path);
    }

    /* ── 保留策略 ────────────────────────────────────────────────── */

    /** 按天清理旧备份，跳过未还原的事务 */
    public static int apply_retention (AppConfig cfg) {
        if (!cfg.backup_enabled ())
            return 0;

        string dir = history_dir ();
        if (!AppPath.is_dir (dir))
            return 0;

        var entries = new GenericArray<string> ();
        try {
            var de = GLib.Dir.open (dir, 0);
            string? n;
            while ((n = de.read_name ()) != null) {
                if (AppPath.is_dir (GLib.Path.build_filename (dir, n)))
                    entries.add (n);
            }
        } catch { return 0; }

        // 按名字倒序 = 时间倒序（txid 以时间戳开头）
        entries.sort ((a, b) => strcmp (b, a));
        var arr = entries.steal ();

        int max_tx = cfg.retention_tx ();
        int max_days = cfg.retention_days ();
        var now = new GLib.DateTime.now_utc ();
        int removed = 0;

        for (int i = 0; i < arr.length; i++) {
            string txid = arr[i];
            if (txid.length < 15)
                continue;
            bool over_count = (i >= max_tx);
            bool over_age = false;

            var dt = new GLib.DateTime.from_iso8601 (txid.substring (0, 4)
                + "-" + txid.substring (4, 2) + "-" + txid.substring (6, 2)
                + "T" + txid.substring (9, 2) + ":" + txid.substring (11, 2)
                + ":" + txid.substring (13, 2) + "Z", null);
            if (dt != null) {
                int days = (int) (now.difference ((!) dt) / (int64) GLib.TimeSpan.DAY);
                if (days > max_days)
                    over_age = true;
            }

            if (!over_count && !over_age)
                break;

            // 已提交但未还原的事务跳过
            string manifest = GLib.Path.build_filename (history_tx_dir (txid), "manifest.json");
            if (AppPath.exists (manifest)) {
                string json;
                try {
                    if (GLib.FileUtils.get_contents (manifest, out json)) {
                        var tx = Tx.from_json (json);
                        if (tx != null && tx.status == STATUS_COMMITTED)
                            continue;   // 保留，除非用户显式清理
                    }
                } catch {}
            }

            AppImageInfo.rm_rf (history_tx_dir (txid));
            removed++;
        }
        return removed;
    }
}