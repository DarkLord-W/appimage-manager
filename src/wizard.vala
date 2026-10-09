/*
 * wizard.vala — 首次运行向导
 *
 * 三步：选目录 → 提取设置 → 完成并扫描。
 * 只在 ~/.config/appimage-manager/config.ini 不存在时触发，
 * 之后可从菜单随时重新打开。
 */
namespace Wizard {

    public const string STACK_DIR   = "step-dirs";
    public const string STACK_ICON  = "step-icons";
    public const string STACK_DONE  = "step-done";

    /** 常见候选目录 */
    private const string[] CANDIDATES = {
        "~/Applications",
        "~/apps",
        "~/AppImages",
        "~/iso-tools",
        "/opt/appimages"
    };

    private class DirRow : GLib.Object {
        public Gtk.CheckButton check;
        public Gtk.Label status;
        public Gtk.Button action;
        public string path;
        public bool exists;
    }

    public class FirstRunWizard : Gtk.Dialog {

        private AppConfig config;
        private Gtk.Stack stack;
        private Gtk.Button back_btn;
        private Gtk.Button next_btn;

        private Gtk.Box dir_list;
        private Gtk.Box step_dots;
        private Gtk.Label done_label;
        private Gtk.Label[] step_labels = new Gtk.Label[3];

        private GLib.Array<DirRow> rows;
        private GLib.Array<string> extra_dirs;

        // 第二步的控件
        private Gtk.RadioButton r128;
        private Gtk.RadioButton r256;
        private Gtk.RadioButton r512;
        private Gtk.Switch sw_recursive;
        private Gtk.Switch sw_autodb;
        private Gtk.Switch sw_autoscan;

        public FirstRunWizard (Gtk.Window? parent, AppConfig cfg) {
            set_transient_for (parent);
            set_modal (true);
            set_position (Gtk.WindowPosition.CENTER_ON_PARENT);
            set_title ("欢迎使用 AppImage Manager");
            set_default_size (850, 560);
            set_border_width (0);
            set_resizable (false);
            this.config = cfg;

            rows = new GLib.Array<DirRow> ();
            extra_dirs = new GLib.Array<string> ();

            build_header ();

            var root = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            root.pack_start (make_header_area (), false, false, 0);

            stack = new Gtk.Stack ();
            stack.set_transition_type (Gtk.StackTransitionType.SLIDE_LEFT_RIGHT);
            stack.set_transition_duration (260);
            stack.add_named (make_step_dirs (), STACK_DIR);
            stack.add_named (make_step_icons (), STACK_ICON);
            stack.add_named (make_step_done (), STACK_DONE);
            root.pack_start (stack, true, true, 0);

            root.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 0);
            root.pack_start (make_button_row (), false, false, 0);

            get_content_area ().add (root);
            stack.set_visible_child_name (STACK_DIR);
            update_buttons ();
            update_step_dots ();   // 必须在 stack 建好之后调用
            show_all ();
        }

        private void build_header () {
            // 无 HeaderBar，用自绘标题区，避免不同桌面环境下的歧义
        }

        private Gtk.Widget make_header_area () {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
            box.set_border_width (18);
            box.set_spacing (6);

            step_dots = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            string[] names = { "① 目录", "② 设置", "③ 完成" };
            for (int i = 0; i < 3; i++) {
                var l = new Gtk.Label (names[i]);
                step_labels[i] = l;
                step_dots.pack_start (l, false, false, 0);
                if (i < 2)
                    step_dots.pack_start (new Gtk.Label ("·"), false, false, 0);
            }
            box.pack_start (step_dots, false, false, 0);

            return box;
        }

        // ══════════════════════════════════════════════════════════
        //  第 1 步：目录
        // ══════════════════════════════════════════════════════════

        private Gtk.Widget make_step_dirs () {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            box.set_border_width (18);

            var h = new Gtk.Label (null);
            h.use_markup = true;
            h.label = "<span size='large' weight='bold'>选择要管理的 AppImage 目录</span>";
            h.set_xalign (0.0f);
            box.pack_start (h, false, false, 0);

            var sub = new Gtk.Label ("可以稍后在主界面随时添加或删除目录。");
            sub.set_xalign (0.0f);
            sub.get_style_context ().add_class ("dim-label");
            box.pack_start (sub, false, false, 0);

            dir_list = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
            foreach (string c in CANDIDATES)
                add_dir_row (c);

            var sw = new Gtk.ScrolledWindow (null, null);
            sw.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
            sw.add (dir_list);
            box.pack_start (sw, true, true, 0);

            var browse = new Gtk.Button.with_label ("+ 浏览其他目录…");
            browse.set_halign (Gtk.Align.START);
            browse.clicked.connect (() => {
                var chooser = new Gtk.FileChooserDialog (
                    "选择目录", this, Gtk.FileChooserAction.SELECT_FOLDER,
                    "取消", Gtk.ResponseType.CANCEL,
                    "添加", Gtk.ResponseType.ACCEPT);
                if (chooser.run () == Gtk.ResponseType.ACCEPT) {
                    string? d = chooser.get_filename ();
                    if (d != null && !row_exists (d)) {
                        extra_dirs.append_val (d);
                        add_dir_row (d);
                        dir_list.show_all ();
                    }
                }
                chooser.destroy ();
            });
            box.pack_start (browse, false, false, 0);

            return box;
        }

