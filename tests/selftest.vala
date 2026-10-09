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

    /* ══ 8. 状态药丸的通道顺序 ═══════════════════════════════════ */
    stdout.printf ("\n── 8. 状态药丸渲染 ───────────────────────\n");

    // 回归测试：Cairo 的 ARGB32 在小端机上是 BGRA 字节序，而 GdkPixbuf
    // 期望 RGBA。若直接在 pixbuf 的缓冲上建 surface，红蓝通道会互换
    // （琥珀色的「新发现」会渲染成青色）。这里逐通道校验。
    check_pill (ref checks, ref failures, "新发现", 0, "#e5a00d");
    check_pill (ref checks, ref failures, "已创建", 0, "#2ecc71");
    check_pill (ref checks, ref failures, "失效",   0, "#e74c3c");
    check_pill (ref checks, ref failures, "外部",   1, "#3498db");
    check_pill (ref checks, ref failures, "损坏",   3, "#e74c3c");

    /* ══ 9. 端到端：创建启动器 ═══════════════════════════════════
     * 重要：本段会向 AppPath.applications_dir () 写文件。
     * 运行时务必把 XDG_DATA_HOME 指向沙箱，别污染真实家目录。
     * Makefile 的 selftest 目标已经这么做了。
     * ══════════════════════════════════════════════════════════ */
    stdout.printf ("\n── 9. 创建启动器（端到端）────────────────\n");

    string apps_out = AppPath.applications_dir ();
    bool sandboxed = apps_out.has_prefix (sandbox) || apps_out.contains ("appmgr-sandbox");
    check (ref checks, ref failures, "写入目标在沙箱内（防止污染真实家目录）",
           sandboxed, "实际: %s".printf (apps_out));

    if (sandboxed) {
        AppPath.ensure_dir (apps_out);

        // 用带空格和 % 的文件名，顺便验证转义
        string tricky = GLib.Path.build_filename (apps_dir, "100% Pure.AppImage");
        var app = new AppEntry (tricky);
        app.meta_name = "100% Pure";
        app.categories = "Utility;";
        app.comment = "a test app";

        var store = new Store (new AppConfig ());
        var cfg = new AppConfig ();

        var cres = Repair.create_launchers ({ app }, cfg, store);
        check (ref checks, ref failures, "创建返回成功 1 个",
               cres.created == 1, "created=%d failed=%d  %s".printf (
                   cres.created, cres.failed, string.joinv (" / ", cres.messages)));

        // 找到生成的文件
        string? made = null;
        var entries2 = DesktopFiles.scan_directory (apps_out);
        foreach (var e in entries2)
            if (e.exec_target == AppPath.canonical (tricky))
                made = e.file_path;

        check (ref checks, ref failures, "落盘的 .desktop 能被反查匹配到",
               made != null, "在 %s 中未找到指向该 AppImage 的条目".printf (apps_out));

        if (made != null) {
            string content;
            GLib.FileUtils.get_contents (made, out content);

            check (ref checks, ref failures,
                   "生成的条目带 X-AppImage-Manager-Path 标记",
                   content.contains (DesktopFiles.MARKER_PATH), "");
            check (ref checks, ref failures,
                   "Exec 已转义：字面 %% 写成 %%%%",
                   content.contains ("100%% Pure"), "");
            check (ref checks, ref failures,
                   "包含 TryExec",
                   content.contains ("TryExec="), "");
            check (ref checks, ref failures,
                   "包含 StartupNotify",
                   content.contains ("StartupNotify=true"), "");

            string verr = DesktopFiles.validate_content (content);
            check (ref checks, ref failures,
                   "desktop-file-validate 校验通过",
                   verr == "", verr);

            // 幂等性：再创建一次应被跳过
            var res2 = Repair.create_launchers ({ app }, cfg, store);
            check (ref checks, ref failures, "重复创建被跳过",
                   res2.created == 0, "第二次仍创建了 %d 个".printf (res2.created));
        }

        // 事务历史应当有记录
        var hist = Backup.list_history ();
        check (ref checks, ref failures, "事务已写入历史",
               hist.length > 0, "历史为空");
    }

    /* ══ 10. 端到端：修复启动器 ══════════════════════════════════
     * 验证「勾选 = 用户明确要修」的语义：即使处在保守模式，
     * 勾了「缺失字段」类问题也应该真的写进文件。
     * ══════════════════════════════════════════════════════════════ */
    stdout.printf ("\n── 10. 修复启动器（端到端）───────────────\n");

    if (sandboxed) {
        string tricky2 = GLib.Path.build_filename (apps_dir, "Krita-5.2.0-x86_64.AppImage");
        var app2 = new AppEntry (tricky2);
        app2.meta_name = "Krita";
        app2.categories = "Graphics;";
        app2.comment = "digital painting";
        app2.startup_wm_class = "krita";
        app2.generic_name = "Paint Tool";

        var store2 = new Store (new AppConfig ());
        var cfg2 = new AppConfig ();
        var cr = Repair.create_launchers ({ app2 }, cfg2, store2);
        check (ref checks, ref failures, "为修复测试准备好了启动器",
               cr.created == 1 || cr.skipped == 1,
               "created=%d skipped=%d".printf (cr.created, cr.skipped));

        // 重新扫一遍，拿到刚创建的条目
        var found = DesktopFiles.scan_directory (apps_out);
        DesktopFiles.Entry? target = null;
        foreach (var d in found)
            if (d.exec_target == AppPath.canonical (tricky2))
                target = d;

        if (target != null) {
            var rs2 = RuleSet.check (target, app2);
            check (ref checks, ref failures, "新建的条目有可优化项",
                   rs2.problems.length > 0,
                   "问题数 %d".printf (rs2.problems.length));

            // 夹具没有真图标也能提取，所以图标类问题应被标为「不可自动修」，
            // 而不是让用户勾了却什么都不发生。
            check (ref checks, ref failures,
                   "无可用图标时 I001 被标记为不可自动修",
                   !has_applyable (rs2, "I001"),
                   "I001 仍显示为可修，勾了会无效");

            // 人工注入两个「一定能修」的问题，覆盖真正的修复路径
            string raw = "";
            GLib.FileUtils.get_contents (target.file_path, out raw);
            raw = raw.replace ("Version=1.5", "Version=2.0");
            raw = raw.replace ("Terminal=false", "Terminal=true");
            raw += "Hidden=true\n";
            string? werr0;
            DesktopFiles.write_atomic (target.file_path, raw, out werr0);

            var broken = DesktopFiles.parse (target.file_path);
            var rs2b = RuleSet.check (broken, app2);
            check (ref checks, ref failures,
                   "注入后确实检出可修问题",
                   has_problem (rs2b, "E001") && has_problem (rs2b, "I005"),
                   "问题: %s".printf (problem_ids (rs2b)));

            // 模拟用户在对话框里全勾选，模式保持「保守」
            var plan = new RepairPlan (app2, broken);
            plan.problems = rs2b.problems;
            plan.selected = new bool[rs2b.problems.length];
            for (int i = 0; i < plan.selected.length; i++)
                plan.selected[i] = rs2b.problems[i].applyable;
            plan.mode = FixMode.CONSERVATIVE;

            string proposed = Repair.build_repaired (plan);

            stdout.printf ("      命中规则: %s\n", join_strs (plan.rules_fired));

            check (ref checks, ref failures,
                   "保守模式 + 勾选 → 真的改了文件",
                   has_str2 (plan.rules_fired, "E001")
                   && has_str2 (plan.rules_fired, "I005"),
                   "命中: %s".printf (join_strs (plan.rules_fired)));

            // 落盘并复检
            string? werr;
            DesktopFiles.write_atomic (target.file_path, proposed, out werr);
            check (ref checks, ref failures, "修复后的内容写入成功",
                   werr == null, werr ?? "");

            string after = "";
            GLib.FileUtils.get_contents (target.file_path, out after);
            check (ref checks, ref failures,
                   "Version= 被钳回 1.5",
                   after.contains ("Version=1.5"), "");
            check (ref checks, ref failures,
                   "Terminal= 改为 false",
                   after.contains ("Terminal=false") && !after.contains ("Terminal=true"), "");

            string verr2 = DesktopFiles.validate_content (after);
            check (ref checks, ref failures,
                   "修复后的文件通过 desktop-file-validate",
                   verr2 == "", verr2);

            // 再体检一次：这两个问题应该消失
            var reparsed = DesktopFiles.parse (target.file_path);
            if (reparsed != null) {
                var rs3 = RuleSet.check (reparsed, app2);
                check (ref checks, ref failures,
                       "修复后 E001 / I005 都不再报",
                       !has_problem (rs3, "E001") && !has_problem (rs3, "I005"),
                       "仍报: %s".printf (problem_ids (rs3)));
                check (ref checks, ref failures,
                       "修复后问题总数下降",
                       rs3.problems.length < rs2b.problems.length,
                       "修复前 %d → 修复后 %d".printf (
                           rs2b.problems.length, rs3.problems.length));
            }
        } else {
            check (ref checks, ref failures, "找到刚创建的 Krita 条目", false, "");
        }
    }

    /* ══ 11. 子进程：硬超时 + 工作目录 ══════════════════════════
     *
     * 这两条都是实测事故换来的：
     *   - 没有超时 → 不认识 --appimage-extract 的运行时会把参数透传给
     *     真正的应用，spawn_sync 永久阻塞，界面卡死且关不掉
     *   - 没有 set_cwd → 解包内容写进程序启动目录，实测 2.1 GB
     * ══════════════════════════════════════════════════════════════ */
    stdout.printf ("\n── 11. 子进程：超时与工作目录 ─────────────\n");

    // run_process 的超时靠 GLib.Timeout 触发，需要一个跑着的主循环
    var loop = new GLib.MainLoop ();
    var ml_thread = new GLib.Thread<void*> ("mainloop", () => {
        loop.run ();
        return null;
    });

    // ── 超时：sleep 60 应该被 ~2 秒强制终止 ──
    int64 t0 = GLib.get_monotonic_time ();
    bool to_flag = false;
    int rc = AppImageExtract.run_process ({ "/bin/sleep", "60" }, 2, null,
                                          out to_flag, null);
    int64 elapsed_ms = (GLib.get_monotonic_time () - t0) / 1000;

    check (ref checks, ref failures, "超时标志被置起", to_flag,
           "未被判定为超时");
    check (ref checks, ref failures, "超时在 2~6 秒内触发（未等满 60 秒）",
           elapsed_ms >= 1800 && elapsed_ms <= 6000,
           "实测 %lld 毫秒".printf (elapsed_ms));
    check (ref checks, ref failures, "超时后返回失败码", rc != 0,
           "rc=%d".printf (rc));

    // ── 工作目录：子进程必须在指定的 cwd 里干活 ──
    string cwd_test = GLib.Path.build_filename (sandbox, "cwdtest");
    AppPath.ensure_dir (cwd_test);
    string marker = GLib.Path.build_filename (cwd_test, "marker.txt");
    AppPath.file_remove (marker);

    bool to2 = false;
    AppImageExtract.run_process (
        { "/bin/sh", "-c", "touch marker.txt" }, 5, null, out to2, cwd_test);

    check (ref checks, ref failures, "子进程在指定的工作目录里产生了文件",
           AppPath.exists (marker),
           "没在 %s 下找到 marker.txt".printf (cwd_test));

    // CWD 里不该出现（这正是 2.1 GB 事故的形态）
    string stray = "squashfs-root";
    check (ref checks, ref failures, "项目目录里没有解包残留",
           !AppPath.is_dir (stray),
           "存在 %s —— 说明工作目录没设对".printf (stray));

    loop.quit ();

    /* ══ 12. 过滤判定（纯函数）══════════════════════════════════
     *
     * 回归测试：界面上的过滤器曾经一选就崩 —— on_row_visible 里
     * 往 4 字节的枚举读 8 字节的对象指针，破坏栈。现在判定逻辑是
     * 纯函数，这里把 6 种模式 × 各种状态的组合全测一遍。
     * ══════════════════════════════════════════════════════════════ */
    stdout.printf ("\n── 12. 过滤判定 ──────────────────────────\n");

    // 造几个不同状态的条目
    AppEntry mk (string name, MatchState ms, HealthState hs) {
        var a = new AppEntry ("/tmp/filter-test/%s.AppImage".printf (name));
        a.meta_name = name;
        a.display_name = name;
        a.match = ms;
        a.health = hs;
        return a;
    }

    var e_new  = mk ("NewOne",  MatchState.NEW,        HealthState.UNKNOWN);
    var e_reg  = mk ("RegOne",  MatchState.REGISTERED, HealthState.HEALTHY);
    var e_ext  = mk ("ExtOne",  MatchState.EXTERNAL,   HealthState.IMPROVABLE);
    var e_bad  = mk ("BadOne",  MatchState.BROKEN,     HealthState.UNKNOWN);
    var e_cor  = mk ("CorOne",  MatchState.REGISTERED, HealthState.CORRUPT);

    // ── 模式 0：全部，谁都应该通过 ──
    check (ref checks, ref failures, "过滤 全部 → 新发现通过",
           Store.matches_filter (e_new, 0, ""), "");
    check (ref checks, ref failures, "过滤 全部 → 失效也通过",
           Store.matches_filter (e_bad, 0, ""), "");

    // ── 模式 1：新发现 ──
    check (ref checks, ref failures, "过滤 新发现 → 只放行 NEW",
           Store.matches_filter (e_new, 1, "")
           && !Store.matches_filter (e_reg, 1, "")
           && !Store.matches_filter (e_ext, 1, "")
           && !Store.matches_filter (e_bad, 1, ""), "");

    // ── 模式 2：已创建 ──
    check (ref checks, ref failures, "过滤 已创建 → 只放行 REGISTERED",
           Store.matches_filter (e_reg, 2, "")
           && !Store.matches_filter (e_new, 2, "")
           && !Store.matches_filter (e_ext, 2, ""), "");

    // ── 模式 3：外部 ──
    check (ref checks, ref failures, "过滤 外部 → 只放行 EXTERNAL",
           Store.matches_filter (e_ext, 3, "")
           && !Store.matches_filter (e_reg, 3, ""), "");

    // ── 模式 4：失效 ──
    check (ref checks, ref failures, "过滤 失效 → 只放行 BROKEN",
           Store.matches_filter (e_bad, 4, "")
           && !Store.matches_filter (e_new, 4, ""), "");

    // ── 模式 5：可优化（健康度，不是匹配状态）──
    check (ref checks, ref failures, "过滤 可优化 → IMPROVABLE 通过",
           Store.matches_filter (e_ext, 5, ""), "");
    check (ref checks, ref failures, "过滤 可优化 → CORRUPT 通过",
           Store.matches_filter (e_cor, 5, ""), "");
    check (ref checks, ref failures, "过滤 可优化 → HEALTHY 不通过",
           !Store.matches_filter (e_reg, 5, ""), "");
    check (ref checks, ref failures, "过滤 可优化 → UNKNOWN 不通过",
           !Store.matches_filter (e_new, 5, ""), "");

    // ── 未知模式当「全部」──
    check (ref checks, ref failures, "未知过滤模式当全部处理（不误伤）",
           Store.matches_filter (e_new, 99, ""), "");

    // ── 搜索 ──
    check (ref checks, ref failures, "搜索：匹配显示名（大小写不敏感）",
           Store.matches_filter (e_new, 0, "newone"), "");
    check (ref checks, ref failures, "搜索：匹配路径片段",
           Store.matches_filter (e_new, 0, "filter-test"), "");
    check (ref checks, ref failures, "搜索：不匹配的应被滤掉",
           !Store.matches_filter (e_new, 0, "zzzznope"), "");
    check (ref checks, ref failures, "搜索：首尾空格被忽略",
           Store.matches_filter (e_new, 0, "   NewOne   "), "");

    // ── 组合：模式 + 搜索 ──
    check (ref checks, ref failures, "组合：模式命中但搜索不命中 → 滤掉",
           !Store.matches_filter (e_new, 1, "RegOne"), "");
    check (ref checks, ref failures, "组合：模式与搜索都命中 → 通过",
           Store.matches_filter (e_new, 1, "NewOne"), "");

    // ── 空引用不该崩 ──
    check (ref checks, ref failures, "传入 null 不崩、返回 false",
           !Store.matches_filter (null, 1, "x"), "");

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

