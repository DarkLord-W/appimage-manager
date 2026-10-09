/*
 * dialogs.vala — 对话框集合
 *
 * 全部以静态工厂函数提供，返回 Gtk.Dialog（或其子类）。
 * 对话框一律同步阻塞：内部 run() 后自行销毁，并返回需要外层刷新数据的结果对象；
 * 无结果需求时返回 null 表示"用户取消 / 无事可做"。
 */

namespace Dialogs {

    /* ── 通用小部件 ──────────────────────────────────────────────── */

    private Gtk.Dialog new_dialog (Gtk.Window? parent, string title, int w, int h) {
        var dlg = new Gtk.Dialog ();
        dlg.set_transient_for (parent);
        dlg.set_modal (true);
        dlg.set_destroy_with_parent (true);
        dlg.set_position (Gtk.WindowPosition.CENTER_ON_PARENT);
        dlg.title = title;
        dlg.set_default_size (w, h);
        dlg.set_border_width (0);
        return dlg;
    }

    private Gtk.Label mk_label (string text, float xalign = 0.0f) {
        var l = new Gtk.Label (null);
        l.label = text;
        l.xalign = xalign;
        l.selectable = true;
        return l;
    }

    /** 只读、可滚动、等宽字体的文本框（差异预览 / 内容预览都用它） */
    private Gtk.TextView mk_textview (Gtk.TextBuffer? out_buffer = null) {
        var tv = new Gtk.TextView ();
        tv.editable = false;
        tv.cursor_visible = false;
        tv.monospace = true;
        tv.wrap_mode = Gtk.WrapMode.WORD_CHAR;
        tv.left_margin = 8;
        tv.right_margin = 8;
        tv.top_margin = 6;
        tv.bottom_margin = 6;
        if (out_buffer != null)
            out_buffer = tv.buffer;
        return tv;
    }

    private void put_buffer (Gtk.TextView tv, string text) {
        tv.buffer.text = text ?? "";
    }

    private Gtk.ScrolledWindow mk_scrolled (Gtk.Widget child, int min_h, bool expand_v = true) {
        var sw = new Gtk.ScrolledWindow (null, null);
        sw.set_policy (Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC);
        sw.set_shadow_type (Gtk.ShadowType.IN);
        sw.add (child);
        sw.set_size_request (-1, min_h);
        if (expand_v)
            sw.vexpand = true;
        return sw;
    }

    private Gtk.Frame mk_frame (string label, Gtk.Widget child, int min_h = 140) {
        var f = new Gtk.Frame (label);
        f.add (child);
        f.set_size_request (-1, min_h);
        return f;
    }

    private Gtk.Button add_button (Gtk.Dialog dlg, string text, int response) {
        var b = dlg.add_button (text, response) as Gtk.Button;
        return b;
    }

    private void info (Gtk.Window? parent, string title, string msg, Gtk.MessageType type = Gtk.MessageType.INFO) {
        var d = new Gtk.MessageDialog (parent, Gtk.DialogFlags.MODAL, type,
            Gtk.ButtonsType.CLOSE, "%s", msg);
        d.title = title;
        d.run ();
        d.destroy ();
    }

    private bool confirm (Gtk.Window? parent, string title, string msg) {
        var d = new Gtk.MessageDialog (parent, Gtk.DialogFlags.MODAL,
            Gtk.MessageType.QUESTION, Gtk.ButtonsType.OK_CANCEL, "%s", msg);
        d.title = title;
        d.set_default_response (Gtk.ResponseType.OK);
        int r = d.run ();
        d.destroy ();
        return r == Gtk.ResponseType.OK;
    }

    /* ══════════════════════════════════════════════════════════════
     *  1. 编辑启动器
     * ══════════════════════════════════════════════════════════════ */

    /**
     * 编辑 .desktop 的字段，并实时预览将要写入的内容。
     * @return 实际写入路径；未改动或取消返回 null
     */

    /* ══════════════════════════════════════════════════════════════
     *  创建启动器（填写式）
     *
     *  设计原则：默认路径上不做任何解包。图标要用户自己选，元数据要用户
     *  自己填。解包（--appimage-extract）降级为一个显式按钮 —— 它慢、
     *  而且对不认这个参数的运行时会卡住，不该出现在主流程里。
     * ══════════════════════════════════════════════════════════════ */

    public enum CreateAction {
        CREATE,               // 创建这一条
        SKIP,                 // 跳过这一条，继续下一条
        CANCEL,               // 中止整个批次
        CREATE_AND_DEFAULT    // 创建这一条，且剩余都用默认值
    }

    public class CreateDecision : GLib.Object {
        public CreateAction action = CreateAction.SKIP;
        public Prefill.Fields fields;
        public string icon_path = "";        // 已安装到缓存后的最终路径
        public string desktop_basename = "";
    }

    /** 把用户选中的图片复制进图标缓存，返回最终路径；失败返回 "" */
    private string install_chosen_icon (string src, string slug, AppConfig cfg) {
        if (src == "" || !AppPath.exists (src))
            return "";

        string lower = GLib.Path.get_basename (src).down ();
        string ext = lower.has_suffix (".svg") ? "svg"
                   : (lower.has_suffix (".xpm") ? "xpm" : "png");

        string dir = cfg.icon_dir ();
        if (!AppPath.ensure_dir (dir))
            return "";

        string dest = GLib.Path.build_filename (dir, "%s.%s".printf (slug, ext));

        try {
            AppPath.file_copy (src, dest, true);
            return dest;
        } catch {
            return "";
        }
    }

    /** 图片文件选择器 */
    private string? pick_image_file (Gtk.Window parent) {
        var chooser = new Gtk.FileChooserDialog (
            "选择图标文件", parent, Gtk.FileChooserAction.OPEN,
            "取消", Gtk.ResponseType.CANCEL,
            "选择", Gtk.ResponseType.ACCEPT);
        chooser.set_modal (true);

        var images = new Gtk.FileFilter ();
        images.set_name ("图片 (png / svg / xpm)");
        images.add_mime_type ("image/png");
        images.add_mime_type ("image/svg+xml");
        images.add_mime_type ("image/x-xpixmap");
        images.add_pattern ("*.png");
        images.add_pattern ("*.svg");
        images.add_pattern ("*.xpm");
        images.add_pattern ("*.PNG");
        images.add_pattern ("*.SVG");
        chooser.add_filter (images);

        var all = new Gtk.FileFilter ();
        all.set_name ("所有文件");
        all.add_pattern ("*");
        chooser.add_filter (all);

        string? picked = null;
        if (chooser.run () == Gtk.ResponseType.ACCEPT)
            picked = chooser.get_filename ();
        chooser.destroy ();
        return picked;
    }

    /**
     * 创建启动器对话框。
     *
     * 返回非 null 表示用户做了决定（创建 / 跳过 / 中止）。
     * 调用方按 action 决定后续动作。
     */
    public CreateDecision create_launcher (Gtk.Window parent, AppEntry entry,
                                           AppConfig cfg, int index = 1,
                                           int total = 1) {
        var decision = new CreateDecision ();
        decision.fields = Prefill.from_appimage (entry.path);
        decision.fields.name = entry.get_best_name ();

        var slug = AppPath.slugify (entry.basename);
        var taken = new GenericArray<string> ();
        foreach (var d in DesktopFiles.scan_directory (AppPath.applications_dir ()))
            taken.add (d.basename);
        decision.desktop_basename = Prefill.ensure_unique_slug (
            entry.path, taken.steal ());

        string title = total > 1
            ? "创建启动器 (%d/%d) — %s".printf (index, total, entry.get_best_name ())
            : "创建启动器 — %s".printf (entry.get_best_name ());

        var dlg = new_dialog (parent, title, 780, 640);
        var content = dlg.get_content_area ();
        content.set_border_width (12);

        var flow = new Gtk.Box (Gtk.Orientation.VERTICAL, 10);

        /* ── 顶部：图标预览 + 字段网格 ─────────────────────────── */

        var top = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 14);

        var left = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        left.set_size_request (132, -1);

        var icon_img = new Gtk.Image.from_icon_name ("application-x-executable",
                                                     Gtk.IconSize.DIALOG);
        icon_img.set_pixel_size (96);
        icon_img.set_size_request (96, 96);
        left.pack_start (icon_img, false, false, 0);

        var icon_btns = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
        var icon_pick = new Gtk.Button.with_label ("选择…");
        var icon_clear = new Gtk.Button.with_label ("清除");
        icon_btns.pack_start (icon_pick, true, true, 0);
        icon_btns.pack_start (icon_clear, true, true, 0);
        left.pack_start (icon_btns, false, false, 0);

        var icon_hint = new Gtk.Label ("未设置图标");
        icon_hint.get_style_context ().add_class ("dim-label");
        icon_hint.set_ellipsize (Pango.EllipsizeMode.MIDDLE);
        icon_hint.set_max_width_chars (18);
        left.pack_start (icon_hint, false, false, 0);

        top.pack_start (left, false, false, 0);

        var grid = new Gtk.Grid ();
        grid.set_column_spacing (10);
        grid.set_row_spacing (8);
        grid.set_hexpand (true);

        var f_name = new Gtk.Entry ();
        f_name.set_text (decision.fields.name);
        f_name.set_placeholder_text ("显示在菜单里的名称");

        var f_exec = new Gtk.Entry ();
        f_exec.set_text (decision.fields.exec_line);
        f_exec.get_style_context ().add_class ("cell-mono");

        var f_icon = new Gtk.Entry ();
        f_icon.set_editable (false);
        f_icon.set_placeholder_text ("（未设置，使用系统通用图标）");

        /* 分类：普通 Entry + 建议菜单按钮。
         * 不用 ComboBoxText.with_entry ()：它没有公开 API 能拿到内部 Entry，
         * get_child () 赌的是未文档化的内部布局，转型失败拿到 NULL 再调
         * text / set_text 就会崩。这里自己拿住 Entry，行为完全可控。 */
        var cat_entry = new Gtk.Entry ();
        cat_entry.set_text (decision.fields.categories);
        cat_entry.set_hexpand (true);

        var cat_menu = new Gtk.Menu ();
        foreach (string c in Prefill.category_choices ()) {
            // 每个菜单项绑定独立的局部拷贝：若共享循环变量，点哪一项都会写入最后一项的值
            string choice = c;
            var mi = new Gtk.MenuItem.with_label (choice);
            mi.activate.connect (() => { cat_entry.set_text (choice); });
            cat_menu.append (mi);
        }
        cat_menu.show_all ();

