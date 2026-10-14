# 20: Implementation guide

This chapter is the developer's map for building a clone of Total Commander 11.58 x64 from chapters 01–19 and the appendices. It does not repeat the specification: it organises it into a component tree, a data model, a command-dispatch contract, the cross-cutting rules that are scattered over many chapters, the main state machines, the rendering rules, a build order and an acceptance checklist, and it says what a first clone can leave out and which points are still open. Every item points to the section that defines the behaviour. The guide is technology-neutral and fits a native Win32, Qt, GTK or AppKit build as well as an Electron or web one.

**Related:** all chapters; especially [01](01-overview-and-architecture.md) (concepts), [02](02-main-window.md) and [03](03-file-panels.md) (main window and panels), [07](07-file-operations.md) (jobs), [17](17-internal-commands.md) (command catalogue), [19](19-settings-files-and-command-line.md) (persistence), [Appendix A](A-host-differences.md) (host differences).

## 1. Component tree

### 1.1 Application core

The non-visual subsystems, in the order in which they depend on each other. The concepts are introduced in 01 › Architecture at a glance.

```
App
├── SettingsStore ............ wincmd.ini (+ AlternateUserIni / RedirectSection files), wcx_ftp.ini,
│                              *.bar, usercmd.ini, *.tab, tcDirFrq.txt, treeinfo*.wc, descript.ion
│                              → 19 › File inventory and locations, 19 › INI rules, 19 › What is saved when
├── LanguageManager .......... .LNG strings, .MNU menu, translated .INC → 16 › Language components
├── CommandRegistry .......... 594 cm_ (name ↔ number ↔ handler), 27 text commands, em_ from usercmd.ini
│                              → 17 › Names, numbers and where they are used, 17 › User commands (`em_`)
├── CommandDispatcher ........ menus, bars, keys, command line, aliases, hotlist, IPC → §3
├── VFS (file-system providers) → 01 › File systems shown in a panel
│   ├── LocalProvider ........ drives, UNC, change watching, tree cache → 03 › Refresh,
│   │                          12 › Reading the tree and the tree cache, 11 › UNC paths and servers
│   ├── ArchiveProvider ...... internal ZIP/7Z/TAR/GZ/…, external packers, WCX plugins
│   │                          → 08 › Format support matrix, 08 › Archives as folders, 15 › Packer plugins in use
│   ├── FtpProvider .......... sessions 0–9, listing parser, cache, TLS → 11 › Connection model and addresses
│   ├── PortProvider ......... USB/LPT link built on the FTP code → 11 › PORT connection (USB or parallel cable)
│   ├── PluginFsProvider ..... WFX plugins under Network Neighborhood → 15 › File-system plugins in use
│   ├── ShellProvider ........ Desktop, My Computer, Recycle bin, Network, Control Panel, shell: paths
│   └── ListProvider ......... search results, duplicates, LOADLIST, branch view, comparison view
│                              → 09 › Feed to listbox (search-result panel), 03 › Branch view
├── ContentFieldEngine ....... pseudo-plugin tc + WDX plugins → 18 › Content fields, 15 › Content plugins in use
├── ListerEngine ............. viewer modes, WLX plugins → 10 › Display modes, 15 › Lister plugins in use
├── JobEngine ................ foreground jobs, background threads, Background Transfer Managers
│                              → 07 › Progress window and job sequence, 07 › Background operations
├── ElevationHelper .......... tcmadmin.exe → 07 › Access denied and "As Administrator"
└── Ipc ...................... WM_USER+50/51, WM_COPYDATA, second instance (/O)
                               → 19 › Controlling a running instance, 19 › Command-line switches
```

### 1.2 Main window

```
MainWindow ............................. 02 › Window composition and visibility; title: 01 › Window title
├── MenuBar (8 menus, Help right-aligned; built-in or .MNU) → 02 › Menu bar, 04, 14 › Main-menu files (`.MNU`)
├── ButtonBar (default.bar, 18 buttons) → 02 › Horizontal button bar: appearance, 14 › Button bars
├── DriveButtonBar (none | one | one per panel) → 02 › Drive button bar, 03 › Drive button bar
├── FtpToolbar (only while connected) → 02 › FTP toolbar, 11 › FTP toolbar
├── PanelHost (side by side | stacked; divider in ‰) → 02 › Panel divider and arrangement
│   ├── Panel L
│   │   ├── DriveLine: DriveCombo · volume label · free space · [\] · [..] → 03 › Drive line
│   │   ├── TabStrip (shown with ≥ 2 tabs) → 03 › Folder tabs
│   │   ├── PathBar: ▾ special folders · breadcrumb / edit box · [*] hotlist · [▼] history
│   │   │                                   → 03 › Current-directory bar (path bar)
│   │   ├── SeparateTree (0, 1 or 2 panes) → 03 › Separate tree
│   │   ├── ColumnHeader → 03 › Column header and sorting
│   │   ├── FileList: Brief | Full | Comments | Thumbnails | Custom n | Tree → 03 › View types,
│   │   │             03 › Custom columns;  or QuickView (embedded Lister) → 03 › Quick View
│   │   ├── QuickSearchBox / quick filter → 03 › Quick search and quick filter
│   │   └── StatusLine → 03 › Status line
│   ├── VerticalButtonBar (vertical.bar, 6 buttons) → 02 › Vertical button bar ("Button bar 2")
│   └── Panel R (same parts)
├── CommandLine: prompt label + history combo → 02 › Command line
└── FKeyBar (7 buttons, captions follow held modifiers) → 02 › Function-key bar
```

Popups owned by the main window: context menus (05 › File and folder context menu, 05 › Context menus of other elements), the drop menu (05 › Gestures and modifiers), the drive list (03 › Drive combo box), the history list (03 › Directory history list), the hotlist (03 › Directory hotlist), the tab list (03 › Switching tabs), the breadcrumb subfolder lists (03 › Current-directory bar (path bar)) and the other popup menus of 05 › Popup menus that are not context menus.

### 1.3 Tool windows and dialogs

| Window | Opened by | Specified in |
|---|---|---|
| Lister (several at once; also embedded as Quick View; separate quick view `Lister*`) | F3, Alt+Shift+F3, Ctrl+Shift+Q | 10 › The Lister window, 10 › Configure Lister, 03 › Quick View |
| Find Files, Multi-Rename Tool, Synchronize directories, Compare by content | Alt+F7, Ctrl+M, Commands menu, Files menu | 09 › Find Files, 09 › Multi-Rename Tool, 09 › Synchronize directories, 09 › Compare by content |
| Background Transfer Manager (one per queue) | F2 Queue, `cm_OpenTransferManager` | 07 › Background Transfer Manager |
| Configuration (modal, 26 pages) | Configuration › Options, `cm_…Config` | 13 › The dialog framework |
| Directory Tree dialog, hotlist editor, Print directory, System Information, Volume label, Help, About | Alt+F10, Ctrl+D › Configure..., menus | 12 › Directory Tree dialog (Alt+F10), 12 › Directory hotlist editor, 12 › Printing, 12 › System Information, 12 › Volume label, 12 › Help |
| FTP dialogs and the "Connect" log window | Ctrl+N, Ctrl+F | 11 › Quick connect: the "ftp" dialog (Ctrl+N), 11 › "Connect to ftp server" dialog (Ctrl+F), 11 › "FTP: connection details" dialog, 11 › The "Connect" window |
| File-operation dialogs and progress windows | F5, F6, Shift+F6, F7, F8, Shift+F4, Alt+Enter, Ctrl+L, Ctrl+Z | 07 › Copy dialog, 07 › F6 dialog, 07 › Progress window, 07 › Name collisions: the Overwrite dialog, 07 › New folder (F7, Shift+F7), 07 › Questions, 07 › Change attributes, 07 › File comments (Ctrl+Z), 07 › Properties (Alt+Enter), 07 › Calculate occupied space (Ctrl+L) |
| Archive and file tools | Alt+F5, Alt+F9, Files menu | 08 › Pack dialog, 08 › Unpack dialog, 08 › Test archives, 08 › Split file, 08 › Combine files, 08 › Encode and decode, 08 › Create checksum files, 08 › Verify window |
| Selection dialogs | Num +, Num − | 03 › Select and unselect group, 09 › "Select duplicate files" dialog |
| Customisation editors | Configuration menu, context menus | 14 › The *Change button bar* dialog, 14 › The *Change start menu* dialog, 14 › The *Choose command* dialog, 14 › Redefining hotkeys and aliases, 03 › Custom columns, 03 › View modes, 03 › Auto Switch Mode |
| Associations, plugins, network | Files, Configuration and Net menus; Enter on a plugin ZIP | 10 › Associations, 15 › Managing plugins: Options › Plugins, 15 › Installation, 11 › Windows network functions |
| Start-up windows | Program start | 01 › Nag screen (unregistered copy), 01 › First-start dialogs |

