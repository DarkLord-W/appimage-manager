/*
 * window.vala — 主窗口
 *
 * 结构：
 *   HeaderBar  —— 标题 / 统计副标题 / 搜索 / 刷新 / 菜单
 *   目录条     —— 扫描目录 chips + 添加
 *   过滤条     —— 状态过滤 / 全选 / 已选计数
 *   内容区     —— Gtk.Overlay(TreeView + 浮动操作条)
 *   InfoBar    —— 警告与结果反馈
 */
public class MainWindow : Gtk.ApplicationWindow {

    private AppMgr app;
    private AppConfig config;
    private Store store;

    // ── 顶栏 ──────────────────────────────────────────────────────
    private Gtk.HeaderBar header;
    private Gtk.Label subtitle_label;
    private Gtk.SearchEntry search;
    private Gtk.Button refresh_btn;
    private Gtk.Spinner spinner;

    // ── 目录条 ────────────────────────────────────────────────────
    private Gtk.Box dir_box;

    // ── 过滤条 ────────────────────────────────────────────────────
    private Gtk.ComboBoxText filter_combo;
    private Gtk.CheckButton select_all;
    private Gtk.Label sel_count;

    // ── 列表 ──────────────────────────────────────────────────────
    private Gtk.ListStore model;
    private Gtk.TreeModelFilter filter;
    private Gtk.TreeModelSort sort;
    private Gtk.TreeView tree;
    private Gtk.ScrolledWindow scrolled;

    // ── 浮动操作条 ────────────────────────────────────────────────
    private Gtk.Revealer overlay_revealer;
    private Gtk.Box overlay_box;
    private Gtk.Label overlay_label;
    private Gtk.Button act_create;
    private Gtk.Button act_icon;
    private Gtk.Button act_edit;
    private Gtk.Button act_delete;
    private Gtk.Button act_test;

    // ── InfoBar ───────────────────────────────────────────────────
    private Gtk.InfoBar infobar;
    private Gtk.Label infobar_label;

    // ── 状态 ──────────────────────────────────────────────────────
    private int filter_mode = 0;      // 0=全部 1=新发现 2=已创建 3=外部 4=失效 5=可优化
    private bool scanning = false;

    // 模型列
    private enum Col {
        CHECK,   // bool
        ICON,    // Gdk.Pixbuf
        NAME,    // string
        SIZE,    // string
        PILL,    // Gdk.Pixbuf (药丸)
        PATH,    // string
        ENTRY,   // AppEntry
        SORTNAME,// string (用于排序，避免大小写差异)
        N_COLS
    }

    public MainWindow (AppMgr app) {
        // Vala 要求构造属性赋值必须是构造函数的第一条语句。
        // 放在其它语句之后会导致 g_object_new 之后字段仍未被正确初始化而崩溃。
        //
        // 必须把 application 设为构造属性：否则 Gtk.Application 不认为
        // 这个窗口属于自己，会在数完窗口数=0 后立即退出主循环。
        Object (application: app,
                title: "AppImage Manager",
                default_width: 1080,
                default_height: 680);

        this.app = app;
        this.config = app.get_config ();
        this.store = app.get_store ();

        set_size_request (780, 480);
        icon_name = "appimage-manager";

        build_header ();
        build_body ();
        build_infobar ();

        var root = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        root.pack_start (header, false, false, 0);
        root.pack_start (dir_bar_widget, false, false, 0);
        root.pack_start (filter_bar_widget, false, false, 0);
        root.pack_start (content, true, true, 0);
        root.pack_start (infobar, false, false, 0);
        add (root);

        install_css ();
        install_accels ();
        connect_signals ();

        store.changed.connect (on_store_changed);

        if (config.auto_on_startup () || config.is_configured ())
            refresh ();
        else
            update_subtitle ();
    }

    // ══════════════════════════════════════════════════════════════
    //  构建：顶栏
    // ══════════════════════════════════════════════════════════════

    private void build_header () {
        header = new Gtk.HeaderBar ();
        header.set_show_close_button (true);

        // 菜单
        var menu_btn = new Gtk.MenuButton ();
        menu_btn.set_tooltip_text ("菜单");
        var menu_icon = new Gtk.Image.from_icon_name ("open-menu-symbolic",
                                                     Gtk.IconSize.BUTTON);
        menu_btn.set_image (menu_icon);

        var menu = new Gtk.Menu ();
        add_menu_item (menu, "扫描目录…", () => { on_menu_dirs (); return false; });
        add_menu_item (menu, "修复历史…", () => { on_menu_history (); return false; });
        menu.append (new Gtk.SeparatorMenuItem ());
        add_menu_item (menu, "健康检查", () => { on_menu_health (); return false; });
        add_menu_item (menu, "失效与孤儿清理…", () => { on_menu_cleanup (); return false; });
        menu.append (new Gtk.SeparatorMenuItem ());
        add_menu_item (menu, "设置…", () => { on_menu_settings (); return false; });
        add_menu_item (menu, "关于", () => { on_menu_about (); return false; });
        menu.show_all ();
        menu_btn.set_popup (menu);
        header.pack_start (menu_btn);

        // 标题 + 副标题
        var title_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        var title_label = new Gtk.Label ("AppImage Manager");
        title_label.get_style_context ().add_class ("app-title");
        subtitle_label = new Gtk.Label ("正在初始化…");
        subtitle_label.get_style_context ().add_class ("app-subtitle");
        title_box.pack_start (title_label, false, false, 0);
        title_box.pack_start (subtitle_label, false, false, 0);
        header.set_custom_title (title_box);

        // 刷新
        refresh_btn = new Gtk.Button ();
        refresh_btn.set_tooltip_text ("重新扫描 (Ctrl+R)");
        var refresh_icon = new Gtk.Image.from_icon_name ("view-refresh-symbolic",
                                                         Gtk.IconSize.BUTTON);
        refresh_btn.set_image (refresh_icon);
        header.pack_end (refresh_btn);

        // 扫描中的旋转指示
        spinner = new Gtk.Spinner ();
        spinner.set_no_show_all (true);
        header.pack_end (spinner);

        // 搜索
        search = new Gtk.SearchEntry ();
        search.set_placeholder_text ("搜索名称或路径…");
        search.set_width_chars (22);
        header.pack_end (search);
    }

