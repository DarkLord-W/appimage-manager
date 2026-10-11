/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 DarkLord-W
 *
 * backup.vala — 备份存储、历史查询与还原
 *
 * 布局：
 *   history/<txid>/manifest.json      事务元数据
 *   history/<txid>/file/<name>         原文件逐字节副本
 *   history/<txid>/icon/<slug>.<ext>   图标快照
 *
 * 历史是追加式的：还原本身也是一条新记录（operation=rollback, undo_of=<txid>）。
 */
namespace Backup {

    /* ── 写入备份 ────────────────────────────────────────────────── */

    public static Journal.Item backup_file (Journal.Tx tx, string path) {
        var it = new Journal.Item ();
        it.orig_path = path;
        it.new_path = path;
        it.status = "pending";

        if (!AppPath.exists (path)) {
            it.status = "skipped";
            return it;
        }

        string backup_dir = GLib.Path.build_filename (
            Journal.history_tx_dir (tx.txid), "file");
        if (!AppPath.ensure_dir (backup_dir)) {
            it.status = "failed";
            it.error = I18n.s ("无法创建备份目录");
            return it;
        }

        string dest = GLib.Path.build_filename (backup_dir, GLib.Path.get_basename (path));
        try {
            AppPath.file_copy (path, dest, true);
            DesktopFiles.sync_dir (backup_dir);
            it.backup_path = "file/" + GLib.Path.get_basename (path);
            it.sha256_before = Journal.sha256 (path);
            it.status = "pending";
        } catch (GLib.Error e) {
            it.status = "failed";
            it.error = I18n.s ("备份失败: %s").printf (e.message);
        }
        return it;
    }

    public static void backup_icon (Journal.Tx tx, string icon_path) {
        if (!AppPath.exists (icon_path))
            return;
        string dir = GLib.Path.build_filename (Journal.history_tx_dir (tx.txid), "icon");
        if (!AppPath.ensure_dir (dir))
            return;
        try {
            AppPath.file_copy (icon_path,
                GLib.Path.build_filename (dir, GLib.Path.get_basename (icon_path)), true);
        } catch {}
    }

    /* ── 读取备份 ────────────────────────────────────────────────── */

    public static string backup_file_path (Journal.Tx tx, Journal.Item it) {
        if (it.backup_path == "")
            return "";
        return GLib.Path.build_filename (Journal.history_tx_dir (tx.txid), it.backup_path);
    }

    public static bool backup_intact (Journal.Tx tx, Journal.Item it, out bool file_matches) {
        file_matches = false;
        string bp = backup_file_path (tx, it);
        if (bp == "" || !AppPath.exists (bp))
            return false;

        if (Journal.sha256 (bp) != it.sha256_before)
            return false;

        // 当前磁盘文件是否还是我们修复后的那个
        if (AppPath.exists (it.new_path) && it.sha256_after != "")
            file_matches = Journal.sha256 (it.new_path) == it.sha256_after;

        return true;
    }

    /* ── 还原 ────────────────────────────────────────────────────── */

    public enum ConflictPolicy {
        OVERWRITE,   // 直接用备份覆盖
        SKIP,        // 跳过
        STASH        // 另存当前内容后再覆盖（默认）
    }

    public class RestoreResult {
        public int restored = 0;
        public int skipped = 0;
        public int failed = 0;
        public string[] messages = {};

        public void log (string m) {
            var l = new GenericArray<string> ();
            foreach (string s in messages) l.add (s);
            l.add (m);
            messages = l.steal ();
        }
    }