Whether the top-level tool windows are modal was not tested (02 › Other top-level windows); a clone should keep the main window usable while they are open.

*Basis: structure derived from chapters 01–19; window inventory observed on Windows 11 and under Wine.*

## 2. Data model

### 2.1 Objects and fields

```text
FileItem    { name, ext, isDir, isLink(<LNK>), size | dirSize(computed snapshot) | none,
              mtime, ctime, atime, attrs{r,a,h,s,c,e}, icon, overlay(!, link, …),
              comment?, linkTarget?, fullPath (result lists), relPath (branch view),
              dupGroup? (duplicate results), contentFields{} (lazy), providerData }
Tab         { provider, path, displayMask, caption?, lock: none|locked|lockedDCA, lockedRoot?,
              view: brief|full|comments|thumbs|custom(n)|tree, viewMode, autoViewMode,
              sort{key, descending, extraKeys[], customSortCol}, filter{show, userspec, template?},
              onlySelected?, quickFilter{text, active, boxOpen}, selection: Set<itemKey>,
              cursorKey, scrollTop, branch{on, selectedOnly, savedSelection},
              comparisonView?, archive{name, type, encoding}, panelColours? }
Panel       { side: L|R, tabs[], activeTab, back[≤50], forward[], history[] (raw, with cursor
              suffix, thinning flag), separateTree?, quickSearch{text, mode}, driveInfo{label, free} }
App         { activeSide, layout flags ([Layout]), separateTree 0|1|2, quickView: none|L|R|separate,
              verticalPanels, divider‰, dividerQuickView‰, dividerComments‰, darkMode,
              savedSelectionSlot, fileClipboard, font/icon/tabstop metrics per resolution }
Job         { kind(copy|move|delete|pack|unpack|test|split|combine|encode|decode|checksum|sync|ftp),
              operands[], target, options (dialog switches), overwriteMode, stickyAnswer,
              precount{bytes, files, dirs}, progress{item, total}, state, foreground|thread|queue }
TransferQueue { title, jobs[] (active first), paused, speedLimit, overwriteMemory }
Connection  { number 0–9, session name | quick, host, port, user, tls, mode(active/passive),
              transferMode, encoding, features (FEAT), dirCache, lastLocalDir, saved? }
Config      { ini document(s) with section → key → raw value, origin file per section,
              encoding, defaults table, dirty keys }
```

### 2.2 Lifetimes and ownership

| Object | Created | Ends | Rules |
|---|---|---|---|
| FileItem | Every directory read by its provider | Next read of that location | A computed directory size stays until the item is re-read (07 › State after a copy); both status-line figures must come from the same snapshot (03 › Counting rules) |
| Selection | Per tab | Cleared or replaced per operation (§5.7) | Survives cursor moves, tab switches, switching away from TC and back, quick-filter changes (03 › Selection); never contains `[..]` |
| Saved-selection slot | App-wide, one slot | Overwritten by every file operation and by *Save Selection* | 03 › Saving and restoring the selection |
| Tab | Ctrl+T, Ctrl+↑, `.tab` files, start-up | Close, *Close all tabs* (locked tabs survive), exit | 03 › Folder tabs |
| Back/forward list | Per panel | Exit (saving not documented) | 50 entries; `HistoryCut`, `HistoryAppend` (03 › Back and forward) |
| Directory history | Per panel; every directory left | Oldest beyond `HistoryLenStored` (200) | Thinning hides entries only from the popup; saved with `SaveHistory`; cursor suffix `#n,name` (19 › History sections) |
| Job | OK in an operation dialog, F2 Queue, `cm_…` with `G` | Done, Cancel, Abort, Esc guard | §5.2 |
| Connection | Ctrl+N, Ctrl+F, `FTPOPEN`, `cd ftp://` | Disconnect, `AutoDisconnect`, suspend (`DisconnectOnSuspend`) | §5.3 |
| Temporary copies | F3/F4/Enter on archive or FTP members, nested archives | Leaving the nested archive; exit lists leftovers | `%TEMP%\_tc\` (08 › Temporary extraction) |
| Config values | Start-up read | Written per §4.3 | Absent key = default; never materialise defaults (19 › Round-trip rules for a clone) |

### 2.3 Where each object is persisted

When each item is written, and under which *Save on exit* condition, is in 19 › What is saved when (summary in §4.3).

| Object | Persisted in | Defined in |
|---|---|---|
| Active tab of each panel (path, view, sort, filter, view mode, lock, caption) | `[left]`, `[right]` | 19 › `[left]` and `[right]` |
| Other tabs | `[LeftTabs]`, `[RightTabs]` (`N_path`, `N_caption`, `N_filter`, `N_options`) | 19 › `[LeftTabs]` and `[RightTabs]` |
| Saved tab sets | `.tab` files (`[activetabs]`, `[inactivetabs]`) | 19 › `.tab` files |
| Directory history, command-line history, combo histories | `[LeftHistory]`, `[RightHistory]`, `[Command line history]`, `[MkDirHistory]` … | 19 › History sections |
| Frequently used folders | `tcDirFrq.txt` | 03 › Directory history list |
| Layout flags | `[Layout]` | 19 › `[Layout]` |
| Window placement, divider, tabstops, fonts, icon size | Resolution section `[<W>x<H> (<a>x<b>)]` or `[AllResolutions]` | 19 › Resolution section `[<W>x<H> (<a>x<b>)]` and `[AllResolutions]` |
| Colours | `[Colors]`, `[ColorsDark]` | 19 › `[Colors]` and `[ColorsDark]` |
| Key map, aliases | `[Shortcuts]`, `[ShortcutsWin]`, `[Alias]` | 19 › `[Shortcuts]`, `[ShortcutsWin]`, `[Alias]` |
| Button bars, Start menu, hotlist | `.bar` files, `[user]`, `[DirMenu]` | 19 › `.bar` files, 19 › `[user]` (Start menu) and `[DirMenu]` (directory hotlist) |
| User commands | `usercmd.ini` | 19 › `usercmd.ini` and `wcmd_<lang>.ini` |
| View modes, custom columns, colour filters | `[ViewModes]`, `[CustomFields]`, `[Colors]` … | 19 › Custom columns, view modes, custom fields |
| Associations | `[Associations]`, `[Extensions]` | 19 › `[Associations]` and `[Extensions]` |
| FTP sessions and all FTP options | `wcx_ftp.ini` | 19 › `wcx_ftp.ini` |
| Plugins | Plugin sections of `wincmd.ini` | 15 › Registration in `wincmd.ini` |
| Comments | `descript.ion` / `files.bbs` per folder | 19 › `descript.ion` and `files.bbs` |
| Tree cache | `treeinfo*.wc` | 19 › `treeinfo*.wc` (directory tree cache) |
| Tool settings | `[Packer] LastUsedPacker`, `SyncFlags`, `LastSearchOptions`, saved searches, rename and sync sets | 19 › Saved tool settings and drive names, 19 › What is saved when |
| Not persisted | Selection, saved-selection slot, quick-search text, file clipboard | — |

*Basis: help: inisettings, save_settings; observed on Windows 11 (fresh and used ini files); derived from 03, 07, 11 and 19.*

## 3. Command dispatch contract

### 3.1 Input sources

Every input resolves to one entry of the command language and goes through one dispatcher; nothing calls a handler directly (01 › Command system, 17 › Where commands appear).

| Source | Holds | Defined in |
|---|---|---|
| Main menu | `cm_` name or number, `em_` name; no parameters | 04, 14 › Main-menu files (`.MNU`) |
| Button bars | The full command language, including subbars and `OPENBAR…` | 14 › Button bars, 14 › The command language |
| Function-key bar | The function of the key with the held modifier | 02 › Function-key bar |
| Keyboard | Built-in map, replaced per key by `[Shortcuts]` / `[ShortcutsWin]` (`<key>_params=`) | 06 › Main window, 14 › Redefining hotkeys and aliases |
| Command line and aliases | A typed line; `[Alias]` words with `%A` codes | 02 › Executing a line (Enter), 14 › Aliases |
| Start menu, directory hotlist | `[user]`, `[DirMenu]` (hotlist entries also carry a target path) | 14 › Start menu, 03 › Directory hotlist |
| Internal associations, view-mode auto-run | Commands per file type / per mode | 10 › Internal associations: commands, 03 › Auto-run commands |
| Mouse and drag & drop | Gestures mapped to commands; drops onto buttons, F-keys, tabs, command line | 05 › Mouse gestures by element, 05 › Drop targets inside TC |
| Other programs | `WM_USER+51` with the command number (inferred); `WM_COPYDATA` with `cm_`/`em_` text | 19 › Controlling a running instance |
| Program start | Switches `/L`, `/R`, `/O`, `/T`, `/S` … | 19 › Command-line switches |

### 3.2 Resolving a command string

```text
dispatch(entry{command, parameters, startPath, windowState}, ctx):
  for item in splitAtCommas(entry.command):          # a comma inside "double quotes" does not split
      if item is a positive number:  run cm by number           # negative INC numbers are not commands
      elif item ~ /^cm_name( param)?$/i:  run cm with param, else with entry.parameters if not chained
      elif item ~ /^em_/i:  run user command                   # recursion detected and refused
      elif item is a text command (+ suffix letters):  17 › Commands with parameters
      elif item is "cd …":  change the source panel; startPath goes to the TARGET panel
      elif item is a .bar file (buttons only):  open subbar / menu
      else:  program; '*' = as administrator, '**' = as other user;
             expand %env% in Command, expand Parameters (18 › Expansion, '?' = edit first);
             start in startPath (default: source path) with windowState