    private void add_menu_item (Gtk.Menu menu, string label, owned GLib.SourceFunc cb) {
        var item = new Gtk.MenuItem.with_label (label);
        item.activate.connect (() => { cb (); });
        menu.append (item);
    }

    // ══════════════════════════════════════════════════════════════
    //  构建：目录条 / 过滤条 / 内容区
    // ══════════════════════════════════════════════════════════════

    private Gtk.ScrolledWindow? dir_bar_widget = null;
    private Gtk.Box? filter_bar_widget = null;
    private Gtk.Overlay? content = null;
    private Gtk.TreeViewColumn? pill_col = null;
    private PillRenderer? pill_renderer = null;

    private void build_body () {
        build_dir_bar ();
        build_filter_bar ();
        build_tree ();
        build_overlay ();
    }

    private void build_dir_bar () {
        dir_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        dir_box.set_border_width (6);
        dir_box.margin_start = 4;
        dir_box.margin_end = 4;

        var sw = new Gtk.ScrolledWindow (null, null);
        sw.set_policy (Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.NEVER);
        sw.set_size_request (-1, 40);
        sw.add (dir_box);
        dir_bar_widget = sw;

        rebuild_dir_chips ();
    }

    private void rebuild_dir_chips () {
        dir_box.foreach ((w) => dir_box.remove (w));

        foreach (string d in config.scan_dirs ()) {
            var chip = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
            chip.get_style_context ().add_class ("dir-chip");
            if (!AppPath.is_dir (d))
                chip.get_style_context ().add_class ("missing");

            var icon = new Gtk.Image.from_icon_name (
                AppPath.is_dir (d) ? "folder-symbolic" : "dialog-warning-symbolic",
                Gtk.IconSize.MENU);
            chip.pack_start (icon, false, false, 0);

            var lab = new Gtk.Label (AppPath.shorten (d));
            lab.set_ellipsize (Pango.EllipsizeMode.MIDDLE);
            lab.set_max_width_chars (34);
            chip.pack_start (lab, false, false, 0);

            var remove = new Gtk.Button ();
            var close_icon = new Gtk.Image.from_icon_name ("window-close-symbolic",
                                                           Gtk.IconSize.MENU);
            remove.set_image (close_icon);
            remove.set_relief (Gtk.ReliefStyle.NONE);
            remove.set_tooltip_text ("移除此目录");
            string target = d;
            remove.clicked.connect (() => on_remove_dir (target));
            chip.pack_start (remove, false, false, 0);

            chip.set_tooltip_text (AppPath.is_dir (d) ? d : d + "\n（目录不存在）");
            dir_box.pack_start (chip, false, false, 0);
        }

        var add = new Gtk.Button.with_label ("+ 添加目录");
        add.set_relief (Gtk.ReliefStyle.NORMAL);
        add.clicked.connect (() => on_add_dir ());
        dir_box.pack_start (add, false, false, 0);

        dir_box.show_all ();
    }

    private void build_filter_bar () {
        filter_bar_widget = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
        filter_bar_widget.get_style_context ().add_class ("filter-bar");

        filter_combo = new Gtk.ComboBoxText ();
        filter_combo.append_text ("全部");
        filter_combo.append_text ("新发现");
        filter_combo.append_text ("已创建");
        filter_combo.append_text ("外部创建");
        filter_combo.append_text ("失效");
        filter_combo.append_text ("可优化");
        filter_combo.set_active (0);
        filter_bar_widget.pack_start (filter_combo, false, false, 0);

        select_all = new Gtk.CheckButton.with_label ("全选");
        filter_bar_widget.pack_start (select_all, false, false, 0);

        sel_count = new Gtk.Label ("");
        sel_count.get_style_context ().add_class ("dim-label");
        filter_bar_widget.pack_start (sel_count, false, false, 0);

        var spacer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        filter_bar_widget.pack_start (spacer, true, true, 0);
    }

