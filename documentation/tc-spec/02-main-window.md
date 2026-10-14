# 02: Main window

This chapter describes the main window as a whole: its regions and how each is shown or hidden, the menu bar, the two
button bars, the drive button bar and drive combo box, the command line and the function-key bar. It also covers the
visual design that applies across the window (fonts, colours, icons, dark mode) and the window geometry and rendering
metrics. The contents of the file panels (drive line, path bar, column header, file list, status line) are described in
chapter 03; this chapter names them only as regions.

**Related:** [01](01-overview-and-architecture.md) (window title, first start), [03](03-file-panels.md) (panel regions),
[04](04-main-menu.md) (menu items), [05](05-mouse-context-menus-drag-drop.md) (right-click menus, drops),
[06](06-keyboard.md) (keys), [13](13-configuration-dialog.md) (Layout, Display, Icons, Font, Color pages),
[14](14-customisation.md) (button-bar editor, .MNU files), [19](19-settings-files-and-command-line.md) (ini keys).

## 1. Window composition and visibility

### 1.1 Regions

The main window is one top-level frame. From top to bottom it holds the regions below. The two file panels sit side by
side, with the vertical button bar between them.

```text
+--------------------------------------------------------------------------------+
| Total Commander (x64) 11.58 - NOT REGISTERED                         [_][ ][X] |  title (01)
+--------------------------------------------------------------------------------+
| Files  Mark  Commands  Net  Show  Configuration  Start                   Help  |  1 menu bar
+--------------------------------------------------------------------------------+
| [Rr]|[Br][Fu][Th][Tr]|[Bv]|[In]|[<][>]|[Pk][Un]|[Ft][Nw]|[Se][Mr][Sy][Cp]|[Np] |  2 button bar
+--------------------------------------------------------------------------------+
| [c] [d] [\]          (drive button bar, off by default)                        |  3 drive button bar
+-------------------------------------+---+--------------------------------------+
| [c v] [_none_] ... k free     \ ..  |   | [c v] [_none_] ... k free     \ ..   |  4 drive line
| [tab 1] [tab 2]   (folder tabs)     |   |                                      |  5 folder tabs
| v c:\*.*                       *  v |   | v c:\*.*                        *  v |  6 path bar
| ^Name        Ext  Size  Date Attr   | 9 | ^Name        Ext  Size  Date  Attr   |  7 column header
| [..]                                |   | [..]                                 |
| [Program Files]  <DIR>  ...  r---   |   | [Program Files]  <DIR>  ...   r---   |  8 file list
| [Users]          <DIR>  ...  r---   |   | [Users]          <DIR>  ...   r---   |
| ...                                 |   | ...                                  |
+-------------------------------------+---+--------------------------------------+
| 0 k / 0 k in 0 / 0 file(s), ...     |   | 0 k / 0 k in 0 / 0 file(s), ...      |  status lines
+--------------------------------------------------------------------------------+
|                                         c:\> [______________________________v] |  10 command line
+--------------------------------------------------------------------------------+
| F3 View | F4 Edit | F5 Copy | F6 Move | F7 NewFolder | F8 Delete | Alt+F4 Exit |  11 F-key bar
+--------------------------------------------------------------------------------+
```

Button abbreviations: Rr reread; Br / Fu / Th Brief / Full / Thumbnails; Tr tree; Bv branch view; In invert selection;
`<` `>` back / forward; Pk / Un pack / unpack; Ft / Nw FTP connect / new FTP connection; Se search; Mr multi-rename; Sy
synchronize; Cp copy names; Np Notepad (§3.1). The column "9" between the panels is the vertical button bar.

| #   | Region                                                                             | Described in                          |
| --- | ---------------------------------------------------------------------------------- | ------------------------------------- |
| —   | Title bar: `Total Commander (x64) 11.58 - NOT REGISTERED`                          | 01 › Window title                     |
| 1   | Menu bar                                                                           | §2                                    |
| 2   | Button bar (horizontal)                                                            | §3                                    |
| 3   | Drive button bar (one bar, or one per panel)                                       | §4.1                                  |
| 4   | Drive line: drive combo box, volume label, free space, `\` and `..` buttons        | §4.2 (combo); 03 › Drive line         |
| 5   | Folder tabs (above the path bar of their panel)                                    | 03 › Folder tabs                      |
| 6   | Current-directory bar (path bar, breadcrumb), with the history and hotlist buttons | 03 › Current-directory bar (path bar) |
| 7   | Column ("tabstop") header                                                          | 03 › Column header and sorting        |
| 8   | File list ("file window")                                                          | 03 › File list rendering              |
| —   | Status line (one per panel)                                                        | §7; 03 › Status line                  |
| 9   | Vertical button bar ("Button bar 2")                                               | §3.3                                  |
| 10  | Command line                                                                       | §5                                    |
| 11  | Function-key bar                                                                   | §6                                    |
| —   | FTP toolbar (only while an FTP connection is open)                                 | §1.4                                  |

The help's user-interface map lists them in this order: menu bar, button bar, drive button bar, drive selection list,
free space, root/parent buttons, folder tabs, current directory, hotlist/history buttons, tabstop header, file window,
number of selected files, command line, function-key bar.

### 1.2 Showing and hiding regions

Every region except the menu bar and the file list can be switched off on Configuration › Options › Layout (13 › Layout
page) or with a toggle command. The settings live in `[Layout]` of `wincmd.ini` unless noted.

| Region                                                    | Layout-page caption                                          | Default | Key                                                                                      | Toggle command            |
| --------------------------------------------------------- | ------------------------------------------------------------ | ------- | ---------------------------------------------------------------------------------------- | ------------------------- |
| Button bar                                                | Show button bar                                              | on      | `ButtonBar=1`                                                                            | `cm_VisButtonBar`         |
| Vertical button bar                                       | Show button bar 2 (vertical)                                 | on      | `ButtonBarVertical=1`                                                                    | `cm_VisButtonBar2`        |
| Drive button bar                                          | Show drive buttons                                           | off     | `DriveBar1=0`                                                                            | `cm_VisDriveButtons`      |
| └ Two drive bars                                          | Show two drive button bars (fixed width, above file windows) | off     | `DriveBar2=0` (used only with `DriveBar1=1`)                                             | `cm_VisTwoDriveButtons`   |
| └ Flat drive buttons                                      | Flat icons                                                   | on      | `DriveBarFlat=1`                                                                         | `cm_VisFlatDriveButtons`  |
| Drive combo box                                           | Show drive combobox                                          | on      | `DriveCombo=1`                                                                           | `cm_VisDriveCombo`        |
| Folder tabs                                               | Show folder tabs                                             | on      | `DirectoryTabs=1`                                                                        | `cm_VisDirTabs`           |
| Current-directory bar                                     | Show current directory                                       | on      | `CurDir=1`                                                                               | `cm_VisCurDir`            |
| └ Breadcrumb                                              | Show clickable path parts ('breadcrumb bar')                 | on      | `BreadCrumbBar=1`                                                                        | `cm_VisBreadCrumbs`       |
| └└ Auto-open                                              | Auto-open when moving mouse over it                          | off     | (see 03 › Current-directory bar (path bar))                                              | —                         |
| └ History/hotlist buttons                                 | Show buttons for history list and hotlist                    | on      | `HistoryHotlistButtons=1`                                                                | `cm_VisHistHotButtons`    |
| Column header                                             | Show tabstop header                                          | on      | `TabHeader=1`; `TabHeaderThemed=1`; `TabHeaderBoldArrow` (defaults to `TabHeaderThemed`) | `cm_VisTabHeader`         |
| Status line                                               | Show status bar                                              | on      | `StatusBar=1`                                                                            | `cm_VisStatusBar`         |
| Command line                                              | Show command line                                            | on      | `CmdLine=1`                                                                              | `cm_VisCmdLine`           |
| └                                                         | Run command line only when focused                           | off     | `[Configuration] ExecCmdLineFocused=0`                                                   | —                         |
| Function-key bar                                          | Show function key buttons                                    | on      | `KeyButtons=1`                                                                           | `cm_VisKeyButtons`        |
| Flat look of everything except button bar and drive bar   | Flat user interface (button bar configured separately)       | on      | `InterfaceFlat=1`                                                                        | `cm_VisFlatInterface`     |
| Theme background under menu, all bars and the FTP toolbar | Windows XP theme background (menu+all bars)                  | on      | `XPthemeBg=1`                                                                            | `cm_VisXPthemeBackground` |
| Borders around list boxes in dark mode                    | —                                                            | on      | `DarkListBorders=1`                                                                      | —                         |

Changes made with **Apply** on the Layout page take effect at once (observed: switching on _Show drive buttons_ showed
the drive bar immediately).

Rules that cross regions:

- The folder-tab header is drawn only when the panel has at least 2 tabs, unless _Show tab header also when there is
  only one tab_ is set (03 › Folder tabs).
- A hidden command line reappears by itself as soon as the user types a character (§5.1).
- The current-directory bar marks the active panel through its active/inactive colours (§9.3).
- The panel that holds the source directory receives keyboard input (cursor keys, Enter).
- Hiding the button bar and showing it again reloads the **default** bar file, which discards a bar loaded temporarily
  (§3.4).

### 1.3 Panel divider and arrangement

- Each file panel takes half of the client width, minus the vertical button bar. The divider is stored in per-mille:
  `Divider=500` (resolution section, 19 › Screen-resolution sections).
- The divider can be dragged (the gap between the panels), or set with `cm_50Percent` (separator at 50 %) and
  `cm_100Percent` (separator at 100 %).
- Quick View (Ctrl+Q) and the comments view keep their own dividers, `DividerQuickView=500` and `DividerComments=500`,
  saved with _Configuration › Save Position_ while that mode is shown (03 › Quick View).
- `cm_VerticalPanels` (`PanelsVertical=1`) stacks the two file windows one above the other (03 › View types).
- Right-clicking the panel separator offers _Show vertical button bar_ when that bar is hidden (§3.3, 05 › Vertical
  button bar).

### 1.4 FTP toolbar

While an FTP connection is open, a full-width bar appears **above the panels**, below the button bars:

```text
[lock] FTP   Transfer mode [Binary (archives, doc etc.)  v]   [ Disconnect ]   +-------------------------+
                                                                              | Waiting for server...   |
                                                                              | 226 Transfer complete.  |
                                                                              +-------------------------+
