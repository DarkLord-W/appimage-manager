# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 DarkLord-W

PREFIX      ?= /usr/local
BINDIR      ?= $(PREFIX)/bin
DATADIR     ?= $(PREFIX)/share
DESTDIR     ?=

VALAC       ?= valac
PKGS        := gtk+-3.0 gdk-pixbuf-2.0 pangocairo gio-2.0 json-glib-1.0
PKG_FLAGS   := $(addprefix --pkg ,$(PKGS))
PKG_CFLAGS  := $(shell pkg-config --cflags $(PKGS))
PKG_LIBS    := $(shell pkg-config --libs $(PKGS))
# pkg-config 的 vapidir 变量在 Debian 打包里常为空，
# 这里直接用 valac 的默认搜索路径，只在需要覆盖时才指定
VAPIDIR     ?=
CC          ?= gcc
VERSION     ?= 1.1.0

# 发行版的打包工具都是通过**环境变量**注入编译参数的，这里必须让它们生效，
# 否则打包出来会静默地少掉加固和调试信息：
#
#   LDFLAGS  makepkg.conf 里带 `-Wl,-z,relro,-z,now`（全量 RELRO）。
#            不接的话 namcap 会报 "lacks FULL RELRO" —— 本项目包里确实没有，
#            不是误报。Debian 的 dh、rpm 的 %build 是同一套做法。
#   CFLAGS   带 -g。不接的话 makepkg 生成的 -debug 包是**空的**，还带一个
#            指向不存在文件的符号链接（namcap 报 E: Symlink points to
#            non-existing）。那不是 namcap 挑刺，是包真的坏了。
#
# 用 ?= 而不是 =：环境里已经有值就不覆盖（这正是打包工具要的）。
# 直接 `make` 的人拿下面的默认值。
CFLAGS      ?= -O2
LDFLAGS     ?=

SOURCES := $(sort $(wildcard src/*.vala))
VALA_C  := $(SOURCES:.vala=.c)
OBJS    := $(SOURCES:.vala=.o)
DEPS    := $(OBJS:.o=.d)
BIN     := appimage-manager

ICON    := data/appimage-manager.png

VALAFLAGS := $(PKG_FLAGS) \
             $(if $(VAPIDIR),--vapidir=$(VAPIDIR),) \
             --target-glib=2.76 \
             --enable-deprecated \
             --disable-warnings

.PHONY: all clean install uninstall run valac test selftest appimage

all: $(BIN)

$(BIN): $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $(OBJS) $(PKG_LIBS) -lm

src/%.o: src/%.c
	$(CC) $(CFLAGS) -c -o $@ $< $(PKG_CFLAGS) -Wno-deprecated-declarations

# Vala 编译器需要一次看到全部源文件才能解析跨文件类型。
# 用 stamp 文件避免「多目标规则」被 make 展开成 N 次调用。
VALA_STAMP := .vala-stamp

$(VALA_STAMP): $(SOURCES)
	$(VALAC) $(VALAFLAGS) -C $(SOURCES)
	@touch $@

$(VALA_C): $(VALA_STAMP)
	@:

valac:
	$(VALAC) $(VALAFLAGS) -C $(SOURCES)

run: $(BIN)
	./$(BIN)

# ── 自测 ─────────────────────────────────────────────────────────────
# 核心引擎的独立测试程序，不依赖 GUI。
# 直接编译引擎的 .vala 源（排除 GUI 入口与对话框），
# 这样引擎的正确性可以脱离界面单独验证。
ENGINE_VALA := $(filter-out src/main.vala src/window.vala src/dialogs.vala \
                               src/menubar.vala src/wizard.vala,$(SOURCES))
SELFTEST_BIN := appimage-manager-selftest

$(SELFTEST_BIN): tests/selftest.vala $(ENGINE_VALA)
	$(VALAC) $(VALAFLAGS) -X -lm -o $@ $^

selftest: $(SELFTEST_BIN)
	@if [ ! -d /tmp/appmgr-fixtures/apps ]; then \
	    echo "生成测试夹具…"; \
	    tests/make-fixtures.sh; \
	fi
	rm -rf /tmp/appmgr-sandbox && mkdir -p /tmp/appmgr-sandbox
	XDG_DATA_HOME=/tmp/appmgr-sandbox XDG_CONFIG_HOME=/tmp/appmgr-sandbox/cfg \
	    ./$(SELFTEST_BIN) /tmp/appmgr-fixtures

test: selftest

# ── 安装 ─────────────────────────────────────────────────────────────
install: $(BIN)
	install -d $(DESTDIR)$(BINDIR)
	install -m 0755 $(BIN) $(DESTDIR)$(BINDIR)/$(BIN)
	install -d $(DESTDIR)$(DATADIR)/applications
	sed -e 's|@PREFIX@|$(PREFIX)|g' data/appimage-manager.desktop.in \
	    > $(DESTDIR)$(DATADIR)/applications/appimage-manager.desktop
	chmod 0644 $(DESTDIR)$(DATADIR)/applications/appimage-manager.desktop
	install -d $(DESTDIR)$(DATADIR)/appimage-manager
	install -m 0644 data/style.css $(DESTDIR)$(DATADIR)/appimage-manager/style.css
	@if [ -f $(ICON) ]; then \
	    install -d $(DESTDIR)$(DATADIR)/icons/hicolor/256x256/apps; \
	    install -m 0644 $(ICON) $(DESTDIR)$(DATADIR)/icons/hicolor/256x256/apps/; \
	fi
	# 许可证全文。GPL 要求分发二进制时附带，各发行版也都要求装到
	# 这个位置（deb 的 debian/copyright 之外还有它，Arch 的
	# /usr/share/licenses/<pkgname>/，rpm 的 %license）。
	# 放在 make install 里而不是各打包配置里各写一遍 —— 这一处改了，
	# deb / rpm / arch / AppImage / tar.gz 五种产物一起就有了。
	install -d $(DESTDIR)$(DATADIR)/licenses/appimage-manager
	install -m 0644 LICENSE $(DESTDIR)$(DATADIR)/licenses/appimage-manager/LICENSE
	gtk-update-icon-cache -f -t $(DESTDIR)$(DATADIR)/icons/hicolor 2>/dev/null || true
	update-desktop-database $(DESTDIR)$(DATADIR)/applications 2>/dev/null || true

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(BIN)
	rm -f $(DESTDIR)$(DATADIR)/applications/appimage-manager.desktop
	rm -f $(DESTDIR)$(DATADIR)/appimage-manager/style.css
	rmdir --ignore-fail-on-non-empty $(DESTDIR)$(DATADIR)/appimage-manager 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/icons/hicolor/256x256/apps/appimage-manager.png
	rm -f $(DESTDIR)$(DATADIR)/licenses/appimage-manager/LICENSE
	rmdir --ignore-fail-on-non-empty $(DESTDIR)$(DATADIR)/licenses/appimage-manager 2>/dev/null || true

# ── AppImage ─────────────────────────────────────────────────────────
# 无网络、无 appimagetool：脚本手工拼「runtime + squashfs」。
# runtime 依次取 $RUNTIME、runtime/ 缓存，否则从现成 AppImage 抽取。
appimage: $(BIN)
	VERSION='$(VERSION)' bash scripts/make-appimage.sh

clean:
	@rm -f $(SELFTEST_BIN) $(VALA_STAMP)
	rm -f $(VALA_C) $(OBJS) $(DEPS) $(BIN)

-include $(DEPS)