        private bool row_exists (string path) {
            string c = AppPath.canonical (path);
            for (uint i = 0; i < rows.length; i++) {
                var row = rows.index (i);
                if (row != null && AppPath.canonical (row.path) == c)
                    return true;
            }
            return false;
        }

        private void add_dir_row (string path) {
            var row = new DirRow ();
            row.path = path;
            row.exists = AppPath.is_dir (AppPath.expand_tilde (path));

            var line = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            line.get_style_context ().add_class ("option-card");

            row.check = new Gtk.CheckButton ();
            row.check.set_active (row.exists);
            row.check.toggled.connect (() => update_buttons ());
            line.pack_start (row.check, false, false, 0);

            var lab = new Gtk.Label (AppPath.shorten (AppPath.expand_tilde (path)));
            lab.set_xalign (0.0f);
            lab.set_ellipsize (Pango.EllipsizeMode.MIDDLE);
            line.pack_start (lab, true, true, 0);

            row.status = new Gtk.Label ("");
            row.status.get_style_context ().add_class ("dim-label");
            row.status.set_xalign (1.0f);
            line.pack_start (row.status, false, false, 0);

            row.action = new Gtk.Button ();
            row.action.set_relief (Gtk.ReliefStyle.NONE);
            row.action.set_sensitive (row.exists);
            line.pack_start (row.action, false, false, 0);

            refresh_row_status (row);

            row.action.clicked.connect (() => {
                string real = AppPath.expand_tilde (row.path);
                if (!row.exists) {
                    if (AppPath.ensure_dir (real)) {
                        row.exists = true;
                        row.action.set_sensitive (false);
                        row.check.set_active (true);
                        refresh_row_status (row);
                    } else {
                        warn ("无法创建目录", real);
                    }
                } else {
                    // 打开所在目录（用默认文件管理器）
                    try {
                        GLib.AppInfo.launch_default_for_uri ("file://" + real, null);
                    } catch {}
                }
            });

            rows.append_val (row);
            dir_list.pack_start (line, false, false, 0);
        }

        private void refresh_row_status (DirRow row) {
            string real = AppPath.expand_tilde (row.path);
            if (!AppPath.is_dir (real)) {
                row.status.set_text ("不存在");
                row.action.set_label ("创建");
                row.action.set_sensitive (true);
                row.check.set_active (false);
                return;
            }
            // 数一下里面有几个 AppImage
            var res = Scanner.scan ({ real }, false);
            int n = res.found.length;
            if (n == 0)
                row.status.set_text ("存在 · 暂无 AppImage");
            else
                row.status.set_text ("存在 · %d 个 AppImage".printf (n));
            row.action.set_label ("打开");
            row.action.set_sensitive (true);
        }

        // ══════════════════════════════════════════════════════════
        //  第 2 步：设置
        // ══════════════════════════════════════════════════════════

        private Gtk.Widget make_step_icons () {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            box.set_border_width (18);

            var h = new Gtk.Label (null);
            h.use_markup = true;
            h.label = "<span size='large' weight='bold'>设置</span>";
            h.set_xalign (0.0f);
            box.pack_start (h, false, false, 0);

            // 图标尺寸
            var sz_title = new Gtk.Label (null);
            sz_title.use_markup = true;
            sz_title.label = "<b>图标缓存尺寸</b>";
            sz_title.set_xalign (0.0f);
            box.pack_start (sz_title, false, false, 0);

            var sz_hint = new Gtk.Label ("提取出的图标会复制到 ~/.local/share/icons/hicolor/<尺寸>/apps/");
            sz_hint.set_xalign (0.0f);
            sz_hint.get_style_context ().add_class ("dim-label");
            box.pack_start (sz_hint, false, false, 0);

            r128 = new Gtk.RadioButton.with_label (null, "128 × 128    体积最小");
            r256 = new Gtk.RadioButton.with_label_from_widget (r128, "256 × 256    推荐，清晰度与体积平衡");
            r512 = new Gtk.RadioButton.with_label_from_widget (r128, "512 × 512    高分屏");
            r256.set_active (true);
            box.pack_start (r128, false, false, 0);
            box.pack_start (r256, false, false, 0);
            box.pack_start (r512, false, false, 0);

            box.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 6);