```

- The lock icon appears only on a TLS connection.
- _Transfer mode_ offers Automatic · Binary (archives, doc etc.) · Text (plain text, html, etc.).
- The two-line box shows the last server lines; lines from background transfers start with `BG:`.
- The bar disappears when the connection is closed. Its behaviour is described in 11 › FTP toolbar.

### 1.5 Other top-level windows

These open as separate top-level windows (whether each is modal was not tested):

- Lister (F3), 10;
- Multi-Rename Tool (Ctrl+M), Synchronize directories, Compare contents, Find Files (Alt+F7), 09;
- Background Transfer Manager, 07;
- Help: an HTML-Help style viewer with the toolbar _Hide / Back / Forward / Home / Options / Print_ and the tabs
  _Contents / Index / Search_, 12.

_Basis: observed on Windows 11 and under Wine; help: cmdinterface, dlg_config, ftp_menu, inisettings2, inisettings3
[Layout]._

## 2. Menu bar

The menu bar holds eight top-level menus. **Help is right-aligned.**

| Menu          | Caption in `WCMD_ENG.MNU` | Contents                                                                                |
| ------------- | ------------------------- | --------------------------------------------------------------------------------------- |
| Files         | `&Files`                  | File-level operations and tools                                                         |
| Mark          | `&Mark`                   | Selection, compare directories                                                          |
| Commands      | `&Commands`               | Actions without a function key: navigation, tree, search, sync, hotlist, command prompt |
| Net           | `&Net`                    | Local network and FTP                                                                   |
| Show          | `Sho&w`                   | View, filter, sort and panel layout of the **source** panel                             |
| Configuration | `C&onfiguration`          | Options, button bars, Dark<->Normal, saving                                             |
| Start         | `&Start`                  | User-defined program menu; programs can get the file under the cursor as a parameter    |
| Help          | `&Help`                   | Help, keyboard, registration, website, update check, About                              |

- In the `.MNU` file the Start menu is the placeholder line `STARTMENU`, and the line `HELP_BREAK` before the Help popup
  right-aligns it.
- The old-style menu had separate _Left_ and _Right_ menus where _Show_ now acts on the source panel.
- **Icons**: menu items carry the icons of their internal commands in a left gutter, 16×16 by default (_Show icons for
  commands in the main menu_). Checked items are drawn as **pressed icon buttons** instead of check marks (_Show checked
  items as pressed buttons instead of checkmarks_). See §10.3 for the bits.
- Shortcuts are right-aligned in the items.
- The whole menu can be replaced by a `.MNU` file: _Start › Change Main Menu_, or Display › Language › _Main menu file_
  (14 › Main-menu files).
- Keyboard: Alt+letter opens a menu (accelerators underlined); F9 activates the menu above the source window;
  `cm_FocusMainMenu` focuses the menu bar (06).

Every item is listed in [04](04-main-menu.md).

_Basis: observed on Windows 11 and under Wine; help: add_menu; program data: WCMD_ENG.MNU._

## 3. Button bars

### 3.1 Horizontal button bar: appearance

- A row of flat 16×16 icon buttons, button size 24 at 96 DPI (`SmallIcons=1`, `SmallIconSize=16`), with thin vertical
  **separators** (a 1 px etched line with 3–4 px padding). The size is DPI-scaled (depends on DPI; see Appendix A).
- Defined by `default.bar`; the icons come from `wcmicons.dll` unless another default icon library is chosen (§3.4).
- **Toggle buttons** are drawn **pressed** while their state is active: the view buttons (_All file details_ is pressed
  in Full view, _Thumbnail view_ in Thumbnails view), the tree button while a separate tree is shown, and the branch
  button in branch view.
- Buttons that open a sub-bar carry a small arrow overlay (`PopupOverlay=1`).
- When the buttons do not fit in one row, the bar wraps into further rows; `BarLimitLines=0` (0 = unlimited) caps the
  number of rows.
- The rest of the bar right of the last button is empty space.

Default buttons, left to right (`default.bar`, 26 entries including separators):

| #   | Tooltip (exact)                               | Command                  | Icon (`wcmicons.dll` index) | Kind                                                |
| --- | --------------------------------------------- | ------------------------ | --------------------------- | --------------------------------------------------- |
| 1   | Reread source                                 | `cm_RereadSource`        | 0 (green circular arrows)   | action                                              |
| —   | separator                                     |                          |                             |                                                     |
| 2   | Source: Only file names                       | `cm_SrcShort`            | 3                           | radio toggle                                        |
| 3   | Source: All file details                      | `cm_SrcLong`             | 4                           | radio toggle (pressed by default)                   |
| 4   | Source: Thumbnail view                        | `cm_SrcThumbs`           | 26                          | radio toggle                                        |
| 5   | Switch through tree panel options             | `cm_SwitchSeparateTree`  | 51                          | cycles one tree → two trees → off; pressed while on |
| —   | separator                                     |                          |                             |                                                     |
| 6   | Show all files in current dir and all subdirs | `cm_DirBranch`           | 50                          | toggle (pressed in branch view)                     |
| —   | separator                                     |                          |                             |                                                     |
| 7   | Invert selection                              | `cm_ExchangeSelection`   | 11                          | action                                              |
| —   | separator                                     |                          |                             |                                                     |
| 8   | Go back                                       | `cm_GoToPreviousDir`     | 18 (grey arrow)             | action                                              |
| 9   | Go forward                                    | `cm_GoToNextDir`         | 19 (grey arrow)             | action                                              |
| —   | separator                                     |                          |                             |                                                     |
| 10  | Pack files                                    | `cm_PackFiles`           | 30                          | dialog                                              |
| 11  | Unpack all                                    | `cm_UnpackFiles`         | 31                          | dialog                                              |
| —   | separator                                     |                          |                             |                                                     |
| 12  | Connect to FTP                                | `cm_FtpConnect`          | 16                          | dialog                                              |
| 13  | New FTP connection                            | `cm_FtpNew`              | 17                          | dialog                                              |
| —   | separator                                     |                          |                             |                                                     |
| 14  | Search for                                    | `cm_SearchFor`           | 47 (binoculars)             | dialog                                              |
| 15  | Rename multiple files                         | `cm_MultiRenameFiles`    | 46                          | tool                                                |
| 16  | Synchronize directories                       | `cm_FileSync`            | 48                          | tool                                                |
| 17  | Copy names with full path                     | `cm_CopyFullNamesToClip` | 45 (clipboard)              | action                                              |
| —   | separator                                     |                          |                             |                                                     |
| 18  | Notepad                                       | `notepad.exe`            | icon of `notepad.exe`       | external program                                    |

A button without its own tooltip text shows the command's description (the text of `totalcmd.inc` in the current
language); the Notepad button has the explicit tooltip `menu26=Notepad`.

### 3.2 Using the bars

- A button runs an internal command, an external program, or opens another button bar (a sub-bar, shown as a bar or as a
  drop-down menu). Shift+click on a sub-bar button does the opposite of its _Show as menu_ setting.
- **Tooltips**: hovering shows the button's description after `ToolTipDelay=500` ms. They need _Show help texts for
  buttons (tooltips)_ (Display page, on by default), which is bit 1 of `Tips=3`.
- **Keyboard**: `Alt+Shift+F11` (`cm_FocusButtonBar`) focuses the horizontal bar, `Alt+Shift+F12`
  (`cm_FocusButtonBarVertical`) the vertical bar. Inside a bar the cursor keys and Tab/Shift+Tab move, Enter runs the
  button, Esc leaves. Space, Shift+F10 or the context-menu key opens the button's context menu (06 › Button bars).
- **Right-click** on a button or on empty bar space opens a context menu (05 › Horizontal button bar).
- **Drag & drop**: dropping files on a button runs it with them; dropping on empty space, or with Shift held, inserts a
  new button (05 › Drop targets).
- Larger changes go through _Configuration › Button Bar..._ (14 › The _Change button bar_ dialog).

### 3.3 Vertical button bar ("Button bar 2")

- A narrow column (about 30 px at 96 DPI; depends on DPI; see Appendix A) between the two panels, buttons stacked from
  the top. Defined in `vertical.bar`, icons from `wcmicons.dll`; configured like the horizontal bar (_Configuration ›
  Button Bar 2 (Vertical)..._).
- Default buttons, top to bottom:

| Tooltip           | Command        | Icon index |
| ----------------- | -------------- | ---------- |
| View with Lister  | `cm_List`      | 27         |
| Edit (Notepad)    | `cm_Edit`      | 28         |
| Copy files        | `cm_Copy`      | 62         |
| Rename/Move files | `cm_RenMov`    | 63         |
| _(gap)_           | separator      | —          |
| Pack files        | `cm_PackFiles` | 30         |
| Make directory    | `cm_MkDir`     | 29         |

The shipped `vertical.bar` has 9 entries: two `cmdK=-2` entries (forced line breaks) come first, then the seven above.

- When the bar is taller than the space available, an **overflow button** (a triangle) appears and the remaining buttons
  open from it as a popup menu (change log).
- **Hiding**: right-click between or below the icons › _Hide button bar_ (a confirmation box follows; change log), or
  the Layout page. **Showing again**: right-click the panel separator › _Show vertical button bar_, or the Layout page.

### 3.4 Which bar file is loaded

```text
bar = [Buttonbar] Buttonbar=            ; user-chosen default bar (vertical bar: [ButtonbarVertical])
if bar is empty:
    bar = <program dir>\default.bar     ; vertical.bar for the vertical bar
    if bar is not writable in the program dir
       and the bar file does not contain  [options] redirect=0 :
        copy it to the folder of wincmd.ini and use that copy from then on
