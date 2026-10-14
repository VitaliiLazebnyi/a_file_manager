# 13: Configuration dialog

This chapter describes the **Configuration** dialog (Configuration › Options…): its frame and buttons, how each page can
be opened directly, where the values are stored, and then every page in the order of the navigation tree. For each page
it gives the layout with the captions as shown, the default of every control on a fresh installation, what the control
does, the ini key that stores it, and the effects observed when it was changed. Where a setting only switches a feature
that another chapter describes, the meaning is given briefly here and the full behaviour is in that chapter; the
complete key reference is in 19.

**Related:** 01 (first start), 02 (window elements, fonts, colours, icons, dark mode), 03 (panels, tabs, views, quick
search, refresh), 07 (file operations), 08 (archives), 10 (Lister), 11 (FTP), 14 (button bars, Choose command), 15
(plugins), 16 (localisation), 17 (internal commands), 18 (syntax), 19 (settings files), Appendix A (host differences).

**Conventions.** `[x]` / `[ ]` = checkbox on / off, `(o)` / `( )` = selected / unselected radio button, `[value ▾]` =
combo box, `[n ⇅]` = spin box, `[>>]` = browse button. Ini keys are in `wincmd.ini` `[Configuration]` unless another
section is named; "res." means the screen-resolution section (19 › Screen-resolution sections). Keys are written
`Key=default`. A key in the Key column with a value (e.g. `Showicons=2`) means "this control writes that value".

---

## 1. The dialog framework

### 1.1 Window and navigation tree

```text
┌ Configuration ──────────────────────────────────────────────────────────┐
│ Layout                   │ ┌───────────────── Layout ─────────────────┐ │
│ Display                  │ │                                          │ │
│    Icons                 │ │   (controls of the selected page)        │ │
│    Font                  │ │                                          │ │
│    Color                 │ │                                          │ │
│    Tabstops/Data Formats │ │                                          │ │
│    Folder Tabs           │ │                                          │ │
│    Custom columns        │ │                                          │ │
│    View Mode             │ │                                          │ │
│       Auto Switch Mode   │ │                                          │ │
│    Language              │ │                                          │ │
│ Operation                │ │                                          │ │
│    Edit/View             │ │                                          │ │
│    Copy/Delete           │ │                                          │ │
│    Refresh               │ │                                          │ │
│    Quick Search          │ │                                          │ │
│    FTP                   │ │                                          │ │
│    Plugins               │ │                                          │ │
│    Thumbnails            │ │                                          │ │
│    Log file              │ │                                          │ │
│    Ignore list           │ │                                          │ │
│    History               │ │                                          │ │
│ Packer                   │ │                                          │ │
│    Zip packer            │ │                                          │ │
│    7-Zip packer          │ └──────────────────────────────────────────┘ │
│ Misc.                    │          [ OK ] [ Cancel ] [ Help ] [ Apply ]│
└─────────────────────────────────────────────────────────────────────────┘
```

- A **modal** dialog titled **"Configuration"**, about 507 × 400 px as measured at 96 DPI (depends on DPI/font; see
  Appendix A).
- **Left:** the navigation tree. It uses indentation only, with no lines and no +/- boxes; every node is always
  expanded. Selecting a node shows its page. Every node, including the group nodes Display, Operation and Packer, has a
  page of its own.
- **Right:** the page, headed by a caption bar with the page name centred (white text on blue in the observed sessions).
- **Bottom right:** `[ OK ] [ Cancel ] [ Help ] [ Apply ]`.

### 1.2 Buttons, applying changes, leaving a page

| Control    | Behaviour                                                                                                                        |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------- |
| **OK**     | Applies the changes, writes them to `wincmd.ini` (FTP page: `wcx_ftp.ini`) and closes the dialog.                                |
| **Cancel** | Discards the changes and closes. Whether changes already applied with Apply are reverted is not documented and was not recorded. |
| **Help**   | Opens the help topic of the current page.                                                                                        |
| **Apply**  | Applies the current settings to the two file panels **without closing** the dialog. Disabled until something has been changed.   |
| **Esc**    | Same as Cancel: closes the whole dialog without saving.                                                                          |

- **Live effects.** Applied settings take effect at once. Observed on Windows 11: _Show drive buttons_ (Layout) made the
  drive bar appear immediately; _Append \\_ with brackets off (Display) redrew the folder names immediately; _Like files
  (also by time)_ (Display) re-sorted the folders after OK; _Letter only_ (Quick Search) changed the typing behaviour at
  once. Dark mode (Color page) is applied immediately, but some elements need a restart (02 › Dark mode).
- **Invalid pages.** A page can refuse to be left while its content is invalid: after an incomplete rule had been added
  on _Auto Switch Mode_, selecting another tree node changed the tree selection but the page stayed, until the dialog
  was cancelled.

### 1.3 Opening a page directly

Each page has its own internal command, so a button, hotkey or menu item can open the dialog on that page. The commands
are in the _Configuration_ category of the command list (17).

| Page                                       | Command                                                          | Nr              |
| ------------------------------------------ | ---------------------------------------------------------------- | --------------- |
| Layout (first page)                        | `cm_Config` / `cm_LayoutConfig`                                  | 490 / 476       |
| Display                                    | `cm_DisplayConfig`                                               | 486             |
| Icons                                      | `cm_IconConfig`                                                  | 477             |
| Font                                       | `cm_FontConfig`                                                  | 492             |
| Color                                      | `cm_ColorConfig`                                                 | 494             |
| Tabstops/Data Formats                      | `cm_ConfTabChange`                                               | 497             |
| Folder Tabs                                | `cm_DirTabsConfig`                                               | 488             |
| Custom columns                             | `cm_CustomColumnConfig`                                          | 483             |
| View Mode / Auto Switch Mode               | `cm_ConfigViewModes` / `cm_ConfigViewModeSwitch`                 | 2939 / 2940     |
| Language                                   | `cm_LanguageConfig`                                              | 499             |
| Operation                                  | `cm_Config2`                                                     | 516             |
| Edit/View                                  | `cm_EditConfig`                                                  | 496             |
| Configure Lister (sub-dialog of Edit/View) | `cm_ConfigLister`                                                | 3036            |
| Copy/Delete                                | `cm_CopyConfig`                                                  | 487             |
| Refresh                                    | `cm_RefreshConfig`                                               | 478             |
| Quick Search                               | `cm_QuickSearchConfig`                                           | 479             |
| FTP                                        | `cm_FtpConfig`                                                   | 489             |
| Plugins                                    | `cm_PluginsConfig`                                               | 484             |
| Thumbnails                                 | `cm_ThumbnailsConfig`                                            | 482             |
| Log file                                   | `cm_LogConfig`                                                   | 481             |
| Ignore list                                | `cm_IgnoreConfig`                                                | 480             |
| History                                    | `cm_HistoryConfig`                                               | 475             |
| Packer / Zip packer / 7-Zip packer         | `cm_PackerConfig` / `cm_ZipPackerConfig` / `cm_7ZipPackerConfig` | 491 / 485 / 474 |
| Misc. (confirmations, hotkeys, sounds)     | `cm_Confirmation`                                                | 495             |

Related configuration commands outside this dialog: `cm_ButtonConfig` 498 (main button bar), `cm_ButtonConfig2` 583
(vertical bar), `cm_ChangeStartMenu` 700, `cm_ConfigSavePos` 493, `cm_ConfigSaveSettings` 580, `cm_ConfigChangeIniFiles`
581, `cm_ConfigSaveDirHistory` 582 (§23), `cm_CommandBrowser` 2924 (_Choose command_ on its own),
`cm_ReloadBarIcons` 2945. Their dialogs are in 14.

### 1.4 Where the values are stored

- Settings are written to **`wincmd.ini`**; the values of the **FTP** page go to **`wcx_ftp.ini`**. The paths in use are
  shown in Help › About (12 › About box).
- Values that depend on the screen (fonts, file-list icon size, tabstops, extra drive-button space, thumbnail zoom,
  menu-icon size per DPI) are stored in the **screen-resolution section**, e.g. `[3456x1896 (10x20)]` on Windows 11 at
  200 %, or in `[AllResolutions]` when `ResolutionSpecific=0`.
- TC reads and writes the ini files through the Windows profile API. Valid encodings are ANSI and UTF-16 LE; **an ini
  saved as UTF-8 without BOM gives garbled accented characters**.
- If `wincmd.ini` is missing at start-up, TC copies `maintemplate.txt` from the program directory to `wincmd.ini`, and
  `ftptemplate.txt` to `wcx_ftp.ini` (for company deployments).
- `AlternateUserIni=` redirects the user-changeable sections to another file, except `[Configuration]`, `[Layout]`,
  `[Packer]`, `[Confirmation]`, `[Extensions]`, `[Associations]`, `[Shortcuts]`, `[ShortcutsWin]` and the four plugin
  sections. Any section may carry `RedirectSection=` (`0` never, `1` to the AlternateUserIni file, or a file name).

Details of these rules: 19 › INI rules, 19 › Several ini files.

### 1.5 Defaults and the first start

- On the **first start** after installation the dialog opens by itself on the **Layout** page. When it is closed, the
  icon-library chooser follows (01 › First-start dialogs).
- The defaults in this chapter are those of a **fresh installation on Windows 11** (200 % scaling, 192 DPI). Pages
  checked there: Layout, Display, Icons, Font, Color, Tabstops/Data Formats, Folder Tabs, View Mode, Operation,
  Edit/View, Copy/Delete, Refresh, Quick Search, Thumbnails and Misc. Every checked page matched the Wine session except
  the font-, DPI- and icon-size values on Icons, Font and Tabstops, which depend on the DPI and the fonts (Appendix A).
- The remaining pages (Custom columns, Auto Switch Mode, Language, FTP, Plugins, Log file, Ignore list, History, Packer,
  Zip packer, 7-Zip packer) were recorded under Wine only; none of their defaults depends on DPI or fonts.

_Basis: observed on Windows 11 and under Wine; help: options_config, inisettings; command list (inc)._

---

## 2. Layout

Switches the parts of the main window on and off (02 › Window composition and visibility).

```text
Screen layout
 [x] Show button bar
 [x] Show button bar 2 (vertical)
 [ ] Show drive buttons
     [ ] Show two drive button bars (fixed width, above file windows)
     [x] Flat icons
 [x] Show drive combobox
 [x] Show folder tabs
 [x] Show current directory
     [x] Show clickable path parts ('breadcrumb bar')
         [ ] Auto-open when moving mouse over it
     [x] Show buttons for history list and hotlist
 [x] Show tabstop header
 [x] Show status bar
 [x] Show command line
     [ ] Run command line only when focused
 [x] Show function key buttons
──────────────────────────────────────────────── (untitled group)
 [x] Flat user interface (button bar configured separately)
 [x] Windows XP theme background (menu+all bars)
```

The two drive-bar sub-options are enabled only while _Show drive buttons_ is ticked.

| Control                                                        | Default | `[Layout]` key                                                                           | Toggle command                 | Meaning                                                                                                                                                                                                          |
| -------------------------------------------------------------- | ------- | ---------------------------------------------------------------------------------------- | ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Show button bar                                                | on      | `ButtonBar=1`                                                                            | `cm_VisButtonBar` 2901         | Main (horizontal) button bar. Hiding and showing it again **reloads the default bar file**, leaving any subbar.                                                                                                  |
| Show button bar 2 (vertical)                                   | on      | `ButtonBarVertical=1`                                                                    | `cm_VisButtonBar2` 2944        | Second, vertical bar between the panels                                                                                                                                                                          |
| Show drive buttons                                             | off     | `DriveBar1=0`                                                                            | `cm_VisDriveButtons` 2902      | One bar with a button per drive                                                                                                                                                                                  |
| └ Show two drive button bars (fixed width, above file windows) | off     | `DriveBar2=0`                                                                            | `cm_VisTwoDriveButtons` 2903   | One bar above each file list. Both have the **same fixed width**, which does not follow the panel widths. Used only with `DriveBar1=1`.                                                                          |
| └ Flat icons                                                   | on      | `DriveBarFlat=1`                                                                         | `cm_VisFlatDriveButtons` 2904  | Flat style for the drive bar only                                                                                                                                                                                |
| Show drive combobox                                            | on      | `DriveCombo=1`                                                                           | `cm_VisDriveCombo` 2906        | Drop-down drive selector                                                                                                                                                                                         |
| Show folder tabs                                               | on      | `DirectoryTabs=1`                                                                        | `cm_VisDirTabs` 2916           | Tab headers. By default the header row is hidden while a panel has only one tab (§8).                                                                                                                            |
| Show current directory                                         | on      | `CurDir=1`                                                                               | `cm_VisCurDir` 2907            | Path header above each panel; it also marks the active panel                                                                                                                                                     |
| └ Show clickable path parts ('breadcrumb bar')                 | on      | `BreadCrumbBar=1`                                                                        | `cm_VisBreadCrumbs` 2926       | A small triangle left of the path; hovering underlines path parts; clicking a part jumps there; an arrow button under the hovered part opens a submenu of its subfolders (03 › Current-directory bar (path bar)) |
| └└ Auto-open when moving mouse over it                         | off     | not documented; probably a negative `[Configuration] BreadcrumbDelayButton` (unverified) | —                              | The submenu opens directly after the hover delay (standard 250 ms) instead of an arrow button being shown                                                                                                        |
| └ Show buttons for history list and hotlist                    | on      | `HistoryHotlistButtons=1`                                                                | `cm_VisHistHotButtons` 2919    | `*` (hotlist) and `▼` (directory history) at the right end of the path header                                                                                                                                    |
| Show tabstop header                                            | on      | `TabHeader=1`                                                                            | `cm_VisTabHeader` 2908         | Column header in Full view, used to move tabstops and to sort                                                                                                                                                    |
| Show status bar                                                | on      | `StatusBar=1`                                                                            | `cm_VisStatusBar` 2909         | Footer with the totals of all and of the selected files                                                                                                                                                          |
| Show command line                                              | on      | `CmdLine=1`                                                                              | `cm_VisCmdLine` 2910           | Command line. **When hidden, it appears as soon as a letter is typed.**                                                                                                                                          |
| └ Run command line only when focused                           | off     | `[Configuration] ExecCmdLineFocused=0`                                                   | —                              | Enter runs the command line only while the command line has the focus; Enter in a panel always acts on the panel                                                                                                 |
| Show function key buttons                                      | on      | `KeyButtons=1`                                                                           | `cm_VisKeyButtons` 2911        | F3 … Alt+F4 button row                                                                                                                                                                                           |
| Flat user interface (button bar configured separately)         | on      | `InterfaceFlat=1`                                                                        | `cm_VisFlatInterface` 2905     | Flat style for everything **except** the button bars and the drive bar, which have their own options; off = 3-D look                                                                                             |
| Windows XP theme background (menu+all bars)                    | on      | `XPthemeBg=1`                                                                            | `cm_VisXPthemeBackground` 2923 | Themed background under the main menu, button bar, drive bar and FTP toolbar; can be turned off if alternative themes draw badly                                                                                 |

**`cm_Vis*` parameters:** `0` or none = toggle, `1` = show, `-1` or `2` = hide. Add `4` to apply the change **without
saving it** to `wincmd.ini`: `4` toggles, `5` shows, `6` hides (use `2`, not `-1`, as the base for "hide").

**Related keys not on the page:** `[Layout] TabHeaderThemed=1`, `TabHeaderBoldArrow` (defaults to the `TabHeaderThemed`
value), `DarkListBorders=1`. Breadcrumb delays in ms: `BreadcrumbDelayButton=250` (a negative value shows the subfolder
list directly, without the button), `BreadcrumbDelayDir=250`, `BreadcrumbDelayFtp=500`, `BreadcrumbDelayPlugin=500`,
`BreadcrumbDelayVirtual=500`.

**Observed (Windows 11):** _Show drive buttons_ on + Apply: a drive button bar appeared at once under the button bar,
reading `[c] [d] [\]`, flat icons with letter labels.

_Basis: observed on Windows 11 and under Wine; help: dlg_config, inisettings2, inisettings3._

---

## 3. Display

File-list display options. The rendering rules are in 03 (file list, sorting, tree view, tooltips).

```text
File display
 [ ] Show hidden files                      [ ] Show system files
 [x] Use long names (recommended)
 [ ] Show old 8.3 filenames lowercase (like explorer)
 [ ] Show parent dir [..] also in root of drive
 [x] Show square brackets [ ] around directories   [ ] Append \
 [ ] Limit width of brief view column to: [200] Pixels
 Sort method: [Alphabetical, considering accents ▾]
Tree
 [ ] Always load complete directory tree
 [x] Tree: Press ENTER to open dir in other window
Sorting directories
 (o) Always by name        ( ) Like files (also by time)
Help texts
 [x] Show help texts for buttons (tooltips)
 [x] Show volume labels/network paths for drives
 [ ] Show filename in file list as tooltip if truncated
     [ ] Win32-style tips with file comments (if available)
     [x] Comments from descript.ion/files.bbs
     [x] Comments from Explorer (OLE2)          User-defined: [+]
```

The _Limit width_ edit box is enabled only while its checkbox is ticked; the four tooltip sub-options only while _Show
filename … as tooltip_ is ticked.

### 3.1 File display

