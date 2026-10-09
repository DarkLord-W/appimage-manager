/*
 * menubar.vala — 主窗口菜单栏
 *
 * 用传统的 Gtk.MenuBar 替代原来的汉堡菜单按钮：
 *   - 配合原生窗口装饰（不再自绘标题栏），跨主题不会出现空白按钮
 *   - 所有操作都有第二条入口，窄窗口下也不会丢功能
 *   - 用 Gtk.MenuItem.add_accelerator 让 GTK 自己画快捷键提示
 */

/** 无返回值的动作回调（菜单项、按钮共用） */
public delegate void SimpleAction ();

namespace Menus {

    public class AppMenuBar : Gtk.MenuBar {

        private unowned MainWindow win;
        private Gtk.AccelGroup accel;
        private Gtk.RadioMenuItem[] filter_items = new Gtk.RadioMenuItem[6];
        private Gtk.CheckMenuItem? fullscreen_item = null;

        public AppMenuBar (MainWindow win, Gtk.AccelGroup accel_group) {
            this.win = win;
            this.accel = accel_group;

            append (build_file_menu ());
            append (build_edit_menu ());
            append (build_view_menu ());
            append (build_tools_menu ());
            append (build_help_menu ());
        }

        /* ══════════════════════════════════════════════════════════
         *  文件
         * ══════════════════════════════════════════════════════════ */

        private Gtk.MenuItem build_file_menu () {
            var root = new Gtk.MenuItem.with_mnemonic ("文件(_F)");
            var m = new Gtk.Menu ();
            root.set_submenu (m);

            m.append (item ("添加扫描目录…", () => win.menu_add_dir (),
                            Gdk.Key.d, Gdk.ModifierType.CONTROL_MASK));
            m.append (item ("打开启动器目录", () => win.menu_open_apps_dir ()));
            m.append (item ("打开配置目录", () => win.menu_open_config_dir ()));

            m.append (new Gtk.SeparatorMenuItem ());

            m.append (item ("退出", () => win.menu_quit (),
                            Gdk.Key.q, Gdk.ModifierType.CONTROL_MASK));

            m.show_all ();
            return root;
        }

        /* ══════════════════════════════════════════════════════════
         *  编辑
         * ══════════════════════════════════════════════════════════ */

        private Gtk.MenuItem build_edit_menu () {
            var root = new Gtk.MenuItem.with_mnemonic ("编辑(_E)");
            var m = new Gtk.Menu ();
            root.set_submenu (m);

            m.append (item ("全选", () => win.menu_select_all (true),
                            Gdk.Key.a, Gdk.ModifierType.CONTROL_MASK));
            m.append (item ("取消选择", () => win.menu_select_all (false)));

            m.append (new Gtk.SeparatorMenuItem ());

            m.append (item ("创建启动器…", () => win.menu_create (),
                            Gdk.Key.n, Gdk.ModifierType.CONTROL_MASK));
            m.append (item ("修复选中的启动器…", () => win.menu_repair ()));
            m.append (item ("认领外部启动器…", () => win.menu_claim ()));

            m.append (new Gtk.SeparatorMenuItem ());

            m.append (item ("删除选中的启动器", () => win.menu_delete (),
                            Gdk.Key.Delete, 0));

            m.show_all ();
            return root;
        }

        /* ══════════════════════════════════════════════════════════
         *  视图
         * ══════════════════════════════════════════════════════════ */

