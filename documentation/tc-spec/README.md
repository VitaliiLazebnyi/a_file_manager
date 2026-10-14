# Total Commander 11.58 (x64): functional specification

This set describes **Total Commander 11.58, 64-bit** at clone level: every window, menu, context menu, dialog, settings page, key, internal command and settings file, with the behaviour behind each one. The facts come from the running program (on Windows 11 and under Wine), from hands-on tests in sandbox folders, from the program's own help and data files, and from its change log. Each topic is described **once**, in the chapter that owns it, with the final best-known behaviour; other chapters point to it.

| | |
|---|---|
| Product | Total Commander (x64) 11.58, released 2026-07-01, © 1993-2026 Christian Ghisler (more in 01 › Product facts) |
| Program and settings | `C:\Program Files\totalcmd\TOTALCMD64.EXE`; `%APPDATA%\GHISLER\wincmd.ini` and `wcx_ftp.ini` |
| Licence state while documented | Unregistered evaluation copy |
| Hosts | A Windows 11 virtual machine (Parallels, 200 % scaling, isolated) and macOS through CrossOver 26.3 (Wine). See Appendix B |
| Size | 20 chapters and 3 appendices, about 225,000 words, plus the `translations/` data |
| Investigated | 2026-10-10 to 2026-10-11 |

## 1. How to read this set

- **To understand the program**, read 01 (concepts), then 02 and 03 (the main window and the panels), then the chapter of the feature you need.
- **To build a clone**, start with 20 (component tree, data model, dispatch contract, state machines, build order, acceptance checklist). Each item there points to the chapter that specifies it.
- **To look something up**, use the index in §4 below, or the reference chapters: 04 (every menu item), 06 (every key), 17 (every `cm_` command), 18 (every mini-language), 19 (every settings file and `wincmd.ini` key).
- Chapters 01–19 describe **Windows behaviour**. Anything that was only a quirk of the Wine host is in Appendix A and must not be copied. Values that depend on DPI or fonts are given for Windows 11 at 200 % and marked "(depends on DPI/font; see Appendix A)".
- How the facts were obtained, and how the work was kept safe, is in Appendix B. What changed compared with the first edition of this set is in Appendix C.

## 2. Contents