```

- On a fresh Windows installation the first start copied `default.bar` and `vertical.bar` to `%APPDATA%\GHISLER` and
  wrote the icon caches `default.br2` and `vertical.br2` there (19 › File inventory).
- **Making another bar the default**: pick a `.bar` file with `>>` in _Change button bar_; on OK, TC asks whether it
  should become the default.
- The default bar is loaded at every start, and again whenever the bar is hidden and shown again via the Layout page.
- **Set default icon library** (Icons page and the bars' context menus; also the chooser shown at the first start, 01 ›
  First-start dialogs): every button whose icon file is `wcmicons.dll` **without a path** draws its icon from the chosen
  library instead (e.g. `wcmicon2.dll` with its icon sets). Stored as `[Buttonbar] DefaultLib=wcmicons.dll`, used by
  both bars and the main menu. `[ButtonbarCache] IconDll_<bar>=` remembers the last library used per bar file.

### 3.5 Button-bar ini keys

The horizontal bar uses `[Buttonbar]`, the vertical bar `[ButtonbarVertical]` with the same key names.

| Key                                                       | Meaning                                                                             |
| --------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `Buttonbar=`                                              | Bar file                                                                            |
| `Buttonheight=` / `Buttonheight<dpi>=` / `DefaultDpi=`    | Button size (DPI-scaled)                                                            |
| `FlatIcons=1`                                             | 1 = flat buttons, 0 = 3-D                                                           |
| `SmallIcons=1`, `SmallIconSize=16` (`SmallIconSize<dpi>`) | Icon size                                                                           |
| `XPstyle=1`                                               | Draw buttons with the Windows theme                                                 |
| `BarLimitLines=0`                                         | Maximum number of rows (0 = unlimited)                                              |
| `PopupOverlay=1`                                          | Arrow overlay on buttons that open a sub-bar                                        |
| `PopupIconSize=`                                          | Icon size when a `.bar` is shown as a drop-down menu (default: the bar's icon size) |

The full `.bar` format and the editor are in 14 › The _Change button bar_ dialog; the keys are also listed in 19 ›
`[Buttonbar]`.

_Basis: observed on Windows 11 and under Wine; help: add_btnbar, dlg_configicons, dlg_display, inisettings2,
inisettings3; program data: DEFAULT.BAR, VERTICAL.BAR, totalcmd.inc; change log for the overflow button and the hide
confirmation._

## 4. Drive button bar and drive combo box

### 4.1 Drive button bar

- **Off** by default (`DriveBar1=0`). Either one bar under the button bar for the whole window, or two bars, one above
  each file window (`DriveBar2=1`). The two bars have the same fixed width and do not follow the panel widths.
- Flat buttons by default (`DriveBarFlat=1`). Switched on with Apply on Windows 11, the bar appeared at once as
  `[c] [d] [\]`: flat drive icons with letter labels.
- Four kinds of buttons:

| Kind                                                  | Shown as                                     |
| ----------------------------------------------------- | -------------------------------------------- |
| Normal drive                                          | Drive letter plus an icon for the drive type |
| Network Neighborhood                                  | A backslash `\` beside a network icon        |
| FTP connection                                        | A number `0`…`9` beside a network icon       |
| USB device without a drive letter (e.g. a smartphone) | A USB button                                 |

- **Hiding parts**: `DriveBarHide=` takes a string of characters. `A`–`Z` drives; `0`–`9` FTP connections; `\` Network
  Neighborhood; `.` the parent and root buttons; `-` the volume label and free/total space; `;` USB devices without a
  letter. Terminal-server host drives follow a `$`, e.g. `DriveBarHide=A$CDE` hides local A: and host C:, D:, E:. Unlike
  `Allowed=`, hidden drives remain reachable through the drive list, `cd`, etc.
- **Extra drive space H / V** (Icons page; visible only while the drive bar is enabled): the total pixels added
  left+right / above+below the drive icon, so `2` means 1 px on each side. Stored per resolution as `ExtraDriveWidth` /
  `ExtraDriveHeight` (with `_dpi` and `_<dpi>` variants).
- Clicking a button changes the source panel's drive; Shift+click opens it in a new folder tab (03 › Drive line).
  Right-click: 05 › Drive combo box and drive buttons. Files can be dropped on a button (05 › Drop targets).

### 4.2 Drive combo box

- Sits at the left of each panel's drive line: a small drive icon and the drive letter, shown in lower case (`c`), with
  a drop-down arrow.
- **Opening**: click the arrow, `Alt+F1` (left panel), `Alt+F2` (right panel), or `cm_SrcOpenDrives`.
- **Entries**: each row has a letter or character in the first column and the description in the second; the current
  drive is highlighted. Observed on Windows 11:

```text
c                                         (local-disk icon)
d   DVD Drive
+   Computer (drive overview)
*   My Documents (directory)
\   Network Neighborhood
```

- A mapped network drive adds a row such as `z  \\localhost\c$\tc-sandbox` with a network-drive icon; `(X)` appears
  before the network path while the drive is not connected yet.
- While an FTP connection is open, the combo shows a globe icon and `0` (the connection number).
- The description column shows volume labels, or the server/share path of network drives, when _Show volume
  labels/network paths for drives_ (Display page, `Tips` bit 2) is on. Descriptions appear after `DriveTipDelay=0` ms.
  Floppy names are never read, for speed. `CDlabel=1` shows the labels of CDs and other removable media.
- **Extra entries** (`ShowExtraDrives=7`, bit sum): 1 = _Computer_ (needed for devices without a letter such as Android
  phones); 2 = _My Documents_; 4 = up to **3** external devices without a drive letter.
- **Terminal server / XP mode**: host drives appear with a trailing backslash, e.g. `c\`. If a letter exists twice,
  `Ctrl+letter` picks the host drive.
- **Custom names**: `[DriveHints]`, one line per drive (`E=ZIP drive`, `H=CD-ROM`), used by the combo and the drive
  buttons.
- Choosing an entry (click, or typing its letter in the open list) changes the drive of that panel; Shift + selection
  opens the drive in a new tab (03 › Drive line). Right-click works on the closed combo and inside the open list (05 ›
  Drive combo box and drive buttons).

### 4.3 Drive icons and letter case

| Key                                           | Effect                                                                                                                |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| _Show drive icons from Explorer_ (Icons page) | Explorer's drive icons in the drive bar, the drive combo and on folder tabs                                           |
| `OldDriveIcons=0`                             | 0 = Explorer icons, 1 = TC 6.5x icons, 2 = TC 7/8 icons                                                               |
| `DriveLib=`                                   | Take drive icons from a DLL; overrides `OldDriveIcons`. Ticking the Explorer option moves the value to `DriveLib.bak` |
| `IconsInDriveList=1`                          | Drive icons in the list and in the "drive not found" box                                                              |
| `DrivesShowUpcase=-1`                         | 1 = upper case, 0 = lower case, -1 = leave as is; applies to the drive bar, drive list and path                       |
| `CheckUsbHdd=1`                               | USB hard disks get the removable-disk icon                                                                            |

_Basis: observed on Windows 11 (drive list, drive bar, FTP and network entries) and under Wine; help: add_drive,
add_drivebuttons, dlg_configicons, dlg_display, foldertabs, inisettings1–3._

## 5. Command line

### 5.1 Layout and input routing

- A right-aligned **prompt label** with the source path and `>` (e.g. `c:\>`, `c:\users>`), then an editable **combo
  box** whose drop-down holds the previous commands.
- The prompt follows the active panel. Inside an archive it keeps showing the last real directory (the folder that holds
  the archive); with a path too long for the space it shows the **tail** of the path; on an FTP connection it reads like
  `0:/pub/>`; in a file-system plugin like `\\\Registry\HKEY_CURRENT_USER\AppEvents>`; on a UNC path
  `\\localhost\c$\tc-sandbox\B>`.
- While TC is active, almost all character input goes to the command line: a printable key typed in a file panel moves
  the caret there and is inserted, unless quick search is set to plain letters (06 › Quick search). With quick search on
  _Letter only_, letters jump in the panel and no longer reach the command line (observed).
- If the command line is hidden, typing a character switches it on.
- **Run command line only when focused** (`ExecCmdLineFocused=1`): Enter executes the line only while it has the focus.
  Otherwise Enter in a panel also runs the line whenever it is not empty.
- After a program started from the command line ends and TC gets the focus back, the panel is re-read (_Auto-Refresh
  when activating the program_, observed; 03 › Refresh).

### 5.2 Executing a line (Enter)

```text
if line is empty:  act as Enter on the item under the cursor (open / run)
elif source panel is an FTP connection:
     send the line to the server (HELP lists the server's commands);
     lowercase "cd x" is translated into the FTP change-dir command;
     uppercase "CD x" is a normal TC cd
elif source panel is a file-system plugin:
     give the line to the plugin first; if it does not handle it, TC does
     (typically lowercase cd -> plugin, uppercase CD -> TC; depends on the plugin)
else:
     expand %environment variables%
     "cm_..." / "em_..."                         -> run the internal / user command
     a command with parameters, in CAPITALS (OPENTABS, APPENDTABS, ...) -> run it
     an alias (Misc page, e.g. np -> notepad.exe) -> run its command
     first word cd / md / rd                     -> handled internally
     internal DOS command (dir, copy, ...)       -> run via the command interpreter
     otherwise                                   -> start the program of that name
  prefixes: "*"  run as administrator;  "**" run as a different user;
            "*cmd" uses cmd.exe from System32
add the line to the history
```

- The order of the checks inside `else` is not given by the help.
- With the Registry plugin active, `cd c:\...` typed in the command line was not executed; the drive had to be changed
  with Alt+F1 first (observed).

**`cd` handled internally** changes the source panel's directory. If the argument names a **file**, TC goes to its
folder and puts the cursor on that file. UNC paths open directly (observed: `cd \\localhost\c$\tc-sandbox\B`). Accepted
forms:

```text
c:\Windows
\\server\share\directory
file:///c|/Windows          file:///c:/Windows
file://localhost/c|/Windows file://localhost/c:/Windows
file://server/share/directory
file://c:/Program%20Files   (percent-escapes decoded)
```

### 5.3 Keys in the command line

| Key                            | Action                                                                                                                                                                                                                                                   |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Enter`                        | Execute (§5.2)                                                                                                                                                                                                                                           |
| `Shift+Enter`                  | Run via the Windows shell in a console window that stays open afterwards; needs `noclose.exe` in the TC directory                                                                                                                                        |
| `Ctrl+Enter`                   | Append the name of the file under the cursor (source panel)                                                                                                                                                                                              |
| `Ctrl+Shift+Enter`             | Append the file under the cursor **with its path**                                                                                                                                                                                                       |
| `Ctrl+P`                       | Append the current path (`cm_AddPathToCmdline`)                                                                                                                                                                                                          |
| `Ctrl+↓` or `Alt+F8`           | Open the history list. `↑`/`↓` (with or without Ctrl) choose an entry; `←`/`→` close the list and leave the entry for editing; `Shift+Del` removes the entry from the history                                                                            |
| `Tab`                          | Back to the source panel                                                                                                                                                                                                                                 |
| `←` / `→`                      | Move the caret in the line, even if the focus was in the panel. **In Brief view** they move the panel cursor instead, and `Shift+←/→` moves the caret                                                                                                    |
| `↑` / `↓`                      | Move the panel's cursor bar, even from the command line (command-line help). The ini key `CmdUpDown=0` is described as "move cursor up/down in file list even if the active window is the command line"; its interaction with this default is unverified |
| `Esc`                          | Clear the line and return to the file window                                                                                                                                                                                                             |
| `Ctrl+A`                       | Select the whole line                                                                                                                                                                                                                                    |
| `Ctrl+Y`                       | Clear the line; the caret stays in it                                                                                                                                                                                                                    |
| `Ctrl+C` / `Ctrl+X` / `Ctrl+V` | Copy / cut / paste text                                                                                                                                                                                                                                  |
| `Ctrl+E`                       | Bring back the previous command (`cm_PrevCommand`); `cm_NextCommand` has no default key                                                                                                                                                                  |
| `Ctrl+K`                       | Delete to the end of the line                                                                                                                                                                                                                            |
| `Ctrl+W`                       | Delete the word left of the caret                                                                                                                                                                                                                        |
| `Ctrl+T`                       | Delete the word right of the caret                                                                                                                                                                                                                       |

- `Ctrl+W` and `Ctrl+T` close and open folder tabs when the focus is in a panel; in the command line they delete words.
- `CtrlArrow=0` picks the word-jump method for `Ctrl+←/→` in edit boxes: 1 = TC's own, 0 = Windows.
- After typing in the command line the panel loses its focus marker (Windows allows only one focused control); `↑`/`↓`
  return to the list.
- Commands: `cm_FocusCmdLine`, `cm_ClearCmdLine`, `cm_PrevCommand`, `cm_NextCommand`, `cm_AddFileNameToCmdline`,
  `cm_AddPathAndFileNameToCmdline`, `cm_AddPathToCmdline`, `cm_ShowCmdLineHistory`.
- Dropping a file on the command line adds its name (05 › Drop targets).

### 5.4 Limits and persistence

- **Maximum line length**: 2047 characters on Windows 2000, 8191 on XP and later (operating-system limits).
- **History**: `[Command line history]`, `0=` is the newest entry; up to `OldCmdLineCount=20` entries
  (`MaxItemsInComboBox`). Saved on exit when _Save on exit › Old command lines_ is ticked (`SaveCommands=1`).

_Basis: observed on Windows 11 (prompt forms, UNC cd, plugin cd, refresh after a program, Letter-only quick search) and
under Wine; help: add_cmdline, cmdline, keyboard, dlg_config, frequentlyaskedquestions, inisettings1–3._

## 6. Function-key bar

- Seven equal-width flat buttons separated by thin lines: `F3 View`, `F4 Edit`, `F5 Copy`, `F6 Move`, `F7 NewFolder`,
  `F8 Delete`, `Alt+F4 Exit`. F1 (Help) and F2 (Reread) have **no** buttons, to save space.
- A button shows a raised frame while the mouse is over it.
- A click runs the same function as the key: F3 view, F4 edit, F5 copy, F6 rename/move, F7 new folder, F8 delete, Alt+F4
  exit.
- **Modifiers**: while Shift is held the captions change to the functions of the shifted keys, e.g. Shift+F4 create a
  new text file, Shift+F5 copy in the same directory, Shift+F6 rename; Ctrl and Alt likewise (unverified: the exact
  captions were not recorded). A clone shows the function that 06 lists for the held modifier.
- **Drop targets**: `F3 View`, `F4 Edit` and `F8 Delete` accept dropped files and run their function on them (05 › Drop
  targets).
- **Right-click** on `F8 Delete` opens the Recycle Bin's menu; the other buttons have no context menu (05 › Places
  without a context menu).
