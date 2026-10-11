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

    /* ══ 13. 认领的字节保真 ═══════════════════════════════════════
     *
     * 回归测试：认领原先走 Doc 往返，会丢注释、丢空行、还会把
     * [Desktop Action ...] 整组删掉 —— 与「原有内容一个字节都不改，
     * 只追加标记」的承诺不符。现在改为字节级插入。
     * ══════════════════════════════════════════════════════════════ */
    stdout.printf ("\n── 13. 认领的字节保真 ────────────────────\n");

    // 故意包含：开头注释、带空格的原写法、组内空行、附加组
    string sample =
        "# 这是我自己写的注释，不能被弄丢\n"
        + "[Desktop Entry]\n"
        + "Type=Application\n"
        + "Name = Foo Bar\n"
        + "Comment=中文描述\n"
        + "\n"
        + "Exec=\"/tmp/claim-test/Foo.AppImage\" %U\n"
        + "Terminal=false\n"
        + "\n"
        + "[Desktop Action NewWindow]\n"
        + "Name=新窗口\n"
        + "Exec=\"/tmp/claim-test/Foo.AppImage\" --new-window\n";

    string claimed = Repair.append_markers (sample, "/tmp/claim-test/Foo.AppImage");

    check (ref checks, ref failures, "保留文件开头的注释",
           claimed.contains ("# 这是我自己写的注释"), "");
    check (ref checks, ref failures, "保留 Main 组里的注释（如果有）",
           claimed.contains ("中文描述"), "");
    check (ref checks, ref failures, "保留带空格的原写法 Name = Foo Bar",
           claimed.contains ("Name = Foo Bar"),
           "被规范化成了 Name=Foo Bar");
    check (ref checks, ref failures, "保留组内空行（作为与下一个组的分隔）",
           claimed.contains ("X-AppImage-Manager-Version=1.0.0\n\n[Desktop Action NewWindow]"),
           "空行丢了");
    check (ref checks, ref failures, "完整保留 Desktop Action 组",
           claimed.contains ("[Desktop Action NewWindow]")
           && claimed.contains ("Name=新窗口")
           && claimed.contains ("--new-window"),
           "附加组被删掉了");

    check (ref checks, ref failures, "追加了三个标记键",
           claimed.contains ("X-AppImage-Manager=true")
           && claimed.contains ("X-AppImage-Manager-Path=/tmp/claim-test/Foo.AppImage")
           && claimed.contains ("X-AppImage-Manager-Version="), "");

    // 标记键必须落在 [Desktop Entry] 组内，不能跑到 Action 组后面
    int pos_marker = claimed.index_of ("X-AppImage-Manager=true");
    int pos_action = claimed.index_of ("[Desktop Action NewWindow]");
    check (ref checks, ref failures, "标记键插在 Action 组之前（属于 Main 组）",
           pos_marker > 0 && pos_action > 0 && pos_marker < pos_action,
           "marker@%d action@%d".printf (pos_marker, pos_action));

    // 逐字节比对：差异只应来自插入的三行
    var diff_lines = new GenericArray<string> ();
    foreach (string l in claimed.split ("\n"))
        if (!sample.contains (l) && l.strip () != "")
            diff_lines.add (l);
    check (ref checks, ref failures, "与原文件的差异只有新增的三行",
           diff_lines.length == 3,
           "多了 %d 行: %s".printf (diff_lines.length, join (diff_lines)));

    // 幂等：重复认领不应越叠越多
    string again = Repair.append_markers (claimed, "/tmp/claim-test/Foo.AppImage");
    int cnt = 0;
    int from = 0;
    while (true) {
        int p = again.index_of ("X-AppImage-Manager=true", from);
        if (p < 0) break;
        cnt++;
        from = p + 1;
    }
    check (ref checks, ref failures, "重复认领幂等（标记键只有一份）",
           cnt == 1, "出现了 %d 次".printf (cnt));

    // 换一个 AppImage 路径认领时，旧路径应被替换
    string re = Repair.append_markers (claimed, "/tmp/claim-test/Bar.AppImage");
    check (ref checks, ref failures, "改认领到别的 AppImage 时路径被更新",
           re.contains ("X-AppImage-Manager-Path=/tmp/claim-test/Bar.AppImage")
           && !re.contains ("Path=/tmp/claim-test/Foo.AppImage"), "");

    // 末尾换行状态要保持
    string no_nl = "[Desktop Entry]\nType=Application\nName=X";
    string r1 = Repair.append_markers (no_nl, "/a.AppImage");
    check (ref checks, ref failures, "原文没有结尾换行 → 结果也没有",
           !r1.has_suffix ("\n"), "末尾多了换行");

    string with_nl = "[Desktop Entry]\nType=Application\nName=X\n";
    string r2 = Repair.append_markers (with_nl, "/a.AppImage");
    check (ref checks, ref failures, "原文有结尾换行 → 结果也有",
           r2.has_suffix ("\n"), "末尾丢了对换行");

    // 完全没有 [Desktop Entry] 的坏文件也不能崩
    string no_group = "Name=Broken\nType=Application\n";
    string r3 = Repair.append_markers (no_group, "/a.AppImage");
    check (ref checks, ref failures, "没有 [Desktop Entry] 时追加到末尾且不崩",
           r3.contains ("Name=Broken")
           && r3.contains ("X-AppImage-Manager=true"), "");

    // 认领后的内容必须能通过校验
    check (ref checks, ref failures, "认领后的内容通过 desktop-file-validate",
           DesktopFiles.validate_content (claimed) == "",
           DesktopFiles.validate_content (claimed));

    /* ══ 14. 修复时的注释保真 ════════════════════════════════════
     *
     * 与认领同源的问题：修复原先也走 doc.to_text() 整体序列化，
     * 会把注释、空行、以及原始写法（如 “Name = Foo”）都规范化掉。
     * 保守模式承诺「只改明确坏掉的字段」，所以只应重写真正变化的行。
     * ══════════════════════════════════════════════════════════════ */
    stdout.printf ("\n── 14. 修复的注释保真 ────────────────────\n");

    if (sandboxed) {
        string raw_path = GLib.Path.build_filename (sandbox, "repair-fidelity.desktop");
        string raw_text =
            "# 我自己写的注释：这个启动器手动调过，别乱改\n"
            + "[Desktop Entry]\n"
            + "Type=Application\n"
            + "Version=2.0\n"                 // ← 这一行要修
            + "Name = 带空格的写法\n"          // ← 保持原样
            + "\n"                             // ← 空行
            + "Comment=手写的描述\n"
            + "Exec=\"/tmp/claim-test/Foo.AppImage\" %U\n"
            + "Terminal=true\n"                // ← 这一行也要修
            + "\n"
            + "[Desktop Action Custom]\n"
            + "Name=自定义动作\n"
            + "Exec=\"/tmp/claim-test/Foo.AppImage\" --x\n";
        GLib.FileUtils.set_contents (raw_path, raw_text);

        var fe = DesktopFiles.parse (raw_path);
        var fapp = new AppEntry ("/tmp/claim-test/Foo.AppImage");
        fapp.meta_name = "Foo";

        var frs = RuleSet.check (fe, fapp);
        var fplan = new RepairPlan (fapp, fe);
        fplan.problems = frs.problems;
        fplan.selected = new bool[frs.problems.length];
        for (int i = 0; i < fplan.selected.length; i++)
            fplan.selected[i] = frs.problems[i].applyable;
        fplan.mode = FixMode.CONSERVATIVE;

        string fixed_up = Repair.build_repaired (fplan);

        check (ref checks, ref failures, "修复后保留文件头注释",
               fixed_up.contains ("# 我自己写的注释"), "");
        check (ref checks, ref failures, "修复后保留原写法 Name = 带空格的写法",
               fixed_up.contains ("Name = 带空格的写法"),
               "被规范化掉了");
        check (ref checks, ref failures, "修复后保留空行",
               fixed_up.contains ("\n\n"), "");
        check (ref checks, ref failures, "修复后保留 Desktop Action 组",
               fixed_up.contains ("[Desktop Action Custom]")
               && fixed_up.contains ("Name=自定义动作"), "");

        check (ref checks, ref failures, "Version 确实被钳回 1.5",
               fixed_up.contains ("Version=1.5")
               && !fixed_up.contains ("Version=2.0"), "");
        check (ref checks, ref failures, "Terminal 确实被改成 false",
               fixed_up.contains ("Terminal=false")
               && !fixed_up.contains ("Terminal=true"), "");

        check (ref checks, ref failures, "修复后内容通过 desktop-file-validate",
               DesktopFiles.validate_content (fixed_up) == "",
               DesktopFiles.validate_content (fixed_up));
    }

    /* ══ 15. 认领时改写 Exec 也要保真 ═════════════════════════════
     *
     * 纯认领走 append_markers（已有测试）。但用户勾了「修正 Exec 转义」
     * 就会走改写路径 —— 那条路径原先同样逐行重建，注释、空行、附加组
     * 一并丢失。现在改为只动 Exec / TryExec 两行。
     * ══════════════════════════════════════════════════════════════ */
    stdout.printf ("\n── 15. 认领改写的保真 ────────────────────\n");

    string messy =
        "# 手写注释，别丢\n"
        + "[Desktop Entry]\n"
        + "Type=Application\n"
        + "Name = 带空格写法\n"
        + "\n"
        + "Exec=/tmp/claim-test/Old Name.AppImage %U\n"   // 未转义，需要修
        + "TryExec=/tmp/claim-test/Old Name.AppImage\n"
        + "Terminal=false\n"
        + "\n"
        + "[Desktop Action Keep]\n"
        + "Name=保留我\n"
        + "Exec=/tmp/claim-test/Old Name.AppImage --k\n";

    string rw = Repair.claim_rewrite (messy, "/tmp/claim-test/New.AppImage",
                                      true, true);

    check (ref checks, ref failures, "改写 Exec 后仍保留注释",
           rw.contains ("# 手写注释，别丢"), "");
    check (ref checks, ref failures, "改写 Exec 后仍保留原写法 Name = 带空格写法",
           rw.contains ("Name = 带空格写法"), "");
    check (ref checks, ref failures, "改写 Exec 后仍保留附加组",
           rw.contains ("[Desktop Action Keep]") && rw.contains ("Name=保留我"), "");
    check (ref checks, ref failures, "Exec 已被正确转义并指向新路径",
           rw.contains ("Exec=\"/tmp/claim-test/New.AppImage\" %U"),
           "仍含旧值");
    check (ref checks, ref failures, "TryExec 已更新",
           rw.contains ("TryExec=/tmp/claim-test/New.AppImage"), "");
    check (ref checks, ref failures, "附加组里的旧路径没有被误改",
           rw.contains ("--k") && rw.contains ("Old Name.AppImage"),
           "连别的组也一起改了");
    check (ref checks, ref failures, "追加了标记键",
           rw.contains ("X-AppImage-Manager=true")
           && rw.contains ("Path=/tmp/claim-test/New.AppImage"), "");
    check (ref checks, ref failures, "标记键在附加组之前",
           rw.index_of ("X-AppImage-Manager=true")
           < rw.index_of ("[Desktop Action Keep]"), "");
    check (ref checks, ref failures, "改写后通过 desktop-file-validate",
           DesktopFiles.validate_content (rw) == "",
           DesktopFiles.validate_content (rw));

    // 幂等
    string rw2 = Repair.claim_rewrite (rw, "/tmp/claim-test/New.AppImage", true, true);
    int mc = 0;
    int fp = 0;
    while (true) {
        int q = rw2.index_of ("X-AppImage-Manager=true", fp);
        if (q < 0) break;
        mc++; fp = q + 1;
    }
    check (ref checks, ref failures, "重复改写幂等（标记键只有一份）",
           mc == 1, "出现 %d 次".printf (mc));
    check (ref checks, ref failures, "重复改写不重复插 TryExec",
           rw2.index_of ("TryExec=") == rw2.last_index_of ("TryExec="), "");

    // 不改 Exec 时，Exec 行应逐字保留
    string keep = Repair.claim_rewrite (messy, "/tmp/claim-test/New.AppImage",
                                        false, false);
    check (ref checks, ref failures, "不改 Exec 时原行逐字保留",
           keep.contains ("Exec=/tmp/claim-test/Old Name.AppImage %U"), "");

    /* ══ 16. 按键改写（补全启动器用）═════════════════════════════
     *
     * 「用内置元数据补全所选启动器」靠 Repair.upsert_keys 落地：只替换
     * 指定的几个键，注释、空行、原始写法、附加组必须一个字节都不动 ——
     * 与认领/修复是同一套保真要求。
     * ══════════════════════════════════════════════════════════════ */
    stdout.printf ("\n── 16. 按键改写的保真 ────────────────────\n");

    string src16 =
        "# 我手写的注释\n"
        + "[Desktop Entry]\n"
        + "Type=Application\n"
        + "Name=Old Name\n"
        + "Comment=旧描述\n"
        + "\n"
        + "Exec=\"/tmp/claim-test/Foo.AppImage\" %U\n"
        + "Terminal=false\n"
        + "\n"
        + "[Desktop Action Keep]\n"
        + "Name=保留我\n";

    var up16 = new GLib.HashTable<string, string> (GLib.str_hash, GLib.str_equal);
    up16.insert ("Name", "New Name");
    up16.insert ("Comment", "新描述");
    up16.insert ("Categories", "Graphics;");

    string r16 = Repair.upsert_keys (src16, up16);

    check (ref checks, ref failures, "按键改写保留注释",
           r16.contains ("# 我手写的注释"), "");
    check (ref checks, ref failures, "按键改写保留空行",
           r16.contains ("\n\n"), "");
    check (ref checks, ref failures, "按键改写保留附加组",
           r16.contains ("[Desktop Action Keep]") && r16.contains ("Name=保留我"), "");
    check (ref checks, ref failures, "附加组里的同名键没有被误改",
           r16.contains ("Name=保留我") && !r16.contains ("Name=New Name\nName="), "");
    check (ref checks, ref failures, "指定的键被替换",
           r16.contains ("Name=New Name") && r16.contains ("Comment=新描述")
           && !r16.contains ("Name=Old Name") && !r16.contains ("Comment=旧描述"), "");
    check (ref checks, ref failures, "原文没有的键被补上",
           r16.contains ("Categories=Graphics;"), "");
    check (ref checks, ref failures, "未指定的键逐字保留",
           r16.contains ("Type=Application") && r16.contains ("Terminal=false")
           && r16.contains ("Foo.AppImage\" %U"), "");
    check (ref checks, ref failures, "改写后通过 desktop-file-validate",
           DesktopFiles.validate_content (r16) == "",
           DesktopFiles.validate_content (r16));

    // 幂等：同样的更新再来一次，内容不应再变
    string r16b = Repair.upsert_keys (r16, up16);
    check (ref checks, ref failures, "重复改写幂等（内容不再变化）",
           r16b == r16, "第二次改写又动了文件");

    // 值没变时应当逐字节原样返回
    var up16c = new GLib.HashTable<string, string> (GLib.str_hash, GLib.str_equal);
    up16c.insert ("Name", "Old Name");
    string r16c = Repair.upsert_keys (src16, up16c);
    check (ref checks, ref failures, "值本来就相同 → 文件逐字节不变",
           r16c == src16, "无谓地重写了");

    // 没有 [Desktop Entry] 组时不能崩，也不应凭空造内容
    string nogroup = "Name=Broken\nType=Application\n";
    var up16d = new GLib.HashTable<string, string> (GLib.str_hash, GLib.str_equal);
    up16d.insert ("Name", "X");
    string r16d = Repair.upsert_keys (nogroup, up16d);
    check (ref checks, ref failures, "没有 [Desktop Entry] 组时不崩",
           r16d.length > 0, "");

    // 带空格的原写法在「未指定该键」时必须保留
    string spaced = "[Desktop Entry]\nType=Application\nName = 带空格\n";
    var up16e = new GLib.HashTable<string, string> (GLib.str_hash, GLib.str_equal);
    up16e.insert ("Comment", "新增");
    string r16e = Repair.upsert_keys (spaced, up16e);
    check (ref checks, ref failures, "未指定的键保留原始空格写法",
           r16e.contains ("Name = 带空格"), "被规范化了");

    /* ══ 17. 图标安装与「内置元数据」判定 ════════════════════════
     *
     * 两个都踩过的坑：
     *  1) install_icon 里 slugify 保留了「.」，之后又拼一次扩展名，
     *     产出 krita-real.png.png 这种双扩展名。
     *  2) AppImageInfo.name 在构造时就按文件名猜了一个，所以「name 非空」
     *     不能说明 AppImage 里真有元数据 —— 拿它当判据会把用户手写的
     *     Name 换成文件名猜出来的值，属于静默改用户数据。
     * ══════════════════════════════════════════════════════════════ */
    stdout.printf ("\n── 17. 图标安装与元数据判定 ──────────────\n");

    if (sandboxed) {
        var cfg17 = new AppConfig ();

        // 造一个假的解包目录
        string ex = GLib.Path.build_filename (sandbox, "fake-extract");
        AppPath.ensure_dir (ex);
        AppPath.ensure_dir (GLib.Path.build_filename (ex, "usr", "share", "icons"));

        // 用真 PNG（Gdk 要能读）
        string icon_src = GLib.Path.build_filename (ex, "myapp-icon.png");
        bool made = false;
        try {
            var pb = new Gdk.Pixbuf (Gdk.Colorspace.RGB, true, 8, 16, 16);
            pb.fill (0x3366ccff);
            pb.savev (icon_src, "png", null, null);
            made = true;
        } catch { made = false; }

        if (made) {
            var info17 = new AppImageInfo ("/tmp/whatever/MyApp-1.2.AppImage");
            info17.extract_dir = ex;
            info17.icon_relpath = "myapp-icon.png";
            info17.ok = true;

            string? dest = AppImageExtract.install_icon (info17, cfg17);

            check (ref checks, ref failures, "install_icon 返回了路径",
                   dest != null, "返回 null");
            if (dest != null) {
                check (ref checks, ref failures, "图标文件名没有双扩展名",
                       !dest.has_suffix (".png.png"),
                       "得到 " + GLib.Path.get_basename (dest));
                check (ref checks, ref failures, "图标文件名以单一 .png 结尾",
                       dest.has_suffix (".png"),
                       GLib.Path.get_basename (dest));
                check (ref checks, ref failures, "图标文件确实落盘了",
                       AppPath.exists (dest), dest);
            }

            // has_embedded_metadata 的默认值必须是 false：构造时按文件名
            // 猜出来的 name 不算「内置元数据」
            var fresh = new AppImageInfo ("/tmp/whatever/Guessed-Name-9.AppImage");
            check (ref checks, ref failures, "新 AppImageInfo 默认没有内置元数据标记",
                   !fresh.has_embedded_metadata, "默认为 true，会被误判");
            check (ref checks, ref failures, "但文件名推导出的 name 仍然可用（供表单预填）",
                   fresh.name != "", "预填用不上");
        } else {
            stdout.printf ("  ⚠ 跳过：无法生成测试 PNG\n");
        }
    }

    // 新增的键要插在组尾空行**之前**，空行继续分隔下一个组
    string tail16 = "[Desktop Entry]\nType=Application\nName=X\n\n[Desktop Action A]\nName=A\n";
    var up16f = new GLib.HashTable<string, string> (GLib.str_hash, GLib.str_equal);
    up16f.insert ("Comment", "新增的");
    string r16f = Repair.upsert_keys (tail16, up16f);
    check (ref checks, ref failures, "新增键插在组尾空行之前",
           r16f.contains ("Comment=新增的\n\n[Desktop Action A]"),
           "新键落在了空行后面");

    /* ══ 18. 路径规范化（符号链接）═══════════════════════════════
     *
     * 打包时发现：AppPath.canonical() 遇到软链接会返回垃圾（有报告称
     * 只剩 4 字节）。canonical() 是「两个路径是否指同一个文件」的判据，
     * 出问题会导致认领/关联匹配全线失灵。这里钉死它的行为。
     * ══════════════════════════════════════════════════════════════ */
    stdout.printf ("\n── 18. 路径规范化 ────────────────────────\n");

    if (sandboxed) {
        string real_dir = GLib.Path.build_filename (sandbox, "canon-real");
        AppPath.ensure_dir (real_dir);
        string real_file = GLib.Path.build_filename (real_dir, "Target.AppImage");
        GLib.FileUtils.set_contents (real_file, "x");

        string link_dir = GLib.Path.build_filename (sandbox, "canon-link");
        GLib.FileUtils.remove (link_dir);
        try {
            GLib.FileUtils.symlink (real_dir, link_dir);
        } catch { }

        string link_file = GLib.Path.build_filename (link_dir, "Target.AppImage");

        // 普通路径
        string c1 = AppPath.canonical (real_file);
        check (ref checks, ref failures, "canonical 对普通路径返回合理结果",
               c1 == AppPath.canonical (real_file) && c1 != "",
               "得到 \"" + c1 + "\"");
        check (ref checks, ref failures, "canonical 不返回垃圾（长度合理）",
               c1.length >= real_file.length - 8,
               "长度 %d vs 期望 ~%d".printf (c1.length, real_file.length));

        // 软链接目录下的文件
        string c2 = AppPath.canonical (link_file);
        check (ref checks, ref failures, "canonical 解析软链接目录后得到真实路径",
               c2 == c1,
               "软链接得到 \"" + c2 + "\"，真实路径 \"" + c1 + "\"");
        check (ref checks, ref failures, "canonical 结果不含软链接目录名",
               !c2.contains ("canon-link"),
               c2);

        // 路径本身是软链接
        string link_self = GLib.Path.build_filename (sandbox, "SelfLink.AppImage");
        GLib.FileUtils.remove (link_self);
        try {
            GLib.FileUtils.symlink (real_file, link_self);
        } catch { }
        string c3 = AppPath.canonical (link_self);
        check (ref checks, ref failures, "canonical 解析文件本身是软链接的情况",
               c3 == c1, "得到 \"" + c3 + "\"");

        // 指向不存在的目标时不应崩，且应返回绝对路径
        string dangling = GLib.Path.build_filename (sandbox, "Dangling.AppImage");
        GLib.FileUtils.remove (dangling);
        try {
            GLib.FileUtils.symlink ("/nonexistent/nope", dangling);
        } catch { }
        string c4 = AppPath.canonical (dangling);
        check (ref checks, ref failures, "canonical 对悬空软链接不崩且返回绝对路径",
               c4.has_prefix ("/"), "得到 \"" + c4 + "\"");
    }

    /* ══ 19. 失效启动器的识别与列表可见性 ════════════════════════
     *
     * 「失效」过滤器曾经永远空白：detect_broken() 找出了条目，但只塞进
     * broken_entries，一份都没进 entries —— 而列表和过滤器只看 entries。
     * 这里钉死：失效条目必须真的出现在列表里，且过滤器能选中它。
     * ══════════════════════════════════════════════════════════════ */
    stdout.printf ("\n── 19. 失效启动器的识别 ──────────────────\n");

    if (sandboxed) {
        AppPath.ensure_dir (apps_out);

        // 指向不存在 AppImage 的受管启动器
        string gone = GLib.Path.build_filename (apps_out, "gone-test.desktop");
        GLib.FileUtils.set_contents (gone,
            "# 保留的注释\n"
            + "[Desktop Entry]\n"
            + "Type=Application\n"
            + "Name=已经消失的应用\n"
            + "Exec=\"/tmp/appmgr-nonexistent/Nowhere.AppImage\" %U\n"
            + "X-AppImage-Manager=true\n"
            + "X-AppImage-Manager-Path=/tmp/appmgr-nonexistent/Nowhere.AppImage\n");

        // 全大写扩展名，且没有标记键 —— 靠扩展名识别
        string upper = GLib.Path.build_filename (apps_out, "gone-upper.desktop");
        GLib.FileUtils.set_contents (upper,
            "[Desktop Entry]\n"
            + "Type=Application\n"
            + "Name=大写扩展名\n"
            + "Exec=/tmp/appmgr-nonexistent/UPPER.APPIMAGE %U\n");

        var st19 = new Store (new AppConfig ());
        st19.rescan ();

        AppEntry? b1 = null;
        AppEntry? b2 = null;
        foreach (var e in st19.entries) {
            if (e.basename == "Nowhere.AppImage")
                b1 = e;
            if (e.basename == "UPPER.APPIMAGE")
                b2 = e;
        }

        check (ref checks, ref failures, "失效的启动器进入了列表（不再是空白）",
               b1 != null, "列表里找不到 Nowhere.AppImage");
        if (b1 != null) {
            check (ref checks, ref failures, "它的匹配状态是 BROKEN",
                   b1.match == MatchState.BROKEN,
                   "match=%d".printf ((int) b1.match));
            check (ref checks, ref failures, "「失效」过滤器能选中它",
                   Store.matches_filter (b1, 4, ""), "过滤器 4 返回 false");
            check (ref checks, ref failures, "展示名优先用 .desktop 里的 Name",
                   b1.get_best_name () == "已经消失的应用",
                   "得到 \"" + b1.get_best_name () + "\"");
            check (ref checks, ref failures, "它不应被其他过滤器误选",
                   !Store.matches_filter (b1, 1, "")
                   && !Store.matches_filter (b1, 2, "")
                   && !Store.matches_filter (b1, 3, ""), "");
        }

        check (ref checks, ref failures, "大写扩展名 .APPIMAGE 也能识别为失效",
               b2 != null, "大小写敏感的判断漏掉了它");
        if (b2 != null)
            check (ref checks, ref failures, "大写那条的过滤器也正确",
                   Store.matches_filter (b2, 4, ""), "");

        check (ref checks, ref failures, "broken_entries 同时记录了它们",
               st19.broken_entries.length >= 2,
               "只有 %d 条".printf (st19.broken_entries.length));

        // 目标存在的启动器不能被误判为失效。
        // 只在夹具确实存在时才测，免得夹具缺失导致假失败。
        string alive = GLib.Path.build_filename (apps_out, "alive-test.desktop");
        string real_app = GLib.Path.build_filename (apps_dir, "Krita-5.2.0-x86_64.AppImage");
        if (AppPath.exists (real_app))
        GLib.FileUtils.set_contents (alive,
            "[Desktop Entry]\n"
            + "Type=Application\n"
            + "Name=还活着的\n"
            + "Exec=\"" + real_app + "\" %U\n");

        var st19b = new Store (new AppConfig ());
        st19b.rescan ();
        bool alive_broken = false;
        foreach (var e in st19b.entries)
            if (e.basename == "alive-test.desktop")
                alive_broken = true;
        check (ref checks, ref failures, "目标存在的启动器不被误判为失效",
               !alive_broken, "被当成失效了");

        // 清理，别影响别的用例
        GLib.FileUtils.remove (gone);
        GLib.FileUtils.remove (upper);
        GLib.FileUtils.remove (alive);
    }

    /* ══ 20. 事务日志与备份还原 ════════════════════════════════
     *
     * Journal / Backup 此前几乎零覆盖（Journal 0 处引用），而它们是所有
     * 破坏性操作的唯一撤销通道。这里把最容易悄悄坏掉的三件事钉死：
     *   1) 序列化往返：崩溃恢复读的就是这份 JSON，字段丢了就恢复不了
     *   2) 备份→改动→还原：还原后必须逐字节回到原样
     *   3) 篡改检测：备份之后文件又被改过，还原时必须知道而不是盲覆盖
     * ══════════════════════════════════════════════════════════════ */
    stdout.printf ("\n── 20. 事务日志与备份还原 ────────────────\n");

    if (sandboxed) {
        // ── 1) 序列化往返，含需要转义的字符 ──
        var tx20 = new Journal.Tx ();
        tx20.txid = Journal.new_txid ();
        tx20.operation = "repair";
        tx20.mode = "conservative";
        tx20.started_at = Journal.now_iso ();

        var it20 = new Journal.Item ();
        it20.orig_path = "/tmp/带 空格 和\"引号\".desktop";
        it20.new_path = "/tmp/新名字.desktop";
        it20.actions = { "backup", "fix", "rename" };
        it20.rules_fired = { "版本号越界", "行尾有多余空白" };
        it20.status = "done";
        it20.duration_ms = 12345;
        tx20.set_items ({ it20 });

        string json20 = tx20.serialize ();
        check (ref checks, ref failures, "事务能序列化成 JSON",
               json20.has_prefix ("{") && json20.has_suffix ("}"), json20.substring (0, 60));

        var back20 = Journal.Tx.from_json (json20);
        check (ref checks, ref failures, "JSON 能解析回事务",
               back20 != null, "from_json 返回 null");
        if (back20 != null) {
            check (ref checks, ref failures, "往返后 txid 不变",
                   back20.txid == tx20.txid, back20.txid);
            check (ref checks, ref failures, "往返后 operation/mode 不变",
                   back20.operation == "repair" && back20.mode == "conservative", "");
            check (ref checks, ref failures, "往返后含空格与引号的路径不变",
                   back20.items.length == 1
                   && back20.items[0].orig_path == it20.orig_path,
                   "得到 \"" + (back20.items.length > 0 ? back20.items[0].orig_path : "") + "\"");
            check (ref checks, ref failures, "往返后 actions 数组不变",
                   back20.items[0].actions.length == 3
                   && back20.items[0].actions[2] == "rename",
                   "得到 %d 项".printf (back20.items[0].actions.length));
            check (ref checks, ref failures, "往返后中文 rules_fired 不乱码",
                   back20.items[0].rules_fired.length == 2
                   && back20.items[0].rules_fired[0] == "版本号越界",
                   "得到 \"%s\"".printf (back20.items[0].rules_fired[0] ?? ""));
            check (ref checks, ref failures, "往返后 duration_ms 不变",
                   back20.items[0].duration_ms == 12345,
                   "%d".printf ((int) back20.items[0].duration_ms));
        }

        // ── 2) 未完成的事务能被 pending() 发现（崩溃恢复的入口）──
        tx20.write_journal ();
        bool found_pending = false;
        foreach (var p in Journal.pending ())
            if (p.txid == tx20.txid)
                found_pending = true;
        check (ref checks, ref failures, "未提交的事务能被 pending() 发现",
               found_pending, "崩溃恢复会漏掉它");

        // 提交后就不该再出现在待恢复列表里
        tx20.commit ();
        bool still_pending = false;
        foreach (var p in Journal.pending ())
            if (p.txid == tx20.txid)
                still_pending = true;
        check (ref checks, ref failures, "提交后不再出现在 pending() 里",
               !still_pending, "已提交的事务仍被当成待恢复");

        // ── 3) 备份 → 改动 → 还原 的完整往返 ──
        string orig_text = "[Desktop Entry]\nType=Application\nName=原始名称\n"
                         + "# 一条注释，验证往返不丢\n\nExec=/a/b.AppImage %U\n";
        string victim = GLib.Path.build_filename (sandbox, "restore-me.desktop");
        GLib.FileUtils.set_contents (victim, orig_text);

        var tx21 = new Journal.Tx ();
        tx21.txid = Journal.new_txid ();
        tx21.operation = "repair";
        tx21.started_at = Journal.now_iso ();

        var bk = Backup.backup_file (tx21, victim);
        check (ref checks, ref failures, "backup_file 记录了原路径",
               bk.orig_path != "", bk.orig_path);
        check (ref checks, ref failures, "backup_file 填了备份路径",
               bk.backup_path != "", "backup_path 为空");
        check (ref checks, ref failures, "backup_file 记了改动前的 sha256",
               bk.sha256_before == Journal.sha256 (victim), "");

        // backup_file 只是返回 Item，调用方必须自己注册进事务 ——
        // 真实调用方（Repair.execute）就是这么做的
        bk.actions = { "backup", "fix" };
        bk.status = "done";
        tx21.set_items ({ bk });

        bool intact_ok = false;
        bool file_matches = false;
        intact_ok = Backup.backup_intact (tx21, bk, out file_matches);
        check (ref checks, ref failures, "备份刚做完时校验通过",
               intact_ok, "备份校验失败");

        // 把文件改坏
        GLib.FileUtils.set_contents (victim, "[Desktop Entry]\nType=Application\nName=被改坏了\n");
        // 再还原
        var rr = Backup.restore (tx21, Backup.ConflictPolicy.STASH);
        check (ref checks, ref failures, "还原报告成功 1 个",
               rr.restored == 1,
               "restored=%d failed=%d msg=%s".printf (rr.restored, rr.failed,
                                                      string.joinv ("; ", rr.messages)));

        string got = "";
        try { GLib.FileUtils.get_contents (victim, out got); } catch { got = ""; }
        check (ref checks, ref failures, "还原后内容逐字节回到原样",
               got == orig_text,
               "还原后长度 %d，原长度 %d".printf (got.length, orig_text.length));
        check (ref checks, ref failures, "还原保留了注释",
               got.contains ("一条注释"), "");
        check (ref checks, ref failures, "还原保留了空行",
               got.contains ("\n\n"), "");

        // ── 4) 篡改检测：备份之后文件又被改过，还原时要能发现 ──
        string victim2 = GLib.Path.build_filename (sandbox, "restore-me2.desktop");
        GLib.FileUtils.set_contents (victim2, "[Desktop Entry]\nName=版本二\n");
        var tx22 = new Journal.Tx ();
        tx22.txid = Journal.new_txid ();
        tx22.operation = "repair";
        tx22.started_at = Journal.now_iso ();
        var bk2 = Backup.backup_file (tx22, victim2);
        bk2.actions = { "backup", "fix" };
        bk2.status = "done";
        tx22.set_items ({ bk2 });

        // 用户后来又手动改了它 —— 与备份不符
        GLib.FileUtils.set_contents (victim2, "[Desktop Entry]\nName=用户后来改的\n");
        bool ok2 = false; bool match2 = true;
        ok2 = Backup.backup_intact (tx22, bk2, out match2);
        check (ref checks, ref failures, "文件被改过之后，校验如实报告不匹配",
               !match2, "match2=true，篡改没被发现");

        // STASH 策略应另存当前内容再还原，不能把用户的后续修改直接吞掉
        var rr2 = Backup.restore (tx22, Backup.ConflictPolicy.STASH);
        string got2 = "";
        try { GLib.FileUtils.get_contents (victim2, out got2); } catch { got2 = ""; }
        check (ref checks, ref failures, "STASH 策略下内容被还原",
               got2.contains ("版本二"), "得到 \"%s\"".printf (got2.replace ("\n", "|")));

        // ── 5) 备份文件缺失时必须报错而不是静默放过 ──
        string victim3 = GLib.Path.build_filename (sandbox, "restore-me3.desktop");
        GLib.FileUtils.set_contents (victim3, "[Desktop Entry]\nName=版本三\n");
        var tx23 = new Journal.Tx ();
        tx23.txid = Journal.new_txid ();
        tx23.operation = "repair";
        tx23.started_at = Journal.now_iso ();
        var bk3 = Backup.backup_file (tx23, victim3);
        bk3.actions = { "backup", "fix" };
        bk3.status = "done";
        tx23.set_items ({ bk3 });
        string bpath = Backup.backup_file_path (tx23, bk3);
        if (bpath != "") GLib.FileUtils.remove (bpath);

        var rr3 = Backup.restore (tx23, Backup.ConflictPolicy.STASH);
        check (ref checks, ref failures, "备份缺失时还原要计为失败而不是成功",
               rr3.failed >= 1,
               "restored=%d failed=%d".printf (rr3.restored, rr3.failed));

        // ── 5b) 空事务不能静默「成功」 ──
        var empty_tx = new Journal.Tx ();
        empty_tx.txid = Journal.new_txid ();
        empty_tx.operation = "create";
        empty_tx.started_at = Journal.now_iso ();
        empty_tx.set_items ({});
        var rre = Backup.restore (empty_tx, Backup.ConflictPolicy.STASH);
        check (ref checks, ref failures, "空事务还原要明确报错而不是静默成功",
               rre.failed >= 1 && rre.messages.length >= 1,
               "restored=%d failed=%d messages=%d".printf (rre.restored, rre.failed,
                                                           rre.messages.length));

        // ── 6) sha256 会随内容变化 ──
        string f6 = GLib.Path.build_filename (sandbox, "sha-probe.txt");
        GLib.FileUtils.set_contents (f6, "one");
        string h1 = Journal.sha256 (f6);
        GLib.FileUtils.set_contents (f6, "two");
        string h2 = Journal.sha256 (f6);
        check (ref checks, ref failures, "内容变化时 sha256 随之变化",
               h1 != h2, "两者相同");
        GLib.FileUtils.set_contents (f6, "one");
        check (ref checks, ref failures, "内容变回时 sha256 也变回（稳定不漂移）",
               Journal.sha256 (f6) == h1, "");

        // 收尾
        GLib.FileUtils.remove (victim);
        GLib.FileUtils.remove (victim2);
        GLib.FileUtils.remove (victim3);
        GLib.FileUtils.remove (f6);
    }

    /* ══ 21. 预填与扫描 ═════════════════════════════════════════
     *
     * Prefill 与 Scanner 此前同样接近零覆盖。两者都是「猜」的环节：
     * 从文件名猜应用名、从应用名猜分类、从目录猜有哪些 AppImage。
     * 猜错不会崩，但会静默产出错的启动器 —— 所以每条猜测规则都该有断言。
     * ══════════════════════════════════════════════════════════════ */
    stdout.printf ("\n── 21. 预填与扫描 ────────────────────────\n");

    // ── 分类猜测 ──
    check (ref checks, ref failures, "图形类应用名 → Graphics",
           Prefill.suggest_category ("krita-5.2.0").has_prefix ("Graphics"),
           Prefill.suggest_category ("krita-5.2.0"));
    check (ref checks, ref failures, "开发类应用名 → Development",
           Prefill.suggest_category ("vscode").has_prefix ("Development"),
           Prefill.suggest_category ("vscode"));
    check (ref checks, ref failures, "影音类应用名 → AudioVideo",
           Prefill.suggest_category ("vlc-player").has_prefix ("AudioVideo"),
           Prefill.suggest_category ("vlc-player"));
    check (ref checks, ref failures, "游戏类应用名 → Game",
           Prefill.suggest_category ("steam").has_prefix ("Game"),
           Prefill.suggest_category ("steam"));
    check (ref checks, ref failures, "浏览器类应用名 → Network",
           Prefill.suggest_category ("firefox").has_prefix ("Network"),
           Prefill.suggest_category ("firefox"));

    // 认不出来时必须给出合法兜底，不能是空串 —— 空串会写进 .desktop
    string fallback_cat = Prefill.suggest_category ("zzz完全不存在的东西qqq");
    check (ref checks, ref failures, "认不出的应用名有合法兜底分类",
           fallback_cat != "" && fallback_cat.has_suffix (";"),
           "得到 \"%s\"".printf (fallback_cat));

    // 大小写不敏感
    check (ref checks, ref failures, "分类猜测大小写不敏感",
           Prefill.suggest_category ("KRITA") == Prefill.suggest_category ("krita"),
           "%s vs %s".printf (Prefill.suggest_category ("KRITA"),
                              Prefill.suggest_category ("krita")));

    // ── 文件名 → slug ──
    string[] taken0 = {};
    check (ref checks, ref failures, "slug 去掉已知扩展名并小写化",
           Prefill.ensure_unique_slug ("/x/Obsidian-1.5.3-x86_64.AppImage", taken0)
               == "obsidian-1.5.3-x86_64.desktop",
           Prefill.ensure_unique_slug ("/x/Obsidian-1.5.3-x86_64.AppImage", taken0));

    // 撞名时加序号
    string[] taken1 = { "krita.desktop", "krita-2.desktop" };
    check (ref checks, ref failures, "撞名时递增后缀",
           Prefill.ensure_unique_slug ("/x/krita.AppImage", taken1) == "krita-3.desktop",
           Prefill.ensure_unique_slug ("/x/krita.AppImage", taken1));

    // 判重必须不区分大小写。
    //
    // 为什么这不是吹毛求疵：desktop entry 的文件名在 freedesktop 规范里
    // 是大小写敏感的，但实际部署里启动器目录可能落在大小写不敏感的文件
    // 系统上（NTFS/exFAT 的挂载、macOS 的共享、Samba 共享）。那时候
    // Krita.DESKTOP 和 krita.desktop 是同一个文件，判重漏掉就会直接
    // 覆盖掉用户已有的启动器 —— 而这是不可逆的（顶多能从历史里还原，
    // 但用户不会知道自己丢了东西）。
    string[] taken2 = { "KRITA.DESKTOP" };
    string uniq2 = Prefill.ensure_unique_slug ("/x/krita.AppImage", taken2);
    check (ref checks, ref failures, "判重不区分大小写（防大小写不敏感文件系统上覆盖）",
           uniq2 != "krita.desktop",
           "得到 " + uniq2 + "，会覆盖已存在的 KRITA.DESKTOP");

    // ── 生成内容的基本正确性 ──
    var pf = new Prefill.Fields ();
    pf.name = "Foo & Bar";
    pf.exec_line = "\"/x/foo bar.AppImage\" %U";
    pf.categories = "Graphics;";
    pf.comment = "带 % 和 & 的注释";
    string content = Prefill.build_preview (pf, "/x/foo bar.AppImage", true);

    check (ref checks, ref failures, "生成内容以 [Desktop Entry] 开头",
           content.has_prefix ("[Desktop Entry]\n"), "");
    check (ref checks, ref failures, "生成内容包含转义后的 Exec",
           content.contains ("\"/x/foo bar.AppImage\" %U"),
           "Exec 没被正确转义");
    check (ref checks, ref failures, "生成内容能通过 desktop-file-validate",
           DesktopFiles.validate_content (content) == "",
           DesktopFiles.validate_content (content));

    // Exec 是 desktop 规范里唯一必须把 % 写成 %% 的字段类型（string）。
    // Name / Comment 属于 localestring，规范不要求转义 % 或 & ——
    // 我先前误以为要转义，用 desktop-file-validate 验证后确认是错的。
    check (ref checks, ref failures, "Exec 里的 % 按规范转义成 %%",
           DesktopFiles.build_exec_arg ("/x/100% Pure.AppImage").contains ("100%%"),
           DesktopFiles.build_exec_arg ("/x/100% Pure.AppImage"));
    check (ref checks, ref failures, "Exec 里的引号被转义",
           DesktopFiles.build_exec_arg ("/x/a\"b.AppImage").contains ("\\\""),
           DesktopFiles.build_exec_arg ("/x/a\"b.AppImage"));
    check (ref checks, ref failures, "Exec 里的反斜杠被转义",
           DesktopFiles.build_exec_arg ("/x/a\\b.AppImage").contains ("\\\\"),
           DesktopFiles.build_exec_arg ("/x/a\\b.AppImage"));
    check (ref checks, ref failures, "Exec 参数带空格时被引起来",
           DesktopFiles.build_exec_arg ("/x/foo bar.AppImage").has_prefix ("\""),
           DesktopFiles.build_exec_arg ("/x/foo bar.AppImage"));

    // 关掉标记键
    var pf2 = new Prefill.Fields ();
    pf2.name = "NoMarker";
    pf2.exec_line = "/x/nomarker.AppImage %U";
    string no_marker = Prefill.build_preview (pf2, "/x/nomarker.AppImage", false);
    check (ref checks, ref failures, "关掉标记后不写 X-AppImage-Manager",
           !no_marker.contains (DesktopFiles.MARKER_BOOL),
           "标记键仍在");
    string with_marker = Prefill.build_preview (pf2, "/x/nomarker.AppImage", true);
    check (ref checks, ref failures, "打开标记后写入 X-AppImage-Manager",
           with_marker.contains (DesktopFiles.MARKER_BOOL), "");

    // ── 扩展名判定 ──
        check (ref checks, ref failures, "识别 .AppImage",
           Scanner.has_appimage_extension ("Foo.AppImage"), "");
    check (ref checks, ref failures, "识别 .appimage（小写）",
           Scanner.has_appimage_extension ("Foo.appimage"), "");
    check (ref checks, ref failures, "识别 .APPIMAGE（全大写）",
           Scanner.has_appimage_extension ("Foo.APPIMAGE"), "");
    check (ref checks, ref failures, "识别 .appimage.zsync",
           Scanner.has_appimage_extension ("Foo.appimage.zsync"), "");
    check (ref checks, ref failures, "拒绝普通文件",
           !Scanner.has_appimage_extension ("notes.txt"), "");
    check (ref checks, ref failures, "拒绝 .AppImage 在中间（foo.AppImage.bak）",
           !Scanner.has_appimage_extension ("foo.AppImage.bak"),
           "扩展名判断过于宽松");

    // ── 扫描：不存在的目录不能崩 ──
        var r0 = Scanner.scan ({ "/绝对不存在的目录/appimages" }, true);
    check (ref checks, ref failures, "扫描不存在的目录不崩",
           r0.found.length == 0, "found=%d".printf (r0.found.length));

    if (sandboxed) {
        // 扫真实夹具：递归 + 非递归应当都能找到那些 AppImage
        string apps = GLib.Path.build_filename (sandbox, "apps");
        if (AppPath.is_dir (apps)) {
            var sc_rec = Scanner.scan ({ apps }, true);
            check (ref checks, ref failures, "递归扫描能发现夹具里的 AppImage",
                   sc_rec.found.length > 0, "找到 %d 个".printf (sc_rec.found.length));
            check (ref checks, ref failures, "扫描统计到目录数",
                   sc_rec.scanned_dirs >= 1, "scanned_dirs=%d".printf (sc_rec.scanned_dirs));

            var sc_flat = Scanner.scan ({ apps }, false);
            check (ref checks, ref failures, "非递归扫描的结果不多于递归",
                   sc_flat.found.length <= sc_rec.found.length,
                   "递归 %d vs 非递归 %d".printf (sc_rec.found.length, sc_flat.found.length));
            // 顶层至少有那 11 个，subdir/ 下的两个只在递归时可见
            check (ref checks, ref failures, "递归比非递归多扫到子目录里的",
                   sc_rec.found.length > sc_flat.found.length,
                   "递归 %d vs 非递归 %d（若相等说明 subdir 没被递归扫到）"
                   .printf (sc_rec.found.length, sc_flat.found.length));
        }
    }

    /* ══ 22. 逐条钉住健康检查规则 ══════════════════════════════
     *
     * 规则集有 28 条。此前只有间接覆盖（跑一次 check 看总数），
     * 没有任何一条断言「某个具体的坏法必须命中某条具体的规则」——
     * 于是规则被误删、误改、或判定条件写错，都不会有人发现。
     *
     * 这里做成表驱动：每种坏法 → 期望命中的规则 id。
     * 同时钉住反向：完美样本必须零问题，缺某个键才报对应规则。
     * ══════════════════════════════════════════════════════════════ */
    stdout.printf ("\n── 22. 逐条钉住健康检查规则 ────────────────\n");

    if (sandboxed) {
        int rule_seq = 0;
        var created_rules = new GenericArray<string> ();

        // 在逗号分隔的规则 id 串里找某个 id（避免用 string.contains 这类
        // 会误配的写法：找 "E001" 时不能被 "E0011" 之类的命中）
        bool has_str22 (string ids, string want) {
            foreach (string part in ids.split (","))
                if (part.strip () == want)
                    return true;
            return false;
        }

        string ai22 = GLib.Path.build_filename (apps_dir, "Obsidian-1.5.3-x86_64.AppImage");
        var app22 = new AppEntry (ai22);
        app22.meta_name = "Perfect Entry";
        app22.categories = "Office;Utility;";

        // 写一个 .desktop，返回解析结果
        DesktopFiles.Entry? mk22 (string body) {
            string p = GLib.Path.build_filename (sandbox, "rule-%d.desktop".printf (rule_seq++));
            GLib.FileUtils.set_contents (p, body);
            var d = DesktopFiles.parse (p);
            if (d != null)
                created_rules.add (p);
            return d;
        }

        // 完美样本的各个片段，改哪一块就能单独触发一条规则

        /** 跑一次 check，返回命中的规则 id 串，便于精确断言 */
        string ids22 (string body) {
            var d = mk22 (body);
            if (d == null)
                return "<解析失败>";
            var r = RuleSet.check (d, app22);
            var l = new GenericArray<string> ();
            foreach (var pr in r.problems)
                l.add (pr.id);
            return string.joinv (",", l.steal ());
        }

        // 反向基准：完整样本必须零问题。有问题就说明规则误伤了正确写法。
        string icon22 = GLib.Path.build_filename (sandbox, "rule-icon.png");
        GLib.FileUtils.set_contents (icon22, "x");

        string base22 =
            "[Desktop Entry]\n"
            + "Type=Application\n"
            + "Version=1.5\n"
            + "Name=Perfect Entry\n"
            + "GenericName=Perfect\n"
            + "Comment=A perfectly well-formed desktop entry\n"
            + "Exec=\"" + ai22 + "\" %U\n"
            + "TryExec=" + ai22 + "\n"
            + "Icon=" + icon22 + "\n"
            + "Terminal=false\n"
            + "StartupNotify=true\n"
            + "StartupWMClass=Perfect Entry\n"
            + "Categories=Office;Utility;\n"
            + "X-AppImage-Manager=true\n"
            + "X-AppImage-Manager-Path=" + ai22 + "\n";

        string perfect_ids = ids22 (base22);
        check (ref checks, ref failures, "完美样本零问题（规则不能误伤正确写法）",
               perfect_ids == "", "误报了: " + perfect_ids);

        // 表驱动：坏法 → 必须命中的规则
        // （只断言「命中了」，不断言「只命中这一条」——规则之间有叠加关系）
        // 表驱动：坏法 → 必须命中的规则 id
        // 规则 id 的真实含义（逐条核对 rules.vala，别照字面猜）：
        //   D005=Type 缺失/错  E001=Version 越界  E002=Exec 缺失
        //   E005=Exec 里 % 未转义  E007=Name 缺失  E008=重复键
        //   I002=Categories  I003=StartupWMClass  I004=Comment
        //   I005=Terminal=true 但像 GUI  I007=NoDisplay  I010=TryExec
        //   C001=GenericName
        // 注意 Icon 必须指向真实存在的文件，否则会命中 I001「Icon 指向的
        // 文件不存在」—— 这条规则是对的，测试样本该满足它而不是绕开它。
        string[] case_bodies = {
            base22.replace ("Type=Application\n", "Type=Link\n"),
            base22.replace ("Version=1.5\n", "Version=2.0\n"),
            base22.replace ("Exec=\"" + ai22 + "\" %U\n", ""),
            base22.replace ("Exec=\"" + ai22 + "\" %U", "Exec=\"" + ai22 + " 100%\" %U"),
            base22.replace ("Name=Perfect Entry\n", ""),
            base22 + "Name=重复的名字\n",
            base22.replace ("Categories=Office;Utility;\n", ""),
            base22.replace ("StartupWMClass=Perfect Entry\n", ""),
            base22.replace ("Comment=A perfectly well-formed desktop entry\n", ""),
            base22.replace ("Terminal=false\n", "Terminal=true\n"),
            base22 + "NoDisplay=true\n",
            base22.replace ("TryExec=" + ai22 + "\n", ""),
            base22.replace ("GenericName=Perfect\n", ""),
        };
        string[] case_want = {
            "D005", "E001", "E002", "E005", "E007", "E008",
            "I002", "I003", "I004", "I005", "I007", "I010", "C001"
        };
        string[] case_what = {
            "Type 不是 Application → D005",
            "Version 越界 → E001",
            "Exec 缺失 → E002",
            "Exec 里 % 未转义 → E005",
            "Name 缺失 → E007",
            "重复键 → E008",
            "缺 Categories → I002",
            "缺 StartupWMClass → I003",
            "缺 Comment → I004",
            "Terminal=true 但像 GUI 应用 → I005",
            "NoDisplay=true → I007",
            "缺 TryExec → I010",
            "缺 GenericName → C001",
        };

        for (int i = 0; i < case_bodies.length; i++) {
            string body = case_bodies[i];
            string want = case_want[i];
            string what = case_what[i];
            string got = ids22 (body);

            if (want == "E00") {
                // Exec 缺失对应两条规则，只断言确实报出了 Exec 类问题
                bool hit = got.contains ("E003") || got.contains ("E004")
                        || got.contains ("E005") || got.contains ("E006");
                check (ref checks, ref failures, "规则命中：" + what, hit,
                       "命中的规则: " + (got == "" ? "（无）" : got));
            } else {
                check (ref checks, ref failures, "规则命中：" + what,
                       has_str22 (got, want),
                       "命中 %s，期望含 %s".printf (
                           got == "" ? "（无）" : got, want));
            }
        }

        // 终止规则：NoDisplay / Hidden 的那条必须要求确认，不能被自动应用
        var d22 = mk22 (base22 + "NoDisplay=true\n");
        if (d22 != null) {
            var r22 = RuleSet.check (d22, app22);
            bool found_nd = false;
            bool nd_confirm = false;
            foreach (var pr in r22.problems)
                if (pr.id == "I007") {
                    found_nd = true;
                    nd_confirm = pr.needs_confirm;
                }
            check (ref checks, ref failures, "NoDisplay 问题必须要求用户确认",
                   found_nd && nd_confirm,
                   "found=%s needs_confirm=%s".printf ((found_nd ? "yes" : "no"), (nd_confirm ? "yes" : "no")));
        }

        // 恢复类规则必须标记为可自动修，纯提示类必须不可自动修
        var d22b = mk22 (base22.replace ("Version=1.5\n", "Version=2.0\n"));
        if (d22b != null) {
            var r22b = RuleSet.check (d22b, app22);
            // 版本越界的规则 id 是 E001（E 系列才是 Exec/版本这类问题；
            // D 系列是文件级缺陷如 BOM、CRLF、组头缺失）。先前这里写成
            // D001 —— D001 根本没被命中，于是 ver_applyable 停在初值
            // false，看起来像「规则说不可自动修」，其实是找错了规则。
            bool ver_applyable = false;
            bool ver_found = false;
            foreach (var pr in r22b.problems)
                if (pr.id == "E001") {
                    ver_found = true;
                    ver_applyable = pr.applyable;
                }
            check (ref checks, ref failures, "Version 越界可自动修（钳回 1.5）",
                   ver_found && ver_applyable,
                   "found=%s applyable=%s".printf (ver_found ? "yes" : "no",
                                                   ver_applyable ? "yes" : "no"));
        }
        // GenericName 缺失属提示级（NOTICE）。查过 rules.vala：C001 没有把
        // applyable 置 false，也就是允许自动修 —— 补出来的值就是应用名。
        //
        // 值得留意：这是唯一一条「靠猜」却允许自动写盘的规则。用户没写
        // GenericName 通常是有意为之，自动补上等于替他做了决定。
        // 把「可自动修」这个现状显式钉住 —— 将来若有人改成需要确认，
        // 这条会失败并提醒同步更新文案，而不是让行为悄悄变化。
        var d22c = mk22 (base22.replace ("GenericName=Perfect\n", ""));
        if (d22c != null) {
            var r22c = RuleSet.check (d22c, app22);
            bool gen_found = false;
            bool gen_applyable = false;
            string gen_fixed = "";
            foreach (var pr in r22c.problems)
                if (pr.id == "C001") {
                    gen_found = true;
                    gen_applyable = pr.applyable;
                    gen_fixed = pr.fixed;
                }
            check (ref checks, ref failures, "缺 GenericName 会报出 C001",
                   gen_found, "C001 没被触发，规则本身可能有问题");
            check (ref checks, ref failures, "C001 当前允许自动修（钉住现状）",
                   !gen_found || gen_applyable,
                   "applyable 从 true 变成 false 了 —— 行为已变，同步更新断言与文案");
            check (ref checks, ref failures, "C001 给出的修法就是应用名",
                   !gen_found || gen_fixed.contains (app22.get_best_name ()),
                   "fixed=\"" + gen_fixed + "\"");
        }

        // 每个问题都要有可读的标题，否则界面会显示空白
        bool all_titled = true;
        // 必须先把结果存进本地变量再遍历。
        // 直接写 foreach (var pr in RuleSet.check(...).problems) 时，
        // 那个临时 Result 在 .problems 被取出后、循环体开始前就可能被释放，
        // 循环变量 pr 指向已释放内存，读 .id/.title 就段错误。
        // 与本项目踩过的「闭包捕获变量悬空」是同一类错误。
        var r_titles = RuleSet.check (d22b, app22);
        foreach (var pr in r_titles.problems)
            if (pr.title.strip () == "")
                all_titled = false;
        check (ref checks, ref failures, "每条问题都有可读标题",
               all_titled, "有空标题的问题");

        foreach (string p in created_rules)
            GLib.FileUtils.remove (p);
    }

    /* ══ 中英文界面 ═══════════════════════════════════════════════ */

    stdout.printf ("\n── N. 中英文界面 ─────────────────────────\n");

    // 中文模式必须恒等：整个自测里几百条断言直接比对中文字面量，
    // 只要 I18n.s 在中文下是恒等映射，它们一条都不用改。这条钉住它。
    var saved_lang = I18n.current;
    I18n.current = I18n.Lang.ZH;
    check (ref checks, ref failures, "中文模式恒等（不翻译）",
           I18n.s ("重新扫描") == "重新扫描", I18n.s ("重新扫描"));
    check (ref checks, ref failures, "中文模式对未收录串也恒等",
           I18n.s ("这句根本没进表") == "这句根本没进表", "");
    I18n.current = I18n.Lang.EN;

    check (ref checks, ref failures, "英文模式能查到译文",
           I18n.s ("重新扫描") == "Rescan",
           "实得「%s」".printf (I18n.s ("重新扫描")));

    // 漏翻必须退回中文，绝不能返回空串 —— 界面上出现空白比中英混杂更糟
    check (ref checks, ref failures, "漏翻退回中文而不是空串",
           I18n.s ("绝对没进表的测试串 XYZ") == "绝对没进表的测试串 XYZ", "");

    // 表本身的结构体检
    var tbl = I18n.all_entries ();
    check (ref checks, ref failures, "翻译表条数为偶数（成对存放）",
           tbl.length % 2 == 0, "%d 条".printf (tbl.length));
    check (ref checks, ref failures, "翻译表非空",
           tbl.length > 0, "%d 条".printf (tbl.length / 2));

    int no_zh = 0;
    int no_en = 0;
    int dup = 0;
    int placeholder_bad = 0;
    int dup_key = 0;
    var seen_keys = new GenericArray<string> ();
    for (uint i = 0; i + 1 < tbl.length; i += 2) {
        unowned string zh = tbl[i];
        unowned string en = tbl[i + 1];

        // 数的是「译文里还有汉字」和「译文是空的」这两种坏情况
        if (has_cjk (en))
            no_zh++;
        if (en.strip () == "")
            no_en++;

        if (has_str (seen_keys, zh)) {
            dup_key++;
        } else {
            seen_keys.add (zh);
        }

        // 占位符必须一一对应：个数不同 printf 会读越界，类型不同会打印乱码
        if (!same_placeholders (zh, en))
            placeholder_bad++;

        // 中文里不该出现 %n（格式串漏洞），译文里更不该
        if (en.contains ("%n"))
            dup++;
    }

    check (ref checks, ref failures, "译文全部不含中文", no_zh == 0,
           "%d 条译文里还有中文".printf (no_zh));
    check (ref checks, ref failures, "译文全部非空", no_en == 0,
           "%d 条译文是空的".printf (no_en));
    check (ref checks, ref failures, "翻译表没有重复的中文键", dup_key == 0,
           "%d 个键重复了".printf (dup_key));
    check (ref checks, ref failures, "译文不含 %n 格式串漏洞", dup == 0,
           "%d 条含 %%n".printf (dup));
    check (ref checks, ref failures, "译文占位符与中文一一对应",
           placeholder_bad == 0,
           "%d 条对不上".printf (placeholder_bad));

    // 覆盖率：源码里每个 I18n.s("中文") 都得在表里
    var missing = i18n_missing_keys ();
    check (ref checks, ref failures, "源码里每条 I18n.s 都有译文",
           missing.length == 0,
           missing.length == 0 ? "" : "漏 %d 条，例如「%s」"
                                 .printf (missing.length, missing[0]));

    // 兜底闸门：源码里每一条中文串，要么已包 I18n.s()，要么在豁免清单里。
    // 少了任何一边都说明有界面文案漏了翻译。
    var unwrapped = i18n_unwrapped ();
    check (ref checks, ref failures, "没有漏翻译的界面文案", unwrapped.length == 0,
           unwrapped.length == 0 ? ""
             : "%d 条漏了，例如「%s」".printf (unwrapped.length, unwrapped[0]));

    // 中英两侧的「控制字符结构」必须一致。
    //
    // 踩过的坑：生成翻译表时对英文多转义了一层，源码里中文写 \n（Vala 渲染成
    // 真换行）、英文写 \\n（渲染成字面的反斜杠+n）。结果是界面上直接显示
    // "…for AppImages,\nand create…" 这种东西。中文界面看着正常，只有切到
    // 英文才暴露 —— 63 条译文全中招，而当时所有断言都是绿的。
    //
    // 比的是换行/制表符/回车的**个数**，不是具体位置：英文语序可以调，
    // 但控制字符数量必须对得上，少一个就是转义写错了一层。
    int ctrl_mismatch = 0;
    string first_bad = "";
    for (uint i = 0; i + 1 < tbl.length; i += 2) {
        var a = count_control (tbl[i]);
        var b = count_control (tbl[i + 1]);
        if (a != b) {
            ctrl_mismatch++;
            if (first_bad == "")
                first_bad = "「%s」有 %d 个，译文有 %d 个".printf (
                    tbl[i].substring (0, int.min (24, tbl[i].length)), a, b);
        }
    }
    check (ref checks, ref failures, "中英控制字符数量一致（转义没写错层）",
           ctrl_mismatch == 0,
           ctrl_mismatch == 0 ? "" : "%d 条对不上，例如 %s".printf (
               ctrl_mismatch, first_bad));

    // 反向：表里有、源码里没人用的孤儿条目（提示清理，不算失败）
    var orphan = i18n_orphan_keys ();
    if (orphan.length > 0)
        stdout.printf ("  · 翻译表有 %d 条孤儿条目（代码里已不用）\n",
                       orphan.length);

    I18n.current = saved_lang;

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

