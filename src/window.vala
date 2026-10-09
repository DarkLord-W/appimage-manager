/*
 * window.vala — 主窗口（占位，后续实现完整界面）
 */
public class MainWindow : Gtk.ApplicationWindow {

    private AppMgr app;
    private AppConfig config;
    private Store store;

    public MainWindow (AppMgr app) {
        this.app = app;
        this.config = app.get_config ();
        this.store = app.get_store ();

        title = "AppImage Manager";
        default_width = 1080;
        default_height = 680;
        set_size_request (780, 480);

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        box.margin_start = 12;
        box.margin_end = 12;
        box.margin_top = 12;
        box.margin_bottom = 12;

        var label = new Gtk.Label (null);
        label.use_markup = true;
        label.label = "<span size='xx-large' weight='bold'>AppImage Manager</span>";
        box.pack_start (label, false, false, 0);

        var sub = new Gtk.Label (null);
        sub.label = "%d 个 AppImage · %d 个待创建".printf (
            (int) store.entries.length (), store.count (MatchState.NEW));
        sub.margin_top = 6;
        box.pack_start (sub, false, false, 0);

        add (box);
    }

    public void check_crash_recovery () {
        var pending = Journal.pending ();
        if (pending.length > 0) {
            /* GTK3 的 Gtk.Window 没有 subtitle 属性，占位窗口仅记录日志 */
            warning ("检测到未完成的事务 (%d)", pending.length);
        }
    }

    public void refresh () {
        store.rescan ();
    }
}