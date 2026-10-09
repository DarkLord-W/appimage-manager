/*
 * selftest.vala — 核心引擎自测程序（不依赖 GUI）
 *
 * 直接驱动 scanner / desktopfiles / rules / repair，
 * 用 tests/make-fixtures.sh 生成的数据验证真实行为。
 *
 * 编译：make selftest
 * 运行：./appimage-manager-selftest [沙箱目录]
 */
public int main (string[] args) {
    string sandbox = args.length > 1 ? args[1] : "/tmp/appmgr-fixtures";

    string apps_dir = GLib.Path.build_filename (sandbox, "apps");
    string desktops_dir = GLib.Path.build_filename (sandbox, "desktops");

    if (!AppPath.is_dir (apps_dir)) {
        stderr.printf ("找不到夹具目录 %s\n", apps_dir);
        stderr.printf ("请先运行 tests/make-fixtures.sh\n");
        return 2;
    }

    int failures = 0;
    int checks = 0;

    stdout.printf ("\n══════════ AppImage Manager 核心自测 ══════════\n");
    stdout.printf ("沙箱: %s\n\n", sandbox);

    /* ══ 1. 扫描器：魔数校验 ══════════════════════════════════════ */
    stdout.printf ("── 1. 扫描器 ─────────────────────────────\n");
    var res = Scanner.scan ({ apps_dir }, true);

    check (ref checks, ref failures, "递归找到 11 个真 AppImage",
           res.found.length == 11, "实际 %d".printf (res.found.length));

    check (ref checks, ref failures, "剔除 2 个假货",
           res.rejected.length == 2, "实际 %d".printf (res.rejected.length));

    bool has_nested = false;
    bool has_uppercase = false;
    foreach (string p in res.found) {
        if (p.contains ("nested/DeepTool"))
            has_nested = true;
        if (p.contains ("Uppercase.APPIMAGE"))
            has_uppercase = true;
    }
    check (ref checks, ref failures, "递归进入了二级子目录", has_nested, "");
    check (ref checks, ref failures, "扩展名大小写不敏感", has_uppercase, "");

    /* ══ 2. slug 生成 ═════════════════════════════════════════════ */
    stdout.printf ("\n── 2. slug 与名称提取 ────────────────────\n");

    expect_str (ref checks, ref failures, "slug: 版本号保留",
        AppPath.slugify ("Obsidian-1.5.3-x86_64.AppImage"),
        "obsidian-1.5.3-x86_64");

    expect_str (ref checks, ref failures, "slug: 空格转连字符",
        AppPath.slugify ("Media Player 2.0.AppImage"),
        "media-player-2.0");

    expect_str (ref checks, ref failures, "slug: 括号被替换",
        AppPath.slugify ("Foo(Bar) 1.0.AppImage"),
        "foo-bar-1.0");

    expect_str (ref checks, ref failures, "slug: % 被替换",
        AppPath.slugify ("100% Pure.AppImage"),
        "100-pure");

    // 下划线在文件名里合法且可读，slug 予以保留（不转成连字符）
    expect_str (ref checks, ref failures, "slug: 保留下划线",
        AppPath.slugify ("GNU_Octave-9.1.0.AppImage"),
        "gnu_octave-9.1.0");

    expect_str (ref checks, ref failures, "slug: 连续分隔符被折叠",
        AppPath.slugify ("a---b___c.AppImage"),
        "a-b_c");

    expect_str (ref checks, ref failures, "显示名: 去掉版本与架构",
        AppPath.display_name_from_file ("Obsidian-1.5.3-x86_64.AppImage"),
        "Obsidian");

    expect_str (ref checks, ref failures, "显示名: 保留下划线内的词",
        AppPath.display_name_from_file ("GNU_Octave-9.1.0.AppImage"),
        "GNU_Octave");

    /* ══ 3. Exec 转义 ═════════════════════════════════════════════ */
    stdout.printf ("\n── 3. Exec 字段转义 ──────────────────────\n");

    expect_str (ref checks, ref failures, "转义: 空格加引号",
        DesktopFiles.build_exec_arg ("/tmp/Media Player 2.0.AppImage"),
        "\"/tmp/Media Player 2.0.AppImage\"");

    expect_str (ref checks, ref failures, "转义: % 写成 %%",
        DesktopFiles.build_exec_arg ("/tmp/100% Pure.AppImage"),
        "\"/tmp/100%% Pure.AppImage\"");

    expect_str (ref checks, ref failures, "转义: 反斜杠双写",
        DesktopFiles.build_exec_arg ("/tmp/a\\b.AppImage"),
        "\"/tmp/a\\\\b.AppImage\"");

    expect_str (ref checks, ref failures, "转义: $ 加反斜杠",
        DesktopFiles.build_exec_arg ("/tmp/$HOME.AppImage"),
        "\"/tmp/\\$HOME.AppImage\"");

    /* ── Exec 解析往返 ─────────────────────────────────────────── */
    string arg = DesktopFiles.build_exec_arg ("/tmp/Media Player 2.0.AppImage") + " %U";
    string? parsed = DesktopFiles.extract_exec_path (arg);
    check (ref checks, ref failures, "解析: 从带引号的 Exec 还原路径",
           parsed == "/tmp/Media Player 2.0.AppImage",
           parsed ?? "(null)");

    string? pct_parsed = DesktopFiles.extract_exec_path (
        DesktopFiles.build_exec_arg ("/tmp/100% Pure.AppImage") + " %U");
    check (ref checks, ref failures, "解析: 字面 %% 还原成 %",
           pct_parsed == "/tmp/100% Pure.AppImage",
           pct_parsed ?? "(null)");

    check (ref checks, ref failures, "包装脚本识别",
           DesktopFiles.exec_is_wrapper ("sh -c \"/tmp/x.AppImage\""), "");

    check (ref checks, ref failures, "非包装脚本不误判",
           !DesktopFiles.exec_is_wrapper ("/tmp/x.AppImage %U"), "");

    /* ══ 4. 规则引擎 ══════════════════════════════════════════════ */
    stdout.printf ("\n── 4. 规则引擎 ───────────────────────────\n");

    var entries = DesktopFiles.scan_directory (desktops_dir);
    check (ref checks, ref failures, "解析出 21 个 .desktop",
           entries.length == 21, "实际 %d".printf (entries.length));

    // 逐条验证「哪个文件应该命中哪些规则」。
    // Vala 不支持嵌套的匿名数组初始化，所以用「文件 → 期望的规则 id 列表」
    // 这种扁平写法：matches 里给出必须命中的，forbids 里给出必须不命中的。
    var matches = new GLib.HashTable<string, string> (GLib.str_hash, GLib.str_equal);
    var forbids = new GLib.HashTable<string, string> (GLib.str_hash, GLib.str_equal);

    matches.insert ("no-group.desktop",          "D001");
    matches.insert ("bom.desktop",               "D002");
    matches.insert ("crlf.desktop",              "D003");
    matches.insert ("bad-type.desktop",          "D005");
    matches.insert ("bad-version.desktop",       "E001");
    matches.insert ("exec-unquoted.desktop",     "E004");
    matches.insert ("exec-missing.desktop",      "E003");
    matches.insert ("exec-wrapper.desktop",      "E006");
    matches.insert ("exec-percent.desktop",      "E005");
    matches.insert ("no-name.desktop",           "E007");
    matches.insert ("dup-keys.desktop",          "E008");
    matches.insert ("dangling-actions.desktop",  "E009");
    matches.insert ("icon-missing.desktop",      "I001");
    matches.insert ("terminal-true.desktop",     "I005");
    matches.insert ("hidden-true.desktop",       "I006");
    matches.insert ("broken.desktop",            "E003");
    matches.insert ("external.desktop",          "C004");
    matches.insert ("This Is A Messy Name.desktop", "I008");
    
    // perfect.desktop 不该命中任何「坏」规则
    forbids.insert ("perfect.desktop",
        "D001,D002,D003,D005,E001,E003,E004,E005,E006,E007,E008,E009,I008");

    var dummy_app = new AppEntry (GLib.Path.build_filename (apps_dir,
        "Obsidian-1.5.3-x86_64.AppImage"));

    // 遍历所有夹具文件，逐条比对
    foreach (var e in entries) {
        if (!matches.contains (e.basename))
            continue;

        var rs = RuleSet.check (e, dummy_app);
        var ids = new GenericArray<string> ();
        foreach (var p in rs.problems)
            ids.add (p.id);

        string want = matches.lookup (e.basename);
        check (ref checks, ref failures,
               "%s 应命中 %s".printf (e.basename, want),
               has_str (ids, want),
               "实际命中: [%s]".printf (join (ids)));

        if (forbids.contains (e.basename)) {
            foreach (string bad in forbids.lookup (e.basename).split (",")) {
                string b = bad.strip ();
                if (b == "")
                    continue;
                check (ref checks, ref failures,
                       "%s 不应命中 %s".printf (e.basename, b),
                       !has_str (ids, b),
                       "实际命中: [%s]".printf (join (ids)));
            }
        }
    }

    /* ── Perfect 条目应当是干净的 ─────────────────────────────── */
    var perfect = find_entry (entries, "perfect.desktop");
    if (perfect != null) {
        var rs = RuleSet.check (perfect, dummy_app);
        var ids = new GenericArray<string> ();
        foreach (var p in rs.problems)
            ids.add (p.id);

        // perfect.desktop 的 Icon 指向夹具里真实存在的文件，
        // 所以 I001 不该命中
        check (ref checks, ref failures, "perfect.desktop 不报 I001",
               !has_str (ids, "I001"), "实际命中: [%s]".printf (join (ids)));


    }

    /* ── Desktop Action 组必须被保留 ───────────────────────────── */
    var with_actions = find_entry (entries, "with-actions.desktop");
    if (with_actions != null) {
        check (ref checks, ref failures,
               "with-actions.desktop 解析出 Action 组",
               with_actions.has_group_named ("Desktop Action NewWindow"), "");
    }

    /* ══ 5. 字节级体检 ════════════════════════════════════════════ */
    stdout.printf ("\n── 5. 字节级体检（BOM / CRLF）─────────────\n");

    string bom_path = GLib.Path.build_filename (desktops_dir, "bom.desktop");
    var br = RuleSet.byte_inspect (bom_path);
    check (ref checks, ref failures, "检出 BOM", br.has_bom, "");

    string crlf_path = GLib.Path.build_filename (desktops_dir, "crlf.desktop");
    br = RuleSet.byte_inspect (crlf_path);
    check (ref checks, ref failures, "检出 CRLF", br.has_crlf, "");

    string ver_path = GLib.Path.build_filename (desktops_dir, "bad-version.desktop");
    br = RuleSet.byte_inspect (ver_path);
    check (ref checks, ref failures, "检出 Version 超范围", br.bad_version,
           "值=%s".printf (br.version_raw));

    /* ══ 6. 修复生成与 diff ══════════════════════════════════════ */
    stdout.printf ("\n── 6. 修复生成 ───────────────────────────\n");

    if (bom_path != "" && AppPath.exists (bom_path)) {
        var e = find_entry (entries, "bom.desktop");
        if (e != null) {
            var plan = new RepairPlan (dummy_app, e);
            plan.problems = RuleSet.check (e, dummy_app).problems;
            plan.selected = new bool[plan.problems.length];
            for (int i = 0; i < plan.selected.length; i++)
                plan.selected[i] = true;

            string proposed = Repair.build_repaired (plan);
            check (ref checks, ref failures,
                   "修复后内容不含 BOM",
                   !proposed.has_prefix ("\ufeff"), "");
            check (ref checks, ref failures,
                   "修复后以 [Desktop Entry] 开头",
                   proposed.has_prefix ("[Desktop Entry]"), "");

            string d = Repair.diff (plan.original_content, proposed);
            check (ref checks, ref failures, "diff 非空", d != "", "");
        }
    }

    /* ── 保守修复必须原样保留 Desktop Action 组与自定义键 ──────── */
    if (with_actions != null) {
        var plan = new RepairPlan (dummy_app, with_actions);
        plan.problems = RuleSet.check (with_actions, dummy_app).problems;
        plan.selected = new bool[plan.problems.length];
        plan.mode = FixMode.CONSERVATIVE;
        string proposed = Repair.build_repaired (plan);
        check (ref checks, ref failures,
               "保守修复保留 [Desktop Action NewWindow]",
               proposed.contains ("[Desktop Action NewWindow]"), "");
        check (ref checks, ref failures,
               "保守修复保留自定义 X- 键",
               proposed.contains ("X-Custom-User-Key"), "");
    }

    /* ══ 7. 名称唯一性 ════════════════════════════════════════════ */
    stdout.printf ("\n── 7. 文件名去重 ─────────────────────────\n");

    string uniq = DesktopFiles.unique_desktop_name (
        "krita", DesktopFiles.scan_directory (desktops_dir), "");
    check (ref checks, ref failures, "无冲突时保持原名",
           uniq == "krita.desktop", uniq);

    /* ══ 汇总 ════════════════════════════════════════════════════ */
    stdout.printf ("\n═══════════════════════════════════════════\n");
    if (failures == 0) {
        stdout.printf ("✓ 全部通过（%d 项检查）\n\n", checks);
        return 0;
    }
    stdout.printf ("✗ %d / %d 项检查失败\n\n", failures, checks);
    return 1;
}

