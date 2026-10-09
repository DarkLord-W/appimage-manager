/*
 * main.vala — 应用入口
 */
public class AppMgr : Gtk.Application {

    /* 供 backup.vala / repair.vala / desktopfiles.vala 以 APPMGR_VERSION 引用 */
    /* 版本号定义在 version.vala 的 APPMGR_VERSION */

    private AppConfig config;
    private Store store;
    private MainWindow window;

    public AppMgr () {
        /* 注意：本机 gio-2.0.vapi 把 Gio 的类型全部并入 GLib 命名空间 */
        Object (application_id: "io.github.kali.AppImageManager",
                flags: GLib.ApplicationFlags.HANDLES_OPEN);
    }

    public AppConfig get_config () { return config; }
    public Store get_store () { return store; }

    construct {
        config = new AppConfig ();
        store = new Store (config);
    }

    public override void activate () {
        if (window == null) {
            window = new MainWindow (this);
            window.show_all ();
            window.check_crash_recovery ();

            // 首次运行不再弹模态向导 —— 主窗口本身就是空状态引导页
            // （「还没有添加扫描目录」+ 添加目录 / 看看常见位置）。
            // 那样入口始终在主界面里，不会糊一个弹窗在用户脸上。
            if (!config.is_configured ()) {
                config.mark_configured ();
                config.save ();
            }
        }
        window.present ();
    }

    public override void startup () {
        base.startup ();
        Gtk.IconTheme.get_default ().append_search_path (
            GLib.Path.build_filename (AppPath.icons_hicolor_dir (), "256x256", "apps"));
    }

    /* vapi 中该 vfunc 名为 `open`（signal void open (GLib.File[] files, string hint)） */
    public override void open (GLib.File[] files, string hint) {
        foreach (var f in files) {
            string p = f.get_path ();
            if (p == null) {
                continue;
            }
            if (Scanner.is_appimage (p)) {
                config.add_scan_dir (GLib.Path.get_dirname (p));
            }
        }
        activate ();
        if (window != null) {
            window.refresh ();
        }
    }
}

public int main (string[] args) {
    var app = new AppMgr ();
    return app.run (args);
}