- **Alt+F4 Exit button** and `MinimizeOnClose`: the sum `1` = the [X] button, `2` = the Alt+F4 key, `4` = this button
  minimises instead of closing. Shift+click, or _Files › Quit_, forces a real close.

_Basis: observed under Wine (layout, hover); help: add_buttons, menu_fileoperations, keyboard, inisettings1._

## 7. Panel regions and footer

The regions inside each panel are owned by chapter 03; at window level they are:

| Region        | Short description                                                                                                                                                                                                               | Details                               |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| Drive line    | Drive combo (§4.2), the volume label in brackets (`[_none_]` without a label), free and total space (`… k of … k free`, live, in the _Header/footer_ size unit), and the tiny `\` (root) and `..` (parent) buttons at the right | 03 › Drive line                       |
| Folder tabs   | Tab strip directly above the path bar of its panel                                                                                                                                                                              | 03 › Folder tabs                      |
| Path bar      | One text line: a small `▾` special-folder button, the path plus file mask (`c:\*.*`), then the `*` (hotlist) and `▼` (history) buttons; coloured active/inactive (§9.3)                                                         | 03 › Current-directory bar (path bar) |
| Column header | `Name \| Ext \| Size \| Date \| Attr` in Full view, the sort column tinted and marked with an arrow                                                                                                                             | 03 › Column header and sorting        |
| File list     | Rows with icon, name, ext, size, date, attributes; cursor bar; selected items in red                                                                                                                                            | 03 › File list rendering              |
| Status line   | `<sel size> / <total size> in <sel files> / <total files> file(s), <sel dirs> / <total dirs> dir(s)`; the item under the cursor in Brief and branch view; a red funnel icon at the right end while a quick filter is active     | 03 › Status line                      |

The status line belongs to each panel; there is no window-wide status bar. The only window-level footers are the command
line (§5) and the function-key bar (§6), plus the FTP toolbar's log box (§1.4) while connected.

_Basis: observed on Windows 11 and under Wine; help: cmdinterface._

## 8. Fonts

- **Three fonts** can be set (Display › Font, 13 › Font page): the **file list** font; the **main window** font
  (everything except the file lists); the **dialog box** font. The ini also has a tooltip font (`FontNameTip`… ; the
  dialog font is used when absent) and a compare-tool font (`CompName`…).
- **Defaults on a fresh Windows 11 installation**: file list **Segoe UI, 9** (regular: neither Semibold nor bold); main
  window **Segoe UI, 9**; dialog box **Microsoft Sans Serif, 8** (depends on DPI/font; see Appendix A).
- **Default rule**: `UseNewDefFont=-1` acts as 1 on a fresh installation and as 0 when `[Configuration]` already exists.
  With 1 the help names **Segoe UI Semibold, 9** (Vista and later) for the file list; the fresh Windows 11 installation
  showed Segoe UI 9 regular. With 0 the file list uses **Microsoft Sans Serif 8** (MS Sans Serif on 9x/ME), weight 700.
- **Storage**: per screen resolution, `Fontname`, `Fontsize`, `FontWeight` (400 normal, 600 semibold, 700 bold),
  `FontCharset`; the same with the suffix `Window` and `Dialog` (19 › Screen-resolution sections).
- **Style**: normal or **bold** only; **italic is not supported**. Some fonts, such as Script, render wrongly.
- **Effect on the window**: changing a font resizes the main window automatically, never beyond the screen size; the
  tabstops may then need adjusting.
- **Dialog box scaling** (_Set dots per inch (DPI) to_, `OverrideDPI`, `OverrideDPI<dpi>`): scales the dialog boxes and
  their font to the given DPI. The box is disabled by default and shows the Windows value, `[192]` at 200 % scaling. It
  does **not** scale the main window, the file-list font or the main-window font.
- **Automatically adjust dialog boxes to larger fonts** (`AutoSizeDialogs=1`): dialogs grow when the dialog font is
  larger than the default; without it they keep their size, so an 8–10 pt font should be used. The dialog font option
  exists for languages whose default font lacks the code page, e.g. Japanese.
- **Change font** opens the standard Windows font chooser. Its _Character Set_ is ignored on NT systems; characters
  missing from the chosen font are substituted by Windows. Each font group has a sample box
  `ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz äöüéèêàñç`.

_Basis: observed on Windows 11; help: dlg_configfont, inisettings2, inisettings3._

## 9. Colours

Colour values in the ini are `red + 256·green + 65536·blue` (hex `$BBGGRR`); `-1` means "system default". Dark-mode
colours: §11. Colours by file type: 03 › Colours by file type.

### 9.1 Main colours (Color page)

| Setting                      | Applies to                                                                                                                                 | `[Colors]` key (default)                                                                                         |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------- |
| Font color                   | Text of the file lists                                                                                                                     | `ForeColor=-1`                                                                                                   |
| Background                   | **Only the file panels**; the surrounding window uses the system button colour                                                             | `BackColor=-1`                                                                                                   |
| Background 2                 | Every other row, for alternating rows; pick a colour close to Background. The Color page says "even lines", the View Mode page "odd lines" | `BackColor2=-1`                                                                                                  |
| Mark color                   | Text of selected items, or the bar with inverted selection                                                                                 | `MarkColor=255` (red)                                                                                            |
| Cursor color                 | The frame around the current file, or the bar with inverted cursor; default a dashed inverted frame                                        | `CursorColor=-1`                                                                                                 |
| Cursor font                  | Text inside the cursor bar; available **only with _Use inverted cursor_** (so disabled with the defaults)                                  | `CursorText=-1`                                                                                                  |
| Use Windows theme for cursor | Draw the cursor with the Windows theme instead of the user colour (on by default)                                                          | `ThemedCursor=-100`: 1 on, 0 off, -100 automatic (only when `InverseCursor=0` and WindowBlinds is not installed) |
| Use inverted cursor          | Solid bar in Cursor color; otherwise a rectangle                                                                                           | `InverseCursor=0`                                                                                                |
| Use inverted selection       | Selected items as solid bars in Mark color; cannot be combined with the inverted cursor                                                    | `InverseSelection=0`                                                                                             |

- Each colour row is `[colour combo] [>>]`; the combo offers `default` and 16 swatches (white, silver, grey, black, red,
  maroon, lime, green, blue, navy, yellow, olive, aqua, teal, fuchsia, purple); `>>` opens the Windows colour picker. An
  _Example_ box previews the rows "Selected", "Text", "Cursor", "Selected+Cursor".
- The colours of buttons and lines cannot be changed here; they follow the system settings.

### 9.2 Cursor and selection rendering

```text
drawSelected(item):  InverseSelection ? fill row with MarkColor : text colour = MarkColor
drawCursor(item):
    if themed cursor (ThemedCursor=1, or -100 and InverseCursor=0 and no WindowBlinds): theme highlight
    elif InverseCursor=1: fill bar with CursorColor, text in CursorText
    else: rectangle in CursorColor (default dashed inverted), width CursorPenWidth (0 = thin, >0 px, DPI-scaled)