/* ══════════════════════════════════════════════════════════════════
 *  中英文界面的自测辅助
 *  ══════════════════════════════════════════════════════════════════ */

/**
 * 字符串里有没有汉字。
 *
 * 用 \p{Han} 正则而不是手撸 UTF-8 解码：前者由 PCRE 的 Unicode 属性表
 * 兜底，连扩展区、生僻字（CJK 扩展 A/B）都算上；后者只能覆盖基本区，
 * 漏一个就是一个假阴性。
 */
/**
 * 字符串里有没有汉字（U+4E00–U+9FFF 基本区）。
 *
 * 自己按 UTF-8 三字节序列解码，不用 \p{Han}：实测这套 GRegex 没启用
 * Unicode 属性表，\p{Han} 连中间的「·」(U+00B7) 都会命中，误报一片。
 */
bool has_cjk (string s) {
    for (int i = 0; i + 2 < s.length; i++) {
        uint b0 = (uint8) s[i];
        uint b1 = (uint8) s[i + 1];
        uint b2 = (uint8) s[i + 2];
        if (b0 < 0xE4 || b0 > 0xE9)
            continue;
        if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80)
            continue;
        uint cp = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F);
        if (cp >= 0x4E00 && cp <= 0x9FFF)
            return true;
    }
    return false;
}