| Control                                                | Default                           | Key                                                                                                            | Meaning                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ------------------------------------------------------ | --------------------------------- | -------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Show hidden files / Show system files                  | both off                          | `ShowHiddenSystem=0`: `0` neither, `1` both, `2` hidden only, `3` system only                                  | Two switches for items with the H and with the S attribute; some system folders need the second. Commands `cm_SwitchHidSys`, `cm_SwitchHid`, `cm_SwitchSys`. With the defaults, files with the Hidden or System attribute are not listed; names starting with a dot are listed normally unless they carry the attribute.                                                                                                                                                                                                                  |
| Use long names (recommended)                           | on                                | `UseLongNames=1`                                                                                               | Untick only to work around problems, e.g. with network drives. **Cannot be changed while a background transfer runs.** While off, renaming to a long name **truncates it to 8.3**. `cm_SwitchLongNames`.                                                                                                                                                                                                                                                                                                                                  |
| Show old 8.3 filenames lowercase (like explorer)       | off                               | `Small83names=0`                                                                                               | Short DOS names (stored upper case) are shown lower case except the first letter; can cause problems on UNIX network drives. `cm_Switch83Names`.                                                                                                                                                                                                                                                                                                                                                                                          |
| Show parent dir [..] also in root of drive             | off                               | `ShowParentDirInRoot=0`                                                                                        | `[..]` also in a drive root; it leads up to _My Computer_, the list of all drives                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Show square brackets [ ] around directories / Append \ | brackets on, Append off           | `DirBrackets=1`: `1` brackets, `2` backslash, `3` both                                                         | Folders shown as `[dir]` or as `dir\`. To get both, tick _Append \\_ first, then the brackets.                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Limit width of brief view column to: [n] Pixels        | off, 200                          | `BriefViewWidthLimit=`; `BriefViewWidthLimitMin=0` (ini only; 0 = width of `wwwwwwww.www` in the current font) | A Brief-view column is normally as wide as the longest name, limited only by the panel width; this caps it at n pixels                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Sort method                                            | Alphabetical, considering accents | `SortUpper=0` (values 0–3 in list order; the mapping is inferred from the help)                                | How names are compared (03 › Column header and sorting): **Alphabetical, considering accents** = the system compare function for the current language; **Strictly by numeric character code** = upper-case character codes, so accented letters (and names starting with `_`) sort after Z; **Natural sorting: by character code and numbers** = lower-case codes, digit runs compared as numbers (`file5.txt` < `file10.txt`); **Natural sorting: alphabetical and numbers** = the same, language-aware (`StrCmpLogicalW`, needs IE ≥ 6) |

**Observed (Windows 11):** square brackets off and _Append \\_ on, Apply: folders were shown as `bin\`, `docs\` and the
parent as `..\` at once.

### 3.2 Tree

| Control                                       | Default | Key                                                                                | Meaning                                                                                                                                                                                                                                                                                             |
| --------------------------------------------- | ------- | ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Always load complete directory tree           | off     | `OldStyleTree=0` (this box = `1`; `2` = expandable tree of the current drive only) | Off: a tree view in a panel reads only the top-level folders and expands on demand. On: the whole tree of the current drive is loaded at once, rooted at the drive root, without special-folder icons, using the `treeinfo*.wc` cache. **No effect on the separate tree panels.** (03 › View types) |
| Tree: Press ENTER to open dir in other window | on      | `Autotreechange=0` (checked = 0; inferred)                                         | On: Enter opens the folder under the tree cursor in the other panel. Off: the folder under the cursor opens there automatically as the cursor moves.                                                                                                                                                |

### 3.3 Sorting directories

| Control                   | Default  | Key                | Meaning                                                                                                                                                                                                              |
| ------------------------- | -------- | ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Always by name            | selected | `SortDirsByName=1` | Folders always sorted by name, ascending, whatever the file sort and direction                                                                                                                                       |
| Like files (also by time) | —        | `SortDirsByName=0` | Folders follow the file sort key and direction, including time and reverse order; they stay above the files. `SortDirExt=0` (ini only) allows sorting folders by extension in this mode. `cm_SwitchDirSort` toggles. |

**Observed (Windows 11):** _Like files (also by time)_, OK, then sort by Date descending: folders were sorted newest
first (docs 12:02, photos 12:02, bin 12:01, locked_target 11:55), still above the files.

### 3.4 Help texts

| Control                                              | Default | Key                                                                                                                                                    | Meaning                                                                                                                                                                                        |
| ---------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Show help texts for buttons (tooltips)               | on      | `Tips=3`, bit 1; `ToolTipDelay=500`                                                                                                                    | Tooltip after about 0.5 s over a button-bar button                                                                                                                                             |
| Show volume labels/network paths for drives          | on      | `Tips` bit 2; `DriveTipDelay=0`                                                                                                                        | Descriptions beside the drives in the open drive combo                                                                                                                                         |
| Show filename in file list as tooltip if truncated   | off     | `FileTipWindows=0`; `FileTipWindowsOnIcon=0` (ini only: `1` only over the icon, `2` Win32-style tip over the icon and full name over a shortened name) | When a name does not fit, the full name appears after about **1 s** of pointing; a click or double click removes it. `cm_SwitchFileTipWindows`; `cm_ShowHint` shows the tip from the keyboard. |
| └ Win32-style tips with file comments (if available) | off     | `Win32TipWindows` (defaults to `FileTipWindows`)                                                                                                       | The tip appears **below-right of the mouse** and adds NTFS comments, MS-Office embedded comments and `descript.ion`/`files.bbs` comments; **any key hides it**                                 |
| └ Comments from descript.ion/files.bbs               | on      | `OleComments=1`: `0` comment files only, `1` both, `2` Explorer only, `3` none (plugins only)                                                          | Include comments made with Ctrl+Z (07 › File comments (Ctrl+Z))                                                                                                                                |
| └ Comments from Explorer (OLE2)                      | on      | `OleComments` (as above)                                                                                                                               | Include comments set through Properties (Alt+Enter) in Explorer or TC, stored in NTFS streams, and those of tools such as Mp3ext                                                               |
| └ User-defined: [+]                                  | none    | `[HintsCustomField]` `xexts=` / `xfields=`; `HintMultiFilters=0` (1 = show the tips of all matching filters)                                           | Per-file-type tips built from content-plugin fields, e.g. one set for `*.jpg`, another for `*.mp3`                                                                                             |

_Basis: observed on Windows 11 and under Wine; help: dlg_display, inisettings1, inisettings2, inisettings3._

---

## 4. Display › Icons

Icons in the file lists, the main menu and the drive controls (02 › Icons; 03 › File list rendering).

```text
Show icons to the left of the filename
 (o) All associated + EXE/LNK (slow)
 ( ) All associated                        [x] EXE/LNK not on floppy
 ( ) Only standard icons                   [ ] EXE/LNK not on net
 ( ) No icons
 [x] Show icons for special folders: Normal file system
 [x] Show icons for special folders: Virtual folders (e.g. Network)
 [x] Show default folder/file icons from Explorer
 [ ] Show overlay icons, e.g. for links
 [x] Show '!' on hidden/system             [x] Dimmed hidden files
Icon size
 [32x32 ▾]                                 ┌─────┐ preview of a sample icon
 Extra space: Horizontal: [2 ▾]  Vertical: [1 ▾]
Icons in main menu
 [x] Show icons for commands in the main menu        [16x16 ▾]
     [ ] Show 3d frame around icon
     [x] Show checked items as pressed buttons instead of checkmarks
──────────────────────────────────────────────── (untitled group)
 [x] Show drive icons from Explorer
 [Set default icon library]
```

| Control                                                                             | Default                                        | Key                                                                                                                               | Meaning                                                                                                                                                                                                                                                                                                                                                          |
| ----------------------------------------------------------------------------------- | ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| All associated + EXE/LNK (slow)                                                     | selected                                       | `Showicons=2`, `ShowEXEandLNKicons=1` or `2`                                                                                      | The icon of every EXE and LNK file is extracted                                                                                                                                                                                                                                                                                                                  |
| All associated                                                                      | —                                              | `Showicons=2`, `ShowEXEandLNKicons=0` (inferred)                                                                                  | Program icon for associated files; generic icons for archives (parcel), folders and programs (window); white sheet otherwise; `!` on hidden/system                                                                                                                                                                                                               |
| Only standard icons                                                                 | —                                              | `Showicons=1`                                                                                                                     | Every file gets the generic symbol; associations are not looked up (slow machines)                                                                                                                                                                                                                                                                               |
| No icons                                                                            | —                                              | `Showicons=0`                                                                                                                     | No symbols                                                                                                                                                                                                                                                                                                                                                       |
| EXE/LNK not on floppy                                                               | on                                             | `ShowEXEandLNKicons=2`                                                                                                            | No EXE/LNK extraction on `a:` and `b:`                                                                                                                                                                                                                                                                                                                           |
| EXE/LNK not on net                                                                  | off                                            | `IconsOnNet=1` (1 = extraction **on**, i.e. the box unticked); `IconsOnNetReadOnly=0`                                             | No EXE/LNK extraction on network drives and in Network Neighborhood (slow links)                                                                                                                                                                                                                                                                                 |
| Show icons for special folders: Normal file system / Virtual folders (e.g. Network) | both on                                        | `IconsSpecialFolders=3`: `0` none, `1` local, `2` virtual, `3` both                                                               | Icons such as the recycle bin; servers in Network Neighborhood                                                                                                                                                                                                                                                                                                   |
| Show default folder/file icons from Explorer                                        | on                                             | `OldListIcons=0` (1 = TC 7/8 icons); ignored when `IconLib=` is set; ticking the box moves `IconLib` to `IconLib.bak`             | Explorer's icons for unassociated files and plain folders                                                                                                                                                                                                                                                                                                        |
| Show overlay icons, e.g. for links                                                  | off                                            | `IconOverlays=0`; `IconOverlaysOneDrive=3`; `IconOverlaysUsb=1`                                                                   | Overlays such as the link arrow or version-control marks. `cm_SwitchOverlayIcons`.                                                                                                                                                                                                                                                                               |
| Show '!' on hidden/system                                                           | on                                             | `ShowHiddenSystemOverlay=1`                                                                                                       | Exclamation mark on the icon                                                                                                                                                                                                                                                                                                                                     |
| Dimmed hidden files                                                                 | on                                             | `ShowHiddenDimmed=1`                                                                                                              | Hidden items get a lighter icon, as in Explorer                                                                                                                                                                                                                                                                                                                  |
| Icon size                                                                           | 32x32 (depends on DPI/font; see Appendix A)    | res. `Iconsize32` (with `Iconsize32_dpi`, `Iconsize32_<dpi>`)                                                                     | List: 16x16 · 24x24 · 32x32 · 48x48 · 64x64; a preview box shows a sample icon at that size. Saved **per screen resolution**. With icons off, the size still sets the **row height**. The help discourages non-standard sizes because folder icons scale badly.                                                                                                  |
| Extra space: Horizontal / Vertical                                                  | 2 / 1 (lists 0…16)                             | `MinIconWidth=-2`, `MinLineHeight=-1`                                                                                             | Total pixels added left+right / above+below the icon (2 ⇒ 1 px each side). When the font is taller than the icon, the vertical extra is added to the **font** height. Negative ini values (what the dialog writes) are added to the normal size; positive values are absolute minimums (ini only).                                                               |
| Extra drive space: H / V                                                            | 0 / 0                                          | res. `ExtraDriveWidth`, `ExtraDriveHeight` (with `_dpi`, `_<dpi>`)                                                                | The same sums for the drive-bar buttons. **Shown only while the drive button bar is enabled** (§2), so not visible with the defaults.                                                                                                                                                                                                                            |
| Show icons for commands in the main menu + size                                     | on, 16x16 (list 16x16 · 24x24 · 32x32 · 48x48) | `IconsInMenus=17` (bit 1); size bits `4` = 24, `8` = 32, `4+8` = 48; `IconsInMenus_<dpi>=0…3` (res.)                              | Icons from `wcmicons.dll` / `wciconex.dll` for internal commands in the main menu                                                                                                                                                                                                                                                                                |
| └ Show 3d frame around icon                                                         | off                                            | `IconsInMenus` bit 2                                                                                                              | Icons drawn like buttons, without XP theming                                                                                                                                                                                                                                                                                                                     |
| └ Show checked items as pressed buttons instead of checkmarks                       | on                                             | `IconsInMenus` bit 16                                                                                                             | Active items (e.g. the sort order) shown as a pressed button instead of a check mark or bullet left of the icon                                                                                                                                                                                                                                                  |
| Show drive icons from Explorer                                                      | on                                             | `OldDriveIcons=0` (`1` TC 6.5x icons, `2` TC 7/8 icons); `DriveLib=` overrides it, and ticking the box moves it to `DriveLib.bak` | Explorer drive icons in the drive bar, the drive combo and the folder tabs                                                                                                                                                                                                                                                                                       |
| Set default icon library                                                            | —                                              | not documented                                                                                                                    | When several icon libraries are installed, chooses the one used by the button bar and main menu: every button defined with `wcmicons.dll` **without a path** uses the chosen library. The first-start chooser offers `1: wcmicons.dll` and `2: [wcmicon2.dll: TCNewLib1 ▾]` (01 › First-start dialogs); that this button opens the same chooser is not recorded. |

Row height and icon cell width:

```text
rowHeight     = max(iconHeight, fontHeight) + extraVertical
iconCellWidth = iconWidth + extraHorizontal
```

Ini-only icon keys: `IconsInThread=1` (EXE/LNK icons loaded in a thread), `ShellExtIcons=1`, `IconFromIcoFile=1` (ICO
files show their own icon), `TestIfSharedDir=1` (hand overlay on shared folders), `ThumbIconSize=48` (icons in
Thumbnails view, §20).

_Basis: observed on Windows 11 and under Wine; help: dlg_configicons, inisettings1, inisettings2, inisettings3._

---

## 5. Display › Font

Fonts of the file lists, the main window and the dialogs, and dialog scaling (02 › Fonts).

```text
Dialog box scaling (does not scale the main window)
 [ ] Set dots per inch (DPI) to: [192 ⇅]            (disabled while unticked)
 [x] Automatically adjust dialog boxes to larger fonts
File list font
 Segoe UI,9                                         [Change font]
 ┌ ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz äöüéèêàñç ┐
Main window font
 Segoe UI,9                                         [Change font]
 ┌ ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz äöüéèêàñç ┐
Dialog box font
 Microsoft Sans Serif,8                             [Change font]
 ┌ ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz äöüéèêàñç ┐
```

Each font group shows the font as `name,size[,b]` (`b` = bold) and a sample box drawn in that font. _Change font_ opens
the standard Windows font chooser.

| Control                                           | Default                                                                           | Key (res.)                                                                                  | Meaning                                                                                                                                                                 |
| ------------------------------------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Set dots per inch (DPI) to                        | off; the box shows the Windows DPI, 192 at 200 % (depends on DPI; see Appendix A) | `[Configuration] OverrideDPI=`, per-DPI form `OverrideDPI<dpi>=` (e.g. `OverrideDPI96=120`) | Scales the dialog boxes and their font to the given DPI. Does **not** scale the main window, the file-list font or the main-window font. Default = the Windows scaling. |
| Automatically adjust dialog boxes to larger fonts | on                                                                                | `[Configuration] AutoSizeDialogs=1`                                                         | Dialogs grow when the dialog font is larger than the default. Without it they keep their size; use an 8–10 pt font then.                                                |
| File list font                                    | Segoe UI,9 (depends on DPI/font; see Appendix A)                                  | `Fontname`, `Fontsize`, `FontWeight`, `FontCharset`                                         | Font of the file lists                                                                                                                                                  |
| Main window font                                  | Segoe UI,9 (depends on DPI/font; see Appendix A)                                  | `FontNameWindow`, `FontSizeWindow`, `FontWeightWindow`, `FontCharsetWindow`                 | Everything in the main window except the file lists                                                                                                                     |
| Dialog box font                                   | Microsoft Sans Serif,8                                                            | `FontNameDialog`, `FontSizeDialog`, `FontWeightDialog`, `FontCharsetDialog`                 | Dialogs. Meant for languages whose default dialog font (MS Sans Serif 8) lacks the code page, e.g. Japanese.                                                            |

Rules:

- **Weight** is normal or **bold** only (`FontWeight` 400 normal, 600 semibold, 700 bold); **italic is not supported**.
  Some fonts, such as Script, render wrongly.
- Changing a font **resizes the main window** automatically, but never beyond the screen size; the tabstops (§7) may
  then need adjusting.
- The chooser's _Character Set_ is ignored on NT systems (`FontCharset…=1` is not used there); characters missing from
  the font are substituted by Windows.
- **Default fonts:** `[Configuration] UseNewDefFont=-1` acts as `1` on a fresh installation (no `[Configuration]`
  section yet) and as `0` otherwise; a fresh installation writes `UseNewDefFont=1`. With `1` the help names **Segoe UI
  Semibold, 9** (Vista and later); the Font page of a fresh Windows 11 installation showed **Segoe UI,9**, regular
  (neither Semibold nor bold), for the file list and the main window. With `0` the fonts are **Microsoft Sans Serif 8**,
  bold (MS Sans Serif on 9x/ME), default weight 700.
- Ini-only fonts in the resolution section: the tooltip font `FontNameTip`, `FontSizeTip`, `FontWeightTip`,
  `FontCharsetTip` (the dialog font is used when absent) and the Compare-by-content font `CompFontName`, `CompFontSize`,
  `CompFontStyle`, `CompCharSet`. `[Configuration] FontQuality=0` (`3` non-antialiased, `4` antialiased, `5` ClearType,
  `6` ClearType natural), `FontQualityMenu=0`, `FontSampleText=` (sample text of this page; empty = built-in).

_Basis: observed on Windows 11 and under Wine; help: dlg_configfont, inisettings2, inisettings3._

---

## 6. Display › Color

Colours of the file lists and other elements, dark mode, cursor style and colours by file type (02 › Colours, 02 › Dark
mode; 03 › Colours by file type).

```text
Color
 Dark mode:    [Always disabled ▾]
 Font color:   [default ▾] [>>]          Example:
 Background:   [default ▾] [>>]          ┌──────────────────┐
 Background 2: [default ▾] [>>]          │ Selected         │  (red)
 Mark color:   [red     ▾] [>>]          │ Selected         │
 Cursor color: [default ▾] [>>]          │ Text             │
 Cursor font:  [default ▾] [>>]          │ Text             │
 Others: [element ▾] [colour ▾] [>>]     │ Cursor           │  (on blue)
 [x] Use Windows theme for cursor        │ Selected+Cursor  │  (red on blue)
 [ ] Use inverted cursor                 └──────────────────┘
 [ ] Use inverted selection
 [x] [Define colors by file type...]
