/*
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

    /** 严重度 → 颜色。0 = 由状态文本推断 */
    public string color_for (string status_text, int severity) {
        if (severity == 3) return "#e74c3c";
        if (severity == 2) return "#e5a00d";
        if (severity == 1) return "#3498db";

        if (status_text.has_prefix ("失效"))   return "#e74c3c";
        if (status_text.has_prefix ("损坏"))   return "#e74c3c";
        if (status_text.has_prefix ("可优化")) return "#e5a00d";
        if (status_text.has_prefix ("新发现")) return "#e5a00d";
        if (status_text.has_prefix ("已创建")) return "#2ecc71";
        if (status_text.has_prefix ("外部"))   return "#3498db";
        if (status_text.has_prefix ("健康"))   return "#2ecc71";
        return "#95a5a6";
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
