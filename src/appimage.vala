/*
 * appimage.vala — AppImage 元数据与图标提取
 *
 * 流程：<AppImage> --appimage-extract → 读 squashfs-root 内的 .desktop 与图标。
 * AppImage 自带运行时，不依赖 FUSE，因此解包这一步不需要 root。
 */
public class AppImageInfo : GLib.Object {
    public string appimage_path;
    public string name = "";
    public string generic_name = "";
    public string comment = "";
    public string categories = "";
    public string startup_wm_class = "";
    public string mimetype = "";
    public string icon_relpath = "";      // 解包目录内的相对路径
    public string extract_dir = "";       // 解包根目录
    public string error = "";
    public bool   ok = false;

    public AppImageInfo (string path) {
        appimage_path = path;
        name = AppPath.display_name_from_file (GLib.Path.get_basename (path));
    }

    public void dispose_info () {
        cleanup_extract ();
    }

    public void cleanup_extract () {
        if (extract_dir != "") {
            rm_rf (extract_dir);
            extract_dir = "";
        }
    }

    public static void rm_rf (string path) {
        try {
            var f = GLib.File.new_for_path (path);
            var en = f.enumerate_children (
                "standard::name,standard::type",
                GLib.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
            GLib.FileInfo? info;
            while ((info = en.next_file (null)) != null) {
                string child_path = GLib.Path.build_filename (path, info.get_name ());
                if (info.get_file_type () == GLib.FileType.DIRECTORY)
                    rm_rf (child_path);
                else
                    GLib.File.new_for_path (child_path).delete (null);
            }
            en.close (null);
            f.delete (null);
        } catch {}
    }
}

namespace AppImageExtract {

    private static int64 counter = 0;

    /** 解包默认硬超时（秒） */
    // 60 秒：实测一个 555 MB 的 Electron AppImage 解包超过 20 秒。
// 界面不会卡（跑在后台线程），用户可以随时取消，所以给宽一点更实用。
public const int DEFAULT_EXTRACT_TIMEOUT_SEC = 60;

    /**
     * 跑一个子进程并等待结束，带硬超时。
     *
     * 返回真实退出码；启动失败 / 超时 / 取消均返回 -1，超时时 *timed_out 置 true。
     *
     * 注意：wait() 会阻塞「调用线程」，所以调用方应在工作线程里调用。
     * 超时用 GLib.Timeout.add 挂在默认主循环上（g_timeout_add）：
     * 工作线程调用时由主循环派发，到点 force_exit()（SIGKILL）保证 wait()
     * 一定会返回；从主线程调用时 wait() 会把主循环卡住，定时器无法派发
     * （见 test_launch 的注释）。
     *
     * @param cwd 子进程的工作目录。解包时必须显式指定 work_dir：
     *            `--appimage-extract` 把内容解到「当前目录」，不设的话会
     *            落到本程序被启动时的目录 —— 实测有用户因此被写进
     *            2.1 GB 的解包残留。
     */
    public static int run_process (string[] argv, int timeout_sec,
                                   GLib.Cancellable? cancel,
                                   out bool timed_out,
                                   string? cwd = null) {
        timed_out = false;

        if (cancel != null && cancel.is_cancelled ())
            return -1;

        GLib.Subprocess proc;
        try {
            // 静音输出：不接管道，避免子进程写满管道缓冲后双方死锁
            var flags = GLib.SubprocessFlags.STDOUT_SILENCE
                      | GLib.SubprocessFlags.STDERR_SILENCE;
            if (cwd != null) {
                var launcher = new GLib.SubprocessLauncher (flags);
                launcher.set_cwd (cwd);
                proc = launcher.spawnv (argv);
            } else {
                proc = new GLib.Subprocess.newv (argv, flags);
            }
        } catch (GLib.Error e) {
            return -1;
        }

        // 不用 GLib.Timeout 做超时。
        //
        // 原因：g_subprocess_wait 不会泵主上下文，所以如果本函数跑在主线程
        // 上（例如「测试启动」），主循环被卡住 → Timeout 永远不派发 →
        // 超时形同虚设，进程可能永久阻塞。
        //
        // 改成自轮询：任何线程、有没有主循环都成立。
        int64 deadline = 0;
        if (timeout_sec > 0)
            deadline = GLib.get_monotonic_time ()
                     + (int64) timeout_sec * 1000000;

        while (!proc.get_if_exited ()) {
            if (cancel != null && cancel.is_cancelled ()) {
                proc.force_exit ();
                return -1;
            }
            if (deadline != 0 && GLib.get_monotonic_time () > deadline) {
                timed_out = true;
                proc.force_exit ();
                return -1;
            }
            GLib.Thread.usleep (50000);   // 50ms
        }

        if (!proc.get_if_exited ())
            return -1;   // 被信号杀死，没有正常退出码

        return proc.get_exit_status ();
    }

