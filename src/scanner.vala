/*
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
            var header = new uint8[10];
            size_t n = stream.read_bytes (header, 0, 10, null);

            if (n < 10)
                return false;

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
        string lower = basename.to_lower ();
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
                errors.add ("%s —— 目录不存在".printf (AppPath.shorten (dir)));
                continue;
            }
            res.scanned_dirs++;
            walk (dir, recursive, found, rejected, errors, seen);
        }

        res.found = (owned) found.to_array ();
        res.rejected = (owned) rejected.to_array ();
        res.errors = (owned) errors.to_array ();
        return res;
    }

    private void walk (string dir, bool recursive,
                       GenericArray<string> found,
                       GenericArray<string> rejected,
                       GenericArray<string> errors,
                       GenericArray<string> seen) {

        if (seen.contains (dir))
            return;
        seen.add (dir);

        GLib.Dir dir_enum;
        try {
            dir_enum = GLib.Dir.open (dir, 0);
        } catch (GLib.Error e) {
            errors.add ("%s —— 无法读取（%s）".printf (AppPath.shorten (dir), e.message));
            return;
        }

        string? name;
        while ((name = dir_enum.read_name ()) != null) {
            string full = GLib.build_filename (dir, name);

            // 不跟随符号链接，避免软链接环与越权访问
            var info = GLib.FileUtils.lstat (full);
            if (info == null)
                continue;

            if (info.file_type == GLib.FileType.DIRECTORY) {
                if (recursive)
                    walk (full, recursive, found, rejected, errors, seen);
                continue;
            }

            if (info.file_type != GLib.FileType.REGULAR)
                continue;

            if (!has_appimage_extension (name))
                continue;

            // 同名文件可能被多个扫描目录覆盖，用 realpath 去重
            string canonical = AppPath.canonical (full);
            if (found.contains (canonical) || rejected.contains (canonical))
                continue;

            if (is_appimage (full))
                found.add (full);
            else
                rejected.add (full);
        }

        dir_enum.close ();
    }
}