        var cat_btn = new Gtk.MenuButton ();
        cat_btn.set_popup (cat_menu);
        cat_btn.set_tooltip_text ("从常见分类里挑一个");
        cat_btn.set_relief (Gtk.ReliefStyle.NONE);
        // 个别图标主题没有 pan-down-symbolic，退化成文字箭头，保证按钮不会空白
        if (Gtk.IconTheme.get_default ().has_icon ("pan-down-symbolic"))
            cat_btn.set_image (new Gtk.Image.from_icon_name ("pan-down-symbolic",
                                                             Gtk.IconSize.BUTTON));
        else
            cat_btn.set_label ("▾");

        var cat_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        cat_box.pack_start (cat_entry, true, true, 0);
        cat_box.pack_start (cat_btn, false, false, 0);

        var f_comment = new Gtk.Entry ();
        f_comment.set_placeholder_text ("一句话描述，可留空");

        var f_wm = new Gtk.Entry ();
        f_wm.set_text (decision.fields.startup_wm_class);

        int row = 0;
        grid.attach (mk_label ("名称"), 0, row, 1, 1);
        grid.attach (f_name, 1, row++, 1, 1);
        grid.attach (mk_label ("命令"), 0, row, 1, 1);
        grid.attach (f_exec, 1, row++, 1, 1);
        grid.attach (mk_label ("图标"), 0, row, 1, 1);
        grid.attach (f_icon, 1, row++, 1, 1);
        grid.attach (mk_label ("分类"), 0, row, 1, 1);
        grid.attach (cat_box, 1, row++, 1, 1);
        grid.attach (mk_label ("备注"), 0, row, 1, 1);
        grid.attach (f_comment, 1, row++, 1, 1);
        grid.attach (mk_label ("窗口类"), 0, row, 1, 1);
        grid.attach (f_wm, 1, row++, 1, 1);

        var f_term = new Gtk.CheckButton.with_label ("在终端中启动");
        f_term.active = decision.fields.terminal;
        grid.attach (f_term, 1, row++, 1, 1);

        top.pack_start (grid, true, true, 0);
        flow.pack_start (top, false, false, 0);

        /* ── 可选：从 AppImage 提取内置元数据 ──────────────────── */

        var extract_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        var extract_btn = new Gtk.Button.with_label ("尝试提取内置元数据");
        extract_btn.set_tooltip_text (
            "解包 AppImage 读取它自带的名称 / 图标 / 分类。\n"
            + "较慢（可能几十秒），且对旧格式或自定义运行时会失败 ——\n"
            + "有 %d 秒硬超时，不会卡住界面；超时秒数可在「工具 → 设置」里调整。"
              .printf (cfg.extract_timeout ()));
        extract_row.pack_start (extract_btn, false, false, 0);

        var extract_note = new Gtk.Label (
            "仅在你需要更完整的元数据时使用");
        extract_note.get_style_context ().add_class ("dim-label");
        extract_row.pack_start (extract_note, false, false, 0);
        flow.pack_start (extract_row, false, false, 0);

        /* ── 预览 ──────────────────────────────────────────────── */

        var prev_view = mk_textview ();
        var prev_frame = mk_frame (
            "将写入 " + AppPath.shorten (
                GLib.Path.build_filename (AppPath.applications_dir (),
                                          decision.desktop_basename)),
            mk_scrolled (prev_view, 190), 190);
        flow.pack_start (prev_frame, true, true, 0);

        /* ── 底部选项 ──────────────────────────────────────────── */

        var default_rest = new Gtk.CheckButton.with_label (
            "之后都用默认值创建，不再逐个询问");
        flow.pack_start (default_rest, false, false, 0);

        content.pack_start (flow, true, true, 0);

        /* ── 逻辑 ──────────────────────────────────────────────── */

        string current_icon = "";

        void refresh_preview () {
            decision.fields.name = f_name.text.strip ();
            decision.fields.exec_line = f_exec.text.strip ();
            decision.fields.icon = current_icon;
            decision.fields.categories = cat_entry.text.strip ();
            decision.fields.comment = f_comment.text.strip ();
            decision.fields.startup_wm_class = f_wm.text.strip ();
            decision.fields.terminal = f_term.active;

            put_buffer (prev_view, Prefill.build_preview (
                decision.fields, entry.path, cfg.write_marker ()));
        }

        void set_icon (string path) {
            current_icon = path;
            f_icon.set_text (AppPath.shorten (path));
            if (path != "" && AppPath.exists (path)) {
                try {
                    var pb = new Gdk.Pixbuf.from_file_at_scale (path, 96, 96, true);
                    icon_img.set_from_pixbuf (pb);
                } catch {
                    icon_img.set_from_icon_name ("dialog-warning",
                                                 Gtk.IconSize.DIALOG);
                }
                icon_hint.set_text (GLib.Path.get_basename (path));
            } else {
                icon_img.set_from_icon_name ("application-x-executable",
                                             Gtk.IconSize.DIALOG);
                icon_hint.set_text ("未设置图标");
            }
            refresh_preview ();
        }

        icon_pick.clicked.connect (() => {
            string? p = pick_image_file (dlg);
            if (p == null)
                return;
            string installed = install_chosen_icon (p, slug, cfg);
            if (installed == "") {
                info (dlg, "无法安装图标",
                      "复制到图标缓存失败：\n%s".printf (p));
                return;
            }
            set_icon (installed);
        });

        icon_clear.clicked.connect (() => set_icon (""));

        // 注意：必须用 lambda 包一层，不能把局部函数直接接到信号上。
        //
        // Vala 在「局部函数 → 信号」时会把委托拷贝一份，但捕获的变量
        // （decision / prev_view / current_icon 这些）不会跟着被正确持有，
        // 信号触发时闭包数据已悬空 → 段错误。实测在任一字段里打一个字
        // 就崩，而不接信号的直接调用却完全正常 —— 就是这个原因。
        f_name.changed.connect (() => { refresh_preview (); });
        f_exec.changed.connect (() => { refresh_preview (); });
        f_comment.changed.connect (() => { refresh_preview (); });
        f_wm.changed.connect (() => { refresh_preview (); });
        f_term.toggled.connect (() => { refresh_preview (); });
        cat_entry.changed.connect (() => { refresh_preview (); });

        /* ── 提取（后台线程 + 可取消）─────────────────────────── */

        void do_extract () {
            var prog = Dialogs.progress (dlg, "正在提取内置元数据");
            prog.set_progress (0, 1, entry.basename);

            string work = GLib.Path.build_filename (
                AppPath.tmp_extract_dir (),
                "%s-%u".printf (slug, (uint)(GLib.get_real_time () % 100000)));

            var cancel = new GLib.Cancellable ();

            // 把进度框的「取消」接到 Cancellable 上。
            // worker 阻塞在解包里，只能由主线程去取消它。
            uint watch_id = GLib.Timeout.add (200, () => {
                if (prog.cancelled) {
                    cancel.cancel ();
                    return false;
                }
                return true;   // 继续观察
            });

            var th = new GLib.Thread<void*> ("extract-meta", () => {
                var einfo = AppImageExtract.run (entry.path, work, cancel,
                                                 cfg.extract_timeout ());
                bool ok = einfo.ok;
                string err = einfo.error;

                string m_name = einfo.name;
                string m_comment = einfo.comment;
                string m_cats = einfo.categories;
                string m_wm = einfo.startup_wm_class;
                string? m_icon = null;
                if (ok)
                    m_icon = AppImageExtract.install_icon (einfo, cfg);
                einfo.cleanup_extract ();

                GLib.Idle.add (() => {
                    GLib.Source.remove (watch_id);
                    prog.finish ();
                    if (!ok) {
                        info (dlg, "提取未能完成",
                              err != "" ? err : "未能读取到内置元数据。\n"
                              + "这很常见 —— 直接手工填写上面的字段即可。");
                        return false;
                    }
                    if (m_name != "")
                        f_name.set_text (m_name);
                    if (m_comment != "")
                        f_comment.set_text (m_comment);
                    if (m_cats != "")
                        cat_entry.set_text (m_cats);
                    if (m_wm != "")
                        f_wm.set_text (m_wm);
                    if (m_icon != null)
                        set_icon (m_icon);
                    refresh_preview ();
                    info (dlg, "提取完成",
                          "已用 AppImage 内置的元数据填充字段，可以直接改。");
                    return false;
                });
                return null;
            });
        }

        extract_btn.clicked.connect (() => { do_extract (); });

        /* ── 按钮 ──────────────────────────────────────────────── */

        var cancel_btn = add_button (dlg, "取消", Gtk.ResponseType.CANCEL);
        cancel_btn.set_tooltip_text ("中止整个批次，不再处理剩余条目");

        var skip_btn = add_button (dlg, "跳过", Gtk.ResponseType.REJECT);
        skip_btn.set_tooltip_text ("不创建这一条，继续处理下一个");

        var create_btn = add_button (dlg, "创建", Gtk.ResponseType.OK);
        create_btn.get_style_context ().add_class ("suggested-action");
        dlg.set_default_response (Gtk.ResponseType.OK);

        set_icon ("");
        dlg.show_all ();
        refresh_preview ();

        // 设置里开了开关就自动跑一次；用户仍可随时取消
        if (cfg.auto_extract_on_create ())
            GLib.Idle.add (() => { do_extract (); return false; });

        int resp = dlg.run ();
        bool want_default = default_rest.get_active ();
        dlg.destroy ();

        if (resp == Gtk.ResponseType.OK) {
            decision.action = want_default ? CreateAction.CREATE_AND_DEFAULT
                                           : CreateAction.CREATE;
            decision.icon_path = current_icon;
        } else if (resp == Gtk.ResponseType.REJECT) {
            decision.action = CreateAction.SKIP;
        } else {
            decision.action = CreateAction.CANCEL;
        }

