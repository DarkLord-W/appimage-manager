/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 DarkLord-W
 *
 * prefill.vala — 从 AppImage 文件名推导 .desktop 的预填字段
 *
 * 纯逻辑模块：不做界面、不写文件（唯一例外是 find_local_icon ()，
 * 只做几次 FileUtils.test）。对话框和向导共用这里的规则，
 * 保证「预填」与「预览」两处行为一致。
 */
namespace Prefill {

    /* ── 预填字段模型 ────────────────────────────────────────────── */

    /** 向导 / 编辑对话框里可编辑的字段集合 */
    public class Fields : GLib.Object {
        public string name = "";
        public string exec_line = "";
        public string icon = "";
        public string categories = "";
        public string comment = "";
        public string generic_name = "";
        public string startup_wm_class = "";
        public bool terminal = false;
    }

    /* ── 从路径预填 ──────────────────────────────────────────────── */

    /**
     * 根据 AppImage 路径生成整套预填值。
     *
     * 刻意复用已有工具，避免出现第二套逻辑：
     *   - AppPath.display_name_from_file () 剥版本号 / 架构后缀
     *   - DesktopFiles.build_exec_arg ()    Exec 的引号与转义
     */
    public static Fields from_appimage (string appimage_path) {
        var f = new Fields ();

        f.name = AppPath.display_name_from_file (GLib.Path.get_basename (appimage_path));

        // 与 DesktopFiles.build_content () 的 field_code 参数保持一致
        f.exec_line = DesktopFiles.build_exec_arg (appimage_path) + " %U";

        f.categories = suggest_category (f.name);
        f.startup_wm_class = f.name;

        // 图标故意留空：不扫描图标主题、不猜测相邻文件，由用户在对话框里手动
        // 选择。「猜错图标」比「暂时没有图标」更糟。
        // （find_local_icon 只在用户主动挑选时作为候选查询，不自动套用）
        f.icon = "";

        // comment / generic_name / terminal 留空，交给用户填写
        return f;
    }

    /* ── 分类建议 ────────────────────────────────────────────────── */

    /**
     * 依据名称猜一个主分类。
     *
     * 匹配大小写不敏感，并优先「更完整」的命中：
     *   3 = 完整单词（video player 里的 video）
     *   2 = 词首或词尾（libreoffice 里的 office、vscode 里的 code）
     *   1 = 词中间的普通子串（videolan 里的 ide）
     * 同一优先级时按表序取先出现者，等价于「第一个命中」。
     *
     * 这样 "Video Player" 会命中 AudioVideo，而不是把 video 中间的
     * "ide" 当成 Development（纯子串匹配的经典坑）。
     */
    public static string suggest_category (string name) {
        if (name == null || name == "")
            return "Utility;";

        string normalized = normalize_for_match (name);

        // keyword 与 category 一一对应，两数组长度必须一致（10/7/6/5/3/3/6/4）
        string[] keywords = {
            /* Graphics */
            "krita", "gimp", "inkscape", "draw", "paint",
            "image", "photo", "blender", "cad", "freecad",
            /* Development */
            "code", "vim", "emacs", "git", "ide", "studio", "sublime",
            /* AudioVideo */
            "player", "vlc", "music", "audio", "mpv", "video",
            /* Office */
            "office", "writer", "calc", "doc", "pdf",
            /* Game */
            "game", "steam", "lutris",
            /* System */
            "terminal", "shell", "bash",
            /* Network */
            "browser", "chrome", "firefox", "network", "chat", "mail",
            /* Office（笔记 / 编辑器） */
            "editor", "note", "obsidian", "logseq"
        };
        string[] categories = {
            "Graphics;", "Graphics;", "Graphics;", "Graphics;", "Graphics;",
            "Graphics;", "Graphics;", "Graphics;", "Graphics;", "Graphics;",
            "Development;", "Development;", "Development;", "Development;", "Development;",
            "Development;", "Development;",
            "AudioVideo;", "AudioVideo;", "AudioVideo;", "AudioVideo;", "AudioVideo;", "AudioVideo;",
            "Office;", "Office;", "Office;", "Office;", "Office;",
            "Game;", "Game;", "Game;",
            "System;TerminalEmulator;", "System;TerminalEmulator;", "System;TerminalEmulator;",
            "Network;", "Network;", "Network;", "Network;", "Network;", "Network;",
            "Office;", "Office;", "Office;", "Office;"
        };

        int best_score = 0;
        string best = "";

        for (int i = 0; i < keywords.length && i < categories.length; i++) {
            int score = match_score (normalized, keywords[i]);
            if (score > best_score) {
                best_score = score;
                best = categories[i];
            }
        }

        return best_score == 0 ? "Utility;" : best;
    }

