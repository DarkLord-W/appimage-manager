/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 DarkLord-W
 *
 * pill.vala — 状态药丸渲染器
 *
 * 两种实现并存，窗格按需选用：
 *
 *   PillPainter  —— 把药丸画成 Gdk.Pixbuf，配 Gtk.CellRendererPixbuf 使用。
 *                   这是主用方案：不依赖渲染器自己的 style context，
 *                   跨主题表现稳定，也不需要 Pango 手动排版。
 *
 *   PillRenderer —— Gtk.CellRendererText 子类，靠 CSS 类上色。
 *                   备用方案，样式全在 data/style.css 里。
 */
namespace PillPainter {

    /*
     * 状态色：亮背景和暗背景各一套。
     *
     * 原来的五个色是照暗背景挑的，换到亮背景上实测全都不合格：
     *
     *             亮背景(#f6f5f4)   暗背景(#282a33)
     *   可优化        2.06:1 ✗         6.37:1 ✓
     *   已创建        1.93:1 ✗         6.80:1 ✓
     *   外部          2.90:1 ✗         4.53:1 ✓
     *
     * 也就是说药丸在任何亮色主题下都看不清。而用哪个主题是系统决定的，
     * 不能赌用户用暗色，所以每个状态给两套色，运行时按背景亮度挑。
     *
     * 取值全部按 WCAG 正文标准（≥4.5:1）验过，覆盖三种典型背景：
     *   亮：#ffffff / #f6f5f4 / #e8e8e8
     *   暗：#282a33 / #1e1e24 / #2b2b2b
     *
     * 暗色里有两个提亮了一档，都是因为原值在最暗的背景上不过线：
     *   红 #e74c3c → #f26452   3.71:1 → 4.53:1
     *   蓝 #3498db → #3d9ee3   4.49:1 → 4.85:1
     * 都取了同色相里最接近的取值，肉眼几乎看不出区别。
     * 其余三个（琥珀、绿、灰）原样保留。
     */
    private const string DANGER_DARK    = "#f26452";
    private const string WARNING_DARK   = "#e5a00d";
    private const string SUCCESS_DARK   = "#2ecc71";
    private const string INFO_DARK      = "#3d9ee3";
    private const string MUTED_DARK     = "#95a5a6";

    private const string DANGER_LIGHT   = "#b03a2e";
    private const string WARNING_LIGHT  = "#8a6100";
    private const string SUCCESS_LIGHT  = "#17703c";
    private const string INFO_LIGHT     = "#1565a0";
    private const string MUTED_LIGHT    = "#4e5863";

    /** 主题背景是不是亮的。null = 还没探过 */
    private static int? light_bg = null;

    private static double to_linear (double v) {
        return v <= 0.03928 ? v / 12.92 : Math.pow ((v + 0.055) / 1.055, 2.4);
    }

    private static double luminance (Gdk.RGBA c) {
        return 0.2126 * to_linear (c.red)
             + 0.7152 * to_linear (c.green)
             + 0.0722 * to_linear (c.blue);
    }

    /**
     * 探一次主题背景亮度。
     *
     * 读的是主题 CSS 里的 @theme_bg_color —— 几乎所有 GTK 主题都会定义它，
     * 比去看 gtk-theme 的字符串名字可靠得多（名字里带不带 dark 完全靠约定）。
     *
     * 必须传一个**已经实现**的控件：控件还没映射时它的 style context 里
     * 没有主题的颜色。探不到就按暗色处理，也就是退回原来的配色。
     */
    public static void probe_theme (Gtk.Widget w) {
        Gdk.RGBA c = Gdk.RGBA ();
        if (w.get_style_context ().lookup_color ("theme_bg_color", out c)
            && c.alpha > 0.0) {
            light_bg = luminance (c) > 0.5 ? 1 : 0;
        } else {
            light_bg = 0;
        }
    }

    /**
     * 两套配色的全部取值，供自测核对对比度。
     *
     * 返回「名称, 颜色, 是否亮色背景用」三元组，展平成数组。
     */
    public static string[] palette_for_test () {
        return new string[] {
            "danger",  DANGER_DARK,   "dark",
            "warning", WARNING_DARK,  "dark",
            "success", SUCCESS_DARK,  "dark",
            "info",    INFO_DARK,     "dark",
            "muted",   MUTED_DARK,    "dark",
            "danger",  DANGER_LIGHT,  "light",
            "warning", WARNING_LIGHT, "light",
            "success", SUCCESS_LIGHT, "light",
            "info",    INFO_LIGHT,    "light",
            "muted",   MUTED_LIGHT,   "light",
        };
    }