```

- Each colour row is a colour combo plus `[>>]`, which opens the Windows colour picker with custom colours. The combo
  offers `default`, then 16 swatches: white, silver, grey, black, red, maroon, lime, green, blue, navy, yellow, olive,
  aqua, teal, fuchsia, purple.
- _Cursor font_ is available **only while _Use inverted cursor_ is ticked**, so it is disabled with the defaults.
- The _Example_ list previews the current text, background, mark and cursor colours.
- The colours of buttons and lines cannot be changed here; they follow the system settings.

### 6.1 Main colours and cursor style

| Control                                           | Default            | Key                                                                                                                                                                                     | Meaning                                                                                                                           |
| ------------------------------------------------- | ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Dark mode                                         | Always disabled    | `DarkMode=0`: `0` Always disabled, `1` Only when enabled for Windows 10 apps, `2` Always enabled (list order: Always disabled · Always enabled · Only when enabled for Windows 10 apps) | Dark user interface; value 1 follows the Windows app mode. Applied immediately; uses the `[ColorsDark]` colours (02 › Dark mode). |
| Font color                                        | default            | `[Colors] ForeColor=-1`                                                                                                                                                                 | Text of the file lists                                                                                                            |
| Background                                        | default            | `[Colors] BackColor=-1`                                                                                                                                                                 | **Only the file panels**; the surrounding window uses the system button colour                                                    |
| Background 2                                      | default            | `[Colors] BackColor2=-1`                                                                                                                                                                | Every other line, for alternating rows; pick a colour close to Background                                                         |
| Mark color                                        | red                | `[Colors] MarkColor=255`                                                                                                                                                                | Text of selected items, or the bar with inverted selection                                                                        |
| Cursor color                                      | default            | `[Colors] CursorColor=-1`                                                                                                                                                               | The frame around the current file, or the bar with inverted cursor; default a dashed inverted frame                               |
| Cursor font                                       | default (disabled) | `[Colors] CursorText=-1`                                                                                                                                                                | Text inside the inverted cursor bar                                                                                               |
| Use Windows theme for cursor                      | on                 | `[Colors] ThemedCursor=-100`: `1` on, `0` off, `-100` automatic (themed only with `InverseCursor=0` and no WindowBlinds)                                                                | Cursor drawn with the Windows theme. On Windows 11: a light-blue filled bar with a darker blue 1 px border.                       |
| Use inverted cursor                               | off                | `[Colors] InverseCursor=0`                                                                                                                                                              | Solid bar in Cursor color, text in Cursor font; otherwise a rectangle                                                             |
| Use inverted selection                            | off                | `[Colors] InverseSelection=0`                                                                                                                                                           | Selected items drawn as solid bars in Mark color. **Cannot be combined with the inverted cursor.**                                |
| Define colors by file type... (checkbox + button) | on, list empty     | `[Colors] ColorFilters=1`; `cm_SwitchColorsByFileType`                                                                                                                                  | The checkbox switches the feature on; the button opens the editor (§6.3)                                                          |

Colour values are `red + 256·green + 65536·blue` (hex `$BBGGRR`); `-1` = system default. Cursor, selection and
focus-frame rendering rules (`CursorPenWidth`, `InactiveFocus`, `SelectionFocus`) are in 02 › Colours and 03 › File list
rendering.

### 6.2 Others

`Others: [element ▾] [colour ▾] [>>]` sets the colours of further elements. The element list is grouped:

| Group                     | Elements (as listed)                                                                                                                                                                                                                                                                                             | Keys                                                                                                                                                                                                                                                                            |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Lister                    | Text color, Background color, Selected text, Selected background, Link color, Media player controls: Text, Media player controls: Background                                                                                                                                                                     | `[Lister]` `FgColor`, `BgColor`, `FgSelColor`, `BgSelColor`, `LinkColor` (HTML-as-text mode only), `MediaFgColor`, `MediaBgColor`; dark variants in `[ListerDark]`                                                                                                              |
| Compare by contents       | Differences - text mode, Differences - text mode (selected), Differences - binary mode, Differences - binary mode (selected), Text with no differences, Text background (no differences), Text background (lines with differences), Selected lines: Text, Selected lines: Background, Search results (underline) | `[Colors]` `CompareText`, `CompareTextSel`, `CompareBinary`, `CompareBinarySel`, `CompareNormalText`, `CompareNormalBack`, `CompareDifferenceBack=-2` (-1 = as normal lines, -2 = slightly darker/lighter), `CompareSelText`, `CompareSelBack`, `CompareSearchLine`             |
| Title bar for file panels | Active side: Text, Active side: Background, Inactive Side: Text, Inactive Side: Background                                                                                                                                                                                                                       | `[Colors]` `ActiveTitleText`, `ActiveTitle`, `InactiveTitleText`, `InactiveTitle` (path bars; by default from the Windows caption colours)                                                                                                                                      |
| Synchronize directories   | Selection: Background                                                                                                                                                                                                                                                                                            | `[Colors] SyncSelBack`                                                                                                                                                                                                                                                          |
| Hint windows              | Text color, Background color, Border                                                                                                                                                                                                                                                                             | `[Colors]` `HintForeground`, `HintBackground`, `HintBorder`                                                                                                                                                                                                                     |
| Dark Mode                 | Text color, Background color, Highlight, Border, Horizontal lines                                                                                                                                                                                                                                                | `[ColorsDark]` `DarkForeground`, `DarkBackground`, `DarkHighlight` (active tab, buttons that stay down; a second highlight is used for the pressed button and borders), `DarkBorder` (list boxes, group boxes), `HorizontalLines` (between main menu, button bar and drive bar) |

Ini-only colour keys: `ThumbnailFrame=-1` (-2 = invisible), `TreeLineColor=-1` (-2 = invisible), `TreeTriangles=-1` (0 =
`[+]` boxes, 1 = triangles, -1 = TC decides), `ProgressBarBottom`, `ProgressBarTop`, `ActiveTabColor=-1`. Every
`[Colors]` key except the colour filters may be overridden in `[ColorsDark]`.

### 6.3 Define colors by file type

```text
┌ Define colors by file type ───────────────────────────────┐
│ File types (sort by drag&drop, edit with <spacebar>):     │
│ ┌──────────────────────────────┐   [ Add...       ]       │
│ │ (each entry drawn in its     │   [ Edit...      ]       │
│ │  colour)                     │   [ Delete       ]       │
│ │                              │   [ Dark<->Normal]       │
│ └──────────────────────────────┘   [ OK ] [ Cancel ]      │
└───────────────────────────────────────────────────────────┘
```

- **Add...** asks first for the file type in **"Specify file type"**, then for the colour; **Edit...** (or double click,
  or Space) edits the selected entry and its colour; **Delete** removes it. OK saves, Cancel discards.
- **Priority = list order:** the first matching entry decides the colour (a ZIP entry above a read-only entry gives a
  read-only ZIP the ZIP colour). Reorder by drag & drop.
- **Quick disable:** clicking the leading `*` of an entry such as `*.txt` turns it into `-.txt`, which disables it (a
  file literally named `-.txt` would still match).
- **Dark<->Normal** switches which colour set is edited. Normal colours are converted automatically to suitable dark
  colours, and each can be overridden.

```text
┌ Specify file type ──────────────────────────────────────────────────────┐
│ Specify file type, e.g. *.txt, or RegEx with leading '<', like <(a|b)   │
│ [                                                                    ▾] │
│ Or select predefined selection type:                                    │
│ ┌──────────────────────────────────────────────┐                        │
│ │ (saved search templates)                     │                        │
│ └──────────────────────────────────────────────┘                        │
│                                      [ Define... ] [ OK ] [ Cancel ]    │
└─────────────────────────────────────────────────────────────────────────┘
```

- Matching uses everything Num+ selection can match: wildcard masks, regular expressions written with a leading `<`, and
  predefined selection types (search templates, which can also test attributes, size, date and plugin fields; 18 › File
  masks and selection types).
- **Define...** opens **"Define selection"**: the Find Files dialog in template mode, with the pages General, Advanced,
  Plugins and Load/Save, the buttons [Save] [Cancel] [Help], and the _Search in_ field disabled (09 › Find Files).
- **Storage** in `[Colors]`: `ColorFilterN=` the type string, `ColorFilterNColor=` the colour, `ColorFilterNColorDark=`
  the dark colour, a comma, then the normal colour it was derived from (so that values changed by older versions can be
  detected). These keys cannot be overridden in `[ColorsDark]`.

_Basis: observed on Windows 11 and under Wine; help: dlg_configcolor, def_colors_by_file_type, dark___normal,
inisettings1, inisettings2, inisettings3._

---

## 7. Display › Tabstops/Data Formats

Column positions in Full view and the formats of sizes, dates and times (03 › Column header and sorting, 03 › Status
line).

```text
Show file extensions
 ( ) directly after filename        (o) aligned (with Tab)
Tabstops
 Extension: [176 ⇅]  Size: [234 ⇅]  Date/Time: [238 ⇅]  Attributes: [299 ⇅]
 Comments (fixed): [91 ⇅]                                          [Default]
Separators
 Date: [<default> ▾]  Time: [<default> ▾]  Thousands: [<default> ▾]  Decimal: [<default> ▾]
──────────────────────────────────────────────── (untitled group)
 [x] Adjust Tabs to window width
 [x] Show century in date (20xx)
 [ ] Use 12 hour AM/PM format
 [x] Show directory count in footer
 Size display:  [bytes  ▾]
 Header/footer: [kbytes ▾]
 Date format:   [<default> ▾]       time: [hh:mm ▾]
```

| Control                                                            | Default                                                         | Key                                                                                                                                                                                                                                                                                                                     | Meaning                                                                                                                                                                                                           |
| ------------------------------------------------------------------ | --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| directly after filename / aligned (with Tab)                       | aligned                                                         | `Aligned extension=1` (0 = directly after)                                                                                                                                                                                                                                                                              | `name.ext` as in Explorer, or the extension in its own left-aligned column at the Extension tabstop. The Extension tabstop can be edited only in aligned mode.                                                    |
| Tabstops: Extension, Size, Date/Time, Attributes, Comments (fixed) | 176, 234, 238, 299, 91 px (depends on DPI/font; see Appendix A) | res. `Tabstops=` in the order size, date/time, attributes, extension, window width, comments, size-minus-extension (the last used only when the extension follows the name directly); fallback `[Tabstops]` `0`=size, `1`=date/time, `2`=unused, `3`=attributes, `4`=extension, `5`=comment, `6`=reference window width | Column positions in pixels; the spin arrows nudge them. Dragging a separator in the column header changes the same values, but those are kept only after Configuration › Save Position.                           |
| Default                                                            | —                                                               | —                                                                                                                                                                                                                                                                                                                       | Restores the values of the first start                                                                                                                                                                            |
| Separators: Date, Time, Thousands, Decimal                         | `<default>` each                                                | `CustomSeparators=0000` (four characters in that order; `0` = from the Control Panel)                                                                                                                                                                                                                                   | Editable combos. Date: `<default>` · `/` · `-` · `.`; Time: `<default>` · `:` · `.`; Thousands: `<default>` · `,` · `.` · space; Decimal: `<default>` · `,` · `.`                                                 |
| Adjust Tabs to window width                                        | on                                                              | stored with the tabstops (window-width value in `Tabstops=`; `[Tabstops] AdjustWidth=1` in the fallback section)                                                                                                                                                                                                        | When the main window is resized, the name column changes width so that the extension, size, date and attribute columns stay right-aligned                                                                         |
| Show century in date (20xx)                                        | on                                                              | `ShowCentury=1`                                                                                                                                                                                                                                                                                                         | `2026` instead of `26`                                                                                                                                                                                            |
| Use 12 hour AM/PM format                                           | off                                                             | `ShowAMPM=0`                                                                                                                                                                                                                                                                                                            | Time followed by `a` or `p`; otherwise 24-hour                                                                                                                                                                    |
| Show directory count in footer                                     | on                                                              | `DirsInFooter=1`                                                                                                                                                                                                                                                                                                        | Adds the selected/total folder count to the footer, e.g. `5 / 7 dir(s)`                                                                                                                                           |
| Size display                                                       | bytes                                                           | `SizeStyle=0`                                                                                                                                                                                                                                                                                                           | Size format in the file lists (codes below)                                                                                                                                                                       |
| Header/footer                                                      | kbytes                                                          | `SizeFooter=1`                                                                                                                                                                                                                                                                                                          | The same list, for the free/total space above the panels, the selected/total footers and the copy-progress dialog (unless `SizeTransfer=` is set; its values 0 and 1 are ignored and mean automatic bytes/kbytes) |
| Date format                                                        | `<default>`                                                     | `CustomDateFormat=-1`: `-1` Control Panel, `0` MM/DD/YYYY, `1` DD/MM/YYYY, `2` YYYY/MM/DD                                                                                                                                                                                                                               | Order of day, month and year                                                                                                                                                                                      |
| time                                                               | hh:mm                                                           | `CustomTimeFormat=0` (1 = hh:mm:ss)                                                                                                                                                                                                                                                                                     | Seconds in the date column                                                                                                                                                                                        |

Size-display codes (both lists): `0` bytes · `1` kbytes (1 k = 1024 bytes) · `2` dynamic (x k/M/G) · `3` dynamic (x.x
k/M/G) · `4` dynamic (x k/M) · `5` dynamic (x.x k/M) · `6` dynamic (x k/M/G/T) · `7` dynamic (x.x k/M/G/T) · `8` dynamic
(x.xx k/M/G) · `9` dynamic (x.xx k/M/G/T). "Dynamic" picks the unit by size; the (x k/M) styles never use G, so files
over 1 GB stay in M. `SizeStyle1000=0` (ini only) uses binary units; `1` uses decimal units and overrides the "1 kbyte =
1024 bytes" rule. The thresholds at which the dynamic styles change unit are not documented.

_Basis: observed on Windows 11 and under Wine; help: dlg_configtabs, add_tabstopheader, inisettings1, inisettings2,
inisettings3._

---

## 8. Display › Folder Tabs

Options of the folder tabs above the panels (03 › Folder tabs).

```text
Folder tab headers
 [ ] Show tab header also when there is only one tab
 [ ] Tabs on multiple lines
 [ ] All tabs have same width
 [x] Limit tab title length to: [32] characters
 [x] Confirm close all tabs
 [x] Close tab on double click
 [ ] Ctrl+Up opens new tab in foreground
 [ ] Ctrl+Tab opens as list            [ ] Ctrl+Tab switches to last visited
 [ ] Open new tabs near current tab
 [x] Show locked tabs with an asterisk *
 [x] Activate target panel when clicking on one of its Tabs
 [ ] Always show drive letter in tab title
 [x] Show icons on tabs                                          [>>]
 [x] Return to locked tab root directory on tab change
 [x] Save displayed file types separately for each tab
```

Most checkboxes are bits of `DirTabOptions=824` (824 = 8 + 16 + 32 + 256 + 512).

| Control                                                | Default           | Key                                | Meaning                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------------------------------------ | ----------------- | ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Show tab header also when there is only one tab        | off               | `DirTabOptions` bit 1              | Header always visible; otherwise only with ≥ 2 tabs, and with one tab new tabs can only be opened with Ctrl+T or Ctrl+Up                                                                                                                                                                                                                                                                                                                                          |
| Tabs on multiple lines                                 | off               | bit 2                              | Tabs wrap into several rows; otherwise one row with two small scroll buttons                                                                                                                                                                                                                                                                                                                                                                                      |
| All tabs have same width                               | off               | bit 4                              | Fixed-width tabs ("like Mozilla")                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| Limit tab title length to: [n] characters              | on, 32            | bit 8; `DirTabLimit=32`            | Maximum number of characters shown on a tab                                                                                                                                                                                                                                                                                                                                                                                                                       |
| Confirm close all tabs                                 | on                | bit 16                             | Ask before _Close all tabs_                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| Close tab on double click                              | on                | bit 32                             | Double click closes a tab (in addition to the middle click)                                                                                                                                                                                                                                                                                                                                                                                                       |
| Ctrl+Up opens new tab in foreground                    | off               | bit 64                             | Ctrl+Up opens the folder under the cursor in a new tab; normally the current tab stays active, with this option the new tab is activated                                                                                                                                                                                                                                                                                                                          |
| Ctrl+Tab opens as list                                 | off               | `DirTabOpenList=0`                 | Ctrl+Tab works like Ctrl+Shift+A (list of open tabs)                                                                                                                                                                                                                                                                                                                                                                                                              |
| Ctrl+Tab switches to last visited                      | off               | `DirTabGotoLastVisited=0`          | Ctrl+Tab goes to the last visited tab; pressing Tab again with Ctrl held continues to the tabs right of the active one. The help describes this option as available only while _Ctrl+Tab opens as list_ is off, and a companion _Last visited first_ (`TabsListLastVisited`, last visited tabs at the top of the list) available only while it is on; the observed page, with the list option off, showed only _Ctrl+Tab switches to last visited_ in that place. |
| Open new tabs near current tab                         | off               | bit 128                            | New tabs are inserted right of the active tab instead of at the end                                                                                                                                                                                                                                                                                                                                                                                               |
| Show locked tabs with an asterisk *                    | on                | bit 256                            | `*` in front of locked tab titles                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| Activate target panel when clicking on one of its Tabs | on                | bit 512                            | Off: clicking a tab of the inactive panel switches that panel's tab but the other panel stays active                                                                                                                                                                                                                                                                                                                                                              |
| Always show drive letter in tab title                  | off               | bit 1024; `TabSeparator=:`         | Title becomes `c:windows`; FTP tabs show the connection number (`0:tmp`), and `#` for a connection not reconnected after a restart                                                                                                                                                                                                                                                                                                                                |
| Show icons on tabs + [>>]                              | on, all six types | `DirTabIcons=255` (bit sum, below) | Icons on tabs for the folder types chosen in the `>>` dialog                                                                                                                                                                                                                                                                                                                                                                                                      |
| Return to locked tab root directory on tab change      | on                | `DirTabRevert=1`                   | A tab "locked, but directory changes allowed" returns to its saved directory when another tab is selected; otherwise only a click on the already active tab, the `\` button or Ctrl+\\ returns. A `!` before the title marks such a tab whose directory differs.                                                                                                                                                                                                  |
| Save displayed file types separately for each tab      | on                | `DirTabFilters=1`                  | The _Show › Custom_ display filter is kept per tab; otherwise per panel, as before TC 10.00                                                                                                                                                                                                                                                                                                                                                                       |

**"Folder Tab Icons"** (the `>>` button):

```text
Show icons on tabs
 [x] For local drives
 [x] Icons defined via folder properties
 [x] For virtual folders (e.g. Network Neighborhood)
 [x] For file system plugins
 [x] For FTP connections
 [x] User-defined icons (view modes)
                                   [ OK ] [ Cancel ]
