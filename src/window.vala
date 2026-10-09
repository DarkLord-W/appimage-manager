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

    // ── 工具栏与菜单 ──────────────────────────────────────────────
    private Gtk.Box toolbar;
    private Gtk.AccelGroup accel_group;
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

    // ── 常驻操作条（批量，听「勾选优先，回退选中」）─────────────────
    private Gtk.Button bar_create;
    private Gtk.Button bar_repair;
    private Gtk.Button bar_claim;
    private Gtk.Button bar_icon;
    private Gtk.Button bar_delete;

    // ── 浮动操作条（单条，只听行选中）─────────────────────────────
    private Gtk.Revealer overlay_revealer;
    private Gtk.Box overlay_box;
    private Gtk.Label overlay_label;
    private Gtk.Button act_edit;
    private Gtk.Button act_test;
    private Gtk.Button act_open_dir;
    private Gtk.Button act_copy_path;

    // ── InfoBar ───────────────────────────────────────────────────
    private Gtk.InfoBar infobar;
    private Gtk.Label infobar_label;

    // ── 状态 ──────────────────────────────────────────────────────
    private int filter_mode = 0;      // 0=全部 1=新发现 2=已创建 3=外部 4=失效 5=可优化
    private bool scanning = false;
    private bool suppress_select_all = false;   // 抑制「全选」信号的递归

    // ── 跨「图标提取 → 创建」保留的强引用 ────────────────────────
    //
    // 图标提取是后台线程，回调在它结束后才执行；而 do_extract_icons
    // 在回调之前会调用 store.rescan()，那会重建 ListStore 并释放旧的
    // AppEntry。Vala 的闭包只复制数组指针、不接管所有权，所以回调里
    // 拿到的会是悬空指针（实测崩溃点：repair_create_launchers 里的
    // g_object_ref）。
    //
    // 因此由窗口自己持有一份强引用，跨过 rescan 这段窗口期。
    private GLib.List<AppEntry>? pending_entries = null;

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

        // 最小尺寸：能缩到和别的窗口并排。过滤+操作条那一行套了横向
        // 滚动，所以窄窗口下不会破版。
        set_size_request (620, 400);
        icon_name = "appimage-manager";

        // 用原生窗口装饰（不再 set_titlebar），最小化/最大化/关闭由窗口
        // 管理器绘制 —— 自绘标题栏在第三方主题（如 Windows-10）下会把
        // 这两个按钮画成空白圆圈。
        set_wmclass ("AppImage Manager", "AppImage Manager");

        build_toolbar ();
        build_body ();
        build_infobar ();
        build_empty_state ();

        var root = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

        accel_group = new Gtk.AccelGroup ();
        add_accel_group (accel_group);

        root.pack_start (new Menus.AppMenuBar (this, accel_group), false, false, 0);
        root.pack_start (toolbar, false, false, 0);
        root.pack_start (dir_bar_widget, false, false, 0);
        // 这一行控件多，窄窗口下让它横向滚动，而不是撑破最小宽度
        filter_scroll = new Gtk.ScrolledWindow (null, null);
        filter_scroll.set_policy (Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.NEVER);
        filter_scroll.add (filter_bar_widget);
        root.pack_start (filter_scroll, false, false, 0);
        root.pack_start (content_stack, true, true, 0);
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

        update_empty_state ();
    }

    // ══════════════════════════════════════════════════════════════
    //  构建：工具栏（重新扫描 / 搜索 / 统计）
    // ══════════════════════════════════════════════════════════════

    private void build_toolbar () {
        toolbar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        toolbar.get_style_context ().add_class ("app-toolbar");

        refresh_btn = new Gtk.Button ();
        refresh_btn.set_tooltip_text ("重新扫描 (F5)");
        refresh_btn.set_always_show_image (true);
        refresh_btn.set_label ("重新扫描");
        var refresh_icon = new Gtk.Image.from_icon_name ("view-refresh-symbolic",
                                                         Gtk.IconSize.BUTTON);
        refresh_btn.set_image (refresh_icon);
        toolbar.pack_start (refresh_btn, false, false, 0);

        spinner = new Gtk.Spinner ();
        spinner.set_no_show_all (true);
        toolbar.pack_start (spinner, false, false, 0);

        search = new Gtk.SearchEntry ();
        search.set_placeholder_text ("搜索名称或路径…");
        search.set_width_chars (24);
        toolbar.pack_start (search, false, false, 0);

        // 右侧实时统计
        subtitle_label = new Gtk.Label ("正在初始化…");
        subtitle_label.get_style_context ().add_class ("app-subtitle");
        subtitle_label.set_ellipsize (Pango.EllipsizeMode.END);
        toolbar.pack_end (subtitle_label, false, false, 0);
    }

    // ══════════════════════════════════════════════════════════════
    //  构建：目录条 / 过滤条 / 内容区
    // ══════════════════════════════════════════════════════════════

    private Gtk.ScrolledWindow? dir_bar_widget = null;
    private Gtk.Box? filter_bar_widget = null;
    private Gtk.Overlay? content = null;
    private Gtk.Stack? content_stack = null;
    private Gtk.Widget? empty_state = null;
    private Gtk.Widget? list_empty_hint = null;
    private Gtk.ScrolledWindow? filter_scroll = null;
    private Gtk.TreeViewColumn? pill_col = null;
    private PillRenderer? pill_renderer = null;

    private void build_body () {
        build_dir_bar ();
        build_filter_bar ();
        build_tree ();
        build_context_menu ();
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

    /** 供 main.vala 在向导结束后刷新目录 chips */
    public void rebuild_dir_chips_public () {
        rebuild_dir_chips ();
        update_empty_state ();
        update_subtitle ();
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

        // ── 常驻操作条：批量操作，入口永远可见 ────────────────────
        var sep = new Gtk.Separator (Gtk.Orientation.VERTICAL);
        filter_bar_widget.pack_start (sep, false, false, 4);

        bar_create = mk_action ("⚡ 创建", "为勾选的 AppImage 创建桌面启动器", () => {
            on_bar_create (); return false; });
        bar_repair = mk_action ("🔧 修复", "检查并修复勾选项的 .desktop 文件", () => {
            on_bar_repair (); return false; });
        bar_claim  = mk_action ("🔗 认领", "把外部创建的启动器纳入本工具管理", () => {
            on_bar_claim (); return false; });
        bar_icon   = mk_action ("🖼 图标", "为勾选项重新提取图标", () => {
            on_bar_icon (); return false; });
        bar_delete = mk_action ("🗑 删除", "删除勾选项对应的桌面启动器", () => {
            on_bar_delete (); return false; });

        foreach (var b in new Gtk.Button[] { bar_create, bar_repair, bar_claim,
                                             bar_icon, bar_delete })
            filter_bar_widget.pack_start (b, false, false, 0);
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

        // 右键菜单：最符合直觉的操作入口
        tree.button_press_event.connect (on_tree_button_press);
    }

    // ── 右键菜单 ──────────────────────────────────────────────────

    private Gtk.Menu? context_menu = null;
    private Gtk.MenuItem ctx_create;
    private Gtk.MenuItem ctx_repair;
    private Gtk.MenuItem ctx_claim;
    private Gtk.MenuItem ctx_edit;
    private Gtk.MenuItem ctx_delete;
    private Gtk.MenuItem ctx_open_dir;
    private Gtk.MenuItem ctx_test;
    private Gtk.MenuItem ctx_copy;

    private bool on_tree_button_press (Gdk.EventButton ev) {
        if (ev.button != 3)          // 只处理右键
            return false;

        // 右键落在哪一行就选中哪一行；如果已经有选中则保持（支持多选操作）
        Gtk.TreePath? path = null;
        tree.get_path_at_pos ((int) ev.x, (int) ev.y, out path, null, null, null);
        if (path != null && !tree.get_selection ().path_is_selected (path)) {
            tree.get_selection ().unselect_all ();
            tree.get_selection ().select_path (path);
        }
        if (path == null && collect_selected ().length == 0)
            return false;   // 空白处右键且无选中 → 不弹菜单

        show_context_menu (ev);
        return true;
    }

    private void build_context_menu () {
        context_menu = new Gtk.Menu ();

        ctx_create = mk_menu_item ("⚡  创建启动器", () => { on_bar_create (); });
        ctx_repair = mk_menu_item ("🔧  修复问题…",    () => { on_bar_repair (); });
        ctx_claim  = mk_menu_item ("🔗  认领…",        () => { on_bar_claim (); });
        context_menu.append (ctx_create);
        context_menu.append (ctx_repair);
        context_menu.append (ctx_claim);
        context_menu.append (new Gtk.SeparatorMenuItem ());

        ctx_edit      = mk_menu_item ("✎  编辑…",          () => { on_act_edit (); });
        ctx_delete    = mk_menu_item ("🗑  删除",          () => { on_bar_delete (); });
        context_menu.append (ctx_edit);
        context_menu.append (ctx_delete);
        context_menu.append (new Gtk.SeparatorMenuItem ());

        ctx_open_dir  = mk_menu_item ("📂  打开所在目录",  () => { on_act_open_dir (); });
        ctx_test      = mk_menu_item ("▶  测试启动",       () => { on_act_test (); });
        ctx_copy      = mk_menu_item ("⧉  复制路径",       () => { on_act_copy_path (); });
        context_menu.append (ctx_open_dir);
        context_menu.append (ctx_test);
        context_menu.append (ctx_copy);

        // 借用常驻条的启用规则算出可用性，再映射到菜单项
        context_menu.show_all ();
    }

    private Gtk.MenuItem mk_menu_item (string label, owned SimpleAction cb) {
        var item = new Gtk.MenuItem.with_label (label);
        item.activate.connect (() => { cb (); });
        return item;
    }

    /** 菜单项的可用性跟常驻条保持一致，禁用时把原因写进 tooltip */
    private void sync_context_menu (AppEntry[] targets) {
        if (context_menu == null)
            return;

        int n_new = 0, n_reg = 0, n_ext = 0, n_problem = 0;
        foreach (var e in targets) {
            switch (e.match) {
                case MatchState.NEW:        n_new++;    break;
                case MatchState.REGISTERED: n_reg++;    break;
                case MatchState.EXTERNAL:   n_ext++;    break;
            }
            if (e.health == HealthState.IMPROVABLE || e.health == HealthState.CORRUPT)
                n_problem++;
        }

        bool has_reg = (n_reg + n_ext) > 0;
        set_menu_item (ctx_create, n_new > 0,
            n_new > 0 ? "创建启动器" : "没有「新发现」的条目");
        set_menu_item (ctx_repair, n_problem > 0,
            n_problem > 0 ? "修复问题" : "没有需要修复的问题");
        set_menu_item (ctx_claim, n_ext > 0,
            n_ext > 0 ? "认领" : "没有「外部创建」的条目");
        set_menu_item (ctx_edit, has_reg,
            has_reg ? "编辑" : "这个条目还没有启动器");
        set_menu_item (ctx_delete, has_reg,
            has_reg ? "删除" : "这个条目还没有启动器");
        set_menu_item (ctx_open_dir, targets.length > 0, "打开所在目录");
        set_menu_item (ctx_test, targets.length > 0, "测试启动");
        set_menu_item (ctx_copy, targets.length > 0, "复制路径");
    }

    private void set_menu_item (Gtk.MenuItem item, bool sensitive, string tip) {
        if (item == null)
            return;
        item.set_sensitive (sensitive);
        item.set_tooltip_text (tip);
    }

    private void show_context_menu (Gdk.EventButton ev) {
        sync_context_menu (resolve_targets ());
        context_menu.popup_at_pointer (ev);
    }

    private void build_overlay () {
        content = new Gtk.Overlay ();
        content.add (scrolled);

        // 浮层只放「单条」操作，与常驻条的批量操作零重叠
        overlay_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
        overlay_box.get_style_context ().add_class ("action-overlay");

        overlay_label = new Gtk.Label ("已选 0 项");
        overlay_box.pack_start (overlay_label, false, false, 0);

        overlay_box.pack_start (new Gtk.Separator (Gtk.Orientation.VERTICAL),
                                false, false, 2);

        act_edit      = mk_action ("✎ 编辑", "编辑当前条目的启动器", () => { on_act_edit (); return false; });
        act_test      = mk_action ("▶ 测试", "试运行这个 AppImage", () => { on_act_test (); return false; });
        act_open_dir  = mk_action ("📂 目录", "在文件管理器中打开所在目录", () => { on_act_open_dir (); return false; });
        act_copy_path = mk_action ("⧉ 复制", "复制 AppImage 完整路径", () => { on_act_copy_path (); return false; });

        foreach (var b in new Gtk.Button[] { act_edit, act_test,
                                             act_open_dir, act_copy_path })
            overlay_box.pack_start (b, false, false, 0);

        overlay_revealer = new Gtk.Revealer ();
        overlay_revealer.set_transition_type (Gtk.RevealerTransitionType.SLIDE_UP);
        overlay_revealer.set_transition_duration (200);
        overlay_revealer.set_halign (Gtk.Align.END);
        overlay_revealer.set_valign (Gtk.Align.END);
        overlay_revealer.set_margin_end (16);
        overlay_revealer.set_margin_bottom (16);
        overlay_revealer.add (overlay_box);

        // no_show_all 是 Revealer 的标准用法（由它自己管子控件显隐），
        // 但必须显式 show() —— 否则 show_all() 会跳过它，
        // 结果 reveal_child 再为真也永远看不见。
        overlay_revealer.set_no_show_all (true);
        overlay_revealer.show ();

        content.add_overlay (overlay_revealer);

        // 有扫描目录、但一个 AppImage 都没扫到时的提示。
        // 比一片空白强 —— 用户至少知道程序跑了、只是没东西。
        list_empty_hint = build_list_empty_hint ();
        content.add_overlay (list_empty_hint);
        list_empty_hint.hide ();   // 初始隐藏，由 update_list_hint() 决定
    }

    private Gtk.Widget build_list_empty_hint () {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        box.get_style_context ().add_class ("list-empty-hint");
        box.set_halign (Gtk.Align.CENTER);
        box.set_valign (Gtk.Align.CENTER);

        var icon = new Gtk.Image.from_icon_name ("edit-find-symbolic",
                                                 Gtk.IconSize.DIALOG);
        icon.set_pixel_size (48);
        box.pack_start (icon, false, false, 0);

        var title = new Gtk.Label ("这个目录里没有找到 AppImage");
        title.get_style_context ().add_class ("title");
        box.pack_start (title, false, false, 0);

        var hint = new Gtk.Label ("换一个目录，或在菜单里点「视图 → 重新扫描」再试一次");
        hint.get_style_context ().add_class ("hint");
        box.pack_start (hint, false, false, 0);

        return box;
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
    //  空状态引导（替代首次运行向导）
    // ══════════════════════════════════════════════════════════════

    private void build_empty_state () {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 14);
        box.set_valign (Gtk.Align.CENTER);
        box.set_halign (Gtk.Align.CENTER);
        box.set_border_width (32);

        var icon = new Gtk.Image.from_icon_name ("folder-symbolic",
                                                 Gtk.IconSize.DIALOG);
        icon.set_pixel_size (72);
        icon.get_style_context ().add_class ("empty-icon");
        box.pack_start (icon, false, false, 0);

        var title = new Gtk.Label (null);
        title.use_markup = true;
        title.label = "<span size='x-large' weight='bold'>还没有添加扫描目录</span>";
        box.pack_start (title, false, false, 0);

        var hint = new Gtk.Label (
            "添加一个目录，程序会扫描其中的 AppImage，\n"
            + "并帮你创建规范的桌面启动器。");
        hint.set_justify (Gtk.Justification.CENTER);
        hint.get_style_context ().add_class ("dim-label");
        box.pack_start (hint, false, false, 0);

        var btn_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
        btn_row.set_halign (Gtk.Align.CENTER);

        var add = new Gtk.Button.with_label ("添加目录…");
        add.get_style_context ().add_class ("suggested-action");
        add.clicked.connect (() => on_add_dir ());
        btn_row.pack_start (add, false, false, 0);

        var common = new Gtk.Button.with_label ("看看常见位置");
        common.clicked.connect (() => on_common_locations ());
        btn_row.pack_start (common, false, false, 0);

        box.pack_start (btn_row, false, false, 0);

        empty_state = box;

        content_stack = new Gtk.Stack ();
        content_stack.set_transition_type (Gtk.StackTransitionType.CROSSFADE);
        content_stack.set_transition_duration (180);
        content_stack.add_named (content, "list");
        content_stack.add_named (empty_state, "empty");
    }

    /** 没有扫描目录时显示引导页，否则显示列表 */
    private void update_empty_state () {
        if (content_stack == null)
            return;
        bool no_dirs = (config.scan_dirs ().length == 0);
        content_stack.set_visible_child_name (no_dirs ? "empty" : "list");
    }

    /**
     * 有扫描目录但一个条目都没有时，在列表上叠一句提示。
     * 与「没有目录」的空状态区分开：那是有目录却没东西。
     */
    private void update_list_hint () {
        if (list_empty_hint == null)
            return;
        bool no_dirs = (config.scan_dirs ().length == 0);
        int n = (int) store.entries.length ();
        list_empty_hint.visible = (!no_dirs && n == 0);
    }

    /** 「看看常见位置」：列出常见目录，可勾选并直接创建不存在的 */
    private void on_common_locations () {
        string[] candidates = {
            GLib.Path.build_filename (GLib.Environment.get_home_dir (), "Applications"),
            GLib.Path.build_filename (GLib.Environment.get_home_dir (), "apps"),
            GLib.Path.build_filename (GLib.Environment.get_home_dir (), "AppImages"),
            "/opt/appimages"
        };

        var dlg = new Gtk.Dialog.with_buttons ("常见位置", this,
            Gtk.DialogFlags.MODAL, "取消", Gtk.ResponseType.CANCEL,
            "添加选中的目录", Gtk.ResponseType.OK);
        dlg.set_default_size (560, 320);
        dlg.set_border_width (12);

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        var checks = new GLib.GenericArray<Gtk.CheckButton> ();
        var paths = new GLib.GenericArray<string> ();

        var head = new Gtk.Label (
            "勾选要扫描的目录。不存在的会一并创建。");
        head.set_xalign (0.0f);
        head.get_style_context ().add_class ("dim-label");
        box.pack_start (head, false, false, 6);

        foreach (string c in candidates) {
            bool exists = AppPath.is_dir (c);

            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            row.get_style_context ().add_class ("option-card");

            var cb = new Gtk.CheckButton ();
            cb.set_active (exists);
            row.pack_start (cb, false, false, 0);

            var lab = new Gtk.Label (AppPath.shorten (c));
            lab.set_xalign (0.0f);
            lab.set_ellipsize (Pango.EllipsizeMode.MIDDLE);
            row.pack_start (lab, true, true, 0);

            var st = new Gtk.Label (exists ? "已存在" : "不存在，将创建");
            st.get_style_context ().add_class ("dim-label");
            row.pack_start (st, false, false, 0);

            checks.add (cb);
            paths.add (c);
            box.pack_start (row, false, false, 0);
        }

        dlg.get_content_area ().add (box);
        dlg.show_all ();

        if (dlg.run () == Gtk.ResponseType.OK) {
            int added = 0;
            unowned Gtk.CheckButton[] chk = (Gtk.CheckButton[]) checks.data;
            string[] pth = paths.steal ();
            for (uint i = 0; i < checks.length; i++) {
                if (!chk[i].get_active ())
                    continue;
                string d = pth[i];
                if (!AppPath.is_dir (d) && !AppPath.ensure_dir (d))
                    continue;
                config.add_scan_dir (d);
                added++;
            }
            if (added > 0) {
                config.save ();
                rebuild_dir_chips ();
                update_empty_state ();
                refresh ();
            }
        }
        dlg.destroy ();
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
        // 复用菜单栏已经在用的 accel_group，避免建两个
        var accel = accel_group;

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
                       () => { on_bar_delete (); return true; });
        accel.connect (Gdk.Key.Return, 0, Gtk.AccelFlags.VISIBLE,
                       () => { on_primary_action (); return true; });
        accel.connect (Gdk.Key.Escape, 0, Gtk.AccelFlags.VISIBLE,
                       () => { infobar.hide (); return true; });
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
        // 连到带抑制标志的处理函数 —— 之前这里直连内联 lambda，
        // 绕过了标志，导致 update_selection_ui 里 set_active(true)
        // 反过来把所有行都勾上。
        select_all.toggled.connect (on_select_all_toggled);
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
            update_empty_state ();
            update_list_hint ();
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
                Col.ICON, e.get_thumbnail (40) ?? placeholder_icon (40),
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

    /** 没有图标时的占位图：一个淡色圆角方块 */
    private Gdk.Pixbuf? placeholder_icon (int size) {
        if (placeholder_cache != null)
            return placeholder_cache;

        var pb = new Gdk.Pixbuf (Gdk.Colorspace.RGB, true, 8, size, size);
        pb.fill (0x00000000);

        var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, size, size);
        var cr = new Cairo.Context (surface);
        cr.set_antialias (Cairo.Antialias.BEST);

        double r = 6.0;
        double m = 5.5;
        double w = size - 2 * m;
        cr.new_sub_path ();
        cr.arc (m + w - r, m + r,     r, -Math.PI / 2, 0);
        cr.arc (m + w - r, m + w - r, r, 0, Math.PI / 2);
        cr.arc (m + r,     m + w - r, r, Math.PI / 2, Math.PI);
        cr.arc (m + r,     m + r,     r, Math.PI, 3 * Math.PI / 2);
        cr.close_path ();

        // 用当前主题的弱化前景色，深浅主题都成立
        cr.set_source_rgba (0.55, 0.58, 0.62, 0.16);
        cr.fill_preserve ();
        cr.set_source_rgba (0.55, 0.58, 0.62, 0.38);
        cr.set_line_width (1.0);
        cr.stroke ();

        // 中间一个淡淡的「应用」轮廓
        cr.set_source_rgba (0.55, 0.58, 0.62, 0.42);
        cr.set_line_width (1.6);
        double cx = size / 2.0, cy = size / 2.0;
        double bw = size * 0.30, bh = size * 0.22;
        cr.rectangle (cx - bw / 2, cy - bh / 2, bw, bh);
        cr.stroke ();

        var out = Gdk.pixbuf_get_from_surface (surface, 0, 0, size, size);
        if (out == null)
            return null;
        placeholder_cache = out;
        return placeholder_cache;
    }

    private Gdk.Pixbuf? placeholder_cache = null;

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

    /**
     * TreeModelFilter 的可见性判定。
     *
     * 这里只做一件事：把 AppEntry 取出来，交给 Store.matches_filter 判。
     * 判定逻辑全部在纯函数里 —— 一是可被自测覆盖，二是避免在这里做
     * 任何列类型转换（曾经因为往 4 字节的枚举里读 8 字节的对象指针
     * 而破坏栈、一选过滤器就崩）。
     */
    private bool on_row_visible (Gtk.TreeModel m, Gtk.TreeIter it) {
        AppEntry? e = null;
        m.get (it, Col.ENTRY, out e);
        if (e == null)
            return false;

        return Store.matches_filter (e, filter_mode, search.get_text ());
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

    /** 统计当前过滤条件下可见的行数 */
    private int count_visible () {
        int n = 0;
        Gtk.TreeIter it;
        bool valid = filter.get_iter_first (out it);
        while (valid) {
            n++;
            valid = filter.iter_next (ref it);
        }
        return n;
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

    /**
     * 把「勾选优先，回退行选中」收敛成一处。
     *
     * 规则：
     *   1. 有勾选 → 只认勾选的（显式意图最强）
     *   2. 无勾选 → 回退到行选中的
     *   3. 都没有 → 空
     *
     * 批量操作与按钮状态全部走这个函数，避免各处理解不一致。
     */
    private AppEntry[] resolve_targets () {
        var checked = collect_checked ();
        if (checked.length > 0)
            return checked;
        return collect_selected ();
    }

    /** 目标是不是来自勾选（用于决定文案措辞） */
    private bool targets_from_checked (AppEntry[] targets) {
        return count_checked () > 0;
    }

    private void update_selection_ui () {
        int checked = count_checked ();
        var selected = collect_selected ();
        var targets = resolve_targets ();

        // ── 常驻操作条：批量，入口永远可见 ──
        apply_bar_states (targets);

        // ── 浮层：单条，只听行选中 ──
        bool show = (selected.length > 0);
        overlay_revealer.set_reveal_child (show);
        if (show) {
            overlay_label.set_text (selected.length == 1
                ? "选中 1 项"
                : "选中 %d 项".printf (selected.length));
            apply_overlay_states (selected);
        }

        // ── 全选按钮的三态 ──
        // 用标志抑制信号，而不是 disconnect/reconnect ——
        // 之前 disconnect 的目标和 connect 的不是同一个处理器，
        // 断不掉，每刷新一次就叠一层，越点越慢。
        // 三态：一个没勾 = 未选；全勾 = 已选；部分勾 = 半选（横杠）
        // 之前只要有一个勾就显示成「已选」，用户会误以为已全选。
        int visible = count_visible ();
        suppress_select_all = true;
        if (checked == 0) {
            select_all.set_inconsistent (false);
            select_all.set_active (false);
        } else if (visible > 0 && checked >= visible) {
            select_all.set_inconsistent (false);
            select_all.set_active (true);
        } else {
            select_all.set_inconsistent (true);
        }
        suppress_select_all = false;

        sel_count.set_text (checked > 0 ? "已勾选 %d 项".printf (checked) : "");
    }

    private void on_select_all_toggled () {
        if (suppress_select_all)
            return;   // 由 update_selection_ui 同步导致的，不要反向触达
        set_all_checked (select_all.get_active ());
    }

    /**
     * 常驻操作条：批量按钮的启用规则。
     * 每个按钮都在「目标里至少有一个能处理」时才亮，禁用时 tooltip 说明原因。
     */
    private void apply_bar_states (AppEntry[] targets) {
        int n_new = 0, n_reg = 0, n_ext = 0, n_broken = 0;
        int n_problem = 0, n_no_icon = 0;

        foreach (var e in targets) {
            switch (e.match) {
                case MatchState.NEW:        n_new++;    break;
                case MatchState.REGISTERED: n_reg++;    break;
                case MatchState.EXTERNAL:   n_ext++;    break;
                case MatchState.BROKEN:     n_broken++; break;
            }
            if (e.health == HealthState.IMPROVABLE || e.health == HealthState.CORRUPT)
                n_problem++;
            if (!e.icon_extracted)
                n_no_icon++;
        }

        bool empty = (targets.length == 0);

        set_btn (bar_create, !empty && n_new > 0,
            empty ? "先勾选要处理的 AppImage"
                  : (n_new > 0 ? "为 %d 个条目创建启动器".printf (n_new)
                               : "勾选的条目都已经有启动器了"));

        set_btn (bar_repair, !empty && n_problem > 0,
            empty ? "先勾选要处理的条目"
                  : (n_problem > 0 ? "检查并修复 %d 个条目的 .desktop".printf (n_problem)
                                   : "勾选的条目没有需要修复的问题"));

        set_btn (bar_claim, !empty && n_ext > 0,
            empty ? "先勾选要处理的条目"
                  : (n_ext > 0 ? "把 %d 个外部创建的启动器纳入管理".printf (n_ext)
                               : "勾选的条目都已在管理之下"));

        set_btn (bar_icon, !empty && n_no_icon > 0,
            empty ? "先勾选要处理的条目"
                  : (n_no_icon > 0 ? "为 %d 个条目提取图标".printf (n_no_icon)
                                   : "图标都已提取过了"));

        set_btn (bar_delete, !empty && (n_reg + n_ext) > 0,
            empty ? "先勾选要处理的条目"
                  : ((n_reg + n_ext) > 0
                        ? "删除 %d 个启动器（会先备份）".printf (n_reg + n_ext)
                        : "勾选的条目还没有启动器"));

        // 失效条目单独提示
        if (!empty && n_broken > 0 && targets.length == n_broken) {
            bar_repair.set_tooltip_text (
                "这些条目的 AppImage 已不存在，请用菜单里的「失效与孤儿清理」");
        }
    }

    /** 浮层：单条按钮的启用规则 */
    private void apply_overlay_states (AppEntry[] sel) {
        bool has_reg = false;
        bool has_broken = false;
        foreach (var e in sel) {
            if (e.match == MatchState.REGISTERED || e.match == MatchState.EXTERNAL)
                has_reg = true;
            if (e.match == MatchState.BROKEN)
                has_broken = true;
        }

        bool exists = false;
        if (sel.length > 0)
            exists = AppPath.exists (sel[0].path);

        set_btn (act_edit, has_reg,
            has_reg ? "编辑启动器" : "这个条目还没有启动器，先用「⚡ 创建」");
        set_btn (act_test, exists && !has_broken,
            has_broken ? "AppImage 文件已不存在"
                       : "试运行这个 AppImage");
        set_btn (act_open_dir, AppPath.is_dir (
                     GLib.Path.get_dirname (sel.length > 0 ? sel[0].path : "")),
            "在文件管理器中打开所在目录");
        set_btn (act_copy_path, sel.length > 0, "复制完整路径");
    }

    /** 设置按钮可用性，禁用时把原因写进 tooltip */
    private void set_btn (Gtk.Button b, bool sensitive, string tip) {
        if (b == null)
            return;
        b.set_sensitive (sensitive);
        b.set_tooltip_text (tip);
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
        // Enter：按「勾选优先」的目标来决定做创建还是编辑
        var targets = resolve_targets ();
        if (targets.length == 0)
            return;
        if (targets[0].match == MatchState.NEW)
            on_bar_create ();
        else if (targets[0].match == MatchState.EXTERNAL)
            on_bar_claim ();
        else
            do_edit (targets[0]);
    }

    // ── 常驻操作条的处理函数 ──────────────────────────────────────

    private void on_bar_create () {
        var targets = filter_by (resolve_targets (), MatchState.NEW);
        if (targets.length == 0) {
            show_msg ("要创建的目标里没有「新发现」的条目。");
            return;
        }
        do_create (targets);
    }

    private void on_bar_repair () {
        var all = resolve_targets ();
        var targets = new GenericArray<AppEntry> ();
        foreach (var e in all)
            if (e.health == HealthState.IMPROVABLE || e.health == HealthState.CORRUPT)
                targets.add (e);
        if (targets.length == 0) {
            show_msg ("要处理的目标里没有需要修复的条目。");
            return;
        }
        do_repair (targets.steal ());
    }

    private void on_bar_claim () {
        var targets = filter_by (resolve_targets (), MatchState.EXTERNAL);
        if (targets.length == 0) {
            show_msg ("要处理的目标里没有「外部创建」的条目。");
            return;
        }
        do_claim (targets);
    }

    private void on_bar_icon () {
        var all = resolve_targets ();
        var targets = new GenericArray<AppEntry> ();
        foreach (var e in all)
            if (!e.icon_extracted)
                targets.add (e);
        if (targets.length == 0) {
            show_msg ("要处理的目标里图标都已提取过了。");
            return;
        }
        do_extract_icons (targets.steal ());
    }

    private void on_bar_delete () {
        var all = resolve_targets ();
        var targets = new GenericArray<AppEntry> ();
        foreach (var e in all)
            if (e.match == MatchState.REGISTERED || e.match == MatchState.EXTERNAL)
                targets.add (e);
        if (targets.length == 0)
            return;
        confirm_delete (targets.steal ());
    }

    /** 从一组条目里挑出指定匹配状态的 */
    private AppEntry[] filter_by (AppEntry[] src, MatchState want) {
        var out_list = new GenericArray<AppEntry> ();
        foreach (var e in src)
            if (e.match == want)
                out_list.add (e);
        return out_list.steal ();
    }

    private void on_act_edit () {
        var sel = collect_selected ();
        if (sel.length > 0)
            do_edit (sel[0]);
    }

    private void on_act_test () {
        var sel = collect_selected ();
        if (sel.length == 0)
            return;
        do_test (sel[0]);
    }

    private void on_act_open_dir () {
        var sel = collect_selected ();
        if (sel.length == 0)
            return;
        string dir = GLib.Path.get_dirname (sel[0].path);
        if (!AppPath.is_dir (dir)) {
            show_msg ("目录不存在：%s".printf (dir));
            return;
        }
        open_in_file_manager (dir);
    }

    private void on_act_copy_path () {
        var sel = collect_selected ();
        if (sel.length == 0)
            return;
        string text = sel.length == 1
            ? sel[0].path
            : string.joinv ("\n", paths_of (sel));

        var cb = Gtk.Clipboard.get_for_display (
            Gdk.Display.get_default (), Gdk.SELECTION_CLIPBOARD);
        cb.set_text (text, -1);
        show_info (sel.length == 1
            ? "✓ 路径已复制"
            : "✓ 已复制 %d 条路径".printf (sel.length));
    }

    private string[] paths_of (AppEntry[] list) {
        var a = new GenericArray<string> ();
        foreach (var e in list)
            a.add (e.path);
        return a.steal ();
    }

    /** 用桌面默认的文件管理器打开目录 */
    private void open_in_file_manager (string dir) {
        try {
            GLib.AppInfo.launch_default_for_uri (
                GLib.File.new_for_path (dir).get_uri (), null);
        } catch (GLib.Error e) {
            show_msg ("无法打开目录：%s".printf (e.message));
        }
    }

    private void confirm_delete (AppEntry[] targets) {
        var dlg = new Gtk.MessageDialog (this,
            Gtk.DialogFlags.MODAL, Gtk.MessageType.QUESTION,
            Gtk.ButtonsType.NONE,
            "删除 %d 个启动器？", targets.length);
        dlg.format_secondary_text (
            "将删除对应的 .desktop 文件。AppImage 本体不受影响，\n"
            + "原文件会先备份，可随时从「修复菜单 → 修复历史」还原。");
        dlg.add_button ("取消", Gtk.ResponseType.CANCEL);
        dlg.add_button ("删除", Gtk.ResponseType.OK);
        dlg.set_default_response (Gtk.ResponseType.CANCEL);
        int r = dlg.run ();
        dlg.destroy ();

        if (r != Gtk.ResponseType.OK)
            return;

        var res = Repair.delete_launchers (targets, config);
        store.rescan ();
        if (res.failed == 0)
            show_info ("✓ 已删除 %d 个启动器".printf (res.created));
        else
            show_msg ("删除完成：成功 %d，失败 %d".printf (res.created, res.failed));
    }

    // ── 修复（接线 repair_entry）──────────────────────────────────

    /**
     * 逐个打开修复对话框。
     *
     * repair_entry 是单条目设计（每个问题的勾选、diff 预览都是独立状态），
     * 所以批量时按顺序来，标题里给出进度，用户可以跳过。
     */
    private void do_repair (AppEntry[] targets) {
        int total = targets.length;
        int fixed_count = 0;
        int skipped = 0;

        for (int i = 0; i < targets.length; i++) {
            var e = targets[i];
            if (e.entry == null) {
                skipped++;
                continue;
            }

            // repair_entry 是单条目设计，批量时按顺序逐个打开，
            // 标题里给出进度提示
            var res = Dialogs.repair_entry (this, e, config);
            if (res == null) {
                skipped++;   // 用户取消/跳过
                continue;
            }
            if (res.failed == 0 && res.done > 0)
                fixed_count += res.done;

            store.rescan ();
        }

        if (fixed_count > 0)
            show_info ("✓ 已修复 %d 个条目%s".printf (fixed_count,
                skipped > 0 ? "，跳过 %d 个".printf (skipped) : ""));
        else if (skipped > 0)
            show_msg ("没有条目被修复（跳过 %d 个）".printf (skipped));
    }

    // ── 认领（接线 claim_entry）───────────────────────────────────

    private void do_claim (AppEntry[] targets) {
        int done = 0;
        int skipped = 0;

        foreach (var e in targets) {
            if (e.entry == null || e.entry.is_managed) {
                skipped++;
                continue;
            }
            var res = Dialogs.claim_entry (this, e, e.entry, config);
            if (res == null) {
                skipped++;
                continue;
            }
            done++;
            store.rescan ();
        }

        if (done > 0)
            show_info ("✓ 已认领 %d 个启动器%s".printf (done,
                skipped > 0 ? "，跳过 %d 个".printf (skipped) : ""));
        else
            show_msg ("没有条目被认领。");
    }

    /**
     * 创建启动器。
     *
     * 默认走「填写式」：逐个弹对话框，预填好启发式信息，用户确认或改。
     * 勾了「之后都用默认值」后剩余的静默创建。
     *
     * 图标不再自动提取 —— 默认空，由用户在对话框里选。这样主流程上
     * 没有任何解包操作，毫秒级完成、永不卡死。
     */
    private void do_create (AppEntry[] targets) {
        var created = new GenericArray<string> ();
        int ok = 0;
        int skipped = 0;
        bool cancel_all = false;
        bool default_rest = false;

        int total = targets.length;
        for (int i = 0; i < targets.length; i++) {
            var e = targets[i];

            if (e.match != MatchState.NEW) {
                skipped++;
                continue;
            }

            if (default_rest) {
                // 静默用默认值创建
                if (create_silently (e))
                    ok++;
                else
                    skipped++;
                continue;
            }

            var d = Dialogs.create_launcher (this, e, config, i + 1, total);

            switch (d.action) {
                case Dialogs.CreateAction.CANCEL:
                    cancel_all = true;
                    break;

                case Dialogs.CreateAction.SKIP:
                    skipped++;
                    break;

                case Dialogs.CreateAction.CREATE_AND_DEFAULT:
                    default_rest = true;
                    // 落到下面一起创建
                    if (create_with_decision (e, d))
                        ok++;
                    else
                        skipped++;
                    break;

                default:
                    if (create_with_decision (e, d))
                        ok++;
                    else
                        skipped++;
                    break;
            }

            if (cancel_all)
                break;
        }

        store.rescan ();

        string msg = "✓ 已创建 %d 个启动器".printf (ok);
        if (skipped > 0)
            msg += " · 跳过 %d 个".printf (skipped);
        if (cancel_all)
            msg += " · 已中止";
        if (ok == 0 && skipped > 0 && !cancel_all)
            msg = "没有创建任何启动器（跳过 %d 个）".printf (skipped);

        if (ok > 0)
            show_info (msg);
        else
            show_msg (msg);
    }

    /** 用对话框里填好的字段创建 */
    private bool create_with_decision (AppEntry e, Dialogs.CreateDecision d) {
        // 执行位：没有就询问（会改动用户的文件，必须显式确认）
        if (!ensure_executable (e))
            return false;

        string content = Prefill.build_preview (
            d.fields, e.path, config.write_marker ());

        string verr = DesktopFiles.validate_content (content);
        if (verr != "") {
            show_msg ("「%s」的内容没通过 desktop-file-validate：\n%s"
                      .printf (d.fields.name, verr));
            return false;
        }

        string target = GLib.Path.build_filename (AppPath.applications_dir (),
                                                  d.desktop_basename);
        string? werr;
        DesktopFiles.write_atomic (target, content, out werr);
        if (werr != null) {
            show_msg ("写入失败：%s".printf (werr));
            return false;
        }

        // 记入事务历史，便于「修复历史」里还原
        var tx = new Journal.Tx ();
        tx.txid = Journal.new_txid ();
        tx.operation = "create";
        tx.started_at = Journal.now_iso ();
        var it = new Journal.Item ();
        it.orig_path = target;
        it.new_path = target;
        it.actions = { "fix" };
        it.status = "done";
        it.sha256_after = Journal.sha256 (target);
        tx.set_items ({ it });
        tx.write_journal ();
        tx.commit ();

        DesktopFiles.refresh_menu (config.should_update_database ());
        return true;
    }

    /** 不弹对话框，直接用预填值创建 */
    private bool create_silently (AppEntry e) {
        if (!ensure_executable (e))
            return false;

        var fields = Prefill.from_appimage (e.path);
        fields.name = e.get_best_name ();

        string content = Prefill.build_preview (
            fields, e.path, config.write_marker ());

        if (DesktopFiles.validate_content (content) != "")
            return false;

        var taken = new GenericArray<string> ();
        foreach (var de in DesktopFiles.scan_directory (AppPath.applications_dir ()))
            taken.add (de.basename);
        string base = Prefill.ensure_unique_slug (e.path, taken.steal ());
        string target = GLib.Path.build_filename (AppPath.applications_dir (), base);

        string? werr;
        DesktopFiles.write_atomic (target, content, out werr);
        if (werr != null)
            return false;

        DesktopFiles.refresh_menu (config.should_update_database ());
        return true;
    }

    private bool exec_ask_disabled = false;

    /**
     * 确保 AppImage 有执行位。
     *
     * 没有就弹窗询问 —— 加执行位是在改动用户的文件，不能默默做。
     * 用户可以拒绝，我们照样创建启动器（只是点开时系统会拒绝执行）。
     */
    private bool ensure_executable (AppEntry e) {
        if (AppPath.file_is_executable (e.path))
            return true;

        if (exec_ask_disabled)
            return true;   // 本批次已选过「不再询问」

        var dlg = new Gtk.MessageDialog (this, Gtk.DialogFlags.MODAL,
            Gtk.MessageType.QUESTION, Gtk.ButtonsType.NONE,
            "这个 AppImage 没有执行权限");
        dlg.format_secondary_text (
            "%s\n\n"
            .printf (AppPath.shorten (e.path))
            + "桌面启动器点开后无法运行。要现在给它加上执行位吗？\n\n"
            + "⚠ 这会修改文件权限（chmod +x），是在改动你的文件。");

        var never = new Gtk.CheckButton.with_label ("本批次中不再询问");
        dlg.get_content_area ().add (never);
        dlg.get_content_area ().show_all ();

        dlg.add_button ("跳过，不加", Gtk.ResponseType.REJECT);
        dlg.add_button ("仍然创建", Gtk.ResponseType.CLOSE);
        dlg.add_button ("加上执行位", Gtk.ResponseType.OK);
        dlg.set_default_response (Gtk.ResponseType.OK);

        int r = dlg.run ();
        exec_ask_disabled = never.get_active ();
        dlg.destroy ();

        if (r == Gtk.ResponseType.OK)
            AppPath.file_chmod_exec (e.path);

        return true;   // 三个选项都继续创建
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

        // 注意：targets 是「借用」的参数，而下面的线程闭包会跨过本函数的
        // 生命周期。Vala 的闭包只复制指针、不接管所有权 —— 直接捕获
        // targets 会在调用方返回后悬空。所以这里只取需要的值（长度）
        // 和一份自己拥有的队列。
        int total = targets.length;
        dlg.set_progress (0, total, "");

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
                    dlg.set_progress (done, total, label);
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
        if (n == 0) {
            show_info ("✓ 没有发现可优化或损坏的启动器");
        } else {
            show_msg ("发现 %d 个可优化或损坏的启动器，已自动勾选。\n"
                      .printf (n)
                      + "点右上角的「🔧 修复」逐个处理，或右键单条选择「修复问题…」。");
        }
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

    // ══════════════════════════════════════════════════════════════
    //  公开接口：供菜单栏调用
    // ══════════════════════════════════════════════════════════════

    public void menu_refresh ()            { refresh (); }
    public void menu_add_dir ()            { on_add_dir (); }
    public void menu_open_apps_dir ()      { open_in_file_manager (AppPath.applications_dir ()); }
    public void menu_open_config_dir ()    { open_in_file_manager (AppPath.config_dir ()); }
    public void menu_quit ()               { destroy (); }

    public void menu_select_all (bool on)  { set_all_checked (on); }

    public void menu_create ()             { on_bar_create (); }
    public void menu_repair ()             { on_bar_repair (); }
    public void menu_claim ()              { on_bar_claim (); }
    public void menu_delete ()             { on_bar_delete (); }

    public void menu_health ()             { on_menu_health (); }
    public void menu_history ()            { on_menu_history (); }
    public void menu_cleanup ()            { on_menu_cleanup (); }
    public void menu_settings ()           { on_menu_settings (); }

    public void menu_set_filter (int mode) {
        if (filter_combo.get_active () != mode)
            filter_combo.set_active (mode);
    }

    public void menu_set_fullscreen (bool on) {
        if (on)
            fullscreen ();
        else
            unfullscreen ();
    }

    public void menu_about () { on_menu_about (); }

    public void menu_extract_metadata () {
        show_msg ("「从 AppImage 提取内置元数据」已移到创建对话框里：\n"
                  + "选中条目 → ⚡ 创建（或右键 → 创建启动器），"
                  + "在对话框里点同名的按钮即可。");
    }

    public void menu_shortcuts () {
        var dlg = new Gtk.MessageDialog (this, Gtk.DialogFlags.MODAL,
            Gtk.MessageType.INFO, Gtk.ButtonsType.CLOSE, "键盘快捷键");
        dlg.format_secondary_text (
            "Ctrl+R / F5   重新扫描\n"
            + "Ctrl+A        全选\n"
            + "Ctrl+F        聚焦搜索框\n"
            + "Ctrl+N        创建启动器\n"
            + "Ctrl+D        添加扫描目录\n"
            + "Ctrl+,        设置\n"
            + "Ctrl+Q        退出\n"
            + "F11           全屏\n"
            + "Delete        删除选中的启动器\n"
            + "Enter         创建 / 认领 / 编辑（按当前状态）\n"
            + "Esc           关闭提示条\n"
            + "双击条目      未创建 → 创建；已创建 → 编辑\n"
            + "右键条目      打开完整操作菜单");
        dlg.run ();
        dlg.destroy ();
    }

    /** GenericArray 在这套 vapi 里没有 contains */
    private static bool has_str (GenericArray<string> a, string want) {
        unowned string[] raw = (string[]) a.data;
        for (uint i = 0; i < a.length; i++)
            if (raw[i] == want)
                return true;
        return false;
    }
}