    /** 相对亮度，供自测算对比度 */
    public static double luminance_of (Gdk.RGBA c) {
        return luminance (c);
    }

    /** 解析 #rrggbb，供自测用 */
    public static Gdk.RGBA parse (string hex) {
        Gdk.RGBA c = Gdk.RGBA ();
        c.parse (hex);
        return c;
    }

    /** 供自测与调试查看探测结果 */
    public static bool theme_is_light () { return light_bg == 1; }
    public static bool theme_probed ()   { return light_bg != null; }

    /** 严重度 → 颜色。0 = 由状态文本推断 */
    public string color_for (string status_text, int severity) {
        bool lt = (light_bg == 1);

        if (severity == 3) return lt ? DANGER_LIGHT  : DANGER_DARK;
        if (severity == 2) return lt ? WARNING_LIGHT : WARNING_DARK;
        if (severity == 1) return lt ? INFO_LIGHT    : INFO_DARK;

        if (status_text.has_prefix ("失效"))   return lt ? DANGER_LIGHT  : DANGER_DARK;
        if (status_text.has_prefix ("损坏"))   return lt ? DANGER_LIGHT  : DANGER_DARK;
        if (status_text.has_prefix ("可优化")) return lt ? WARNING_LIGHT : WARNING_DARK;
        if (status_text.has_prefix ("新发现")) return lt ? WARNING_LIGHT : WARNING_DARK;
        if (status_text.has_prefix ("已创建")) return lt ? SUCCESS_LIGHT : SUCCESS_DARK;
        if (status_text.has_prefix ("外部"))   return lt ? INFO_LIGHT    : INFO_DARK;
        if (status_text.has_prefix ("健康"))   return lt ? SUCCESS_LIGHT : SUCCESS_DARK;
        return lt ? MUTED_LIGHT : MUTED_DARK;
    }

    /** 每个字符的近似宽度（Sans 9pt），用于估算药丸宽度 */
    private const double CHAR_W = 7.2;

    /**
     * 画一个药丸。
     *
     * @param text    文字
     * @param color   #rrggbb
     * @param hollow  true = 只描边（「新发现」用）
     * @param height  高度，默认 22
     */
    public static Gdk.Pixbuf render (string text, string color, bool hollow,
                                     int height = 22) {
        double r, g, b;
        parse_hex (color, out r, out g, out b);

        // 宽度估算：内边距 + 圆点 + 间隔 + 文字
        int pad = 8;
        int dot = 7;
        int gap = (text == "") ? 0 : 6;
        int text_w = (int) Math.ceil (text.char_count () * CHAR_W);
        int w = pad + dot + gap + text_w + pad;
        if (w < 24) w = 24;

        var pixbuf = new Gdk.Pixbuf (Gdk.Colorspace.RGB, true, 8, w, height);
        pixbuf.fill (0x00000000);

        // 画到独立的 Cairo surface 上。
        //
        // 不要直接在 pixbuf 的像素缓冲上建 surface：Cairo 的 ARGB32 在小端
        // 机器上按 B,G,R,A 排列，而 GdkPixbuf 期望 R,G,B,A —— 直接共用缓冲
        // 会把红蓝通道互换（琥珀色会变成青色）。
        var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, w, height);
        var cr = new Cairo.Context (surface);
        cr.set_antialias (Cairo.Antialias.BEST);

        // 胶囊背景
        double radius = (height - 2.0) / 2.0;
        rounded_rect (cr, 0.5, 0.5, w - 1.0, height - 1.0, radius);

        if (hollow) {
            cr.set_source_rgba (r, g, b, 0.95);
            cr.set_line_width (1.4);
            cr.stroke_preserve ();
            cr.set_source_rgba (r, g, b, 0.09);
            cr.fill ();
        } else {
            cr.set_source_rgba (r, g, b, 0.19);
            cr.fill_preserve ();
            cr.set_source_rgba (r, g, b, 0.52);
            cr.set_line_width (1.0);
            cr.stroke ();
        }