/* ── 测试辅助 ──────────────────────────────────────────────────── */

void check (ref int checks, ref int failures, string name, bool ok, string detail) {
    checks++;
    if (ok) {
        stdout.printf ("  ✓ %s\n", name);
    } else {
        failures++;
        stdout.printf ("  ✗ %s%s\n", name,
            detail == "" ? "" : "  —— " + detail);
    }
}

void expect_str (ref int checks, ref int failures,
                 string name, string actual, string expected) {
    checks++;
    if (actual == expected) {
        stdout.printf ("  ✓ %s\n", name);
    } else {
        failures++;
        stdout.printf ("  ✗ %s\n", name);
        stdout.printf ("      期望: %s\n", expected);
        stdout.printf ("      实际: %s\n", actual);
    }
}

DesktopFiles.Entry? find_entry (DesktopFiles.Entry[] list, string basename) {
    foreach (var e in list)
        if (e.basename == basename)
            return e;
    return null;
}

string join (GenericArray<string> a) {
    var parts = new GenericArray<string> ();
    for (uint i = 0; i < a.length; i++)
        parts.add (get_str (a, i));
    return string.joinv (", ", parts.steal ());
}

/** GenericArray 在这套 vapi 里没有 contains，线性查找 */
bool has_str (GenericArray<string> a, string want) {
    for (uint i = 0; i < a.length; i++)
        if (get_str (a, i) == want)
            return true;
    return false;
}

/** GenericArray 在这套 vapi 里没有 get/index，用 data 字段直接访问 */
unowned string get_str (GenericArray<string> a, uint i) {
    unowned string[] raw = (string[]) a.data;
    return raw[i];
}
