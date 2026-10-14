# 03: File panels

This chapter describes everything a file panel shows and how the user moves and selects in it: the drive line, the
current-directory bar with its breadcrumb, history and hotlist buttons, folder tabs, the column header and sorting, row
rendering, the view types (Brief, Full, Comments, Thumbnails, Tree, custom columns, separate trees, Quick View), view
modes and their automatic switching, colours by file type, display filters, selection, quick search and quick filter,
branch view, the status line, directory history and hotlist navigation, and refreshing. The window around the panels and
its visual design (fonts, colour pickers, icon options) are in chapter 02, the context menus of the panel parts in 05,
and the complete key tables in 06.

**Related:** [01](01-overview-and-architecture.md) (two-panel model, cursor vs selection), [02](02-main-window.md)
(window composition, fonts, colours, icons, dark mode), [05](05-mouse-context-menus-drag-drop.md) (mouse model, context
menus, drag & drop), [06](06-keyboard.md) (keyboard), [09](09-search-rename-sync-compare.md) (Compare directories, Feed
to listbox), [12](12-other-tools.md) (Directory Tree dialog, hotlist editor), [13](13-configuration-dialog.md) (the
Options pages named below), [17](17-internal-commands.md) (command catalogue), [18](18-syntax-reference.md) (masks),
[19](19-settings-files-and-command-line.md) (`wincmd.ini`, `.tab` and other file formats).

Conventions: INI keys are written `Key=default` and live in `[Configuration]` of `wincmd.ini` unless another section is
named. "Resolution section" is the per-screen-resolution section such as `[3456x1896 (10x20)]` (19 › Screen-resolution
sections). Wherever a `cm_Src…` command is named, `Trg…` (other panel), `Left…` and `Right…` variants exist too. Example
paths and values come from the test installations (Windows 11 at 200 % scaling, and Wine).

## 1. Panel anatomy and state

### 1.1 Parts of a panel

Each of the two panels is a vertical stack. Parts in brackets are optional or appear only in some states:

```text
[drive button bar]        off by default; with "two bars" one sits above each panel
drive line                [c ▾] [_none_]  1,465,383,472 k of 7,811,085,600 k free      [\] [..]
[folder tab strip]        shown when the panel has ≥ 2 tabs (default)
current-directory bar     ▾c:\users\*.*                                              [*] [▼]
[separate tree] │ column header     ↑Name        Ext    Size   Date              Attr
                │ file list         [..]                <DIR>  10/11/2026 01:19  ----
                │                   [Public]            <DIR>  10/11/2026 01:19  ----
                │                   win          ini       34  10/11/2026 01:19  -a--
status line               0 k / 0 k in 0 / 0 file(s), 0 / 2 dir(s)
[quick search box]        small edit box below the file list; "Search: [____] [⏷ Ctrl+S]" in filter mode
```

- The separate tree pane sits to the left of the column header and file list (§8.7).
- In Quick View the other panel's column header and file list are replaced by a Lister window (§8.8).
- Each part can be hidden through Configuration › Layout; the `[Layout]` key and the toggle command are given in the
  section of each part. The window-level list of regions is in 02 › Window composition and visibility.

### 1.2 Source and target

- The panel surrounded by a frame holds the **source directory**. It receives keyboard input such as the cursor keys and
  Enter; the other panel is the **target**.
- The active panel is also marked by its current-directory bar, drawn in the active title colours (§3.1), and by the
  cursor bar, which by default is drawn only in the active panel (02 › Cursor and selection rendering).
- `Tab` switches the active panel; `Shift+Tab` moves between a file list and its separate tree (§8.7).

### 1.3 What a panel and a tab remember

- Each panel holds an ordered list of **folder tabs** (§4); a panel without extra tabs has exactly one, whose header is
  hidden by default.
- **Per tab**: the path, the view type, the sort order (with additional sort keys), the display filter (with _Save
  displayed file types separately for each tab_, the default), the **selection**, the view mode, the lock state, a user
  caption and, for archives, the archive name and type. Switching tabs keeps all of these.
- **Per panel**: the back/forward list of the last 50 directories, the directory history list (§17), and its separate
  tree pane when two trees are shown.
- The active tab is stored in `[left]` / `[right]`, the other tabs in `[LeftTabs]` / `[RightTabs]` (§4.8). Directories
  are saved on exit with _Save on exit › Directories_ (`Savepath=1`), the view settings with _Save on exit › Panels
  (brief/full, etc.)_; key lists are in 19 › `[left]` and `[right]`.

_Basis: observed on Windows 11 and under Wine; help: add_srcdir, add_curdir, foldertabs, go_back._

## 2. Drive line