    /**
     * 还原一个事务。
     * 原路径与新路径不同的条目（重命名过）会先移回再删除。
     */
    public static RestoreResult restore (Journal.Tx tx, ConflictPolicy policy) {
        var res = new RestoreResult ();

        // 空事务要明确说出来。Backup.backup_file() 只是返回一个 Item，
        // 还得调用方自己 set_items() 塞回去 —— 调用方一漏，这里原本
        // 会什么都不做然后报「成功」，用户以为还原了其实文件没动过。
        if (tx == null || tx.items.length == 0) {
            res.failed++;
            res.log (I18n.s ("这个事务没有可还原的条目")
                     + I18n.s ("（创建类的操作只记录了「新建了什么」，没有旧内容可还原）。"));
            return res;
        }

        foreach (var it in tx.items) {
            bool file_matches;
            if (!backup_intact (tx, it, out file_matches)) {
                res.failed++;
                res.log (I18n.s ("%s —— 备份缺失或校验不通过").printf (GLib.Path.get_basename (it.orig_path)));
                continue;
            }

            if (!file_matches && AppPath.exists (it.new_path)) {
                // 修复后被人改过
                switch (policy) {
                    case ConflictPolicy.SKIP:
                        res.skipped++;
                        res.log (I18n.s ("%s —— 修复后被修改过，按设置跳过").printf (GLib.Path.get_basename (it.new_path)));
                        continue;
                    case ConflictPolicy.STASH: {
                        string stash = "%s.modified-%s".printf (
                            it.new_path, stamp_now ());
                        if (GLib.FileUtils.rename (it.new_path, stash) != 0) {
                            res.failed++;
                            res.log (I18n.s ("%s —— 无法另存当前内容").printf (GLib.Path.get_basename (it.new_path)));
                            continue;
                        }
                        res.log (I18n.s ("%s —— 当前内容已另存为 %s")
                            .printf (GLib.Path.get_basename (it.new_path),
                                     GLib.Path.get_basename (stash)));
                        break;
                    }
                    default:
                        break;
                }
            }

            string bp = backup_file_path (tx, it);
            string content;
            bool read_ok;
            try {
                read_ok = GLib.FileUtils.get_contents (bp, out content);
            } catch {
                read_ok = false;
            }
            if (!read_ok) {
                res.failed++;
                continue;
            }

            // 认领操作的还原：移除本工具加的标记键
            if (has_action (it.actions, "claim"))
                content = strip_markers (content);

            string? err;
            if (it.new_path != it.orig_path && AppPath.exists (it.new_path)) {
                // 先把新路径挪走，再把备份写回原路径
                if (GLib.FileUtils.rename (it.new_path, it.new_path + ".pre-restore") != 0) {
                    res.failed++;
                    res.log (I18n.s ("%s —— 无法清理重命名后的文件").printf (GLib.Path.get_basename (it.new_path)));
                    continue;
                }
            }

            DesktopFiles.write_atomic (it.orig_path, content, out err);
            if (err != null) {
                res.failed++;
                res.log (I18n.s ("%s —— 还原写入失败: %s").printf (
                    GLib.Path.get_basename (it.orig_path), err));
                continue;
            }

            res.restored++;
            it.status = "pending";   // 标记为待重新处理
        }

        // 图标处理
        restore_icons (tx, res);

        return res;
    }

    /** 图标：本次创建的若无其它引用则删除；本次删除的恢复到原位 */
    private static void restore_icons (Journal.Tx tx, RestoreResult res) {
        string icon_dir = GLib.Path.build_filename (Journal.history_tx_dir (tx.txid), "icon");
        if (!AppPath.is_dir (icon_dir))
            return;

        // 找出修复后当前使用的图标
        foreach (var it in tx.items) {
            if (!has_action (it.actions, "extract_icon"))
                continue;
            var e = DesktopFiles.parse (it.orig_path);
            if (e == null || e.icon == "" || !e.icon.has_prefix ("/"))
                continue;
            if (!AppPath.exists (e.icon))
                continue;
            if (!icon_referenced_elsewhere (e.icon, it.orig_path))
                AppPath.file_remove (e.icon);
        }

        // 恢复被删除的图标
        try {
            var de = GLib.Dir.open (icon_dir, 0);
            string? n;
            while ((n = de.read_name ()) != null) {
                // 目标：hicolor 下的原图标目录（从 desktop 的 Icon 键判断）
                res.log (I18n.s ("%s —— 图标快照已保留在 %s").printf (
                    n, AppPath.shorten (icon_dir)));
            }
        } catch {}
    }

