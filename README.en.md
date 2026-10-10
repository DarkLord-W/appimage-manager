# AppImage Manager

> **Language**: [English](README.en.md) · [简体中文](README.md)

A desktop integration manager for AppImage, written in **Vala + GTK3**. It scans
the directories you point it at, turns your AppImages into proper `.desktop`
launchers, and keeps those launchers healthy over time.

The build product is a **single native binary** — copy it to any Linux box with
GTK3 installed and run it.

## Download

| Format | Who it's for |
|---|---|
| `AppImage-Manager-*-x86_64.AppImage` | No install — `chmod +x` and double-click |
| `appimage-manager-*-linux-x86_64.tar.gz` | No install, but you want it in the app menu |
| `appimage-manager_*_amd64.deb` | Debian / Ubuntu / Kali / Mint |
| `appimage-manager-*.x86_64.rpm` | Fedora / RHEL / openSUSE |
| `appimage-manager-*.pkg.tar.zst` | Arch / Manjaro |

Grab them from [Releases](https://github.com/DarkLord-W/appimage-manager/releases).

The native binary and the AppImage both **depend on your system GTK3** (every
desktop distro ships it). With the deb / rpm / arch packages the dependency is
declared and pulled in automatically.

---

## Screenshots

### Main window

![Main window](docs/screenshots/main-window.en.png)

Eleven AppImages with four states visible at a glance: yellow `New` (no
launcher yet), orange `Optimizable` (launcher has problems — the badge shows how
many), blue `External` (created by something else; this tool leaves it alone),
and green `Created` (managed by this tool).

### Create launcher

![Create launcher dialog](docs/screenshots/create-dialog.en.png)

Fill in the fields at the top and the panel below shows a **live preview of the
exact `.desktop` file that will be written** — you know what you're getting
before you commit.

### Repair

![Repair dialog](docs/screenshots/repair-dialog.en.png)

Every problem is listed with the rule it hit and the suggested fix. Conservative
mode touches only what's broken; the fuller modes clean up redundant keys too.

### Context menu

![Context menu](docs/screenshots/context-menu.en.png)

Per-item actions live here, with zero overlap against the always-visible action
bar (which is for batch operations).

### Interface languages

Every user-facing string is translatable — there is no half-Chinese,
half-English state. Switch from the `Language` menu; on first run the app
follows your system locale.

| English | 简体中文 |
|---|---|
| ![English UI](docs/screenshots/main-window.en.png) | ![Chinese UI](docs/screenshots/main-window.png) |

<details>
<summary>The other dialogs in Chinese</summary>

| | English | 简体中文 |
|---|---|---|
| Create | ![](docs/screenshots/create-dialog.en.png) | ![](docs/screenshots/create-dialog.png) |
| Repair | ![](docs/screenshots/repair-dialog.en.png) | ![](docs/screenshots/repair-dialog.png) |
| Context menu | ![](docs/screenshots/context-menu.en.png) | ![](docs/screenshots/context-menu.png) |

</details>

---

## Features

### Scanning
- Multiple scan directories, recursive into subdirectories
- Extension pre-filter plus **dual validation on the ELF magic and the AppImage
  `AI` magic** — a random file renamed to `.AppImage` is rejected
- Scan results are matched against existing entries in
  `~/.local/share/applications`

### Creating launchers
- Pulls real metadata out of the AppImage itself: `Name` / `Comment` /
  `Categories` / `StartupWMClass` / `MimeType`
- Extracts the embedded icon (`.DirIcon` first, then the largest png/svg),
  scales it and caches it under `hicolor`
- The `Exec` field is **fully escaped** per the XDG spec (quotes around paths
  with spaces, literal `%` becomes `%%`, shell metacharacters escaped)
- Validated with `desktop-file-validate` before writing; a failed validation
  rolls back
- Atomic writes (temp file + `fsync` + `rename`), so the desktop environment
  can never read a half-written file

### Health checks (28 rules)
Existing `.desktop` files get a checkup, graded in four severity levels:

| Level | Examples |
|---|---|
| 🔴 Fatal | Missing `[Desktop Entry]` group header, UTF-8 BOM, CRLF line endings, invalid encoding bytes |
| 🔴 Critical | `Version=` out of range, unescaped `Exec=`, `Exec=` pointing at a missing file, wrong `Type=`, duplicate keys, dangling `Actions=` reference |
| 🟡 Warning | Missing `Icon=`, missing `Categories=`, missing `StartupWMClass=`, `Terminal=true`, non-standard filename |
| ⚪ Notice | Missing `GenericName=`, missing `TryExec=`, not managed by this tool |

### Repair (three modes)
- **Conservative** — fix only what is definitely broken; not one byte of an
  existing field is touched
- **Complete** — conservative plus filling in missing standard fields (only
  adds, never overwrites)
- **Rebuild** — replace wholesale using the AppImage's metadata; custom fields
  must be individually ticked to be preserved

Every problem shows its "current value / fixed value", and there is a unified
diff preview before anything is written.

### Interface languages

- The `Language(L)` menu offers three choices: follow the system, 简体中文, or
  English
- First run **follows the system locale** — if `LANG`/`LC_MESSAGES` isn't
  `zh*` you get English, so users outside China don't have to go hunting through
  a menu first
- Switching shows an infobar with a **Restart Now** button that takes effect in
  one click. The restart re-execs in place (`execv`), so the GApplication
  single-instance name is never released — no "clicked it and nothing happened",
  no two copies running at once
- 570 strings live in a table inside `src/i18n.vala`, **compiled into the
  binary**. No gettext / `.po` dependency, so CI and all three distro packages
  need nothing extra installed
- A missing translation **falls back to Chinese rather than rendering blank** —
  there is never an empty cell in the UI
- GTK's own widgets (file chooser, colour chooser) follow along too: `LANGUAGE`
  is set before GTK initialises, otherwise you get the jarring combination of a
  Chinese interface popping up an English file dialog — which is exactly what
  happened in testing
- Two self-test gates guard this: translated placeholders must match the Chinese
  one-for-one (this is what prevents a `printf` overrun), and every Chinese
  string in the source must either be wrapped in `I18n.s()` or be on an explicit
  exempt list. Add a Chinese UI string and forget to translate it, and the
  self-test goes red immediately

### Working backwards
- Delete a launcher (backed up first)
- Edit `Name` / `Comment` / `Categories` / `Exec` / `Icon`
- **Claim**: bring a third-party or hand-written `.desktop` under management by
  appending only the `X-AppImage-Manager-*` marker keys — nothing else changes
- **Fill in from embedded metadata**: unpack the AppImage and read the real
  name / comment / categories / icon from the `.desktop` inside it, then update
  the existing launcher. Only fields the AppImage actually specifies are
  replaced, and only the lines whose values genuinely changed are rewritten —
  comments, blank lines, original spacing such as `Name = Foo`, and
  `[Desktop Action …]` groups are all preserved byte-for-byte. Everything is
  backed up and recorded in a transaction first, so it can be restored from
  Repair History at any time
- Broken and orphaned launcher cleanup

### Fidelity rules

Any operation that rewrites a user's `.desktop` file (claim, repair, fill-in)
touches **only the lines it has confirmed it needs to change**; the rest is
preserved byte-for-byte:

- Comments and blank lines are left alone
- Non-standard spacing like `Name = Foo` is not "normalized"
- Extra groups such as `[Desktop Action …]` survive intact
- Idempotent: running the same operation twice does not stack up duplicates

The naive "parse into key/value pairs, then serialize the whole thing" route
eats all of that — claim a carefully hand-written launcher and you'd lose the
comments and the whole action group, directly contradicting the promise of
"append two marker lines". So these operations go through byte-level insertion
and minimal line-level rewriting instead.

### Transactions and rollback
- Two-phase commit (WAL); every step is traceable
- Crash recovery: unfinished transactions are detected on startup and can be
  rolled back in one click
- Append-only repair history — anything can be restored at any time
- Retention policy (30 days / 200 transactions by default)

---

## Layout

```
┌ Native title bar (drawn by the window manager) ─────────────────────┐
├ File(F)  Edit(E)  View(V)  Tools(T)  Language(L)  Help(H) ───────────┤
├ [⟳ Rescan]  [🔍 Search…]           3 directories · 12 AppImages … ───┤
├ 📁 ~/Applications ✕   📁 /opt/apps ✕              [+ Add Directory] ┤
├ [All▾] ☐Select All 3 selected │ +Create ⚙Repair 🔗Claim ⛶Icon −Delete ┤
├ List ───────────────────────────────────────────────────────────────┤
│  ☐ │ 🖼 │ Name │ Size │ Status │ Path                                │
│                                                       ┌──────────┐  │
│                                                       │✎Edit ▶Test│  │
│                                                       │📁Dir ⧉Copy│  │
│                                                       └──────────┘  │
├ InfoBar ────────────────────────────────────────────────────────────┤
```

It uses the **native window title bar** rather than drawing its own — a custom
title bar tends to render minimize/maximize as blank circles under third-party
GTK themes; handing it to the window manager avoids that entirely.

### Menus

| Menu | Items |
|---|---|
| File | Add scan directory `Ctrl+D` · Open launcher directory · Open config directory · Quit `Ctrl+Q` |
| Edit | Select all `Ctrl+A` · Deselect · Create launcher `Ctrl+N` · Repair selected · Claim · Delete `Delete` |
| View | Rescan `F5` · Filter (All / New / Created / External / Broken / Optimizable) · Maximize `F11` |
| Tools | Health check · Repair history · Broken and orphan cleanup · Fill selected launchers from embedded metadata · Settings `Ctrl+,` |
| Language | Follow system · 简体中文 · English |
| Help | Keyboard shortcuts `F1` · About |

### Three ways in

| Entry point | Scope | When it appears |
|---|---|---|
| **Persistent action bar** | Batch (create/repair/claim/icon/delete) | Always visible |
| **Floating action bar** | Single item (edit/test/open dir/copy path) | When a row is selected |
| **Context menu** | All 8 items | Right-click any row |

Target selection rule: **ticked items win; with nothing ticked it falls back to
the selected row**. Buttons enable and disable dynamically, and a disabled
button's tooltip explains why.

### Creating a launcher

Clicking `+ Create` opens a dialog pre-filled with heuristics for you to confirm:

- **Name** is derived from the filename (`Obsidian-1.5.3-x86_64.AppImage` →
  `Obsidian`)
- **Command** is already escaped per the XDG spec
- **Icon** defaults to empty; click "Choose…" to pick a file from disk
  (png/svg/xpm, copied into the icon cache) with a live 32 px preview. The same
  picker is available when editing an existing launcher
- **Categories** is an editable dropdown that suggests by keyword
  (`krita` → `Graphics;`)
- The right-hand side **previews the final `.desktop` content** in real time

In batch mode you get one dialog per item — skip a single item, or tick
"use these defaults for the rest" to get through them all at once.

**Icons are not extracted automatically, and metadata is not unpacked
automatically.** The main path is pure string manipulation: it completes in
milliseconds and cannot hang. When you do want fuller metadata, click
"Try to Extract Embedded Metadata" in the dialog — it has a hard 60-second
timeout, can be cancelled at any moment, and on failure cleans up after itself
and tells you why.

### First run

No modal wizard. The main window opens straight into an empty-state guide:

```
              No scan directory yet
    Add a directory and the app will scan it for AppImages,
    and create proper desktop launchers for you

        [ Add Directory… ]   [ Show Common Locations ]
```

"Show Common Locations" lists `~/Applications`, `~/apps` and similar; you can
tick them and create the ones that don't exist yet on the spot.

### Keyboard shortcuts

| Key | Action | | Key | Action |
|---|---|---|---|---|
| `F5` / `Ctrl+R` | Rescan | | `Enter` | Create / Claim / Edit |
| `Ctrl+A` | Select all | | `Delete` | Delete selected launchers |
| `Ctrl+F` | Focus search | | `F11` | Maximize / restore |
| `Ctrl+N` | Create launcher | | `F1` | Keyboard shortcuts |
| `Ctrl+D` | Add scan directory | | `Ctrl+Q` | Quit |
| `Ctrl+,` | Settings | | Double-click a row | Not created → create; created → edit |

Minimum window size is **620 × 560**, and the action bar turns into a
horizontally scrolling strip in narrow windows. Below 880 px wide the floating
action bar in the bottom-right corner retracts automatically — it would
otherwise cover the last few rows of the list, making them unclickable in a
small window.

There is no "fullscreen" — only "maximize". Under X11 a genuine fullscreen
makes the window manager drop every decoration, so the title bar and all three
of the minimize/maximize/close buttons disappear together and it looks like the
buttons are broken. Maximizing fills the screen while keeping the title bar,
which is what people actually want. Double-clicking the title bar or using the
window manager's shortcut (xfwm4 uses `Super+↑`) also maximizes, and the menu
checkbox follows along.

---

## Building

### Dependencies

```bash
# Debian / Ubuntu / Kali
sudo apt install valac libgtk-3-dev libjson-glib-dev pkg-config

# Fedora
sudo dnf install vala gtk3-devel json-glib-devel pkgconfig

# Arch
sudo pacman -S vala gtk3 json-glib pkgconf
```

Version requirements: Vala ≥ 0.48, GTK ≥ 3.24.

Running the tests additionally needs (for the UI automation):

```bash
sudo apt install desktop-file-utils xvfb xfwm4 xdotool imagemagick xclip
```

```bash
make selftest        # 253 engine self-tests, no graphical environment needed
tests/ui-test.sh     # 21 UI automation steps + a click-stability sweep over every button
```

CI runs exactly these two. When a tool is missing, `ui-test.sh` skips and exits
0, so an incomplete local setup is never mistaken for a failure.

### Build

```bash
make          # produces ./appimage-manager
make run      # build and run
```

### Install

```bash
sudo make install                  # installs to /usr/local by default
make install PREFIX=$HOME/.local   # or into your home directory
```

What gets installed:
- `$PREFIX/bin/appimage-manager`
- `$PREFIX/share/applications/appimage-manager.desktop`
- `$PREFIX/share/icons/hicolor/256x256/apps/appimage-manager.png`

Uninstall with `sudo make uninstall`.

### Running without installing (packaging as an AppImage)

```bash
make appimage
# → dist/AppImage-Manager-1.0.0-x86_64.AppImage   (~496 KiB)
```

This produces a self-contained AppImage: `chmod +x` it and double-click, with no
installation into any system directory.

It's only a few hundred KB because it **does not bundle GTK** — it uses the
system GTK3 at runtime, so the target machine needs GTK3 installed (every
desktop distro has it). Bundling the whole GTK stack for true self-containment
would push the size past 100 MB and drag in glibc compatibility problems, which
isn't a good trade for a tool like this.

Packaging needs no network access and no `appimagetool`: the script pulls the
runtime out of any type-2 AppImage already on your machine and assembles the
bundle itself with the system `mksquashfs`.

The runtime is located in this order, first usable one wins:

1. The `RUNTIME=/path/to/runtime` environment variable
2. `runtime/appimage-runtime-x86_64` in the repo (cached here after the first
   successful run)
3. Extracted from an AppImage already on the machine: `$APPMGR_RUNTIME_SOURCE`,
   then `~/Desktop/audit/dl/*.AppImage`, then `/tmp/*.AppImage`

The runtime length comes from the AppImage's **own reported**
`--appimage-offset`, not from searching the file for the `hsqs` magic — the
runtime's own code contains those four bytes, so a naive search hits a false
positive and slices out a crippled runtime that starts but segfaults on
`--appimage-extract`. Every candidate runtime must pass a round-trip check
("rebuilt offset matches what it reports" plus "extraction exits 0") before it
is accepted.

`dist/` and `runtime/` are in `.gitignore`.

### Building deb / rpm / arch packages

```bash
# The .desktop file contains an @PREFIX@ placeholder that needs substituting,
# and nfpm doesn't do substitutions, so stage the substituted files first:
make install DESTDIR=build/pkg PREFIX=/usr

cd packaging
/tmp/nfpm package --config nfpm.yaml --packager deb      --target ../dist
/tmp/nfpm package --config nfpm.yaml --packager rpm      --target ../dist
/tmp/nfpm package --config nfpm.yaml --packager archlinux --target ../dist
```

This uses [nfpm](https://nfpm.goreleaser.com/) rather than three separate
`debian/rules` + `.spec` + `PKGBUILD` files: one config generates all three
package types, and each family names its dependencies differently (GTK3 is
`libgtk-3-0` on deb, or `libgtk-3-0t64` on newer releases, and `gtk3` on rpm and
arch) — maintaining that in one place is more reliable than in three files.

The config lives in `packaging/nfpm.yaml`; dependency changes go there.

---

## File locations

| Purpose | Path |
|---|---|
| Config | `~/.config/appimage-manager/config.ini` |
| Launchers (write target) | `~/.local/share/applications/` |
| Icon cache | `~/.local/share/icons/hicolor/<size>/apps/` |
| Transaction log | `~/.local/share/appimage-manager/journal/` |
| Backups and history | `~/.local/share/appimage-manager/history/` |
| Extraction scratch | `~/.cache/appimage-manager/extract/` |

The launcher directory follows the XDG spec (`$XDG_DATA_HOME`) and takes
**precedence over** `/usr/share/applications` in the menu search order, so a
per-user launcher overrides a system-wide entry of the same name.

---

## Project structure

```
src/
├── main.vala           App entry point, Gtk.Application wiring
├── window.vala         Main window: list, directory chips, floating action bar, InfoBar
├── dialogs.vala        Editor / repair / claim / cleanup / settings / history / progress
├── menubar.vala        Traditional menu bar
├── prefill.vala        Derives prefill values from filename / AppImage
├── pill.vala           Custom cell renderer for the status pills
├── store.vala          Data model, two-dimensional state (match × health)
├── config.vala         GKeyFile config persistence
├── scanner.vala        Recursive scan + magic validation
├── appimage.vala       --appimage-extract metadata and icon extraction
├── desktopfiles.vala   Entry parsing, Exec escaping, atomic writes, validation
├── rules.vala          28-rule health check engine
├── repair.vala         Three repair modes, diff generation, byte-level rewriting, transactional execution
├── journal.vala        WAL two-phase transactions, crash recovery
├── backup.vala         Backup storage, append-only history, restore
├── version.vala        Version number
├── i18n.vala           Chinese/English table and I18n.s() (compiled in, no gettext)
├── paths.vala          XDG path resolution, file operation compatibility shim
data/
├── style.css           GTK3 stylesheet (theme-adaptive)
├── appimage-manager.png            Application icon
├── appimage-manager.desktop.in     Installed .desktop template
└── appimage-manager-appimage.desktop.in   .desktop template embedded in the AppImage
scripts/
└── make-appimage.sh    Offline AppImage packaging (fetch runtime + mksquashfs + assemble)
tests/
├── selftest.vala       Engine self-tests (no GUI)
├── ui-test.sh          UI automation via Xvfb + xdotool
├── ui-helpers.sh       Assertion and screenshot helpers shared by ui-test.sh
└── make-fixtures.sh    Generates fake AppImages and 21 malformed .desktop files
```

---

## Design notes

**State is two-dimensional.** "Match state" (new / created / external / broken)
and "health state" (healthy / optimizable / damaged) are orthogonal axes, so a
status pill reflects both at once.

**Slow operations never block the UI.** Icon extraction has to unpack an
AppImage (tens to hundreds of MB), so it runs on a background thread pool behind
a cancellable progress bar. Writing a `.desktop` file takes milliseconds and
runs synchronously.

**Transaction boundaries are kept as short as possible.** All the concurrency
happens before the transaction (icon extraction); inside the transaction it's
pure file operations only.

**Writes are always atomic.** Temp file → `fsync` → `rename`. The worst case is
"some files repaired, some not", never "file corrupted".

**Every automatic repair is reversible.** The original file is backed up before
the repair, history is append-only, and a restore is itself a new record.

---

## Known limitations

- AppImage's `--appimage-extract` requires the file to be executable. **This
  tool never changes your AppImages behind your back**: when it meets a file
  without the executable bit it asks, and the default answer is to leave the
  file alone. Files under `/opt` or `/media` may need administrator rights, in
  which case setting the executable bit fails — and it says so rather than
  pretending it worked
- Unpacking can be slow (tens of seconds to minutes for a large AppImage). The
  timeout is configurable (60 seconds by default, range 5–600) and it can be
  cancelled at any time. Cancelling or timing out kills the child process
  outright, leaving nothing behind
- Icon extraction and unpacking do not support encrypted or split (`.part`)
  AppImages
- It does not manage launcher directories outside
  `~/.local/share/applications`. A launcher living elsewhere can be claimed, but
  scanning won't see it (claiming asks about this)
- The packaged AppImage depends on the system GTK3; GTK is not bundled (see
  "Running without installing" above)

---

## License

GPL-3.0, see [LICENSE](LICENSE).

The source in this repository is the complete source. Distributing a binary
(deb / rpm / arch package, AppImage, tar.gz) requires making the corresponding
complete source available — every tagged Release on GitHub reproduces the full
source for that version; clone and `git checkout <sha>`.