/**
 * 取出字符串里所有 printf 占位符的**转换符**。
 *
 * 只留转换符那一段：宽度（%10s）和长度修饰（%lld）允许译文改，但转换符
 * 和出现次数不能变 —— 次数变了对不上参数，类型变了会按错误的长度从栈上
 * 取值，都能崩。
 *
 * 用正则而不是手写扫描状态机：手写那版在多字节字符串上 substring 越界
 * （g_strsubstr 的 offset+len 断言炸过），而且「完成度 100%」这种普通
 * 百分号很容易被误判成占位符。
 */
string[] placeholders (string s) {
    var rx = new GLib.Regex (
        "%[-+ #0]*[0-9*]*(?:\\.[0-9*]+)?(?:hh|h|ll|l|j|z|t)?([diouxXeEfFgGaAcspn])");
    var misses = new GenericArray<string> ();
    GLib.MatchInfo? mi = null;
    if (!rx.match (s, 0, out mi) || mi == null)
        return new string[0];
    while (mi.matches ()) {
        int b0 = 0, b1 = 0;
        if (mi.fetch_pos (1, out b0, out b1))
            misses.add (mi.fetch (1).dup ());
        try {
            if (!mi.next ())
                break;
        } catch (GLib.RegexError e) {
            break;
        }
    }
    return misses.steal ();
}