    private static bool icon_referenced_elsewhere (string icon_path, string exclude_desktop) {
        foreach (var d in DesktopFiles.scan_directory (AppPath.applications_dir ())) {
            if (d.file_path == exclude_desktop)
                continue;
            if (d.icon == icon_path)
                return true;
        }
        return false;
    }

    private static bool has_action (string[] actions, string want) {
        foreach (string a in actions)
            if (a == want)
                return true;
        return false;
    }

    /** 从内容里移除本工具添加的标记键 */
    private static string strip_markers (string content) {
        var sb = new GLib.StringBuilder ();
        foreach (string line in content.split ("\n")) {
            string t = line.strip ();
            if (t.has_prefix (DesktopFiles.MARKER_BOOL + "=")
             || t.has_prefix (DesktopFiles.MARKER_PATH + "=")
             || t.has_prefix (DesktopFiles.MARKER_VERSION + "="))
                continue;
            sb.append (line);
            sb.append_c ('\n');
        }
        return sb.str;
    }

    private static string stamp_now () {
        return new GLib.DateTime.now_local ().format ("%Y%m%d-%H%M%S");
    }

    /* ── 历史列表 ────────────────────────────────────────────────── */

    public class HistoryEntry {
        public string txid = "";
        public string operation = "";
        public string mode = "";
        public string status = "";
        public string started_at = "";
        public int total = 0;
        public int done = 0;
        public bool undone = false;

        public string display_op () {
            switch (operation) {
                case "repair":   return I18n.s ("批量修复");
                case "create":   return I18n.s ("创建");
                case "delete":   return I18n.s ("删除");
                case "claim":    return I18n.s ("认领");
                case "unclaim":  return I18n.s ("取消认领");
                case "rollback": return I18n.s ("已还原");
                default:         return operation;
            }
        }

        public string display_time () {
            if (started_at.length < 16)
                return started_at;
            return started_at.substring (0, 16).replace ("T", " ");
        }
    }

    public static HistoryEntry[] list_history () {
        var list = new GenericArray<HistoryEntry> ();
        string dir = Journal.history_dir ();
        if (!AppPath.is_dir (dir))
            return list.steal ();

        var names = new GenericArray<string> ();
        try {
            var de = GLib.Dir.open (dir, 0);
            string? n;
            while ((n = de.read_name ()) != null) {
                if (AppPath.is_dir (GLib.Path.build_filename (dir, n)))
                    names.add (n);
            }
        } catch { return list.steal (); }

        names.sort ((a, b) => strcmp (b, a));   // 时间倒序
        var arr = names.steal ();

        foreach (string txid in arr) {
            string manifest = GLib.Path.build_filename (Journal.history_tx_dir (txid), "manifest.json");
            if (!AppPath.exists (manifest))
                continue;
            string json;
            try {
                if (!GLib.FileUtils.get_contents (manifest, out json))
                    continue;
            } catch {
                continue;
            }
            var tx = Journal.Tx.from_json (json);
            if (tx == null)
                continue;
            var h = new HistoryEntry ();
            h.txid = tx.txid;
            h.operation = tx.operation;
            h.mode = tx.mode;
            h.status = tx.status;
            h.started_at = tx.started_at;
            h.total = tx.total ();
            h.done = tx.done ();
            list.add (h);
        }

        return list.steal ();
    }

    public static Journal.Tx? load_tx (string txid) {
        string manifest = GLib.Path.build_filename (Journal.history_tx_dir (txid), "manifest.json");
        if (!AppPath.exists (manifest))
            return null;
        try {
            string json;
            if (!GLib.FileUtils.get_contents (manifest, out json))
                return null;
            return Journal.Tx.from_json (json);
        } catch {
            return null;
        }
    }

    /** 取回原文件内容，供差异对比 */
    public static string? get_original (string txid, Journal.Item it) {
        var tx = load_tx (txid);
        if (tx == null)
            return null;
        string bp = backup_file_path (tx, it);
        if (bp == "" || !AppPath.exists (bp))
            return null;
        try {
            string content;
            if (!GLib.FileUtils.get_contents (bp, out content))
                return null;
            return content;
        } catch {
            return null;
        }
    }
}