The drive line is the first row of a panel: the drive combo box, the volume label, the free-space text and,
right-aligned, two small flat buttons `\` and `..`. The free-space text updates live.

### 2.1 Drive combo box

Shown with `[Layout] DriveCombo=1` (`cm_VisDriveCombo`). Closed, it shows a small drive icon and the drive letter (lower
case by default, `c`) with a drop-down arrow.

**Opening:** click the arrow, press `Alt+F1` (left panel) or `Alt+F2` (right panel), or run `cm_SrcOpenDrives`. The
current drive is highlighted. Observed list on Windows 11, letter or symbol in the first column, description in the
second:

```text
c                                          (local-disk icon)
d   DVD Drive
z   \\localhost\c$\tc-sandbox              (network-drive icon; while Z: is mapped, among the letters)
+   Computer (drive overview)
*   My Documents (directory)
\   Network Neighborhood
```

| Element                         | Rule                                                                                                                                                              | Key                             |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------- |
| Description                     | The volume label or, for a network drive, the server/share path. Needs _Show volume labels/network paths for drives_ (Display page)                               | `Tips` bit 2 (default `Tips=3`) |
| Not connected                   | `(X)` before the network path while the network drive is not connected yet                                                                                        | —                               |
| Floppy drives                   | Their names are never read, for speed                                                                                                                             | —                               |
| Description delay               | Delay before the descriptions appear                                                                                                                              | `DriveTipDelay=0` ms            |
| CD and removable media          | Labels shown                                                                                                                                                      | `CDlabel=1`                     |
| Icons                           | Drive icons in the list and in the "drive not found" box                                                                                                          | `IconsInDriveList=1`            |
| Removable drives without medium | Hidden when set (CD and floppy drives always show); bit sum 1 drive bar, 2 drive list, 4 Find › Drives                                                            | `HideRemovableNoMedia=0`        |
| Extra entries                   | Bit sum: 1 = _Computer_ (needed for devices without a letter such as Android phones), 2 = _My Documents_, 4 = up to **3** external devices without a drive letter | `ShowExtraDrives=7`             |
| Terminal server / XP mode       | Host-computer drives appear with a trailing backslash, e.g. `c\`. `Ctrl+letter` picks the **host** drive when a letter exists twice                               | `tsclient=\\tsclient`           |
| Letter case                     | Drive letters in the drive bar, the drive list and the path: 1 upper, 0 lower, -1 leave as is                                                                     | `DrivesShowUpcase=-1`           |
| USB hard disks                  | Shown with the removable-disk icon                                                                                                                                | `CheckUsbHdd=1`                 |
| Custom names                    | One line per drive in `[DriveHints]`, e.g. `E=ZIP drive`, `H=CD-ROM`; used by the combo and the drive buttons                                                     | `[DriveHints]`                  |

**Choosing a drive:** click it or type its letter. `+` shows the drive overview (_My Computer_), `*` the Documents
folder, `\` Network Neighborhood (`\\Network\*.*`; installed file-system plugins are listed there, 15 › File-system
plugins). **Shift** while choosing opens the drive in a **new folder tab**. Which directory opens on the new drive:
§2.5.

**Right-click** on the closed combo, or directly on an entry inside the open list (without switching drives first),
opens the drive's context menu: format, copy disk, share, and the shell menu of the drive root (05 › Drive combo box and
drive buttons).

**Special locations shown in the combo:**

| Panel shows                                 | Combo                                    | Drive line text                                                                        |
| ------------------------------------------- | ---------------------------------------- | -------------------------------------------------------------------------------------- |
| FTP connection                              | Globe icon and the connection number `0` | `ftp://127.0.0.1:2121`, or `ftps://127.0.0.1:2122` with TLS (11 › The connected panel) |
| UNC path (`cd \\localhost\c$\tc-sandbox\B`) | Network icon `\`                         | —                                                                                      |
| _Feed to listbox_ results                   | Empty                                    | `Search result:` (09 › Feed to listbox)                                                |

### 2.2 Drive button bar

Off by default (`[Layout] DriveBar1=0`, `cm_VisDriveButtons`). _Show two drive button bars (fixed width, above file
windows)_ (`DriveBar2=0`, only with `DriveBar1=1`, `cm_VisTwoDriveButtons`) puts one bar above each file window; the two
bars have the same fixed width and do not follow the panel widths. _Flat icons_ is `DriveBarFlat=1`
(`cm_VisFlatDriveButtons`). Switched on with Apply on Windows 11, a single bar appeared at once under the button bar as
`[c] [d] [\]`, flat icons with letter labels. Its placement in the window is in 02 › Drive button bar and drive combo
box.

| Button kind                                           | Shown as                                     |
| ----------------------------------------------------- | -------------------------------------------- |
| Normal drive                                          | Drive letter plus an icon for the drive type |
| Network Neighborhood                                  | A backslash `\` beside a network icon        |
| FTP connection                                        | A number `0`…`9` beside a network icon       |
| USB device without a drive letter (e.g. a smartphone) | A USB button                                 |

- **Right-click** a drive button for its context menu (copy or format disks, Properties, etc.; 05 › Drive combo box and
  drive buttons).
- **Hiding parts** (`DriveBarHide=`, a string of characters; applies to the drive bar and the drive line):
  - `A`–`Z` drives; `0`–`9` FTP connections; `\` Network Neighborhood; `;` USB devices without a letter;
  - `.` the parent and root buttons; `-` the volume label and free/total space;
  - terminal-server host drives after a `$`, e.g. `DriveBarHide=A$CDE` hides local A: and host C:, D:, E:.
  - Unlike `Allowed=`, hidden drives can still be reached through the drive list, `cd`, etc.
- **Extra drive space H / V** (Icons page; the fields are visible only while the drive bar is enabled): the total number
  of pixels added left+right / above+below the drive icon, so `2` means 1 px on each side. Stored per resolution as
  `ExtraDriveWidth` / `ExtraDriveHeight` (with `_dpi` and `_<dpi>` variants).
- **Icons:** _Show drive icons from Explorer_ applies to the drive bar, the drive combo and folder tabs.
  `OldDriveIcons=0`: 0 = Explorer icons, 1 = TC 6.5x icons, 2 = TC 7/8 icons. `DriveLib=` takes icons from a DLL and
  overrides `OldDriveIcons`; ticking the Explorer option moves the value to `DriveLib.bak`.

### 2.3 Volume label and free space

- The **volume label** in square brackets, `[_none_]` when the volume has no label; then the **free and total space** of
  the current volume: `1,465,383,472 k of 7,811,085,600 k free`.
- **Units:** the help page for this field says "kilobytes (1024 bytes)"; in fact the _Header/footer_ size style on the
  Tabstops page governs it (default `SizeFooter=1` = kbytes, §6.4). `SizeStyle1000=1` switches to decimal units.
- The text updates live. With file-system watching on, _Update header (free disk space)_ (`WatchDirs` bit 32) re-reads
  it on each change (§18.3).
- Hidden with `DriveBarHide` character `-`.

### 2.4 Root and parent buttons

- **`\`** goes to the root of the current volume (`cm_GoToRoot`, also `Ctrl+\`); **`..`** goes to the parent directory
  (`cm_GoToParent`).
- **Locked-tab exception:** on a tab that is "locked, but directory changes allowed", `\` returns to the tab's saved
  directory instead; with `LockedGoToDriveRoot=1` it goes to the real drive root (§4.6).
- Hidden with `DriveBarHide` character `.`.

### 2.5 Changing drives

- _Always go to the root of a drive when changing drives_ (`AlwaysToRoot=0`): off = the panel goes to the **last
  directory used on that drive**; on = always to the root.
- Choosing the drive that the **other panel** is on opens the other panel's folder, not the root (left panel at
  `c:\tc-sandbox\A`, choosing `c` in the right combo opened `c:\tc-sandbox\A`).
- `Allowed=` (e.g. `cde`; `\` = Network Neighborhood) restricts which drives can be used at all.
- When changing to a CD-ROM drive fails, TC tries to close the tray (`CdCloseDoor=1`).
- `Alt+F1` / `Alt+F2` open the drive list from the keyboard; inside it, typing a letter chooses the drive.

_Basis: observed on Windows 11 (drive list, mapped drive, FTP and plugin panels, drive buttons) and under Wine (other
panel's folder); help: add_drive, add_drivebuttons, add_freemem, add_root, dlg_configicons, dlg_display, foldertabs,
inisettings1–3._

## 3. Current-directory bar (path bar)

### 3.1 Content

Shown with `[Layout] CurDir=1` (`cm_VisCurDir`); clickable path parts with `BreadCrumbBar=1` (`cm_VisBreadCrumbs`); the
two buttons with `HistoryHotlistButtons=1` (`cm_VisHistHotButtons`). The bar sits directly above the column header
(below the folder tabs) and shows:

- a small `▾` button at the left (special-folder menu, §3.2);
- the **path plus the display mask**: `c:\users\*.*`. The mask reflects the display filter (§12): `*.*` for all files,
  otherwise the mask in use;
- at the right end the hotlist `*` and history `▼` buttons (§3.5).

| Location                                      | Bar shows                                                                                       |
| --------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Local folder                                  | `c:\users\*.*`                                                                                  |
| Inside an archive                             | The archive file and the subdirectories inside it: `c:\x\a.zip\sub\` (08 › Archives as folders) |
| FTP connection                                | `0:/*.*` at the server root, `0:/pub/*.*` in a folder                                           |
| Network Neighborhood                          | `\\Network\*.*`                                                                                 |
| File-system plugin                            | `\\\Registry\*.*`                                                                               |
| _Mark Newer, Hide Same Files_ comparison view | `Comparison: c:\tc-sandbox\A\docs\*.*` (09 › Compare directories and Mark newer)                |
| _Feed to listbox_ results                     | Empty bar                                                                                       |
| Quick View panel (other panel)                | Only the file name, e.g. `copy1.txt`                                                            |

- **Long paths:** a path longer than the bar (tested with more than 300 characters) shows its **end**, with a `◀` scroll
  arrow at the left and `▶` at the right. The command-line prompt shows the tail of the path.
- **Colours:** active and inactive panels use the _Title bar for file panels_ colours (`[Colors] ActiveTitle`,
  `ActiveTitleText`, `InactiveTitle`, `InactiveTitleText`). With the defaults they follow the Windows caption colours:
  on Windows 11 the active bar is a muted steel blue with white text, the inactive one a lighter grey-blue (02 ›
  Colours).
- `PathExtraHeight=-100` adds height to the path field or reduces it (scaled from 96 dpi). `BreadCrumbMaxWidth=-1`
  limits the breadcrumb width in pixels; -1 = half the screen width, clamped to 100 px … screen width.

### 3.2 Mouse

| Gesture                                             | Result                                                                                                                                                                                                                                                                                                                                                                                             |
| --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Hover over the path                                 | The path part under the mouse is **underlined**. After `BreadcrumbDelayButton=250` ms a small **triangle button** appears below it. The button is not shown while **Ctrl** is held. A negative delay opens the list at once, without the button                                                                                                                                                    |
| _Auto-open when moving mouse over it_ (Layout page) | The subdirectory list opens directly after the standard 250 ms instead of the button                                                                                                                                                                                                                                                                                                               |
| Click an underlined part                            | Jump straight to that directory (breadcrumb)                                                                                                                                                                                                                                                                                                                                                       |
| Click the triangle button                           | Drop down the **subdirectories** of that part                                                                                                                                                                                                                                                                                                                                                      |
| In that list, move the mouse to the right           | Opens the subdirectory list of the item under the mouse (a cascade). Delay `BreadcrumbDelayDir=250`; `BreadcrumbDelayFtp=500`, `BreadcrumbDelayPlugin=500`, `BreadcrumbDelayVirtual=500` for those locations. `BreadcrumbSeparator=-3` says where the "open sub-folder" zone starts: 0…100 = percent of the item width (0 = the whole item), negative = that many line heights from the right edge |
| Click the `▾` at the left                           | **Special-folder menu**: Desktop, My Computer ▸ (the drives), Documents ▸ and the other top-level shell folders of the host (observed under Wine, whose list held host-specific entries; see Appendix A)                                                                                                                                                                                           |
| Click `*` / `▼`                                     | Hotlist / history popup (§3.5)                                                                                                                                                                                                                                                                                                                                                                     |
| **Single click outside the path text**              | Turns the bar into an edit box (§3.4)                                                                                                                                                                                                                                                                                                                                                              |
| **Double click**                                    | Opens the **Directory hotlist** (§17.4)                                                                                                                                                                                                                                                                                                                                                            |
| Right click                                         | Context menu of the current directory (05 › Path bar (current directory))                                                                                                                                                                                                                                                                                                                          |
| **Slow right click** (held about 1 s)               | **History** of visited directories (§17.3)                                                                                                                                                                                                                                                                                                                                                         |

Triangle markers in the subdirectory list:

| Marker          | Meaning                                                  |
| --------------- | -------------------------------------------------------- |
| None            | The directory has no subdirectory, or none is accessible |
| Filled triangle | There are listable subdirectories                        |
| Hollow triangle | Not determined (e.g. virtual folders)                    |

`InplaceRenamePath=1` (defaults to the value of `InplaceRename` if that key is present): 1 = the path can be edited in
place; 0 = it cannot; 2 = no in-place path editing, but quick directory changes with a single click (no Shift).

### 3.3 Keyboard

- `Alt+F11` (left) / `Alt+F12` (right) put the cursor in the bar.
- `←` / `→` or `Tab` jump between path parts.
- `Enter` or `↓` opens the directory or drops down its subdirectory list.
- `Esc` closes an open subdirectory list, or leaves the bar.
- Commands: `cm_SrcPathFocus` / `cm_LeftPathFocus` / `cm_RightPathFocus` focus the path; `cm_EditPath` (no default key)
  switches to edit mode.

### 3.4 Edit mode

- Entered with a single click outside the path text, or `cm_EditPath`. The path can be copied to the clipboard, or
  another path pasted in.
- `Enter` switches to the typed path. **If the path cannot be accessed, the edit box stays open.**
- **Auto-complete** (Operation › _Auto-complete paths_, `AutoComplete=3`) suggests directory names that match what has
  been typed (13 › Operation page). Picking a suggestion does **not** close the box; a second `Enter` is needed.

### 3.5 History and hotlist buttons

| Button | Tooltip                      | Opens                                                                 |
| ------ | ---------------------------- | --------------------------------------------------------------------- |
| `*`    | "Directory hotlist (Ctrl+D)" | The directory hotlist (§17.4)                                         |
| `▼`    | "History (Alt+Down)"         | The list of recently visited plus frequently used directories (§17.3) |

_Basis: observed on Windows 11 (colours, long paths, FTP and plugin paths) and under Wine (layout, special-folder menu,
tooltips); help: add_curdir, add_hothist, dlg_configcolor, inisettings1–2._

## 4. Folder tabs

### 4.1 Model

- Each panel has its own ordered list of tabs (`[Layout] DirectoryTabs=1`, `cm_VisDirTabs`). Switching tabs **keeps**
  each tab's sort order, view (brief/full etc.) and **selection**.
- The display filter chosen with _Show › Custom_ (§12.2) is kept **per tab** when _Save displayed file types separately
  for each tab_ is on (`DirTabFilters=1`, the default); otherwise it is kept per panel, as before TC 10.00. With
  `DirTabFilters=1`, `Ctrl+U` (exchange the panels' directories) swaps the displayed file types too.
- The tab strip sits directly above the current-directory bar of its panel.

### 4.2 Opening tabs

| Action                                                                  | Result                                                                                                                                                                                                                                               |
| ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Ctrl+T` (Show › New Folder Tab)                                        | New tab with the current directory, **activated** (`cm_OpenNewTab`)                                                                                                                                                                                  |
| `Ctrl+Shift+T`                                                          | Same, but **not** activated (`cm_OpenNewTabBg`); `cm_OpenNewTabOther` / `cm_OpenNewTabBgOther` do the same in the other panel                                                                                                                        |
| `Ctrl+↑`                                                                | Opens the folder or archive under the cursor in a new tab. By default the current tab stays active, so several subfolders can be opened quickly. With _Ctrl+Up opens new tab in foreground_ (bit 64) the new tab is activated (`cm_OpenDirInNewTab`) |
| `Ctrl+Shift+↑`                                                          | Opens the folder under the cursor in a new tab of the **other** panel (`cm_OpenDirInNewTabOther`)                                                                                                                                                    |
| Shift + drive selection                                                 | The drive opens in a new tab                                                                                                                                                                                                                         |
| Shift + hotlist choice, or `Shift+Enter` in the history list or hotlist | The folder opens in a new tab                                                                                                                                                                                                                        |
| Tab context menu › _Duplicate this tab_ / _Copy tab to other panel_     | New tab with the same directory, in the same panel / in the other panel                                                                                                                                                                              |
| Double-click or middle-click on **free space** of the tab header        | New tab                                                                                                                                                                                                                                              |
| Drag several folders to an empty spot of the tab header                 | Each becomes a new tab. The mouse cursor shows a small arrow in the file symbol. Dropping files **onto** a tab copies or moves them into that tab's directory (05 › Drag & drop)                                                                     |

- **Insertion point:** at the end; with _Open new tabs near current tab_ (bit 128), directly to the right of the active
  tab.
- **Single tab, header hidden:** new tabs can only be opened with `Ctrl+T` or `Ctrl+↑`. The Folder Tabs page also
  mentions "Ctrl+Cursor up on a file"; what happens on a plain file is not documented (unverified).

### 4.3 Tab header appearance

- Tabs are labelled with the folder name; the active tab is drawn raised.
- **Hint:** hovering a tab shows a hint with its path and a date/time (observed: `c:\windows>` with
  `10/11/2026 01:19 …`; what the date refers to was not recorded).

| Option (Folder Tabs page) / key                                         | Effect                                                                                                                                                                                                                                                                                                                                                           |
| ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| _Show tab header also when there is only one tab_ (bit 1)               | Header always visible; otherwise only with ≥ 2 tabs                                                                                                                                                                                                                                                                                                              |
| _Tabs on multiple lines_ (bit 2)                                        | Wrap into several rows; otherwise one row with two small scroll buttons                                                                                                                                                                                                                                                                                          |
| _All tabs have same width_ (bit 4)                                      | Fixed-width tabs ("like Mozilla")                                                                                                                                                                                                                                                                                                                                |
| _Limit tab title length to: [32] characters_ (bit 8) + `DirTabLimit=32` | Maximum number of characters shown on a tab                                                                                                                                                                                                                                                                                                                      |
| _Always show drive letter in tab title_ (bit 1024)                      | Title becomes `c:windows`. FTP tabs show the connection number, `0:tmp`; a connection that is disconnected after a restart shows `#` instead of the number. The separator is `TabSeparator=:`                                                                                                                                                                    |
| _Show locked tabs with an asterisk \*_ (bit 256)                        | Locked tabs get `*` in front of the title                                                                                                                                                                                                                                                                                                                        |
| (always)                                                                | A "locked, but directory changes allowed" tab whose current directory differs from its saved directory gets `!` in front of the title                                                                                                                                                                                                                            |
| _Show icons on tabs_ + `>>` (`DirTabIcons=255`, bit sum)                | 1 enable; 2 drive icon in the root of non-network drives (_For local drives_); 4 folders with `desktop.ini`, only if the folder has the read-only or system attribute (_Icons defined via folder properties_); 8 virtual folders such as the Desktop; 16 file-system plugins; 32 FTP; 64 icons from view modes (_User-defined icons (view modes)_); 128 reserved |
| View-mode tab colour (§10.2)                                            | `TabFullColor=0` draws it as a gradient; 1…100 draws a full colour blended over the tab at that percentage. `[Colors] ActiveTabColor=-1` sets the colour of the active tab (-1 = off)                                                                                                                                                                            |

`DirTabOptions=824` is the bit sum for the page: 824 = 8 + 16 + 32 + 256 + 512 (title limit, confirm close-all, close on
double-click, asterisk, activate target panel). Bits 1, 2, 4, 64, 128 and 1024 are off by default.

### 4.4 Switching tabs

- **Mouse:** click a tab. With _Activate target panel when clicking on one of its Tabs_ (bit 512, on by default),
  clicking a tab of the inactive panel also makes that panel active; with the option off, the clicked panel switches tab
  but the other panel stays active.
- **Ctrl+Tab / Ctrl+Shift+Tab:** next / previous tab (`cm_SwitchToNextTab` / `cm_SwitchToPreviousTab`):

```text
if DirTabOpenList=1 ("Ctrl+Tab opens as list"):
        Ctrl+Tab behaves like Ctrl+Shift+A (list of tabs)
        TabsListLastVisited=1: last visited tabs on top
else if DirTabGotoLastVisited=1 ("Ctrl+Tab switches to last visited"):
        Ctrl+Tab goes to the last visited tab; pressing Tab again (Ctrl still held)
        continues to the tabs right of the active tab
else:   Ctrl+Tab goes to the tab to the right
TabSwitchMode=0: the switch happens when Ctrl is released; 1: at once on each Tab press
```

- **`Ctrl+Shift+A`** (`cm_SrcTabsList`) shows a menu of all open tabs, like Chrome:
  - pressing it again toggles between showing tab **titles** and tab **directories**;
  - `Ctrl+L` inside the list puts the most recently visited tabs at the top;
  - typing runs a quick search / quick filter on the list (`QuickSearchTabsAutoFilter=0` sets whether filtering is
    automatic; a leading `*` searches the full path);
  - `Shift+Enter` on a recently closed tab restores it without focusing it.
- **Direct activation:** `cm_SrcActivateTab1…99`, and the `Trg` / `Left` / `Right` variants.

### 4.5 Closing tabs

- `Ctrl+W` (`cm_CloseCurrentTab`), middle click on the tab, double click (_Close tab on double click_, bit 32, on by
  default), `Ctrl+click`, or the context menu (_Close this tab_ closes the tab that was right-clicked).
- **Close all tabs** (`Ctrl+Shift+W`, `cm_CloseAllTabs`) closes every tab **except locked ones**, keeps the current
  directory, and asks first when _Confirm close all tabs_ (bit 16, on) is set.
- **Close duplicate tabs** (`cm_CloseDuplicateTabs`) closes every tab that points to a directory already shown by
  another tab, keeping one per directory.
- **Recently closed tabs** is a context sub-menu; it appears only if a tab has been closed since TC started, and reopens
  those tabs.

### 4.6 Locked tabs

Three states, stored per tab (locked flag in `N_options`) and as `activelocked=` (1 = locked, 2 = locked with directory
changes allowed) for the active tab.

| Event                                                        | Normal tab | **Locked**                                                                                                  | **Locked, but directory changes allowed** (DCA)                                                          |
| ------------------------------------------------------------ | ---------- | ----------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Change directory (Backspace, `cd`, hotlist, drive change, …) | In place   | The tab keeps its directory; the new directory goes to a **new tab**, or a reused one per `LockedTabChange` | In place; the saved directory is kept                                                                    |
| Enter on a directory                                         | In place   | `TabEnterDirChange=1`: 0 = do nothing, 1 = open a new tab, 2 = ask                                          | In place                                                                                                 |
| Switch to another tab and back                               | —          | —                                                                                                           | Reverts to the saved directory if _Return to locked tab root directory on tab change_ (`DirTabRevert=1`) |
| Click the tab header while the tab is already active         | —          | —                                                                                                           | Reverts to the saved directory                                                                           |
| `\` button or `Ctrl+\`                                       | Drive root | —                                                                                                           | Reverts to the saved directory (`LockedGoToDriveRoot=1`: the drive root instead)                         |
| `cm_GoToLockedDir`                                           | —          | —                                                                                                           | Reverts to the saved directory                                                                           |
| _Close all tabs_                                             | Closed     | Kept                                                                                                        | Kept (unverified: "locked tabs" is taken to cover both kinds)                                            |

`LockedTabChange=1` decides which tab receives a directory change made on a locked tab: 0 = always a new tab; 1 = reuse
a tab that already shows that directory; 2 = reuse the first unlocked tab; 3 = reuse the last unlocked tab.

- Locked tabs are described as tabs that "cannot be deleted (so easily)". Only survival of _Close all tabs_ is
  documented; how a single close (`Ctrl+W`, middle click) treats a locked tab is not stated (unverified).
- **Setting the state:** the tab context menu (_Rename/Lock tab_, _Lock this tab_, _Locked, but directory changes
  allowed_; 05 › Folder tabs) and the commands `cm_ToggleLockCurrentTab`, `cm_ToggleLockDcaCurrentTab`,
  `cm_SetTabOptionNormal` / `…PathLocked` / `…PathResets`, and `cm_SetAllTabsOption…` for all tabs at once.
- **Typical use:** a DCA tab holds a project root the user can always return to.

### 4.7 Renaming and rearranging

- _Rename/Lock tab_ opens a small dialog; the caption entered there replaces the folder name on the tab (`N_caption=`,
  `activecaption=`):

```text
New name:
[windows                                    ]
[ ] Lock this tab
[ ] Locked, but directory changes allowed
                               [  OK  ] [ Cancel ]
```

- Drag a tab to a new position; it can also be dropped on the **other panel's** tab header. `cm_MoveTabLeft` /
  `cm_MoveTabRight` move the current tab by one place.
- The context menu ends with _Configure view modes_ (opens the View Mode page) and the **list of view modes**, which
  switches the tab to that mode (§10).

### 4.8 Tab files and storage

- **Context menu:** _Save tabs to file_ saves the current panel's tab paths, names and options; _Save tabs on both sides
  to file_ saves both panels; _Load tabs from file, keep current_ **appends** the saved tabs; _Load tabs from file,
  replace tabs_ **replaces** all tabs.
- **Commands with parameters** (button bar or command line, written in capitals on the command line):
  `APPENDTABS <file>` and `OPENTABS <file>` append or replace (suffix `L` / `R` targets the left/right panel; without a
  parameter a file-open dialog appears); `SAVETABS`, `SAVETABSL`, `SAVETABSR` save one side (active / left / right);
  `SAVETABS2`, `SAVETABS2L`, `SAVETABS2R` save both sides, with the active / left / right side written first.
- **Format:** an INI file. A one-side file holds `[activetabs]`; a both-sides file also holds `[inactivetabs]` (to build
  one by hand, join two one-side files and rename one section). The per-tab keys are presumably those of `[LeftTabs]`
  (unverified). `TabDir=` remembers the folder last used for tab files.
- **In `wincmd.ini`:** `[LeftTabs]` / `[RightTabs]` hold the tabs other than the active one, which is in `[left]` /
  `[right]`:

| Key                                | Meaning                                                                                                                                                                                                                                                                                                                                                         |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `N_path=`                          | Path of tab N (0-based)                                                                                                                                                                                                                                                                                                                                         |
| `N_caption=`                       | User-defined title                                                                                                                                                                                                                                                                                                                                              |
| `N_filter=`                        | Display filter of the tab (with `DirTabFilters=1`)                                                                                                                                                                                                                                                                                                              |
| `N_options=`                       | Fields separated by `\|`: view mode, sort order, sort direction, archive: start of archive name, archive: archive type, locked flag, custom-view sort order, additional sort orders, custom background colours (header / background / background 2, plus background / background 2 for dark mode), view mode, auto view-mode switch. Example `1\|3\|1\|0\|0\|1` |
| `activetab=`                       | Index of the active tab (in `[left]` / `[right]`)                                                                                                                                                                                                                                                                                                               |
| `activelocked=` / `activecaption=` | Lock state (1 / 2) and caption of the active tab                                                                                                                                                                                                                                                                                                                |

The file formats are in 19 › `.tab` files and › `[LeftTabs]` and `[RightTabs]`.

_Basis: observed under Wine (strip, hint, context menu, rename dialog); help: foldertabs, dlg_configfoldertabs,
cm_new_folder_tab, keyboard, inisettings1–3._

## 5. Column header and sorting

### 5.1 The header

- Shown with `[Layout] TabHeader=1` (`cm_VisTabHeader`); drawn themed with `TabHeaderThemed=1`.
- **Full view:** `Name | Ext | Size | Date | Attr`. **Brief view:** `Name | Ext | Size | Date`, as sort buttons only.
  **Comments view:** the unchanged Full header (§8.4). **Thumbnails:** the header row stays. **Custom columns:** the
  captions of the view's columns. A file-system plugin may supply its own columns (the Registry plugin showed Name, Ext,
  Type, Size, Date, Value).
- The **sort column** is tinted light blue and carries a small arrow to the **left** of its text: `↑Name` ascending, `↓`
  descending. `TabHeaderBoldArrow` (defaults to `TabHeaderThemed`) makes the arrow bold.
- **Inside an archive** the Name header reads `[Auto] Name`; `[Auto]` is the file-name encoding marker. Left-clicking
  the header sorts as usual; right-clicking `[Auto]` opens the encoding menu (08 › File-name encoding;
  `cm_ChangeArchiveEncoding`).

### 5.2 Header clicks and multi-key sort

- A click on _Name_, _Ext_, _Size_ or _Date_ sorts by that column; clicking the **same** header again reverses the
  order.
- **Multi-key sort** (`AddSortOrders`):

| Click on header H | H not used for sorting                                      | H already used for sorting       |
| ----------------- | ----------------------------------------------------------- | -------------------------------- |
| Plain click       | Sort by H only (earlier extra keys are dropped; unverified) | H is the primary key: reverse it |
| `Ctrl+Click`      | Append H as an additional sort key                          | **Reverse** H's direction        |
| `Shift+Click`     | Append H as an additional sort key                          | **Remove** H from the sort chain |

Ties on the first key are broken by the second key, then the third, and so on. Example: click _Size_, then Shift+click
_Date_: files are sorted by size, files of equal size by date.

INI forms: `[left] AddSortOrders=1,-3,2` = also sort by column 1 ascending, column 3 descending, column 2 ascending
(columns counted from 1); `customsortorder=100+n` sorts by the n-th custom column (custom columns mode only).

### 5.3 Sort keys (Show menu)

| Show menu item | Key       | Command            | Rule                                                                                                                | Direction when chosen          |
| -------------- | --------- | ------------------ | ------------------------------------------------------------------------------------------------------------------- | ------------------------------ |
| Name           | `Ctrl+F3` | `cm_SrcByName`     | By name, then by extension                                                                                          | Ascending                      |
| Extension      | `Ctrl+F4` | `cm_SrcByExt`      | By extension, then by name                                                                                          | Ascending                      |
| Time           | `Ctrl+F5` | `cm_SrcByDateTime` | By timestamp                                                                                                        | **Descending** (newest first)  |
| Size           | `Ctrl+F6` | `cm_SrcBySize`     | By size on disk                                                                                                     | **Descending** (largest first) |
| Unsorted       | `Ctrl+F7` | `cm_SrcUnsorted`   | Only separates directories from files; within each group the order is that of the `dir` command (file-system order) | —                              |
| Reversed Order | —         | `cm_SrcNegOrder`   | Inverts the current order (Z→A, largest→smallest, newest→oldest)                                                    | toggle                         |

- **Time:** the Sort and View help pages call this "creation date and time", while the file-window page says the Date
  column shows the "date and time of last change". A clone sorts on the timestamp shown in the Date column (last
  modified).
- `[..]` is always the first row, and directories are always listed before files.
- `cm_SrcSortByCol1…99` (IDs 6001…6099; `Trg` 6101…, `Left` 6201…, `Right` 6301…) sort by the n-th column of the current
  view.
- Stored as `[left]` / `[right]` `sortorder=` (0 name, 1 extension, 2 size, 3 date, 4 unsorted) and
  `negative Sortorder=` (0/1).

### 5.4 Directories

- **Always by name** (`SortDirsByName=1`, the default): directories are always sorted by name, ascending, whatever the
  file sort or its direction.
- **Like files (also by time):** directories follow the file sort key and direction, including time and reverse. With a
  sort by Date descending, folders were sorted newest first (docs 12:02, photos 12:02, bin 12:01, locked_target 11:55),
  still above the files; the change applies at once.
- `SortDirExt=0` allows directories to be sorted by extension; it applies only when `SortDirsByName=0`.
- `cm_SwitchDirSort` toggles the setting.

### 5.5 Name comparison (Display › _Sort method_)

| Method                                         | Rule                                                                                                |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Alphabetical, considering accents (default)    | The operating system's compare function for the current language, so accents are taken into account |
| Strictly by numeric character code             | Compares **upper-case** character codes; accented letters therefore sort after Z                    |
| Natural sorting: by character code and numbers | **Lower-case** character codes, but digit runs compare as numbers: `file5.txt` < `file10.txt`       |
| Natural sorting: alphabetical and numbers      | Like the above, but language-aware; uses `StrCmpLogicalW` (IE ≥ 6)                                  |

`SortUpper=0`: 0 default; 1 = files starting with `_` go last; 2 = mixed lexical/numerical; 3 = like 2 via
`StrCmpLogicalW`.

### 5.6 Column widths

- Dragging a separator in the header moves the tabstop (§6.5). The new position is kept only after _Configuration › Save
  Position_, because tabstops are stored per resolution.
- **Double-click a separator** (Full or custom columns view) to auto-fit the column to its **left** to the widest
  content. In custom columns view only fields already loaded at that moment are measured.

### 5.7 Header context menu

Right-clicking the header opens the view menu: Brief, Full, Comments, Thumbnail View, _Configure custom columns..._, the
user custom-column views, and any custom-column views supplied by the current file-system plugin (05 › Column header).

_Basis: observed on Windows 11 (directory sort, plugin columns) and under Wine (header look, `[Auto]`); help:
add_tabstopheader, show_sort, show_shortlong, dlg_display, menu_show, inisettings1–3._

## 6. File list rendering

### 6.1 Rows in Full view

The first row is `[..]` (parent directory, with an up-arrow folder icon), except in a drive root (§6.2). Directories
follow, then files, each group in the current sort order (§5).

| Column | Content                                                                                                                                                                                                                                                                           | Alignment | Notes                                                                                                                                                             |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Icon   | The file-type icon (§6.7). Folders use Explorer's yellow folder icon on Windows; `[..]` the up-arrow folder icon                                                                                                                                                                  | —         | Size per the Icons page: 32×32 on Windows 11 at 200 % (depends on DPI; see Appendix A). Hidden/system items get a red `!` overlay, hidden items are dimmed (§6.3) |
| Name   | The file name **without** its extension (aligned-extension mode, §6.2); folders as `[name]`                                                                                                                                                                                       | left      | Brackets and trailing `\` per _Show square brackets_ / _Append \\_ (§6.2)                                                                                         |
| Ext    | The extension without the dot (`exe`, `ini`, `dll`, `lnk`)                                                                                                                                                                                                                        | left      | Empty for folders                                                                                                                                                 |
| Size   | Bytes with thousands separators (`250,944`); `<DIR>` for folders; `<LNK>` for NTFS **symbolic links** and junctions (seen on the junction `Documents and Settings`)                                                                                                               | right     | Unit per _Size display_ (§6.4, default bytes). A computed folder size replaces `<DIR>` (§16.2)                                                                    |
| Date   | `MM/DD/YYYY hh:mm`, e.g. `10/11/2026 01:19`: date and time of last change, in local time                                                                                                                                                                                          | left      | Century, 12/24 h, seconds, separators and order configurable (§6.4)                                                                                               |
| Attr   | One position per flag `r a h s`, the letter when set, else `-`: `-a--` archive only; `----` for most folders; `r---` on Windows system folders such as `Program Files` and `Users`; `ra--` for a read-only file; `--h-`, `---s`, `--hs` (`$Recycle.Bin`), `-ahs` (`pagefile.sys`) | left      | Also `c` (NTFS compressed) and `e` (NTFS encrypted) when set (their position was not recorded). FTP listings show `----`                                          |

Attribute letters: `r` read-only, `a` archive, `h` hidden, `s` system, `c` NTFS compressed, `e` NTFS encrypted.

### 6.2 Names, extensions and folders

| Option (page)                                                                   | Effect                                                                                                                                                                                                           | INI                                              |
| ------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| _Show file extensions: directly after filename / aligned (with Tab)_ (Tabstops) | Directly: `name.ext`, as in Explorer. Aligned (default): the extension sits in its own left-aligned column at the Extension tabstop; the Extension tabstop can be edited only in aligned mode                    | `Aligned extension=1`                            |
| _Show square brackets [ ] around directories_ / _Append \\_ (Display)           | Directories shown as `[dir]`, as `dir\`, or both. To get both, tick _Append \\_ first, then the brackets. Brackets off and _Append \\_ on gives `bin\`, `docs\` and the parent `..\`, applied at once with Apply | `DirBrackets=1`: 1 brackets, 2 backslash, 3 both |
| _Show parent dir [..] also in root of drive_ (Display)                          | `[..]` also appears in a drive root and leads up to _My Computer_ (the list of all drives)                                                                                                                       | `ShowParentDirInRoot=0`                          |
| _Use long names (recommended)_ (Display)                                        | Untick only to work around problems, e.g. with network drives. **Cannot be changed while a background transfer is running.** While off, renaming to a long name **truncates it to 8.3**                          | `UseLongNames=1` (`cm_SwitchLongNames`)          |
| _Show old 8.3 filenames lowercase (like explorer)_ (Display)                    | Short DOS names, stored in upper case, are shown in lower case except the first letter. Can cause problems on UNIX network drives                                                                                | `Small83names=0` (`cm_Switch83Names`)            |
| _Limit width of brief view column to: [200] Pixels_ (Display)                   | §8.2                                                                                                                                                                                                             | `BriefViewWidthLimit=`                           |

- Names starting with a dot are ordinary names: a dot-file without the Hidden attribute is listed normally.
- `descript.ion`, which holds file comments, carries the Hidden attribute and is therefore not listed with default
  settings (07 › File comments).
- In virtual folders such as MTP devices or libraries, sizes and time stamps are shown when `VirtualFolderDetails=1`
  (can be slow); `WarnMissingExtensions=1` warns there when file extensions are hidden.

### 6.3 Hidden and system items

| Option (page)                                       | Effect                                                                                                                                                                                          | INI                                                                                                                                                                           |
| --------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| _Show hidden files_ / _Show system files_ (Display) | Two switches: items with the H attribute, items with the S attribute. Some system folders need the second. With the default (both off) files with the Hidden or System attribute are not listed | `ShowHiddenSystem=0`: 0 neither, 1 both, 2 hidden only, 3 system only; `cm_SwitchHidSys`, `cm_SwitchHid`, `cm_SwitchSys` (parameter 0 toggle, 1 on, 2/-1 off, +4 do not save) |
| _Show '!' on hidden/system_ (Icons)                 | A red exclamation-mark overlay on the icon                                                                                                                                                      | `ShowHiddenSystemOverlay=1`                                                                                                                                                   |
| _Dimmed hidden files_ (Icons)                       | **Hidden** items get a lighter icon, as in Explorer                                                                                                                                             | `ShowHiddenDimmed=1`                                                                                                                                                          |
| (ini only)                                          | `c:\users\<user>\Appdata` is always shown, even though it is hidden and hidden files are off                                                                                                    | `AlwaysShowAppdata=1`                                                                                                                                                         |

Example with both shown (`cm_SwitchHidSys 5`, i.e. on + do not save), root of `C:` on Windows 11:

| Entry                                       | Size column   | Attr           |
| ------------------------------------------- | ------------- | -------------- |
| `[$Recycle.Bin]`                            |               | `--hs`         |
| `[Documents and Settings]` (a junction)     | `<LNK>`       | `--hs`         |
| `[ProgramData]`                             |               | `--h-`         |
| `[Recovery]`, `[System Volume Information]` |               | (not recorded) |
| `DumpStack.log.tmp`, `swapfile.sys`         |               | `-ahs`         |
| `pagefile.sys`                              | 5,368,709,120 | `-ahs`         |

The footer counts include the shown hidden and system items (`0 / 3 file(s), 0 / 14 dir(s)`).

### 6.4 Data formats (Tabstops/Data Formats page)

| Option                                                                                                                                                           | Rule                                                                             | INI                                                                |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| Separators: Date (`<default>` · `/` · `-` · `.`), Time (`<default>` · `:` · `.`), Thousands (`<default>` · `,` · `.` · space), Decimal (`<default>` · `,` · `.`) | By default from the Control Panel                                                | `CustomSeparators=0000`: 4 characters in that order; `0` = default |
| _Show century in date (20xx)_                                                                                                                                    | `1996` instead of `96`                                                           | `ShowCentury=1`                                                    |
| _Use 12 hour AM/PM format_                                                                                                                                       | Time followed by `a` (AM) or `p` (PM); otherwise 24-hour                         | `ShowAMPM=0`                                                       |
| Date format: `<default>` · MM/DD/YYYY · DD/MM/YYYY · YYYY/MM/DD                                                                                                  | Order of the date parts                                                          | `CustomDateFormat=-1` / 0 / 1 / 2                                  |
| time: hh:mm · hh:mm:ss                                                                                                                                           | Show seconds                                                                     | `CustomTimeFormat=0` (1 = seconds)                                 |
| _Show directory count in footer_                                                                                                                                 | Adds e.g. `, 5 / 7 dir(s)` to the status line (§16.1)                            | `DirsInFooter=1`                                                   |
| Size display (file lists)                                                                                                                                        | Table below                                                                      | `SizeStyle=0` (bytes)                                              |
| Header/footer                                                                                                                                                    | Same list, for the free-space text, the status line and the copy-progress dialog | `SizeFooter=1` (kbytes)                                            |

| UI entry               | Code | Rule                                     |
| ---------------------- | ---- | ---------------------------------------- |
| bytes                  | 0    | Exact bytes (file-list default)          |
| kbytes                 | 1    | 1 k = 1024 bytes (header/footer default) |
| dynamic (x k/M/G)      | 2    | Unit chosen by size: bytes, k, M, G      |
| dynamic (x.x k/M/G)    | 3    | Same, 1 decimal                          |
| dynamic (x k/M)        | 4    | No G: files over 1 GB still in M         |
| dynamic (x.x k/M)      | 5    | Same, 1 decimal                          |
| dynamic (x k/M/G/T)    | 6    | Up to T                                  |
| dynamic (x.x k/M/G/T)  | 7    | Same, 1 decimal                          |
| dynamic (x.xx k/M/G)   | 8    | 2 decimals, up to G                      |
| dynamic (x.xx k/M/G/T) | 9    | 2 decimals, up to T                      |

- `SizeStyle1000=0` uses binary units (1 k = 1024, 1 M = 1024 k, …); 1 uses decimal (1000) and overrides the "1 kbyte =
  1024" rule. The Windows Properties dialog always uses binary.
- The copy-progress dialog follows _Header/footer_ unless `SizeTransfer=` is set; values 0 and 1 there are ignored and
  mean automatic bytes/kbytes.
- The thresholds at which the dynamic styles change unit are not documented (not recorded).
- `AlignNumberFix=1` fixes misaligned digits in the size/date/time columns with some OpenType fonts (e.g. Segoe UI).

### 6.5 Tabstops

- **Fields:** Extension, Size, Date/Time, Attributes, Comments (fixed). Pixel values, which can also be nudged with the
  scroll bars beside them. Defaults on Windows 11 at 200 %: 176 / 234 / 238 / 299 / 91 (depend on DPI and font; see
  Appendix A). _Default_ restores the first-start values.
- Dragging the header separators (§5.6) changes the same values; only _Save Position_ keeps them.
- **Adjust Tabs to window width** (on): when the main window is resized, the name column changes width so that the
  extension, size, date and attribute columns stay **right-aligned**.
- **Storage:** resolution section `Tabstops=` with values in the order size, date/time, attributes, extension, window
  width, comments, size-minus-extension (the last is used only when the extension follows the name directly). Fallback
  `[Tabstops]`, used when nothing is stored for the current resolution: `0`=size, `1`=date/time, `2`=unused,
  `3`=attributes, `4`=extension, `5`=comment, `6`=reference window width, `AdjustWidth=1`.

### 6.6 Cursor, selection and row states

| State                                                    | Default look                                                                                        |
| -------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Normal row                                               | Black text on a white background; optional alternating _Background 2_                               |
| **Selected**                                             | Red text (_Mark color_, `[Colors] MarkColor=255`)                                                   |
| **Cursor** (active panel)                                | Light-blue filled bar with a darker blue 1 px border on Windows 11 (_Use Windows theme for cursor_) |
| Selected + cursor                                        | Red text on the cursor bar                                                                          |
| Cursor in the inactive panel                             | Not drawn, unless `InactiveFocus` is set                                                            |
| Item while its context menu or a delete question is open | Drawn red                                                                                           |

The colour options, inverted cursor/selection, focus frames and dark-mode variants are in 02 › Cursor and selection
rendering. Colours by file type can override the text colour per mask (§7).

_Extra lines below cursor: [4]_ (Operation page) keeps that many rows visible beyond the cursor when moving with the
keyboard: `ScrollingTopMargin=4`, `ScrollingBottomMargin=4` (the dialog sets both), `ScrollingMarginFlags=3` (1 =
vertical lists, 2 = Brief view).

### 6.7 Icons

With icons enabled (Icons page, _Show icons to the left of the filename_), the icon shows the file type:

| Item            | Icon                                                                                                     |
| --------------- | -------------------------------------------------------------------------------------------------------- |
| Folder          | Folder icon; special folders (recycle bin, servers in Network Neighborhood) their own icons when enabled |
| Archive         | Parcel                                                                                                   |
| Program         | Window (the real EXE/LNK icons are extracted with _All associated + EXE/LNK_, the default)               |
| Associated file | The icon of its program                                                                                  |
| Other files     | White sheet                                                                                              |
| Hidden/system   | An extra `!` (§6.3)                                                                                      |

The icon options (sources, overlays, size, extra space, effect on row height) are in 02 › Icons.

### 6.8 Tooltips

| Option (Display page)                                  | Rule                                                                                                                                                         | INI                                                                                                                                                                                |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| _Show filename in file list as tooltip if truncated_   | When a name does not fit, the full name appears after about **1 s** of pointing. A click or double click removes it                                          | `FileTipWindows=0` (for Full view); `FileTipWindowsOnIcon=0`: 1 = only over the icon (or where it would be), 2 = Win32-style tip over the icon and full name over a shortened name |
| └ _Win32-style tips with file comments (if available)_ | The tip is shown **below-right of the mouse** and adds NTFS comments, MS-Office embedded comments, `files.bbs`/`descript.ion` comments. **Any key hides it** | `Win32TipWindows` (defaults to `FileTipWindows`)                                                                                                                                   |
| └ _Comments from descript.ion/files.bbs_               | Include those comments (created with `Ctrl+Z`)                                                                                                               | `OleComments`                                                                                                                                                                      |
| └ _Comments from Explorer (OLE2)_                      | Comments set via Properties (Alt+Enter) in Explorer or TC, stored in NTFS streams; also tools such as Mp3ext                                                 | `OleComments=1`: 0 comment files only, 1 both, 2 Explorer only, 3 none (plugins only)                                                                                              |
| └ _User-defined: [+]_                                  | Per-file-type tips built from content-plugin fields, e.g. one set for `*.jpg`, another for `*.mp3`                                                           | `[HintsCustomField]` `xexts=` / `xfields=`; `HintMultiFilters=0` (1 = tips of all matching filters)                                                                                |

- The sub-options are enabled only while the parent option is ticked.
- `cm_ShowHint` shows the file tip window from the keyboard; `cm_SwitchFileTipWindows` toggles the option.
- _Show volume labels/network paths for drives_ concerns the drive list (§2.1); button tooltips are in 02 › Button bars.

### 6.9 Font and row height

- On Windows 11 a fresh installation showed **Segoe UI, 9** (regular) for the file lists; the help names Segoe UI
  Semibold 9 for new installations and Microsoft Sans Serif 8 bold as the fallback (depends on host and font; see
  Appendix A and 02 › Fonts).
- **Row height** = max(icon height, font height) + _Extra space vertical_ (default 1 px); _Extra space horizontal_ is 2
  px. With Segoe UI 9 the row pitch was about 13 logical px (02 › Window geometry and rendering metrics).

_Basis: observed on Windows 11 (icons, cursor, attributes, hidden/system, brackets applied live) and under Wine (row
layout); help: add_filelist, dlg_display, dlg_configicons, dlg_configtabs, add_tabstopheader, inisettings1–3._

## 7. Colours by file type

- **Enabling:** the checkbox next to _Define colors by file type…_ on the Color page (`ColorFilters=1`), or
  `cm_SwitchColorsByFileType`.
- **What can be matched:** everything that Num+ selection can match (§13.4): wildcard masks, regular expressions written
  with a leading `<`, and predefined selection types (search templates, which can also test attributes, size, date and
  plugin fields).
- **Effect:** the matching entry sets the **text colour** of the item in the file lists.
- **Priority = list order:** the first matching entry decides the colour. Example: with a ZIP entry above a read-only
  entry, a read-only ZIP gets the ZIP colour. Entries are reordered by drag & drop.
- **Editing:** the _Define colors by file type..._ button opens a dialog with the label "File types (sort by drag&drop,
  edit with \<spacebar\>):" above a list in which each entry is drawn in its colour, and the buttons [Add...] [Edit...]
  [Delete] [Dark<->Normal] [OK] [Cancel] (the dialog itself: 13 › Color page):
  - double-click or Space edits the entry and its colour;
  - _Add…_ asks first for the file type (the "Specify file type" box of §13.4), then for the colour; _Edit…_ and
    _Delete_ work on the selected entry;
  - OK saves; Cancel discards.
- **Quick enable/disable:** for an entry starting with `*` (e.g. `*.txt`), clicking the `*` changes it to `-` (`-.txt`),
  which disables it. A file literally named `-.txt` would still match.
- **Dark<->Normal:** switches which colour set is being edited. Normal-mode colours are converted automatically to
  suitable dark colours, and each can be overridden separately.
- **Slow plugin fields:** plugin data for colour filters is fetched in a background thread when the plugin reports a
  delayed or on-demand field, but only if the filter uses fields of just that plugin and the internal TC plugin; using
  the quick filter stops this background retrieval.
- **INI** (`[Colors]`): `ColorFilterN=` the type string; `ColorFilterNColor=` the colour; `ColorFilterNColorDark=` the
  **dark** colour, a comma, then the normal colour it was derived from (so that values changed by older versions can be
  detected). These keys cannot be overridden in `[ColorsDark]`.

_Basis: observed under Wine (dialog layout); help: def_colors_by_file_type, dlg_configcolor, inisettings1, inisettings3;
change log for background retrieval._

## 8. View types

### 8.1 Overview and persistence

| View                   | Key             | Command                                          | `[left]` / `[right]`                  |
| ---------------------- | --------------- | ------------------------------------------------ | ------------------------------------- |
| Brief                  | `Ctrl+F1`       | `cm_SrcShort`                                    | `ShowAllDetails=0`                    |
| Full ("long", default) | `Ctrl+F2`       | `cm_SrcLong`                                     | `ShowAllDetails=1`, `SpecialView=0`   |
| Comments               | `Ctrl+Shift+F2` | `cm_SrcComments`                                 | `ShowAllDetails=1`, `SpecialView=1`   |
| Thumbnails             | `Ctrl+Shift+F1` | `cm_SrcThumbs`                                   | `ShowAllDetails=1`, `SpecialView=2`   |
| Custom columns n       | `Shift+F1` menu | `cm_SrcCustomView<n>`                            | `ShowAllDetails=1`, `SpecialView=n+2` |
| Tree                   | `Ctrl+F8`       | `cm_SrcTree`                                     | `ShowAllDetails=2`                    |
| Quick View             | `Ctrl+Q`        | `cm_SrcQuickView` (shown in the **other** panel) | —                                     |

- `SpecialView` is kept separate from `ShowAllDetails` so that older versions do not break.
- The Show menu draws the current view as a checked radio item (the column header's context menu offers the same choice,
  05 › Column header). The default button bar's _Brief_, _Full_ and _Thumbnail view_ buttons are drawn pressed for the
  current view.
- Brief, Full, Comments, Thumbnails and custom columns are mutually exclusive; the separate tree (§8.7) and Quick View
  (§8.8) combine with any of them. View modes (§10) bundle a view type with sort order and colours.
- `cm_SrcComments` and the other `cm_*Comments` commands accept 0 / none = toggle, 1 = on, 2 or -1 = off.

### 8.2 Brief

- Names only (icon + name, the extension right-aligned in its cell) in newspaper columns, flowing top to bottom, then
  left to right.
- A column is as wide as the longest name, limited only by the panel width. _Limit width of brief view column to: [200]
  Pixels_ caps it (`BriefViewWidthLimit=`; the edit box is enabled only when ticked). `BriefViewWidthLimitMin=0` is the
  minimum width (0 = the width of `wwwwwwww.www` in the current font).
- The header shows `Name | Ext | Size | Date` as sort buttons only.
- The status line shows the details of the item under the cursor instead of the totals (§16.1).
- `←` / `→` move the cursor between columns (in the other views they move the caret in the command line); `Shift+←/→`
  moves the command-line caret.

### 8.3 Full

The default view: icon, name, extension, size, date and time, attributes (§6.1).

### 8.4 Comments

- Shows the comment from `descript.ion` or `files.bbs`. If both files exist in a folder, the one preferred in Operation
  › _File comments_ is used. Comments are created and edited with `Ctrl+Z` (07 › File comments).
- The header row is **unchanged**: Name, Ext, Size, Date, Attr, all narrow.
- Each row shows name and extension, then the comment text **starting at the Size column**. Folders show nothing after
  the name.
- A multi-line comment is shown on one line, with a space in place of each line break.
- The panel divider in this view is stored separately (`DividerComments=500`).

### 8.5 Thumbnails

- A grid of square tiles, default **96 × 96** px (Configuration › Thumbnails; the drawn size depends on DPI, see
  Appendix A), with the caption below: name left, extension right (`name ext`). A long caption is shortened with `..`,
  e.g. `gree..png`. The column header row stays; the list scrolls vertically; `[..]` is a large up-arrow tile.
- **Pictures:** images get real previews (on Windows 11 PNG and JPG through the shell thumbnail provider); text files
  (`*.txt *.ini`) show their first lines in a miniature font; executables use their icon; folders a folder icon. Icons
  shown in thumbnail mode have the size `ThumbIconSize=48`.
- **Sources, in order:** internal previews embedded in images (EXIF, camera RAW), Lister plugins, the Explorer method
  (OLE2, the only method that works in virtual folders), Irfanview/XnView, plain-text thumbnails; each with its own
  mask. The masks, the thumbnail database (cache) and its compaction are on the Thumbnails page (13 › Thumbnails page).
- **Custom fields:** extra text lines below the name, e.g. the image size or camera data from a content plugin (_Show
  custom fields below thumbnails_, `ThumbsCustomField=`; per file type in `[ThumbsCustomField]`; same field syntax as
  custom columns, §9.3).
- **Where thumbnails work:** the normal file system; **not** archives or FTP; some file-system plugins; in virtual
  folders thumbnails cannot come from Lister plugins.
- **Loading:** `PreloadThumbnails=1` loads the thumbnails of the whole directory on open; `2` also in branch view; `3`
  only the next two rows; `0` only when scrolled into view.
- **Zoom:** 10–200 % in 10 % steps with `Ctrl+mouse wheel`, `cm_ZoomIn` or `cm_ZoomOut`; both accept an absolute
  percentage (`cm_ZoomIn 150`). `cm_ZoomIn 200` doubled the tile size at once; `cm_ZoomOut 100` restored it. Stored as
  `ThumbScaleFactor=100` in the resolution section (with `_dpi` and `_<dpi>` variants).
- `cm_ReloadSelThumbs` reloads the thumbnails of the selected files. `[Colors] ThumbnailFrame=-1` sets the frame colour
  (-2 = invisible).
- No thumbnail-specific keys exist; the other panel keys apply.

### 8.6 Tree view inside a panel

`Ctrl+F8` (`cm_SrcTree`) turns the panel into a directory tree.

| Mode (Display page)                   | Behaviour                                                                                                                                                                             |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Default, Explorer style               | Reads only the top-level directories at first. Branches expand on demand with `Num +` / `Num -` or by clicking the `+`/`-` (or triangle) left of the folder icon                      |
| _Always load complete directory tree_ | Loads and shows the **whole tree of the current drive** at once. The tree root is the drive root, and **no special-folder icons** are shown. **No effect on the separate tree panes** |

- **Link to the other panel:** the tree chosen for the left panel shows the tree of the drive in the **right** panel
  (and vice versa, unverified), and is used to navigate the other panel. With _Tree: Press ENTER to open dir in other
  window_ (default on), Enter opens the folder under the tree cursor in the other panel; with it off, the folder under
  the cursor opens there **automatically** as the cursor moves.
- **Tree cache** (complete tree only): the tree is saved as `treeinfo.wc` in the **root of the drive** if writable;
  otherwise, and always for network shares and for the drive that holds the Windows directory, in the thumbnail-cache
  folder (normally `%LOCALAPPDATA%\GHISLER\`) with the drive letter appended (`treeinfoC.wc`, Hidden attribute, 12 ›
  Reading the tree and the tree cache; plain text, one `[relative\path]` line per directory; format in 19 ›
  `treeinfo*.wc`). When TC itself creates or deletes directories it updates only this file (up to `TreeUpdateLimit=2048`
  KB) instead of rescanning. After **external** changes, rescan with `F2` / `Ctrl+R`. `TreeFileLocation=` relocates the
  file (`%D%` drive letter or share root with `\` replaced by `_`, `%R%` root path, `%L%` volume label); per-drive
  overrides `TreeFileLocationE=` and `TreeFileLocation__server_share=` work only if `TreeFileLocation=` is also set.
- `OldStyleTree=0` (panel trees only): 0 = Explorer-style tree for all drives; 1 = always load the full tree of a drive;
  2 = expandable tree for the current drive only. `Tree=0`: 0 = sorted by name, 1 = unsorted.
- When a large directory is expanded with the mouse, the mouse pointer is moved so that it stays on that directory
  (`AllowSetCursorPos=1`).
- Rendering: `[Colors] TreeLineColor=-1` (-2 = invisible) and `TreeTriangles=-1` (0 = `[+]` boxes, 1 = triangles if
  supported, -1 = TC decides) apply to panel trees, separate trees, the Directory Tree dialog and the FTP connect
  dialog.

### 8.7 Separate tree

The toolbar button _Switch through tree panel options_ and _Show › Separate Tree_ have three states (`SeparateTree=0`):

| State | Show menu item              | Command              | Effect                                                                                                                                                                     |
| ----- | --------------------------- | -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0     | 0 (None)                    | `cm_SeparateTreeOff` | No tree pane                                                                                                                                                               |
| 1     | 1 (One For Both Panels)     | `cm_SeparateTree1`   | One tree pane at the far left of the left panel; it shows, and scrolls to, the current directory of the **active** panel. Choosing a folder in it changes the active panel |
| 2     | 2 (Two, One For Each Panel) | `cm_SeparateTree2`   | Each panel gets its own tree pane on its left                                                                                                                              |

- `Ctrl+Shift+F8` / `cm_SwitchSeparateTree` and the toolbar button cycle one tree → two trees → off.
  `cm_ToggleSeparateTree1` / `cm_ToggleSeparateTree2` switch that state on or off. Width `SeparateTreeWidth=160`,
  changed by dragging the splitter.
- It is always the **expandable** kind, never fully pre-loaded. Expand/collapse with `Num +` / `Num -` or the `+`/`-`
  signs (or triangles). The current folder is drawn red; drive nodes show their free space; the pane has a horizontal
  scrollbar.
- **Start-up:** `UpdateTreeAtStartup=1` expands the tree up to the current directory at start; with 0 it is expanded
  only at the first directory change or panel swap, which makes TC load faster.
- **Operations inside the tree:** Copy/Cut/Paste (clipboard), Delete, Rename (`Shift+F6`), Properties (`Alt+Enter`), the
  context menu, drag & drop (05 › Drag & drop; Space while dragging over the tree expands or collapses the branch under
  the pointer).
- **Focus:** `Shift+Tab` switches between the file list and its tree; `cm_FocusLeftTree`, `cm_FocusRightTree`,
  `cm_FocusSrcTree`, `cm_FocusTrgTree`.
- **Quick search** in the tree: §14.5.

Tree contents (drives and shell folders depend on the machine; the Wine list is in A › Host shell and environment):

```text
[Desktop]
└ [My Computer]
  ├ [C:]  1,406,258.2…        ← drive nodes show free space
  │ ├ [Program Files]
  │ ├ [Program Files (x86)]
  │ ├ [ProgramData]
  │ ├ [users]
  │ └ [windows]               ← the current folder is drawn red
  ├ [D:] …                   ← further drives of the machine
  └ [Control Panel]
[Documents]  … further shell folders of the host
```

Nodes have expand triangles; the Directory Tree dialog (12 › Directory Tree dialog) uses connector lines instead.

### 8.8 Quick View

- `Ctrl+Q` (`cm_SrcQuickView`, Show › Quick View Panel) replaces the **other** panel's list with an embedded Lister that
  shows the file under the cursor in the active panel. It updates as the cursor moves (also after `cm_GoToPreviousDir`,
  `cm_ShowOnlySelected`, branch-view commands and similar).
- It is a real Lister window, so Lister keys work there, e.g. `Ctrl+F` / `F7` to search (10 › The Lister window). Text
  files appear in a fixed-width font with a horizontal scrollbar along the bottom.
- **Header bar** (in place of the path bar): the file name followed by the name of the Lister plugin in use; for music,
  the track name and artist; on a **folder**, information about its occupied space. The Quick View panel has **no column
  header**.
- **Switching off:** press `Ctrl+Q` again, or **select another drive in the Quick View panel**. `cm_SrcHideQuickView`
  switches it off; `cm_UpdateQuickView` reloads it.
- **No plugins:** `cm_SrcQuickInternalOnly` shows the file with the internal Lister only.
- **Links:** `QuickViewFollowLinks=1` shows the contents of a link's target: 1 = always, but on network paths only when
  the link is also on the network; 2 = always; 0 = never; +4 = also `.url` files.
- **Width:** resize the Quick View panel and choose _Configuration › Save position_; that width (`DividerQuickView`) is
  then used whenever Quick View is on, independent of the normal divider (`Divider`).
- **`Ctrl+Shift+Q`** (`cm_SeparateQuickView`; no plugins: `cm_SeparateQuickInternalOnly`) opens a **separate**
  quick-view window, also Lister-based, that follows the cursor. Its title reads `Lister*`; the asterisk tells it apart
  from ordinary Lister windows. _Options › Save position_ in that window saves the position for separate quick-view
  windows only.
- Inside the quick search box `Ctrl+Q` toggles the Quick View panel (§14.3).

### 8.9 Vertical arrangement

_Show › Vertical Arrangement_ (`cm_VerticalPanels`, `PanelsVertical=1`) stacks the two file windows one above the other
instead of side by side; the vertical button bar moves to the right edge.

_Basis: observed on Windows 11 (thumbnails, zoom) and under Wine (views, separate tree, Quick View, comments view);
help: show_shortlong, show_tree, show_separatetree, show_thumbnails, quick_view, vertical_alignment, dlg_display,
dlg_configthumbs, inisettings2–3; change log for Quick View updates._

## 9. Custom columns

### 9.1 Configuration page

- _Configure columns for file system:_ `<General>` for the normal file system, or a file-system plugin that supports
  custom columns (plugins may need an update for this; examples are registry values or Linux permissions).
- _Custom column configurations (sort with drag&drop):_ up to **29** views (empty by default).
- _New_ creates a view and opens the editor; _Edit_ edits the selected view; _Copy_ duplicates it and opens the editor;
  _Delete_ removes it, saved **only after Apply or OK**.

### 9.2 Editor ("Custom columns")

```text
Configure view nr:  1            Name: [                      ]
Caption       Width   Align   Field contents
[Name ]       [80 ⇅]  [← ▾]   [Name                    ] [+]   ← fixed, disabled
[Ext  ]       [30 ⇅]  [← ▾]   [Ext                     ] [+]   ← fixed, disabled (width 0 hides it)
[     ]       [80 ⇅]  [← ▾]   [                        ] [+]   ← rows added with "Add column"
[ Add column ] [ Delete active column ]
[ ] Adjust Tabs to window width     [ ] Horizontal scrollbar
                                 [ OK ] [ Cancel ] [ Apply ]
```

| Element                                    | Rule                                                                                                                                                                    |
| ------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Configure view nr                          | Which of the 29 views is being edited                                                                                                                                   |
| Name                                       | Title in menus. **If empty, the view is not listed in menus**, but `cm_SrcCustomView<n>` (button or hotkey) still reaches it                                            |
| Caption                                    | Header text of the column. The first two columns, Name and Ext, are fixed; a width of 0 hides Ext                                                                       |
| Width                                      | In **dialog units**, so it depends on the large/small font mode                                                                                                         |
| Align                                      | `←` left (text) or `→` right (numbers)                                                                                                                                  |
| Field contents                             | Any mix of plain text and one or more field references (§9.3). `[+]` inserts a plugin field through _Choose plugin property_ (15 › The _Choose plugin property_ dialog) |
| Up/Down arrows                             | Appear when the cursor is in a column row and move that column; `Ctrl+PgUp` / `Ctrl+PgDn` do the same                                                                   |
| Add column / Delete active column          | Append a column at the end / delete the column holding the cursor                                                                                                       |
| Adjust Tabs to window width                | The name column resizes with the main window, as in Full view (§6.5)                                                                                                    |
| Horizontal scrollbar                       | Scrollbar when the fields need more than the panel width                                                                                                                |
| Switch to this view when using this plugin | Shown only for plugin column sets: switches to the view automatically on entering that file-system plugin (`AutoLoad=1`)                                                |

### 9.3 Field syntax

The same as in the Multi-Rename Tool (18 › Content fields):

| Form                                   | Meaning                                                                                                                                         |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `[=plugin.field.unit]`                 | Field `field` of content plugin `plugin`; `unit` is optional: a unit the field supports, or a date formatter                                    |
| `[=plugin.field.unit:4-7]`             | Only characters 4–7 of the value                                                                                                                |
| `[="prefix"plugin.field.unit"suffix"]` | `prefix` / `suffix` are output **only if the field exists and has a valid value**; otherwise nothing is output (useful for units such as " kB") |
| `[=<fs>.field]`                        | In plugin column sets: a field of the current **file-system plugin** itself                                                                     |

Date formatters for date, time and date/time fields, in place of a unit: `Y` 4-digit year, `y` 2-digit year, `M` month,
`D` day, `h` hour (24 h), `m` minute, `s` second (all 2-digit), `v` 3-digit milliseconds, `a` 2-digit hour (12 h), `P`
`am`/`pm`, `p` `a`/`p`.

### 9.4 Using custom views

- **Choosing:** _Show › Custom Columns Mode ▸_ / `Shift+F1` (`cm_SrcCustomViewMenu`; the submenu ends with _Configure
  custom columns..._), or the header context menu (§5.7).
- **Commands:** `cm_SrcCustomView1…29` (IDs 271–299), `cm_TrgCustomView…` (421–449), `cm_LeftCustomView…` (71…),
  `cm_RightCustomView…` (171…); `cm_SrcNextCustomView`, `cm_SrcPrevCustomView` etc.; `cm_CustomColumnDlg` edits the
  current view; `cm_LeftSwitchToThisCustomView` / `cm_RightSwitchToThisCustomView` are for scripting (lparam = view).
- **`OPENCUSTOMVIEW <title>`** switches to the **first** view with that title (**case-sensitive**). Suffixes `L`, `R`,
  `S`, `T`, `B` = left, right, source, target, both (e.g. `OPENCUSTOMVIEWL my_view`).
- **Sorting:** a click on a custom column header sorts by it (`customsortorder=100+n`, §5.2).
- **Slow (on-demand) fields** are loaded in the background or on request: `cm_LoadAllOnDemandFields`,
  `cm_LoadSelOnDemandFields`, `cm_ContentStopLoadFields`.
- **Typical uses:** creation date/time, program version, or plugin data such as MP3 artist/title.

### 9.5 Storage

`[CustomFields]`; plugin sets in `[CustomFields_<PluginName>]` with the same keys plus `AutoLoad=`:

| Key            | Content                                                                    |
| -------------- | -------------------------------------------------------------------------- |
| `Titles=`      | View names separated by `\|`                                               |
| `Headers<n>=`  | Column captions separated by the literal text `\n`                         |
| `Contents<n>=` | Column contents separated by `\n`                                          |
| `Widths<n>=`   | Column widths; **negative = right-aligned**                                |
| `Options<n>=`  | Window width for auto-sizing `\|` 1 = horizontal scrollbar `\|` screen dpi |

_Basis: observed under Wine (page and editor layout); help: dlg_configcustomcolumns, dialog_usercolumns,
show_customcolumns, add_tabstopheader, inisettings3._

## 10. View modes

### 10.1 Model

- A **view mode** is a named preset applied to a tab or panel: view type, sort order, tab colour and icon, background
  colours and auto-run commands.
- `<default>` is the standard mode. It is applied whenever no Auto Switch rule matches (§11), has no colours or icon,
  and cannot be deleted (`cm_SrcViewMode0`).
- **Managing the list** (View Mode page): _Add..._ asks "Add new view mode" (title "Total Commander") for a name, e.g.
  "Photos"; _Delete..._; _Change Title..._; `[^]` / `[v]` reorder.
- **Applying a mode:** _Show › Custom View Modes ▸_ (`cm_SrcViewModeList`; the submenu lists `<default>`, a separator,
  the user modes and _Configure view modes_); the tab context menu's list of modes (§4.7); `cm_SrcViewMode<n>`
  (8501…8749), with `Trg` 8751…, `Left` 8001…, `Right` 8251…; Auto Switch (§11).
- `[left] ViewMode=-1` holds the active tab's mode; -1 or 10001 means "determine again".

### 10.2 Settings per mode

| Field                     | Values and rule                                                                                                                                                                                                                                       |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Columns view              | Unchanged · Brief · Full · Comments · Thumbnail View · ──── · the custom column views                                                                                                                                                                 |
| Sort order                | Unchanged · Name · Ext · Size · Date · Unsorted; [ ] Descending (newest/largest first)                                                                                                                                                                |
| Additional sort orders    | `[edit] [+]`: further keys, e.g. extension then size                                                                                                                                                                                                  |
| Tab color and icon        | `[colour ▾] [>>]` and `[icon preview] [>>]`: colour and icon of the folder tab (disabled for `<default>`; drawing per `TabFullColor`, §4.3)                                                                                                           |
| Priority                  | Gives the **view-mode icon** priority over icons from other sources, e.g. `desktop.ini` or the drive icon in a root directory                                                                                                                         |
| Background / Background 2 | `[colour ▾] [>>]`: panel background and the alternating-line colour, e.g. to mark FTP or plugin panels. The help advises a colour only slightly different from the normal one (very light blue on white). **Set separately for normal and dark mode** |
| Auto-run commands         | `[edit] [+]`: §10.3                                                                                                                                                                                                                                   |

### 10.3 Auto-run commands

The field holds `cm_…` and `em_…` commands:

```text
field      := enterList [ "|" leaveList ]
enterList  := [flags] command { "," command }
flags      := "-"  → do not run when the mode is entered by switching tabs;
                     run only on directory changes inside a tab
            | "*"  → run on every directory change into AND within this mode
                     (without "*": only when switching from a different mode to this one)
leaveList  := commands run when this view mode is left
```

Example: `cm_100percent|cm_50percent` widens the active panel to the full window when the mode (e.g. a thumbnails mode)
becomes active, and restores 50:50 when it is left.

```text
on mode change for a panel (oldMode → newMode, cause = dirChange | tabSwitch):
    if oldMode ≠ newMode:
        run oldMode.leaveList
        if not (newMode has "-" and cause = tabSwitch): run newMode.enterList
    elif cause = dirChange and newMode has "*":
        run newMode.enterList
```

The help says to put `-` / `*` "in front of the commands"; whether each command can carry its own flag or one flag
covers the whole list is not stated (unverified).

### 10.4 Storage

`[ViewModes]`: `x_name=` the name; `x_icon=` the tab icon; `x_options=` view, sort order, reversed, additional sort
orders, tab colour, background, background 2; `x_commands=` the auto-run commands. The colours in effect for a panel are
in `[left]` / `[right]`: `ActivePanelColor`, `ActivePanelColor2`, `ActivePanelColorDark`, `ActivePanelColorDark2` (-1 =
none).

_Basis: observed under Wine (page layout, Add prompt); help: dlg_configviewmode, show_customviewmodes, foldertabs,
inisettings3._

## 11. Auto Switch Mode

### 11.1 Evaluation

- On/off: _Automatically switch view mode on directory change_ (`[ViewModeSwitch] Enabled=1`;
  `cm_ToggleAutoViewModeSwitch`, which accepts 0 toggle, 1 on, 2/-1 off, +4 do not save). The checkbox becomes checked
  automatically when the first rule is added.
- After every directory change the rules are tested **in list order**. The **first** matching rule sets its mode; if
  none matches, `<default>` is set.

```text
onDirectoryChange(panel):
    if not Enabled: return
    mode = <default>
    for rule in rules (top to bottom):
        if matches(rule): mode = rule.mode; break
    if the user picked a mode by hand while auto-switching was on
       and mode == panel.AutoViewMode:      ; same automatic result as when the user overrode it
        keep panel.ViewMode                 ; the manual choice survives
    else apply(mode)

matches(rule):           ; sub-rules joined by & (AND) and | (OR); AND binds tighter
    return OR over groups( AND over subrules in group( sub.matches ) )
```

Example of precedence: `A & B | C & D` = `(A AND B) OR (C AND D)`.

**Manual override:** when the user picks a mode by hand while auto-switching is on, the hand-picked mode is stored in
`ViewMode=` and the automatic result in `AutoViewMode=`. The manual mode stays as long as the automatic result keeps
equal to the stored `AutoViewMode`.

### 11.2 Sub-rules

Each rule consists of one or more sub-rule rows:

```text
Rule:                    Directory:              File types:
[+: Must match       ▾]  [                ] [>>] [                 ]
[ More sub-rules ] [ Fewer sub-rules ]
Set this mode: [<default> ▾]
```

The _Rule_ combo of a row offers one combined list: `+: Must match`, `-: Must not match`, `%: At least 50% match`,
`?: At least one match`, `D: Directory`, `L: With drive letter`, `U: UNC path: \\Server`, `V: Virtual folder`,
`F: FTP connection`, `A: Archive`, `P: File System Plugin`, `S: Search result`.

| Match type | Condition                                                         |
| ---------- | ----------------------------------------------------------------- |
| `+`        | The directory matches **and all** file names match the file types |
| `-`        | The directory matches **and no** file name matches the file types |
| `%`        | **At least half** of the file names match (e.g. "50 % pictures")  |
| `?`        | **At least one** file name matches                                |

| Folder type | Location                                                                                                                                                              |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `D`         | A directory such as `c:\dir` **or** `\\server\share`                                                                                                                  |
| `L`         | A directory with a drive letter. The edit box may hold one or more **drive-type digits**: 1 removable hard disk, 2 USB stick, 3 fixed, 4 remote, 5 CD-ROM, 6 RAM disk |
| `U`         | A UNC path `\\server\share`                                                                                                                                           |
| `V`         | A virtual folder, e.g. the Desktop                                                                                                                                    |
| `F`         | An FTP connection (Ctrl+F / Ctrl+N)                                                                                                                                   |
| `A`         | Inside an archive, e.g. `c:\dir\file.zip`                                                                                                                             |
| `P`         | A file-system plugin, e.g. `\\\Secure FTP\connection`                                                                                                                 |
| `S`         | A search result (_Feed to listbox_)                                                                                                                                   |

_More sub-rules_ adds a row; _Fewer sub-rules_ removes the **bottom** row. _Set this mode_ picks the target mode
(`<default>` or a user mode).

### 11.3 Directory pattern and file types

- **Directory** is compared with the current directory. Wildcards are allowed anywhere; a **trailing `*`** makes the
  pattern match all subdirectories as well:

| Pattern              | Matches                                                                       |
| -------------------- | ----------------------------------------------------------------------------- |
| `c:\photos\`         | Only the folder `photos`                                                      |
| `c:\photos\*`        | `photos` and every folder below it                                            |
| `c:\photos\*2016*\*` | Folders below `photos` whose name contains `2016`, plus everything below them |

- **File types:** include masks separated by spaces; masks after `|` are exclusions. `*.doc *.docx *.xlsx` = Office
  files; `a*.* | *.bak *.org *.~*` = files starting with `a`, but not those backup types. Whether subfolders count as
  "file names", and how a rule with an empty list behaves, is not documented (unverified).

### 11.4 Rules list and storage

- The rules list (entries shown by their text, e.g. `*`) has _Add..._, _Delete..._ and `[^]` / `[v]`; the order is the
  evaluation order. While an incomplete rule was in the list, the dialog did not leave the page (observed; the dialog
  was cancelled).
- `[ViewModeSwitch]`: `Enabled=`; `x_rules=` the sub-rules, joined with `|&` (AND) and `||` (OR); `x_mode=` the mode to
  set.

_Basis: observed under Wine (page layout, rule list); help: dlg_configautomodeswitch, dlg_configviewmode, inisettings3._

## 12. Display filters

### 12.1 What decides whether an item is listed

An item appears in the file list only if it passes every layer below; `[..]` always stays.

| Layer                                            | Scope                          | Section                                 |
| ------------------------------------------------ | ------------------------------ | --------------------------------------- |
| Hidden / system attributes                       | Global setting                 | §6.3                                    |
| Ignore list                                      | Global list file               | §12.4                                   |
| Show files of type (incl. _Only Selected Files_) | Per tab (default) or per panel | §12.2, §12.3                            |
| Quick filter                                     | Temporary, current directory   | §14.4                                   |
| _Mark Newer, Hide Same Files_                    | Temporary comparison view      | 09 › Compare directories and Mark newer |

The current-directory bar always shows the mask of the _Show files of type_ filter (`c:\users\*.*`).

### 12.2 Show files of type

| Show menu item                     | Key        | Command               | Shows                                                                                           | `[left]` `show=`    |
| ---------------------------------- | ---------- | --------------------- | ----------------------------------------------------------------------------------------------- | ------------------- |
| All Files (default)                | `Ctrl+F10` | `cm_SrcAllFiles`      | Everything (after the hidden/system and ignore-list rules). Also removes an active quick filter | 1                   |
| Programs                           | `Ctrl+F11` | `cm_SrcExecs`         | `*.exe *.com *.bat *.pif *.cmd`                                                                 | 2                   |
| _(the last user mask, e.g. `*.*`)_ | —          | `cm_SrcUserSpec`      | Re-applies the latest custom specification                                                      | 3, with `userspec=` |
| Custom...                          | `Ctrl+F12` | `cm_SrcUserDef`       | Opens the mask dialog below                                                                     | 3                   |
| Only Selected Files                | —          | `cm_ShowOnlySelected` | §12.3                                                                                           | —                   |

The five items form one radio group in the Show menu. _Custom..._ opens a dialog with the same layout as the selection
dialogs (§13.4) and the label "Enter file types (e.g. _.doc;_.txt)" (title not recorded):

```text
Enter file types (e.g. *.doc;*.txt)
[*.*                                            ▾]
Or select predefined selection type:
┌──────────────────────────────────────────────┐
│ (saved search templates)                     │
└──────────────────────────────────────────────┘
                   [ Define... ] [ OK ] [ Cancel ]
```

**Mask syntax** (help: masks delimited with a space):

- Include masks are separated by spaces. After a `|`, **exclusions** follow. An exclusion ending in `\` matches
  **directories**.
- A predefined selection type (a saved search template) can be chosen instead of a mask; it brings the full search
  criteria.

| Spec                       | Effect                                 |
| -------------------------- | -------------------------------------- |
| `*.bmp *.gif *.jpg`        | Only these images                      |
| `*.* \| *.bmp *.gif *.jpg` | Everything except these images         |
| `*.* \| .cvs\`             | Hide directories named `.cvs`          |
| `*.txt \| *\`              | Only text files, and no folders at all |

The filter is stored per tab when `DirTabFilters=1` (`N_filter=`), otherwise per panel (§4.1). The full mask grammar is
in 18 › File masks.

### 12.3 Only Selected Files

- Hides every item of the panel that is **not currently selected** (`cm_ShowOnlySelected`). It belongs to the Show
  menu's filter radio group.
- Typical use: concentrating on a few files in a directory with thousands.
- It is a one-time snapshot (unverified: changing the selection afterwards is taken not to bring hidden files back).
  Show › All Files (`Ctrl+F10`) or re-reading the directory restores the full list.

### 12.4 Ignore list

- Configuration › Ignore list holds a TC-only list of names and paths that are **not displayed** (and not copied,
  counted, searched or synchronized). It is independent of the hidden/system attributes and is switched on and off as a
  whole: _Ignore (don't show) the following files and folders_ (`IgnoreListFileEnabled=1`, `cm_SwitchIgnoreList`: 0
  toggle, 1 on, -1/2 off, +4 do not save).
- The list is an external text file (`IgnoreListFile=`, default name `tcignore.txt`).
- Ignored items can still be reached directly: `cd` to an ignored folder, or opening an ignored file by name, works.
- The page's buttons _Add selected names with full path_ / _Add selected names_ take the selection of the last active
  panel.
- Entry syntax and the effect on file operations: 13 › Ignore list page.

_Basis: observed under Wine (menu, dialog label); help: show_files, only_selected, menu_show, dlg_configfoldertabs,
dlg_configignorelist, inisettings1, inisettings3._

## 13. Selection

### 13.1 Model

- The **selection** (marked items) is separate from the **cursor** (01 › Cursor, selection and the operand rule).
  Selected items are drawn in the mark colour (red by default, §6.6); the counts appear in the status line (§16).
- `[..]` is never selected.
- The selection belongs to the tab: switching tabs keeps it (§4.1); switching away from TC and back keeps it, also while
  a quick filter is active.
- Operations use the selection, or the item under the cursor when nothing is selected (01 › The operand rule). What
  happens to the selection after each operation is in 07 › Selection and refresh after an operation (copy clears the
  source selection; a skipped read-only delete clears it; Ctrl+C keeps it).
- _Selection (with Num +)_ on the Operation page: _Select files only_ / _Also select directories_ (default) decides
  whether **Num +**, **Ctrl+Num +** and **Num \*** also affect folders (`MarkDirectories=1`). "As configured" below
  refers to this option; the Shift variants give the other choice.

### 13.2 Mouse

| Mode (Operation page)                                                                           | Rules                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ----------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| _Use right mouse button (as in NC) - context menu after 1 second_ (default, `UseRightButton=1`) | The left button only moves the cursor. A **right click** toggles the selection of the item. **Right-drag** selects a range. **Holding** the right button opens the context menu: the help says "about 1 second", the INI default is `PopupDelay=500` ms; `ContextProgress=1` shows a progress bar while the button is held. **Touch screen:** hold a finger until a square appears, then drag to select; releasing without dragging opens the context menu |
| _Left mouse button (Windows standard)_ (`UseRightButton=0`)                                     | Explorer-like clicking. **Rubber band selection** (TC 9+, `UseRubberBandSelection=1`, enabled only in this mode): press **behind** the name of a file that is not selected and drag a rectangle; everything it touches is selected. Files must then be dragged by their names                                                                                                                                                                              |
| Both modes                                                                                      | **Shift+click** selects the range from the last click. _By clicking on icon_ (TC 8.5+, `IconClickSelection=1`): a click on the icon toggles that item; _Only on touchscreen_ (`IconClickSelection=2`) limits this to touch input                                                                                                                                                                                                                           |

Observed on Windows 11 and under Wine: a right click toggles the selection (red); after one file the footer read
`3,607 k / 3,607 k in 1 / 1 file(s)`. The general mouse model is in 05 › Mouse selection modes.

### 13.3 Keyboard

| Key                       | Action                                                                                                                                                                                                                                                                | Command                                                              |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `Insert`                  | Toggle the item under the cursor and move down                                                                                                                                                                                                                        | ≈ `cm_Reverse`                                                       |
| `Space`                   | Toggle the item. On an **unselected** folder, also compute its size and show it instead of `<DIR>` (`CountSpace=1`; Operation › _Calculate space occupied by subdirectories › when selecting with the space bar_). The cursor does not move unless `SpaceMovesDown=1` | —                                                                    |
| `Shift+↓`                 | Toggle the item and move down. Pressed 4× from `report_01` it selected `report_01`…`report_04` and left the cursor on `report_05`, unselected; footer `5 k / 8 k in 4 / 14 file(s)`                                                                                   | (not recorded)                                                       |
| `Num +` / `Shift+Num +`   | Select group (§13.4): as configured / the other choice                                                                                                                                                                                                                | `cm_SpreadSelection`; `cm_SelectFiles` / `cm_SelectBoth`             |
| `Num -`                   | Unselect group: **always files and folders** (for safety)                                                                                                                                                                                                             | `cm_ShrinkSelection`                                                 |
| `Shift+Num -`             | Unselect group: always **files only**                                                                                                                                                                                                                                 | `cm_ClearFiles`                                                      |
| `Ctrl+Num +`, `Ctrl+A`    | Select all, as configured. `Ctrl+A` selected all files **and** folders; footer `0 k / 0 k in 1 / 1 file(s), 4 / 4 dir(s)`                                                                                                                                             | `cm_SelectAll`                                                       |
| `Ctrl+Shift+Num +`        | Select all, the other choice                                                                                                                                                                                                                                          | `cm_SelectAllFiles` / `cm_SelectAllBoth`                             |
| `Ctrl+Num -`              | Unselect all: always files and folders                                                                                                                                                                                                                                | `cm_ClearAll`                                                        |
| `Ctrl+Shift+Num -`        | Unselect all files only (folders stay selected)                                                                                                                                                                                                                       | `cm_ClearAllFiles`                                                   |
| `Num *` / `Shift+Num *`   | Invert the selection: as configured / the other choice. Useful after comparing directories                                                                                                                                                                            | `cm_ExchangeSelection`; `cm_ExchangeSelFiles` / `cm_ExchangeSelBoth` |
| `Alt+Num +` / `Alt+Num -` | Select / unselect every file with the extension of the file under the cursor (Mark › _Select All With Same Extension_)                                                                                                                                                | `cm_SelectCurrentExtension` / `cm_UnselectCurrentExtension`          |
| `Num /`                   | Restore the selection from before the last file operation (§13.5)                                                                                                                                                                                                     | `cm_RestoreSelection`                                                |

The default button bar has an _Invert selection_ button (`Num *`). Further commands without default keys:
`cm_SpreadSelectionCurrentExt` (select group with the extension under the cursor pre-loaded), `cm_SelectCurrentName` /
`cm_UnselectCurrentName` (same name), `cm_SelectCurrentNameExt` / `cm_UnselectCurrentNameExt` (same name and extension),
`cm_SelectCurrentPath` / `cm_UnselectCurrentPath` (all items in the same path, for branch view and search results),
`cm_Select` / `cm_UnSelect` / `cm_Reverse` (select / unselect / toggle the item under the cursor and go to the next),
`cm_SelectFolders` and the other explicit variants (17 › Command catalogue).

**`SELECTFILES masks`** (button, hotkey, command line) selects matching items without the dialog; a saved selection type
is given as `>name`. Suffixes may be combined (`SELECTFILESDUT`): `D` folders only, `B` files and folders, `U` unselect,
`L` / `R` left / right panel, `T` target panel, `S` also folders when Shift is held while the command runs.

### 13.4 Select and unselect group

`Num +` opens **"Expand selection"**, `Num -` **"Shrink selection"** (Mark › _Select Group..._ / _Unselect Group..._):

```text
Specify file type, e.g. *.txt, or RegEx with leading '<', like <(a|b)
[*.*                                            ▾]
Or select predefined selection type:
┌──────────────────────────────────────────────┐
│ (saved search templates)                     │
└──────────────────────────────────────────────┘
                   [ Define... ] [ OK ] [ Cancel ]
```

- _Define..._ opens "Define selection", i.e. the Find Files dialog in template mode (09 › Find Files), to create a
  predefined selection type. It allows the same criteria as a search (attributes, size, date, content, plugins).
- The mask combo keeps a history (`[Selection]`); **Shift+Del** removes the highlighted history entry.
- When the panel shows _duplicate file_ search results, `Num +` opens the richer "Select duplicate files" dialog instead
  (09 › "Select duplicate files" dialog).

**Mask grammar** (complete rules in 18 › File masks and selection types):

- **Include and exclude:** `includes|excludes`, several masks separated by spaces. `|` is used because it cannot occur
  in a file name. `w*.*|*.bak *.old` selects everything starting with w, except `.bak` and `.old`; `|*.exe` selects
  everything except programs (an empty include part means all).
- **Regular expression:** start with `<`, e.g. `<(a|b)` (18 › Regular expressions).
- **Path-limited masks** (TC 9.1+, useful in branch view): `\sub1\sub2\*.ext` or `\*.ext` are relative to the **base**
  directory; `sub1\sub2\*.ext` (no leading `\`) matches that path below **any** subdirectory; `**` matches any number of
  directory levels, e.g. `subdir\**\*.txt` matches `subdir\subdir2\subdir3\test.txt`.
- **Related files:** `A>B` selects the files matching `A`, plus each file matching `B` whose name can be derived from a
  selected `A` file in the **same directory**. `*.jpg>*.cr2` gives `IMG_1057.JPG` together with `IMG_1057.CR2`;
  `*.jpg>crw*.cr2` pairs `IMG_1057.JPG` with `CRW_1057.CR2` (the B mask acting as a rename mask: `IMG_1057` →
  `CRW_1057`; unverified mechanism).

### 13.5 Saving and restoring the selection

| Command                                                     | Behaviour                                       |
| ----------------------------------------------------------- | ----------------------------------------------- |
| Mark › _Save Selection_ (`cm_SaveSelection`)                | Stores the selection in a single in-memory slot |
| Mark › _Restore Selection_ (`Num /`, `cm_RestoreSelection`) | Restores that slot                              |

Every file operation overwrites the slot automatically with the selection it started from, so `Num /` after an operation
brings back the selection that the operation cleared.

### 13.6 Selection files

**Mark › Save Selection To File** (`cm_SaveSelectionToFile`; ANSI / Unicode variants `cm_SaveSelectionToFileA` / `W`;
text command `SAVESELECTION`, `…A`, `…W`, where no suffix means Unicode on NT systems):

1. A standard "Save As" dialog opens in the current panel's folder, with an empty file name and _Files of type_ `*.txt`.
2. Saving as `sel` writes `sel.txt`: UTF-16LE with a BOM (`FF FE`), CRLF line ends, names only (no path), folders with a
   trailing `\`, **no** CRLF after the last name.
3. The panel is not re-read (with the default `WatchDirs=0` the new file appears only after `Ctrl+R`).

**Mark › Load Selection From File** (`cm_LoadSelectionFromFile`; text command `LOADSELECTION`, ANSI or UTF-16):

1. A standard "Open" dialog opens, _Files of type_ `*.*`.
2. Loading `sel.txt` selected exactly the saved items again and refreshed the panel.

- `cm_LoadSelectionFromClip` reads the names from the clipboard instead.
- `cm_SaveDetailsToFile` (and `…A`, `…W`, with headers `cm_SaveHdrDetailsToFile…`; text command `SAVEDETAILS`) saves all
  shown columns of the selected items to a file.
- The four Mark-menu clipboard commands (_Copy Selected Names To Clipboard_, _Copy Names With Path To Clipboard_, _Copy
  To Clipboard With All Details_, _Copy To Clipboard With Path+Details_) and their line formats are in 07 › Names to the
  clipboard (Mark menu). `LOADLIST` (load a list of names into the panel like a search result) is in 09 › Feed to
  listbox.

_Basis: observed on Windows 11 (right-click selection) and under Wine (keys, footers, selection files, dialog); help:
proc_select, options_mark, local_menus, dlg_config2, inisettings1–3; change log (selection kept with quick filter)._

## 14. Quick search and quick filter

### 14.1 Invocation modes

Configuration › Quick Search, group "Quick search (current dir)", stored as `AltSearch`:

| `AltSearch` | Option caption               | Trigger                                                                                                                                                                                                                                    | Menu access                                           |
| ----------- | ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------- |
| 0 (default) | Ctrl+Alt+Letters             | **Ctrl+Alt+letter** (or **AltGr+letter**) opens a small edit box below the active file list, pre-filled with that letter. Ctrl and Alt may then be released and further letters typed plainly                                              | Alt+letter opens the underlined menu                  |
| 1           | Alt+Letters                  | **Alt+letter** opens the box. Alt+Space (system menu) is not intercepted                                                                                                                                                                   | F9, F10, or Alt pressed and released, then the letter |
| 2           | Letter only                  | Explorer-like: typing jumps directly to the next matching name, **without a box**. Several leading characters may be typed; the typed prefix is **forgotten after about 1 s** without typing. Observed: `rep` → `report_01`, `n` → `notes` | Alt+letter                                            |
| 3           | Letters - with search dialog | Like 2, but with the edit box. A leading `*` typed from the main keyboard (not the numeric keypad) searches anywhere in the name                                                                                                           | Alt+letter                                            |
| 4           | Disabled                     | No implicit trigger. Quick search only through `cm_ShowQuickSearch` / `cm_QuickSearch` / `cm_QuickFilter` on a hotkey                                                                                                                      | Alt+letter                                            |

- In modes 2 and 3 typed letters **no longer reach the command line**; it is reached with `→` (`Shift+→` in Brief view).
  In mode 2, `Enter` opens the file under the cursor as usual (an `.md` file without association brought up Windows'
  "Select an app to open this .md file").
- In modes 0 and 1 plain letters go to the command line (02 › Command line).

### 14.2 Matching

Group "Exact name match:" on the same page turns the typed string _s_ into a pattern:

1. **Beginning (name must start with first typed character)** (`QuickSearchMatchBeginning=1`, checked): the name must
   **start** with _s_. Unchecked: `*` is put in front, so _s_ may occur anywhere. Example: `est` finds "Test.txt" only
   when unchecked.
2. **Ending (last character before a typed dot . must match)** (`QuickSearchExactMatch=0`, unchecked); applies when _s_
   contains a dot. Unchecked: each typed `.` is read as `*.` (anything before the dot), so `Te.tx` also finds "Test.txt"
   and `win.i` finds "wincmd.ini". Checked: the part before the dot must match exactly; `Te.tx` finds "Te.txt" but not
   "Test.txt".
3. Wildcards `*` and `?` may be typed. A leading `*` in mode 3 gives a match anywhere.

- `QuickSearchAllowNoMatch=0` (default): a keystroke or paste that would give **no** match is rejected. With `=1` it is
  accepted.
- `tcmatch.dll` / `tcmatch64` (path via `tcmatch=` / `tcmatch64=`, environment variables allowed) may replace the
  matching, e.g. for phonetic or Chinese input.

### 14.3 Movement, closing and keys in the box

- After each keystroke the cursor jumps to the **next** item, from the current cursor position on, that matches. `↓` /
  `↑` move to the next / previous match.
- **Esc** closes the box. Any other action (a command, a mouse click elsewhere) closes it automatically.

| Key in the box                                | Action                                                                                                     |
| --------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Letters, digits, `*`, `?`                     | Extend the search text                                                                                     |
| `Ctrl+X` / `Ctrl+C` / `Ctrl+A`, `Ctrl+Insert` | Standard edit: cut / copy / select all / copy                                                              |
| `Ctrl+V` / `Shift+Ins`                        | Paste, processed **as if typed** character by character; stops at the first character that would not match |
| `Ctrl+Y` or `Ctrl+Z`                          | Clear the field                                                                                            |
| `Ctrl+W` or `Ctrl+Backspace`                  | Delete the word left of the cursor                                                                         |
| `Ctrl+T`                                      | Delete the word right of the cursor                                                                        |
| Typing over selected text                     | Replaces it                                                                                                |
| `←` / `→`                                     | Move inside the box, except in Brief view, where they move between columns                                 |
| `Ctrl+Q`                                      | Toggle the Quick View panel (§8.8)                                                                         |
| `Ctrl+S`                                      | Toggle the filter (§14.4)                                                                                  |

### 14.4 Quick filter

- In both modes with a search box (0 and 3) the box shows a **filter button** (funnel, "Ctrl+S"); the box then reads
  `Search: [____] [⏷]` in place of the status line. When the filter is active, the panel shows only items matching the
  current string, by the rules of §14.2 (with the default _Beginning_, names must start with the text; `no` in
  `c:\windows` left only `[..]` and `notepad.exe`). The `[..]` entry stays.
- **`Ctrl+S`** (`cm_QuickFilter`) opens the box directly in filter mode, or toggles the filter inside the box.
  **`Ctrl+Shift+S`** (or `cm_QuickFilter 1`) reopens it with the **last used** filter.
- **The filter persists** after the box is closed (first `Esc`): a red funnel icon at the right end of the status line
  shows it. Clicking the status line reopens the filter box.
- **The filter is removed by:** a directory change; **Esc** while the box is closed (i.e. a second Esc); **F2 /
  Ctrl+R**; Show › All Files (**Ctrl+F10**).
- It is **not** removed by file operations, by switching away from TC and back, or by automatic refreshes, which keep it
  applied. The selection is kept as well.
- **QuickSearchAutoFilter** (default 0; the investigated installation had 1 in its `wincmd.ini`):

| Value | Meaning                                                                             |
| ----- | ----------------------------------------------------------------------------------- |
| 0     | The filter starts off                                                               |
| 1     | The filter starts on, i.e. typing filters automatically; the state is saved on exit |
| −1    | Always off at start, not saved                                                      |
| 2     | Always on at start, not saved                                                       |

- The filter button state is kept separately for the main window, the history list and the list of tabs.

### 14.5 Quick search in trees and lists

- **Separate tree pane:** `Enter` opens the found directory; `Esc` returns to the previous directory; `Insert` stays on
  the new directory and opens it only if the tree is configured to open directories automatically.
- **Directory history list** (§17.3) and **list of open tabs** (§4.4): typing runs quick search / quick filter on the
  entries; `QuickSearchHistoryAutoFilter=0` / `QuickSearchTabsAutoFilter=0` set whether filtering is automatic. A
  leading `*` searches the **whole path** instead of the last component; in the history list `Tab` then adds lower-case
  characters from the current path up to the next `\`. Filtering starts only when more than an asterisk has been typed,
  and entries present in both the history and the frequently-used list are shown once.
- The Directory Tree dialog has its own quick search (12 › Directory Tree dialog).

_Basis: observed on Windows 11 (Letter only, page captions) and under Wine (box, quick filter); help: dlg_quicksearch,
dlg_configquicksearch, inisettings1–2; KEYBOARD.TXT; change log._

## 15. Branch view

### 15.1 Branch view (`Ctrl+B`)

- Commands › _Branch View (With Subdirs)_, `cm_DirBranch`, or the toolbar button _Show all files in current dir and all
  subdirs_, which stays pressed while branch view is on.
- Lists every file of the current directory **and all its subdirectories** in one flat list; folders themselves are not
  listed. Rows show the bare file names (without their folder), sorted by the current sort order (by name in the test);
  the current-directory bar is unchanged.
- The status line shows the **relative path** of the item under the cursor, e.g. `dups\sub\copy1   txt` (§16.1).
- Operations work on the real files. Typical uses: finding a file whose folder is unknown, feeding the Multi-Rename
  Tool, copying with "keep relative paths".
- **Reading** is slow at the root of very large disks. It can be aborted with **Esc**; any directory read that takes
  longer than 5 s offers an abort dialog. `IgnoreLinks` bit 4 skips directory links. `PreloadThumbnails=2` also preloads
  thumbnails in branch view.
- **Leaving with `Ctrl+B`:** if the cursor is on a file from a subdirectory, TC goes to **that subdirectory**, with the
  cursor on the file (observed: `y:\…\A\dups\sub\`), not to the branch root. **F2 / Ctrl+R** returns to the normal
  listing of the branch root.
- **Command parameters** for `cm_*DirBranch*`: 0 / none toggle, 1 on, 2 / −1 off.

### 15.2 Selected branch (`Ctrl+Shift+B`)

- `cm_DirBranchSel` shows branch view only for the **selected** directories (and selected files), or for the item under
  the cursor if nothing is selected.
- Leaving it with `Ctrl+B` or `Ctrl+Shift+B` while on `..` restores the original selection and puts the cursor on the
  last selected item.
- Returning to such a tab re-selects the directories used for it.

### 15.3 Related syntax

- Selection masks can be limited to subdirectories in branch view: `\sub1\sub2\*.ext` (relative to the base),
  `sub1\sub2\*.ext` (anywhere), `sub\**\*.txt` (§13.4). `cm_SelectCurrentPath` selects all items in the same path.
- Parameter placeholders `%B…` give branch-view path parts (18 › Button and command parameters).

_Basis: observed under Wine (list, status line, leaving); help: options_branch_view, proc_select, inisettings1–2; change
log._

## 16. Status line

Shown with `[Layout] StatusBar=1` (`cm_VisStatusBar`), below each file list.

### 16.1 Formulas

```text
Full and other views:  {selSize} k / {totalSize} k in {selFiles} / {totalFiles} file(s), {selDirs} / {totalDirs} dir(s)
Brief view:            {name}  {ext}  {size} {date} {time} {attr}       (item under the cursor)
Branch view:           {relative\path\name}  {ext}                       (item under the cursor)
Feed to listbox:       {full\path\name.ext}  {size} {date} {time} {attr} (item under the cursor)
```

| Situation                                      | Example                                                          |
| ---------------------------------------------- | ---------------------------------------------------------------- |
| Fresh panel on `c:\users`                      | `0 k / 0 k in 0 / 0 file(s), 0 / 2 dir(s)`                       |
| 4 of 14 files selected with `Shift+↓`          | `5 k / 8 k in 4 / 14 file(s)`                                    |
| `Ctrl+A` in a folder with 1 file and 4 folders | `0 k / 0 k in 1 / 1 file(s), 4 / 4 dir(s)`                       |
| Hidden/system shown, root of `C:`              | `… 0 / 3 file(s), 0 / 14 dir(s)`                                 |
| Brief view                                     | `win   ini   34 10/11/2026 01:19 -a--`                           |
| Branch view                                    | `dups\sub\copy1   txt`                                           |
| _Feed to listbox_ (09)                         | `y:\…\copy1.txt   19 05/02/2026 09:00 -a--`                      |
| _Mark Newer, Hide Same Files_ view (09)        | `0 k / 1 k in 0 / 1 file(s)`: only the visible files are counted |

- The sizes use the _Header/footer_ size style (default kbytes, §6.4).
- The `, … dir(s)` part depends on _Show directory count in footer_ (`DirsInFooter=1`). The recorded footers lacked it
  in folders that apparently held no subfolders; whether it is omitted exactly when a list has no folders was not
  recorded.

### 16.2 Counting rules

- `totalSize` counts the files plus any **already-calculated** folder sizes; a calculated folder that is selected also
  counts into `selSize`. Items hidden by the ignore list are counted neither in numbers nor in sizes.
- Folder sizes are calculated by `Space` on an unselected folder, `Ctrl+L` (07 › Calculate occupied space),
  `Alt+Shift+Enter` (`cm_CountDirContent`: all subfolders of the current directory; hold `Esc` to abort; shown only in
  Full view; `Everythingforsize=1` uses the _Everything_ indexer), or the pre-count before Copy/Delete (_Calculate space
  occupied by subdirectories_, Operation page: _when selecting with the space bar_, _before copying/deleting_,
  _'Everything'_, and the mode list _Manual: Alt+Shift+Enter_ · _Automatic, local drives only_ · _Automatic, also on
  network_ · _Automatic, only with 'Everything'_; 13 › Operation page). The calculated size replaces `<DIR>` in the Size
  column (e.g. 11,613,426) and stays there after the operation.
- Both figures must come from the same data snapshot, so the selected size can never exceed the total (an inconsistent
  footer seen under Wine is in A › Artefacts not to copy).
- With file-system watching, _Update footer (total number of files)_ (`WatchDirs` bit 16) recalculates the counts on
  each change (§18.3).

### 16.3 Other states

- While a quick filter is active, a red funnel icon appears at the right end of the line; clicking the line reopens the
  filter box (§14.4).
- While the quick search box is open it takes the place of the line.
- Right-clicking the line does nothing (05 › Places without a context menu).

_Basis: observed on Windows 11 and under Wine (formats, examples, calculated sizes); help: add_markedfiles,
dlg_configtabs, keyboard, inisettings1–2._

## 17. Navigation, directory history and hotlist

### 17.1 Moving between directories

| Action                                                       | Result                                                                                                                                                                                               |
| ------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Enter` / double-click on a folder or archive                | Opens it (archives: 08 › Archives as folders). On a program or file: runs or opens it (10 › Associations)                                                                                            |
| `Backspace`, `Ctrl+PgUp`, `[..]`, the `..` button            | Parent directory (`cm_GoToParent`); the cursor is put on the folder that was left (`[A]` after leaving `A`)                                                                                          |
| `Ctrl+PgDn`                                                  | Opens the directory or archive under the cursor, also self-extracting `.exe` archives and unusual extensions (`cm_GoToDir`)                                                                          |
| `Ctrl+\`, the `\` button                                     | Root directory (`cm_GoToRoot`); the cursor lands on the directory that was part of the old path. Locked tabs: §4.6                                                                                   |
| `Ctrl+←` / `Ctrl+→`                                          | Opens the directory or archive under the cursor **in the target panel**; if the cursor is not on a directory, the current directory is shown there instead (06 › Navigation, `CtrlArrowOpenArchive`) |
| Breadcrumb click, `cd` on the command line, hotlist, history | §3, 02 › Command line (`cd` to a file name goes to its folder with the cursor on the file), §17.3, §17.4                                                                                             |
| `Ctrl+U` / Commands › _Target=Source_                        | Exchange the panels' directories / give the target panel the source path                                                                                                                             |

- **Unreadable directories:** entering a folder without access shows "Access denied on file / `<path>`!" with [OK] [As
  Administrator]; OK keeps the panel where it was (07 › Access denied and "As Administrator"). `IgnoreDirErrors=0`: 0 =
  show `<Read error!>` only at start-up for unreachable locked tabs, otherwise switch away; 1 = allow switching to
  inaccessible or missing directories, showing `<Read error!>`; −1 = never, always switch away.
- Reading a hanging network path runs in a separate thread so it can be aborted (`ThreadFindFirst=1`).

### 17.2 Back and forward

- Each panel remembers the **last 50 directories**. `Alt+←` goes back and `Alt+→` forward, browser style
  (`cm_GoToPreviousDir` / `cm_GoToNextDir`; also the toolbar buttons _Go back_ / _Go forward_ and Commands › _Go Back_).
  The `cm_GoToPreviousLocalDir` / `cm_GoToNextLocalDir` variants skip FTP.
- `HistoryCut=1`: changing directory while back in the history cuts off the forward part.
- `HistoryAppend=1`: choosing an entry from the history list appends that directory at the end; 0 = move the position
  pointer to it instead.

### 17.3 Directory history list

**Opening:** `Alt+↓` (`cm_DirectoryHistory`), the `▼` button, or a **1-second right click** on the current path.
`Alt+Shift+↓` (`cm_DirectoryHistoryNoThinning`) opens it **without thinning**: all entries, beyond the "maximum to show"
limits.

**Content:** one popup combining two lists:

1. **Frequently used folders**, ranked by visit count, each with its count; stored in `tcDirFrq.txt` (location
   `DirUsageLocation=1`: `%LOCALAPPDATA%\GHISLER\`; 2 = the `wincmd.ini` folder; 0 = disabled; or a path).
2. a separator, then the **history**: the last visited directories of this panel. The current directory is marked with a
   green arrow.

`ReverseHistory=0` (1 = last visited at the top), `ShowFrequentlyUsed=1`, `ShowLastVisitedInMiddle=0`,
`ShowFrequentlyUsedMaxInMiddle=0` and `HistoryScrollTo=0` (what is visible first when the list is taller than the
screen) arrange the two blocks; `OldStyleHistory=1` shows a plain Windows menu; `HistoryMaxWidth=120`, `HistoryIcons=1`
and `HistoryFont=0` set width, icons and font (13 › History page).

**Thinning** (`HistoryThinning=1`, `HistoryThinningDelta=5000` ms):

```text
onLeaveDirectory(dir, timeSpentMs, didFileOperation):
    addToRawHistory(dir)                        # always recorded (Alt+Shift+Down, saving)
    if not HistoryThinning:                     visible(dir) = true
    elif didFileOperation:                      visible(dir) = true
    elif HistoryThinningDelta > 0 and timeSpentMs >= HistoryThinningDelta:
                                                visible(dir) = true
    else:                                       visible(dir) = false   # hidden from Alt+Down only
```

With `HistoryThinningDelta=0` only folders where a file operation was done stay visible.

**Limits:** `HistoryLen=26` entries shown (max 100); `HistoryLenStored=200` saved per side (max 200, including entries
hidden by thinning); `FrequentlyUsedLen=30` shown (max 200); `FrequentlyUsedLenStored=200` saved.

**In the list:**

| Key / item         | Action                                                                                                                                                                                                                                                                                                                                                                  |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `↑` / `↓`, `Enter` | Choose an entry                                                                                                                                                                                                                                                                                                                                                         |
| Typing             | Quick search / quick filter (§14.5)                                                                                                                                                                                                                                                                                                                                     |
| `Shift+Enter`      | Open the directory in a new tab                                                                                                                                                                                                                                                                                                                                         |
| `Shift+Del`        | Remove the entry from the history                                                                                                                                                                                                                                                                                                                                       |
| Context menu       | Open the folder in a new tab, in the other panel, or both; remove an entry from the history or from the frequently used list; copy the path to the clipboard; show all entries when thinning is on, including folders only passed through; reverse the order (history at top or bottom, `ReverseHistory`); show or hide the frequently used list (`ShowFrequentlyUsed`) |

**Storage:** `[LeftHistory]` / `[RightHistory]`, written on exit when _Save history on exit_ (`SaveHistory=1`); the
frequently-used list when _Save frequently used folders on exit_ (`SaveFrequentlyUsed`, defaults to `SaveHistory`).
Value format: 19 › History sections.

### 17.4 Directory hotlist

**Opening:** `Ctrl+D` (`cm_DirectoryHotlist`), Commands › _Directory Hotlist_, the `*` button, or a **double click** on
the current-directory bar.

**The popup menu:** the user's entries (with submenus and separators), followed by two fixed items:

- **Add/remove current dir:** adds the current directory, or removes it if it is already listed;
- **Configure...:** opens the "Change directory menu" editor (12 › Directory hotlist editor).

`DirMenuHotkeys=1` makes the accelerators of these items `+`, `-` and `*`; 0 uses letters from the translated menu
texts. An `&` in an entry title makes the next letter its accelerator.

**Choosing an entry:**

- The entry's command runs: normally `cd <path>`. A command ending in `\:` (or `\\:`) goes to the **parent** and puts
  the cursor on that directory, e.g. `cd D:\Dir\Focusme\:`. Any internal command works too, e.g. `cm_OpenDesktop`.
- If the entry has a **target path**, the other panel changes to it at the same time.
- With **Shift** held, or `Shift+Enter`, the directory opens in a new tab.
- Entries whose title starts with the hide character (default `?`) are not shown while hiding is active.

Shift-dragging a folder onto the button bar creates a button that changes to that folder (14 › Drag and drop onto a
bar). The `[DirMenu]` storage format is in 19 › `[user]` (Start menu) and `[DirMenu]` (directory hotlist).

_Basis: observed under Wine (history popup layout, cursor after `[..]`) and on Windows 11 (access denied); help:
go_back, add_hothist, directoryhotlist, dlg_dirmenu, dlg_confighistory, keyboard, inisettings1–2; change log._

## 18. Refresh

### 18.1 Manual reread

- `F2` / `Ctrl+R` (`cm_RereadSource`, Show › _Reread Source_, the toolbar button _Reread source_) rescans the source
  directory.
- A reread also removes an active quick filter (§14.4), returns branch view to the branch root (§15.1), rescans a fully
  loaded tree (§8.6), and ends the _Mark Newer, Hide Same Files_ view: the first `Ctrl+R` restores the normal caption,
  the second the full list (09 › Compare directories and Mark newer).

### 18.2 On activation and restart

- By default the file lists are re-read when TC is re-activated after another program had the focus, and when TC is
  restarted. Observed on Windows 11: after a program was run from the command line, the panel was re-read when TC got
  the focus back.
- _No refresh for these drives_ (`NoReread=`) lists drives that are **not** re-read on activation; `F2` still re-reads
  them. _Do not remember these drives on exit_ (`NoReread2=`, defaults to `NoReread`) lists drives whose directory is
  not restored at the next start (slow or intermittent network drives).
- Character syntax of both fields (and of `WatchDirsExclude`): a letter = that drive; `\` = all UNC paths and Network
  Neighborhood; `/` = file-system plugins; `:` = virtual folders such as the Desktop. Example: `NoReread=ABC\` with
  `NoReread2=AB\` turns off re-reading for A:, B:, C: and the network, but still restores the C: directories after a
  restart.

### 18.3 Watching the file system

_Refresh when files are created, deleted and renamed_ is **off** by default (`WatchDirs=0`, on Windows 11 too). When on,
changes made by other programs appear after about **1 second**; **virtual folders are never watched**.

| `WatchDirs` bit | Option                                                        | Effect                                                                     |
| --------------- | ------------------------------------------------------------- | -------------------------------------------------------------------------- |
| 1               | Refresh when files are created, deleted and renamed           | Master switch; on its own only create, delete and rename are handled       |
| 2               | Also when size, date, or attributes change                    | Minor changes too, e.g. a file growing during a download                   |
| 4               | Put added files at the END of the file list (default: sorted) | New entries are appended instead of sorted into place                      |
| 8               | Don't react to updates while in the background                | Suspended while TC is not the foreground application                       |
| 16              | Update footer (total number of files)                         | Recalculate counts and sizes on each change (may be slow in large folders) |
| 32              | Update header (free disk space)                               | Re-read free and total space on each change (may be slow)                  |
| 256             | (ini only)                                                    | Beep on each update (debugging aid)                                        |

- _No refresh for these drives_ in this group (`WatchDirsExclude=`) excludes drives from watching (syntax as in §18.2).
- `cm_SwitchWatchDirs` turns watching off or on **temporarily** (0 toggle, 1 on, −1/2 off).
- `DeviceChange=2` decides how drive arrival and removal are handled: 1 = always, 2 = only while TC is in the
  foreground, 3 = also do not switch away from removed drives, 0 = ignore.

### 18.4 Consequences

- TC's own operations refresh the panels they change (07 › State changes at a glance). Files written in other ways
  appear only after a reread while watching is off: after _Save Selection To File_ the new `.txt` was not listed until
  `Ctrl+R` (§13.6).
- Automatic refreshes keep a quick filter applied (§14.4).

_Basis: observed on Windows 11 (default off, re-read on activation) and under Wine; help: dlg_configrefresh,
inisettings1–2, KEYBOARD.TXT._