/**
 * 占位符是否一一对应。
 *
 * 比的是**多重集**不是顺序：译文完全可以在英文语序里把 "%s ... %d"
 * 调成 "%d ... %s"，只要参数按同样顺序传给 printf 就完全正确。
 * 按位置逐个比会把这种合法改写误判成不匹配。
 */
bool same_placeholders (string zh, string en) {
    var a = placeholders (zh);
    var b = placeholders (en);
    if (a.length != b.length)
        return false;

    string kinds = "diouxXeEfFgGaAcspn";
    for (int i = 0; i < kinds.length; i++) {
        string key = kinds.substring (i, i + 1).dup ();
        int ca = 0, cb = 0;
        for (uint k = 0; k < a.length; k++) if (a[k] == key) ca++;
        for (uint k = 0; k < b.length; k++) if (b[k] == key) cb++;
        if (ca != cb)
            return false;
    }
    return true;
}


/**
 * 豁免清单：这些中文字面量是**故意不翻译**的。
 *
 * 两类：
 *   1. 拿中文字面量做比较判断 —— pill.vala 用 has_prefix("失效") 决定药丸
 *      颜色。翻成英文的话，英文界面下所有药丸会挤成同一种颜色。
 *   2. 规则元数据的常量 —— rules.vala 的 SEV_* 是严重级别的规范名，
 *      保持中文才能和自测里的断言对上；只在 severity_label() 出口翻译。
 *
 * 这份清单同时是**兜底闸门**：下面那条断言要求「源码里的中文串，要么包了
 * I18n.s()，要么在这份清单里」。以后有人新加一条中文界面文案忘了翻译，
 * 自测立刻红 —— 否则英文用户会看到一半中文一半英文。
 */
