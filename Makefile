PREFIX      ?= /usr/local
BINDIR      ?= $(PREFIX)/bin
DATADIR     ?= $(PREFIX)/share
DESTDIR     ?=

VALAC       ?= valac
PKGS        := gtk+-3.0 gdk-pixbuf-2.0 gio-2.0 json-glib-1.0
PKG_FLAGS   := $(addprefix --pkg ,$(PKGS))
PKG_CFLAGS  := $(shell pkg-config --cflags $(PKGS))
PKG_LIBS    := $(shell pkg-config --libs $(PKGS))
# pkg-config 的 vapidir 变量在 Debian 打包里常为空，
# 这里直接用 valac 的默认搜索路径，只在需要覆盖时才指定
VAPIDIR     ?=
CC          ?= gcc
VERSION     ?= 1.0.0

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

.PHONY: all clean install uninstall run valac

all: $(BIN)

$(BIN): $(OBJS)
	$(CC) -o $@ $(OBJS) $(PKG_LIBS) -lm

src/%.o: src/%.c
	$(CC) -c -o $@ $< $(PKG_CFLAGS) -Wno-deprecated-declarations

# Vala 编译器需要一次看到全部源文件才能解析跨文件类型，
# 因此统一生成后再分发到各目标
$(VALA_C): $(SOURCES)
	$(VALAC) $(VALAFLAGS) -C $(SOURCES)

valac:
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