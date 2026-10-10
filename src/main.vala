/*
 * main.vala — 应用入口
 */
public class AppMgr : Gtk.Application {

    /**
     * main() 收到的原始 argv。
     *
     * 「立即重启」要用它重新起一遍进程：重启时如果丢掉 .desktop 传进来的
     * 文件路径，用户刚打开的东西就没了。
     */
    private static string[] saved_argv = {};
    public static string[] argv_snapshot () { return saved_argv; }
    public static void set_argv_snapshot (string[] a) { saved_argv = a; }

    /* 供 backup.vala / repair.vala / desktopfiles.vala 以 APPMGR_VERSION 引用 */
    /* 版本号定义在 version.vala 的 APPMGR_VERSION */

    private AppConfig config;
    private Store store;
    private MainWindow window;

    public AppMgr () {
        /* 注意：本机 gio-2.0.vapi 把 Gio 的类型全部并入 GLib 命名空间 */
        Object (application_id: "io.github.darklord-w.AppImageManager",
                flags: GLib.ApplicationFlags.HANDLES_OPEN);
    }

    public AppConfig get_config () { return config; }
    public Store get_store () { return store; }

    construct {
        config = new AppConfig ();
        // 语言必须在任何界面文案定下来之前定死：控件文字都是构造时调
        // I18n.s() 取的，运行中再改就来不及了。缺省 auto = 跟随系统 locale。
        I18n.current = config.language ();
        // 必须在这里调而不是 main() 开头：那边 I18n.current 还是 AUTO，
        // 会按系统 locale 判成英文，中文用户拿到的是英文文件选择器。
        // 又必须早于 gtk_init —— Gtk.Application 的 startup 才做 gtk_init，
        // 而本 construct 跑在 run() 之前，时机正好。
        sync_gtk_locale ();
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

        // 程序名决定 GTK 自动推导出的 WM_CLASS 和默认图标名。
        // 必须和 data/*.desktop 的 StartupWMClass / Icon= 保持一致，
        // 否则窗口管理器和任务栏认不出这是哪个应用。
        GLib.Environment.set_prgname ("appimage-manager");
        GLib.Environment.set_application_name ("AppImage Manager");

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


/**
 * 让 GTK 自带控件的语言跟着本应用走。
 *
 * GTK 里的文件选择器、颜色选择器、关于框的内建按钮，文案来自 GTK 自己的
 * gettext 域，不经过本项目的 I18n 表 —— 所以会出现「界面中文、选文件时
 * 弹出英文对话框」这种割裂（实测如此）。
 *
 * 修法是在 GTK 初始化之前把 locale 环境变量改成应用所选语言对应的值。
 * 必须在 Gtk.init 之前：gettext 只在**第一次**查某个域时读一次
 * LC_MESSAGES / LANGUAGE，之后再改就来不及了。
 *
 * 语言包没装时 setlocale 会失败，这时 GTK 退回默认语言，不崩也不报错 ——
 * 退化成现在这个样子，不会更糟。
 */
void sync_gtk_locale () {
    bool zh = (I18n.Lang.effective () == I18n.Lang.ZH);

    // 三个变量各有一个坑，实测出来的（写了个 C 小程序逐组试）：
    //
    //   LC_ALL  —— 有值就**必须清掉**。glibc 的 gettext 在 LC_ALL 被显式
    //              设置时会直接忽略 LANGUAGE，怎么调都是英文。这一条最坑，
    //              一开始把它设成 C.UTF-8，结果中文界面配英文文件选择器。
    //
    //   LANGUAGE —— 真正决定取哪个语言目录的。支持冒号分隔的候选列表，
    //              所以 zh_CN 找不到时还能退到 zh。它**不需要**系统生成
    //              对应 locale，只要 .mo 文件在就行 —— 这台机器就一个
    //              zh_CN locale 都没生成，但 GTK 的中文翻译照样能用。
    //
    //   LANG    —— 必须是一个**真实存在**的 locale。设成 C / POSIX / C.UTF-8
    //              都会让 gettext 整体不查翻译，连 LANGUAGE 都不看。
    //              实测只有 en_US.UTF-8 这种才算数。
    GLib.Environment.unset_variable ("LC_ALL");

    GLib.Environment.set_variable ("LANGUAGE", zh ? "zh_CN:zh" : "en", true);

    string? lang = GLib.Environment.get_variable ("LANG");
    if (lang == null || lang == "" || lang == "C" || lang == "POSIX"
            || lang == "C.UTF-8" || lang == "C.utf8")
        GLib.Environment.set_variable ("LANG", "en_US.UTF-8", true);

    GLib.Intl.setlocale (GLib.LocaleCategory.ALL, "");
}

public int main (string[] args) {
    AppImageExtract.quiet_known_glib_assertion ();
    AppMgr.set_argv_snapshot (args);
    var app = new AppMgr ();
    return app.run (args);
}