private static string[] i18n_exempt () {
    return new string[] {
        "严重",
        "健康",
        "可优化",
        "外部",
        "失效",
        "已创建",
        "损坏",
        "提示",
        "新发现",
        "警告",
    };
}

/** 真正的字符串值 → 源码里的 Vala 字面量形态（用于反查源码） */
string escape_vala (string s) {
    return s.replace ("\\", "\\\\").replace ("\n", "\\n")
            .replace ("\t", "\\t").replace ("\r", "\\r");
}

/** 源码里的 Vala 字符串字面量 → 真正的字符串值 */
string unescape_vala (string s) {
    var b = new GLib.StringBuilder ();
    int i = 0;
    while (i < s.length) {
        if (s[i] == '\\' && i + 1 < s.length) {
            char c = s[i + 1];
            if (c == 'n') { b.append_c ('\n'); i += 2; continue; }
            if (c == 't') { b.append_c ('\t'); i += 2; continue; }
            // \r 也要处理：漏了它，含 \r\n 的条目会被算成「没进表」
            if (c == 'r') { b.append_c ('\r'); i += 2; continue; }
            if (c == '"' || c == '\\') { b.append_c (c); i += 2; continue; }
        }
        b.append_c (s[i]);
        i++;
    }
    return b.str;
}