/**
 * 渲染一个药丸，取左侧圆点的中心像素，比对 RGB。
 * 圆点是不透明纯色，最适合用来验证通道顺序。
 */
void check_pill (ref int checks, ref int failures,
                 string text, int sev, string expect_hex) {
    string color = PillPainter.color_for (text, sev);
    bool hollow = (text == "新发现");
    var pb = PillPainter.render (text, color, hollow, 24);

    // 圆点圆心：pad(8) + dot(7)/2 = 11.5，取 11；纵向居中
    int px = 11, py = 12;
    int nch = pb.get_n_channels ();
    int rowstride = pb.get_rowstride ();
    unowned uchar[] pix = pb.get_pixels ();
    int off = py * rowstride + px * nch;

    int r = pix[off];
    int g = pix[off + 1];
    int b = pix[off + 2];

    uint er = 0, eg = 0, eb = 0;
    string h = expect_hex.substring (1);
    uint.try_parse (h.substring (0, 2), out er, null, 16);
    uint.try_parse (h.substring (2, 2), out eg, null, 16);
    uint.try_parse (h.substring (4, 2), out eb, null, 16);

    // 抗锯齿会影响边缘，圆心应该是纯色，允许 ±6 的误差
    bool ok = (Math.fabs (r - (int) er) <= 6)
           && (Math.fabs (g - (int) eg) <= 6)
           && (Math.fabs (b - (int) eb) <= 6);

    checks++;
    if (ok) {
        stdout.printf ("  ✓ 药丸 %s 圆点颜色 #%02X%02X%02X\n", text, r, g, b);
    } else {
        failures++;
        stdout.printf ("  ✗ 药丸 %s 圆点颜色错误\n", text);
        stdout.printf ("      期望 #%02X%02X%02X，实际 #%02X%02X%02X\n",
                       er, eg, eb, r, g, b);
        if (r == (int) eb && b == (int) er)
            stdout.printf ("      → 红蓝通道互换（Cairo/GdkPixbuf 字节序搞反了）\n");
    }
}

/** 该问题是否存在且被标记为可自动修 */
bool has_applyable (RuleSet.Result rs, string id) {
    foreach (var p in rs.problems)
        if (p.id == id && p.applyable)
            return true;
    return false;
}

string problem_ids (RuleSet.Result rs) {
    var a = new GenericArray<string> ();
    foreach (var p in rs.problems)
        a.add (p.id);
    return join (a);
}

bool has_str2 (string[] a, string want) {
    foreach (string x in a)
        if (x == want)
            return true;
    return false;
}

bool has_problem (RuleSet.Result rs, string id) {
    foreach (var p in rs.problems)
        if (p.id == id)
            return true;
    return false;
}

string join_strs (string[] a) {
    if (a.length == 0)
        return "（无）";
    return string.joinv (", ", a);
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