        // 左侧圆点
        double cx = pad + dot / 2.0;
        double cy = height / 2.0;
        cr.arc (cx, cy, dot / 2.0, 0, 2 * Math.PI);
        cr.set_source_rgba (r, g, b, 1.0);
        cr.fill ();

        // 文字：用 Pango 排版后居中绘制
        var layout = Pango.cairo_create_layout (cr);
        var desc = Pango.FontDescription.from_string ("Sans 8.5");
        layout.set_font_description (desc);
        layout.set_text (text, -1);

        int lw, lh;
        layout.get_pixel_size (out lw, out lh);
        cr.move_to (pad + dot + gap, (height - lh) / 2.0);
        cr.set_source_rgba (r, g, b, 1.0);
        Pango.cairo_show_layout (cr, layout);

        // 从 surface 拷回 pixbuf：这一步会做正确的通道顺序转换
        var out = Gdk.pixbuf_get_from_surface (surface, 0, 0, w, height);
        if (out == null)
            return pixbuf;   // 极端情况下退回空白图，不崩溃
        return out;
    }

    private static void rounded_rect (Cairo.Context cr, double x, double y,
                                      double w, double h, double r) {
        if (r > w / 2.0) r = w / 2.0;
        if (r > h / 2.0) r = h / 2.0;
        cr.new_sub_path ();
        cr.arc (x + w - r, y + r,     r, -Math.PI / 2.0, 0);
        cr.arc (x + w - r, y + h - r, r, 0, Math.PI / 2.0);
        cr.arc (x + r,     y + h - r, r, Math.PI / 2.0, Math.PI);
        cr.arc (x + r,     y + r,     r, Math.PI, 3.0 * Math.PI / 2.0);
        cr.close_path ();
    }

    private static void parse_hex (string hex, out double r, out double g, out double b) {
        r = 0.6; g = 0.6; b = 0.6;
        string s = hex;
        if (s.has_prefix ("#"))
            s = s.substring (1);
        if (s.length < 6)
            return;
        uint val = 0;
        if (!uint.try_parse (s.substring (0, 6), out val, null, 16))
            return;
        r = ((val >> 16) & 0xFF) / 255.0;
        g = ((val >> 8) & 0xFF) / 255.0;
        b = (val & 0xFF) / 255.0;
    }
}

/*
 * PillRenderer —— 备用方案：靠 CSS 上色。
 * 样式定义在 data/style.css 的 .pill-* 系列里。
 */
public class PillRenderer : Gtk.CellRendererText {

    private string current_class = "";
    private int sev_value = 0;

    /** 当前样式类名，供调试与诊断 */
    public string style_class () { return current_class; }

    public PillRenderer () {
        Object (xpad: 6, ypad: 4, xalign: 0.0f, yalign: 0.5f);
    }

    /** 状态文本，绑定到模型的 status 列 */
    public string status_text {
        set {
            this.text = value;
            apply (value, sev_value);
        }
    }

    /** 可选严重度：0=不覆盖 1=信息 2=警告 3=危险 */
    public int severity {
        set {
            sev_value = value;
            apply (this.text ?? "", value);
        }
    }

    private void apply (string text, int sev) {
        string sub;

        if (sev == 3)      sub = "pill-danger";
        else if (sev == 2) sub = "pill-warning";
        else if (sev == 1) sub = "pill-info";
        else if (text.has_prefix ("失效"))   sub = "pill-danger";
        else if (text.has_prefix ("损坏"))   sub = "pill-danger";
        else if (text.has_prefix ("可优化")) sub = "pill-warning";
        else if (text.has_prefix ("新发现")) sub = "pill-hollow";
        else if (text.has_prefix ("已创建")) sub = "pill-success";
        else if (text.has_prefix ("外部"))   sub = "pill-info";
        else if (text.has_prefix ("健康"))   sub = "pill-success";
        else                                 sub = "pill-muted";

        set_classes ("pill " + sub);
    }

    /**
     * 记录样式类名。
     *
     * 注意：Gtk.CellRenderer 没有 get_style_context ()（在 GTK3 里
     * 渲染器不参与 CSS 级联），所以这里只记录、不施加。
     * 需要彩色药丸时请用 PillPainter.render () + CellRendererPixbuf。
     */
    private void set_classes (string classes) {
        current_class = classes;
    }
}