    private void build_tree () {
        model = new Gtk.ListStore (Col.N_COLS,
            typeof (bool),            // CHECK
            typeof (Gdk.Pixbuf),      // ICON
            typeof (string),          // NAME
            typeof (string),          // SIZE
            typeof (Gdk.Pixbuf),      // PILL
            typeof (string),          // PATH
            typeof (AppEntry),        // ENTRY
            typeof (string));         // SORTNAME

        filter = new Gtk.TreeModelFilter (model, null);
        filter.set_visible_func (on_row_visible);

        sort = new Gtk.TreeModelSort.with_model (filter);
        sort.set_sort_column_id (Col.NAME, Gtk.SortType.ASCENDING);

        tree = new Gtk.TreeView.with_model (sort);
        tree.get_style_context ().add_class ("app-list");
        tree.set_headers_visible (true);
        tree.set_grid_lines (Gtk.TreeViewGridLines.HORIZONTAL);
        tree.get_selection ().set_mode (Gtk.SelectionMode.MULTIPLE);
        tree.set_tooltip_column (Col.PATH);

        // ☐ 勾选
        var toggle = new Gtk.CellRendererToggle ();
        toggle.set_activatable (true);
        toggle.toggled.connect ((path_str) => {
            // toggled 给的是字符串路径，转成 Gtk.TreePath 才能取迭代器
            var tp = new Gtk.TreePath.from_string (path_str);
            Gtk.TreeIter it;
            if (filter.get_iter (out it, tp)) {
                bool cur;
                filter.get (it, Col.CHECK, out cur);
                // TreeModelFilter 没有 set()，改底部 ListStore
                Gtk.TreeIter child;
                filter.convert_iter_to_child_iter (out child, it);
                model.set (child, Col.CHECK, !cur);
                update_selection_ui ();
            }
        });
        var col_check = new Gtk.TreeViewColumn ();
        col_check.pack_start (toggle, false);
        col_check.add_attribute (toggle, "active", Col.CHECK);
        col_check.set_sizing (Gtk.TreeViewColumnSizing.FIXED);
        col_check.set_fixed_width (34);
        tree.append_column (col_check);

        // 图标
        var pix = new Gtk.CellRendererPixbuf ();
        pix.set_property ("width", 40);
        pix.set_property ("height", 40);
        var col_icon = new Gtk.TreeViewColumn ();
        col_icon.pack_start (pix, false);
        col_icon.add_attribute (pix, "pixbuf", Col.ICON);
        col_icon.set_sizing (Gtk.TreeViewColumnSizing.FIXED);
        col_icon.set_fixed_width (56);
        tree.append_column (col_icon);

        // 名称
        var txt_name = new Gtk.CellRendererText ();
        txt_name.set_property ("ellipsize", Pango.EllipsizeMode.END);
        txt_name.set_property ("ellipsize-set", true);
        var col_name = new Gtk.TreeViewColumn.with_attributes (
            "名称", txt_name, "text", Col.NAME, null);
        col_name.set_expand (true);
        col_name.set_resizable (true);
        col_name.set_min_width (140);
        col_name.set_sort_column_id (Col.SORTNAME);
        tree.append_column (col_name);

        // 大小
        var txt_size = new Gtk.CellRendererText ();
        txt_size.set_property ("xalign", 1.0f);
        var col_size = new Gtk.TreeViewColumn.with_attributes (
            "大小", txt_size, "text", Col.SIZE, null);
        col_size.set_sizing (Gtk.TreeViewColumnSizing.FIXED);
        col_size.set_fixed_width (90);
        col_size.set_sort_column_id (Col.SIZE);
        tree.append_column (col_size);

        // 状态药丸
        var pix_pill = new Gtk.CellRendererPixbuf ();
        pix_pill.set_property ("xpad", 4);
        pill_col = new Gtk.TreeViewColumn ();
        pill_col.pack_start (pix_pill, false);
        pill_col.add_attribute (pix_pill, "pixbuf", Col.PILL);
        pill_col.set_sizing (Gtk.TreeViewColumnSizing.FIXED);
        pill_col.set_fixed_width (118);
        pill_col.set_title ("状态");
        tree.append_column (pill_col);

        // 路径
        var txt_path = new Gtk.CellRendererText ();
        txt_path.set_property ("ellipsize", Pango.EllipsizeMode.MIDDLE);
        txt_path.set_property ("ellipsize-set", true);
        var col_path = new Gtk.TreeViewColumn.with_attributes (
            "路径", txt_path, "text", Col.PATH, null);
        col_path.set_expand (true);
        col_path.set_resizable (true);
        col_path.set_min_width (160);
        col_path.set_sort_column_id (Col.PATH);
        tree.append_column (col_path);

        scrolled = new Gtk.ScrolledWindow (null, null);
        scrolled.set_policy (Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC);
        scrolled.add (tree);
    }

    private void build_overlay () {
        content = new Gtk.Overlay ();
        content.add (scrolled);

        overlay_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
        overlay_box.get_style_context ().add_class ("action-overlay");

        overlay_label = new Gtk.Label ("已选 0 项");
        overlay_box.pack_start (overlay_label, false, false, 0);

        overlay_box.pack_start (new Gtk.Separator (Gtk.Orientation.VERTICAL),
                                false, false, 2);

        act_create = mk_action ("⚡ 创建", "创建桌面启动器 (Enter)", () => { on_act_create (); return false; });
        act_icon   = mk_action ("🖼 图标", "重新提取图标", () => { on_act_icon (); return false; });
        act_edit   = mk_action ("✎ 编辑", "编辑启动器", () => { on_act_edit (); return false; });
        act_delete = mk_action ("🗑 删除", "删除启动器", () => { on_act_delete (); return false; });
        act_test   = mk_action ("▶ 测试", "测试启动", () => { on_act_test (); return false; });

        foreach (var b in new Gtk.Button[] { act_create, act_icon, act_edit,
                                             act_delete, act_test })
            overlay_box.pack_start (b, false, false, 0);

        overlay_revealer = new Gtk.Revealer ();
        overlay_revealer.set_transition_type (Gtk.RevealerTransitionType.SLIDE_UP);
        overlay_revealer.set_transition_duration (200);
        overlay_revealer.set_halign (Gtk.Align.END);
        overlay_revealer.set_valign (Gtk.Align.END);
        overlay_revealer.set_margin_end (16);
        overlay_revealer.set_margin_bottom (16);
        overlay_revealer.add (overlay_box);
        overlay_revealer.set_no_show_all (true);

        content.add_overlay (overlay_revealer);
    }