```

`DirTabIcons` bits: `1` enable (the main checkbox), `2` drive icon in the root of non-network drives, `4` folders with
`desktop.ini` (only if the folder has the read-only or system attribute), `8` virtual folders such as the Desktop, `16`
file-system plugins, `32` FTP, `64` icons from view modes (§10), `128` reserved.

Ini-only tab keys (behaviour in 03 › Folder tabs): `LockedTabChange=1`, `LockedGoToDriveRoot=0`, `TabEnterDirChange=1`,
`TabFullColor=0`, `TabSwitchMode=0`, `TabDir=`, `[Colors] ActiveTabColor=-1`, `QuickSearchTabsAutoFilter=0`.

_Basis: observed on Windows 11 and under Wine; help: dlg_configfoldertabs, foldertabs, inisettings1, inisettings2,
inisettings3._

---

## 9. Display › Custom columns

User-defined column sets for the Full-style view (03 › Custom columns).

```text
Configure columns for file system: [<General> ▾]
Custom column configurations (sort with drag&drop):
┌──────────────────────────────────────┐   [ New    ]
│ (empty by default)                   │   [ Edit   ]
│                                      │   [ Delete ]
└──────────────────────────────────────┘   [ Copy   ]
```

| Control                           | Default     | Meaning                                                                                                                                                                                                 |
| --------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Configure columns for file system | `<General>` | `<General>` = the normal file system; one further entry per installed file-system plugin that supports custom columns (e.g. registry values, Linux permissions; the plugin may need an update for this) |
| Custom column configurations      | empty       | Up to **29** views; reorder by drag & drop                                                                                                                                                              |
| New                               | —           | Creates a view and opens the editor                                                                                                                                                                     |
| Edit                              | —           | Opens the editor for the selected view                                                                                                                                                                  |
| Delete                            | —           | Deletes the selected view; the deletion is saved **only after Apply or OK**                                                                                                                             |
| Copy                              | —           | Duplicates the selected view and opens the editor on the copy                                                                                                                                           |

**"Custom Columns" editor** (New / Edit / Copy; also `cm_CustomColumnDlg` for the current view):

```text
Configure view nr:  1            Name: [                          ]
Caption       Width    Align   Field contents
[Name ]       [80 ⇅]   [← ▾]   [Name                     ] [+]   ← fixed row, disabled
[Ext  ]       [30 ⇅]   [← ▾]   [Ext                      ] [+]   ← fixed row; width 0 hides it
[     ]       [80 ⇅]   [← ▾]   [                         ] [+]   ← rows added with "Add column"
[ Add column ] [ Delete active column ]
[ ] Adjust Tabs to window width        [ ] Horizontal scrollbar
                                          [ OK ] [ Cancel ] [ Apply ]
```

| Element                                    | Rule                                                                                                                                                                        |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Configure view nr                          | Which of the 29 views is edited                                                                                                                                             |
| Name                                       | Title in menus. **If empty, the view is not listed in menus**, but `cm_SrcCustomView<n>` (button or hotkey) still reaches it.                                               |
| Caption                                    | Header text of the column                                                                                                                                                   |
| Width                                      | In **dialog units**, so it depends on the large/small font mode                                                                                                             |
| Align                                      | `←` left (text) or `→` right (numbers)                                                                                                                                      |
| Field contents                             | Any mix of literal text and field references `[=plugin.field.unit]` (18 › Content fields). `[+]` opens _Choose plugin property_ (15 › The _Choose plugin property_ dialog). |
| Up/down arrows                             | Appear while the cursor is in a column row and move that column; Ctrl+PgUp / Ctrl+PgDn do the same                                                                          |
| Add column                                 | Appends a column at the end                                                                                                                                                 |
| Delete active column                       | Deletes the column holding the cursor; disabled until a custom row has the focus                                                                                            |
| Adjust Tabs to window width                | The name column resizes with the main window, as in Full view (§7)                                                                                                          |
| Horizontal scrollbar                       | A scrollbar when the columns need more than the panel width                                                                                                                 |
| Switch to this view when using this plugin | Shown only for a plugin's column sets: switches to the view automatically on entering that file-system plugin (`AutoLoad=1`)                                                |

**Storage:** `[CustomFields]` `Titles=` (view names separated by `|`), `Headers<n>=` and `Contents<n>=` (columns
separated by the literal text `\n`), `Widths<n>=` (negative = right-aligned), `Options<n>=` (window width for
auto-sizing `|` 1 = horizontal scrollbar `|` screen DPI). Plugin sets use `[CustomFields_<PluginName>]` with the same
keys plus `AutoLoad=`; the plugin's own fields are written `[=<fs>.field]`.

_Basis: observed under Wine; help: dlg_configcustomcolumns, dialog_usercolumns, inisettings3._

---

## 10. Display › View Mode

Named presets of view, sort order, colours, tab icon and commands, applied to a tab manually or by Auto Switch Mode (03
› View modes, 03 › Auto Switch Mode).

```text
View Modes
┌──────────────────────────────┐   [ Add...          ]
│ <default>                    │   [ Delete...       ]
│                              │   [ Change Title... ]
└──────────────────────────────┘   [ ^ ] [ v ]
Columns view:            [Unchanged      ▾]
Sort order:              [Unchanged      ▾]   [ ] Descending
Additional sort orders:  [                    ] [+]
Tab color and icon:      [default ▾] [>>]   [icon] [>>]
Background:              [default ▾] [>>]   [ ] Priority
Background 2:            [default ▾] [>>]
Auto-run commands:       [                    ] [+]
```

| Control                      | Default          | Meaning                                                                                                                                                                                                     |
| ---------------------------- | ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| View Modes list              | `<default>` only | `<default>` is applied whenever no Auto Switch rule matches; it has no colours or icons (`cm_SrcViewMode0`)                                                                                                 |
| Add...                       | —                | Asks "Add new view mode" in a box titled "Total Commander" (`[edit] [OK] [Cancel]`) for a name, e.g. "Photos"                                                                                               |
| Delete...                    | —                | Deletes the selected mode; disabled for `<default>`                                                                                                                                                         |
| Change Title...              | —                | Renames the selected mode                                                                                                                                                                                   |
| ^ / v                        | —                | Reorder the modes                                                                                                                                                                                           |
| Columns view                 | Unchanged        | Unchanged · Brief · Full · Comments · Thumbnail View · ──── · the custom column sets (§9)                                                                                                                   |
| Sort order + Descending      | Unchanged, off   | Unchanged · Name · Ext · Size · Date · Unsorted; Descending = newest/largest first                                                                                                                          |
| Additional sort orders `[+]` | empty            | Further sort keys, e.g. extension, then size                                                                                                                                                                |
| Tab color and icon           | default; no icon | Colour and icon of the folder tab; disabled for `<default>`                                                                                                                                                 |
| Background / Background 2    | default          | Panel background and the colour of every other line, e.g. to mark FTP or plugin panels. The help advises a colour only slightly different from the normal one. Set **separately for normal and dark mode.** |
| Priority                     | off              | Gives this mode's **icon** priority over icons from other sources, e.g. `desktop.ini` or the drive icon in a root directory                                                                                 |
| Auto-run commands `[+]`      | empty            | `cm_` and `em_` commands run when the mode changes (grammar below)                                                                                                                                          |

**Auto-run grammar:**

```text
field     := enterList [ "|" leaveList ]
enterList := [flag] command { "," command }
flag      := "-"   do not run when the mode is entered by switching tabs; only on directory changes within a tab
           | "*"   run on every directory change into AND within this mode
                   (without "*": only when switching from a different mode to this one)
leaveList := commands run when the mode is left
```

Example: `cm_100percent|cm_50percent` widens the active panel to the full window when the mode (e.g. a thumbnails mode)
becomes active and restores 50:50 when it is left. Whether each command can carry its own flag is not documented. The
evaluation on a mode change is in 03 › View modes.

**Storage:** `[ViewModes]` `x_name=`, `x_icon=`, `x_options=` (view, sort order, reversed, additional sort orders, tab
colour, background, background 2), `x_commands=`. Per-panel colours: `[left]`/`[right]` `ActivePanelColor`,
`ActivePanelColor2`, `ActivePanelColorDark`, `ActivePanelColorDark2` (-1 = none). Applying a mode: _Show › Custom view
modes_ (`cm_SrcViewModeList`), the tab context menu, `cm_SrcViewMode<n>` (8501…), `[left] ViewMode=`.

_Basis: observed on Windows 11 and under Wine; help: dlg_configviewmode, show_customviewmodes, inisettings3._

---

## 11. Display › View Mode › Auto Switch Mode

Rules that pick a view mode after every directory change (03 › View modes, 03 › Auto Switch Mode).

```text
[ ] Automatically switch view mode on directory change
Rules
┌──────────────────────────────┐   [ Add...    ]
│ (rules)                      │   [ Delete... ]
└──────────────────────────────┘   [ ^ ] [ v ]
Rule:                     Directory:              File types:
[+: Must match        ▾]  [                ] [>>] [                    ]
[ More sub-rules ] [ Fewer sub-rules ]
Set this mode: [<default> ▾]
```

| Control                                            | Default         | Key                                                        | Meaning                                                                                                                                                                                                                                                             |
| -------------------------------------------------- | --------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Automatically switch view mode on directory change | off             | `[ViewModeSwitch] Enabled=`; `cm_ToggleAutoViewModeSwitch` | Master switch. It becomes **checked automatically when a rule is added.**                                                                                                                                                                                           |
| Rules list + Add... / Delete... / ^ v              | empty           | `[ViewModeSwitch] x_rules=`, `x_mode=`                     | After each directory change the rules are tested **in list order**; the first matching rule sets its mode, otherwise `<default>` is set                                                                                                                             |
| Rule (per sub-row)                                 | `+: Must match` | —                                                          | Match type and folder type (tables below). Sub-rules are combined with `&` (AND) and `\|` (OR); AND binds tighter: `A & B \| C & D` = (A AND B) OR (C AND D). Stored joined with `\|&` (AND) and `\|\|` (OR).                                                       |
| Directory + [>>]                                   | empty           | —                                                          | Pattern compared with the current directory; wildcards anywhere; a **trailing `*`** also matches all subfolders (`c:\photos\` only that folder; `c:\photos\*` it and all below; `c:\photos\*2016*\*` folders below it containing `2016`, and everything below them) |
| File types                                         | empty           | —                                                          | Masks separated by spaces; masks after `\|` are exclusions, e.g. `*.doc *.docx *.xlsx`, `a*.* \| *.bak *.org *.~*`                                                                                                                                                  |
| More sub-rules / Fewer sub-rules                   | —               | —                                                          | Add a row / remove the **bottom** row                                                                                                                                                                                                                               |
| Set this mode                                      | `<default>`     | `x_mode=`                                                  | `<default>` or a user view mode (§10)                                                                                                                                                                                                                               |

**Rule types** (the _Rule_ combo offers them in this order):

| Entry                   | Meaning                                                                                                                                               |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `+: Must match`         | The directory matches **and all** file names match the file types                                                                                     |
| `-: Must not match`     | The directory matches **and no** file name matches                                                                                                    |
| `%: At least 50% match` | **At least half** of the file names match (e.g. "50 % pictures")                                                                                      |
| `?: At least one match` | **At least one** file name matches                                                                                                                    |
| `D: Directory`          | A directory `c:\dir` or `\\server\share`                                                                                                              |
| `L: With drive letter`  | A directory with a drive letter; the edit box may hold drive-type digits: 1 removable hard disk, 2 USB stick, 3 fixed, 4 remote, 5 CD-ROM, 6 RAM disk |
| `U: UNC path: \\Server` | A UNC path `\\server\share`                                                                                                                           |
| `V: Virtual folder`     | A virtual folder such as the Desktop                                                                                                                  |
| `F: FTP connection`     | An FTP connection (Ctrl+F / Ctrl+N)                                                                                                                   |
| `A: Archive`            | Inside an archive, e.g. `c:\dir\file.zip`                                                                                                             |
| `P: File System Plugin` | Inside a file-system plugin, e.g. `\\\Secure FTP\connection`                                                                                          |
| `S: Search result`      | A _Feed to listbox_ search result                                                                                                                     |

- A **manual override** survives: when the user picks a mode by hand while auto-switching is on, it is kept as long as
  the automatic result stays the same (`ViewMode=` / `AutoViewMode=` in `[left]`/`[right]`; 03 › View modes).
- **Leaving the page with an incomplete rule** is refused (§1.2).
- Not documented: whether subfolders count as "file names", and how a rule with an empty file-types list behaves.

_Basis: observed under Wine; help: dlg_configautomodeswitch, dlg_configviewmode, inisettings3._

---

## 12. Display › Language

Language of the user interface and the main-menu file (16 › Switching the language).

```text
Change the language/ Sprache wechseln/ Changer de langue
┌──────────────────────────────────────────────────────┐
│ English                                              │
│ Čeština (Czech) (WCMD_CZ.LNG)                        │
│ …                                                    │
└──────────────────────────────────────────────────────┘
Main menu file: [                          ] [>>] [Edit]
[Download]
```

- **List:** entries `<native name> (<file>)`, built from the `LANGUAGE\WCMD_*.LNG` files of the program directory.
  **English is built into `totalcmd.exe`** and comes first (selected by default). The 11.58 package lists: English;
  Čeština (Czech) (WCMD_CZ.LNG); Dansk (WCMD_DAN.LNG); Deutsch (WCMD_DEU.LNG); Español (tradicional) (WCMD_ESP.LNG);
  Français (WCMD_FRA.LNG); Italiano (WCMD_ITA.LNG); Korean (한국어 for 10.0) (WCMD_KOR.LNG); Magyar (tegezős)
  (WCMD_HUN.LNG); Nederlands (WCMD_DUT.LNG); Norsk (Bokmål) (WCMD_NOR.LNG); Polski (WCMD_POL.LNG); Română - by Eugen
  ANTAL - ver. 11.58 (WCMD_ROM.LNG); Russian (Русский) (WCMD_RUS.LNG); Slovenski (Slovenian) (WCMD_SVN.LNG); Slovenský
  (Slovak) (WCMD_SK.LNG); Svenska (WCMD_SWE.LNG); Ukrainian (Українська) (WCMD_UKR.LNG); 简体中文 (Simplified Chinese)
  (WCMD_CHN.LNG).

| Control               | Default                       | Key                                                            | Meaning                                                                                                                                                                                                        |
| --------------------- | ----------------------------- | -------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language list         | English                       | `LanguageINI=` (e.g. `WCMD_DEU.LNG`; empty = built-in English) | Each other language is a pair `WCMD_xxx.LNG` (dialogs, messages, buttons) + `WCMD_xxx.MNU` (main menu). Choosing a language **selects the matching .MNU automatically**. Unused language files may be deleted. |
| Main menu file + [>>] | empty                         | `Mainmenu=` (path)                                             | Empty = the built-in default menu. `>>` browses for a `.MNU` file (format: 14 › Main-menu files).                                                                                                              |
| Edit                  | disabled while no file is set | —                                                              | Opens the menu file in Notepad                                                                                                                                                                                 |
| Download              | —                             | —                                                              | Opens the web page with additional languages in the default browser                                                                                                                                            |

Related: `OPENLANGUAGEFILE wcmd_deu.lng` switches the language by command (no parameter = internal English);
`OPENLANGUAGEFILE WCMD_xyz.MNU` changes only the menu, `OPENLANGUAGEFILE .MNU` restores the internal menu.
`TranslateMessageButtons=1` shows the buttons of standard Windows message boxes in the TC language (0 = system language;
always translated in dark mode). A language may bring its own user commands in `wcmd_<lang>.ini` (14 › User commands).
Details: 16.

_Basis: observed under Wine; help: dlg_configlanguage, inisettings1, inisettings2; history._

---

## 13. Operation

General program behaviour: instances, mouse, selection, saving on exit, folder sizes and file comments.

```text
Main program
 [ ] Allow only 1 copy of Total Commander at a time
 [ ] Move icon to system tray when minimized
 [ ] Always go to the root of a drive when changing drives
 [ ] Open files and directories with a single click
 [ ] Select only the file name when renaming (not the extension)
 [x] Auto-complete paths                  [x] Auto-append suggested name
 [ ] Check for updates                    [x] Extra lines below cursor: [4]
Mouse selection mode
 (o) Use right mouse button (as in NC) - context menu after 1 second
 ( ) Left mouse button (Windows standard)        [x] Rubber band selection
 [x] By clicking on icon                          [ ] Only on touchscreen
Selection (with Num + )
 ( ) Select files only     (o) Also select directories
Save on exit
 [x] Directories  [x] Panels (brief/full, etc.)  [x] Old command lines  [Directory history]
NTFS daylight saving correction
 [ ] Ignore 1 hour time delay
Calculate space occupied by subdirectories
 [x] when selecting with the space bar           [ ] 'Everything'
 [x] before copying/deleting                     [Manual: Alt+Shift+Enter ▾]
File comments
 Preferred type: [Plain text+UTF16 ▾]            [ ] DOS charset
 [ ] Copy comments with files                    [x] Read from both