target panel: no cursor unless InactiveFocus = 1 or an RGB value
              (+$1000000 dashes, +$2000000 dash-dot, +$3000000 solid frame)
SelectionFocus: special border on the current file while files are selected
              (+$4000000 = only when the current file is not selected)
dark mode: InactiveFocusDark / SelectionFocusDark (default to the normal values)
```

With the defaults on Windows 11 the cursor is the themed one: a **light-blue filled bar with a darker blue 1 px border**
in the active panel; selected items have **red** text; the inactive panel shows no cursor bar.

### 9.3 "Others" colours

| Group                     | Items                                                                                                                                                                                                                                                 | Keys                                                                                                                                                                                                                                                          |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Lister                    | Text color, Background color, Selected text, Selected background, Link color (**HTML-text mode only**), Media player controls: Text / Background                                                                                                      | `[Lister]`, `[ListerDark]`                                                                                                                                                                                                                                    |
| Compare by contents       | Differences - text mode (and selected), Differences - binary mode (and selected), Text with no differences, Text background (no differences), Text background (lines with differences), Selected lines: Text / Background, Search results (underline) | `CompareText`, `CompareTextSel`, `CompareBinary`, `CompareBinarySel`, `CompareNormalText`, `CompareNormalBack`, `CompareDifferenceBack=-2` (-1 = same as normal lines, -2 = slightly darker/lighter), `CompareSelText`, `CompareSelBack`, `CompareSearchLine` |
| Title bar for file panels | Active side: Text / Background; Inactive Side: Text / Background                                                                                                                                                                                      | `ActiveTitleText`, `ActiveTitle`, `InactiveTitleText`, `InactiveTitle`                                                                                                                                                                                        |
| Synchronize directories   | Selection: Background                                                                                                                                                                                                                                 | `SyncSelBack`                                                                                                                                                                                                                                                 |
| Hint windows              | Text color, Background color, Border                                                                                                                                                                                                                  | `HintForeground`, `HintBackground`, `HintBorder`                                                                                                                                                                                                              |
| Dark Mode                 | Text color; Background color; Highlight (active tab and buttons that stay down); Highlight (2) (the button being pressed, and borders); Border (list boxes, group boxes etc.); Horizontal lines (between the main menu, button bar and drive bar)     | `[ColorsDark]` `DarkForeground`, `DarkBackground`, `DarkHighlight`, `DarkBorder`, `HorizontalLines`                                                                                                                                                           |

**Title bar for file panels.** With the default colours the path bars follow the Windows caption colours: on Windows 11
the active panel's bar is a **muted steel blue** with light text, the inactive one a **lighter grey-blue** (host theme;
see Appendix A).

Other colour keys: `ThumbnailFrame=-1` (-2 = invisible); `TreeLineColor=-1` (-2 = invisible; used by panel trees,
separate trees, the Alt+F10 dialog and the FTP connect dialog); `TreeTriangles=-1` (0 = `[+]` boxes, 1 = triangles if
supported, -1 = TC decides); `ProgressBarBottom` / `ProgressBarTop`.

_Basis: observed on Windows 11 (cursor, path-bar colours) and under Wine (Color page); help: dlg_configcolor,
add_filelist, inisettings1–3._

## 10. Icons

### 10.1 File-list icons

| Option (Icons page)                                                            | Rule                                                                                                                                    | Ini                                                                                                                      |
| ------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| All associated + EXE/LNK (slow) (default)                                      | Extracts the icon of every EXE and LNK                                                                                                  | `Showicons=2`, `ShowEXEandLNKicons=1/2`                                                                                  |
| All associated                                                                 | The program icon for associated files; generic icons for archives, folders and programs; a white sheet otherwise; `!` for hidden/system | `Showicons=2`, `ShowEXEandLNKicons=0` (mapping inferred)                                                                 |
| Only standard icons                                                            | Every file gets the generic symbol; associations are not looked up (for slow machines)                                                  | `Showicons=1`                                                                                                            |
| No icons                                                                       | —                                                                                                                                       | `Showicons=0`                                                                                                            |
| EXE/LNK not on floppy (on)                                                     | No EXE/LNK extraction on `a:`/`b:`                                                                                                      | `ShowEXEandLNKicons=2` (default)                                                                                         |
| EXE/LNK not on net (off)                                                       | No EXE/LNK extraction on network drives and in Network Neighborhood                                                                     | `IconsOnNet=1` means extraction **on**; `IconsOnNetReadOnly=0`                                                           |
| Show icons for special folders: Normal file system / Virtual folders (both on) | Icons such as the recycle bin; servers in Network Neighborhood                                                                          | `IconsSpecialFolders=3`: 0 none, 1 local, 2 virtual, 3 both                                                              |
| Show default folder/file icons from Explorer (on)                              | Explorer's icons for unassociated files and plain folders                                                                               | `OldListIcons=0` (1 = TC 7/8 icons); ignored when `IconLib=` is set; ticking the option moves `IconLib` to `IconLib.bak` |
| Show overlay icons, e.g. for links (off)                                       | E.g. the link arrow, version-control overlays                                                                                           | `IconOverlays=0`; `IconOverlaysOneDrive=3`; `IconOverlaysUsb=1`; `cm_SwitchOverlayIcons`                                 |
| Show '!' on hidden/system (on)                                                 | A **red** exclamation mark on the icon of hidden and system items                                                                       | `ShowHiddenSystemOverlay=1`                                                                                              |
| Dimmed hidden files (on)                                                       | Hidden items get a lighter icon, as in Explorer                                                                                         | `ShowHiddenDimmed=1`                                                                                                     |

- Further keys: `IconsInThread=1` (load EXE/LNK icons in a background thread), `ShellExtIcons=1`, `IconFromIcoFile=1`
  (ICO files show their own icon), `TestIfSharedDir=1` (a hand under shared folders).
- On Windows 11 folders show Explorer's yellow folder icon and `[..]` an up-arrow icon. Generic icons: folder → folder
  icon; archive → parcel; program → window; associated file → its program's icon; other files → white sheet.

### 10.2 Icon size and row spacing

- **Icon size**: 16×16 · 24×24 · 32×32 · 48×48 · 64×64 (with a preview box). Saved **per screen resolution**
  (`Iconsize32=16`, `Iconsize32_<dpi>`). The default follows the DPI: **32×32** on Windows 11 at 200 % (depends on DPI;
  see Appendix A). Non-standard sizes are discouraged because folder icons scale badly.
- With icons switched off, the icon size still sets the row height.
- **Extra space**: Horizontal `[2]`, Vertical `[1]` (0…16 each). Horizontal = total pixels added left+right of the icon
  (2 ⇒ 1 px each side); Vertical = total above+below. When the font is taller than the icon, the extra is added to the
  font height:

```text
rowHeight     = max(iconHeight, fontHeight) + extraVertical
iconCellWidth = iconWidth + extraHorizontal
```

- Ini: `MinIconWidth=-2`, `MinLineHeight=-1`. A **negative** value is added to the normal width/height (this is what the
  dialog writes); a **positive** value is an absolute minimum and can only be set in the ini.

### 10.3 Main-menu icons

`IconsInMenus=17` is a bit sum:

- 1 = show icons (from `wcmicons.dll`/`wciconex.dll`, for internal commands);
- 2 = 3-D frame around the icon (button look, no theming; _Show 3d frame around icon_, off);
- 4 = 24×24; 8 = 32×32; 4+8 = 48×48 (the size combo offers 16/24/32/48);
- 16 = show checked items as **pressed buttons** instead of a check mark or bullet left of the icon.

`IconsInMenus_<dpi>=0…3` sets the size per DPI (16/24/32/48). `cm_ReloadBarIcons` forces the icons of the button bars
and the main menu to be reloaded.

_Basis: observed on Windows 11 (folder icons, red `!`, icon size) and under Wine (Icons page); help: dlg_configicons,
add_filelist, inisettings1–3._

## 11. Dark mode

### 11.1 Setting and switching

| Color-page choice                     | `DarkMode=` | Behaviour                                                 |
| ------------------------------------- | ----------- | --------------------------------------------------------- |
| Always disabled (default)             | 0           | Normal                                                    |
| Only when enabled for Windows 10 apps | 1           | Follows the Windows option "Choose your default app mode" |
| Always enabled                        | 2           | Dark                                                      |

- The Color-page setting applies immediately.
- **Configuration › Dark<->Normal** (`cm_SwitchDarkMode`; also `cm_EnableDarkMode` / `cm_DisableDarkMode`) switches at
  once. The switch changes the setting itself, except with `DarkMode=1`, where the automatic rule keeps applying and the
  switch is temporary.
- After switching on and straight back off, `wincmd.ini` still held `DarkMode=0` (observed; whether the toggle writes
  the key at once or only with the other settings was not established).
- Some elements change only after a restart: most context menus and the standard Windows dialogs.

### 11.2 Appearance

Observed on Windows 11, the whole window turns dark:

- menu bar and button bar dark grey, the toolbar icons recoloured light;
- file lists black (about `#1E1E1E`) with light-grey text;
- the cursor bar dark slate blue;
- the column header dark; the path bars dark grey, the active one slightly lighter;
- the drive combos dark.