            // 扫描行为
            var sc_title = new Gtk.Label (null);
            sc_title.use_markup = true;
            sc_title.label = "<b>扫描行为</b>";
            sc_title.set_xalign (0.0f);
            box.pack_start (sc_title, false, false, 0);

            sw_recursive = add_switch_row (box, "递归扫描子目录",
                "关闭时只扫描目录顶层的 AppImage", true);
            sw_autodb = add_switch_row (box, "写入后自动刷新菜单数据库",
                "执行 update-desktop-database，让新启动器立即出现在菜单里", true);
            sw_autoscan = add_switch_row (box, "启动时自动重新扫描",
                "每次打开程序都扫描一次，而不是等手动刷新", false);

            // 提示
            var hint = new Gtk.Label (
                "⚠ 提取图标需要 AppImage 有执行权限。程序会自动补上执行位，\n"
                + "   但对 /opt、/media 下的文件可能需要管理员权限，届时会跳过并提示。");
            hint.set_xalign (0.0f);
            hint.get_style_context ().add_class ("hint-box");
            box.pack_start (hint, false, false, 6);

            return box;
        }

        private Gtk.Switch add_switch_row (Gtk.Box box, string label, string hint, bool on) {
            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);

            var texts = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);
            var l = new Gtk.Label (label);
            l.set_xalign (0.0f);
            texts.pack_start (l, false, false, 0);
            var h = new Gtk.Label (hint);
            h.set_xalign (0.0f);
            h.get_style_context ().add_class ("dim-label");
            texts.pack_start (h, false, false, 0);
            row.pack_start (texts, true, true, 0);

            var sw = new Gtk.Switch ();
            sw.set_active (on);
            sw.set_valign (Gtk.Align.CENTER);
            row.pack_start (sw, false, false, 0);

            box.pack_start (row, false, false, 0);
            return sw;
        }

        // ══════════════════════════════════════════════════════════
        //  第 3 步：完成
        // ══════════════════════════════════════════════════════════

        private Gtk.Widget make_step_done () {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 14);
            box.set_border_width (18);
            box.set_valign (Gtk.Align.CENTER);

            var icon = new Gtk.Image.from_icon_name ("emblem-ok-symbolic",
                                                     Gtk.IconSize.DIALOG);
            box.pack_start (icon, false, false, 0);

            done_label = new Gtk.Label ("");
            done_label.use_markup = true;
            done_label.set_line_wrap (true);
            done_label.set_justify (Gtk.Justification.CENTER);
            box.pack_start (done_label, false, false, 0);

            var hint = new Gtk.Label ("点击「立即扫描」开始；扫描过程中会提取图标，可能需要几秒到几十秒。");
            hint.get_style_context ().add_class ("dim-text");
            hint.get_style_context ().add_class ("dim-label");
            box.pack_start (hint, false, false, 0);

            return box;
        }

        /** 统计选中的目录里一共有多少 AppImage */
        private void update_done_summary () {
            var dirs = selected_dirs ();
            int total = 0;
            foreach (string d in dirs) {
                var res = Scanner.scan ({ d }, false);
                total += res.found.length;
            }
            done_label.label = "<span size='large' weight='bold'>配置完成</span>\n"
                + "%d 个目录 · %d 个 AppImage 待处理".printf (dirs.length, total);
        }

        // ══════════════════════════════════════════════════════════
        //  按钮行与导航
        // ══════════════════════════════════════════════════════════

        private Gtk.Widget make_button_row () {
            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            row.set_border_width (12);

            var cancel = new Gtk.Button.with_label ("稍后再说");
            cancel.clicked.connect (() => {
                config.mark_configured ();
                config.save ();
                response (Gtk.ResponseType.CANCEL);
            });
            row.pack_start (cancel, false, false, 0);

            var spacer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            row.pack_start (spacer, true, true, 0);

            back_btn = new Gtk.Button.with_label ("← 上一步");
            back_btn.clicked.connect (() => go_back ());
            row.pack_start (back_btn, false, false, 0);

            next_btn = new Gtk.Button.with_label ("下一步 →");
            next_btn.get_style_context ().add_class ("suggested-action");
            next_btn.clicked.connect (() => go_next ());
            row.pack_start (next_btn, false, false, 0);

            return row;
        }

        private void go_next () {
            string cur = stack.get_visible_child_name ();
            if (cur == STACK_DIR) {
                if (selected_dirs ().length == 0) {
                    // 区分「一个没勾」和「勾了但都不存在」——
                    // 后者用户往往以为是程序坏了
                    bool any_checked = false;
                    for (uint i = 0; i < rows.length; i++) {
                        var r = rows.index (i);
                        if (r != null && r.check.get_active ())
                            any_checked = true;
                    }
                    if (any_checked)
                        warn ("所选目录都不存在",
                              "这些目录还没被创建。\n"
                              + "点目录行右侧的「创建」按钮新建，\n"
                              + "或取消勾选它们、改用「浏览其他目录…」选择一个已有的目录。");
                    else
                        warn ("请至少选择一个目录",
                              "勾选一个目录，或点「浏览其他目录…」添加。");
                    return;
                }
                stack.set_visible_child_name (STACK_ICON);
            } else if (cur == STACK_ICON) {
                update_done_summary ();
                stack.set_visible_child_name (STACK_DONE);
            } else {
                apply_and_finish ();
            }
            update_buttons ();
            update_step_dots ();
        }

        private void go_back () {
            string cur = stack.get_visible_child_name ();
            if (cur == STACK_ICON)
                stack.set_visible_child_name (STACK_DIR);
            else if (cur == STACK_DONE)
                stack.set_visible_child_name (STACK_ICON);
            update_buttons ();
            update_step_dots ();
        }

        /** 高亮当前步骤，已走过的步骤维持普通色 */
        private void update_step_dots () {
            if (stack == null)
                return;   // 构造期间可能被提前调用
            string cur = stack.get_visible_child_name ();
            int active = 0;
            if (cur == STACK_ICON)      active = 1;
            else if (cur == STACK_DONE) active = 2;

            for (int i = 0; i < 3; i++) {
                unowned Gtk.StyleContext ctx = step_labels[i].get_style_context ();
                ctx.remove_class ("wizard-step-active");
                ctx.remove_class ("wizard-step-idle");
                ctx.add_class (i == active ? "wizard-step-active"
                                           : "wizard-step-idle");
            }
        }

        private void update_buttons () {
            string cur = stack.get_visible_child_name ();
            back_btn.set_sensitive (cur != STACK_DIR);

            if (cur == STACK_DONE)
                next_btn.set_label ("立即扫描并开始");
            else
                next_btn.set_label ("下一步 →");
        }

        /** 汇总勾选的目录 + 额外添加的目录 */
        private string[] selected_dirs () {
            var list = new GenericArray<string> ();
            var seen = new GenericArray<string> ();

            for (uint i = 0; i < rows.length; i++) {
                var row = rows.index (i);
                if (row == null || !row.check.get_active ())
                    continue;
                string real = AppPath.expand_tilde (row.path);
                if (!AppPath.is_dir (real))
                    continue;
                string c = AppPath.canonical (real);
                if (!has_str (seen, c)) {
                    seen.add (c);
                    list.add (c);
                }
            }
            for (uint i = 0; i < extra_dirs.length; i++) {
                string d = extra_dirs.index (i);
                string c = AppPath.canonical (d);
                if (!has_str (seen, c)) {
                    seen.add (c);
                    list.add (c);
                }
            }
            return list.steal ();
        }

        private void apply_and_finish () {
            config.set_scan_dirs (selected_dirs ());

            int size = r256.get_active () ? 256 : (r128.get_active () ? 128 : 512);
            config.set_int ("general", "icon_size", size);

            config.set_bool ("scan", "recursive", sw_recursive.get_active ());
            config.set_bool ("sync", "update_desktop_database", sw_autodb.get_active ());
            config.set_bool ("scan", "auto_on_startup", sw_autoscan.get_active ());
            config.mark_configured ();
            config.save ();

            response (Gtk.ResponseType.OK);
        }

        private void warn (string primary, string secondary) {
            var dlg = new Gtk.MessageDialog (this, Gtk.DialogFlags.MODAL,
                Gtk.MessageType.WARNING, Gtk.ButtonsType.OK, "%s", primary);
            dlg.format_secondary_text ("%s", secondary);
            dlg.run ();
            dlg.destroy ();
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

    /** 便捷构造 */
    public FirstRunWizard show (Gtk.Window? parent, AppConfig cfg) {
        return new FirstRunWizard (parent, cfg);
    }
}
