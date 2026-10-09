/*
 * main.vala — 应用入口
 */
public class AppMgr : Gtk.Application {

    /* 供 backup.vala / repair.vala / desktopfiles.vala 以 AppMgr.VERSION 引用 */
    public const string VERSION = "1.0.0";

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