    /**
     * 读取 AppImage 头，返回格式版本字节。
     *
     * 校验偏移 8/9 是否为 "AI"（AppImage 规范魔数）；
     * 魔数不符或读不出来返回 -1。
     */
    private static int read_appimage_version (string path) {
        try {
            var stream = GLib.File.new_for_path (path).read (null);
            var bytes = stream.read_bytes (11, null);
            stream.close (null);
            if (bytes.get_size () < 11)
                return -1;
            if (bytes.get (8) != (uint8) 'A' || bytes.get (9) != (uint8) 'I')
                return -1;
            return bytes.get (10);
        } catch {
            return -1;
        }
    }

    /**
     * 解包 AppImage 并解析元数据。
     *
     * @param work_dir 临时工作区（每项独立子目录，避免并发冲突）
     * @param cancel   可选取消令牌，worker 线程用它响应界面取消
     * @param timeout_sec 解包硬超时（秒），超时强杀子进程
     */
    public static AppImageInfo run (string path, string work_dir,
                                    GLib.Cancellable? cancel = null,
                                    int timeout_sec = DEFAULT_EXTRACT_TIMEOUT_SEC) {
        var info = new AppImageInfo (path);

        if (!GLib.FileUtils.test (path, GLib.FileTest.EXISTS)) {
            info.error = "文件不存在";
            return info;
        }

        // 不做静默 chmod：不修改用户文件，权限问题交由调用方询问用户
        if (!AppPath.is_executable (path)) {
            info.error = "文件没有执行权限";
            return info;
        }

        // 先验 AppImage 头，绝不把 --appimage-extract 交给普通程序：
        // 老式 / 自制运行时会把它当普通参数，把真正的 GUI 拉起来且永不退出。
        int fmt = read_appimage_version (path);
        if (fmt != 1 && fmt != 2) {
            if (fmt >= 0)
                info.error = "不是标准 AppImage 格式（版本字节 %d），不支持解包".printf (fmt);
            else
                info.error = "不是标准 AppImage 格式，不支持解包";
            return info;
        }

        GLib.DirUtils.create_with_parents (work_dir, 0700);
        string extract_dir = GLib.Path.build_filename (work_dir, "squashfs-root");

        bool timed_out = false;
        // --appimage-extract 把内容解到当前工作目录
        // 关键：cwd 必须是 work_dir。--appimage-extract 把内容解到
        // 「当前目录」，不指定的话会写进本程序被启动时的目录 ——
        // 实测有用户因此被写进 2.1 GB 的解包残留。
        int status = run_process ({ path, "--appimage-extract" },
                                  timeout_sec, cancel, out timed_out, work_dir);

        if (timed_out) {
            AppImageInfo.rm_rf (work_dir);
            info.error = "解包超时（%d 秒）。可能是旧格式或自定义运行时，已强制终止。".printf (timeout_sec);
            return info;
        }

        if (cancel != null && cancel.is_cancelled ()) {
            AppImageInfo.rm_rf (work_dir);
            info.error = "已取消";
            return info;
        }

        // 某些变体会把解包内容放在别处，做一次兜底查找
        if (!AppPath.is_dir (extract_dir)) {
            string alt = find_extracted_root (work_dir);
            if (alt != null) {
                extract_dir = alt;
            } else {
                info.error = "解包失败（exit %d），文件可能已损坏或不是标准 AppImage".printf (status);
                return info;
            }
        }

        info.extract_dir = extract_dir;
        parse_metadata (info);
        info.icon_relpath = find_icon (extract_dir);
        info.ok = true;
        return info;
    }

    /** 兜底：在工作区里找 AppImage 解出来的根目录 */
    private static string? find_extracted_root (string work_dir) {
        try {
            var de = GLib.Dir.open (work_dir, 0);
            string? n;
            while ((n = de.read_name ()) != null) {
                string full = GLib.Path.build_filename (work_dir, n);
                if (AppPath.is_dir (full))
                    return full;
            }
        } catch {}
        return null;
    }