    /**
     * 归一化成「单词之间用空格分隔」的小写串，并在前后各补一个空格，
     * 这样整词匹配就是简单的 contains (" kw ")。
     */
    private static string normalize_for_match (string name) {
        string lower = name.down ();
        var sb = new GLib.StringBuilder ();
        sb.append_c (' ');
        for (int i = 0; i < lower.length; i++) {
            char c = lower[i];
            if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
                sb.append_c (c);
            else
                sb.append_c (' ');
        }
        sb.append_c (' ');
        return sb.str;
    }

    /** 0 = 未命中；1 / 2 / 3 = 由弱到强的匹配度 */
    private static int match_score (string normalized, string keyword) {
        if (normalized.contains (" " + keyword + " "))
            return 3;   // 完整单词
        if (normalized.contains (" " + keyword) || normalized.contains (keyword + " "))
            return 2;   // 词首 / 词尾
        if (normalized.contains (keyword))
            return 1;   // 词中间的普通子串
        return 0;
    }

    /* ── 预览 ────────────────────────────────────────────────────── */

    /**
     * 生成预览用的 .desktop 内容。
     * 直接复用 DesktopFiles.build_content ()，不在别处维护第二套格式。
     */
    public static string build_preview (Fields f, string appimage_path, bool write_marker) {
        return DesktopFiles.build_content (
            appimage_path,
            f.name,
            f.generic_name,
            f.comment,
            f.icon,
            f.categories,
            f.startup_wm_class,
            "",          // MimeType：预填阶段不猜
            write_marker,
            "%U");       // 与 from_appimage () 的 exec_line 一致
    }

    /* ── 分类下拉候选 ────────────────────────────────────────────── */

    /** 对话框里可编辑 ComboBox 的常用分类 */
    public static string[] category_choices () {
        return {
            "Utility;",
            "Graphics;",
            "Development;",
            "AudioVideo;",
            "Office;",
            "Network;",
            "Game;",
            "System;",
            "Graphics;RasterGraphics;",
            "Office;Finance;"
        };
    }

    /* ── 文件名去重 ──────────────────────────────────────────────── */

    /**
     * 生成不冲突的 .desktop 文件名（含后缀）。
     *
     * 先试 slug.desktop，再试 slug-2 … slug-50，
     * 都占用则退回 slug-xxxxxxxx.desktop（路径哈希 8 位十六进制）。
     */
    public static string ensure_unique_slug (string appimage_path, string[] taken_basenames) {
        string slug = AppPath.slugify (GLib.Path.get_basename (appimage_path));

        string candidate = slug + ".desktop";
        if (!basename_taken (taken_basenames, candidate))
            return candidate;

        for (int i = 2; i <= 50; i++) {
            candidate = "%s-%d.desktop".printf (slug, i);
            if (!basename_taken (taken_basenames, candidate))
                return candidate;
        }

        string digest = "%08x".printf (appimage_path.hash ());
        return "%s-%s.desktop".printf (slug, digest);
    }

    /**
     * 判重必须大小写不敏感。
     *
     * desktop entry 的文件名在 freedesktop 规范里是大小写敏感的，但启动器
     * 目录未必落在大小写敏感的文件系统上 —— NTFS/exFAT 挂载、macOS 共享、
     * Samba 共享下 KRITA.DESKTOP 和 krita.desktop 就是同一个文件。大小写
     * 敏感地判重会漏判，然后 write_atomic 直接把用户已有的启动器覆盖掉，
     * 而那是不可逆的破坏。所以宁可多算一次撞名，也绝不覆盖。
     */
    private static bool basename_taken (string[] taken, string candidate) {
        if (taken == null)
            return false;
        string c = candidate.down ();
        foreach (string t in taken) {
            if (t.down () == c)
                return true;
        }
        return false;
    }

    /* ── 可选：相邻图标查找 ──────────────────────────────────────── */

    /**
     * 在 AppImage 同目录查找同名图标（.png/.svg/...），找到返回绝对路径。
     *
     * 只做 FileUtils.test，不扫描主题。from_appimage () 不会调用它；
     * 这是给「用户手动挑选图标」场景准备的候选查询。
     */
    public static string? find_local_icon (string appimage_path) {
        if (appimage_path == null || appimage_path == "")
            return null;

        string dir = GLib.Path.get_dirname (appimage_path);
        string stem = AppPath.strip_known_extensions (GLib.Path.get_basename (appimage_path));
        if (stem == "")
            return null;

        string[] exts = { ".png", ".svg", ".svgz", ".xpm", ".jpg", ".jpeg", ".ico" };
        foreach (string ext in exts) {
            string p = GLib.Path.build_filename (dir, stem + ext);
            if (GLib.FileUtils.test (p, GLib.FileTest.EXISTS))
                return p;
        }
        return null;
    }
}