    private Gtk.Button mk_action (string label, string tip, owned GLib.SourceFunc cb) {
        var b = new Gtk.Button.with_label (label);
        b.set_tooltip_text (tip);
        b.set_sensitive (false);
        b.clicked.connect (() => { cb (); });
        return b;
    }

    private void build_infobar () {
        infobar = new Gtk.InfoBar ();
        infobar.set_no_show_all (true);
        infobar.set_show_close_button (true);

        infobar_label = new Gtk.Label ("");
        infobar_label.set_line_wrap (true);
        infobar.get_content_area ().add (infobar_label);

        var action = new Gtk.Button.with_label ("查看并清理");
        infobar.add_action_widget (action, Gtk.ResponseType.ACCEPT);
        infobar.add_button ("知道了", Gtk.ResponseType.CLOSE);
    }

    // ══════════════════════════════════════════════════════════════
    //  样式与快捷键
    // ══════════════════════════════════════════════════════════════

    private void install_css () {
        string css_path = find_css ();
        if (css_path == "") {
            warning ("未找到 style.css，使用默认外观");
            return;
        }
        try {
            var provider = new Gtk.CssProvider ();
            provider.load_from_path (css_path);
            var screen = Gdk.Screen.get_default ();
            if (screen != null)
                Gtk.StyleContext.add_provider_for_screen (
                    screen, provider,
                    Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        } catch (GLib.Error e) {
            warning ("样式表加载失败: %s", e.message);
        }
    }

    /** 依次尝试：安装目录 → 源码树 → 当前目录 */
    private string find_css () {
        string[] candidates = {
            GLib.Path.build_filename ("/usr/local/share/appimage-manager", "style.css"),
            GLib.Path.build_filename ("/usr/share/appimage-manager", "style.css"),
            "data/style.css",
            GLib.Path.build_filename (AppPath.data_root (), "style.css")
        };
        foreach (string c in candidates)
            if (AppPath.exists (c))
                return AppPath.canonical (c);
        return "";
    }

    private void install_accels () {
        var accel = new Gtk.AccelGroup ();
        add_accel_group (accel);

        accel.connect (Gdk.Key.r, Gdk.ModifierType.CONTROL_MASK,
                       Gtk.AccelFlags.VISIBLE, () => { refresh (); return true; });
        accel.connect (Gdk.Key.F5, 0, Gtk.AccelFlags.VISIBLE,
                       () => { refresh (); return true; });
        accel.connect (Gdk.Key.a, Gdk.ModifierType.CONTROL_MASK,
                       Gtk.AccelFlags.VISIBLE, () => { set_all_checked (true); return true; });
        accel.connect (Gdk.Key.f, Gdk.ModifierType.CONTROL_MASK,
                       Gtk.AccelFlags.VISIBLE, () => { search.grab_focus (); return true; });
        accel.connect (Gdk.Key.comma, Gdk.ModifierType.CONTROL_MASK,
                       Gtk.AccelFlags.VISIBLE, () => { on_menu_settings (); return true; });
        accel.connect (Gdk.Key.Delete, 0, Gtk.AccelFlags.VISIBLE,
                       () => { on_act_delete (); return true; });
        accel.connect (Gdk.Key.Return, 0, Gtk.AccelFlags.VISIBLE,
                       () => { on_primary_action (); return true; });
    }

    private void connect_signals () {
        refresh_btn.clicked.connect (() => refresh ());
        search.search_changed.connect (() => { filter.refilter (); update_selection_ui (); });
        filter_combo.changed.connect (() => {
            filter_mode = filter_combo.get_active ();
            filter.refilter ();
            tree.get_selection ().unselect_all ();
            update_selection_ui ();
        });
        select_all.toggled.connect (() => {
            set_all_checked (select_all.get_active ());
        });
        tree.get_selection ().changed.connect (() => update_selection_ui ());
        tree.row_activated.connect ((path, col) => on_row_activated (path));

        infobar.response.connect ((id) => {
            infobar.hide ();
            if (id == Gtk.ResponseType.ACCEPT)
                on_menu_cleanup ();
        });

        key_press_event.connect ((ev) => {
            if (ev.keyval == Gdk.Key.Escape) {
                infobar.hide ();
                return true;
            }
            return false;
        });
    }

    // ══════════════════════════════════════════════════════════════
    //  扫描与刷新
    // ══════════════════════════════════════════════════════════════

    public void refresh () {
        if (scanning)
            return;
        scanning = true;
        spinner.start ();
        spinner.show ();
        refresh_btn.set_sensitive (false);

        // 让 spinner 有机会先画出来，再开始同步扫描
        GLib.Idle.add (() => {
            store.rescan ();
            scanning = false;
            spinner.stop ();
            spinner.hide ();
            refresh_btn.set_sensitive (true);
            rebuild_dir_chips ();
            update_subtitle ();
            check_infobar ();
            update_selection_ui ();
            return false;
        });
    }

    private void on_store_changed () {
        rebuild_model ();
    }

    private void rebuild_model () {
        model.clear ();
        foreach (var e in store.entries) {
            Gtk.TreeIter it;
            model.append (out it);
            model.set (it,
                Col.CHECK, false,
                Col.ICON, e.get_thumbnail (40),
                Col.NAME, e.get_best_name (),
                Col.SIZE, AppPath.format_size (e.size),
                Col.PILL, make_pill (e),
                Col.PATH, AppPath.shorten (e.path),
                Col.ENTRY, e,
                Col.SORTNAME, e.get_best_name ().down ());
        }
        filter.refilter ();
        update_selection_ui ();
    }

    private Gdk.Pixbuf? make_pill (AppEntry e) {
        string text = e.get_status_text ();
        int sev = 0;
        if (e.health == HealthState.CORRUPT) sev = 3;
        else if (e.health == HealthState.IMPROVABLE) sev = 2;
        else if (e.match == MatchState.EXTERNAL) sev = 1;

        string color = PillPainter.color_for (text, sev);
        bool hollow = (e.match == MatchState.NEW);
        return PillPainter.render (text, color, hollow);
    }

    private void update_subtitle () {
        int total = (int) store.entries.length ();
        int pending = store.count (MatchState.NEW);
        int broken = store.broken_entries.length;
        int dirs = config.scan_dirs ().length;

        string s = "%d 个目录 · %d 个 AppImage · %d 个待创建"
            .printf (dirs, total, pending);
        if (broken > 0)
            s += " · %d 个失效".printf (broken);
        subtitle_label.set_text (s);
    }

    private void check_infobar () {
        int broken = store.broken_entries.length;
        if (broken == 0) {
            infobar.hide ();
            return;
        }
        infobar_label.set_text ("⚠ 发现 %d 个失效的启动器（指向的 AppImage 已不存在）".printf (broken));
        infobar.set_message_type (Gtk.MessageType.WARNING);
        infobar.show_all ();
    }

    // ══════════════════════════════════════════════════════════════
    //  过滤与选择
    // ══════════════════════════════════════════════════════════════

    private bool on_row_visible (Gtk.TreeModel m, Gtk.TreeIter it) {
        // 状态过滤
        if (filter_mode != 0) {
            MatchState ms;
            HealthState hs;
            ((Gtk.ListStore) m).get (it, Col.ENTRY, out ms, Col.ENTRY, out hs);
            // 上面这行拿不到枚举，改用下面的写法
        }

        AppEntry? e = null;
        m.get (it, Col.ENTRY, out e);
        if (e == null)
            return false;

        // 状态过滤
        if (filter_mode != 0) {
            bool ok = false;
            switch (filter_mode) {
                case 1: ok = (e.match == MatchState.NEW); break;
                case 2: ok = (e.match == MatchState.REGISTERED); break;
                case 3: ok = (e.match == MatchState.EXTERNAL); break;
                case 4: ok = (e.match == MatchState.BROKEN); break;
                case 5: ok = (e.health == HealthState.IMPROVABLE
                           || e.health == HealthState.CORRUPT); break;
            }
            if (!ok)
                return false;
        }

        // 搜索
        string q = search.get_text ().strip ().down ();
        if (q != "") {
            if (!e.get_best_name ().down ().contains (q)
                && !e.basename.down ().contains (q)
                && !e.path.down ().contains (q))
                return false;
        }

        return true;
    }

    private void set_all_checked (bool on) {
        Gtk.TreeIter it;
        bool valid = filter.get_iter_first (out it);
        while (valid) {
            AppEntry? e = null;
            filter.get (it, Col.ENTRY, out e);
            bool actionable = (e != null && e.is_actionable ());
            Gtk.TreeIter child;
            filter.convert_iter_to_child_iter (out child, it);
            model.set (child, Col.CHECK, on && actionable);
            valid = filter.iter_next (ref it);
        }
        update_selection_ui ();
    }

    /** 统计勾选数量 */
    private int count_checked () {
        int n = 0;
        Gtk.TreeIter it;
        bool valid = model.get_iter_first (out it);
        while (valid) {
            bool c;
            model.get (it, Col.CHECK, out c);
            if (c) n++;
            valid = model.iter_next (ref it);
        }
        return n;
    }

    /** 收集勾选的条目 */
    private AppEntry[] collect_checked () {
        var list = new GenericArray<AppEntry> ();
        Gtk.TreeIter it;
        bool valid = model.get_iter_first (out it);
        while (valid) {
            bool c;
            AppEntry? e = null;
            model.get (it, Col.CHECK, out c, Col.ENTRY, out e);
            if (c && e != null)
                list.add (e);
            valid = model.iter_next (ref it);
        }
        return list.steal ();
    }

    /** 收集选中的行（用于编辑/测试这类单条操作）*/
    private AppEntry[] collect_selected () {
        var list = new GenericArray<AppEntry> ();
        var sel = tree.get_selection ();
        unowned Gtk.TreeModel m = null;
        GLib.List<Gtk.TreePath> paths = sel.get_selected_rows (out m);
        if (m == null)
            return list.steal ();

        foreach (unowned Gtk.TreePath p in paths) {
            Gtk.TreeIter it;
            if (!m.get_iter (out it, p))
                continue;
            AppEntry? e = null;
            m.get (it, Col.ENTRY, out e);
            if (e != null)
                list.add (e);
        }
        return list.steal ();
    }

    private void update_selection_ui () {
        int checked = count_checked ();
        var selected = collect_selected ();

        // 浮动条
        bool show = (selected.length > 0);
        overlay_revealer.set_reveal_child (show);
        if (show) {
            overlay_label.set_text ("已选 %d 项".printf (selected.length));
            apply_button_states (selected);
        }

        // 全选按钮的三态
        select_all.toggled.disconnect (on_select_all_toggled);
        select_all.set_inconsistent (false);
        if (checked == 0)
            select_all.set_active (false);
        else
            select_all.set_active (true);
        select_all.toggled.connect (on_select_all_toggled);

        sel_count.set_text (checked > 0 ? "已勾选 %d 项".printf (checked) : "");
    }

    private void on_select_all_toggled () {
        set_all_checked (select_all.get_active ());
    }

    /** 按选中项的状态决定按钮可用性 */
    private void apply_button_states (AppEntry[] sel) {
        bool any_new = false, any_reg = false, any_ext = false, any_bad = false;
        foreach (var e in sel) {
            switch (e.match) {
                case MatchState.NEW:        any_new = true; break;
                case MatchState.REGISTERED: any_reg = true; break;
                case MatchState.EXTERNAL:   any_ext = true; break;
                case MatchState.BROKEN:     any_bad = true; break;
            }
        }

        if (any_bad) {
            act_create.set_sensitive (false);
            act_icon.set_sensitive (false);
            act_edit.set_sensitive (false);
            act_delete.set_sensitive (false);
            act_test.set_sensitive (false);
            return;
        }

        act_create.set_sensitive (any_new);
        act_test.set_sensitive (true);
        act_icon.set_sensitive (any_reg || any_ext || any_new);

        if (any_reg || any_ext) {
            act_edit.set_sensitive (any_reg || any_ext);
            act_delete.set_sensitive (any_reg || any_ext);
        } else {
            act_edit.set_sensitive (false);
            act_delete.set_sensitive (false);
        }
    }

    // ══════════════════════════════════════════════════════════════
    //  动作
    // ══════════════════════════════════════════════════════════════

    private void on_row_activated (Gtk.TreePath path) {
        var sel = collect_selected ();
        if (sel.length == 0)
            return;
        var e = sel[0];
        if (e.match == MatchState.NEW)
            do_create (sel);
        else if (e.match == MatchState.REGISTERED || e.match == MatchState.EXTERNAL)
            do_edit (e);
    }

    private void on_primary_action () {
        var sel = collect_selected ();
        if (sel.length == 0)
            return;
        if (sel[0].match == MatchState.NEW)
            do_create (sel);
        else
            do_edit (sel[0]);
    }

    private void on_act_create () {
        var sel = collect_selected ();
        var targets = new GenericArray<AppEntry> ();
        foreach (var e in sel)
            if (e.match == MatchState.NEW)
                targets.add (e);
        if (targets.length == 0) {
            show_msg ("选中的条目都已创建过启动器");
            return;
        }
        do_create (targets.steal ());
    }

    private void on_act_icon () {
        var sel = collect_selected ();
        if (sel.length > 0)
            do_extract_icons (sel);
    }

    private void on_act_edit () {
        var sel = collect_selected ();
        if (sel.length > 0)
            do_edit (sel[0]);
    }

    private void on_act_delete () {
        var sel = collect_selected ();
        var targets = new GenericArray<AppEntry> ();
        foreach (var e in sel)
            if (e.match == MatchState.REGISTERED || e.match == MatchState.EXTERNAL)
                targets.add (e);
        if (targets.length == 0)
            return;

        var dlg = new Gtk.MessageDialog (this,
            Gtk.DialogFlags.MODAL, Gtk.MessageType.QUESTION,
            Gtk.ButtonsType.NONE,
            "删除 %d 个启动器？", targets.length);
        dlg.format_secondary_text (
            "将删除对应的 .desktop 文件。AppImage 本体不受影响，\n"
            + "原文件会先备份，可随时从「修复历史」还原。");
        dlg.add_button ("取消", Gtk.ResponseType.CANCEL);
        dlg.add_button ("删除", Gtk.ResponseType.OK);
        dlg.set_default_response (Gtk.ResponseType.CANCEL);
        int r = dlg.run ();
        dlg.destroy ();

        if (r != Gtk.ResponseType.OK)
            return;

        var res = Repair.delete_launchers (targets.steal (), config);
        store.rescan ();
        if (res.failed == 0)
            show_info ("✓ 已删除 %d 个启动器".printf (res.created));
        else
            show_msg ("删除完成：成功 %d，失败 %d".printf (res.created, res.failed));
    }

    private void on_act_test () {
        var sel = collect_selected ();
        if (sel.length == 0)
            return;
        do_test (sel[0]);
    }

    private void do_create (AppEntry[] targets) {
        // 图标还没提取的，先提取
        var need_icon = new GenericArray<AppEntry> ();
        foreach (var e in targets)
            if (!e.icon_extracted)
                need_icon.add (e);

        if (need_icon.length > 0)
            do_extract_icons (need_icon.steal (), () => { finish_create (targets); return false; });
        else
            finish_create (targets);
    }

    private void finish_create (AppEntry[] targets) {
        var res = Repair.create_launchers (targets, config, store);
        store.rescan ();

        string msg = "✓ 已创建 %d 个启动器".printf (res.created);
        if (res.skipped > 0)
            msg += " · 跳过 %d 个（已存在）".printf (res.skipped);
        if (res.failed > 0)
            msg += " · ✗ %d 个失败".printf (res.failed);

        if (res.failed > 0) {
            show_msg (msg + "\n\n" + string.joinv ("\n", res.messages));
        } else {
            show_info (msg);
        }
    }

    private void do_edit (AppEntry e) {
        if (e.entry == null) {
            show_msg ("该条目没有对应的 .desktop 文件");
            return;
        }
        var result = Dialogs.edit_launcher (this, e, config);
        store.rescan ();
        if (result != null)
            show_info (result);
    }

    /**
     * 后台提取图标。
     *
     * @param after_done 全部完成后回到主线程调用
     */
    private void do_extract_icons (AppEntry[] targets, owned GLib.SourceFunc? after_done = null) {
        var dlg = Dialogs.progress (this, "正在提取图标");
        dlg.set_progress (0, targets.length, "");

        var queue = new GenericArray<AppEntry> ();
        foreach (var e in targets)
            queue.add (e);

        int done = 0;
        int fails = 0;

        GLib.Thread<void*> t = new GLib.Thread<void*> ("extract", () => {
            foreach (var e in queue) {
                if (dlg.cancelled)
                    break;

                string label = e.basename;
                GLib.Idle.add (() => {
                    dlg.set_progress (done, targets.length, label);
                    return false;
                });

                string work = GLib.Path.build_filename (
                    AppPath.tmp_extract_dir (),
                    "%s-%u".printf (e.get_slug (),
                                    (uint)(GLib.get_real_time () % 100000)));

                var info = AppImageExtract.run (e.path, work);
                bool ok = false;

                if (info.ok) {
                    string? icon = AppImageExtract.install_icon (info, config);
                    if (icon != null) {
                        e.icon_path = icon;
                        e.icon_extracted = true;
                        ok = true;
                    }
                }
                info.cleanup_extract ();

                if (ok) {
                    done++;
                    string nm = e.basename;
                    GLib.Idle.add (() => { dlg.log_done (nm); return false; });
                } else {
                    fails++;
                    string nm = e.basename;
                    string err = info.error != "" ? info.error : "未找到可用图标";
                    GLib.Idle.add (() => { dlg.log_fail (nm, err); return false; });
                }
            }

            GLib.Idle.add (() => {
                dlg.finish ();
                DesktopFiles.refresh_icon_cache (config.should_update_icon_cache ());
                store.rescan ();
                if (after_done != null) {
                    after_done ();
                } else {
                    if (fails == 0)
                        show_info ("✓ 已提取 %d 个图标".printf (done));
                    else
                        show_msg ("图标提取完成：成功 %d，失败 %d".printf (done, fails));
                }
                return false;
            });
            return null;
        });
    }

    private void do_test (AppEntry e) {
        var res = AppImageExtract.test_launch (e.path, 10000);

        var dlg = new Gtk.MessageDialog (this, Gtk.DialogFlags.MODAL,
            res.success ? Gtk.MessageType.INFO : Gtk.MessageType.ERROR,
            Gtk.ButtonsType.NONE, "测试启动 — %s".printf (e.get_best_name ()));

        string body = res.success
            ? "✓ %s".printf (res.message)
            : "✗ %s".printf (res.message);

        string err = (res.stderr ?? "").strip ();
        if (err != "")
            body += "\n\n输出：\n" + truncate (err, 800);

        dlg.format_secondary_text (body);
        dlg.add_button ("关闭", Gtk.ResponseType.CLOSE);
        dlg.run ();
        dlg.destroy ();
    }

    private string truncate (string s, int max) {
        if (s.length <= max)
            return s;
        return s.substring (0, max) + "\n…（已截断）";
    }

    // ══════════════════════════════════════════════════════════════
    //  目录管理
    // ══════════════════════════════════════════════════════════════

    private void on_add_dir () {
        var chooser = new Gtk.FileChooserDialog (
            "选择要扫描的目录", this,
            Gtk.FileChooserAction.SELECT_FOLDER,
            "取消", Gtk.ResponseType.CANCEL,
            "添加", Gtk.ResponseType.ACCEPT);
        chooser.set_modal (true);
        if (chooser.run () == Gtk.ResponseType.ACCEPT) {
            string dir = chooser.get_filename ();
            if (dir != null) {
                config.add_scan_dir (dir);
                config.save ();
                rebuild_dir_chips ();
                refresh ();
            }
        }
        chooser.destroy ();
    }

    private void on_remove_dir (string dir) {
        var dlg = new Gtk.MessageDialog (this, Gtk.DialogFlags.MODAL,
            Gtk.MessageType.QUESTION, Gtk.ButtonsType.NONE,
            "移除扫描目录？");
        dlg.format_secondary_text ("%s\n\n仅从扫描列表移除，不会删除目录或其中的文件。".printf (dir));
        dlg.add_button ("取消", Gtk.ResponseType.CANCEL);
        dlg.add_button ("移除", Gtk.ResponseType.OK);
        dlg.set_default_response (Gtk.ResponseType.CANCEL);
        int r = dlg.run ();
        dlg.destroy ();
        if (r != Gtk.ResponseType.OK)
            return;

        config.remove_scan_dir (dir);
        config.save ();
        rebuild_dir_chips ();
        refresh ();
    }

    // ══════════════════════════════════════════════════════════════
    //  菜单
    // ══════════════════════════════════════════════════════════════

    private void on_menu_dirs () {
        // 复用第一次运行向导的目录选择页：这里用简单对话框
        var dlg = new Gtk.Dialog.with_buttons ("扫描目录", this,
            Gtk.DialogFlags.MODAL, "关闭", Gtk.ResponseType.CLOSE);
        dlg.set_default_size (560, 340);
        dlg.set_border_width (12);

        var content = dlg.get_content_area ();
        var list = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);

        foreach (string d in config.scan_dirs ()) {
            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            bool ok = AppPath.is_dir (d);
            var icon = new Gtk.Image.from_icon_name (
                ok ? "folder-symbolic" : "dialog-warning-symbolic",
                Gtk.IconSize.BUTTON);
            row.pack_start (icon, false, false, 0);
            var lab = new Gtk.Label (AppPath.shorten (d));
            lab.set_xalign (0.0f);
            lab.set_ellipsize (Pango.EllipsizeMode.MIDDLE);
            row.pack_start (lab, true, true, 0);
            var hint = new Gtk.Label (ok ? "" : "不存在");
            hint.get_style_context ().add_class ("dim-label");
            row.pack_start (hint, false, false, 0);
            list.pack_start (row, false, false, 0);
        }

        content.pack_start (list, true, true, 0);
        dlg.show_all ();
        dlg.run ();
        dlg.destroy ();
    }