```

- Names are case-insensitive; numbers are stable and must be kept for every command (17 › Rules a clone must keep). `em_` numbers are assigned at run time (10000 and up) and are not addressable.
- Text and parameter expansion order: 19 › Expansion order (for a clone); empty-selection and archive modifiers `%Y`, `%y`, `%Z`: 18 › Empty-selection and archive modifiers.
- The command line has its own pre-dispatch: on an FTP or plugin panel the line goes to the server or plugin first (lowercase `cd` there, uppercase `CD` to TC); otherwise `cm_`/`em_`, text commands in capitals, aliases, `cd`/`md`/`rd`, DOS internals, programs (02 › Executing a line (Enter)).

### 3.3 Command interface

```text
execute(cmd, param?, ctx)    ctx = { source, target, side (Src|Trg|Left|Right), invokedFrom,
                                     modifiers held at run time, dropped files?, chain position }
enabled(cmd, ctx) -> bool    # e.g. FTP Disconnect greyed without a connection; provider capabilities
checked(cmd, ctx) -> none | check | radio | pressed   # Show-menu radio groups, pressed bar buttons
```

- Panel commands exist as `Src…`, `Trg…`, `Left…`, `Right…`; plain menu items act on the source (01 › Addressing variants).
- Toggles take `0`/none toggle, `1` set, `2`/`-1` reset, `+4` = do not save (17 › Tri-state commands). Dialog commands take `/` switches with `G` = go immediately (17 › Patterns).
- Some commands read the keyboard state when they run (Shift with `SELECTFILES…S`, `cm_*SortByCol` with parameter 0, Shift on OK buttons); dispatch must pass the live modifier state (17 › Commands with parameters, 17 › Commands and their parameters).
- A command the current provider cannot serve is greyed or refused with a message, never half-executed (01 › File systems shown in a panel; matrix in 07 › Where each operation works).

### 3.4 Operand resolution

```text
operands(panel):
    sel = panel.activeTab.selection                 # never contains [..]
    if sel not empty: return sel in list order       # hidden/system only while shown
    if cursor on [..]: return none                   # except Alt+Enter and Ctrl+Z: the current folder
    return [cursor item]

caption(op, ops): one FILE → `Copy "name" to`;  otherwise `Copy N file(s) to` (a folder counts as a file)
```

The rule and its wording are defined in 01 › The operand rule and 07 › Operand rules. Variants: `cm_DirBranchSel` and Lister's multi-file methods fall back to the cursor item (03 › Selected branch (`Ctrl+Shift+B`), 10 › Keys and commands); multi-file parameter codes fall back to the cursor item unless `%Y`/`%y` (18 › Empty-selection and archive modifiers); on duplicate results Num + opens "Select duplicate files" (09 › "Select duplicate files" dialog).

### 3.5 What every command must do afterwards

| Obligation | Rule | Defined in |
|---|---|---|
| Save the selection | Before any file operation, copy the operand selection into the one saved-selection slot | 07 › Selection and refresh after an operation |
| Deselect | Remove fully processed items from the selection; keep items excluded by a copy filter; keep everything after Cancel or the Esc guard | 07 › Selection and refresh after an operation |
| Refresh | Re-read the panels whose location changed (both, if both changed); keep the quick filter and the selection of untouched items | 03 › Consequences, 07 › State changes at a glance |
| Cursor | Place the cursor as tabulated (next item after delete or move, new item after Shift+F5 and F7, follows a renamed item) | 07 › State changes at a glance |
| Status line | Recompute from the same data snapshot | 03 › Counting rules |
| History | Record the left directory, with the cursor suffix, subject to thinning | 03 › Directory history list, 19 › History sections |
| UI state | Update checked menu items and pressed buttons; write toggled keys unless `+4` | 02 › Horizontal button bar: appearance, 17 › Tri-state commands |
| Side effects | Update `treeinfo*.wc` for own folder changes; write the operation log if enabled; play the sound after `SoundDelay` | 03 › Tree view inside a panel, 13 › Operation › Log file, 13 › Custom sounds |

### 3.6 Key routing

```text
onKey(k):
  modal dialog or tool window focused   → its own keys; no remapping there
  quick-search box open                 → box keys (06 › Quick search box); any other action closes it
  focus in the command line             → command-line keys; protected keys keep their meaning
  k in [Shortcuts] / [ShortcutsWin]     → the mapped command
  printable character                   → AltSearch 2/3: quick search in the panel
                                          else: the command line (shown if hidden)
  Ctrl+Alt+letter (mode 0), Alt+letter (mode 1) → open quick search
  otherwise                             → built-in map (06 › Main window)
