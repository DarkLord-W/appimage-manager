PREFIX      ?= /usr/local
BINDIR      ?= $(PREFIX)/bin
DATADIR     ?= $(PREFIX)/share
DESTDIR     ?=

VALAC       ?= valac
PKGS        := gtk+-3.0 gio-2.0 glib-2.0
VAPIDIR     := $(shell pkg-config --variable=vapidir gtk+-3.0)
CC          ?= gcc

SOURCES := $(wildcard src/*.vala)
VALA_C  := $(SOURCES:.vala=.c)
OBJS    := $(SOURCES:.vala=.o)
DEPS    := $(OBJS:.o=.d)
BIN     := appimage-manager

CSS     := data/style.css
ICON    := data/appimage-manager.png

# 编译期固定的应用目录，供路径解析模块使用
VALAFLAGS := --pkg $(PKGS) \
             --vapidir=$(VAPIDIR) \
             --target-glib=2.76 \
             --enable-deprecated \
             -X -DAPPMGR_VERSION=\"$(VERSION)\" \
             -X -DAPPMGR_PREFIX=\"$(PREFIX)\" \
             --disable-warnings

.PHONY: all build clean install uninstall run valac

all: $(BIN)

$(BIN): $(OBJS)
	$(CC) -o $@ $(OBJS) $(shell pkg-config --libs $(PKGS)) -lm

src/%.o: src/%.c
	$(CC) -c -o $@ $< $(shell pkg-config --cflags $(PKGS)) -Wno-deprecated-declarations

src/%.c: src/%.vala
	$(VALAC) $(VALAFLAGS) -D $(PKGS) -C $< -o $@

valac:            # 只重新生成 C，保留 .c 以便调试
	$(VALAC) $(VALAFLAGS) -C $(SOURCES)

run: $(BIN)
	./$(BIN)

install: $(BIN)
	install -d $(DESTDIR)$(BINDIR)
	install -m 0755 $(BIN) $(DESTDIR)$(BINDIR)/$(BIN)
	install -d $(DESTDIR)$(DATADIR)/applications
	sed -e 's|@PREFIX@|$(PREFIX)|g' data/appimage-manager.desktop.in \
	    > $(DESTDIR)$(DATADIR)/applications/appimage-manager.desktop
	chmod 0644 $(DESTDIR)$(DATADIR)/applications/appimage-manager.desktop
	@if [ -f $(ICON) ]; then \
	    install -d $(DESTDIR)$(DATADIR)/icons/hicolor/256x256/apps; \
	    install -m 0644 $(ICON) $(DESTDIR)$(DATADIR)/icons/hicolor/256x256/apps/; \
	fi
	gtk-update-icon-cache -f -t $(DESTDIR)$(DATADIR)/icons/hicolor 2>/dev/null || true

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(BIN)
	rm -f $(DESTDIR)$(DATADIR)/applications/appimage-manager.desktop
	rm -f $(DESTDIR)$(DATADIR)/icons/hicolor/256x256/apps/appimage-manager.png

clean:
	rm -f $(VALA_C) $(OBJS) $(DEPS) $(BIN)

-include $(DEPS)