    private void on_menu_history () {
        Dialogs.history (this, config);
        store.rescan ();
    }

    private void on_menu_settings () {
        int before = config.icon_size ();
        if (Dialogs.settings (this, config)) {
            config.save ();
            if (config.icon_size () != before) {
                DesktopFiles.refresh_icon_cache (true);
            }
            refresh ();
        }
    }

    private void on_menu_cleanup () {
        if (Dialogs.cleanup (this, store) > 0) {
            store.rescan ();
            show_info ("✓ 清理完成");
        }
    }

    private void on_menu_health () {
        // 把所有有问题的条目勾选出来，切到「可优化」过滤
        filter_combo.set_active (5);
        int n = 0;
        Gtk.TreeIter it;
        bool valid = model.get_iter_first (out it);
        while (valid) {
            AppEntry? e = null;
            model.get (it, Col.ENTRY, out e);
            if (e != null && (e.health == HealthState.IMPROVABLE
                           || e.health == HealthState.CORRUPT)) {
                model.set (it, Col.CHECK, true);
                n++;
            }
            valid = model.iter_next (ref it);
        }
        update_selection_ui ();
        if (n == 0)
            show_info ("✓ 没有发现可优化或损坏的启动器");
        else
            show_msg ("发现 %d 个可优化或损坏的启动器，已自动勾选。\n"
                      .printf (n)
                      + "在列表中双击任一条目即可打开修复对话框。");
    }