```

_Rubber band selection_ is enabled only in left-button mode.

### 13.1 Main program

| Control                                                     | Default | Key                                                                                                              | Meaning                                                                                                                                                                                                                                                                                                                                                                      |
| ----------------------------------------------------------- | ------- | ---------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Allow only 1 copy of Total Commander at a time              | off     | `OnlyOnce=0`                                                                                                     | Starting another copy (desktop, Start menu, taskbar) activates the running one. Ini values: `1` one instance per user; `-1` one per computer, across users; `x>0` up to x per user; `x<0` up to \|x\| per computer. Overridden by the `/O` and `/N` switches (19 › Command-line switches).                                                                                   |
| Move icon to system tray when minimized                     | off     | `TrayIcon=0`; `AltTabWindow=1`                                                                                   | When minimized, the taskbar button is replaced by a tray icon; clicking it restores TC. Alt+Tab still works through an invisible helper window; on NT-based Windows Enter must be pressed after releasing Alt.                                                                                                                                                               |
| Always go to the root of a drive when changing drives       | off     | `AlwaysToRoot=0`                                                                                                 | Off: changing to a drive goes to the **last directory used on that drive**; on: always to its root                                                                                                                                                                                                                                                                           |
| Open files and directories with a single click              | off     | `SingleClickStart=0`                                                                                             | Web style. Ini values: `1` single click opens files and folders; `2` single click opens folders only; add `4` so the text cursor no longer follows the mouse                                                                                                                                                                                                                 |
| Select only the file name when renaming (not the extension) | off     | `RenameSelOnlyName=0`                                                                                            | Initial selection in in-place rename (Shift+F6): the name without extension, or the whole name. **Pressing Shift+F6 again toggles between the two.** The same applies to copying within the same folder (Shift+F5).                                                                                                                                                          |
| Auto-complete paths                                         | on      | `AutoComplete=3`, bit 1                                                                                          | While a **full** path (drive letter or `\\server`) is typed, matching paths are offered in a drop-down list                                                                                                                                                                                                                                                                  |
| Auto-append suggested name                                  | on      | `AutoComplete` bit 2                                                                                             | The first match is appended, selected, in the edit box; Up/Down cycle through the matches, Right accepts. With `AutoCompleteTab` set, Tab cycles and Ctrl+Space accepts. `AutoCompleteTab=0`: `0` Tab moves to the file list; `1` Tab takes the next completion, or acts like 0 when nothing completes; `2` takes the next completion and is ignored when nothing completes. |
| Check for updates                                           | off     | `AutoUpdateCheck=0` (`1` releases and betas, `2` releases only); `AutoUpdateCheckBeta=0`                         | Periodic update check. In a beta build, new betas are reported too; `AutoUpdateCheckBeta=1` reports betas even when running a release. Disabled by `RestrictInterface` bit 1024.                                                                                                                                                                                             |
| Extra lines below cursor: [n]                               | on, 4   | `ScrollingTopMargin=4`, `ScrollingBottomMargin=4`, `ScrollingMarginFlags=3` (1 = vertical lists, 2 = Brief view) | When moving with the keyboard, n lines stay visible beyond the cursor (below and above). One value sets both margins; the ini keys allow different values. How the unticked checkbox is stored is not documented.                                                                                                                                                            |

### 13.2 Mouse selection mode

| Control                                                         | Default                        | Key                        | Meaning                                                                                                                                                                                                                                                                        |
| --------------------------------------------------------------- | ------------------------------ | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Use right mouse button (as in NC) - context menu after 1 second | selected                       | `UseRightButton=1`         | Norton style: hold the right button and drag to select; holding it opens the context menu. The caption and the help say about 1 s; the ini default `PopupDelay=500` ms is the delay until the menu appears. `ContextProgress=1` shows a progress bar while the button is held. |
| Left mouse button (Windows standard)                            | —                              | `UseRightButton=0`         | Explorer style (05 › Mouse selection modes)                                                                                                                                                                                                                                    |
| └ Rubber band selection                                         | on (enabled only in left mode) | `UseRubberBandSelection=1` | Pressing **behind** a name and dragging draws a rectangle that selects everything it touches; files must then be dragged **by their names**                                                                                                                                    |
| By clicking on icon                                             | on                             | `IconClickSelection=1`     | A click on the icon toggles that item's selection                                                                                                                                                                                                                              |
| └ Only on touchscreen                                           | off                            | `IconClickSelection=2`     | Icon-click selection only for touch input, not the mouse                                                                                                                                                                                                                       |

### 13.3 Selection (with Num +)

| Control                                     | Default                 | Key                                  | Meaning                                                                               |
| ------------------------------------------- | ----------------------- | ------------------------------------ | ------------------------------------------------------------------------------------- |
| Select files only / Also select directories | Also select directories | `MarkDirectories=1` (0 = files only) | Whether **Num +**, **Ctrl+Num +** and **Num \*** also select folders (03 › Selection) |

### 13.4 Save on exit

| Control                   | Default | Key                                    | What is saved when TC closes                                                                                                                                               |
| ------------------------- | ------- | -------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Directories               | on      | `Savepath=1`                           | Both panel paths, plus the folder tabs when tabs are enabled                                                                                                               |
| Panels (brief/full, etc.) | on      | `Savepanels=1`                         | Per panel: view (Brief / Full / Tree …), file filter (All / Programs / Custom) and sort order. When off, the last saved settings (or the defaults) are loaded at start-up. |
| Old command lines         | on      | `SaveCommands=1`; `OldCmdLineCount=20` | The command-line history, in `[Command line history]`                                                                                                                      |
| [Directory history]       | —       | —                                      | Jumps to the History page (§23), where the directory-history options now live                                                                                              |

`cm_Exit` with parameter `4` saves directories, tabs and panels even when these options are off. Virtual folders survive
in a saved history only if they can be written as a unique `::{…}` string.

### 13.5 NTFS daylight saving correction

| Control                  | Default | Key          | Meaning                                                                                                                                                                                                                                                                                              |
| ------------------------ | ------- | ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ignore 1 hour time delay | off     | `1hourdif=0` | FAT stores local time, NTFS stores UTC; when daylight saving starts or ends, NTFS times shown in local time move by one hour while FAT times do not. With this option every compare function, including _Synchronize dirs_ (09), treats two timestamps that differ by **exactly one hour** as equal. |

### 13.6 Calculate space occupied by subdirectories

| Control                           | Default                 | Key                                                                                                                                                                                                                                                      | Meaning                                                                                                                                              |
| --------------------------------- | ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| when selecting with the space bar | on                      | `CountSpace=1`                                                                                                                                                                                                                                           | Selecting a folder with Space sums everything inside it; the sum replaces `<DIR>` in Full view                                                       |
| 'Everything'                      | off                     | `Everythingforsize=0`                                                                                                                                                                                                                                    | Takes folder sizes from the external _Everything_ indexer (version 1.4.1 or later, with folder-size indexing on); used for Space and Alt+Shift+Enter |
| before copying/deleting           | on                      | `CountMarked=1`                                                                                                                                                                                                                                          | Counts the whole selection first, so that a second (overall) progress bar can be shown (07 › Progress window and job sequence)                       |
| Drop-down                         | Manual: Alt+Shift+Enter | `GetDirSize=0`: `0` Manual: Alt+Shift+Enter; `1` Automatic, local drives only (uses Everything when enabled); `2` Automatic, also on network; `3` Automatic, only with 'Everything' (does nothing if Everything is missing or does not index that drive) | When the sizes of displayed subfolders are calculated                                                                                                |

Items on the ignore list (§22) are left out of every size count.

### 13.7 File comments

| Control                  | Default          | Key                                                               | Meaning                                                                                                                                                                                                                                                                                                                                                                              |
| ------------------------ | ---------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Preferred type           | Plain text+UTF16 | `CommentPreferredFormat=4`; `CopyComments` type bit (table below) | Format of new comments (07 › File comments (Ctrl+Z)). The list is headed "descript.ion:". `descript.ion` handles long names and Unicode and supports multi-line comments only through a TC-specific extension approved by the 4DOS authors; `files.bbs` works with 8.3 names only but supports multi-line comments natively. The help recommends `descript.ion` unless a BBS is run. |
| DOS charset              | off              | `CopyComments` bit 16; also `CmtOemFont=0`                        | Affects `descript.ion` only: accented characters written in the OEM code page, as 4DOS/4NT expect; otherwise the Windows code page, which programs such as ACDSee expect. **files.bbs always uses the DOS charset.**                                                                                                                                                                 |
| Copy comments with files | off              | `CopyComments` bit 8                                              | When files (and subfolders) are copied, their comment lines are copied into the target's comment file. The comment files themselves are then **not** copied when the target already has one, so they are not overwritten.                                                                                                                                                            |
| Read from both           | on               | `CopyComments` bit 4                                              | If no comment file of the preferred type exists in a folder, the other type is read. A comment taken from the other type is converted to the **preferred** format when its file is copied.                                                                                                                                                                                           |

| List entry           | `CommentPreferredFormat`                                                 | `CopyComments` type bit |
| -------------------- | ------------------------------------------------------------------------ | ----------------------- |
| Plain text           | 0 (ANSI or OEM; no Unicode comments)                                     | 2                       |
| Unicode UTF16        | 1 (UTF-16 LE, always)                                                    | 2                       |
| Unicode UTF16 Mac    | 2 (UTF-16 BE, always)                                                    | 2                       |
| Unicode UTF8         | 3 (always)                                                               | 2                       |
| Plain text+UTF16     | 4 (plain text; UTF-16 LE only when a name or comment needs it) — default | 2                       |
| Plain text+UTF16 Mac | 5 (plain text, otherwise UTF-16 BE)                                      | 2                       |
| Plain text+UTF8      | 6 (plain text, otherwise UTF-8)                                          | 2                       |
| files.bbs (DOS)      | —                                                                        | 1                       |

`CopyComments=6` is a bit sum: `1` preferred type files.bbs, `2` preferred type descript.ion (wins when both are set),
`4` read from both, `8` copy comments with files, `16` DOS charset for descript.ion.

_Basis: observed on Windows 11 and under Wine; help: dlg_config2, inisettings1, inisettings2._

---

## 14. Operation › Edit/View

Viewer for F3, editor for F4 and temporary-file re-upload (10 › Entry points for viewing and editing; 10 › Edit (F4)).

```text
Viewer for F3
 [Configure internal viewer...]
 External viewer: [none                    ] [>>]
 [Associations...]
 Hotkeys:
   Internal Viewer with file under cursor   [Shift+F3 ▾]
   Internal Viewer with selected files       F3
   External viewer                           Alt+F3
Editor for F4
 Editor: [notepad.exe                      ] [>>]
──────────────────────────────────────────────── (separate group)
 [ ] Plugins/FTP: Automatically re-upload changed files
```

### 14.1 Controls

| Control                                            | Default        | Key                                                                                  | Meaning                                                                                                                                                                                                                                                                                                                                      |
| -------------------------------------------------- | -------------- | ------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Configure internal viewer...                       | —              | —                                                                                    | Opens **"Configure Lister"** (§14.3); also `cm_ConfigLister`                                                                                                                                                                                                                                                                                 |
| External viewer + [>>]                             | `none`         | `Viewer=none`                                                                        | Program used by the external-viewer action when the extension has no viewer association; `none` or empty = the internal viewer                                                                                                                                                                                                               |
| Associations...                                    | —              | `[Extensions]`                                                                       | Per-extension viewers, edited in the **"Associate"** dialog (§14.2) but saved in `wincmd.ini`, not the registry                                                                                                                                                                                                                              |
| Hotkeys: Internal Viewer with file under cursor    | Shift+F3       | `Viewertype=1`                                                                       | Combo: which key opens Lister with only the file under the cursor (the list values were not recorded). The two other rows are labels showing the resulting keys.                                                                                                                                                                             |
| Internal Viewer with selected files                | F3 (label)     | `Viewertype`                                                                         | Lister with every selected file; **N** and **P** step through them                                                                                                                                                                                                                                                                           |
| External viewer                                    | Alt+F3 (label) | —                                                                                    | The external viewer action                                                                                                                                                                                                                                                                                                                   |
| Editor + [>>]                                      | `notepad.exe`  | `Editor=notepad.exe`                                                                 | Program for F4; `>>` browses                                                                                                                                                                                                                                                                                                                 |
| Plugins/FTP: Automatically re-upload changed files | off            | `AutoReUpload=1` (ini default; the dialog writes `2` when ticked, `0` when unticked) | Temporary copies of files from FTP or file-system plugins viewed with F3 or edited with F4: ticked = re-uploaded **every time the file is saved**, without closing the editor; unticked = re-uploaded only after the editor closes and only if the user confirms (TC ≤ 8.0x behaviour); `1` = ask on the first re-upload which method to use |

- **`Viewertype`** stores the F3 behaviour: `0` internal, file under cursor; `1` internal, selected files (default); `2`
  external. Whichever internal method F3 uses, the other stays available on Shift+F3. The **F3** button of the
  function-key bar follows the same setting. Alt+Shift+F3 always opens the internal Lister without plugins or
  multimedia.
- **External viewer resolution** (Alt+F3 by default):

```text
viewExternal(file):
  if [Extensions] has an entry for the file's extension: run that program with the file
  elif Viewer= is set and not "none":                    run Viewer with the file
  elif a Windows Quick View handler exists:              use Windows Quick View
  else:                                                  open the internal Lister
```

- **How F4 passes the name**, depending on the Editor field: `"%1"` = long name, always quoted; `%1` = 8.3 name if one
  exists, otherwise the long name, quoted when it contains a space; no `%1` = appended — on NT-based Windows the long
  name, quoted only if it contains a space (on 9x/ME the 8.3 name).
- `[Lister] Editor=` can set a different editor for F4 pressed **inside Lister**; empty = `[Configuration] Editor=`.
- `EditWaitTime=2` (ini only): if the editor of a temporary file ends within this many seconds, TC assumes a
  multi-document editor that handed the file to an existing instance, and shows a dialog in which the user confirms when
  editing has finished; `0` turns this check off, `-1` never shows the dialog (e.g. when the file was passed by DDE).

### 14.2 "Associate" dialog (Associations...)

```text
All files with extension (ending with): [            ▾]
Associate with: [                                    ]
┌──────────────────────────────────────┐
│ (none)                               │
│ (registered file types)              │
└──────────────────────────────────────┘
[ New type... ] [ Delete ]          [ OK ] [ Cancel ] [ Help ]
```

The same layout as Files › Associate With… (10 › Associations), but the result is written to `wincmd.ini` `[Extensions]`
as `ext=program [params]`, e.g. `bat=c:\windows\notepad.exe ^.bat`; the trailing `^.ext` is optional and `"%1"` may be
used instead. The _Edit type_ function of that dialog is not available for viewer associations.

### 14.3 "Configure Lister" dialog

Tabs **General / Multimedia / Player**, buttons `[OK] [Cancel] [Help]`; all keys in `[Lister]`. The full layout,
defaults and option-to-key table are in 10 › Configure Lister. In brief:

- **General:** _Display at startup_ and _Font at startup_ (Text / Binary / Hex / Autodetect; ANSI / ASCII / Variable /
  Autodetect, both Autodetect by default; `Startup`), the three fonts (`Font1`–`Font3`), _Use old non-scalable default
  fonts_, _Display width (characters per line)_ Text 81 / Binary 75 (`TextWidth`, `binwidth`; one help topic says 80 /
  74), _Search result: Lines from top of list_ 3 (`SearchGoBack`).
- **Multimedia:** start-up detection switches (plugins/bitmaps, multimedia, RTF, HTML as text, link braces, Explorer
  preview handlers, thumbnail providers), the Irfanview/XnView path (also used by the thumbnail loader, §20, even when
  its checkbox is off), **LS-Plugins** (the "Lister plugins" dialog, §19) and **Define view method by file type...**
  ("Lister: view methods by file type": "File types (sort by drag&drop, edit with \<spacebar\>):" list,
  `[Add...] [Edit...] [Delete] [OK] [Cancel]`; Add opens "Specify file type", §6.3). One method for an extension = F3
  uses it; two or more = key **4** in Lister cycles through only those; none = 4 cycles through every plugin that
  accepts the file.
- **Player** ("Internal Media Player"): `( ) Use default system filters` · `(o) Recommended filters (LAV, ffdshow)` ·
  `( ) Old Video for Windows player` · `( ) User defined:` `[Download filters...]`; _Source filters_ list, observed with
  `(not installed) {B98D13E7-55DB-4385-A33D-09FD1BA26338}`, and _Decoder filters (audio/video)_ list with
  `(not installed) {EE30215D-164F-4A92-A4EB-9D4C13390F9F}` and `(not installed) {E8E73B6B-4CB3-44A4-BE99-4F7BCB96E491}`,
  each with `[Add] [Remove]` (`PreloadFilterType32/64`, `PreloadInputFilters32/64`, `PreloadFilters32/64`; 10 › Media
  player mode).

_Basis: observed on Windows 11 (Edit/View) and under Wine (Configure Lister and its sub-dialogs); help: dlg_configedit,
dlg_listerconfig, dlg_assotiate, inisettings1, inisettings2, inisettings3; KEYBOARD.TXT._

---

## 15. Operation › Copy/Delete

Copy method and general copy and delete options (07 › Copy (F5) and its variants, 07 › Delete (F8, Del, Shift+F8)).

```text
 [x] Use standard copy method (recommended)
Copy method (for experts only!)                    (disabled while the box above is ticked)
 (o) Use default method only (reliable, not very fast)
     Buffer sizes for small files:  Source+Target on same disk: [32] k   on different disks: [32] k
 ( ) Also use big file copy mode (not using cache)
     Buffer sizes for big files:    same disk: [10240] k   different disks: [64] k
 The following drive letters are on the same physical harddisk (example: CDE,FGH ): [CY]
 [ ] Use compatibility mode for the following drives: [      ]  Enter drive letters, e.g. CDEF, or *
                                                                  [x] USB sticks
 ( ) Use copy+paste via Explorer (only in case of copy problems)
General Copy+Delete options
 [ ] Copy date/time of directories
 [ ] Verify after copy (MD5/BLAKE3 checksum)
 [ ] Use Explorer delete method (faster, cannot handle comments)
 [x] F8/Del deletes to recycle bin (Shift=directly)
```

The same-disk field's pre-filled value is machine-dependent (e.g. `[CY]`; A › Host shell and environment); how TC
pre-fills it is not documented.

### 15.1 Copy method

| Control                                                      | Default             | Key                                                                                           | Meaning                                                                                                                                                                                                                       |
| ------------------------------------------------------------ | ------------------- | --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Use standard copy method (recommended)                       | on                  | `CopyDefaultMethod=1`                                                                         | TC chooses the method: `ReadFile`/`WriteFile` on 9x/ME, `CopyFileEx` on NT through Windows 11                                                                                                                                 |
| Use default method only (reliable, not very fast)            | selected (inactive) | —                                                                                             | Built-in `ReadFile`/`WriteFile` copy with the small-file buffers                                                                                                                                                              |
| Buffer sizes for small files: same disk / different disks    | 32 k / 32 k         | `CopyBlockSize=32` (minimum) / `CopyBlockSizeOther=32`                                        | Buffer in KiB. On one disk use a larger buffer than between two disks, so the head does not keep jumping.                                                                                                                     |
| Also use big file copy mode (not using cache)                | —                   | `CopyHugeBlockSize` set (unset = mode off)                                                    | Files larger than the big-file buffer are copied unbuffered, bypassing the Windows cache. Good on hard disks, slow on USB drives; some vendor disk drivers are buggy in this mode.                                            |
| Buffer sizes for big files: same disk / different disks      | 10240 k / 64 k      | `CopyHugeBlockSize` (≥ 10 MB) / `CopyHugeBlockSizeOther`                                      | The help recommends at least 10240 k within one disk and 32 k between disks; it also calls 256 kB the minimum for the second value, which contradicts that advice                                                             |
| Drive letters on the same physical harddisk                  | (machine-dependent) | `SamePartitions=` (e.g. `CDE,FGH`)                                                            | Comma-separated groups of letters on one physical disk; copies between them use the same-disk strategy                                                                                                                        |
| Use compatibility mode for the following drives + USB sticks | off; USB sticks on  | `CopyCompatDrives=` (letters, `\` = Network Neighborhood, `*` = all); `CopyCompatUsbSticks=1` | `CopyFileEx` for exotic drives that misbehave with the other modes; USB sticks formatted as super-floppy are detected automatically (without it, copying to sticks on XP is extremely slow, there is no cache). Not on 9x/ME. |
| Use copy+paste via Explorer (only in case of copy problems)  | —                   | `ExplorerForCopy=0`                                                                           | F5/F6 copy through the clipboard and Explorer, for virus scanners that slow down everything except Explorer. **No comment copying, no extended overwrite/rename options, no Verify; simplified F5/F6 dialogs.**               |

```text
chooseCopyMethod(source, target, file):
  if ExplorerForCopy=1:            copy through the clipboard / Explorer
  elif standard method (default):  9x/ME → ReadFile/WriteFile;  NT … 11 → CopyFileEx
  else (expert):
    if drive in CopyCompatDrives or (CopyCompatUsbSticks=1 and drive is a super-floppy USB stick):
                                   CopyFileEx (compatibility mode; not on 9x)
    elif big-file mode on and size(file) > huge block size:
                                   unbuffered copy with CopyHugeBlockSize / …Other
    else:                          ReadFile/WriteFile with CopyBlockSize / …Other
  "same disk" ⇔ source and target letters are in one group of SamePartitions
