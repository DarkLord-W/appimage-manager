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
        private Gtk.CheckMenuItem? maximize_item = null;

        public AppMenuBar (MainWindow win, Gtk.AccelGroup accel_group) {
            this.win = win;
            this.accel = accel_group;

            append (build_file_menu ());
            append (build_edit_menu ());
            append (build_view_menu ());
            append (build_tools_menu ());
            append (build_language_menu ());
            append (build_help_menu ());
        }

        /* ══════════════════════════════════════════════════════════
         *  文件
         * ══════════════════════════════════════════════════════════ */

        private Gtk.MenuItem build_file_menu () {
            var root = new Gtk.MenuItem.with_mnemonic (I18n.s ("文件(_F)"));
            var m = new Gtk.Menu ();
            root.set_submenu (m);

            m.append (item (I18n.s ("添加扫描目录…"), () => win.menu_add_dir (),
                            Gdk.Key.d, Gdk.ModifierType.CONTROL_MASK));
            m.append (item (I18n.s ("打开启动器目录"), () => win.menu_open_apps_dir ()));
            m.append (item (I18n.s ("打开配置目录"), () => win.menu_open_config_dir ()));

            m.append (new Gtk.SeparatorMenuItem ());

            m.append (item (I18n.s ("退出"), () => win.menu_quit (),
                            Gdk.Key.q, Gdk.ModifierType.CONTROL_MASK));

            m.show_all ();
            return root;
        }

        /* ══════════════════════════════════════════════════════════
         *  编辑
         * ══════════════════════════════════════════════════════════ */

        private Gtk.MenuItem build_edit_menu () {
            var root = new Gtk.MenuItem.with_mnemonic (I18n.s ("编辑(_E)"));
            var m = new Gtk.Menu ();
            root.set_submenu (m);

            m.append (item (I18n.s ("全选"), () => win.menu_select_all (true),
                            Gdk.Key.a, Gdk.ModifierType.CONTROL_MASK));
            m.append (item (I18n.s ("取消选择"), () => win.menu_select_all (false)));

            m.append (new Gtk.SeparatorMenuItem ());

            m.append (item (I18n.s ("创建启动器…"), () => win.menu_create (),
                            Gdk.Key.n, Gdk.ModifierType.CONTROL_MASK));
            m.append (item (I18n.s ("修复选中的启动器…"), () => win.menu_repair ()));
            m.append (item (I18n.s ("认领外部启动器…"), () => win.menu_claim ()));

            m.append (new Gtk.SeparatorMenuItem ());

            m.append (item (I18n.s ("删除选中的启动器"), () => win.menu_delete (),
                            Gdk.Key.Delete, 0));

            m.show_all ();
            return root;
        }

        /* ══════════════════════════════════════════════════════════
         *  视图
         * ══════════════════════════════════════════════════════════ */

        private Gtk.MenuItem build_view_menu () {
            var root = new Gtk.MenuItem.with_mnemonic (I18n.s ("视图(_V)"));
            var m = new Gtk.Menu ();
            root.set_submenu (m);

            m.append (item (I18n.s ("重新扫描"), () => win.menu_refresh (),
                            Gdk.Key.F5, 0));
            m.append (item (I18n.s ("重新扫描"), () => win.menu_refresh (),
                            Gdk.Key.r, Gdk.ModifierType.CONTROL_MASK));

            m.append (new Gtk.SeparatorMenuItem ());

            // 过滤：单选组
            string[] names = { I18n.s ("全部"), I18n.s ("新发现"), I18n.s ("已创建"), I18n.s ("外部创建"),
                               I18n.s ("失效"), I18n.s ("可优化") };
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

            // 之前这里是「全屏」，调 Gtk.Window.fullscreen()。
            // 那是真全屏 —— X11 协议下窗口管理器必须撤掉全部装饰，
            // 于是标题栏连同最小化/最大化/关闭三个按钮一起消失，
            // 用户会以为「按钮坏了」。实际需求是「铺满屏幕但保留标题栏」，
            // 那是 maximize()，不是 fullscreen()。
            //
            // 快捷键用 F11 而不是更常见的 F10：GTK 的 GtkMenuBar 自带
            // F10 绑定（聚焦菜单栏），抢过来会破坏键盘导航。
            maximize_item = new Gtk.CheckMenuItem.with_label (I18n.s ("最大化"));
            maximize_item.add_accelerator ("activate", accel,
                Gdk.Key.F11, 0, Gtk.AccelFlags.VISIBLE);
            maximize_item.toggled.connect (() =>
                win.menu_set_maximize (maximize_item.get_active ()));
            m.append (maximize_item);

            m.show_all ();
            return root;
        }

        /* ══════════════════════════════════════════════════════════
         *  工具
         * ══════════════════════════════════════════════════════════ */

        private Gtk.MenuItem build_tools_menu () {
            var root = new Gtk.MenuItem.with_mnemonic (I18n.s ("工具(_T)"));
            var m = new Gtk.Menu ();
            root.set_submenu (m);

            m.append (item (I18n.s ("健康检查…"), () => win.menu_health ()));
            m.append (item (I18n.s ("修复历史…"), () => win.menu_history ()));
            m.append (item (I18n.s ("失效与孤儿清理…"), () => win.menu_cleanup ()));

            m.append (new Gtk.SeparatorMenuItem ());

            m.append (item (I18n.s ("用内置元数据补全所选启动器…"),
                            () => win.menu_extract_metadata ()));

            m.append (new Gtk.SeparatorMenuItem ());

            m.append (item (I18n.s ("设置…"), () => win.menu_settings (),
                            Gdk.Key.comma, Gdk.ModifierType.CONTROL_MASK));

            m.show_all ();
            return root;
        }

        /* ══════════════════════════════════════════════════════════
         *  帮助
         * ══════════════════════════════════════════════════════════ */

        /**
         * 语言菜单。
         *
         * 三个选项：跟随系统 / 简体中文 / English。用 Gtk.RadioMenuItem 而不是
         * 自己画勾 —— radio 组自带互斥和键盘导航，省掉一堆状态同步。
         *
         * 切换不立刻换界面（见 Config.set_language 的注释），所以选中后由
         * MainWindow 弹提示条带「立即重启」按钮。
         */
        private Gtk.MenuItem build_language_menu () {
            var root = new Gtk.MenuItem.with_mnemonic (I18n.s ("语言(_L)"));
            var m = new Gtk.Menu ();
            m.set_accel_group (accel);
            root.set_submenu (m);

            // 只有菜单被用户真正打开过，才允许它改语言。
            //
            // Gtk.RadioMenuItem 在菜单第一次显示时会自行激活组里的某一项并
            // 发出 "activate" —— 那是 GTK 的焦点行为，不是用户点的。接到
            // activate 上就会在启动时凭空把语言改回 auto：实测启动一次，
            // 配置里的 language=en 就被写成了 auto，用户的设置存不住。
            // "show" 只在用户点开菜单时发，用它当闸门刚好。
            m.show.connect (() => { win.language_menu_armed = true; });

            Gtk.RadioMenuItem? first = null;
            foreach (var lang in new I18n.Lang[] { I18n.Lang.AUTO, I18n.Lang.ZH, I18n.Lang.EN }) {
                Gtk.RadioMenuItem it;
                if (first == null) {
                    it = new Gtk.RadioMenuItem.with_label (null, lang.display_name ());
                    first = it;
                } else {
                    // with_label_from_widget 把后面的项挂进第一个的 radio 组，
                    // 互斥和方向键导航都由 GTK 自己管
                    it = new Gtk.RadioMenuItem.with_label_from_widget (first,
                                                                        lang.display_name ());
                }
                if (lang.is_selected ())
                    it.set_active (true);
                it.activate.connect (() => { win.menu_set_language (lang); });
                m.append (it);
            }

            m.show_all ();
            return root;
        }

        private Gtk.MenuItem build_help_menu () {
            var root = new Gtk.MenuItem.with_mnemonic (I18n.s ("帮助(_H)"));
            var m = new Gtk.Menu ();
            root.set_submenu (m);

            m.append (item (I18n.s ("键盘快捷键"), () => win.menu_shortcuts (),
                            Gdk.Key.F1, 0));
            m.append (item (I18n.s ("关于 AppImage Manager"), () => win.menu_about ()));

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

        /** 最大化状态被外部改变时同步勾选（例如双击标题栏、WM 快捷键） */
        public void sync_maximize (bool on) {
            if (maximize_item != null && maximize_item.get_active () != on)
                maximize_item.set_active (on);
        }
    }
}