```

This order is derived from 06 › Panel focus versus command-line focus, 06 › Quick search and letters, 06 › Who wins between definitions and 14 › Where redefined keys do not take effect; the precedence between `[Shortcuts]` and a Start-menu *Shortcut key* is not documented.

*Basis: TOTALCMD.INC; help: dlg_configbuttonbar, dlg_choosecommand, cmdline, keyboard; observed on Windows 11 (command line, plugin cd, `cm_` parameters).*

## 4. Key behaviours and cross-cutting rules

Each rule applies across chapters; the pointer names the section that defines it. Rules already given as contracts in §3 (operands, post-command duties, key routing) are not repeated.

### 4.1 Panels, selection and focus

| # | Rule | Defined in |
|---|---|---|
| 1 | The active panel is the source: only it shows the cursor bar, its path bar has the active title colours, the prompt shows its path. Tab or a click switches. | 01 › Two panels: source and target |
| 2 | Default destination: target path + `*.*`; a single file `<target>\<name>`, fully selected. Pack: `zip:<target>\<operand>.zip` (Ctrl+Files › Pack: the source folder). A drop targets the panel or folder under the pointer. | 07 › Target field, 08 › Pack dialog, 05 › Drop targets inside TC |
| 3 | Default mouse model: right click toggles, holding the right button about 1 s opens the context menu; left-button mode adds rubber-band selection. | 05 › Mouse selection modes |
| 4 | Space toggles without moving and, on an unselected folder, writes its size into the Size column; Insert toggles and moves down. Each size calculation is a fresh snapshot. | 03 › Selection, 01 › Directory sizes during selection |
| 5 | Printable keys typed in a panel go to the command line (shown if hidden) unless quick search is *Letter only* or *Letters - with search dialog*; ←/→ move the caret in Full view and the cursor in Brief view; Enter runs a non-empty line unless `ExecCmdLineFocused=1`. | 02 › Layout and input routing, 06 › Panel focus versus command-line focus |
| 6 | Esc closes the quick-search box, then removes a closed quick filter, clears the command line, aborts a long operation, closes a dialog. The Esc guard aborts an operation only while Esc is physically held. | 06 › Esc, 07 › Esc guard |

### 4.2 Refresh, confirmations and errors

| # | Rule | Defined in |
|---|---|---|
| 7 | Panels are re-read after TC's own foreground operations (exceptions: several folders with `\|`, *Save Selection To File*), on re-activation and at restart (not for `NoReread` drives). After a background job F2 may be needed. | 07 › Selection and refresh after an operation, 03 › On activation and restart |
| 8 | Watching (`WatchDirs`) is off by default; when on, changes appear after about 1 s; virtual folders are never watched. FTP listings are cached (`CacheDirs=1`). | 03 › Watching the file system, 11 › Directory cache and refresh |
| 9 | Every *Get confirmation before* switch is on by default (in `[Confirmation]` only the ini-only `OverwriteHidSysNotReadonly` defaults to 0); non-empty folders are asked per folder; read-only and hidden/system targets are asked a second time, also after *Overwrite all*; `H0` does not re-enable a switched-off question. Vista+ recycling asks only TC's own question. | 13 › Get confirmation before, 07 › When it appears, 07 › Flow |
| 10 | One-time flags (`FirstTime…`) show their dialog once and are then written as `0`. | 19 › Missing or empty ini file |
| 11 | Denied folder: "Access denied on file …!" [OK] [As Administrator], panel stays. Denied target: "The given target path … is invalid!", nothing copied. Elevation needed: [Skip] [Retry] [Abort] [Skip all] [Rename] [As Administrator] [All as Administrator], through `tcmadmin.exe`. | 07 › Access denied and "As Administrator" |
| 12 | Paths over 260 characters work; target names over 259 follow `LongNameCopy`; reads slower than 5 s offer an abort. | 07 › Long paths, 03 › Branch view |

### 4.3 Jobs, encoding, DPI and settings

| # | Rule | Defined in |
|---|---|---|
| 13 | Items are processed in case-insensitive name order; *Background* moves a job into a thread, which returns to the foreground only while no other TC dialog is open; F2 Queue feeds the last opened manager; the FTP *download in background* manager is separate and closes itself. | 07 › Processing order, 07 › Routes into the background, 11 › Background transfers |
| 14 | Ini files are ANSI (keep `SetEncoding=äö.do.not.remove`) or UTF-16 LE with BOM, never UTF-8; keep the encoding and CRLF. | 19 › Encoding |
| 15 | Selection files default to UTF-16 LE with BOM; list files accept ANSI, UTF-16 and UTF-8; download lists ANSI or UTF-8 with BOM; Verify reads UTF-8 checksum files only with a BOM; Unicode paths between instances carry a UTF-8 BOM. | 19 › Selection files, 19 › List files, 19 › Download list (`ftplist.txt`), 08 › Target name and file options |
| 16 | Archive names use `[Auto]` encoding with a per-archive menu; FTP uses UTF-8 when `OPTS UTF8 ON` is confirmed, else the ANSI code page; Lister and Compare have their own encoding menus. | 08 › File-name encoding, 11 › File-name encoding, 10 › Encoding menu |
| 17 | Fonts, icon size, tabstops, row height and bar sizes follow the system DPI and font metrics, stored per screen-resolution section (fallback `[AllResolutions]`, then `[Tabstops]`); *Set dots per inch* scales dialogs only. | A › How TC stores DPI-dependent values, 19 › Screen-resolution sections, 02 › Fonts |
| 18 | Settings are read once at start; direct edits take effect after a restart and can be overwritten on exit. Writes happen on exit (per *Save on exit*), Options OK/Apply, editor OK, toggles (unless `+4`), Save Position, Save Settings, tool close and tool use. | 19 › What is saved when |
| 19 | Write only changed keys, in place; preserve unknown content; unchanged settings give a byte-identical file. Instances share one ini; saving a bar makes the others reload it. | 19 › Round-trip rules for a clone, 19 › Write test, read-only and shared ini files |

### 4.4 Providers and display

| # | Rule | Defined in |
|---|---|---|
| 20 | Each provider declares its capabilities; FTP → archive copies are refused; in a plugin path a typed `cd c:\…` is not executed. | 01 › File systems shown in a panel, 07 › Where each operation works |
| 21 | Members of archives and FTP are viewed, edited and run from copies in `%TEMP%\_tc\`; plaintext from encrypted archives is wiped; changed files are offered for re-pack or re-upload. | 08 › Temporary extraction, 10 › FTP and file-system plugins: re-upload |
| 22 | `[..]` first, folders before files, folders by name unless *Like files*; Time and Size start descending; Unsorted keeps file-system order. | 03 › Sort keys (Show menu), 03 › Directories |

*Basis: collected from the chapters named in each row, with their observations on Windows 11 and under Wine.*

## 5. State machines

### 5.1 Panel location

A panel is always in exactly one location state; the provider of §1.1 serves it.

| State | Path bar / drive line / prompt | Entered by | Left by | Defined in |
|---|---|---|---|---|
| Local or UNC | `c:\users\*.*` / drive combo / `c:\users>` | Start-up, drive change, `cd`, breadcrumb, hotlist, history | Any other state | 03 › Navigation, directory history and hotlist |
| Archive | `c:\x\a.zip\sub\*.*`, header `[Auto] Name` / prompt keeps the real folder | Enter, Ctrl+PgDn, Ctrl+←/→ on an archive (`ZIPlikeDirectory`, `PreferOpenTypes`) | Backspace at the archive root (cursor on the archive), any directory change | 08 › Opening an archive, 08 › The archive panel |
| Nested archive | Drive and path switch to `%TEMP%\_tc\…` | Enter on an archive inside an archive | Backspace at its root returns to the outer archive; leaving deletes the temp copy | 08 › Nested archives |
| FTP / PORT connection | `0:/pub/*.*` / `ftp://host:port` / `0:/pub/>` | Ctrl+N, Ctrl+F, `FTPOPEN`, `cd ftp://`, `cd port://` (panel per `FtpOpenIn`) | Disconnect → the last local directory; open connections are listed under `\ftp` | 11 › A connection is a panel location, 11 › Disconnecting |
| Network Neighborhood | `\\Network\*.*` | Drive-list entry `\` | Drive change, entering a plugin or the network | 11 › Network Neighborhood |
| File-system plugin | `\\\Registry\…` / plugin prompt | Network Neighborhood | Drive change (`cd c:\` from the command line is not executed) | 15 › File-system plugins in use |
| Shell folder | Virtual path (exact form unverified) | `▾` special-folder menu, `shell:`/`::{GUID}`, `cm_OpenDesktop` … | Any navigation | 01 › File systems shown in a panel |
| Search results / list | Drive line `Search result:`, empty path bar, full paths in Name | Feed to listbox (Shift: new tab), `LOADSEARCH ==`, `LOADLIST` | Backspace (previous real directory), F2, Ctrl+B (directory of the cursor file) | 09 › Feed to listbox (search-result panel) |
| Branch view | Path unchanged; button pressed; status line shows relative path | Ctrl+B, Ctrl+Shift+B | Ctrl+B (subfolder of the cursor file), F2 (branch root); Ctrl+Shift+B on `..` restores the selection | 03 › Branch view |
| Comparison view | `Comparison: <path>\*.*` | Mark Newer, Hide Same Files | First F2 restores the caption, second the list; any reread (e.g. saving a comment), directory change | 09 › Compare directories and Mark newer |

Orthogonal per-tab states: view type, quick filter, lock state (normal → locked → locked with directory changes, 03 › Locked tabs); per window: Quick View in the other panel, separate tree 0 → 1 → 2 → 0 (`cm_SwitchSeparateTree` cycles one → two → off, 03 › Separate tree).

### 5.2 File-operation job

```text
[dialog] ──Cancel──► nothing done
   │ OK │ F2 Queue │ /G switch
   ▼
[prepare]  pre-count (CountMarked) · free-space check (SizeCheck)
   ├─ Esc physically held ─────► [aborted] "ESC is pressed…"; selection kept
   ├─ target denied ───────────► [refused] "…is invalid!"; dialog closed
   ├─ create missing target folders silently
   ▼
[run] progress window ──Background──► [thread] ──(no other dialog open)──► [run]
   │   └─F2 Queue──► [queued] in the last opened manager; Pause ⇄ Start; one job at a time
   │  target folder = source folder ──► "You cannot copy a file to itself!" → [done, nothing copied]
   │  per item, case-insensitive name order:
   │     exists ─► mode = sticky "…all" | default (Options >>) | Ask → Overwrite dialog
   │              └─ will overwrite read-only / hidden / system ─► second question
   │     access denied ─► Skip | Retry | Abort | Skip all | Rename | (All) As Administrator
   │     Cancel / Abort ─► [aborted]
   ▼
[done]  log (if on) · sound (> SoundDelay) · deselect processed items · re-read panels
        manager: "(READY)", window stays open
```

Defined in 07 › Job sequence, 07 › Name collisions: the Overwrite dialog, 07 › Background operations; delete follows the same frame with its own questions (07 › Flow); pack, unpack and test use it with their own dialogs (08 › Background operation and interactions). The relative order of the prepare steps was not recorded.

### 5.3 FTP session

```text
[none] ──Ctrl+N │ Ctrl+F │ FTPOPEN │ cd ftp://──► [connecting]  "Connect" log window
[connecting]  TCP (retries: ConnectRetries × WaitDelay) → implicit TLS? → greeting → AUTH TLS?
              → USER/PASS (OTP) → FEAT → OPTS UTF8 ON → SYST → init commands → CWD → MLSD|LIST
   ├─ failure ─► "Connect call failed!" / "Connect failed!" ─► [none]
   ├─ Abort / Esc ─► [none]
   └─ ok ─► [connected]  panel n:/path, FTP toolbar, transfer mode, directory cache
[connected] ⇄ [foreground transfer]  (download/upload, resume, progress)
[connected] ─ background transfer ─► own new connection, log lines "BG:"
[connected] ─ F2 ─► re-list   │  new connection in the same panel ─► AutoDisconnect: ask | close | keep
[connected] ─ Disconnect ─► quick session and SaveNewConnection=1: "Current session not saved, save?"
                             Yes → connection details dialog; No → [none]; Cancel → [connected]
                            saved session: [none]; panel returns to the last local directory
```

Defined in 11 › Connecting, 11 › The connected panel, 11 › Transfers, 11 › Disconnecting and session summary; the step order FEAT / OPTS / SYST is not documented. A PORT connection uses the same machine (11 › PORT connection (USB or parallel cable)).

### 5.4 Lister mode selection

On open, the first matching rule wins: internal-only request → start-up text mode; `[ListerModes]` rule (with `ModeByfileType`) → its first method; with `BmpStartup`: Lister plugins in list order (detect string first, `NoPluginFileTypes` veto), internal image or IrfanView/XnView types, multimedia; then RTF, HTML as text; otherwise the start-up mode and font of `[Lister] Startup` (auto-detect text/binary and ANSI/ASCII). A rule-chosen text, binary or hex mode is never switched to HTML or RTF by content. Inside Lister the keys 1–8 switch modes and 4 cycles plugins and the internal viewer. Defined in 10 › Reference algorithm, 10 › Mode list, 10 › Order and cycling.

### 5.5 Quick search and quick filter

```text
[closed] ──AltSearch 0 Ctrl+Alt+letter │ 1 Alt+letter │ 3 letter │ 4 only cm_ShowQuickSearch──► [search box]
[closed] ──mode 2: letter──► jump to the next match, no box; prefix forgotten after ~1 s
[closed] ──Ctrl+S──► [filter box]        [closed] ──Ctrl+Shift+S──► [filter box, last filter]
[search box] ──Ctrl+S──► [filter box] ──Ctrl+S──► [search box]
[search box] ──Esc │ any other action──► [closed]
[filter box] ──Esc │ any other action──► [filtered]  box hidden, red funnel in the status line
[filtered]  ──click status line │ Ctrl+Shift+S──► [filter box]
[filtered]  ──Esc │ directory change │ F2 │ Ctrl+F10──► [closed]  (file operations, refreshes and
                                                                    deactivation keep the filter)
```

Matching (`QuickSearchMatchBeginning`, `QuickSearchExactMatch`, `QuickSearchAllowNoMatch`) and `QuickSearchAutoFilter`: 03 › Matching, 03 › Quick filter; keys: 06 › Quick search box.

### 5.6 Other state holders

| Holder | States and transitions | Defined in |
|---|---|---|
| Panel focus | Left ⇄ right (Tab, click); typing → command line; Tab or Esc → back to the panel | 06 › Panel focus versus command-line focus |
| Background Transfer Manager | Empty → running → paused (Start resumes; added jobs appended) → READY (window stays) | 07 › Background Transfer Manager |
| Dark mode | `DarkMode` 0 off · 1 follow Windows · 2 on; *Dark<->Normal* switches at once (temporary with 1) | 02 › Setting and switching |
| Configuration dialog | Clean → dirty (Apply enabled) → applied; Cancel discards; an invalid page blocks leaving | 13 › Buttons, applying changes, leaving a page |
| Multi-Rename Tool | Preview → Start! (list emptied, Undo and Result list enabled) → Undo (asks, reverse order) | 09 › Start!, collisions, Undo, Result list |
| Synchronize | Paths → Compare (button reads Pause/Start while running) → Synchronize... → optional re-compare | 09 › Window and workflow, 09 › The "Synchronize" dialog and the run |

### 5.7 State changes at a glance (consolidated)

The full tables stay where they are; this index gives the rule per family and the table to read.

| Family | Selection afterwards | Cursor afterwards | Panels | Full table |
|---|---|---|---|---|
| Copy, move, rename | Processed items cleared; filter-excluded kept; kept after Esc guard | Move: next item; rename: follows the item; Shift+F5: new file | Re-read; computed folder size kept | 07 › State changes at a glance |
| New folder, new file | — | Last folder of a range | Re-read, except several names with `\|` | 07 › State changes at a glance |
| Delete | Cleared after Skip on read-only; kept on Cancel | Next item, previous if the last was deleted | Re-read | 07 › State changes at a glance |
| Attributes, comments, Ctrl+L, clipboard | Ctrl+C/X keep it; Ctrl+L draws the folder selected | — | Attr updated at once; comment save re-reads both panels (ends a comparison view); Ctrl+V re-reads | 07 › State changes at a glance |
| Pack, unpack, test, split, combine, encode, decode | Not recorded for pack and unpack | — | No message on success except split and combine | 08 › State changes at a glance |
| Checksums | Create: source selection cleared; Verify: failing files selected | — | Verify window is non-modal | 08 › State changes at a glance |
| FTP session and transfers | — | — | Panel shows `0:/…`; disconnect returns to the last local directory | 11 › Session state changes at a glance |
| Compare directories | Shift+F2 replaces the selection with newer/missing files; captions unchanged | — | Mark Newer, Hide Same Files: `Comparison:` captions, same files hidden | 09 › Compare directories and Mark newer |
| Find Files, Multi-Rename, Synchronize | Multi-Rename empties its preview list | — | Feed to listbox replaces the panel list; Synchronize re-compares after copying (`SyncRecompareAfterCopy=1`) | 09 › Feed to listbox (search-result panel), 09 › Start!, collisions, Undo, Result list, 09 › The "Synchronize" dialog and the run |
| Tabs, branch view, quick filter, reread | Kept per tab; Ctrl+Shift+B restores on leaving | Branch exit: on the file in its folder | Reread ends filter, branch, results, comparison | 03 › Folder tabs, 03 › Branch view, 03 › Quick filter, 03 › Manual reread |
| Selection files | Load selects the saved items | — | Save does not re-read (file appears after Ctrl+R) | 03 › Selection files |

*Basis: collected from 03, 07, 08, 09, 10 and 11; observed on Windows 11 and under Wine as stated there.*

## 6. Rendering rules

The values are measured on Windows 11 at 200 % with Segoe UI 9 unless noted; every pixel value depends on DPI and font (A › Values that depend on DPI and fonts).

| Element | Rule a clone needs | Defined in |
|---|---|---|
| Window | ≈ 863 × 628 logical px, centred, at first start; placement per resolution section; font changes resize the window within the screen | 02 › Size, placement and persistence, 02 › Fonts |
| Element heights | Drive line ≈ 16, path bar ≈ 14, header ≈ 14, row pitch ≈ 13 (96 DPI: ~20 / ~16 / ~16 / ≈ 17; menu ~21, status / command line / F-keys ~16 / ~20 / ~20) | 02 › Metrics, A › Window and element metrics |
| Rows | `rowHeight = max(iconHeight, fontHeight) + extraVertical` (default 1); icon cell = icon width + `extraHorizontal` (2); icon size by DPI (32×32 at 200 %) | 02 › Icon size and row spacing, 03 › Font and row height |
| Full view | `[..]` first; `[dir]` with `<DIR>` (or computed size), `<LNK>` for links; sizes with thousands separators, right-aligned; `MM/DD/YYYY hh:mm`; Attr `r a h s` letters or `-` (`-a--`) | 03 › Rows in Full view, 03 › Names, extensions and folders |
| Formats and columns | Date/time/separator options, size styles (bytes in lists, kbytes in header/footer); tabstops 176 / 234 / 238 / 299 / 91 at 200 %; *Adjust Tabs to window width* keeps the right-hand columns right-aligned | 03 › Data formats (Tabstops/Data Formats page), 03 › Tabstops, 13 › Display › Tabstops/Data Formats |
| Brief and Thumbnails | Newspaper columns as wide as the longest name (`BriefViewWidthLimit`); 96 × 96 tiles with `name ext` caption shortened with `..` | 03 › Brief, 03 › Thumbnails |
| Cursor and selection | Themed cursor: light-blue bar with a darker 1 px border, active panel only; selection = red text (`MarkColor=255`); the item whose context menu or delete question is open is drawn red; inverted cursor/selection and focus frames per the pseudo-code | 02 › Cursor and selection rendering, 03 › Cursor, selection and row states |
| Header | Sort column tinted light blue with the arrow left of its text; `[Auto] Name` inside archives | 03 › The header |
| Path bar | Active / inactive title colours (Windows 11: muted steel blue with light text / lighter grey-blue); tail of long paths with ◀ ▶; breadcrumb underline and triangle button after 250 ms | 03 › Content, 03 › Current-directory bar (path bar) |
| Colours | Ini values `R + 256·G + 65536·B`, `-1` default; colour rows = `default` + 16 swatches + `>>`; alternating *Background 2*; colours by file type override the text colour | 02 › Main colours (Color page), 03 › Colours by file type, 13 › Display › Color |
| Icons | Sources and overlays (red `!` on hidden/system, dimmed hidden items), Explorer folder icons, `[..]` up-arrow | 02 › File-list icons, 03 › Icons |
| Bars | Main bar: 16 px icons on 24 px buttons at 96 DPI, 1 px etched separators with 3–4 px padding, pressed toggles, wrapping rows; vertical bar ~30 px wide with an overflow button; F-key bar: 7 equal flat buttons with hover frame | 02 › Horizontal button bar: appearance, 02 › Vertical button bar ("Button bar 2"), 02 › Function-key bar |
| Tabs and status line | Active tab raised; `*` locked, `!` changed DCA tab; status-line formulas, red funnel while filtered | 03 › Tab header appearance, 03 › Status line |
| Dark mode | Dark grey bars, black (≈ `#1E1E1E`) lists, dark slate-blue cursor; `[ColorsDark]` overrides | 02 › Dark mode |
| Dialogs | Configuration ≈ 507 × 400 at 96 DPI, tree ≈ 120 px, blue centred page caption; dialogs scale with DPI, `AutoSizeDialogs` | 13 › Window and navigation tree, 02 › Fonts |

*Basis: observed on Windows 11 (200 %) and from 96-DPI screenshots under Wine; help: add_filelist, dlg_configcolor, dlg_configicons, inisettings3.*

## 7. Build order

Each milestone builds on the previous ones and ends with a part of the acceptance checklist (§8).

| # | Milestone | Content | Chapters |
|---|---|---|---|
| 1 | Foundations | Ini store with profile-API semantics and round-trip writing; resolution sections; language strings; the 594-command registry with names, numbers and categories; dispatcher skeleton | 19 › INI rules, 19 › What is saved when, 16, 17 |
| 2 | Window shell | Regions and their visibility, menu from `.MNU`, button bars from `.bar`, F-key bar, command line with prompt and history, title | 02, 04, 14 › Button bars, 14 › Main-menu files (`.MNU`), 01 › Window title |
| 3 | Local panel | Local/UNC provider, Full and Brief views, header and sorting, drive line, path bar, status line, navigation, back/forward, history list, hotlist | 03 › Panel anatomy and state to 03 › File list rendering, 03 › Status line, 03 › Navigation, directory history and hotlist |
| 4 | Selection and input | Mouse models, selection keys and groups, display filters, quick search and filter, key routing and remapping | 03 › Display filters, 03 › Selection, 03 › Quick search and quick filter, 05 › Mouse selection modes, 06, 14 › Redefining hotkeys and aliases |
| 5 | File operations | Job engine, Copy/Move/Rename/New folder/New file/Delete, Overwrite dialog, progress, Esc guard, refresh rules, attributes, comments, clipboard, elevation | 07, 13 › Operation › Copy/Delete, 13 › Misc. |
| 6 | Panel features | Tabs and `.tab` files, Comments, Thumbnails, trees, separate trees, Quick View, branch view, custom columns, view modes, auto switch, colours by type, refresh/watching | 03 › Folder tabs, 03 › View types to 03 › Auto Switch Mode, 03 › Branch view, 03 › Refresh, 18 › Content fields |
| 7 | Archives and file tools | Archive provider, Pack, Unpack, Test, Split/Combine, Encode/Decode, checksums | 08 |
| 8 | Viewing | Lister with all modes, F3/F4 rules, associations | 10 |
| 9 | Bulk tools | Find Files, Multi-Rename Tool, Compare directories, Synchronize, Compare by content | 09, 18 |
| 10 | Network | FTP client, Background Transfer Manager, Windows network functions | 11, 07 › Background operations |
| 11 | Configuration and customisation | All 26 Configuration pages, bar/Start-menu/hotlist editors, user commands, command-line switches, IPC | 12, 13, 14, 19 › Command-line switches |
| 12 | Extensions and polish | Plugin loading and installation, language switching, dark mode, DPI behaviour, installer and first start | 15, 16, 02 › Dark mode, A, 01 › Installation, 01 › Start-up |

*Basis: derived from the dependencies between chapters 01–19.*

## 8. Acceptance checklist

Each check is observable and names the section that defines the expected result.

**Window and start-up**

- [ ] Title `Total Commander (x64) 11.58 - NOT REGISTERED`, with no prefix (01 › Window title).
- [ ] First start: nag screen, Configuration on Layout, icon-library chooser, both panels at `c:\` (01 › Start-up sequence).
- [ ] Eight menus, Help right-aligned, items as in 04 (02 › Menu bar); main bar with 18 buttons and exact tooltips, vertical bar with 6 (02 › Button bars).
- [ ] Layout-page toggles apply at once; showing the bar again reloads the default bar (02 › Showing and hiding regions).

**Panels**

- [ ] Drive line `[c ▾] [_none_] … k of … k free [\] [..]` (03 › Drive line); path bar `c:\path\*.*` with active/inactive colours and `▾ * ▼` (03 › Current-directory bar (path bar)).
- [ ] Full view shows `[..]`, `[dir]` with `<DIR>`, thousands separators, `MM/DD/YYYY hh:mm`, `-a--`; `<LNK>` on junctions (03 › Rows in Full view).
- [ ] Four Shift+↓ from `report_01` give `5 k / 8 k in 4 / 14 file(s)`; Ctrl+A with 1 file and 4 folders gives `0 k / 0 k in 1 / 1 file(s), 4 / 4 dir(s)` (03 › Formulas).
- [ ] Ctrl+F5 sorts newest first with folders still by name (03 › Directories); Backspace puts the cursor on the folder just left (03 › Moving between directories).
- [ ] Alt+↓ shows frequent folders with counts, a separator, then recent folders with the current one marked (03 › Directory history list).
- [ ] Tabs: Ctrl+T/Ctrl+W, strip only with ≥ 2 tabs, double-click closes, `*` on locked tabs, the rename dialog (03 › Folder tabs).
- [ ] All view types, separate trees, Quick View, branch view, vertical arrangement and dark mode render as described (03 › View types, 02 › Dark mode); `cm_ZoomIn 200` doubles the thumbnails (03 › Thumbnails).
- [ ] `cm_SwitchHidSys 5` shows hidden/system items (`--hs`, red `!`) without changing `wincmd.ini` (03 › Hidden and system items).

**Selection and input**

- [ ] Right click toggles red selection and updates the footer; holding the button opens the context menu (05 › Right-button mode (default, Norton Commander style)).
- [ ] Space on a folder writes its size; `Num /` restores the selection cleared by a copy (03 › Selection).
- [ ] Ctrl+S then `no` in `c:\windows` leaves `[..]` and `notepad.exe`; first Esc keeps the filter with the funnel, second Esc clears it (03 › Quick filter).
- [ ] *Letter only*: `rep` jumps to `report_01`, the prefix is forgotten after about 1 s, letters no longer reach the command line (03 › Invocation modes).
- [ ] `cd \\localhost\c$\…` on the command line opens the share; in the Registry plugin `cd c:\…` is not executed (02 › Executing a line (Enter)).
- [ ] *Save Selection To File* writes UTF-16 LE with BOM, folders with `\`, no CRLF after the last name, and the file appears only after Ctrl+R (03 › Selection files).

**File operations**

- [ ] Copy headings `Copy "name" to` / `Copy 1 file(s) to`; counter strip `6.68 k 13 1` and `15 b 1 2` (07 › Operand rules).
- [ ] Missing target folders are created silently; a denied target gives "…is invalid!" (07 › Target field, 07 › Access denied and "As Administrator").
- [ ] Items are processed in name order; the first conflict appears at `7 / 14` (07 › Processing order).
- [ ] Overwrite dialog layout and *More Options >>* menu; *Overwrite all older* keeps a newer target silently; *Compare* on identical files says "The two files have the same content!" (07 › Name collisions: the Overwrite dialog); a read-only target asks "… is READ ONLY! …" again (07 › Read-only, hidden and system targets).
- [ ] The Esc box appears only while Esc is held (07 › Esc guard).
- [ ] After a copy the source is deselected, the computed folder size stays, read-only files arrive as `ra--` (07 › State after a copy).
- [ ] F2 Queue opens `<first item> (Copy)`, runs at once, appends jobs while paused, ends with "(READY)" and stays open (07 › Background Transfer Manager).
- [ ] F8 asks "Do you really want to move the selected file <name> to the recycle bin?"; the cursor goes to the next item, or the previous after the last (07 › Delete (F8, Del, Shift+F8)).
- [ ] F7 `<1-3>dir[C]` creates three folders with the cursor on the last (07 › New folder (F7, Shift+F7)); saving a comment re-reads both panels (07 › File comments (Ctrl+Z)).

**Archives and file tools**

- [ ] Enter on a ZIP shows `…\a.zip\*.*`, `[Auto] Name` and the real folder in the prompt (08 › The archive panel).
- [ ] `sample.tar.gz` → `sample.tar` → temp copy under `%TEMP%\_tc\`, deleted on leaving (08 › Nested archives).
- [ ] Pack on one folder proposes `zip:<target path>\<folder name>.zip` (target panel at `c:\`: `zip:c:\<folder name>.zip`); choosing GZ gives `gz:c:\*.*.gz` and ticks separate archives; a target without prefix copies normally (08 › Pack dialog, 08 › Target string).
- [ ] Split with *360 k* writes 362,496-byte parts and a `.crc` file, then "Split of … succeeded!" (08 › Split file).
- [ ] Creating checksums clears the source selection; Verify selects the failing files (08 › State changes at a glance).

**Search, rename, compare**

- [ ] Shift+F2 marks `only_in_B` and the newer `report_03` on the right, replaces the previous selection and keeps the captions; *Mark Newer, Hide Same Files* shows `Comparison:` captions until Ctrl+R twice (09 › Compare directories and Mark newer).
- [ ] Feed to listbox shows `Search result:`, an empty path bar and full paths; Backspace returns (09 › Feed to listbox (search-result panel)).
- [ ] Multi-Rename preview applies masks → search & replace → case; Start! shows no message and empties the list; Undo lists the pairs and asks (09 › Rename pipeline, 09 › Start!, collisions, Undo, Result list).
- [ ] Synchronize runs Right → Left before Left → Right and re-compares afterwards (09 › The "Synchronize" dialog and the run).

**Lister**

- [ ] F3 on an archive member opens `Lister - [<TEMP>\_tc\…]` (08 › Temporary extraction); keys 1–8 switch modes; N/P act only with several files (10 › Mode list, 10 › Multi-file sessions).
- [ ] Hex mode shows `|` after the 8th byte and ` | ` before the character column (10 › Hex).

**FTP and network**

- [ ] Ctrl+N anonymous: e-mail prompt once, "Connect" log with the header block, panel `0:/*.*`, drive line `ftp://127.0.0.1:2121`, FTP toolbar (11 › Session state changes at a glance).
- [ ] TLS shows the sChannel lines and the lock icon; a failed handshake gives "Connect failed!" (11 › The "Connect" window, 11 › Connection errors).
- [ ] Disconnecting a quick session asks "Current session not saved, save?" (11 › Disconnecting); a download onto an existing file offers Resume (11 › Target already exists and resume).
- [ ] Backspace at a UNC share root lists `\\localhost\*.*` (01 › File systems shown in a panel).

**Configuration, commands and persistence**

- [ ] 26 Configuration pages with every control and default; Apply enabled only when dirty; Esc discards; *Letter only* and *Show drive buttons* apply at once (13 › The dialog framework).
- [ ] The command list matches 17 in names, numbers and categories (17 › Command catalogue).
- [ ] A `[Shortcuts]` entry replaces the built-in key; protected editing keys keep their meaning in the command line (14 › Where redefined keys do not take effect).
- [ ] The fresh settings folder matches 19 › Files written on first start; unchanged settings give a byte-identical `wincmd.ini` (19 › Round-trip rules for a clone).
- [ ] Enter on a plugin ZIP with `pluginst.inf` offers installation into `…\plugins\<type>\<name>` and opens the registration dialog (15 › Automatic installation).

*Basis: observed behaviour recorded in 01–19 (Windows 11 and Wine sandbox tests).*

## 9. What can be left out

### 9.1 Features a first clone can defer or omit

Where a feature is left out, keep its menu item, button and command number with a "not available" message, so that menus, `.bar` and `.MNU` files and scripts keep working (17 › Rules a clone must keep).

| Feature | Reason | Defined in |
|---|---|---|
| Nag screen, "NOT REGISTERED", registration and key file | Licensing, not file management | 01 › Nag screen (unregistered copy), 01 › Registration (concept) |
| PORT connection over parallel or USB cable, its driver switches and test mode | Obsolete hardware (parallel ports, "Windows Easy Transfer Cable") | 11 › PORT connection (USB or parallel cable), 19 › Switches |
| 16-bit and legacy Windows items: 9x/ME/NT4/2000 rules, CleanSweep workarounds (`Win95Delete`, `DeleteDelay`), floppy rules (EXE/LNK icons, 360 k and 1.44 MB split presets), 8.3 short names (`UseLongNames=0`, lower-case `%p`) | Platforms and media no longer in use | 07 › Delete method keys, 08 › Part names and sizes, 18 › Expansion |
| IrfanView/XnView for Lister and thumbnails (`IView`) | External third-party converters | 10 › Type lists and vetoes, 13 › Operation › Thumbnails |
| External packers (ARJ, LHA, RAR, ACE, UC2, PKZIP/Info-ZIP) | Need third-party programs; keep the Packer page | 08 › Packer page (`cm_PackerConfig` 491) |
| *Everything* integration | Third-party indexer | 09 › Everything integration |
| Media player and Explorer Preview modes, RTF | Depend on platform components | 10 › Media player mode, 10 › Explorer Preview, 10 › RTF |
| Shell extensions, X64/X32 submenu, NTFS permission and stream copy, `tcmadmin.exe` elevation | Windows-only; stub on other systems | 05 › X64/X32 submenu and shell-extension configuration, 07 › NTFS permissions, alternate streams, Verify, 07 › Access denied and "As Administrator" |
| External control messages (`WM_USER+50/51`, `WM_COPYDATA`) | Windows-specific; offer an equivalent IPC | 19 › Controlling a running instance |
| Printing, help viewer | A browser or the system print dialog can stand in | 12 › Printing, 12 › Help viewer |
| Installer parameters and installer UI | Packaging, not the program | 01 › Installation |
| `tcmatch.dll`, WindowBlinds checks, external conflicts (GeForce Experience) | Optional add-ons and host specifics | 03 › Matching, 02 › Main colours (Color page), 06 › Who wins between definitions |

**Must not be copied:** the Wine and CrossOver artefacts (user-name prefix in the title, stuck-Esc boxes, missing PNG thumbnails, hidden dot-files, host shell folders) listed in A › Artefacts not to copy.

### 9.2 What this set does not specify

- **Plugin programming interfaces** (WCX, WFX, WLX, WDX function sets): only their visible effects are described (15 › Programming interface).
- **English base strings** of language IDs that never appear in the observed UI: they are compiled into the program; reconstruct them as described in 16 › About the English base strings. Many message texts are marked "(text not recorded)".
- **Items marked "(not recorded)" or "(unverified)"**: the most important ones are listed in §10.
- **Undocumented heuristics**: Lister's text/binary and ANSI/ASCII detection, the "same file" test of *Mark Newer*, the unit thresholds of dynamic size styles, the digit grammar of history suffixes; a clone chooses its own and documents it.
- **Undocumented file formats**: `.br2` icon caches, the thumbnail database, `tcDirFrq.txt` (19 › Caches and lists without a documented format), the Multi-Rename undo store (19 › Multi-Rename result log (`renlog.txt`)).
- **Other operating systems**: the specification describes Windows 11; Appendix A says which observed values depend on the host.

*Basis: help: plugins, registration, usb_cable_connection; investigation decisions recorded in 15, 16, 19 and Appendix B.*

## 10. Open points

The most important points still marked "(unverified)" or "(not recorded)" in the chapters, one per line.

**01 Overview and architecture**

- Exact virtual path shown for shell folders such as the Desktop (01 › File systems shown in a panel).
- Form of the instance number in the title (`ShowInstanceNr`) (01 › Window title).
- What a wrong number and the two info buttons of the nag screen do (01 › Nag screen (unregistered copy)).

**02 Main window**

- F-key bar captions while Ctrl or Alt is held (02 › Function-key bar).
- How `CmdUpDown=0` interacts with ↑/↓ from the command line (02 › Keys in the command line).

**03 File panels**

- How Ctrl+W and middle click treat a locked tab; whether *Close all tabs* keeps DCA tabs (03 › Locked tabs).
- Whether `.tab` files use exactly the `[LeftTabs]` keys (03 › Tab files and storage).
- Whether a plain header click drops extra sort keys (03 › Header clicks and multi-key sort).
- Column positions of the `c` and `e` attribute letters (03 › Rows in Full view).
- Unit thresholds of the dynamic size styles (03 › Data formats (Tabstops/Data Formats page)).
- Whether a tree in the right panel shows the left panel's drive, the reverse of the observed case (03 › Tree view inside a panel).
- Whether *Only Selected Files* is a one-time snapshot (03 › Only Selected Files).
- When the `, … dir(s)` part is omitted from the footer (03 › Formulas).
- Mechanism of the `A>B` related-files mask (03 › Select and unselect group).

**05 Mouse, context menus, drag & drop**

- Windows 11 items of the path-bar context menu; captions of the right-drag drop menu; whether a drag-move uses the Rename/Move dialog (05 › Path bar (current directory), 05 › Gestures and modifiers, 05 › Confirmation).

**06 Keyboard**

- Home and the Shift+Home/End/PgUp/PgDn selection ranges (06 › Navigation, 06 › Selection).
- Backspace, Del, Space, Home, End while the command line holds text but the panel has the focus (06 › Panel focus versus command-line focus).
- AltGr+letter on layouts where it produces a character (06 › Quick search and letters).
- Esc precedence when several Esc states hold (06 › Esc).
- `[Shortcuts]` versus Start-menu *Shortcut key*; spelling of keypad and other non-letter key names; modifier subsets (06 › Who wins between definitions, 06 › Hotkey notation in `wincmd.ini`).

**07 File operations**

- Relative order of pre-count, free-space check, Esc guard, target check and folder creation (07 › Job sequence).
- Behaviour on a collision with `OverwriteFiles=0` (overwrite assumed) (07 › When it appears).
- Full "(READY)" title text, and why the Wine manager closed itself (07 › Background Transfer Manager).
- Texts of the `CopyToDirWarn`, `MoveToDirWarn` and `AppendWarning` questions and of the several-item delete question (07 › Target field, 07 › F6 dialog, 07 › Append, 07 › Questions).
- Layouts of *Change UNIX attributes* and *Rename each file separately* (07 › Change UNIX attributes (FTP), 07 › Shift+F6 with several items).
- The *As Administrator* route itself was never exercised (07 › Access denied and "As Administrator").

**08 Archives and file tools**

- Write support for ZSTD and Brotli (08 › Operations per format).
- Default pack name for several items and for a single file's extension; selection state after pack and unpack (08 › Pack dialog, 08 › After packing).
- Byte sizes of the split presets other than 360 k; combined name without a `.crc` file (08 › Part names and sizes, 08 › Combine files).
- File extensions of the SHA2-512/224/384 and SHA3 checksum files; SFV layout; wrong-checksum row text (08 › Methods, 08 › Checksum file format, 08 › Verify window).
- Flattening when *Unpack path names* is off (08 › Fields and options).

**09 Search, rename, synchronize, compare**

- Upper limit of the search-depth list; Ctrl+B in the Find result list (09 › General tab, 09 › Feed to listbox (search-result panel)).
- Captions after `cm_CompareDirsWithSubdirs` (09 › Compare directories and Mark newer).
- `SyncFlags` default on a fresh installation; a full Synchronize run against FTP (09 › Window and workflow, 09 › Synchronizing with FTP).

**10 Lister, viewing and editing**

- What Lister shows for a folder without a folder-capable plugin; the control for `Viewertype=2` (10 › Keys and commands, 10 › Choosing the F3 method (Configuration › Edit/View)).
- Whether `Contextmenu1=` replaces or adds to the Google item (10 › User items).

**11 FTP and network**

- Session order in Ctrl+F (alphabetical or creation order) (11 › The list).
- Storage of several firewall definitions and the base of `[firewall] Method=` (11 › Firewall (proxy) settings).
- What *Always trust this server* writes; the codes of `copyflags:` (11 › Certificates, 11 › List file format).
- Whether *SSL/TLS* is stored as the `ftps://` prefix of `host=` (11 › Field semantics).
- Where a Ctrl+N HTTP download is saved (11 › HTTP(S) downloads).

**13–16 Configuration, customisation, plugins, localisation**

- Whether Configuration Cancel reverts changes already applied (13 › Buttons, applying changes, leaving a page).
- `cd "path\*.ext"` inside a chain (14 › Rules); storage of *Show as menu* (14 › The *Change button bar* dialog); `[Alias]` value layout (14 › Redefining hotkeys and aliases); `usercmd.ini` location and keys (14 › User commands (`em_`)).
- Whether *Remove* in the plugin lists deletes files (15 › Common behaviour of the list dialogs).
- How a continued line in a `.LNG` value is read (16 › Rules (derived from the 18 files)).

**19 Settings files and command line**

- HKCU versus HKLM precedence for `IniFileName` (19 › How the location of `wincmd.ini` and `wcx_ftp.ini` is chosen).
- Exact rule for Unicode values in ANSI ini files (19 › Encoding).
- `activetab`, `activelocked`, `activecaption` in `[left]` / `[right]` (19 › `[left]` and `[right]`).
- Which instance wins when several save on exit (19 › Write test, read-only and shared ini files).
- `/L=` together with a positional path (19 › Interaction rules).
- The resolution-section height 1896 versus the logical screen (19 › Screen-resolution sections).

*Basis: collected from the "(unverified)" and "(not recorded)" markers of chapters 01–19.*