### 11.3 Colours in dark mode

- Dark mode uses `[ColorsDark]` (Color › Others › Dark Mode, §9.3). Every `[Colors]` key except the colour filters may
  be overridden there. Normal mode uses the normal Windows theme colours.
- Own dark variants exist for view-mode backgrounds (`ActivePanelColorDark`, `…Dark2`), colour filters
  (`ColorFilterNColorDark`, 03 › Colours by file type), Lister (`[ListerDark]`) and focus frames (`InactiveFocusDark`,
  `SelectionFocusDark`).
- `DarkListBorders=1` (`[Layout]`) draws borders around list boxes in dark mode.

### 11.4 Platform rules

- Dark context menus need Windows 10 1809 or newer; on older Windows TC **simulates** the dark mode.
- The dark-mode options exist only on Windows XP and newer; on 95/98/ME/NT4/2000 they need `ForceDarkModeOptions=1` in
  `[Configuration]`.
- In dark mode the message-box buttons are always translated to the TC language (`TranslateMessageButtons`).

_Basis: observed on Windows 11; help: dark___normal, dlg_configcolor, def_colors_by_file_type, dlg_configviewmode,
inisettings1–3._

## 12. Window geometry and rendering metrics

### 12.1 Size, placement and persistence

- **First start** (Windows 11, 200 % scaling): the main window is **≈ 863 × 628 logical px**, placed **centred** on a
  1728 × 1117 logical screen as recorded (not reconciled with the `[3456x1896 (10x20)]` resolution section written at
  the same time; depends on DPI; see Appendix A).
