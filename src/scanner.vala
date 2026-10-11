/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 DarkLord-W
 *
 * scanner.vala — 递归扫描 AppImage 文件
 *
 * 扫描器做两件事：
 *   1. 递归遍历配置的目录，收集候选文件
 *   2. 对候选文件做 ELF 魔数校验，剔除「改名成 .AppImage 的假货」
 */
namespace Scanner {

    /**
     * 判定一个文件是否真的是 AppImage。
     *
     * AppImage Type 2 的结构：
     *   偏移 0x00: 7F 45 4C 46            ELF magic
     *   偏移 0x08: 41 49                  "AI" magic
     * 同时要求具备可执行位。
     */
    public bool is_appimage (string path) {
        try {
            var file = GLib.File.new_for_path (path);
            var stream = file.read (null);
            GLib.Bytes bytes = stream.read_bytes (10, null);

            if (bytes.get_size () < 10)
                return false;

            // 取出拷贝再用：get_data() 返回的是 const 视图
            uint8[] header = GLib.Bytes.unref_to_data ((owned) bytes);

            // ELF magic
            if (header[0] != 0x7f || header[1] != 0x45
             || header[2] != 0x4c || header[3] != 0x46)
                return false;

            // AppImage magic at offset 8
            if (header[8] != 0x41 || header[9] != 0x49)
                return false;

            return true;
        } catch {
            return false;
        }
    }

    /** 判断扩展名是否像 AppImage（用于快速筛选候选） */
    public bool has_appimage_extension (string basename) {
        string lower = basename.down ();
        string[] suffixes = { ".appimage", ".appimage.zsync" };
        foreach (string s in suffixes)
            if (lower.has_suffix (s))
                return true;
        return false;
    }

    /** 扫描结果 */
    public class Result {
        public string[] found = {};       // 通过校验的真实 AppImage
        public string[] rejected = {};    // 扩展名像但校验不过
        public string[] errors = {};      // 无法读取的目录等
        public int scanned_dirs = 0;
    }

    /**
     * 递归扫描目录树。
     *
     * @param dirs   根目录列表
     * @param recursive 是否进入子目录
     */
    public Result scan (string[] dirs, bool recursive) {
        var res = new Result ();
        var found = new GenericArray<string> ();
        var rejected = new GenericArray<string> ();
        var errors = new GenericArray<string> ();
        var seen = new GenericArray<string> ();

        foreach (string dir in dirs) {
            if (!AppPath.is_dir (dir)) {
                errors.add (I18n.s ("%s —— 目录不存在").printf (AppPath.shorten (dir)));
                continue;
            }
            res.scanned_dirs++;
            walk (dir, recursive, found, rejected, errors, seen);
        }

        res.found = to_array (found);
        res.rejected = to_array (rejected);
        res.errors = to_array (errors);
        return res;
    }

    /** GenericArray → string[]；比 steal() 少一层指针强转 */
    private string[] to_array (GenericArray<string> arr) {
        string[] out = {};
        for (int i = 0; i < arr.length; i++)
            out += arr.get ((uint) i);
        return out;
    }

    /**
     * GenericArray<string> 没有可用的 contains()。
     *
     * 注意：不能用 find()，它落到 g_ptr_array_find，是按指针比较，
     * 字符串永远匹配不上。这里显式按内容逐个比较。
     */
    private bool arr_contains (GenericArray<string> arr, string needle) {
        for (int i = 0; i < arr.length; i++) {
            if (arr.get ((uint) i) == needle)
                return true;
        }
        return false;
    }

    private void walk (string dir, bool recursive,
                       GenericArray<string> found,
                       GenericArray<string> rejected,
                       GenericArray<string> errors,
                       GenericArray<string> seen) {

        if (arr_contains (seen, dir))
            return;
        seen.add (dir);

        GLib.Dir dir_enum;
        try {
            dir_enum = GLib.Dir.open (dir, 0);
        } catch (GLib.Error e) {
            errors.add (I18n.s ("%s —— 无法读取（%s）").printf (AppPath.shorten (dir), e.message));
            return;
        }

        string? name;
        while ((name = dir_enum.read_name ()) != null) {
            string full = GLib.Path.build_filename (dir, name);

            // 不跟随符号链接，避免软链接环与越权访问
            var info = AppPath.file_lstat (full);
            if (info == null)
                continue;

            if (info.get_file_type () == GLib.FileType.DIRECTORY) {
                if (recursive)
                    walk (full, recursive, found, rejected, errors, seen);
                continue;
            }

            if (info.get_file_type () != GLib.FileType.REGULAR)
                continue;

            if (!has_appimage_extension (name))
                continue;

            // 同名文件可能被多个扫描目录覆盖，用 realpath 去重
            string canonical = AppPath.canonical (full);
            if (arr_contains (found, canonical) || arr_contains (rejected, canonical))
                continue;

            if (is_appimage (full))
                found.add (full);
            else
                rejected.add (full);
        }
    }
}