```

### 15.2 General Copy+Delete options

| Control                                                     | Default | Key                                                                                                | Meaning                                                                                                                                                                                                                                                    |
| ----------------------------------------------------------- | ------- | -------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Copy date/time of directories                               | off     | `CopyDirTimeStamp=0`                                                                               | Copies a folder's last-modified time; also when unpacking folders that were packed _explicitly_. NTFS may change a folder's time when files inside it change.                                                                                              |
| Verify after copy (MD5/BLAKE3 checksum)                     | off     | `VerifyCopy=0`                                                                                     | The **start-up state** of the _Verify_ box of the F5 dialog (07 › Copy dialog): the copy is read again, bypassing the cache, and its checksum compared with the source; BLAKE3 is used instead of MD5 when available. Slow; for disks with known problems. |
| Use Explorer delete method (faster, cannot handle comments) | off     | `Win95Delete=-1` (`0` TC's own method, `1` Explorer's, `-1` Explorer's only while CleanSweep runs) | Delete through Explorer; faster, but file comments are not kept in step. **While ticked, the recycle-bin option below is unavailable.**                                                                                                                    |
| F8/Del deletes to recycle bin (Shift=directly)              | on      | `UseTrash=1`                                                                                       | On: F8, Del and a drop on the F8 button recycle, Shift+F8/Shift+Del delete directly. Off: the reverse.                                                                                                                                                     |

Ini-only delete keys (07 › Delete method keys): `VistaDelete=-1`, `DeleteDelay=0`. Further copy-engine keys
(`CopyStreams`, `CopyAllTimes`, `CopyLinks`, `SizeCheck` …) are in 07 › Other copy settings and 19.

_Basis: observed on Windows 11 and under Wine; help: dlg_configcopydelete, inisettings1, inisettings2._

---

## 16. Operation › Refresh

When the file lists are re-read (03 › Refresh). TC has two independent mechanisms.

```text
Auto-Refresh when activating the program
 No refresh for these drives:            [            ]
 Do not remember these drives on exit:   [            ]
 Note: Use a backslash \ for network paths (UNC), / for file system plugins,
       and a colon : for virtual folders like the desktop.
Auto-Refresh when the file system changes
 [ ] Refresh when files are created, deleted and renamed
     [ ] Also when size, date, or attributes change
     [ ] Put added files at the END of the file list (default: sorted)
     [ ] Don't react to updates while in the background
     [ ] Update footer (total number of files)
     [ ] Update header (free disk space)
     No refresh for these drives: [            ]
```

The sub-options of the second group are enabled only while its first checkbox is ticked.

### 16.1 Refresh on activation

By default the file lists are re-read when TC is activated again after another program had the focus (observed on
Windows 11: after a program was run from the command line, the panel was re-read when TC got the focus back), and the
directories are restored when TC is restarted.

| Control                              | Default | Key          | Meaning                                                                                                                                                                                           |
| ------------------------------------ | ------- | ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| No refresh for these drives          | empty   | `NoReread=`  | Drives that are **not** re-read on activation                                                                                                                                                     |
| Do not remember these drives on exit | empty   | `NoReread2=` | Drives whose directory is **not** restored at the next start, e.g. slow or intermittently reachable network drives. If the key is missing, the `NoReread` value is used (behaviour of TC < 6.52). |

Character syntax of both fields and of `WatchDirsExclude`: a letter = that drive; `\` = all UNC paths (`\\server\share`,
Network Neighborhood); `/` = file-system plugins; `:` = virtual folders such as the Desktop. Example: `NoReread=ABC\`
with `NoReread2=AB\` turns off re-reading for A:, B:, C: and the network but still restores the C: directories after a
restart.

### 16.2 Watching the file system

The shown directories are monitored; changes made by other programs appear after about **1 second**. **Virtual folders
are never watched.**

| Control                                                         | Default | `WatchDirs=0` bit   | Effect                                                                                 |
| --------------------------------------------------------------- | ------- | ------------------- | -------------------------------------------------------------------------------------- |
| Refresh when files are created, deleted and renamed             | off     | 1                   | Master switch; alone it handles only "major" changes (create, delete, rename)          |
| └ Also when size, date, or attributes change                    | off     | 2                   | Minor changes too, e.g. a file growing during a download                               |
| └ Put added files at the END of the file list (default: sorted) | off     | 4                   | New entries are appended (Explorer style) instead of sorted into place                 |
| └ Don't react to updates while in the background                | off     | 8                   | Watching is suspended while TC is not the foreground application                       |
| └ Update footer (total number of files)                         | off     | 16                  | Recalculate the file count and total size on each change; may be slow in large folders |
| └ Update header (free disk space)                               | off     | 32                  | Re-read the total and free space on each change; may be slow                           |
| (ini only)                                                      | —       | 256                 | Beep on each auto-update (debugging aid)                                               |
| └ No refresh for these drives                                   | empty   | `WatchDirsExclude=` | Drives excluded from watching (syntax above)                                           |

- `cm_SwitchWatchDirs` (2921) turns watching off or on **temporarily**: `0` toggle, `1` on, `-1`/`2` off.
- `DeviceChange=2` (ini only) decides how drive arrival and removal messages are handled: `1` always, `2` only in the
  foreground, `3` also do not switch away from removed drives, `0` ignore.

_Basis: observed on Windows 11 and under Wine; help: dlg_configrefresh, inisettings1, inisettings2._

---

## 17. Operation › Quick Search

How typing letters in a file panel searches the current directory (03 › Quick search and quick filter).

```text
Quick search (current dir)
 (o) Ctrl+Alt+Letters
 ( ) Alt+Letters
 ( ) Letter only
 ( ) Letters - with search dialog
 ( ) Disabled
Exact name match:
 [x] Beginning (name must start with first typed character)
 [ ] Ending (last character before a typed dot . must match)
```

| Control                                                 | Default  | Key                           | Meaning                                                                                                                                                                                                               |
| ------------------------------------------------------- | -------- | ----------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ctrl+Alt+Letters                                        | selected | `AltSearch=0`                 | Ctrl+Alt+letter opens the quick-search box; Ctrl and Alt may then be released. Alt+letter keeps opening the menus.                                                                                                    |
| Alt+Letters                                             | —        | `AltSearch=1`                 | Alt+letter opens the quick-search box; the menu is reached with F9, F10, or Alt released then a letter                                                                                                                |
| Letter only                                             | —        | `AltSearch=2`                 | As in Explorer: typing jumps to the next name starting with the typed characters, without a box; the typed letters are forgotten after about 1 s. The command line is reached with Right (Shift+Right in Brief view). |
| Letters - with search dialog                            | —        | `AltSearch=3`                 | Like _Letter only_, but with the quick-search box; a `*` typed first (not on the numeric keypad) searches anywhere in the name                                                                                        |
| Disabled                                                | —        | `AltSearch=4`                 | No key opens quick search; meant for use with `cm_ShowQuickSearch` on a hotkey                                                                                                                                        |
| Beginning (name must start with first typed character)  | on       | `QuickSearchMatchBeginning=1` | On: the name must begin with the typed text (`est` does not find `Test.txt`). Off: a `*` is put in front (`est` finds `Test.txt`).                                                                                    |
| Ending (last character before a typed dot . must match) | off      | `QuickSearchExactMatch=0`     | Off: a typed dot is read as `*.` (`Te.tx` also finds `Test.txt`; `win.i` finds `wincmd.ini`). On: the part before the dot must match exactly (`Te.tx` finds `Te.txt` only).                                           |

- With the variants that show the search box, the box has a filter button that hides all non-matching files; the filter
  and its keys (Ctrl+S, Ctrl+Shift+S, `QuickSearchAutoFilter`) are in 03 › Quick filter.
- Ini-only keys: `QuickSearchAllowNoMatch=0`, `QuickSearchAutoFilter=0`, `QuickSearchHistoryAutoFilter=0`,
  `QuickSearchTabsAutoFilter=0`, `tcmatch=` / `tcmatch64=` (custom matching DLL).

**Observed (Windows 11):** with _Letter only_, typing in the panel jumped at once (`rep` → `report_01`, `n` → `notes`)
without a box; letters no longer went to the command line; Enter opened the file under the cursor (an `.md` file without
association gave Windows' "Select an app to open this .md file").

_Basis: observed on Windows 11 and under Wine; help: dlg_configquicksearch, inisettings2._

---

## 18. Operation › FTP

Options of the built-in FTP client (11 › Overview). **These values are stored in `wcx_ftp.ini`**, `[General]` unless
noted.

```text
FTP
 [10] Number of times to retry if FTP server busy
 [5]  Delay between retries (seconds)
 Default transfer mode: [Binary (archives, doc etc.) ▾]
 Open new connections:  [in the active panel         ▾]
 [ ] Create a log file: [%TEMP%\tcftp.log            ] [>>]      (disabled while unticked)
 [ ] All uploads/downloads in background
 [ ] Use passive mode by default
 [ ] PORT mode: only use ports from limited range: [10000] - [11000]
 [ ] PORT mode: external address (IP/DNS/HTTP): [                ]
 [x] Compress during transfer (MODE Z)          [x] Not on LAN
 [x] Auto-resume transfer if no data received for: [30] s
```

| Control                                             | Default                     | Key                                                                                       | Meaning                                                                                                                                                                                                                                                                                                                                                |
| --------------------------------------------------- | --------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Number of times to retry if FTP server busy         | 10                          | `ConnectRetries=10`                                                                       | Reconnect attempts when the server is busy; `0` = off. The dialog help applies it to anonymous and user/password logins; the ini help mentions anonymous logins only.                                                                                                                                                                                  |
| Delay between retries (seconds)                     | 5                           | `WaitDelay=5`                                                                             | Wait before each retry                                                                                                                                                                                                                                                                                                                                 |
| Default transfer mode                               | Binary (archives, doc etc.) | `TransferMode=I` (`A` text, `I` binary, `X` automatic)                                    | Mode at start-up. List: Automatic · Binary (archives, doc etc.) · Text (plain text, html, etc.). _Automatic_ decides by extension (`Ascii=*.txt *.htm*`).                                                                                                                                                                                              |
| Open new connections                                | in the active panel         | `FtpOpenIn=0` (`1` left, `2` right, `3` target panel)                                     | List: in the active panel · in the left panel · in the right panel · in the target panel                                                                                                                                                                                                                                                               |
| Create a log file + path                            | off, `%TEMP%\tcftp.log`     | `LogFile=`                                                                                | **Appends** the messages of the FTP log window to the file; `LogFile2=` (ini only) writes a reduced log                                                                                                                                                                                                                                                |
| All uploads/downloads in background                 | off                         | `FtpInBackground=0`                                                                       | New transfers start in the Background Transfer Manager; each needs its own new connection (11 › Transfers)                                                                                                                                                                                                                                             |
| Use passive mode by default                         | off                         | `[default] pasvmode=0`                                                                    | Passive mode for new connections, to pass firewalls that block incoming connections. When a new connection is configured, its passive setting becomes the default. Also used by the Background Transfer Manager when ftps URLs are added (e.g. with the `+` button).                                                                                   |
| PORT mode: only use ports from limited range        | off, 10000 – 11000          | `PortFrom=`, `PortTo=`                                                                    | The client listens only on ports in that range (for firewalls opened for a range). Use ports 1024–65535, at least 100 per computer, better 1000. Also needed with the external address.                                                                                                                                                                |
| PORT mode: external address (IP/DNS/HTTP)           | off, empty                  | `PortIP=`, `PortIPEnabled=0`                                                              | IPv4 address announced in `PORT`, for routers without FTP support; counter-productive for routers that rewrite PORT themselves. Accepts a fixed IP, a DynDNS name, or an `http://` URL of a page that returns the caller's IP as plain text (e.g. a PHP page printing `$_SERVER["REMOTE_ADDR"]`); the forwarded port range must then be entered above. |
| Compress during transfer (MODE Z) / Not on LAN      | on / on                     | `ModeZ=`: `0` off, `1` Internet only (the default state of the page), `2` also on the LAN | Compresses on the fly (zlib) when the server supports it. _Not on LAN_ excludes servers on the same subnet or with a private address such as `192.168.*.*`; a teleworker on a slow link into the company LAN should turn it off. Strength: `ZlibRatioBin=3`, `ZlibRatioTxt=3` (ini only).                                                              |
| Auto-resume transfer if no data received for: [n] s | on, 30                      | `AutoResume=30` (`-1` = off)                                                              | After n seconds without data TC drops the connection, reconnects and resumes the transfer                                                                                                                                                                                                                                                              |

The other `wcx_ftp.ini` keys (TLS, MLSD, keep-alive, `SpecialFlags`, firewall) are in 11 and 19 › `wcx_ftp.ini`.

_Basis: observed under Wine; help: dlg_configftp, wcx_ftp_ini_settings._

---

## 19. Operation › Plugins

Entry points to the four plugin types (15 › Managing plugins: Options › Plugins).

```text
Download new plugins from ghisler.com
 Opens your default WEB browser with the plugins page. Installation: After downloading
 the plugin ZIP file, open it in Total Commander with ENTER and follow the instructions.
                                                                   [Download]
Packer plugins (.WCX)
 Packer plugins are used to open archives not supported internally by Total Commander.
                                                                   [Configure]
File system plugins (.WFX)
 File system plugins allow access to disks inaccessible by Windows, e.g. Linux file
 systems, or to external devices like Palm/PocketPC.               [Configure]
Lister plugins (.WLX)
 Lister plugins allow to display file formats like images, spreadsheets, databases etc.
 in Lister (F3, Ctrl+Q)                                            [Configure]
Content plugins (.WDX)
 Content plugins allow to display extended file details like mp3 tags or image
 attributes in file lists, or use them in search and rename tool.  [Configure]
```

| Button                          | Opens                                                                                                                                                                                                                                                  | Stored in                                |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------- |
| Download                        | The plugins web page in the default browser                                                                                                                                                                                                            | —                                        |
| Packer plugins › Configure      | An "Associate"-style dialog: "All files with extension (ending with):" `[combo]`, "Associate with:" `[edit]` with a list `(none)` / the plugins, `[New type...] [Delete] [OK] [Cancel] [Help]`. Usage: Files › Pack and entering archives (08).        | `[PackerPlugins]` `<ext>=<flags>,<path>` |
| File system plugins › Configure | **"File system plugins"**: "Installed file system plugins:" list, each line `<root name>  -  <path>`, e.g. `Registry  -  %APPDATA%\GHISLER\plugins\wfx\registry\Registry.wfx`; `[Add] [Remove] [Rename] [OK] [Cancel]`. Used via Network Neighborhood. | `[FileSystemPlugins]` `<name>=<path>`    |
| Lister plugins › Configure      | **"Lister plugins"**: "Lister plugins:" list, `[^] [v]`, `[Add] [Remove] [Rename]`, `[OK] [Cancel]` (the same dialog as _LS-Plugins_, §14.3). Usage: F3 on a supported file.                                                                           | `[ListerPlugins]` `N=<path>`             |
| Content plugins › Configure     | **"Content plugins"**: list, `[^] [v]`, `[Add] [Remove] [Rename]` (Rename disabled), `[OK] [Cancel]`. Usage: custom columns, Multi-Rename Tool, search.                                                                                                | `[ContentPlugins]` `N=<path>`            |

The 64-bit index sections `[PackerPlugins64]`, `[FileSystemPlugins64]`, `[ListerPlugins64]`, `[ContentPlugins64]` are
maintained by TC (19 › Plugin sections). Auto-installation (Enter on a plugin archive with `pluginst.inf`) ends in these
same dialogs; that flow is in 15 › Installation.

_Basis: observed on Windows 11 (dialogs reached through auto-install) and under Wine; help: dlg_configplugin,
inisettings3._

---

## 20. Operation › Thumbnails

Thumbnail cache, size, extra fields and loading methods (03 › View types).

```text
Thumbnails: general
 Database Location (leave empty to disable caching):
   [%$LOCAL_APPDATA%\GHISLER                 ] [>>] [Default]
 [x] Copy/delete thumbnails with files
 [x] Show custom fields below thumbnails (e.g. image size): [            ] [Add...]
 Thumbnail size: [96] x [96] Pixels                                   [Fields by type]
Loading Thumbnails:
 [x] Internal thumbnails from images: [*.jpg *.dng *.arw *.crw *.cr2 *.cr3 *.nef *.orf *.pef *.raf *.rw2]
 [x] Get from Lister plugins for:     [*.*                ]
 [x] Use Explorer method (OLE2) for:  [*.* | *.htm *.html ]
 [x] Get from Irfan-/Xnview for:      [*.*                ]
 [x] Plain Text file thumbnails for:  [*.txt *.ini        ]
Compact thumbnail database
 [ ] Remove thumbnails for no longer existing files                    [Start!]
 [ ] Remove thumbnails for currently ejected CDs
 [ ] Remove thumbnails for inaccessible disks (e.g. Network, USB)
```

### 20.1 General settings

| Control                                                          | Default                                              | Key                                                 | Meaning                                                                                                                                                                                                                                                                                             |
| ---------------------------------------------------------------- | ---------------------------------------------------- | --------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Database Location + [>>] [Default]                               | `%$LOCAL_APPDATA%\GHISLER` (Win9x: the TC directory) | `ThumbsLocation=`                                   | Folder of the thumbnail cache, an OLE compound file. **Only one user can open it at a time**, so it must not be shared. Empty = no cache; the size then comes from `ThumbWidthNoCache` / `ThumbHeightNoCache`. _Default_ restores the default path.                                                 |
| Copy/delete thumbnails with files                                | on                                                   | `ThumbsCopyDel=1`                                   | When a file with a cached thumbnail is copied or deleted, the database is updated in a **background thread**                                                                                                                                                                                        |
| Show custom fields below thumbnails (e.g. image size) + [Add...] | on, empty                                            | `ThumbsCustomFieldsEnabled=1`, `ThumbsCustomField=` | Extra text lines under the name, in custom-column field syntax (`[=plugin.field.unit]`, 18 › Content fields); `\n` starts a new line, inserted by _Add..._                                                                                                                                          |
| Thumbnail size: [w] x [h] Pixels                                 | 96 × 96                                              | not named by the help                               | Thumbnail size; multiples of 16 are faster. Recommended: square 96×96 or 128×128, or 4:3 (96×72, 128×96) for photo collections. Zoom 10–200 % in 10 % steps with Ctrl+wheel or `cm_ZoomIn` / `cm_ZoomOut` (also with a percentage, `cm_ZoomIn 150`), stored per DPI in res. `ThumbScaleFactor=100`. |
| Fields by type                                                   | none                                                 | `[ThumbsCustomField]` `xexts=` / `xfields=`         | Different field sets per file mask, e.g. EXIF data for `*.jpg *.jpeg`, the codec for videos; several lines allowed                                                                                                                                                                                  |