    private void on_menu_about () {
        var dlg = new Gtk.AboutDialog ();
        dlg.set_transient_for (this);
        dlg.set_modal (true);
        dlg.set_program_name ("AppImage Manager");
        dlg.set_version (APPMGR_VERSION);
        dlg.set_comments ("扫描 AppImage、管理目录并创建与修复桌面启动器");
        dlg.set_license_type (Gtk.License.MIT_X11);
        dlg.set_logo_icon_name ("appimage-manager");
        dlg.set_website ("https://github.com/");
        dlg.run ();
        dlg.destroy ();
    }

    // ══════════════════════════════════════════════════════════════
    //  提示
    // ══════════════════════════════════════════════════════════════

    private void show_info (string text) {
        infobar.set_message_type (Gtk.MessageType.INFO);
        infobar_label.set_text (text);
        infobar.show_all ();
        auto_hide_infobar (6000);
    }

    private void show_msg (string text) {
        infobar.set_message_type (Gtk.MessageType.WARNING);
        infobar_label.set_text (text);
        infobar.show_all ();
        auto_hide_infobar (12000);
    }

    private uint hide_timer = 0;

    private void auto_hide_infobar (uint ms) {
        if (hide_timer != 0) {
            GLib.Source.remove (hide_timer);
            hide_timer = 0;
        }
        hide_timer = GLib.Timeout.add (ms, () => {
            hide_timer = 0;
            // 失效警告不应该被自动隐藏
            if (store.broken_entries.length == 0)
                infobar.hide ();
            return false;
        });
    }