| # | File | Contents |
|---|---|---|
| 01 | [01-overview-and-architecture.md](01-overview-and-architecture.md) | What TC is; two panels, source and target; cursor, selection and the operand rule; file systems a panel can show; command system, job engine, plugins and persistence as concepts; installation, first start, nag screen, window title |
| 02 | [02-main-window.md](02-main-window.md) | Window composition; menu bar; horizontal and vertical button bars; drive button bar and drive combo; command line; function-key bar; fonts, colours, icons, dark mode; window geometry and rendering metrics |
| 03 | [03-file-panels.md](03-file-panels.md) | Drive line; current-directory bar; folder tabs; column header and sorting; list rendering; colours by file type; view types (Brief, Full, Comments, Thumbnails, trees, Quick View); custom columns; view modes and Auto Switch Mode; display filters; selection; quick search and quick filter; branch view; status line; navigation, history and hotlist; refresh |
| 04 | [04-main-menu.md](04-main-menu.md) | Every main-menu item: caption, accelerator, shortcut, icon, command number and result, verified against `WCMD_ENG.MNU` |
| 05 | [05-mouse-context-menus-drag-drop.md](05-mouse-context-menus-drag-drop.md) | Mouse selection modes; mouse gestures by element; the file and folder context menu (Windows 11 shell menus and TC's items); context menus of every other element; drag & drop inside TC and with Explorer |
| 06 | [06-keyboard.md](06-keyboard.md) | Complete key reference for the main window and every tool and dialog; context rules (focus, quick search, Esc); redefining keys |
| 07 | [07-file-operations.md](07-file-operations.md) | Common rules (operands, refresh, Esc guard, elevation, long paths); Copy and its variants; progress window; Overwrite dialog; background operations and the Background Transfer Manager; Rename/Move; New folder; Delete; Change attributes; file comments; Properties; Calculate occupied space; file clipboard and name lists |
| 08 | [08-archives-and-file-tools.md](08-archives-and-file-tools.md) | Format matrix; archives as folders; operations in archives; Pack, Unpack, Test; packer settings and their effects; Split and Combine; Encode and Decode; Create and Verify checksums |
| 09 | [09-search-rename-sync-compare.md](09-search-rename-sync-compare.md) | Find Files; Multi-Rename Tool; Compare directories and Mark newer; Synchronize directories (also with FTP); Compare by content |
| 10 | [10-lister-and-viewing.md](10-lister-and-viewing.md) | Lister (modes, start-up detection, encodings, keys, search, image and media modes, plugins, printing, Configure Lister); Edit (F4); New text file (Shift+F4); associations |
| 11 | [11-ftp-and-network.md](11-ftp-and-network.md) | The built-in FTP client (all dialogs, the connected panel, transfers, TLS, download lists, settings); Windows network functions; PORT cable connection |
| 12 | [12-other-tools.md](12-other-tools.md) | Directory Tree dialog and tree cache; directory hotlist editor; System Information; volume label; printing; help viewer and About box; miscellaneous commands |
| 13 | [13-configuration-dialog.md](13-configuration-dialog.md) | The Options dialog and every page, with every control, its default, its ini key and its effect |
| 14 | [14-customisation.md](14-customisation.md) | The command language; button bars and their editors; Start menu; main-menu files (`.MNU`); user commands (`em_`); the *Choose command* dialog; redefining hotkeys and aliases |
| 15 | [15-plugins.md](15-plugins.md) | The four plugin types; installation; the plugin management dialogs; registration in `wincmd.ini`; each type in use; the plugins tried |
| 16 | [16-localisation.md](16-localisation.md) | Language files (`.LNG`, `.MNU`, `.INC`), the 18 bundled languages, switching language, the extracted data |
| 17 | [17-internal-commands.md](17-internal-commands.md) | All 594 `cm_` commands in 24 categories; the 27 commands with parameters; modifiers; `cm_` parameters; `em_` commands |
| 18 | [18-syntax-reference.md](18-syntax-reference.md) | Rename and new-folder placeholders; file masks; regular expressions; plugin-rule operators; content fields; button and command parameters (`%P %N …`); hotkey notation; path syntax; menu-entry conventions |
| 19 | [19-settings-files-and-command-line.md](19-settings-files-and-command-line.md) | File inventory and locations; INI rules; full `wincmd.ini` reference; `wcx_ftp.ini`; small file formats; command-line switches; controlling a running instance; environment variables; what is saved when |
| 20 | [20-implementation-guide.md](20-implementation-guide.md) | Component tree; data model; command dispatch contract; cross-cutting rules; state machines; rendering rules; build order; acceptance checklist; what can be left out; open points |
| A | [A-host-differences.md](A-host-differences.md) | Wine/CrossOver artefacts not to copy; DPI- and font-dependent values; defaults that differed between the sessions; keys the host intercepted |
| B | [B-investigation-and-test-setup.md](B-investigation-and-test-setup.md) | Sources; phases; safety rules and side effects; the Wine sandbox; the Windows 11 VM and its isolation; test tools (local FTP/FTPS server, plugins); provenance conventions |
| C | [C-change-log.md](C-change-log.md) | Corrections made between the first edition and this one, by topic |
| — | [translations/](translations/) | All strings of the 18 bundled languages: `ui_strings_all_languages.csv` (2,126 strings), `menus_all_languages.csv`, `commands_all_languages.csv` (594 commands), `command_categories_all_languages.csv`, one JSON per language, and every original language file converted to UTF-8 (16 › Extracted data (in `translations/`)) |

## 3. Conventions

- **Cross-references** are written `NN › Section title`, for example "07 › Name collisions: the Overwrite dialog"; `§3.2` is a section of the same chapter. Appendices are A, B, C.
- **Menu paths** are written `Menu › Item › Subitem`. Options pages are written by their tree path, e.g. `Operation › Copy/Delete`; in tables, `13 › Copy/Delete: *control*` names a control on that page.
- **Accelerators** are shown as `&` before the underlined letter, as in a Windows resource file: `&Files` is shown as "Files" with **F** underlined.
- **Controls** in sketches: `[x]` checked, `[ ]` unchecked, `[■]` the grey third state; `(o)` / `( )` radio buttons; `[Caption]` buttons; `[value ▾]` combo boxes.
- Text in quotation marks is the exact on-screen wording. English strings are built into the executable and are given as seen on screen.
- **Defaults** are the values of a fresh installation after one first start, on Windows 11.
- **Provenance:** every `##` section ends with an italic *Basis* line naming where its facts come from (observed on Windows 11, observed under Wine, help topic, change log). When sources disagreed, the order of trust was: observed on Windows 11; hands-on tests under Wine; on-screen observation under Wine; the help; the change log (B › Provenance conventions of this edition).
- **(unverified)** marks a plausible point that no observation confirmed; **(not recorded)** marks a detail that exists but was never captured. The most important ones are collected in 20 › Open points.

## 4. Where to find what

| Topic | Where |
|---|---|
| 7-Zip settings | 08 › 7-Zip packer page; 13 › Packer › 7-Zip packer |
| About box | 12 › About box |
| Access denied, "As Administrator" | 07 › Access denied and "As Administrator" |
| Aliases for the command line | 14 › Aliases; 18 › Alias-only codes |
| Alternate data streams, NTFS permissions | 07 › NTFS permissions, alternate streams, Verify |
| Archives opened as folders | 08 › Archives as folders; 08 › Operations inside an open archive |
| Associations (Enter, double click, Alt+F3) | 10 › Associations |
| Attributes | 07 › Change attributes |
| Auto Switch Mode | 03 › Auto Switch Mode; 13 › Display › View Mode › Auto Switch Mode |
| Background copying, F2 queue, Background Transfer Manager | 07 › Background operations |
| Branch view (Ctrl+B) | 03 › Branch view |
| Breadcrumb, path bar | 03 › Current-directory bar (path bar) |
| Button bars: look and use | 02 › Button bars |
| Button bars: editing, `.bar` meaning | 14 › Button bars; file format 19 › `.bar` files |
| Button bars: context menus | 05 › Horizontal button bar; 05 › Vertical button bar and panel separator |
| Button and command parameters (`%P`, `%N`, …) | 18 › Button and command parameters |
| Calculate occupied space (Ctrl+L) | 07 › Calculate occupied space (Ctrl+L) |
| Checksums | 08 › Create checksum files; 08 › Verify checksums; formats 19 › Checksum files |
| *Choose command* dialog | 14 › The *Choose command* dialog |
| Clipboard (files and names) | 07 › File clipboard and name lists |
| Colours | 02 › Colours; 13 › Display › Color; 03 › Colours by file type |
| Column header, sorting | 03 › Column header and sorting |
| Combine files | 08 › Combine files |
| Command catalogue (`cm_`) | 17 › Command catalogue; menu use 04; keys 06 |
| Command line in the main window | 02 › Command line; keys 06 › Command line |
| Command-line switches of `TOTALCMD64.EXE` | 19 › Command-line switches |
| Comments (`descript.ion`) | 07 › File comments (Ctrl+Z); format 19 › `descript.ion` and `files.bbs` |
| Compare by content | 09 › Compare by content |
| Compare directories, Mark newer | 09 › Compare directories and Mark newer |
| Component tree and data model for a clone | 20 › Component tree; 20 › Data model |
| Configuration dialog (Options) | 13 › The dialog framework, then one section per page |
| Context menu of files and folders | 05 › File and folder context menu |
| Context menus of other elements | 05 › Context menus of other elements |
| Copy (F5) | 07 › Copy (F5) and its variants |
| Create shortcut (Ctrl+Shift+F5) | 07 › Create shortcut (Ctrl+Shift+F5) |
| Custom columns | 03 › Custom columns; 13 › Display › Custom columns |
| Dark mode | 02 › Dark mode |
| Delete (F8) and the Recycle Bin | 07 › Delete (F8, Del, Shift+F8) |
| Directory history | 03 › Directory history list; 13 › Operation › History |
| Directory hotlist (Ctrl+D) | 03 › Directory hotlist; editor 12 › Directory hotlist editor |
| Directory Tree dialog (Alt+F10), tree cache | 12 › Directory Tree dialog (Alt+F10); format 19 › `treeinfo*.wc` (directory tree cache) |
| DPI- and font-dependent values | A › Values that depend on DPI and fonts; 02 › Window geometry and rendering metrics |
| Drag & drop | 05 › Drag & drop |
| Drive line, drive buttons, drive combo | 03 › Drive line; 02 › Drive button bar and drive combo box |
| Edit (F4) | 10 › Edit (F4) |
| Encode and decode | 08 › Encode and decode |
| Environment variables | 19 › Environment variables |
| Esc guard ("ESC is pressed - operation aborted!") | 07 › Esc guard |
| Everything (search engine) integration | 09 › Everything integration |
| File masks and selection types | 18 › File masks and selection types |
| File operations: rules common to all | 07 › Common rules |
| File systems a panel can show | 01 › File systems shown in a panel |
| Find Files (Alt+F7) | 09 › Find Files |
| Folder tabs | 03 › Folder tabs; 13 › Display › Folder Tabs; 19 › `.tab` files |
| Fonts | 02 › Fonts; 13 › Display › Font |
| FTP client | 11 (connecting 11 › Connecting; transfers 11 › Transfers; TLS 11 › SSL/TLS); settings 13 › Operation › FTP; 19 › `wcx_ftp.ini` |
| Function-key bar | 02 › Function-key bar |
| Help viewer | 12 › Help viewer |
| Hidden and system files | 03 › Hidden and system items; 07 › Hidden and system files |
| Host quirks (Wine) | A › Artefacts not to copy |
| Hotkey notation in `wincmd.ini` | 18 › Hotkey notation (`[Shortcuts]`); 06 › Hotkey notation in `wincmd.ini` |
| Hotkeys, redefining | 14 › Redefining hotkeys and aliases; 06 › Redefining keys |
| Icons and icon libraries | 02 › Icons; 13 › Display › Icons; 14 › Icons and icon libraries |
| Ignore list | 03 › Ignore list; 13 › Operation › Ignore list |
| INI file rules | 19 › INI rules |
| Installation, first start, nag screen | 01 › Installation; 01 › Start-up; 19 › Files written on first start |
| Keyboard | 06 |
| Language, translations | 16 › Switching the language; 16 › `.LNG` file format; 16 › Extracted data (in `translations/`) |
| Lister (F3) | 10 › The Lister window; 10 › Display modes; 10 › Configure Lister |
| Log file | 13 › Operation › Log file |
| Long paths (> 260 characters) | 07 › Long paths |
| Main menu | 04; menu files 14 › Main-menu files (`.MNU`) |
| Media player in Lister | 10 › Media player mode |
| Mouse selection modes | 05 › Mouse selection modes |
| Multi-Rename Tool (Ctrl+M) | 09 › Multi-Rename Tool; 18 › Rename and new-folder placeholders; 19 › Multi-Rename result log (`renlog.txt`) |
| Navigation, back and forward | 03 › Navigation, directory history and hotlist |
| Network drives, shares, UNC paths | 11 › Windows network functions |
| New file (Shift+F4) | 10 › New text file (Shift+F4) |
| New folder (F7) | 07 › New folder (F7, Shift+F7) |
| Open points of this set | 20 › Open points |
| Operand rule (which files a command acts on) | 01 › The operand rule; 07 › Operand rules |
| Overwrite dialog | 07 › Name collisions: the Overwrite dialog |
| Pack, Unpack, Test | 08 › Pack; 08 › Unpack; 08 › Test archives |
| Packer settings | 08 › Packer configuration: effects; 13 › Packer |
| Plugins | 15; installation 15 › Installation; registration 15 › Registration in `wincmd.ini` |
| PORT (cable) connection | 11 › PORT connection (USB or parallel cable) |
| Printing | 12 › Printing; 10 › Printing from Lister |
| Progress window | 07 › Progress window and job sequence |
| Properties (Alt+Enter) | 07 › Properties (Alt+Enter) |
| Quick search and quick filter | 03 › Quick search and quick filter; 06 › Quick search box |
| Quick View (Ctrl+Q) | 03 › Quick View; 10 › Embedded Lister: Quick View panel and separate quick view |
| Refresh and file-system watching | 03 › Refresh; 13 › Operation › Refresh |
| Regular expressions | 18 › Regular expressions |
| Rename and move (F6, Shift+F6) | 07 › Rename and move (F6, Shift+F6) |
| Rendering metrics | 02 › Window geometry and rendering metrics; 20 › Rendering rules |
| Running instance, controlling it from outside | 19 › Controlling a running instance |
| Selection | 03 › Selection; 19 › Selection files |
| Separate tree | 03 › Separate tree |
| Settings files and their locations | 19 › File inventory and locations |
| Split file | 08 › Split file; 08 › The `.crc` file |
| Start menu | 14 › Start menu |
| State machines | 20 › State machines |
| Status line | 03 › Status line |
| Synchronize directories | 09 › Synchronize directories; 09 › Synchronizing with FTP |
| System Information | 12 › System Information |
| Thumbnails | 03 › Thumbnails; 13 › Operation › Thumbnails |
| User commands (`em_`) | 14 › User commands (`em_`); 17 › User commands (`em_`) |
| View modes | 03 › View modes |
| View types (Brief, Full, Comments, Thumbnails, Tree) | 03 › View types |
| Volume label | 12 › Volume label |
| What is saved, and when | 19 › What is saved when |
| `wincmd.ini` keys | 19 › `[Configuration]` keys; 19 › Other `wincmd.ini` sections |
| Window title | 01 › Window title |
| ZIP settings | 08 › Zip packer page; 13 › Packer › Zip packer |

## 5. Safety of the investigation

Nothing was done to real disks, the network or the host system beyond what TC writes in normal use. In short (details in B › Safety rules):

1. **On-screen exploration** on the Mac host: every dialog was opened and left with Cancel, Close or Esc; no setting was saved; dialogs that would reach the network or the system were not opened.
2. **Hands-on tests under Wine** used only a dummy folder `~/tc-sandbox` with generated data. Every confirmed operation had its source and target inside it.
3. **Tests on Windows 11** ran in a virtual machine whose network was disconnected and whose sharing with the Mac was turned off. The network was switched on only to download TC, Python with pyftpdlib and the official plugins, and off again before testing. The FTP tests used a local server bound to 127.0.0.1; the network tests used only the VM's own shares; printing went to *Microsoft Print to PDF*. Writes outside the sandbox (TC's settings and plugins in `%APPDATA%\GHISLER`, the tree cache in `%LOCALAPPDATA%\GHISLER`, a temporary drive mapping) are listed in B › Writes and side effects outside the sandboxes.