### 20.2 Loading pipeline

The methods are tried **in the order listed**. Each mask uses the search syntax (at most 1023 characters) with
exclusions after `|`.

| Order | Control                         | Default mask                                                        | Key                                                                           | Notes                                                                                                                                                                                                 |
| ----- | ------------------------------- | ------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | Internal thumbnails from images | `*.jpg *.dng *.arw *.crw *.cr2 *.cr3 *.nef *.orf *.pef *.raf *.rw2` | enable: `ThumbOptions=15` bit 16 **disables**; mask key not named by the help | Reads the preview embedded in JPG and in Canon CRW/CR2/CR3, Fuji RAF, Nikon NEF, Olympus ORF, Panasonic RW2, Pentax PEF, Sony ARW and Adobe DNG files. Very fast; old cameras may embed only 160×120. |
| 2     | Get from Lister plugins for     | `*.*`                                                               | bit 2; `ThumbPlgTypes=*.*`                                                    | Needs Lister plugins with the thumbnail-extraction function                                                                                                                                           |
| 3     | Use Explorer method (OLE2) for  | `*.* \| *.htm *.html`                                               | bit 1; `ThumbExplTypes=*.* \| *.htm *.html`                                   | The **only** method that works in virtual folders (Desktop, attached phones). HTML is excluded for security. On Windows 11 it produced real thumbnails for PNG and JPG.                               |
| 4     | Get from Irfan-/Xnview for      | `*.*`                                                               | bit 4; `ThumbIrfXnTypes=*.*`                                                  | Uses the viewer path set in Configure Lister › Multimedia (§14.3); the full image is loaded, passed back via `WM_COPYDATA` and scaled down                                                            |
| 5     | Plain Text file thumbnails for  | `*.txt *.ini`                                                       | bit 8; `ThumbTxtTypes=*.txt *.ini`                                            | Renders the first lines of the text                                                                                                                                                                   |

`ThumbGdiplusTypes=` (ini only) lists types extracted internally as pictures through GDI+. Further ini-only keys:
`PreloadThumbnails=1` (`2` also in branch view, `3` only the next two rows, `0` only when scrolled into view),
`ThumbnailSizeLimit` (MB in memory; 500 on NT, max 1024 and 10 % of RAM), `ThumbIconSize=48`,
`ThumbnailPrealloc=100000`, `ThumbsInDlg=0` (thumbnails in the overwrite dialog), `WmfAllowed=-1`.

### 20.3 Compact thumbnail database

**Start!** compacts the database file and removes stale entries according to the checkboxes:

| Checkbox                                                     | Default | Removes                                                                                           |
| ------------------------------------------------------------ | ------- | ------------------------------------------------------------------------------------------------- |
| Remove thumbnails for no longer existing files               | off     | Entries for files that no longer exist on **reachable** drives; unreachable drives are left alone |
| Remove thumbnails for currently ejected CDs                  | off     | Entries for files on CD/DVD drives without a disc                                                 |
| Remove thumbnails for inaccessible disks (e.g. Network, USB) | off     | Entries for unreachable network drives and USB sticks                                             |

_Basis: observed on Windows 11 and under Wine; help: dlg_configthumbs, inisettings2, inisettings3._

---

## 21. Operation › Log file

Log of file operations (the FTP client has its own log, §18).

```text
File operation log file
 [ ] Create a log file: [%TEMP%\totalcmd.log          ] [>>]
Log operations                                   (enabled only with the log)
 [x] Copy/Move/Create shortcut
 [x] Delete
 [x] Create/Delete folders
 [x] Pack/Unpack/Test archives
 [ ] File system plugins
 Note: The FTP client can create its own log file
Operation status
 [x] Log successful operations
 [x] Log errors
 [x] Log skipped files (when choosing skip or skip all)
Log file rotation
 (o) Never (always log to same log file)
 ( ) Every day after midnight
 ( ) When the log file becomes larger than [1000] kBytes
 [x] Keep a maximum of [30] log file copies
```

| Control                                                          | Default                    | Key                                                     | Meaning                                                                                                  |
| ---------------------------------------------------------------- | -------------------------- | ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Create a log file + path                                         | off, `%TEMP%\totalcmd.log` | `LogOptions` bit 1; `LogFile=`                          | Logging on/off and the log file                                                                          |
| Copy/Move/Create shortcut                                        | on                         | bit 2                                                   | Also logs renames                                                                                        |
| Delete                                                           | on                         | bit 4                                                   |                                                                                                          |
| Create/Delete folders                                            | on                         | bit 8                                                   |                                                                                                          |
| Pack/Unpack/Test archives                                        | on                         | bit 16                                                  | Includes packer plugins and _Verify checksums_. Errors from unpacking **CAB** archives cannot be logged. |
| (unused)                                                         | —                          | bit 32                                                  |                                                                                                          |
| File system plugins                                              | off                        | bit 64                                                  | All plugin file operations                                                                               |
| Log successful operations                                        | on                         | bit 1024                                                |                                                                                                          |
| Log errors                                                       | on                         | bit 2048                                                |                                                                                                          |
| Log skipped files (when choosing skip or skip all)               | on                         | bit 4096                                                | Files skipped with Skip / Skip all                                                                       |
| Never / Every day after midnight / When … larger than [n] kBytes | Never; 1000                | `LogRotateLimit=0` (`-1` daily, `v>0` size limit in kB) | Rotation (below)                                                                                         |
| Keep a maximum of [n] log file copies                            | on, 30                     | `LogKeepCount=30`                                       | Older rotated copies are deleted                                                                         |

- Default `LogOptions=7198` = 2+4+8+16+1024+2048+4096: everything except plugins, with logging itself off.
- Names inside archives with **encrypted names** are not logged when unpacking, unless `LogEncryptedNames=1` (ini only);
  with that key all names are logged and a warning tip is shown on entering a header-encrypted archive.

```text
beforeWrite(entry):
  if rotation == DAILY and this is the first write after midnight:
      rename Name.ext -> Name.<date>.ext ; create a new Name.ext      (date format not documented)
  if rotation == SIZE and size(Name.ext) + len(entry) > limitKB * 1024:
      n = 1; while exists(Name.<n>.ext): n += 1
      rename Name.ext -> Name.<n>.ext ; create a new Name.ext
  if "Keep a maximum" is on and the number of rotated copies > LogKeepCount:
      delete the oldest copies
  append(entry)
```

_Basis: observed under Wine; help: dlgconfiglogfile, inisettings1._

---

## 22. Operation › Ignore list

A TC-only list of files and folders that are hidden and skipped everywhere.

```text
 [ ] Ignore (don't show) the following files and folders:
 ┌──────────────────────────────────────────────────────┐
 │ (multi-line editor with both scrollbars)             │
 └──────────────────────────────────────────────────────┘
 Save in: [                                   ] [>>]
 [Add selected names with full path]  [Add selected names]
```