    // ══════════════════════════════════════════════════════════════
    //  崩溃恢复
    // ══════════════════════════════════════════════════════════════

    public void check_crash_recovery () {
        var pending = Journal.pending ();
        if (pending.length == 0)
            return;

        var tx = pending[0];
        var dlg = new Gtk.MessageDialog (this, Gtk.DialogFlags.MODAL,
            Gtk.MessageType.WARNING, Gtk.ButtonsType.NONE,
            "检测到未完成的修复事务");
        dlg.format_secondary_text (
            "上次运行意外中断（%s）\n\n"
            .printf (tx.started_at)
            + "事务 %s · 共 %d 个文件 · 已完成 %d 个\n\n"
              .printf (tx.txid, tx.total (), tx.done ())
            + "磁盘上的文件不会处于半写状态（每步都是原子重命名），\n"
            + "最坏情况只是「部分已修、部分未修」。" );
        dlg.add_button ("保留现状并归档", Gtk.ResponseType.CLOSE);
        dlg.add_button ("全部回滚", Gtk.ResponseType.REJECT);
        dlg.set_default_response (Gtk.ResponseType.CLOSE);
        int r = dlg.run ();
        dlg.destroy ();

        if (r == Gtk.ResponseType.REJECT) {
            var rr = Backup.restore (tx, Backup.ConflictPolicy.STASH);
            tx.mark_rolled_back ();
            store.rescan ();
            show_info ("✓ 已回滚 %d 个文件".printf (rr.restored));
        } else {
            Journal.archive_interrupted (tx);
            show_info ("已归档中断的事务 %s".printf (tx.txid));
        }
    }

    /** GenericArray 在这套 vapi 里没有 contains */
    private static bool has_str (GenericArray<string> a, string want) {
        unowned string[] raw = (string[]) a.data;
        for (uint i = 0; i < a.length; i++)
            if (raw[i] == want)
                return true;
        return false;
    }

    /** 首次运行钩子：由 main.vala 调用 */
    public void maybe_show_wizard () {
        if (config.is_configured ())
            return;
        refresh ();
    }
}