## 6. Known gaps

Not observed in any session, so the chapters rely on the help for these:

- **FTP beyond a local server:** over the internet, through proxies or firewalls, and against server types other than the local pyftpdlib server (11).
- **SFTP and WebDAV.** These are separate file-system plugins with their own dialogs, not part of the FTP client. The Secure FTP plugin was installed but never connected; no WebDAV plugin was tried (15 › Plugins in the test installation).
- **External packers** (RAR, ARJ and the like) (08).
- **Cable transfers** between two PCs; only the Test button without a cable was tried (11 › PORT connection (USB or parallel cable)).
- **The visible effect of most settings.** Every option is described with its meaning, default and ini key (13, 19), but only some were switched on and watched; 13 says which.
- **Multiple monitors:** which screen windows and dialogs open on, how positions are kept per screen layout (19 › Screen-resolution sections), and what happens when a monitor is removed or has a different scaling.
- **Unicode names** in `treeinfo*.wc` and `descript.ion`, and the `[Shortcuts]` spelling of keypad keys (18 › Hotkey notation (`[Shortcuts]`)).
- **Not specified at all:** the plugin programming interfaces (15 › Programming interface) and the English base strings of IDs that were never seen on screen (16 › About the English base strings).
- Smaller unconfirmed details are marked "(unverified)" or "(not recorded)" where they occur; the important ones are listed in 20 › Open points.