- Both panels start at `c:\`.
- Position and size are saved per screen resolution with _Configuration › Save Position_ (`cm_ConfigSavePos`): `x`, `y`,
  `dx`, `dy`, `maximized` (0 normal, 1 maximized), per-monitor entries `monitor(x,y,dx,dy;dpi)=x,y,dx,dy`, `Tabstops`
  and the divider of the current mode (19 › Screen-resolution sections, 19 › What is saved when). A stored per-monitor
  size is restored when the window is dragged to another monitor.
- Window commands: `cm_Minimize`, `cm_Maximize`, `cm_Restore`, `cm_Exit`. `MinimizeOnClose` and the tray icon
  (`TrayIcon`) are in 19 › `[Configuration]`.

### 12.2 Metrics

Measured from screenshots, approximate, in logical px. The Windows 11 values were measured at 200 % with Segoe UI 9. The
96-DPI values come from the Wine session's scaled screenshots with Microsoft Sans Serif 8 bold (that window measured
1092 × 794 points by its host window bounds). All values depend on DPI and font (see Appendix A).

| Element                                | Windows 11, 200 %    | 96 DPI                                                                           |
| -------------------------------------- | -------------------- | -------------------------------------------------------------------------------- |
| Default window                         | ≈ 863 × 628, centred | ≈ 867 × 630                                                                      |
| Menu bar height                        | —                    | ~21                                                                              |
| Button bar                             | —                    | 24 px buttons with 16 px icons; separator a 1 px etched line with 3–4 px padding |
| Drive line                             | ≈ 16                 | ~20; combo ~36 wide; `\` and `..` buttons ~14 each, right-aligned                |
| Path bar                               | ≈ 14                 | ~16; a `▾` glyph at the left; `*` and `▼` ~14 each at the right                  |
| Column header                          | ≈ 14                 | ~16                                                                              |
| File-list row pitch                    | ≈ 13                 | ≈ 17 (font height + 1 px)                                                        |
| Status line / command line / F-key bar | —                    | ~16 / ~20 / ~20                                                                  |
| Vertical button bar                    | —                    | ~30 wide; buttons stacked from the top, a gap before Pack                        |
| Configuration dialog                   | —                    | ~507 × 400; tree ~120 wide; blue page caption ~16 high                           |

"—" = not measured on Windows. The Windows column is internally inconsistent and should be treated as approximate
(unverified): a row pitch of ≈ 13 logical px cannot hold the 32 × 32 physical (16 logical) icons of §10.2 plus 1 px, and
the screen size of §12.1 does not match the resolution section written at the same time. The likeliest cause is that the
measurements were taken on scaled screenshots; a clone should derive the metrics from the font, icon size and DPI rules
(§10.2) rather than from these numbers.

- Default **tabstops** on Windows 11 at 200 %: Extension 176, Size 234, Date/Time 238, Attributes 299, Comments 91
  (depends on DPI/font; see Appendix A). Their meaning: 03 › Column header and sorting.
- Row height: §10.2. Cursor pen width: §9.2 (`CursorPenWidth`, DPI-scaled). Path-bar height: `PathExtraHeight=-100` adds
  or removes height, scaled from 96 DPI (03 › Current-directory bar (path bar)).

_Basis: observed on Windows 11 (first-start geometry, row/header/path/drive-line heights, tabstops) and from the 96-DPI
screenshots; help: options_configsaveposition, inisettings3._