/** 找到 src 目录（自测可能在项目根或 tests/ 下跑） */
string find_src_dir () {
    foreach (var cand in new string[] { "src", "../src" }) {
        if (GLib.FileUtils.test (cand + "/i18n.vala", GLib.FileTest.EXISTS))
            return cand;
    }
    return "";
}

/**
 * 扫源码，找出所有 I18n.s ("中文") 里没进翻译表的那些。
 *
 * 这是防止「以后有人加了个新按钮忘了加英文」的唯一手段 ——
 * 界面显示成中文虽然不崩，但英文用户会看到一半中文一半英文。
 */
string[] i18n_missing_keys () {
    var misses = new GenericArray<string> ();
    string src_dir = find_src_dir ();
    if (src_dir == "")
        return misses.steal ();

    var rx = new GLib.Regex ("I18n\\.s\\s*\\(\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
    var d = GLib.Dir.open (src_dir);
    if (d == null)
        return misses.steal ();

    string? name;
    while ((name = d.read_name ()) != null) {
        if (!name.has_suffix (".vala") || name == "i18n.vala")
            continue;
        string text;
        try {
            GLib.FileUtils.get_contents (src_dir + "/" + name, out text);
        } catch {
            continue;
        }
        GLib.MatchInfo? mi;
        if (!rx.match (text, 0, out mi) || mi == null)
            continue;
        while (mi.matches ()) {
            int b0 = 0, b1 = 0;
            if (mi.fetch_pos (1, out b0, out b1)) {
                string key = unescape_vala (mi.fetch (1));
                // 翻译的 key 必须确实是中文；纯英文（比如 "Reset"）不需要译文
                if (key != "" && has_cjk (key) && !T_has (key) && !has_str (misses, key))
                    misses.add (key);
            }
            try {
                if (!mi.next ())
                    break;
            } catch (GLib.RegexError e) {
                break;
            }
        }
    }
    return misses.steal ();
}

bool T_has (string key) {
    var tbl = I18n.all_entries ();
    for (uint i = 0; i + 1 < tbl.length; i += 2)
        if (tbl[i] == key)
            return true;
    return false;
}

/** 翻译表里有、但源码里已经没人调用的条目 */
string[] i18n_orphan_keys () {
    var misses = new GenericArray<string> ();
    var tbl = I18n.all_entries ();
    string src_dir = find_src_dir ();
    if (src_dir == "")
        return misses.steal ();

    string all = "";
    var d = GLib.Dir.open (src_dir);
    if (d == null)
        return misses.steal ();
    string? name;
    while ((name = d.read_name ()) != null) {
        if (!name.has_suffix (".vala") || name == "i18n.vala")
            continue;
        try {
            string chunk;
            GLib.FileUtils.get_contents (src_dir + "/" + name, out chunk);
            all += chunk;
        } catch {
            continue;
        }
    }

    // 匹配的是**源码里的字面量形态**（含 \n \t 等转义），不是运行时值。
    // 拿运行时值去 index_of 源码字符串，含转义的条目会全部误判成孤儿。
    for (uint i = 0; i + 1 < tbl.length; i += 2) {
        string zh = tbl[i];
        if (all.index_of ("\"" + escape_vala (zh) + "\"") < 0)
            misses.add (zh);
    }
    return misses.steal ();
}

/**
 * 扫源码找出「没包 I18n.s()、又不在豁免清单里」的中文字面量。
 *
 * 做法：先把 I18n.s(...) 整段挖掉，再在剩下的文本里找中文字面量 ——
 * 比逐个判断调用点可靠，也不会漏掉多行调用里落在续行上的参数。
 */
string[] i18n_unwrapped () {
    var leaked = new GenericArray<string> ();
    string src_dir = find_src_dir ();
    if (src_dir == "")
        return leaked.steal ();

    var exempt = i18n_exempt ();
    string lit = "\"((?:[^\"\\\\]|\\\\.)*)\"";
    var rx_any     = new GLib.Regex ("[\\u4e00-\\u9fff]");
    var rx_lit     = new GLib.Regex (lit);
    var rx_wrapped = new GLib.Regex ("I18n\\.s\\s*\\(\\s*" + lit);

    var d = GLib.Dir.open (src_dir);
    if (d == null)
        return leaked.steal ();

    string? name;
    while ((name = d.read_name ()) != null) {
        if (!name.has_suffix (".vala") || name == "i18n.vala")
            continue;

        string text;
        try {
            GLib.FileUtils.get_contents (src_dir + "/" + name, out text);
        } catch {
            continue;
        }

        var sb = new GLib.StringBuilder ();
        GLib.MatchInfo? mi = null;
        if (rx_wrapped.match (text, 0, out mi) && mi != null) {
            int pos = 0;
            while (mi.matches ()) {
                int e0 = 0, e1 = 0;
                if (mi.fetch_pos (0, out e0, out e1)) {
                    sb.append (text.substring (pos, e0));
                    pos = e1;
                }
                try {
                    if (!mi.next ())
                        break;
                } catch (GLib.RegexError e) {
                    break;
                }
            }
            sb.append (text.substring (pos));
        } else {
            sb.append (text);
        }

        GLib.MatchInfo? m2 = null;
        if (!rx_lit.match (sb.str, 0, out m2) || m2 == null)
            continue;
        while (m2.matches ()) {
            int a = 0, b = 0;
            if (m2.fetch_pos (0, out a, out b)) {
                string raw = m2.fetch (0);
                if (rx_any.match (raw)) {
                    string val = unescape_vala (raw.substring (1, raw.length - 1));
                    bool ok = false;
                    foreach (var e in exempt)
                        if (e == val) { ok = true; break; }
                    if (!ok && !has_str (leaked, val))
                        leaked.add (val);
                }
            }
            try {
                if (!m2.next ())
                    break;
            } catch (GLib.RegexError e) {
                break;
            }
        }
    }
    return leaked.steal ();
}

/** 字符串里换行/制表/回车的总数 —— 用来比对中英两侧的转义结构 */
int count_control (string s) {
    int n = 0;
    for (int i = 0; i < s.length; i++) {
        char c = s[i];
        if (c == '\n' || c == '\t' || c == '\r')
            n++;
    }
    return n;
}