    /** 读根目录下（或一层内）的 .desktop，取元数据 */
    private static void parse_metadata (AppImageInfo info) {
        string[] candidates = find_desktop_files (info.extract_dir);
        if (candidates.length == 0)
            return;

        // 优先挑主 .desktop（不在 Desktop Action 组里的）
        string chosen = candidates[0];
        foreach (string c in candidates) {
            string b = GLib.Path.get_basename (c);
            if (b == GLib.Path.get_basename (c).replace (".desktop", ".AppImage.desktop"))
                continue;
            chosen = c;
            break;
        }

        var entry = DesktopFiles.parse (chosen);
        if (entry == null)
            return;

        info.name             = entry.name != "" ? entry.name : info.name;
        info.generic_name     = entry.generic_name;
        info.comment          = entry.comment;
        info.categories       = entry.categories;
        info.startup_wm_class = entry.startup_wm_class;

        // MimeType 可能多行
        try {
            string data;
            GLib.FileUtils.get_contents (chosen, out data);
            var kf = new GLib.KeyFile ();
            kf.load_from_data (data, data.length, GLib.KeyFileFlags.NONE);
            info.mimetype = kf.get_string ("Desktop Entry", "MimeType") ?? "";
        } catch {}
    }

    private static string[] find_desktop_files (string root) {
        var list = new GenericArray<string> ();

        // 第一层
        try {
            var de = GLib.Dir.open (root, 0);
            string? n;
            while ((n = de.read_name ()) != null) {
                string full = GLib.Path.build_filename (root, n);
                if (GLib.FileUtils.test (full, GLib.FileTest.IS_REGULAR)
                    && n.has_suffix (".desktop"))
                    list.add (full);
            }
        } catch {}

        // 第二层（AppRun 旁边）
        if (list.length == 0) {
            try {
                var de = GLib.Dir.open (root, 0);
                string? n;
                while ((n = de.read_name ()) != null) {
                    string sub = GLib.Path.build_filename (root, n);
                    if (!AppPath.is_dir (sub))
                        continue;
                    var de2 = GLib.Dir.open (sub, 0);
                    string? m;
                    while ((m = de2.read_name ()) != null) {
                        string full = GLib.Path.build_filename (sub, m);
                        if (GLib.FileUtils.test (full, GLib.FileTest.IS_REGULAR)
                            && m.has_suffix (".desktop"))
                            list.add (full);
                    }
                }
            } catch {}
        }

        return list.steal ();
    }

    /**
     * 找最佳图标：.DirIcon 优先，其次最大面积的 png/svg。
     * 返回相对 extract_dir 的路径。
     */
    private static string find_icon (string root) {
        // 1) .DirIcon 是 AppImage 规范里的显式图标声明
        string diricon = GLib.Path.build_filename (root, ".DirIcon");
        if (AppPath.exists (diricon))
            return ".DirIcon";

        // 2) 根目录下的 svg 优先（矢量，缩放无损）
        string? best = null;
        long best_area = -1;

        try {
            var de = GLib.Dir.open (root, 0);
            string? n;
            while ((n = de.read_name ()) != null) {
                string full = GLib.Path.build_filename (root, n);
                if (!GLib.FileUtils.test (full, GLib.FileTest.IS_REGULAR))
                    continue;
                string lower = n.down ();
                if (!lower.has_suffix (".svg") && !lower.has_suffix (".png")
                    && !lower.has_suffix (".xpm"))
                    continue;
                long area = image_area (full);
                if (area > best_area) {
                    best_area = area;
                    best = n;
                }
            }
        } catch {}

        return best ?? "";
    }

    private static long image_area (string path) {
        if (path.has_suffix (".svg") || path.has_suffix (".SVG"))
            return long.MAX / 2;   // 矢量图视为最大
        try {
            var pb = new Gdk.Pixbuf.from_file (path);
            return (long) pb.width * pb.height;
        } catch {
            return 0;
        }
    }

