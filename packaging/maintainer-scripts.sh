#!/bin/sh
#
# packaging/maintainer-scripts.sh — deb / rpm / archlinux 共用的维护脚本
#
# deb 会把它装成 postinst / prerm / postrm，rpm 会把它嵌成
# %post / %preun / %postun / %posttrans，pacman 会把它包进 .INSTALL 的
# post_install / pre_remove / post_remove / post_upgrade 函数。
# 四个阶段跑的是同一段内容，因为「刷新缓存」这件事在装完之后和卸完之后
# 都是对的 —— 没有需要按参数分派的分支，也就不需要拆成四个文件。
#
# 三条铁律，改动前先读完：
#
#   1. 绝对不要写 set -e。
#      pacman 是用 bash 把整个 .INSTALL 文件 source 进去执行的，
#      函数体里一旦 set -e，任何一条命令失败都会把 pacman 自己那套
#      收尾逻辑一起带走，表现为「卸载报了个看不懂的错」。
#   2. 永远以 exit 0 收尾。
#      刷新缓存失败绝不该让 dpkg / rpm 认为这个包装不上。
#      缓存只是加速手段：最坏情况是这次菜单里没立刻出现新图标，
#      下次开机或者手工刷新就有了，代价远小于「包配置失败」这个结果。
#   3. 工具可能不存在。极简容器、精简安装、chroot 里都可能缺，
#      所以每个外部命令都先 command -v 探测再用。
#
# 这里是 POSIX sh，不是 bash：dpkg 用 sh 跑维护脚本，rpm 的 scriptlet
# 也只用 sh，pacman 虽然用 bash 但没必要在这里用到 bash 特性。

# ── 1. 菜单数据库 ───────────────────────────────────────────────────
#
# /usr/share/applications/appimage-manager.desktop 是包带来的，
# 装完得让 update-desktop-database 重扫一次，桌面菜单才能马上看到入口。
# deb 那边还挂了 interest-noawait 的 dpkg trigger（见 nfpm.yaml），
# 这里再跑一次不是重复劳动：一是用 --no-triggers 装包时 trigger 不会执行，
# 二是从 rpm / arch 装过来时根本没有 deb trigger。
# -q 是静默模式，刷不出来也别刷屏。
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
fi

# ── 2. hicolor 图标缓存 ─────────────────────────────────────────────
#
# .desktop 里写的是 Icon=appimage-manager（按名字查主题，不写死路径），
# 所以图标必须进 hicolor 的索引缓存 GTK 才认得出来。
# -f 强制重建（装了新图必须重建，光更新索引不够），-t 只扫 theme 文件。
# 目录不存在就跳过：图标可能因为被用户删掉而不在了，这时候没什么可重建的。
if [ -d /usr/share/icons/hicolor ] && command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -f -t /usr/share/icons/hicolor || true
fi

# 关于 ldconfig：这里刻意**不**调用。
# 本包只装一个可执行文件，不装任何 .so，ldconfig 刷出来的缓存和本包无关；
# 依赖的 libgtk-3.so.0 之类本来就在系统缓存里。
# 无条件加 ldconfig 是从别的包的 postinst 抄来的习惯，
# 代价是每次装卸都白跑几十毫秒，收益是零。
# 真正需要它的是「本包往 /usr/lib 放了新库」的情况 —— 那是另一个包。

exit 0