| Control                                             | Default | Key                                                               | Meaning                                                                                                                                                                          |
| --------------------------------------------------- | ------- | ----------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ignore (don't show) the following files and folders | off     | `IgnoreListFileEnabled=` (ini default 1, but no list file is set) | Master switch; lets the list be disabled without forgetting the file. `cm_SwitchIgnoreList` (2922): `0` toggle, `1` on, `-1`/`2` off, `+4` = do not save.                        |
| Editor                                              | empty   | —                                                                 | The entries, one per line (syntax below)                                                                                                                                         |
| Save in + [>>]                                      | empty   | `IgnoreListFile=`                                                 | The list is **an external text file**, default name `tcignore.txt`; written as UTF-8 automatically when Unicode names need it                                                    |
| Add selected names with full path                   | —       | —                                                                 | Appends the items selected in the last active panel as full paths (form 1); plugin and FTP prefixes are added when needed. Enabled only with the checkbox on and items selected. |
| Add selected names                                  | —       | —                                                                 | The same, as bare names (form 3), so they are hidden everywhere                                                                                                                  |

When names are added, no blank line is inserted if the list is empty or already ends with a line break.

### 22.1 Effect

"Ignored" is **not** a file attribute and is independent of hidden/system.

| Area                                      | Effect on ignored items                                                                                               |
| ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| File panels                               | Not displayed                                                                                                         |
| Copy (F5)                                 | Not copied, also inside copied subfolders                                                                             |
| Move (F6)                                 | Not moved, **except** inside a folder moved by renaming on the same drive                                             |
| Counting (Space, Alt+Shift+Enter, footer) | Excluded from count and size; a folder containing only ignored items shows size 0 (unless sizes come from Everything) |
| Synchronize dirs, Find Files              | Ignored                                                                                                               |
| Direct access                             | Still possible: `cd` to an ignored folder or opening an ignored file by name works                                    |
| Master switch off                         | Everything shown and processed normally                                                                               |

Edge cases: **delete to the recycle bin** of a folder that holds only ignored items happens **without** the
non-empty-folder warning; **direct delete** (Shift+F8 / Shift+Del) **does** warn if the folder holds ignored items, even
deep inside; **move across drives** may leave the source folder undeletable (its ignored items were not moved), and TC
reports that it could not be deleted; after a **copy**, source and target look the same although the source still holds
hidden ignored items.

### 22.2 Entry syntax

One entry per line, or several **name** patterns on one line separated by space or `;`.

| #   | Form                                  | Example                                   | Scope                           |
| --- | ------------------------------------- | ----------------------------------------- | ------------------------------- |
| 1   | Full path                             | `c:\config.sys`                           | That item only                  |
| 2   | Path from the root of **every** drive | `\RECYCLER`, `\System volume information` | That path on all drives         |
| 3   | Bare name                             | `descript.ion`                            | That name in every folder       |
| 4   | `*:` + name                           | `*:filename`                              | Inside every file-system plugin |
| 5   | `pluginname:` + name                  | `pluginname:filename`                     | Inside one plugin               |
| 6   | `FTP:` + name (upper case)            | `FTP:filename`                            | On every FTP server             |
| 7   | `FTP:server:` + name                  | `FTP:server:filename`                     | On one server                   |
| 8   | `FTP:>connection:` + name             | `FTP:>my connection:filename`             | For one saved connection        |

- `*` and `?` are allowed in the name part of every form (`*.br1`, `c:\test\*.bak`, `\test\*.bak`).
- `\*\` in a path matches **any number of levels** up to the name, e.g. `SFTP:\servername\*\name`.
- Several bare names may share a line (`*.bak *.old` or `*.bak;*.old`); **path entries (forms 1 and 2) need a line
  each.**
- A trailing `\` makes the entry match **directories only**.
- A name with **both spaces and wildcards** is quoted around the name part only: `"System Volume*"`,
  `c:\path\"long name*"`.
- Environment variables are expanded, e.g. `%USERPROFILE%\AppData`.

_Basis: observed under Wine; help: dlg_configignorelist, inisettings1; history._

---

## 23. Operation › History

The directory-history popup (Alt+Down or the `▼` button) combines two lists: the **history** of last visited folders,
kept **per panel**, and the **frequently used folders**, ranked by visits and stored in `tcDirFrq.txt`. Alt+Shift+Down
opens it unfiltered: thinning is ignored and both lists are shown beyond the "Maximum items to show" limits. Navigation
is in 03 › Navigation, directory history and hotlist.

```text
 [x] Directory history thinning             Max. width in characters (average): [120]
 [x] Icons                                  Font: [Same as file lists ▾]
History (last visited folders)
 [x] Save history on exit
 Maximum items to save: [200]   Maximum items to show: [26]
 [ ] Show last visited directory closest to the middle of the list
 [Save now] [Delete now]
Frequently used folders
 [x] Save frequently used folders on exit
 Maximum items to save: [200]   Maximum items to show: [30]
 [ ] Show most frequently used directory closest to the middle of the list
 Storage location for list of most frequently used folders:
   [Default (%$LOCAL_APPDATA%\GHISLER) ▾]
 [Save now] [Delete now]
 Scroll list: [to last visited folder ▾]
```

| Control                                                               | Default                            | Key                                                                          | Meaning                                                                                                                                                                                                                                                                                                                                 |
| --------------------------------------------------------------------- | ---------------------------------- | ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Directory history thinning                                            | on                                 | `HistoryThinning=1`; `HistoryThinningDelta=5000` (ms, ini only)              | Hides short visits from Alt+Down (algorithm below)                                                                                                                                                                                                                                                                                      |
| Max. width in characters (average)                                    | 120                                | `HistoryMaxWidth=120`                                                        | Popup width cap, in average character widths of its font                                                                                                                                                                                                                                                                                |
| Icons                                                                 | on                                 | `HistoryIcons=1`                                                             | Icons for folders, FTP connections and plugins                                                                                                                                                                                                                                                                                          |
| Font                                                                  | Same as file lists                 | `HistoryFont=0` (`1` main-menu font, otherwise a font name)                  | List: Same as file lists · Same as main menu · Custom...                                                                                                                                                                                                                                                                                |
| Save history on exit                                                  | on                                 | `SaveHistory=1`                                                              | Writes `[LeftHistory]` and `[RightHistory]`. **Unticking does not clear these sections**; use _Delete now_.                                                                                                                                                                                                                             |
| Maximum items to save (history)                                       | 200                                | `HistoryLenStored=200`                                                       | Per side; maximum 200; includes entries hidden by thinning                                                                                                                                                                                                                                                                              |
| Maximum items to show (history)                                       | 26                                 | `HistoryLen=26`                                                              | Maximum 100                                                                                                                                                                                                                                                                                                                             |
| Show last visited directory closest to the middle of the list         | off                                | `ShowLastVisitedInMiddle=0`                                                  | Off: the last visited folder is at the outer edge (top or bottom); on: next to the frequently-used block                                                                                                                                                                                                                                |
| Save now / Delete now (history)                                       | —                                  | `cm_ConfigSaveDirHistory` 582                                                | _Save now_ writes at once (useful when saving on exit is off). _Delete now_ removes the sections; untick _Save history on exit_ too, or they are written again at close.                                                                                                                                                                |
| Save frequently used folders on exit                                  | on                                 | `SaveFrequentlyUsed` (default: the `SaveHistory` value)                      | **Unticking does not delete `tcDirFrq.txt`.**                                                                                                                                                                                                                                                                                           |
| Maximum items to save (frequent)                                      | 200                                | `FrequentlyUsedLenStored=200`                                                | No upper limit                                                                                                                                                                                                                                                                                                                          |
| Maximum items to show (frequent)                                      | 30                                 | `FrequentlyUsedLen=30`                                                       | Maximum 200                                                                                                                                                                                                                                                                                                                             |
| Show most frequently used directory closest to the middle of the list | off                                | `ShowFrequentlyUsedMaxInMiddle=0`                                            | Puts the top entry next to the history block                                                                                                                                                                                                                                                                                            |
| Storage location for list of most frequently used folders             | Default (%$LOCAL_APPDATA%\GHISLER) | `DirUsageLocation=1` (`2` the wincmd.ini directory, `0` disabled, or a path) | List: Default (%$LOCAL_APPDATA%\GHISLER) · Same folder as wincmd.ini · Disabled · Custom...                                                                                                                                                                                                                                             |
| Save now / Delete now (frequent)                                      | —                                  | —                                                                            | The same, for `tcDirFrq.txt`                                                                                                                                                                                                                                                                                                            |
| Scroll list                                                           | to last visited folder             | `HistoryScrollTo=0`                                                          | What is visible first when the combined list is taller than the screen: `0` to last visited folder, `1` to most frequently used folder, `2` to the top, `3` to the bottom, `4` to the middle, on history list, `5` to the middle, on frequently used folders. If that point lies between the two lists, the cursor is placed there too. |

**Thinning:**

```text
onLeaveDirectory(dir, timeSpentMs, didFileOperation):
    addToRawHistory(dir)                           # always recorded (Alt+Shift+Down, saving)
    if not HistoryThinning:                                         visible(dir) = true
    elif didFileOperation:                                          visible(dir) = true
    elif HistoryThinningDelta > 0 and timeSpentMs >= HistoryThinningDelta:
                                                                    visible(dir) = true
    else:                                                           visible(dir) = false
```

With `HistoryThinningDelta=0` only folders where a file operation was started stay visible. The saved history also
contains the hidden entries.

Ini-only history keys: `ShowFrequentlyUsed=1`, `ReverseHistory=0` (1 = last visited at the top), `OldStyleHistory=0` (1
= plain Windows menu), `HistoryAppend=1` (0 = choosing an entry moves the current position instead of appending),
`HistoryCut=1` (going back and then changing directory cuts the forward part), `QuickSearchHistoryAutoFilter=0`. Storage
format of the history sections: 19 › History sections.

_Basis: observed under Wine; help: dlg_confighistory, dlg_config2, inisettings1, inisettings2; KEYBOARD.TXT._

---

## 24. Packer

Archive handling in general and the external packers (08 › Packer configuration: effects). Keys are in `[Packer]`.

```text
 [x] Treat archives like directories
 [ ] Set archive date to newest file date
ARJ
 ARJ packer: [arj32.exe          ] [>>]
 [x] Use internal un-ARJ if possible
 [ ] Pass long filenames to ARJ (ARJ 2.55 or later required)
LHA
 LHA packer: [lha32.exe          ] [>>]
 [x] Use internal un-LZH if possible
RAR
 RAR Packer: [rar.exe            ] [>>]
 [x] Use internal un-RAR if possible
UC2
 UC2 Packer: [uc.exe             ] [>>]
ACE
 ACE (>= 2.04): [winace.exe      ] [>>]
 [ ] Use internal un-ACE if possible          (disabled in the 64-bit version)
TAR
 [x] Create TAR archives for Linux (unchecked: for SunOS)
Additional packers
 Packer plugins: [Configure packer extension WCXs]
```

| Control                                                 | Default       | Key                    | Meaning                                                                                                                                                                     |
| ------------------------------------------------------- | ------------- | ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Treat archives like directories                         | on            | `ZIPlikeDirectory=1`   | Enter / double click on an archive shows its content as a folder; off = the associated program is launched (TC opens it itself if there is none) (08 › Archives as folders) |
| Set archive date to newest file date                    | off           | `ZipSetDateToNewest=0` | After packing, the archive's date is set to that of its youngest member, where supported: internal ZIP, 7-Zip, TAR, GZ; external ZIP (via 7z), 7-Zip, ACE, RAR, LHA         |
| ARJ packer + [>>]                                       | `arj32.exe`   | `ARJ=`                 | External ARJ (recommended `ARJ32.EXE`)                                                                                                                                      |
| Use internal un-ARJ if possible                         | on            | `InternalUnarj=1`      | Built-in un-ARJ; cannot handle encrypted members                                                                                                                            |
| Pass long filenames to ARJ (ARJ 2.55 or later required) | off           | `ARJlongnames=0`       | Long names are passed to ARJ when packing                                                                                                                                   |
| LHA packer + [>>]                                       | `lha32.exe`   | `LHA=`                 | External LHA; creates `.lzh`                                                                                                                                                |
| Use internal un-LZH if possible                         | on            | `InternalUnlzh=1`      | Built-in un-LZH                                                                                                                                                             |
| RAR Packer + [>>]                                       | `rar.exe`     | `RAR=`                 | External RAR (the help recommends `winrar.exe`); creates `.rar`                                                                                                             |
| Use internal un-RAR if possible                         | on            | `InternalUnrar=1`      | `UnRAR.DLL` (`UnRAR64.DLL` on 64-bit), falling back to `tc7z.dll`                                                                                                           |
| UC2 Packer + [>>]                                       | `uc.exe`      | `UC2=`                 | Creates `.uc2`; does not work on 64-bit Windows                                                                                                                             |
| ACE (>= 2.04) + [>>]                                    | `winace.exe`  | `ACE=`                 | External ACE; creates `.ace` (the help says version 1.2b or later)                                                                                                          |
| Use internal un-ACE if possible                         | off, disabled | `InternalUnace=1`      | `UnACEv2.DLL`; there is no 64-bit DLL, so the option is disabled in the x64 version                                                                                         |
| Create TAR archives for Linux (unchecked: for SunOS)    | on            | `LinuxCompatible=1`    | Changes only how names **longer than 99 characters** are stored: GNU-tar (Linux) or SunOS style                                                                             |
| Configure packer extension WCXs                         | —             | `[PackerPlugins]`      | Opens the packer-plugin association dialog (§19)                                                                                                                            |

`>>` opens a file-open dialog to browse for the packer. Further `[Packer]` keys (`VerifyZIP`, `ExpertMode`,
`UnZIPSeparateSubdirs` …) are in 08 and 19.

_Basis: observed under Wine; help: dlg_configpack, inisettings3._

---

## 25. Packer › Zip packer

ZIP packing and unpacking (08 › Packer configuration: effects). Keys are in `[Packer]`.

```text
ZIP
 ZIP packer:   [pkzip.exe          ] [>>]
 [x] Use internal ZIP packer    [ ] 7Z    [ ] Use ZIP-NT 2.01
 ZIP unpacker: [pkunzip.exe        ] [>>]
 [x] Always use internal unzipping (if possible)
Internal ZIP compression (0-9)
 (o) normal compression (6)
 ( ) maximum compression (9)
 ( ) fastest compression (1)
 ( ) other: [6 ⇅] (0 = none)
Directory for temporary files (internal ZIP)
 (o) default (run 'cd %TEMP%' in command line to see directory)
 ( ) other: [                    ]
Additional Settings
 [ ] Use 8.3 short filenames
 [ ] Open partial ZIP files          [ ] Keep damaged files (bad CRC)
 Pack Unicode names: [Ask every time a Unicode name is encountered ▾]
```

| Control                                        | Default                                      | Key                                                           | Meaning                                                                                                                                                                                                                                                                       |
| ---------------------------------------------- | -------------------------------------------- | ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ZIP packer + [>>]                              | `pkzip.exe`                                  | `ZIP=`                                                        | External ZIP packer (PKZIP-compatible by default)                                                                                                                                                                                                                             |
| Use internal ZIP packer                        | on                                           | `InternalZIP=1`                                               | Selects the internal packer; the new ZIP is then tested automatically (`VerifyZIP=1`; the test can be aborted without deleting the ZIP; `0` disables it)                                                                                                                      |
| 7Z                                             | off                                          | `zip7z=0`                                                     | The program in _ZIP packer_ is `7zg.exe` (preferred) or `7z.exe`, used to create **ZIP** archives (not 7z). Switches such as `-mcu=on` may follow the program name, commands such as `a` may not. Packing only.                                                               |
| Use ZIP-NT 2.01                                | off                                          | `zipnt=0` (`1` 2.0.1 patched by TC, `2` unrecognised version) | The program is Info-ZIP (ZIP-NT) 2.0.1 or later. An unpatched 2.0.1 is **patched automatically** when detected (without the patch, names with spaces fail). With later versions TC asks whether to use the packer anyway; answer yes, then test with names containing spaces. |
| ZIP unpacker + [>>]                            | `pkunzip.exe`                                | `UnZIP=`                                                      | Must be pkunzip-compatible; `unzip.exe` and 7-Zip cannot be used                                                                                                                                                                                                              |
| Always use internal unzipping (if possible)    | on                                           | `InternalUnzip=1`                                             | When ticked, the internal unzip (Info-ZIP based) is **always** used                                                                                                                                                                                                           |
| Internal ZIP compression                       | normal compression (6)                       | `InternalZipRate=6`                                           | `0` store … `1` fastest … `9` best; _other_ allows any 0–9. 9 is much slower for a gain of a few per mille. Rate 10 (LZMA) exists only with `LzmaAllowed=1` (ini only).                                                                                                       |
| Directory for temporary files: default / other | default                                      | `InternalzipTemp=`                                            | Temp directory of the internal packer, needed only when packing to removable disks; _other_ must name an existing directory. `RemovableInTemp=0` (ini only) decides when TEMP is used for removable media (08 › Pack).                                                        |
| Use 8.3 short filenames                        | off                                          | `Zip83Name=0`                                                 | Only the 8.3 alias of long names is stored, for plain DOS unzipping                                                                                                                                                                                                           |
| Open partial ZIP files                         | off                                          | `OpenPartial=0`                                               | A ZIP that is still downloading can be listed, from its local headers (the central directory is missing)                                                                                                                                                                      |
| Keep damaged files (bad CRC)                   | off                                          | `NoDelete=0`                                                  | A member whose CRC fails is normally deleted after extraction; with this it is kept (check it)                                                                                                                                                                                |
| Pack Unicode names                             | Ask every time a Unicode name is encountered | `ZipUnicode=0`                                                | How names outside the legacy code page are stored (list below)                                                                                                                                                                                                                |

`Pack Unicode names` entries (`ZipUnicode` value):

| Value | Entry                                                             | Rule                                                                                                                                                                                   |
| ----- | ----------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0     | Ask every time a Unicode name is encountered                      | A dialog asks how to store the names                                                                                                                                                   |
| 1     | Store Unicode names as UTF-8 (Pkzip 4.5/Winzip 11.2 method)       | Only names containing Unicode are written as UTF-8 with the UTF-8 flag; old unzippers (Explorer, old TC) still extract them, showing several accented characters per Unicode character |
| 2     | All as UTF-8 if at least one contains Unicode                     | If any name contains Unicode, **all** names (accented ones too) are UTF-8; otherwise all legacy                                                                                        |
| 3     | All as UTF-8 if at least one contains non-English characters >127 | Like 2, triggered by any character > 127 (e.g. sending accented names to someone with a Cyrillic system)                                                                               |
| 4     | Store Unicode name in extra field (Info-Zip method)               | The name field stays legacy; the Unicode name goes into Info-ZIP's Unicode Path extra field; good for Unix/Linux recipients                                                            |
| 5     | Store all names containing non-English in extra field             | Like 4, for every name with a character > 127                                                                                                                                          |
| 6     | (not in the observed list)                                        | Store Unicode characters as `?` (TC ≤ 7.0x); on unpack `?` becomes `_`. Documented by the help; a clone should accept the ini value.                                                   |

Ini-only: `ZipAnsiNames=0` (legacy names in OEM; 1 = ANSI), `PreferUtf8ForZip=1`, `ZipAES=0` (Pack dialog encryption).
_Set ZIP date to newest file date_ moved to the Packer page (§24).

_Basis: observed under Wine; help: dlg_internalzipconfig, inisettings3._

---

## 26. Packer › 7-Zip packer

7z packing (08 › Packer configuration: effects). Keys are in `[Packer]`.

```text
7-Zip
 7-Zip packer: [7zg.exe            ] [>>]
 [x] Use internal 7-Zip packer   [x] Prefer 7-Zip plugin if installed
 Extra parameters: [                    ]
7-Zip compression
 (o) normal (6)   ( ) maximum (9)   ( ) fastest (1)   ( ) other: [6] (0 = none)
Compression Settings
 Compression method: [LZMA2 * ▾]
 Dictionary size:    [default ▾]
 Word size:          [default ▾]
 [x] Create solid archive
 Solid block size:   [16384 M * ▾]
 Number of CPU threads: [2 ▾] / 16
Memory usage
 for compression:   682 M
 for decompression:  66 M
Encryption settings
 [ ] Also encrypt names
```

The `*` marks the default entry of a list for the current method and rate. _Memory usage_ is recalculated live; the
values above are those shown with the defaults. "/ 16" shows the number of logical processors of the test machine.

| Control                                           | Default                             | Key                                                                                                    | Meaning                                                                                                                                                                                                                                                                       |
| ------------------------------------------------- | ----------------------------------- | ------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 7-Zip packer + [>>]                               | `7zg.exe`                           | `7zip=`                                                                                                | Path of `7zg.exe`; needed only for external 7-Zip                                                                                                                                                                                                                             |
| Use internal 7-Zip packer                         | on                                  | `7zInternal=1`                                                                                         | `tc7z64.dll` (replaceable by a newer `7z.dll` of the right bitness). Even when off, the internal packer packs **into a subdirectory** of a 7z archive, which the external packer cannot do.                                                                                   |
| Prefer 7-Zip plugin if installed                  | on                                  | `7zPreferPlugin=1`                                                                                     | If the 7zip or Total7zip plugin is installed, Enter / double click opens 7z archives with it; in the Pack dialog "7-ZIP" then means the internal packer / 7zg, and "->7z" the plugin                                                                                          |
| Extra parameters                                  | empty                               | — (Pack command parameter `/F=`)                                                                       | Passed to internal and external 7-Zip. The **internal** packer accepts only `-m…` switches plus `-slp` (large pages), `-stl` (archive date = newest file), `-v` (volume size); forms `-mx=9`, `-mx9` and bare `-mx` (= the DLL default for that switch, e.g. `-mx` = `-mx=9`) |
| 7-Zip compression                                 | normal (6)                          | `7zRate=6`                                                                                             | `0` none, `1` fastest … `9` best; officially 0 and odd values, even values work too; the Pack dialog offers 1–9                                                                                                                                                               |
| Compression method                                | LZMA2                               | `7zMethod=LZMA2`                                                                                       | LZMA2 (recommended), LZMA, PPMd, BZip2                                                                                                                                                                                                                                        |
| Dictionary size / Word size                       | default                             | `7ZdictSize<method>_<rate>` (`>0` MB, `<0` kB, `0` default), `7ZwordSize<method>_<rate>` (`0` default) | Defaults depend on method **and** rate. After Apply, values are stored **per method and rate**. Higher values usually compress better but use more memory and time.                                                                                                           |
| Create solid archive                              | on                                  | `7zSolid=1`                                                                                            | All files compressed as one stream: better ratio, but extracting single files and updating are slower                                                                                                                                                                         |
| Solid block size                                  | 16384 M (default for LZMA2, rate 6) | `7zSolidSize<method>_<rate>` (MB)                                                                      | Smaller blocks: slightly bigger archive, faster single-file extraction and update                                                                                                                                                                                             |
| Number of CPU threads                             | 2                                   | `7zThreads=2`                                                                                          | More threads are faster and use more memory                                                                                                                                                                                                                                   |
| Memory usage: for compression / for decompression | 682 M / 66 M (with the defaults)    | —                                                                                                      | Live estimate. 32-bit processes are limited to 2 GB in total; if allocation fails there is an error and the dictionary size or thread count must be reduced.                                                                                                                  |
| Also encrypt names                                | off                                 | `7ZencryptNames=0`                                                                                     | In encrypted archives, names and attributes are encrypted too, so the password is needed even to list the archive                                                                                                                                                             |

_Basis: observed under Wine; help: dlg_internal7zipconfig, inisettings3._

---

## 27. Misc

Confirmations, keyboard remapping and sounds.

```text
Get confirmation before
 [x] Deleting non-empty directories
 [x] Overwriting files
 [x] Overwriting/Deleting read-only files
 [x] Overwriting/Deleting hidden/system files
 [x] Drag&Drop (copying files with mouse)
 [x] Drag&Drop to the 'F8 Delete' button
Redefine hotkeys (Keyboard remapping)
 (o) Hotkey: [▼] [ ]Ctrl+ [ ]Alt+ [ ]Shift+ [ ]Win+ [key ▾]
 ( ) Alias:  [                      ▾]
 Command:    [Default command (no remapping)       ] [🔍] [✓]
 Parameters: [                                      ]
Custom sounds
 [Configure]     [ ] Only play for long operations: > [10] s
```

### 27.1 Get confirmation before

All keys are in `[Confirmation]`; every confirmation is on by default (maximum safety).

| Control                                  | Default | Key                            | Asks…                                                                                                                  |
| ---------------------------------------- | ------- | ------------------------------ | ---------------------------------------------------------------------------------------------------------------------- |
| Deleting non-empty directories           | on      | `deleteDirs=1`                 | Once **per non-empty folder** before deleting it with its content                                                      |
| Overwriting files                        | on      | `OverwriteFiles=1`             | On every name collision during copy, move or rename (07 › Name collisions: the Overwrite dialog)                       |
| Overwriting/Deleting read-only files     | on      | `OverwriteReadonly=1`          | A **second** time, for read-only targets of overwrite, rename or delete                                                |
| Overwriting/Deleting hidden/system files | on      | `OverwriteHidSys=1`            | A **second** time, for hidden or system targets (e.g. the swap file)                                                   |
| Drag&Drop (copying files with mouse)     | on      | `MouseActions=1`               | With the copy/move dialog after a drop; off = dropped files are copied or moved immediately, without the target dialog |
| Drag&Drop to the 'F8 Delete' button      | on      | `MouseDelete=1`                | Before deleting files dropped on the F8 button                                                                         |
| (ini only)                               | —       | `OverwriteHidSysNotReadonly=0` | Also for hidden/system files that are not read-only (standard copy method only)                                        |
| (ini only)                               | —       | `SyncConfirmOverwrite=1`       | `0` = no overwrite confirmation in Synchronize dirs                                                                    |

The `H0` parameter of `cm_Copy` / `cm_RenMov` ("warn if attribute present") does **not** re-enable a read-only or
hidden/system confirmation switched off here. With the default `VistaDelete=-1`, recycling a read-only file on Windows
11 gave no read-only prompt, only TC's question "Do you really want to move the selected file … to the recycle bin?" (07
› Delete (F8, Del, Shift+F8)).

### 27.2 Redefine hotkeys (Keyboard remapping)

A mapping binds either a **hotkey** or a command-line **alias** to a `cm_` command, an `em_` command, a command with
parameters or an external program, plus optional parameters. The full rules (picking a key, suffix variants, removal,
aliases with `%A`, where redefined keys do not take effect) are in 14 › Redefining hotkeys and aliases; the key notation
in 06 › Redefining keys.

| Control                      | Default                        | Meaning                                                                                                                                                                                                                                                                                                             |
| ---------------------------- | ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Hotkey (radio)               | selected                       | Define a key combination                                                                                                                                                                                                                                                                                            |
| `▼`                          | empty list                     | Lists the hotkeys redefined so far; choosing one loads it for editing                                                                                                                                                                                                                                               |
| Ctrl+ / Alt+ / Shift+ / Win+ | all off                        | Modifiers; Win+key works unless Windows reserves the combination (e.g. Win+E)                                                                                                                                                                                                                                       |
| Key list                     | —                              | F1–F12, A–Z, 0–9, INS, DEL, HOME, END, PGUP, PGDN, SPACE, BACK, TAB, +, -, \*, /, ENTER, ESC, LEFT, RIGHT, UP, DOWN, PAUSE, OEM_., OEM_,, OEM_+, OEM_-, OEM_<\>, OEM_US\`~, OEM_US[{, OEM_US]}, OEM_US\\\|, OEM_US;:, OEM_US'", OEM_US/?, OEM_FR!, Numeric keypad 0–9. `OEM_…` codes depend on the keyboard layout. |
| Alias (radio + combo)        | —                              | A word typed on the command line that runs the command (`RedirectSection` is refused)                                                                                                                                                                                                                               |
| Command + `🔍`               | Default command (no remapping) | `🔍` opens _Choose command_ (14 › The _Choose command_ dialog); its first entry, _Default command (no remapping)_, removes a mapping                                                                                                                                                                                |
| Parameters                   | empty                          | Passed to the command; a suffix variant such as `OPENTABSL` is written as the base command plus the suffix as first token (`L filename.tab`)                                                                                                                                                                        |
| `✓`                          | —                              | Stores the mapping; with an existing mapping selected it shows a red **X** and removes it                                                                                                                                                                                                                           |

The dialog does **not** warn when a hotkey is already used internally. Storage: `[Shortcuts]` `CAS+F2=cm_RenameOnly`
with optional `CAS+F2_params=` (C = Ctrl, A = Alt, S = Shift, in this order), `[ShortcutsWin]` for combinations with the
Windows key (same syntax, no W prefix), `[Alias]` one key per alias (value layout not documented); 19 › `[Shortcuts]`.

### 27.3 Custom sounds

| Control                                | Default | Key              | Meaning                                                                                                                                                                                                                                                                                                                                       |
| -------------------------------------- | ------- | ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Configure                              | —       | —                | Shows "Sounds are configured in Control Panel - Sounds and Multimedia, section 'Total Commander'." (information icon) `[OK] [Cancel]`, then the Windows sound control panel. Its _Total Commander_ section holds the events, which include copy complete, background copy complete, delete complete, packing complete and unpacking complete. |
| Only play for long operations: > [n] s | off, 10 | `SoundDelay=-10` | A sound plays only if the operation took at least n seconds. **A negative value means the checkbox is off**; the absolute value is kept as the threshold.                                                                                                                                                                                     |

With no custom sound defined, background operations that reach the minimum time give a standard beep instead.

_Basis: observed on Windows 11 and under Wine; help: dlg_configconfirmation, dlg_choosecommand,
frequentlyaskedquestions, inisettings2, inisettings3; history._