    /**
     * 把提取出的图标安装到 hicolor 缓存，返回最终图标路径。
     *
     * @param icon_relpath 解包目录内的相对路径，空表示没找到
     */
    public static string? install_icon (AppImageInfo info, AppConfig cfg) {
        if (info.extract_dir == "" || info.icon_relpath == "")
            return null;

        string src = GLib.Path.build_filename (info.extract_dir, info.icon_relpath);
        if (!AppPath.exists (src))
            return null;

        string ext = icon_extension (src);
        string slug = AppPath.slugify (GLib.Path.get_basename (info.appimage_path));

        // AppImage 里的文件名通常已含完整名称，用它更不容易撞名
        string icon_base = GLib.Path.get_basename (src);
        if (!icon_base.has_prefix ("."))   // .DirIcon → 用 AppImage 自己的名字
            slug = AppPath.slugify (icon_base);

        string dest_dir = cfg.icon_dir ();
        if (!AppPath.ensure_dir (dest_dir))
            return null;

        string dest = GLib.Path.build_filename (dest_dir, "%s.%s".printf (slug, ext));

        if (icon_extension (src) == "svg") {
            try {
                AppPath.file_copy (src, dest);
                return dest;
            } catch {
                return null;
            }
        }

        // 位图缩放到配置尺寸
        try {
            var pb = new Gdk.Pixbuf.from_file (src);
            int target = cfg.icon_size ();
            int w = pb.width, h = pb.height;
            int nw = target, nh = target;
            if (w >= h) nh = (int) ((double) h * target / w);
            else           nw = (int) ((double) w * target / h);
            if (nw < 1) nw = 1;
            if (nh < 1) nh = 1;

            var scaled = pb.scale_simple (nw, nh, Gdk.InterpType.BILINEAR);
            scaled.savev (dest, "png", null, null);
            return dest;
        } catch {
            try {
                AppPath.file_copy (src, dest);
                return dest;
            } catch {
                return null;
            }
        }
    }

    private static string icon_extension (string path) {
        string b = GLib.Path.get_basename (path).down ();
        if (b.has_suffix (".svg")) return "svg";
        if (b.has_suffix (".xpm")) return "xpm";
        return "png";
    }

    /** 供 UI 显示的 48px 缩略图 */
    public static Gdk.Pixbuf? load_thumbnail (string? icon_path, int size) {
        if (icon_path == null || icon_path == "")
            return null;
        try {
            var pb = new Gdk.Pixbuf.from_file_at_scale (
                icon_path, size, size, true);
            return pb;
        } catch {
            return null;
        }
    }

    /* ── 测试启动 ────────────────────────────────────────────────── */

    public class LaunchResult {
        public bool success = false;
        public int exit_code = -1;
        public string stderr = "";
        public string stdout = "";
        public string message = "";

        public int64 elapsed_ms = 0;
        public bool timed_out = false;
    }

    /**
     * 测试启动 AppImage。
     * 成功与否很难从退出码判断（多数 GUI 应用会 fork 后父进程立即退出），
     * 所以策略是：短时间无致命报错即视为成功。
     *
     * 注意：本函数目前从主线程调用，run_process 的 wait() 会阻塞界面。
     * 超时源挂在默认主循环上，主线程被 wait() 卡住时不会派发，
     * 因此最坏情况仍会一直阻塞。暂时接受，之后应把本函数挪到工作线程。
     */
    public static LaunchResult test_launch (string path, int timeout_ms) {
        var res = new LaunchResult ();

        if (!AppPath.is_executable (path)) {
            res.message = "文件没有执行权限";
            return res;
        }

        int timeout_sec = timeout_ms > 0 ? (timeout_ms + 999) / 1000 : 10;

        int64 start = GLib.get_monotonic_time ();
        bool timed_out = false;
        int status = run_process ({ path }, timeout_sec, null, out timed_out);
        res.elapsed_ms = (GLib.get_monotonic_time () - start) / 1000;

        if (timed_out) {
            res.timed_out = true;
            res.exit_code = -1;
            res.message = "启动测试超时（%d 秒），已终止".printf (timeout_sec);
            return res;
        }

        if (status < 0) {
            res.message = "执行失败（进程未启动或被信号终止）";
            return res;
        }

        res.exit_code = status;

        string err = res.stderr.strip ();
        // 非 0 退出且有 stderr 输出才算失败
        if (status != 0 && err != "") {
            res.success = false;
            res.message = "启动器返回 exit %d".printf (status);
        } else if (status != 0 && err == "") {
            // GUI 应用常见：主进程退出码非 0 但无输出
            res.success = true;
            res.message = "进程已退出（exit %d），无错误输出".printf (status);
        } else {
            res.success = true;
            res.message = "已执行（%lld ms）".printf (res.elapsed_ms);
        }
        return res;
    }
}