        return decision;
    }

    public string? edit_launcher (Gtk.Window parent, AppEntry entry, AppConfig cfg) {
        if (entry.entry == null)
            return null;

        var de = entry.entry;

        var dlg = new_dialog (parent, "编辑启动器", 720, 620);
        Gtk.Box content = dlg.get_content_area ();
        content.set_spacing (10);
        content.set_border_width (12);

        /* ── 上半：左预览 + 右字段 ─────────────────────────────── */

        var top = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 16);

        // 左：128px 图标预览 + 文件名
        var left = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        left.set_size_request (140, -1);

        Gdk.Pixbuf? pb = entry.get_thumbnail (128);
        if (pb != null) {
            var img = new Gtk.Image.from_pixbuf (pb);
            img.set_pixel_size (128);
            img.set_size_request (128, 128);
            left.pack_start (img, false, false, 0);
        } else {
            var ph = new Gtk.Image.from_icon_name ("application-x-executable", Gtk.IconSize.DIALOG);
            ph.set_size_request (128, 128);
            left.pack_start (ph, false, false, 0);
        }

        var fname = mk_label (GLib.Path.get_basename (de.file_path));
        fname.set_line_wrap (true);
        left.pack_start (fname, false, false, 0);

        top.pack_start (left, false, false, 0);

        // 右：字段网格
        var grid = new Gtk.Grid ();
        grid.set_column_spacing (10);
        grid.set_row_spacing (8);
        grid.set_hexpand (true);

        Gtk.Entry f_name = new Gtk.Entry ();
        f_name.set_text (de.name);
        Gtk.Entry f_cat = new Gtk.Entry ();
        f_cat.set_text (de.categories);
        Gtk.Entry f_exec = new Gtk.Entry ();
        f_exec.set_text (de.exec_line);
        Gtk.Entry f_icon = new Gtk.Entry ();
        f_icon.set_text (de.icon);
        Gtk.Entry f_comment = new Gtk.Entry ();
        f_comment.set_text (de.comment);
        Gtk.CheckButton f_term = new Gtk.CheckButton.with_label ("在终端中启动");
        f_term.active = (de.terminal.down () == "true");

        int row = 0;
        grid.attach (mk_label ("名称"), 0, row, 1, 1);
        grid.attach (f_name, 1, row++, 1, 1);
        grid.attach (mk_label ("分类"), 0, row, 1, 1);
        grid.attach (f_cat, 1, row++, 1, 1);
        grid.attach (mk_label ("命令"), 0, row, 1, 1);
        grid.attach (f_exec, 1, row++, 1, 1);
        grid.attach (mk_label ("图标"), 0, row, 1, 1);
        grid.attach (f_icon, 1, row++, 1, 1);
        grid.attach (mk_label ("备注"), 0, row, 1, 1);
        grid.attach (f_comment, 1, row++, 1, 1);
        grid.attach (f_term, 1, row++, 1, 1);

        top.pack_start (grid, true, true, 0);
        content.pack_start (top, false, false, 0);

        /* ── 下半：写入内容预览 ───────────────────────────────── */

        var prev = mk_textview ();
        var prev_path = de.file_path;
        var frame = mk_frame ("将写入 " + AppPath.shorten (prev_path), mk_scrolled (prev, 220), 220);
        content.pack_start (frame, true, true, 0);

        // 生成内容：沿用 DesktopFiles.build_content，保证「所见即所写」
        string build_preview () {
            return DesktopFiles.build_content (
                entry.path,
                f_name.text.strip (),
                de.generic_name,
                f_comment.text.strip (),
                f_icon.text.strip (),
                f_cat.text.strip (),
                de.startup_wm_class,
                entry.mimetype,
                cfg.write_marker (),
                "%U");
        }

        void refresh () {
            if (f_term.active) {
                // build_content 固定写 Terminal=false，这里按开关改写预览
                put_buffer (prev, build_preview ().replace ("Terminal=false", "Terminal=true"));
            } else {
                put_buffer (prev, build_preview ());
            }
        }

        f_name.changed.connect (() => { refresh (); });
        f_cat.changed.connect (() => { refresh (); });
        f_icon.changed.connect (() => { refresh (); });
        f_comment.changed.connect (() => { refresh (); });
        f_term.toggled.connect (() => { refresh (); });
        refresh ();

        /* ── 按钮 ────────────────────────────────────────────── */

        add_button (dlg, "取消", Gtk.ResponseType.CANCEL);

        int RESP_DELETE = 9001;
        var del_btn = add_button (dlg, "删除", RESP_DELETE);
        if (del_btn != null) {
            del_btn.get_style_context ().add_class ("destructive-action");
            del_btn.set_tooltip_text ("删除该 .desktop 文件，不影响 AppImage 本体");
        }

        int RESP_SAVE = 9002;
        var save_btn = add_button (dlg, "保存", RESP_SAVE);
        if (save_btn != null)
            save_btn.get_style_context ().add_class ("suggested-action");
        dlg.set_default_response (RESP_SAVE);

        dlg.show_all ();
        int resp = dlg.run ();

        if (resp == RESP_DELETE) {
            if (confirm (dlg, "删除启动器",
                    "将删除 %s\n\nAppImage 本体不会被删除。".printf (AppPath.shorten (de.file_path)))) {
                string? derr;
                bool ok = DesktopFiles.delete (de.file_path, out derr);
                dlg.destroy ();
                if (!ok) {
                    info (parent, "删除失败", derr ?? "未知错误", Gtk.MessageType.ERROR);
                    return null;
                }
                DesktopFiles.refresh_menu (cfg.should_update_database ());
                return de.file_path;
            }
            return null;
        }

        if (resp != RESP_SAVE) {
            dlg.destroy ();
            return null;
        }

        string content_text = f_term.active
            ? build_preview ().replace ("Terminal=false", "Terminal=true")
            : build_preview ();

        string verr = DesktopFiles.validate_content (content_text);
        if (verr != "") {
            info (dlg, "内容校验未通过",
                "desktop-file-validate 报告：\n%s\n\n已取消保存。".printf (verr),
                Gtk.MessageType.WARNING);
            dlg.destroy ();
            return null;
        }

        string? werr;
        DesktopFiles.write_atomic (de.file_path, content_text, out werr);
        dlg.destroy ();

        if (werr != null) {
            info (parent, "写入失败", werr, Gtk.MessageType.ERROR);
            return null;
        }

        DesktopFiles.refresh_menu (cfg.should_update_database ());
        return de.file_path;
    }

    /* ══════════════════════════════════════════════════════════════
     *  2. 修复
     * ══════════════════════════════════════════════════════════════ */

    private Gtk.RadioButton mk_radio (Gtk.RadioButton? group, string text, string? sub) {
        var rb = new Gtk.RadioButton.with_label_from_widget (group, text);
        if (sub != null) {
            rb.tooltip_text = sub;
            var box = (Gtk.Box) rb.get_child ();
            var v = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            v.pack_start (box, false, false, 0);
            var d = mk_label (sub, 0.0f);
            d.get_style_context ().add_class ("dim-label");
            d.set_margin_start (26);
            v.pack_start (d, false, false, 0);
            rb.remove (box);
            rb.add (v);
        }
        return rb;
    }

    /**
     * 修复对话框。
     * @return 执行完成返回 Repair.ExecResult；取消返回 null
     */
    public Repair.ExecResult? repair_entry (Gtk.Window parent, AppEntry entry, AppConfig cfg) {
        if (entry.entry == null)
            return null;

        var plan = new RepairPlan (entry, entry.entry);
        plan.problems = entry.problems;
        plan.selected = new bool[entry.problems.length];
        for (int i = 0; i < entry.problems.length; i++) {
            var p = entry.problems[i];
            // 需要确认的项默认不勾；不可修的项直接禁用
            plan.selected[i] = p.applyable && !p.needs_confirm;
        }
        plan.mode = FixMode.CONSERVATIVE;

        /* ── 提前声明：Vala 局部函数只能引用在其之前声明的变量/函数，
         *    故部件变量先声明、稍后建 UI 时再赋值 ── */

        Gtk.RadioButton? r_cons = null;
        Gtk.RadioButton? r_enrich = null;
        Gtk.RadioButton? r_rebuild = null;
        Gtk.CheckButton[] keep_checks = new Gtk.CheckButton[0];
        Gtk.CheckButton? rename_cb = null;
        Gtk.TextView? diff_view = null;
        Gtk.Label? status = null;
        Gtk.Button? apply_btn = null;
        Gtk.Widget[] drop_widgets = new Gtk.Widget[0];

        string[] PRESERVE_OPTS = { "Name", "Comment", "Actions" };
        string[] PRESERVE_DESC = {
            "保留现有的 Name=（不采用 AppImage 内的名称）",
            "保留现有的 Comment=",
            "保留 Desktop Actions 分组及其 Actions= 引用"
        };

        string[] collect_preserve () {
            var list = new GenericArray<string> ();
            for (int i = 0; i < PRESERVE_OPTS.length; i++)
                if (keep_checks[i] != null && keep_checks[i].active)
                    list.add (PRESERVE_OPTS[i]);
            return list.steal ();
        }

        void recount () {
            int n = 0;
            foreach (bool b in plan.selected)
                if (b) n++;
            status.label = "将应用 %d 项修改 · 模式：%s".printf (
                n, mode_name (plan.mode));
            if (apply_btn != null)
                apply_btn.label = "备份并修复 %d 项".printf (n);
            apply_btn.sensitive = (n > 0) || (plan.mode == FixMode.REBUILD);
        }

        void update_preview () {
            plan.mode = r_cons.active ? FixMode.CONSERVATIVE
                     : (r_enrich.active ? FixMode.ENRICH : FixMode.REBUILD);
            plan.preserve_keys = collect_preserve ();

            // 保留 Desktop Actions 需要 Actions= 与对应分组同时存在
            if (r_rebuild.active && !keep_holds_actions (keep_checks))
                plan.drop_keys = plan.drop_keys;

            plan.rename_file = rename_cb.active;

            string proposed = Repair.build_repaired (plan);
            string diff = Repair.diff (plan.original_content, proposed);
            put_buffer (diff_view, diff == "" ? "（无变化）" : diff);

            // 丢弃区可见性
            bool show_drop = (plan.mode == FixMode.REBUILD);
            foreach (var w in drop_widgets)
                w.visible = show_drop;

            recount ();
        }

        void on_mode_changed () {
            update_preview ();
        }

        // 文件名规范化目标
        string cur_base = GLib.Path.get_basename (entry.entry.file_path);
        string slug = AppPath.slugify (cur_base.replace (".desktop", ""));
        string prop_base = "%s.desktop".printf (slug);
        plan.new_basename = prop_base;

        var dlg = new_dialog (parent, "修复 " + entry.display_name, 860, 760);
        Gtk.Box content = dlg.get_content_area ();
        content.set_border_width (12);
        content.set_spacing (10);

        // 整个界面放进滚动区
        var scroll_outer = new Gtk.ScrolledWindow (null, null);
        scroll_outer.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);

        var flow = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        flow.set_border_width (12);
        scroll_outer.add (flow);
        content.pack_start (scroll_outer, true, true, 0);

        /* ── 头部 ────────────────────────────────────────────── */

        var head = new Gtk.Box (Gtk.Orientation.VERTICAL, 3);
        var h_title = new Gtk.Label (null);
        h_title.use_markup = true;
        h_title.label = "<b>修复 %s</b>".printf (GLib.Markup.escape_text (entry.display_name, -1));
        h_title.xalign = 0.0f;
        head.pack_start (h_title, false, false, 0);

        head.pack_start (mk_label ("启动器：" + AppPath.shorten (entry.entry.file_path)), false, false, 0);
        head.pack_start (mk_label ("AppImage：" + AppPath.shorten (entry.path)), false, false, 0);

        // 匹配方式
        string how = entry.entry.is_managed ? "标记键（%s）".printf (DesktopFiles.MARKER_PATH)
                    : (entry.entry.exec_target != null ? "Exec= 路径匹配" : "未知");
        head.pack_start (mk_label ("匹配方式：" + how), false, false, 0);

        string vmsg = DesktopFiles.validate_file (entry.entry.file_path);
        var vlab = mk_label (vmsg == "" ? "desktop-file-validate：通过" : "desktop-file-validate：" + vmsg);
        if (vmsg != "")
            vlab.get_style_context ().add_class ("warning");
        head.pack_start (vlab, false, false, 0);

        flow.pack_start (head, false, false, 0);
        flow.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 0);

        /* ── 问题列表 ────────────────────────────────────────── */

        var prob_title = new Gtk.Label (null);
        prob_title.use_markup = true;
        prob_title.label = "<b>发现 %d 个问题</b>".printf (entry.problems.length);
        prob_title.xalign = 0.0f;
        flow.pack_start (prob_title, false, false, 0);

        var prob_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);

        Gtk.CheckButton[] prob_checks = new Gtk.CheckButton[entry.problems.length];
        for (int i = 0; i < entry.problems.length; i++) {
            var p = entry.problems[i];
            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);

            var cb = new Gtk.CheckButton ();
            cb.active = plan.selected[i];
            cb.sensitive = p.applyable;
            cb.toggled.connect (() => {
                plan.selected[i] = cb.active;
                recount ();
            });
            prob_checks[i] = cb;
            row.pack_start (cb, false, false, 0);

            var texts = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);

            // 严重度徽章 + 标题
            var badge = new Gtk.Label (null);
            badge.use_markup = true;
            badge.label = "<span foreground='%s' weight='bold'>[%s]</span> %s".printf (
                p.severity_color (),
                GLib.Markup.escape_text (p.severity_label (), -1),
                GLib.Markup.escape_text (p.title, -1));
            badge.xalign = 0.0f;
            badge.set_line_wrap (true);
            if (!p.applyable) {
                var t = badge.label;
                badge.label = t + " <span foreground='#95a5a6'>（需手工处理）</span>";
            }
            texts.pack_start (badge, false, false, 0);

            var cur = mk_label ("当前：" + (p.current == "" ? "—" : p.current));
            cur.get_style_context ().add_class ("dim-label");
            cur.set_line_wrap (true);
            cur.set_margin_start (12);
            texts.pack_start (cur, false, false, 0);

            var fixl = mk_label ("修复：" + (p.fixed == "" ? "—" : p.fixed), 0.0f);
            fixl.set_line_wrap (true);
            fixl.set_margin_start (12);
            texts.pack_start (fixl, false, false, 0);

            row.pack_start (texts, true, true, 0);
            prob_box.pack_start (row, false, false, 0);
        }
        flow.pack_start (prob_box, false, false, 0);
        flow.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 0);

        /* ── 修复模式 ────────────────────────────────────────── */

        var mode_title = new Gtk.Label (null);
        mode_title.use_markup = true;
        mode_title.label = "<b>修复模式</b>";
        mode_title.xalign = 0.0f;
        flow.pack_start (mode_title, false, false, 0);

        r_cons = mk_radio (null, "保守",
            "只修明确坏掉的字段，不新增任何键");
        r_enrich = mk_radio (r_cons, "补全",
            "在保守基础上补齐 Icon / Categories / Comment 等缺失字段");
        r_rebuild = mk_radio (r_cons, "重建",
            "整体重新生成 .desktop；下方未勾选的现有内容会丢失");

        var mode_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
        mode_box.pack_start (r_cons, false, false, 0);
        mode_box.pack_start (r_enrich, false, false, 0);
        mode_box.pack_start (r_rebuild, false, false, 0);
        flow.pack_start (mode_box, false, false, 0);

        /* ── 保留 / 丢弃 ─────────────────────────────────────── */

        var keep_title = new Gtk.Label (null);
        keep_title.use_markup = true;
        keep_title.label = "<b>将保留的现有内容</b>";
        keep_title.xalign = 0.0f;
        flow.pack_start (keep_title, false, false, 0);

        keep_checks = new Gtk.CheckButton[PRESERVE_OPTS.length];
        var keep_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 3);
        for (int i = 0; i < PRESERVE_OPTS.length; i++) {
            var cb = new Gtk.CheckButton.with_label (PRESERVE_DESC[i]);
            // 有对应内容时才可勾
            bool has_value = true;
            if (PRESERVE_OPTS[i] == "Name")       has_value = entry.entry.name != "";
            else if (PRESERVE_OPTS[i] == "Comment") has_value = entry.entry.comment != "";
            else                                    has_value = entry.entry.has_group ();
            cb.sensitive = has_value;
            if (has_value) cb.active = true;
            keep_checks[i] = cb;
            keep_box.pack_start (cb, false, false, 0);
        }
        flow.pack_start (keep_box, false, false, 0);

        // 丢弃区：只有重建模式下才有意义
        var drop_title = new Gtk.Label (null);
        drop_title.use_markup = true;
        drop_title.label = "<b>将被丢弃的内容</b>";
        drop_title.xalign = 0.0f;
        flow.pack_start (drop_title, false, false, 0);

        var drop_lab = mk_label ("（重建模式下，除上方勾选的保留项外，其余键与自定义分组都会被新内容覆盖）");
        drop_lab.set_line_wrap (true);
        drop_lab.get_style_context ().add_class ("dim-label");
        flow.pack_start (drop_lab, false, false, 0);

        drop_widgets = new Gtk.Widget[] { drop_title, drop_lab };

        /* ── 文件名规范化 ────────────────────────────────────── */

        bool name_differs = (prop_base != cur_base);
        rename_cb = new Gtk.CheckButton.with_label ("规范化文件名");
        rename_cb.tooltip_text = "把启动器文件改成规范的 slug 名称";
        var rename_lab = mk_label (name_differs
            ? "%s  →  %s".printf (cur_base, prop_base)
            : "%s（已是规范形式）".printf (cur_base));
        if (!name_differs)
            rename_cb.sensitive = false;
        rename_cb.active = name_differs && p_has_i008 (entry.problems);

        var rename_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        rename_box.pack_start (rename_cb, false, false, 0);
        rename_box.pack_start (rename_lab, false, false, 0);
        flow.pack_start (rename_box, false, false, 0);

        rename_cb.toggled.connect (() => {
            plan.rename_file = rename_cb.active;
            update_preview ();
        });

        flow.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 0);

        /* ── 差异预览 ────────────────────────────────────────── */

        var diff_title = new Gtk.Label (null);
        diff_title.use_markup = true;
        diff_title.label = "<b>差异预览</b>（− 删除 / ＋ 新增）";
        diff_title.xalign = 0.0f;
        flow.pack_start (diff_title, false, false, 0);

        diff_view = mk_textview ();
        flow.pack_start (mk_frame ("将写入 " + AppPath.shorten (entry.entry.file_path),
            mk_scrolled (diff_view, 200), 200), false, false, 0);

        /* ── 状态：选中项数 ──────────────────────────────────── */

        status = mk_label ("");
        flow.pack_start (status, false, false, 0);

        int RESP_APPLY = 9003;
        apply_btn = add_button (dlg, "备份并修复", RESP_APPLY);
        var auto_db = new Gtk.CheckButton.with_label ("修复后自动 update-desktop-database");
        auto_db.active = cfg.should_update_database ();
        dlg.get_action_area ().pack_start (auto_db, false, false, 8);

        add_button (dlg, "取消", Gtk.ResponseType.CANCEL);

        /* ── 计算逻辑（局部函数已在方法开头提前定义）────────────── */

        r_cons.toggled.connect (() => { on_mode_changed (); });
        r_enrich.toggled.connect (() => { on_mode_changed (); });
        r_rebuild.toggled.connect (() => { on_mode_changed (); });

        foreach (var cb in keep_checks)
            if (cb != null) cb.toggled.connect (() => { update_preview (); });

        update_preview ();

        /* ── 执行 ────────────────────────────────────────────── */

        dlg.show_all ();
        // show_all 之后按模式再刷一次可见性
        foreach (var w in drop_widgets)
            w.visible = (plan.mode == FixMode.REBUILD);
        apply_btn.sensitive = false;
        recount ();

        int resp = dlg.run ();

        if (resp != RESP_APPLY) {
            dlg.destroy ();
            return null;
        }

        // 重新确认一次（勾选可能已被用户改）
        update_preview ();

        if (!plan.any_selected () && plan.mode != FixMode.REBUILD) {
            dlg.destroy ();
            info (parent, "未选择任何修复项", "请至少勾选一项后再执行。", Gtk.MessageType.WARNING);
            return null;
        }

        var result = Repair.execute (new RepairPlan[] { plan }, cfg);

        bool want_db = auto_db.active || cfg.should_update_database ();
        DesktopFiles.refresh_menu (want_db);

        dlg.destroy ();

        show_result (parent, result);
        return result;
    }

    /** 是否勾选了「保留 Desktop Actions」 */
    private bool keep_holds_actions (Gtk.CheckButton[] checks) {
        return checks.length > 2 && checks[2] != null && checks[2].active;
    }

    private bool p_has_i008 (RuleSet.Problem[] problems) {
        foreach (var p in problems)
            if (p.id == "I008") return true;
        return false;
    }

    private string mode_name (FixMode m) {
        switch (m) {
            case FixMode.CONSERVATIVE: return "保守";
            case FixMode.ENRICH:       return "补全";
            default:                   return "重建";
        }
    }

    private void show_result (Gtk.Window? parent, Repair.ExecResult r) {
        string head = "完成 %d / %d 项".printf (r.done, r.total);
        if (r.failed > 0)
            head += "，失败 %d 项".printf (r.failed);
        if (r.rolled_back)
            head += "\n\n已触发回滚策略，本次修改全部撤销。";

        string body = head;
        if (r.messages != null && r.messages.length > 0) {
            var sb = new GLib.StringBuilder ();
            sb.append (head).append ("\n\n");
            foreach (string m in r.messages)
                sb.append ("• ").append (m).append ("\n");
            body = sb.str;
        }
        info (parent, "修复结果", body,
            r.failed > 0 ? Gtk.MessageType.WARNING : Gtk.MessageType.INFO);
    }

    /* ══════════════════════════════════════════════════════════════
     *  3. 进度对话框
     * ══════════════════════════════════════════════════════════════ */

    public class ProgressDialog : Gtk.Dialog {

        private Gtk.ProgressBar bar;
        private Gtk.TextView log_view;
        private Gtk.Label count_label;

        private bool cancel_flag = false;
        private bool suppress_response = false;
        private Gtk.Button cancel_button;

        /** worker 在每一步检查此标志 */
        public bool cancelled {
            get { return cancel_flag; }
        }

        private void on_response (int id) {
            if (suppress_response)
                return;
            if (id == Gtk.ResponseType.CANCEL)
                cancel_flag = true;
        }

        public ProgressDialog (Gtk.Window? parent, string title) {
            set_transient_for (parent);
            set_modal (true);
            set_position (Gtk.WindowPosition.CENTER_ON_PARENT);
            this.title = title;
            set_default_size (520, 360);
            set_deletable (false);   // 不可用关闭按钮关掉
            set_border_width (0);

            Gtk.Box content = get_content_area ();
            content.set_border_width (12);
            content.set_spacing (10);

            count_label = mk_label ("准备中…");
            content.pack_start (count_label, false, false, 0);

            bar = new Gtk.ProgressBar ();
            bar.show_text = true;
            bar.text = "0 / 0";
            content.pack_start (bar, false, false, 0);

            log_view = mk_textview ();
            content.pack_start (mk_scrolled (log_view, 200), true, true, 0);

            cancel_button = add_button ("取消", Gtk.ResponseType.CANCEL) as Gtk.Button;
            set_default_response (Gtk.ResponseType.CANCEL);

            // 取消只是置标志，不销毁对话框（worker 负责收尾）
            response.connect (on_response);

            delete_event.connect (() => {
                cancel_flag = true;
                return true;    // 阻止关闭
            });

            show_all ();
        }

        /** 更新进度：current 为已完成数，total 为总数 */
        public void set_progress (int current, int total, string current_label) {
            if (total > 0)
                bar.fraction = (double) current / (double) total;
            else
                bar.fraction = 0.0;

            bar.text = "%d / %d".printf (current, total);
            count_label.label = current_label ?? "";
            count_label.xalign = 0.0f;

            if (cancel_button != null)
                cancel_button.label = cancel_flag ? "正在中止…" : "取消";
        }

        public void log_done (string message) {
            append_log ("✓ " + message, "#2e9e4f");
        }

        public void log_fail (string message, string error) {
            append_log ("✗ " + message + (error == "" ? "" : " —— " + error), "#e74c3c");
        }

        public void log_info (string message) {
            append_log ("· " + message, null);
        }

        private void append_log (string text, string? color) {
            Gtk.TextBuffer buf = log_view.buffer;
            Gtk.TextIter end;
            buf.get_end_iter (out end);
            if (color != null) {
                // color 是 CSS 颜色值，不是标签名 ——
                // 首次使用时按颜色建一个同名标签，之后复用。
                var table = buf.get_tag_table ();
                if (table.lookup (color) == null)
                    buf.create_tag (color, "foreground", color, null);
                buf.insert_with_tags_by_name (ref end, text + "\n", -1, color);
            } else {
                buf.insert (ref end, text + "\n", -1);
            }
            // 滚到底
            Gtk.TextIter tail;
            buf.get_end_iter (out tail);
            Gtk.TextMark mark = buf.create_mark (null, tail, false);
            log_view.scroll_mark_onscreen (mark);
            buf.delete_mark (mark);
        }

        /** 关闭并销毁；worker 结束后调用 */
        public void finish () {
            suppress_response = true;
            hide ();
            destroy ();
        }
    }

    public ProgressDialog progress (Gtk.Window parent, string title) {
        return new ProgressDialog (parent, title);
    }

    /* ══════════════════════════════════════════════════════════════
     *  4. 清理（失效与孤立项）
     * ══════════════════════════════════════════════════════════════ */

    private class CleanupTarget : GLib.Object {
        public Gtk.CheckButton check;
        public string kind;        // "launcher" / "appimage"
        public string path;
        public string title;
        public string? icon;
    }

    /**
     * @return 被清理的数量；取消返回 -1
     */
    public int cleanup (Gtk.Window parent, Store store) {
        var targets = new GenericArray<CleanupTarget> ();

        // 1) 失效启动器
        foreach (var de in store.broken_entries) {
            var t = new CleanupTarget ();
            t.kind = "launcher";
            t.path = de.file_path;
            t.title = de.basename;
            t.icon = de.icon != "" ? de.icon : null;
            targets.add (t);
        }

        // 2) 孤立 AppImage：有文件但没有启动器
        foreach (var e in store.entries) {
            if (e.entry != null)
                continue;
            var t = new CleanupTarget ();
            t.kind = "appimage";
            t.path = e.path;
            t.title = e.basename;
            t.icon = e.icon_path;
            targets.add (t);
        }

        int n_broken = 0, n_orphan = 0;
        foreach (var t in targets) {
            if (t.kind == "launcher") n_broken++; else n_orphan++;
        }

        if (targets.length == 0) {
            info (parent, "没有可清理的项", "既没有失效启动器，也没有孤立 AppImage。", Gtk.MessageType.INFO);
            return -1;
        }

        var dlg = new_dialog (parent, "清理", 720, 620);
        Gtk.Box content = dlg.get_content_area ();
        content.set_border_width (12);
        content.set_spacing (10);

        var outer = new Gtk.ScrolledWindow (null, null);
        outer.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        var flow = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        flow.set_border_width (12);
        outer.add (flow);
        content.pack_start (outer, true, true, 0);

        // 顶部摘要
        var sum = new Gtk.Label (null);
        sum.use_markup = true;
        sum.xalign = 0.0f;
        sum.label = "失效启动器 <b>%d</b> 个 · 孤立 AppImage <b>%d</b> 个".printf (n_broken, n_orphan);
        flow.pack_start (sum, false, false, 0);

        Gtk.CheckButton[] all_checks = new Gtk.CheckButton[targets.length];

        int section_start = 0;
        for (int pass = 0; pass < 2; pass++) {
            bool is_launcher = (pass == 0);
            string head = is_launcher ? "失效启动器" : "孤立 AppImage（无启动器）";

            var h = new Gtk.Label (null);
            h.use_markup = true;
            h.xalign = 0.0f;
            h.label = "<b>%s</b>".printf (head);
            flow.pack_start (h, false, false, 0);

            bool any = false;
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
            for (int i = section_start; i < targets.length; i++) {
                var t = targets[i];
                if ((t.kind == "launcher") != is_launcher)
                    continue;
                any = true;

                var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
                var cb = new Gtk.CheckButton ();
                cb.active = true;
                all_checks[i] = cb;
                row.pack_start (cb, false, false, 0);

                var texts = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);
                var name = mk_label (t.title);
                name.set_margin_start (4);
                texts.pack_start (name, false, false, 0);

                string detail;
                if (is_launcher) {
                    string ex = t.icon ?? "";
                    detail = "Exec 目标：%s   ✗ 文件已不存在".printf (
                        ex != "" ? ex : "（未知）");
                } else {
                    detail = "%s · %s   ✗ 没有对应的启动器".printf (
                        t.path, AppPath.format_size (AppPath.file_size (t.path)));
                }
                var d = mk_label (detail);
                d.get_style_context ().add_class ("dim-label");
                d.set_margin_start (16);
                texts.pack_start (d, false, false, 0);

                row.pack_start (texts, true, true, 0);
                box.pack_start (row, false, false, 0);
            }

            if (any) {
                flow.pack_start (box, false, false, 0);
                flow.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 0);
            } else {
                var none = mk_label ("（无）");
                none.get_style_context ().add_class ("dim-label");
                flow.pack_start (none, false, false, 0);
            }
            section_start += 0;   // 保持可读性：sections 用 kind 过滤
        }

        var also_icon = new Gtk.CheckButton.with_label ("顺便把失效启动器的缓存图标也清理掉");
        also_icon.tooltip_text = "只删除指向缓存目录且无其它启动器引用的图标";
        flow.pack_start (also_icon, false, false, 0);

        int RESP_CLEAN = 9004;
        var clean_btn = add_button (dlg, "清理", RESP_CLEAN);
        if (clean_btn != null)
            clean_btn.get_style_context ().add_class ("destructive-action");
        add_button (dlg, "取消", Gtk.ResponseType.CANCEL);
        dlg.set_default_response (RESP_CLEAN);

        void recount () {
            int n = 0;
            foreach (var cb in all_checks)
                if (cb != null && cb.active) n++;
            if (clean_btn != null)
                clean_btn.label = "清理 %d 项".printf (n);
            clean_btn.sensitive = (n > 0);
        }

        foreach (var cb in all_checks) {
            if (cb != null) cb.toggled.connect (() => { recount (); });
        }
        recount ();

        dlg.show_all ();
        int resp = dlg.run ();

        if (resp != RESP_CLEAN) {
            dlg.destroy ();
            return -1;
        }

        int ok = 0, failed = 0;
        var msgs = new GenericArray<string> ();

        for (int i = 0; i < targets.length; i++) {
            var t = targets[i];
            if (all_checks[i] == null || !all_checks[i].active)
                continue;

            if (t.kind == "launcher") {
                string? derr;
                if (DesktopFiles.delete (t.path, out derr)) {
                    ok++;
                    if (also_icon.active && t.icon != null && t.icon.has_prefix ("/"))
                        remove_if_unreferenced (t.icon);
                } else {
                    failed++;
                    msgs.add ("%s —— %s".printf (t.title, derr ?? "删除失败"));
                }
            } else {
                try {
                    AppPath.file_remove (t.path);
                    ok++;
                } catch {
                    failed++;
                    msgs.add ("%s —— 无法删除".printf (t.title));
                }
            }
        }

        DesktopFiles.refresh_menu (true);
        dlg.destroy ();

        string body = "已清理 %d 项".printf (ok);
        if (failed > 0)
            body += "，失败 %d 项".printf (failed);
        if (msgs.length > 0) {
            var sb = new GLib.StringBuilder ();
            sb.append (body).append ("\n\n");
            foreach (string m in msgs)
                sb.append ("• ").append (m).append ("\n");
            body = sb.str;
        }
        info (parent, "清理完成", body,
            failed > 0 ? Gtk.MessageType.WARNING : Gtk.MessageType.INFO);

        return ok;
    }

    /** 图标没有被其它启动器引用时才删 */
    private void remove_if_unreferenced (string icon_path) {
        if (!AppPath.exists (icon_path))
            return;
        foreach (var d in DesktopFiles.scan_directory (AppPath.applications_dir ()))
            if (d.icon == icon_path)
                return;
        AppPath.file_remove (icon_path);
    }

    /* ══════════════════════════════════════════════════════════════
     *  5. 认领
     * ══════════════════════════════════════════════════════════════ */

    public Repair.ExecResult? claim_entry (Gtk.Window parent, AppEntry entry,
                                           DesktopFiles.Entry d, AppConfig cfg) {

        if (d.is_managed) {
            info (parent, "已被管理", "%s 已带标记键，无需认领。".printf (d.basename), Gtk.MessageType.INFO);
            return null;
        }

        var plan = new RepairPlan (entry, d);
        plan.claim = true;
        plan.mode = FixMode.CONSERVATIVE;
        plan.problems = {};
        plan.selected = {};

        var dlg = new_dialog (parent, "认领 " + entry.display_name, 720, 560);
        Gtk.Box content = dlg.get_content_area ();
        content.set_border_width (12);
        content.set_spacing (10);

        // 头部信息
        var head = new Gtk.Box (Gtk.Orientation.VERTICAL, 3);
        var t = new Gtk.Label (null);
        t.use_markup = true;
        t.xalign = 0.0f;
        t.label = "<b>把该启动器纳入本工具管理</b>";
        head.pack_start (t, false, false, 0);
        head.pack_start (mk_label ("启动器：" + AppPath.shorten (d.file_path)), false, false, 0);
        head.pack_start (mk_label ("当前 Exec：" + (d.exec_line == "" ? "（缺失）" : d.exec_line)), false, false, 0);
        head.pack_start (mk_label ("AppImage：" + AppPath.shorten (entry.path)), false, false, 0);

        bool wrapper = DesktopFiles.exec_is_wrapper (d.exec_line);
        var wlab = mk_label (wrapper
            ? "检测结果：Exec 指向包装脚本（不是 AppImage 本体）"
            : "检测结果：Exec 直接指向可执行文件");
        if (wrapper)
            wlab.get_style_context ().add_class ("warning");
        head.pack_start (wlab, false, false, 0);

        content.pack_start (head, false, false, 0);
        content.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 0);

        // 选项
        var opt_title = new Gtk.Label (null);
        opt_title.use_markup = true;
        opt_title.xalign = 0.0f;
        opt_title.label = "<b>认领选项</b>";
        content.pack_start (opt_title, false, false, 0);

        var c_escape = new Gtk.CheckButton.with_label ("修正 Exec 转义");
        c_escape.tooltip_text = "把路径写成带引号并转义的合法 Exec 参数";
        c_escape.active = true;

        var c_direct = new Gtk.CheckButton.with_label ("改为直接指向 AppImage 本体");
        c_direct.tooltip_text = "去掉 sh -c 之类的包装脚本层";
        c_direct.active = wrapper;

        var c_rename = new Gtk.CheckButton.with_label ("规范化文件名");
        string cur_base = GLib.Path.get_basename (d.file_path);
        string prop_base = "%s.desktop".printf (AppPath.slugify (cur_base.replace (".desktop", "")));
        c_rename.active = (prop_base != cur_base);
        c_rename.sensitive = (prop_base != cur_base);

        var c_enrich = new Gtk.CheckButton.with_label ("补全缺失字段");
        c_enrich.tooltip_text = "同时补齐 Icon / Categories / Comment 等缺失键";

        var opts = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
        opts.pack_start (c_escape, false, false, 0);
        opts.pack_start (c_direct, false, false, 0);
        opts.pack_start (c_rename, false, false, 0);
        opts.pack_start (c_enrich, false, false, 0);
        content.pack_start (opts, false, false, 0);

        var rename_lab = mk_label (c_rename.sensitive
            ? "%s  →  %s".printf (cur_base, prop_base)
            : "%s（已是规范形式）".printf (cur_base));
        rename_lab.get_style_context ().add_class ("dim-label");
        rename_lab.set_margin_start (26);
        content.pack_start (rename_lab, false, false, 0);

        content.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 0);

        // 差异预览：重点是末尾两行标记键
        var dt = new Gtk.Label (null);
        dt.use_markup = true;
        dt.xalign = 0.0f;
        dt.label = "<b>将追加的两行标记</b>";
        content.pack_start (dt, false, false, 0);

        var marker_view = mk_textview ();
        marker_view.buffer.text =
            "%s=true\n%s=%s\n%s=%s".printf (
                DesktopFiles.MARKER_BOOL,
                DesktopFiles.MARKER_PATH, entry.path,
                DesktopFiles.MARKER_VERSION, APPMGR_VERSION);
        content.pack_start (mk_frame ("标记键", mk_scrolled (marker_view, 90), 90), false, false, 0);

        var diff_view = mk_textview ();
        content.pack_start (mk_frame ("完整差异", mk_scrolled (diff_view, 160), 160), true, true, 0);

        int RESP_CLAIM = 9005;
        var claim_btn = add_button (dlg, "认领", RESP_CLAIM);
        if (claim_btn != null)
            claim_btn.get_style_context ().add_class ("suggested-action");
        add_button (dlg, "取消", Gtk.ResponseType.CANCEL);
        dlg.set_default_response (RESP_CLAIM);

        void update () {
            plan.rewrite_exec = c_escape.active;
            plan.fix_wrapper = c_direct.active;
            plan.rename_file = c_rename.active;
            plan.new_basename = prop_base;
            plan.mode = c_enrich.active ? FixMode.ENRICH : FixMode.CONSERVATIVE;

            // 没有 problems 时，直接把相关修正写进内容
            string proposed = claim_rebuild (entry, d, plan);
            plan.original_content = read_text (d.file_path);
            put_buffer (diff_view,
                Repair.diff (plan.original_content, proposed) == ""
                    ? "（无变化）"
                    : Repair.diff (plan.original_content, proposed));
        }

        c_escape.toggled.connect (() => { update (); });
        c_direct.toggled.connect (() => { update (); });
        c_rename.toggled.connect (() => { update (); });
        c_enrich.toggled.connect (() => { update (); });
        update ();

        dlg.show_all ();
        int resp = dlg.run ();

        if (resp != RESP_CLAIM) {
            dlg.destroy ();
            return null;
        }

        update ();
        string? error = null;
        if (DesktopFiles.validate_content (plan.proposed_content) != "")
            error = DesktopFiles.validate_content (plan.proposed_content);

        if (error != null) {
            info (dlg, "校验未通过",
                "生成的内容未通过 desktop-file-validate：\n%s".printf (error),
                Gtk.MessageType.WARNING);
            dlg.destroy ();
            return null;
        }

        var result = Repair.execute (new RepairPlan[] { plan }, cfg);
        DesktopFiles.refresh_menu (cfg.should_update_database ());
        dlg.destroy ();

        info (parent, "认领结果",
            result.done > 0
                ? "已认领 %s".printf (d.basename)
                : "认领失败，请查看历史记录。",
            result.done > 0 ? Gtk.MessageType.INFO : Gtk.MessageType.WARNING);
        return result;
    }

    private string read_text (string path) {
        string data;
        try {
            if (GLib.FileUtils.get_contents (path, out data))
                return data;
        } catch {}
        return "";
    }

    /**
     * 认领场景没有 problems 列表，直接按选项构造内容。
     * 复用 Repair.build_repaired 需要 selected 与 problems 对齐，这里改走
     * DesktopFiles.build_content + 标记键，行为等价且不依赖规则引擎。
     */
    private string claim_rebuild (AppEntry entry, DesktopFiles.Entry d, RepairPlan plan) {
        string content;

        bool rewrite = plan.rewrite_exec || plan.fix_wrapper;
        string exec_line = d.exec_line;

        if (rewrite) {
            exec_line = DesktopFiles.build_exec_arg (entry.path) + " %U";
        }

        if (plan.mode == FixMode.ENRICH) {
            content = DesktopFiles.build_content (
                entry.path,
                d.name != "" ? d.name : entry.get_best_name (),
                d.generic_name,
                d.comment,
                d.icon,
                d.categories != "" ? d.categories : (entry.categories != "" ? entry.categories : "Utility;"),
                d.startup_wm_class,
                entry.mimetype,
                true, "%U");
        } else {
            // 只认领 + 可选修 Exec：保留原文，替换必要字段
            var sb = new GLib.StringBuilder ();
            foreach (string raw in read_text (d.file_path).split ("\n")) {
                string line = raw.strip ();
                if (line == "" || line.has_prefix ("#"))
                    continue;

                if (line.has_prefix ("[") && line.has_suffix ("]")) {
                    if (line == "[Desktop Entry]") {
                        if (sb.len > 0) sb.append_c ('\n');
                        sb.append ("[Desktop Entry]\n");
                    }
                    continue;
                }

                int eq = line.index_of_char ('=');
                if (eq <= 0)
                    continue;

                string key = line.substring (0, eq).strip ();
                if (key.has_prefix (DesktopFiles.MARKER_BOOL)
                 || key.has_prefix (DesktopFiles.MARKER_PATH)
                 || key.has_prefix (DesktopFiles.MARKER_VERSION))
                    continue;      // 重新追加，保证在末尾

                if (key == "Exec" && rewrite)
                    sb.append ("Exec=%s\n".printf (exec_line));
                else if (key == "TryExec")
                    sb.append ("TryExec=%s\n".printf (entry.path));
                else
                    sb.append (line).append_c ('\n');
            }

            content = sb.str;
            if (!content.has_suffix ("\n"))
                content += "\n";
        }

        // 末尾追加标记键
        var out = new GLib.StringBuilder ();
        out.append (content);
        if (content.length > 0 && !content.has_suffix ("\n"))
            out.append_c ('\n');
        out.append ("%s=true\n".printf (DesktopFiles.MARKER_BOOL));
        out.append ("%s=%s\n".printf (DesktopFiles.MARKER_PATH, entry.path));
        out.append ("%s=%s\n".printf (DesktopFiles.MARKER_VERSION, APPMGR_VERSION));

        plan.proposed_content = out.str;
        return plan.proposed_content;
    }

    /* ══════════════════════════════════════════════════════════════
     *  6. 设置
     * ══════════════════════════════════════════════════════════════ */

    public bool settings (Gtk.Window parent, AppConfig cfg) {
        var dlg = new_dialog (parent, "设置", 640, 660);
        Gtk.Box content = dlg.get_content_area ();
        content.set_border_width (12);
        content.set_spacing (12);

        var scroll = new Gtk.ScrolledWindow (null, null);
        scroll.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        var flow = new Gtk.Box (Gtk.Orientation.VERTICAL, 14);
        flow.set_border_width (12);
        scroll.add (flow);
        content.pack_start (scroll, true, true, 0);

        /* 图标尺寸 */
        var sec = section_title ("图标");
        flow.pack_start (sec, false, false, 0);

        int cur_size = cfg.icon_size ();
        Gtk.RadioButton? size_first = null;
        Gtk.RadioButton[] size_radios = new Gtk.RadioButton[3];
        int[] sizes = { 128, 256, 512 };
        for (int i = 0; i < sizes.length; i++) {
            var rb = (size_radios[i] = new Gtk.RadioButton.with_label_from_widget (
                size_first, "%d × %d".printf (sizes[i], sizes[i])));
            if (size_first == null) size_first = rb;
            rb.active = (cur_size == sizes[i]);
            flow.pack_start (rb, false, false, 0);
        }

        /* 开关 */
        flow.pack_start (section_title ("扫描"), false, false, 0);
        var sw_recursive = mk_switch ("递归扫描子目录", cfg.recursive ());
        var sw_autostart = mk_switch ("启动时自动扫描", cfg.auto_on_startup ());
        flow.pack_start (sw_recursive, false, false, 0);
        flow.pack_start (sw_autostart, false, false, 0);

        flow.pack_start (section_title ("同步"), false, false, 0);
        var sw_udb = mk_switch ("写入后运行 update-desktop-database", cfg.should_update_database ());
        var sw_uic = mk_switch ("写入后运行 gtk-update-icon-cache", cfg.should_update_icon_cache ());
        var sw_marker = mk_switch ("写标记键（X-AppImage-Manager-*）", cfg.write_marker ());
        var sw_del_icon = mk_switch ("删除启动器时同时删图标", cfg.delete_icon_with_launcher ());
        flow.pack_start (sw_udb, false, false, 0);
        flow.pack_start (sw_uic, false, false, 0);
        flow.pack_start (sw_marker, false, false, 0);
        flow.pack_start (sw_del_icon, false, false, 0);

        /* ── 元数据提取（解包）───────────────────────────────
         *
         * 解包是唯一会「慢」的操作，而且对不认 --appimage-extract 的
         * 运行时会一直卡住。默认走手工填写、不自动提取；这里给愿意用
         * 它的人两个旋钮。
         */
        flow.pack_start (section_title ("元数据提取"), false, false, 0);

        var sw_autoextract = mk_switch (
            "创建启动器时自动尝试提取内置元数据", cfg.auto_extract_on_create ());
        sw_autoextract.get_style_context ().add_class ("settings-row");
        flow.pack_start (sw_autoextract, false, false, 0);

        var ext_note = mk_label ("默认关闭。开启后每次创建都会先解包，较慢；"
                                 + "关掉的话可以在创建对话框里手动点「尝试提取内置元数据」。");
        ext_note.get_style_context ().add_class ("settings-note");
        ext_note.set_line_wrap (true);
        flow.pack_start (ext_note, false, false, 0);

        var timeout_spin = new Gtk.SpinButton.with_range (5, 600, 5);
        timeout_spin.value = cfg.extract_timeout ();
        timeout_spin.numeric = true;
        flow.pack_start (labelled ("解包超时（秒）", timeout_spin), false, false, 0);

        var timeout_note = mk_label ("实测一个 555 MB 的 AppImage 解包超过 20 秒。"
                                     + "超时会强制终止并清理，界面不会卡住。");
        timeout_note.get_style_context ().add_class ("settings-note");
        timeout_note.set_line_wrap (true);
        flow.pack_start (timeout_note, false, false, 0);

        flow.pack_start (section_title ("备份"), false, false, 0);
        var sw_backup = mk_switch ("启用备份（修复前自动存档）", cfg.backup_enabled ());
        flow.pack_start (sw_backup, false, false, 0);

        var days = new Gtk.SpinButton.with_range (1, 3650, 1);
        days.value = cfg.retention_days ();
        days.numeric = true;
        flow.pack_start (labelled ("备份保留天数", days), false, false, 0);

        var txs = new Gtk.SpinButton.with_range (10, 10000, 10);
        txs.value = cfg.retention_tx ();
        txs.numeric = true;
        flow.pack_start (labelled ("保留事务数", txs), false, false, 0);

        flow.pack_start (section_title ("批量失败策略"), false, false, 0);
        var policy = new Gtk.ComboBoxText ();
        policy.append ("0", "回滚全部并中止");
        policy.append ("1", "跳过失败项继续");
        policy.active_id = cfg.rollback_on_failure () ? "0" : "1";
        flow.pack_start (labelled ("当某项失败时", policy), false, false, 0);

        flow.pack_start (section_title ("路径"), false, false, 0);
        string apps_dir = AppPath.applications_dir ();
        var path_lab = mk_label (GLib.Path.get_dirname (apps_dir));
        path_lab.get_style_context ().add_class ("dim-label");
        path_lab.set_line_wrap (true);
        flow.pack_start (labelled ("applications 目录位于", path_lab), false, false, 0);
        var path_lab2 = mk_label (apps_dir);
        path_lab2.set_line_wrap (true);
        flow.pack_start (labelled ("实际写入位置", path_lab2), false, false, 0);

        int RESP_SAVE = 9006;
        var save_btn = add_button (dlg, "保存", RESP_SAVE);
        if (save_btn != null)
            save_btn.get_style_context ().add_class ("suggested-action");
        add_button (dlg, "取消", Gtk.ResponseType.CANCEL);
        dlg.set_default_response (RESP_SAVE);

        dlg.show_all ();
        int resp = dlg.run ();
        dlg.destroy ();

        if (resp != RESP_SAVE)
            return false;

        int new_size = cur_size;
        for (int i = 0; i < sizes.length; i++)
            if (size_radios[i].active) new_size = sizes[i];

        cfg.set_int  ("general", "icon_size", new_size);
        cfg.set_bool ("scan", "recursive", sw_recursive.active);
        cfg.set_bool ("scan", "auto_on_startup", sw_autostart.active);
        cfg.set_bool ("sync", "update_desktop_database", sw_udb.active);
        cfg.set_bool ("sync", "update_icon_cache", sw_uic.active);
        cfg.set_bool ("sync", "write_managed_marker", sw_marker.active);
        cfg.set_bool ("sync", "delete_icon_with_launcher", sw_del_icon.active);
        cfg.set_bool ("extract", "auto_on_create", sw_autoextract.active);
        cfg.set_int  ("extract", "timeout_sec", (int) timeout_spin.value);
        cfg.set_bool ("backup", "enabled", sw_backup.active);
        cfg.set_int  ("backup", "retention_days", (int) days.value);
        cfg.set_int  ("backup", "retention_tx", (int) txs.value);
        cfg.set_int  ("repair", "batch_failure_policy",
                      policy.active_id == "1" ? 1 : 0);
        cfg.save ();

        return true;
    }

    private Gtk.Label section_title (string text) {
        var l = new Gtk.Label (null);
        l.use_markup = true;
        l.xalign = 0.0f;
        l.label = "<b>%s</b>".printf (GLib.Markup.escape_text (text, -1));
        l.set_margin_top (4);
        return l;
    }

    private Gtk.CheckButton mk_switch (string text, bool active) {
        var cb = new Gtk.CheckButton ();
        cb.active = active;
        var sw = new Gtk.Switch ();
        sw.active = active;
        sw.halign = Gtk.Align.END;
        sw.valign = Gtk.Align.CENTER;
        cb.add (sw);
        cb.label = text;
        cb.show_all ();
        return cb;
    }

    private Gtk.Box labelled (string text, Gtk.Widget w) {
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
        var l = mk_label (text);
        l.set_size_request (190, -1);
        box.pack_start (l, false, false, 0);
        w.vexpand = false;
        box.pack_start (w, true, true, 0);
        return box;
    }

    /* ══════════════════════════════════════════════════════════════
     *  7. 历史
     * ══════════════════════════════════════════════════════════════ */

    public bool history (Gtk.Window parent, AppConfig cfg) {
        var dlg = new_dialog (parent, "操作历史", 860, 560);
        Gtk.Box content = dlg.get_content_area ();
        content.set_border_width (12);
        content.set_spacing (10);

        var store = new Gtk.ListStore (6, typeof (string), typeof (string),
            typeof (string), typeof (string), typeof (int), typeof (int));
        var tree = new Gtk.TreeView ();
        tree.set_model (store);

        add_col (tree, "时间", 0, true);
        add_col (tree, "操作", 1, false);
        add_col (tree, "状态", 2, false);
        add_col (tree, "文件数", 3, false);
        add_col (tree, "已完成", 4, false);

        Gtk.TreeSelection? sel = tree.get_selection ();
        Gtk.Box btn_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);

        var view_btn = new Gtk.Button.with_label ("查看");
        var undo_btn = new Gtk.Button.with_label ("还原");
        undo_btn.get_style_context ().add_class ("destructive-action");
        btn_box.pack_start (view_btn, false, false, 0);
        btn_box.pack_start (undo_btn, false, false, 0);

        void refresh_list () {
            store.clear ();
            var entries = new GenericArray<Backup.HistoryEntry> ();
            foreach (var h in Backup.list_history ())
                entries.add (h);
            entries.sort ((a, b) => strcmp (b.txid, a.txid));   // 最新在前

            foreach (var h in entries) {
                Gtk.TreeIter it;
                store.append (out it);
                store.set_value (it, 0, h.display_time ());
                store.set_value (it, 1, h.display_op () + "（" + h.mode + "）");
                store.set_value (it, 2, h.status);
                store.set_value (it, 3, "%d".printf (h.total));
                store.set_value (it, 4, "%d".printf (h.done));
            }
        }

        string selected_txid () {
            if (sel == null)
                return "";
            Gtk.TreeModel model;
            Gtk.TreeIter iter;
            if (!sel.get_selected (out model, out iter))
                return "";
            GLib.Value v;
            model.get_value (iter, 0, out v);
            // 第 0 列存的是时间，另存 txid 到 model 之外不可行，
            // 因此时间列同时承载 txid（格式化后仍以时间开头，可反查）
            return v.get_string ();
        }

        // 第 6 列放 txid 原值
        var hidden = new Gtk.ListStore (7, typeof (string), typeof (string),
            typeof (string), typeof (string), typeof (int), typeof (int), typeof (string));
        tree.set_model (hidden);

        void refresh_list2 () {
            hidden.clear ();
            var entries = new GenericArray<Backup.HistoryEntry> ();
            foreach (var h in Backup.list_history ())
                entries.add (h);
            entries.sort ((a, b) => strcmp (b.txid, a.txid));

            foreach (var h in entries) {
                Gtk.TreeIter it;
                hidden.append (out it);
                hidden.set_value (it, 0, h.display_time ());
                hidden.set_value (it, 1, h.display_op () + "（" + h.mode + "）");
                hidden.set_value (it, 2, h.status);
                hidden.set_value (it, 3, "%d".printf (h.total));
                hidden.set_value (it, 4, "%d".printf (h.done));
                hidden.set_value (it, 5, h.txid);
            }
        }

        string current_txid () {
            if (sel == null)
                return "";
            Gtk.TreeModel model;
            Gtk.TreeIter iter;
            if (!sel.get_selected (out model, out iter))
                return "";
            GLib.Value v;
            model.get_value (iter, 5, out v);
            return v.get_string ();
        }

        view_btn.clicked.connect (() => {
            string txid = current_txid ();
            if (txid == "") {
                info (dlg, "未选中", "请先选中一条历史记录。", Gtk.MessageType.INFO);
                return;
            }
            show_tx_detail (dlg, txid);
        });

        undo_btn.clicked.connect (() => {
            string txid = current_txid ();
            if (txid == "") {
                info (dlg, "未选中", "请先选中一条历史记录。", Gtk.MessageType.INFO);
                return;
            }
            var tx = Backup.load_tx (txid);
            if (tx == null) {
                info (dlg, "读取失败", "无法读取事务 %s 的 manifest。".printf (txid), Gtk.MessageType.ERROR);
                return;
            }

            string sample = tx.items.length > 0
                ? GLib.Path.get_basename (tx.items[0].orig_path) : txid;
            var policy = ask_conflict_policy (dlg, sample);

            if (policy < 0) {
                info (dlg, "已取消", "未执行还原。", Gtk.MessageType.INFO);
                return;
            }

            var res = Backup.restore (tx, (Backup.ConflictPolicy) policy);
            string body = "已还原 %d 项".printf (res.restored);
            if (res.skipped > 0)  body += "\n跳过 %d 项".printf (res.skipped);
            if (res.failed > 0)  body += "\n失败 %d 项".printf (res.failed);
            if (res.messages != null && res.messages.length > 0) {
                var sb = new GLib.StringBuilder ();
                sb.append (body).append ("\n\n");
                foreach (string m in res.messages)
                    sb.append ("• ").append (m).append ("\n");
                body = sb.str;
            }
            DesktopFiles.refresh_menu (cfg.should_update_database ());
            refresh_list2 ();
            info (dlg, "还原完成", body,
                res.failed > 0 ? Gtk.MessageType.WARNING : Gtk.MessageType.INFO);
        });

        refresh_list2 ();

        var sw = mk_scrolled (tree, 320);
        content.pack_start (sw, true, true, 0);

        var bottom = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        var prune_btn = new Gtk.Button.with_label ("清理旧备份");
        bottom.pack_start (prune_btn, false, false, 0);
        bottom.pack_end (btn_box, false, false, 0);
        content.pack_start (bottom, false, false, 0);

        prune_btn.clicked.connect (() => {
            if (!confirm (dlg, "清理旧备份",
                    "将删除超过 %d 天或超出最近 %d 个事务的备份目录。\n未还原的事务不会被删除。\n\n继续？".printf (
                        cfg.retention_days (), cfg.retention_tx ()))) {
                return;
            }
            int n = Journal.apply_retention (cfg);
            refresh_list2 ();
            info (dlg, "清理旧备份",
                n == 0 ? "没有需要清理的备份。" : "已移除 %d 个事务目录。".printf (n),
                Gtk.MessageType.INFO);
        });

        add_button (dlg, "关闭", Gtk.ResponseType.CLOSE);
        dlg.show_all ();
        dlg.run ();
        dlg.destroy ();
        return true;
    }

    private void add_col (Gtk.TreeView tree, string title, int col, bool expand) {
        var r = new Gtk.CellRendererText ();
        var c = new Gtk.TreeViewColumn ();
        c.title = title;
        c.pack_start (r, true);
        c.add_attribute (r, "text", col);
        if (expand)
            c.set_expand (true);
        else
            c.set_resizable (true);
        tree.append_column (c);
    }

    /** 事务详情：列出每个文件与命中的规则 */
    private void show_tx_detail (Gtk.Window parent, string txid) {
        var tx = Backup.load_tx (txid);
        var det = new_dialog (parent, "事务详情", 760, 520);
        Gtk.Box content = det.get_content_area ();
        content.set_border_width (12);
        content.set_spacing (10);

        if (tx == null) {
            content.pack_start (mk_label ("无法读取事务 " + txid), false, false, 0);
            add_button (det, "关闭", Gtk.ResponseType.CLOSE);
            det.show_all ();
            det.run ();
            det.destroy ();
            return;
        }

        var head = new Gtk.Label (null);
        head.use_markup = true;
        head.xalign = 0.0f;
        head.label = "<b>%s</b> · %s · %s\n<span size='small'>%s</span>".printf (
            GLib.Markup.escape_text (txid, -1),
            GLib.Markup.escape_text (tx.operation, -1),
            GLib.Markup.escape_text (tx.status, -1),
            GLib.Markup.escape_text (tx.started_at, -1));
        content.pack_start (head, false, false, 0);

        var scroll = new Gtk.ScrolledWindow (null, null);
        scroll.set_policy (Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC);
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        box.set_border_width (4);

        foreach (var it in tx.items) {
            var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
            var name = new Gtk.Label (null);
            name.use_markup = true;
            name.xalign = 0.0f;
            name.label = "<b>%s</b>  <span foreground='#7f8c8d'>%s</span>".printf (
                GLib.Markup.escape_text (GLib.Path.get_basename (it.orig_path), -1),
                GLib.Markup.escape_text (it.status, -1));
            card.pack_start (name, false, false, 0);

            var path_l = mk_label (it.orig_path);
            path_l.get_style_context ().add_class ("dim-label");
            path_l.set_margin_start (12);
            card.pack_start (path_l, false, false, 0);

            if (it.new_path != it.orig_path) {
                var np = mk_label ("→ " + it.new_path);
                np.get_style_context ().add_class ("dim-label");
                np.set_margin_start (12);
                card.pack_start (np, false, false, 0);
            }

            string acts = (it.actions != null && it.actions.length > 0)
                ? string.joinv (" / ", it.actions) : "（无）";
            string rules = (it.rules_fired != null && it.rules_fired.length > 0)
                ? string.joinv (" ", it.rules_fired) : "（无）";
            var info_l = mk_label ("操作：%s · 命中规则：%s".printf (acts, rules));
            info_l.set_margin_start (12);
            card.pack_start (info_l, false, false, 0);

            if (it.error != "") {
                var err_l = mk_label ("错误：" + it.error);
                err_l.get_style_context ().add_class ("warning");
                err_l.set_margin_start (12);
                card.pack_start (err_l, false, false, 0);
            }

            box.pack_start (card, false, false, 0);
            box.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 0);
        }

        scroll.add (box);
        scroll.vexpand = true;
        content.pack_start (scroll, true, true, 0);

        add_button (det, "关闭", Gtk.ResponseType.CLOSE);
        det.show_all ();
        det.run ();
        det.destroy ();
    }

    /* ══════════════════════════════════════════════════════════════
     *  8. 冲突策略
     * ══════════════════════════════════════════════════════════════ */

    /**
     * 询问还原时的冲突处理策略。
     * @return OVERWRITE / SKIP / STASH；用户取消返回 -1
     */
    public int ask_conflict_policy (Gtk.Window parent, string filename) {
        var dlg = new_dialog (parent, "冲突处理", 520, 340);
        Gtk.Box content = dlg.get_content_area ();
        content.set_border_width (12);
        content.set_spacing (10);

        var head = new Gtk.Label (null);
        head.use_markup = true;
        head.xalign = 0.0f;
        head.set_line_wrap (true);
        head.label = "<b>%s</b> 在本次操作之后被修改过。\n还原备份时会覆盖它，请选择处理方式。".printf (
            GLib.Markup.escape_text (filename, -1));
        content.pack_start (head, false, false, 0);

        var g = new Gtk.RadioButton.with_label (null, "覆盖：直接用备份内容替换");
        var s = new Gtk.RadioButton.with_label_from_widget (g, "跳过：保留现有内容不动");
        var t = new Gtk.RadioButton.with_label_from_widget (g, "另存后覆盖：把现有内容另存为 .modified-时间戳 再还原");
        t.active = true;    // 默认最安全

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        box.pack_start (g, false, false, 0);
        box.pack_start (s, false, false, 0);
        box.pack_start (t, false, false, 0);
        content.pack_start (box, false, false, 0);

        add_button (dlg, "取消", Gtk.ResponseType.CANCEL);
        add_button (dlg, "确定", Gtk.ResponseType.OK);
        dlg.set_default_response (Gtk.ResponseType.OK);

        dlg.show_all ();
        int resp = dlg.run ();
        dlg.destroy ();

        if (resp != Gtk.ResponseType.OK)
            return -1;

        if (g.active) return Backup.ConflictPolicy.OVERWRITE;
        if (s.active) return Backup.ConflictPolicy.SKIP;
        return Backup.ConflictPolicy.STASH;
    }
}