        private Gtk.MenuItem build_view_menu () {
            var root = new Gtk.MenuItem.with_mnemonic ("视图(_V)");
            var m = new Gtk.Menu ();
            root.set_submenu (m);

            m.append (item ("重新扫描", () => win.menu_refresh (),
                            Gdk.Key.F5, 0));
            m.append (item ("重新扫描", () => win.menu_refresh (),
                            Gdk.Key.r, Gdk.ModifierType.CONTROL_MASK));

            m.append (new Gtk.SeparatorMenuItem ());

            // 过滤：单选组
            string[] names = { "全部", "新发现", "已创建", "外部创建",
                               "失效", "可优化" };
            Gtk.RadioMenuItem? prev = null;
            for (int i = 0; i < names.length; i++) {
                var it = new Gtk.RadioMenuItem.with_label (
                    prev == null ? null : prev.get_group (), names[i]);
                if (prev == null)
                    it.set_active (true);
                int mode = i;
                it.toggled.connect (() => {
                    if (it.get_active ())
                        win.menu_set_filter (mode);
                });
                filter_items[i] = it;
                m.append (it);
                prev = it;
            }

            m.append (new Gtk.SeparatorMenuItem ());

            fullscreen_item = new Gtk.CheckMenuItem.with_label ("全屏");
            fullscreen_item.add_accelerator ("activate", accel,
                Gdk.Key.F11, 0, Gtk.AccelFlags.VISIBLE);
            fullscreen_item.toggled.connect (() =>
                win.menu_set_fullscreen (fullscreen_item.get_active ()));
            m.append (fullscreen_item);

            m.show_all ();
            return root;
        }

        /* ══════════════════════════════════════════════════════════
         *  工具
         * ══════════════════════════════════════════════════════════ */

        private Gtk.MenuItem build_tools_menu () {
            var root = new Gtk.MenuItem.with_mnemonic ("工具(_T)");
            var m = new Gtk.Menu ();
            root.set_submenu (m);

            m.append (item ("健康检查…", () => win.menu_health ()));
            m.append (item ("修复历史…", () => win.menu_history ()));
            m.append (item ("失效与孤儿清理…", () => win.menu_cleanup ()));

            m.append (new Gtk.SeparatorMenuItem ());

            m.append (item ("从 AppImage 提取内置元数据…",
                            () => win.menu_extract_metadata ()));

            m.append (new Gtk.SeparatorMenuItem ());

            m.append (item ("设置…", () => win.menu_settings (),
                            Gdk.Key.comma, Gdk.ModifierType.CONTROL_MASK));

            m.show_all ();
            return root;
        }

        /* ══════════════════════════════════════════════════════════
         *  帮助
         * ══════════════════════════════════════════════════════════ */

        private Gtk.MenuItem build_help_menu () {
            var root = new Gtk.MenuItem.with_mnemonic ("帮助(_H)");
            var m = new Gtk.Menu ();
            root.set_submenu (m);

            m.append (item ("键盘快捷键", () => win.menu_shortcuts (),
                            Gdk.Key.F1, 0));
            m.append (item ("关于 AppImage Manager", () => win.menu_about ()));

            m.show_all ();
            return root;
        }

        /* ══════════════════════════════════════════════════════════
         *  辅助
         * ══════════════════════════════════════════════════════════ */

        // 注意：Gdk.Key 在本机 vapi 里只能当值用（Gdk.Key.d），不能当类型，
        // 所以这里收 uint。
        private Gtk.MenuItem item (string label, owned SimpleAction cb,
                                   uint key = 0, Gdk.ModifierType mods = 0) {
            var it = new Gtk.MenuItem.with_label (label);
            it.activate.connect (() => cb ());
            if (key != 0)
                it.add_accelerator ("activate", accel, key, mods,
                                    Gtk.AccelFlags.VISIBLE);
            return it;
        }

        /** 让「视图 → 过滤」的单选项与工具栏下拉框保持同步 */
        public void sync_filter (int mode) {
            if (mode < 0 || mode >= filter_items.length)
                return;
            var it = filter_items[mode];
            if (it != null && !it.get_active ())
                it.set_active (true);
        }

        /** 全屏状态被外部改变时同步勾选（例如窗口管理器快捷键） */
        public void sync_fullscreen (bool on) {
            if (fullscreen_item != null && fullscreen_item.get_active () != on)
                fullscreen_item.set_active (on);
        }
    }
}
