# 06: Keyboard

This chapter is the complete default key map of Total Commander 11.58 x64: every key of the main window and the command
line with the internal command it corresponds to, the keys of each tool window and dialog, modifier keys used with the
mouse, the rules that decide which meaning a key has in a given state, and how keys are redefined. The functions
themselves are described in the chapters the tables point to.

**Related:** [02](02-main-window.md) › Command line · [03](03-file-panels.md) › Selection, › Quick search and quick
filter, › Navigation, directory history and hotlist · [04](04-main-menu.md) Main menu ·
[05](05-mouse-context-menus-drag-drop.md) Mouse, context menus, drag & drop · [13](13-configuration-dialog.md) › Misc. ·
[14](14-customisation.md) › Redefining hotkeys and aliases · [17](17-internal-commands.md) Internal commands ·
[18](18-syntax-reference.md) › Hotkey notation

## 1. Notation

### 1.1 How keys are written

| Item           | Convention                                                                                                                                                                                                                                                                                              |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Modifier order | `Ctrl`, `Alt`, `Shift`, `Win`, then the key: `Ctrl+Shift+F5`. `KEYBOARD.TXT` writes some combinations in another order (`SHIFT+CTRL+F5`); the key is the same.                                                                                                                                          |
| Letters        | Written in capitals (`Ctrl+T`) but meaning the plain letter key. Shift is written only when it is part of the combination. In Lister, single letters (`N`, `P`, `Q`, `W` …) are typed without modifiers.                                                                                                |
| Arrows         | `←` `→` `↑` `↓` (`KEYBOARD.TXT`: "left/right", "CURSORDOWN"; menu captions: "Left Arrow")                                                                                                                                                                                                               |
| Numeric keypad | `Num +`, `Num -`, `Num *`, `Num /` are the keypad keys. They are **different keys** from `+ - * /` on the main keyboard. This matters for selection (keypad only), for the `*` prefix in quick search (main keyboard only) and in the hotkey key list, where "Numeric keypad 0–9" are separate entries. |
| `Menu key`     | The context-menu (Apps) key                                                                                                                                                                                                                                                                             |
| `AltGr`        | The right Alt key of most European keyboards. It "works like the combination of CTRL+ALT" (help: dlg_quicksearch).                                                                                                                                                                                      |
| Root key       | `Ctrl+\` on a US keyboard, `Ctrl+<` on most European keyboards                                                                                                                                                                                                                                          |
| `Ctrl Num +`   | The menu caption style for keypad combinations (`Select All\tCtrl Num +`, `Alt Num +`); it means `Ctrl+Num +`. The caption is display text only (14 › Main-menu files (`.MNU`)).                                                                                                                        |

### 1.2 The internal-command column

`cm_Name (number)` as in `totalcmd.inc` (17). A plain entry means that a source ties the key to that command: the menu
item printing the shortcut runs it, the help names it for the key, or the command description names the key or matches
the `KEYBOARD.TXT` text word for word. **≈** means the command was matched by its description only; the key's built-in
handling may differ in detail. **—** means built-in behaviour that is not a separate command.

### 1.3 Modifier semantics that apply everywhere

- **Shift as "the other way":** Shift inverts a configured choice. Examples: delete to the recycle bin ↔ delete directly
  (`Shift+F8`), the F3 viewer method (`Shift+F3`), the Num + files/folders choice (`Shift+Num +`), the ZIP open method
  (`Shift+Enter`), _Show as menu_ on a sub-bar button (Shift+click).
- **Shift as "in a new tab":** Shift with a drive selection, a hotlist entry, Go to file / Feed to listbox, and
  `Shift+Enter` in the history list (§3, §4).
- **Alt** = the alternative command of the same F-key (Alt+F3 other viewer, Alt+F5 pack, Alt+F7 find) or a
  left/right-specific variant (Alt+F1/F2, Alt+F11/F12).
- **Ctrl+F1…F12** = view, sort and filter commands of the source panel. Every `cm_Src…` command also exists as
  `cm_Left…` / `cm_Right…` for user hotkeys (17).

_Basis: KEYBOARD.TXT, WCMD_ENG.MNU, totalcmd.inc; help: keyboard, dlg_quicksearch, dlg_configquicksearch,
dlg_configconfirmation._

## 2. Main window

"Panel" is the active (source) file list. "Command line" is the edit field below the panels. A key listed here works in
the panel unless the notes say otherwise. §5 explains what changes when the command line has the focus or a quick search
is open.

### 2.1 Function keys F1–F12, all documented combinations

| Key                     | Action                                                                                 | Internal command                           | Notes / conditions                                                                                                                                                                                 |
| ----------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| F1                      | Help (index)                                                                           | cm_HelpIndex (610)                         | Help › Index. In dark mode `totalcmddark.chm` is opened instead if it exists next to `totalcmd.chm`.                                                                                               |
| Shift+F1                | Custom columns view menu                                                               | cm_SrcCustomViewMenu (270)                 | Show › Custom Columns Mode                                                                                                                                                                         |
| Ctrl+F1                 | Brief view (file names only)                                                           | cm_SrcShort (301)                          |                                                                                                                                                                                                    |
| Ctrl+Shift+F1           | Thumbnails view                                                                        | cm_SrcThumbs (269)                         |                                                                                                                                                                                                    |
| Alt+F1                  | Open the **left** drive list                                                           | cm_LeftOpenDrives (131)                    | Always the left panel, whichever panel is active; the current entry is highlighted (list content: §4.21). Inside the Alt+F10 tree dialog it opens that dialog's drive combo.                       |
| F2                      | Reread the source directory                                                            | cm_RereadSource (540)                      | Same as Ctrl+R. Also removes a quick filter, leaves branch view / fed search results, and refreshes the FTP listing cache.                                                                         |
| Shift+F2                | Compare directories ("Compare file lists")                                             | cm_CompareDirs (533)                       | Marks newer and missing files in both panels (09 › Compare directories and Mark newer)                                                                                                             |
| Ctrl+F2                 | Full view (all file details)                                                           | cm_SrcLong (302)                           |                                                                                                                                                                                                    |
| Ctrl+Shift+F2           | Comments view                                                                          | cm_SrcComments (300)                       | New comments are created with Ctrl+Z                                                                                                                                                               |
| Alt+F2                  | Open the **right** drive list                                                          | cm_RightOpenDrives (231)                   | As Alt+F1, for the right panel                                                                                                                                                                     |
| F3                      | View (Lister or the external viewer)                                                   | cm_List (903)                              | `[Configuration] Viewertype`: 0 internal, file under cursor; 1 internal, selected files (default); 2 external. The F3 button follows the same setting (10 › Entry points for viewing and editing). |
| Shift+F3                | View with the **other** internal method                                                | ≈ cm_ListOnly (2934) / cm_ListMulti (2935) | With the default setting: "List only file under cursor, when multiple files selected". Several files are possible only in the internal viewer.                                                     |
| Ctrl+F3                 | Sort by name                                                                           | cm_SrcByName (321)                         |                                                                                                                                                                                                    |
| Alt+F3                  | Use the alternate viewer (external if F3 is internal, internal if F3 is external)      | ≈ cm_ListExternal (3026)                   | `[Extensions]` per-extension viewers, then Windows quick view, then the default viewer; `Viewer=none` = internal (10 › External viewer (Alt+F3) and viewer associations)                           |
| Alt+Shift+F3            | Lister with the internal viewer only (no plugins, no multimedia)                       | cm_ListInternalOnly (1006)                 |                                                                                                                                                                                                    |
| F4                      | Edit                                                                                   | cm_Edit (904)                              | `[Configuration] Editor=` (default `notepad.exe`). In archives the file is unpacked, edited and re-packed if changed.                                                                              |
| Shift+F4                | Create a new text file and load it into the editor                                     | cm_EditNewFile (2931)                      | Also in archives, on FTP and in file-system plugins. `EditNewName=` gives the name proposed when the cursor is on a folder (07 › New file (Shift+F4)).                                             |
| Ctrl+F4                 | Sort by extension                                                                      | cm_SrcByExt (322)                          |                                                                                                                                                                                                    |
| Alt+F4                  | Exit, or minimise                                                                      | cm_Exit (24340)                            | Files › Quit. Minimises instead when the `MinimizeOnClose` sum includes 2. Shift, or Files › Quit, always closes.                                                                                  |
| F5                      | Copy                                                                                   | cm_Copy (905)                              | Archive as source → Unpack dialog; open archive as target → Pack dialog; FTP → upload/download (07 › Copy (F5) and its variants)                                                                   |
| Shift+F5                | Copy (with rename) within the same directory                                           | cm_CopySamePanel (3100)                    | Several files: option _Rename each file separately_. `CopyStayOnFile`, `RenameSelOnlyName` apply.                                                                                                  |
| Ctrl+F5                 | Sort by date/time                                                                      | cm_SrcByDateTime (324)                     |                                                                                                                                                                                                    |
| Ctrl+Shift+F5           | Create shortcuts of the selected files in the target directory                         | cm_CreateShortcut (1004)                   | Dialog `Create shortcut of "<name>" as` with the target path and the name, the extension replaced by `.lnk`; `AppendLnk` controls the name (07 › Create shortcut (Ctrl+Shift+F5))                  |
| Alt+F5                  | Pack the selected files                                                                | cm_PackFiles (508)                         |                                                                                                                                                                                                    |
| Alt+Shift+F5            | Move to archive (pack, then delete)                                                    | cm_MoveToArchive (2956)                    | Pack dialog with _Move to archive_ checked                                                                                                                                                         |
| F6                      | Rename or move                                                                         | cm_RenMov (906)                            | `totalcmd.inc` also lists cm_MoveOnly (1005) with the description "Move (F6)". Not available inside archives.                                                                                      |
| Shift+F6                | Rename in the same directory                                                           | cm_RenameOnly (1002)                       | One item: in-place rename (§4.20). Several: wildcard dialog with _Rename each file separately_. Inside ZIP files a single item can be renamed.                                                     |
| Ctrl+F6                 | Sort by size                                                                           | cm_SrcBySize (323)                         |                                                                                                                                                                                                    |
| Alt+F6                  | Unpack the specified files from the archive under the cursor, or the selected archives | cm_UnpackFiles (509)                       | Same as Alt+F9 (`KEYBOARD.TXT`: "use Alt+F9 on Windows 95")                                                                                                                                        |
| F7                      | Create directory                                                                       | cm_MkDir (907)                             | The name under the cursor is offered as the default (07 › New folder (F7, Shift+F7))                                                                                                               |
| Shift+F7                | Create directory in the **target** panel, with the name under the cursor as default    | cm_MkDirOther (911)                        |                                                                                                                                                                                                    |
| Ctrl+F7                 | Unsorted                                                                               | cm_SrcUnsorted (325)                       |                                                                                                                                                                                                    |
| Alt+F7                  | Find Files                                                                             | cm_SearchFor (501)                         | Opens on the General tab with _Search in_ pre-filled with the current path                                                                                                                         |
| Alt+Shift+F7            | Find Files in a separate process                                                       | cm_SearchStandalone (545)                  | Title "Find Files (separate)"                                                                                                                                                                      |
| F8 (or Del)             | Delete: to the recycle bin or directly, according to the configuration                 | cm_Delete (908)                            | Configuration › Copy/Delete _F8/DEL deletes to recycle bin (SHIFT=directly)_ (`UseTrash=1`). Inside archives always direct (07 › Delete (F8, Del, Shift+F8)).                                      |
| Shift+F8 (or Shift+Del) | Delete the other way: directly, or to the recycle bin if the option is off             | cm_Delete (908) + Shift                    | The same command; the Shift state flips the method                                                                                                                                                 |
| Ctrl+F8                 | Directory tree in the panel                                                            | cm_SrcTree (303)                           |                                                                                                                                                                                                    |
| Ctrl+Shift+F8           | Cycle the separate tree: one tree, two trees, off                                      | cm_SwitchSeparateTree (3203)               | Show › Separate Tree (the popup carries the shortcut)                                                                                                                                              |
| Alt+F8                  | Command-line history list                                                              | cm_ShowCmdLineHistory (3023)               | Same as Ctrl+↓ in the command line (§2.7)                                                                                                                                                          |
| F9                      | Activate the menu "above the source window (left or right)"                            | —                                          | The wording comes from the old-style menu, which had separate Left and Right menus (help: add_menu). Also one of the ways to reach the menu when Alt+letters is the quick-search key.              |
| Ctrl+F9                 | Print the file under the cursor with its associated program                            | cm_PrintFile (504)                         | Files › Print › File contents                                                                                                                                                                      |
| Alt+F9                  | Unpack (same as Alt+F6)                                                                | cm_UnpackFiles (509)                       | The shortcut the menu prints (Files › Unpack Specific Files)                                                                                                                                       |
| Alt+Shift+F9            | Test archives for integrity                                                            | cm_TestArchive (518)                       |                                                                                                                                                                                                    |
| F10                     | Activate the left menu, or leave the menu                                              | —                                          | Similar command: cm_FocusMainMenu (4011)                                                                                                                                                           |
| Shift+F10               | Context menu of the selection / item under the cursor                                  | cm_ContextMenu (2500)                      | Also the Menu key. On Windows 11: the classic shell context menu with TC's items merged (05 › File and folder context menu)                                                                        |
| Ctrl+F10                | Show all files                                                                         | cm_SrcAllFiles (312)                       | Also clears an active quick filter                                                                                                                                                                 |
| Alt+F10                 | Directory tree dialog (CD tree)                                                        | cm_CDtree (500)                            | While the tree cache is built: "Reading directories: N (Esc to abort)" (12 › Directory Tree dialog)                                                                                                |
| Ctrl+F11                | Show only programs                                                                     | cm_SrcExecs (311)                          | `*.exe *.com *.bat *.pif *.cmd` (03 › Show files of type)                                                                                                                                          |
| Alt+F11                 | Open the **left** current-directory bar (breadcrumb bar)                               | ≈ cm_LeftPathFocus (132)                   | Keys inside the bar: §4.15                                                                                                                                                                         |
| Alt+Shift+F11           | Focus the horizontal button bar                                                        | cm_FocusButtonBar (4004)                   | The help names the command for this key. Keys inside: §4.16                                                                                                                                        |
| Ctrl+F12                | Show user-defined file types                                                           | cm_SrcUserDef (314)                        | Show › Custom…                                                                                                                                                                                     |
| Alt+F12                 | Open the **right** current-directory bar (breadcrumb bar)                              | ≈ cm_RightPathFocus (232)                  |                                                                                                                                                                                                    |
| Alt+Shift+F12           | Focus the vertical button bar                                                          | cm_FocusButtonBarVertical (4012)           |                                                                                                                                                                                                    |

No source gives a default for plain **F11** or **F12**, nor for Shift+F9, Shift+F11, Shift+F12 or any combination not in
the table. Such keys are free for `[Shortcuts]`.

### 2.2 Function-key overview

| Key | Plain                  | Shift                | Ctrl               | Alt              | Ctrl+Shift          | Alt+Shift              |
| --- | ---------------------- | -------------------- | ------------------ | ---------------- | ------------------- | ---------------------- |
| F1  | Help                   | Custom columns menu  | Brief              | Left drive list  | Thumbnails          |                        |
| F2  | Reread                 | Compare dirs         | Full               | Right drive list | Comments            |                        |
| F3  | View                   | View, other method   | Sort name          | Alternate viewer |                     | Lister, no plugins     |
| F4  | Edit                   | New text file        | Sort ext.          | Exit             |                     |                        |
| F5  | Copy                   | Copy in same dir     | Sort date          | Pack             | Create shortcuts    | Move to archive        |
| F6  | Rename/Move            | Rename in place      | Sort size          | Unpack           |                     |                        |
| F7  | New folder             | New folder in target | Unsorted           | Find             |                     | Find, separate process |
| F8  | Delete                 | Delete other way     | Tree               | Cmd-line history | Cycle separate tree |                        |
| F9  | Menu (source side)     |                      | Print file         | Unpack           |                     | Test archives          |
| F10 | Left menu / leave menu | Context menu         | All files          | Tree dialog      |                     |                        |
| F11 |                        |                      | Programs           | Left breadcrumb  |                     | Focus button bar       |
| F12 |                        |                      | User-defined types | Right breadcrumb |                     | Focus vertical bar     |

### 2.3 Navigation

| Key                            | Action                                                                                                                                                                                                                                                                                                                                         | Internal command                                   | Notes / conditions                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ↑ / ↓                          | Move the cursor bar one line                                                                                                                                                                                                                                                                                                                   | —                                                  | Also while the command line has the focus, the panel cursor bar moves. `ScrollingTopMargin` / `ScrollingBottomMargin` (default 4) keep extra lines visible.                                                                                                                                                                                                                                                                                                                                                                                                      |
| PgUp / PgDn                    | Move one page                                                                                                                                                                                                                                                                                                                                  | —                                                  | Named as keyboard scrolling keys in Configuration › Operation                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Home / End                     | Cursor to the first / last entry                                                                                                                                                                                                                                                                                                               | —                                                  | End observed. Home not observed (unverified); the change log names Shift+Home as a selection key in the file list (§2.4). `cm_GoToFirstEntry` (2049) and `cm_GoToLast` (2057) exist without a default key.                                                                                                                                                                                                                                                                                                                                                       |
| ← / →                          | Full view (and the other one-column views): move the caret **in the command line**, even from the panel. **Brief view**: move the panel cursor between columns.                                                                                                                                                                                | —                                                  | In Brief view, `Shift+←/→` moves the caret in the command line instead. Thumbnails view is not mentioned in the help. `SpecialCursorMovement` (default 0) changes ←/→ in the panel, as a sum: 1 = ← to the first file, → to the last; 2 = ← one directory up, → opens the directory/archive under the cursor; 4 = override the horizontal scrollbar in custom columns view (without it the cursor jumps to the first file only when the scrollbar is already leftmost, otherwise the keys scroll the list); 8 (with 1) = one page up/down instead of first/last. |
| Enter                          | Open the folder or archive, run the program, open the file with its associated program, or **execute the command line if it is not empty**                                                                                                                                                                                                     | ≈ cm_Return (1001)                                 | On an entry inside an archive: shows information on the packed file (property sheet with _Unpack and Execute_ when `[Packer] ExpertMode=0`). `ExecCmdLineFocused=1`: the command line runs only when it has the focus. `RestrictInterface` value 128 disables Enter.                                                                                                                                                                                                                                                                                             |
| Shift+Enter                    | 1. Run the command line or the program under the cursor through the Windows shell; the console window stays open. Needs `noclose.exe` in the TC directory. 2. On a ZIP file: the opposite of the Packer setting (open like a directory ↔ call the associated program). 3. In the history list or the hotlist: open the directory in a new tab. | —                                                  |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| Alt+Enter                      | Properties (system property sheet). On `[..]`: the properties of the current directory.                                                                                                                                                                                                                                                        | cm_VersionInfo (510)                               | Files › Properties. `totalcmd.inc` also has cm_Properties (1003) "Properties dialog". On Windows 11 a file's sheet has the tabs General / Digital Signatures / Security / Details / Previous Versions (07 › Properties (Alt+Enter)). On a file in an archive: packer information, including which plugin opened it. On an FTP panel: Lister with the raw server listing, read from a temporary file such as `%TEMP%\FTP2A7A.tmp` (MLSD lines with UTC times; 11 › Listing: MLSD or LIST, hidden files, raw listing).                                             |
| Alt+Shift+Enter                | Count the contents of all directories in the current directory; sizes replace `<DIR>` in Full view                                                                                                                                                                                                                                             | cm_CountDirContent (2014)                          | Hold Esc to abort. Shown only in Full view. `Everythingforsize=1` uses the Everything tool.                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Backspace, Ctrl+PgUp           | Parent directory (`cd ..`)                                                                                                                                                                                                                                                                                                                     | cm_GoToParent (2002)                               | The cursor lands on the directory just left. At the root of a share it goes up to the server (`\\server\*.*`).                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Ctrl+PgDn                      | Open the directory or archive under the cursor, also self-extracting `.exe`/`.com` archives and unusual extensions                                                                                                                                                                                                                             | cm_GoToDir (2003)                                  | Packer plugins with flag 256 open only this way                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| Ctrl+\ (US), Ctrl+< (European) | Root directory                                                                                                                                                                                                                                                                                                                                 | cm_GoToRoot (2001)                                 | The cursor lands on the directory that was part of the old path. On a tab that is "locked, but directory changes allowed": back to the tab's saved directory (03 › Folder tabs).                                                                                                                                                                                                                                                                                                                                                                                 |
| Ctrl+← / Ctrl+→                | Open the directory or archive under the cursor **in the target panel**. If the cursor is not on a directory, "or the other panel is active", the current directory is shown there instead (= Target=Source).                                                                                                                                   | ≈ cm_TransferLeft (2024) / cm_TransferRight (2025) | Archives: `CtrlArrowOpenArchive=5` (0 never, 1 if Enter would open it as a folder, 2 always except with `ZIPlikeDirectory=0`, 3 always; +4 put the cursor on the file if not opened; +8 respect `PreferOpenTypes`, only with 1).                                                                                                                                                                                                                                                                                                                                 |
| Alt+← / Alt+→                  | Previous / next directory of the visited ones (browser style)                                                                                                                                                                                                                                                                                  | cm_GoToPreviousDir (570) / cm_GoToNextDir (571)    | Commands › Go Back (`Alt+Left Arrow`). Each panel keeps 50 directories (03 › Navigation, directory history and hotlist).                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Alt+↓                          | Directory history list                                                                                                                                                                                                                                                                                                                         | cm_DirectoryHistory (572)                          | Keys inside the list: §4.9                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| Alt+Shift+↓                    | Directory history list without history thinning                                                                                                                                                                                                                                                                                                | cm_DirectoryHistoryNoThinning (575)                |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| Ctrl+D                         | Directory hotlist                                                                                                                                                                                                                                                                                                                              | cm_DirectoryHotlist (526)                          | Keys inside: §4.8                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Tab                            | Switch between the left and right file lists                                                                                                                                                                                                                                                                                                   | ≈ cm_FocusTrg (4006)                               | From the command line: back to the source panel                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| Shift+Tab                      | Switch between the file list and its separate tree                                                                                                                                                                                                                                                                                             | —                                                  | Only when a separate tree is shown. Commands: cm_FocusSrcTree (4009), cm_FocusTrgTree (4010), cm_FocusLeftTree (4007), cm_FocusRightTree (4008).                                                                                                                                                                                                                                                                                                                                                                                                                 |
| Ctrl+I                         | Switch to the target directory                                                                                                                                                                                                                                                                                                                 | ≈ cm_FocusTrg (4006)                               |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |

### 2.4 Selection

"As configured" means Configuration › Operation › _Selection (with Num +)_: `MarkDirectories=1` (default) = files and
folders, `0` = files only. Selection rules in full: 03 › Selection.

| Key                                             | Action                                                                                                                                       | Internal command                                         | Notes / conditions                                                                                                                                                                                                     |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Insert                                          | Toggle the selection of the item under the cursor and move down                                                                              | ≈ cm_Reverse (2938)                                      |                                                                                                                                                                                                                        |
| Space                                           | Toggle the selection like Insert. On an **unselected** directory, also count its contents and show the size instead of `<DIR>` in Full view. | —                                                        | The cursor does **not** move unless `SpaceMovesDown=1`. Size counting can be switched off (Operation › _Calculate space occupied by subdirectories › when selecting with the space bar_). Works on network drives too. |
| Shift+↓ / Shift+↑                               | Toggle the selection of the item under the cursor and move down / up                                                                         | (not recorded)                                           | Shift+↓ pressed 4× from `report_01` selected `report_01`…`report_04` and left the cursor on `report_05`, unselected. Shift+↑ from the change log.                                                                      |
| Shift+Home / Shift+End, Shift+PgUp / Shift+PgDn | Select from the cursor towards the first / last entry, or by a page                                                                          | (not recorded)                                           | Named as selection keys in the change log; the exact range rule was not observed (unverified)                                                                                                                          |
| Num +                                           | Select a group (mask dialog "Expand selection")                                                                                              | cm_SpreadSelection (521)                                 | As configured                                                                                                                                                                                                          |
| Shift+Num +                                     | The same, with the other files/folders choice                                                                                                | ≈ cm_SelectFiles (3312) / cm_SelectBoth (3311)           |                                                                                                                                                                                                                        |
| Num -                                           | Unselect a group ("Shrink selection")                                                                                                        | cm_ShrinkSelection (522)                                 | Always files **and** folders, for safety                                                                                                                                                                               |
| Shift+Num -                                     | Unselect a group, files only                                                                                                                 | cm_ClearFiles (3314)                                     |                                                                                                                                                                                                                        |
| Num *                                           | Invert the selection                                                                                                                         | cm_ExchangeSelection (525)                               | As configured                                                                                                                                                                                                          |
| Shift+Num *                                     | Invert, with the other files/folders choice                                                                                                  | ≈ cm_ExchangeSelFiles (3322) / cm_ExchangeSelBoth (3321) |                                                                                                                                                                                                                        |
| Num /                                           | Restore the selection from before the last file operation                                                                                    | cm_RestoreSelection (529)                                | Every file operation saves the selection first                                                                                                                                                                         |
| Ctrl+Num +, Ctrl+A                              | Select all                                                                                                                                   | cm_SelectAll (523)                                       | As configured. Ctrl+A selected all files **and** folders; `[..]` is never selected.                                                                                                                                    |
| Ctrl+Shift+Num +                                | Select all, with the other files/folders choice                                                                                              | ≈ cm_SelectAllFiles (3302) / cm_SelectAllBoth (3301)     |                                                                                                                                                                                                                        |
| Ctrl+Num -                                      | Unselect all (always files and folders)                                                                                                      | cm_ClearAll (524)                                        |                                                                                                                                                                                                                        |
| Ctrl+Shift+Num -                                | Unselect all files (folders stay selected)                                                                                                   | cm_ClearAllFiles (3304)                                  |                                                                                                                                                                                                                        |
| Alt+Num +                                       | Select all files with the extension of the file under the cursor                                                                             | cm_SelectCurrentExtension (527)                          |                                                                                                                                                                                                                        |
| Alt+Num -                                       | Unselect all files with that extension                                                                                                       | cm_UnselectCurrentExtension (528)                        |                                                                                                                                                                                                                        |

Num + on a panel that shows _duplicate file_ search results opens the "Select duplicate files" dialog instead (§4.4).

### 2.5 Panels, views and windows (keys other than F-keys)

The view, sort and filter keys Ctrl+F1…Ctrl+F12 are in §2.1.

| Key          | Action                                                                       | Internal command            | Notes / conditions                                                                                  |
| ------------ | ---------------------------------------------------------------------------- | --------------------------- | --------------------------------------------------------------------------------------------------- |
| Ctrl+Q       | Quick View panel instead of the other file list                              | cm_SrcQuickView (304)       | Again to close it, or choose another drive in the Quick View panel. Lister keys work inside (§4.1). |
| Ctrl+Shift+Q | Separate Quick View window (Lister that follows the cursor; title `Lister*`) | cm_SeparateQuickView (2941) |                                                                                                     |
| Ctrl+B       | Branch view: the current directory and all subdirectories in one list        | cm_DirBranch (2026)         | Again to leave (§4.12). Esc aborts reading.                                                         |
| Ctrl+Shift+B | Branch view of the selected directories only                                 | cm_DirBranchSel (2046)      |                                                                                                     |
| Ctrl+U       | Exchange the directories of the two panels                                   | cm_Exchange (531)           | With `DirTabFilters=1` the displayed file types are swapped too                                     |
| Ctrl+Shift+U | Exchange directories and tabs                                                | cm_ExchangeWithTabs (535)   |                                                                                                     |
| Ctrl+R       | Reread the source directory                                                  | cm_RereadSource (540)       | Same as F2                                                                                          |

### 2.6 Folder tabs

| Key            | Action                                                                  | Internal command               | Notes / conditions                                                                                                                                                                                                                                                                                               |
| -------------- | ----------------------------------------------------------------------- | ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ctrl+T         | New folder tab with the current directory, activated                    | cm_OpenNewTab (3001)           | With a single tab and the header hidden, Ctrl+T and Ctrl+↑ are the only ways to open tabs                                                                                                                                                                                                                        |
| Ctrl+Shift+T   | New folder tab, not activated                                           | cm_OpenNewTabBg (3002)         |                                                                                                                                                                                                                                                                                                                  |
| Ctrl+↑         | Open the directory or archive under the cursor in a new tab             | cm_OpenDirInNewTab (3003)      | The current tab stays active, unless _Ctrl+Up opens tab in foreground_ is set. Works also on a completely empty drive (no `..`).                                                                                                                                                                                 |
| Ctrl+Shift+↑   | Open the directory under the cursor in a new tab of the **other** panel | cm_OpenDirInNewTabOther (3004) |                                                                                                                                                                                                                                                                                                                  |
| Ctrl+W         | Close the active tab                                                    | cm_CloseCurrentTab (3007)      |                                                                                                                                                                                                                                                                                                                  |
| Ctrl+Shift+W   | Close all tabs                                                          | cm_CloseAllTabs (3008)         | Locked tabs are kept. Asks first if _Confirm close all tabs_ is set.                                                                                                                                                                                                                                             |
| Ctrl+Tab       | Next tab                                                                | cm_SwitchToNextTab (3005)      | _Ctrl+Tab opens as list_ (`DirTabOpenList=1`) makes it act like Ctrl+Shift+A. _Ctrl+Tab switches to last visited_ (`DirTabGotoLastVisited=1`) goes to the last visited tab, and further Tab presses with Ctrl held go on to the right. `TabSwitchMode=0`: the switch happens when Ctrl is released; 1 = at once. |
| Ctrl+Shift+Tab | Previous tab                                                            | cm_SwitchToPreviousTab (3006)  |                                                                                                                                                                                                                                                                                                                  |
| Ctrl+Shift+A   | List of all open tabs as a menu ("as in the Chrome browser")            | cm_SrcTabsList (5515)          | Keys inside: §4.10                                                                                                                                                                                                                                                                                               |

### 2.7 Command line

"If Total Commander is active, nearly all keyboard input is directed to the command line" (`KEYBOARD.TXT`). Execution
rules: 02 › Command line.

| Key                              | Action                                                                                               | Internal command                      | Notes / conditions                                                                                                                                            |
| -------------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Letter (any printable character) | Redirected to the command line; the caret jumps there                                                | —                                     | Not when quick search is set to _Letter only_ or _Letters - with search dialog_ (§2.8). A hidden command line reappears when typing starts.                   |
| Enter                            | Execute the command line if it holds at least one character; otherwise run the item under the cursor | —                                     | `cd`, `md`, `rd` are executed internally; internal DOS commands go to the command interpreter; otherwise a program of that name is started                    |
| Shift+Enter                      | Like Enter, but through the Windows shell; the console window stays open                             | —                                     | Needs `noclose.exe`                                                                                                                                           |
| Ctrl+Enter                       | Append the name of the file under the cursor (source panel) to the command line                      | cm_AddFileNameToCmdline (3021)        |                                                                                                                                                               |
| Ctrl+Shift+Enter                 | Append the file under the cursor **with its path**                                                   | cm_AddPathAndFileNameToCmdline (3022) |                                                                                                                                                               |
| Ctrl+P                           | Copy the current path to the command line                                                            | cm_AddPathToCmdline (2019)            |                                                                                                                                                               |
| Ctrl+↓, Alt+F8                   | Open the list of recent command lines                                                                | cm_ShowCmdLineHistory (3023)          | Inside: ↑/↓ (with or without Ctrl) choose an entry; ← or → closes the list and leaves the entry for editing; Shift+Del removes the highlighted entry          |
| Tab                              | Put the cursor back in the source panel                                                              | —                                     |                                                                                                                                                               |
| ← / →                            | Move the caret in the line (see §2.3 for Brief view)                                                 | —                                     |                                                                                                                                                               |
| ↑ / ↓                            | Move the panel cursor bar, even while the line has the focus                                         | —                                     | `CmdUpDown=0` is described as "Move cursor up/down in file list even if the active window is the command line"; which value is the on state is not documented |
| Esc                              | Clear the command line and put the cursor back in the file list                                      | ≈ cm_ClearCmdLine (2004)              |                                                                                                                                                               |
| Ctrl+Y                           | Clear the command line; the caret stays in it                                                        | ≈ cm_ClearCmdLine (2004)              |                                                                                                                                                               |
| Ctrl+A                           | Select the whole line                                                                                | —                                     |                                                                                                                                                               |
| Ctrl+C / Ctrl+X / Ctrl+V         | Copy / cut the selected text, paste text                                                             | —                                     | Text clipboard, not files (§5.1)                                                                                                                              |
| Ctrl+E                           | Copy the previous command to the command line                                                        | cm_PrevCommand (2006)                 | cm_NextCommand (2005) has **no** default key                                                                                                                  |
| Ctrl+K                           | Delete to the end of the line                                                                        | —                                     |                                                                                                                                                               |
| Ctrl+W                           | Delete the word left of the caret                                                                    | —                                     |                                                                                                                                                               |
| Ctrl+T                           | Delete the word right of the caret                                                                   | —                                     |                                                                                                                                                               |
| Ctrl+← / Ctrl+→                  | Jump by word                                                                                         | —                                     | `CtrlArrow=0` uses the Windows method, 1 the internal one. Stops at extra non-alphanumeric characters.                                                        |

Dropping a file on the command line adds its short (8.3) name; Shift adds the full path. "To add the long name, press
Ctrl+Enter instead" (help: drag_drop).

### 2.8 Quick search and quick filter (triggers in the main window)

The trigger depends on Configuration › Options › Quick Search, stored as `[Configuration] AltSearch`. Matching rules and
the filter itself: 03 › Quick search and quick filter.

| `AltSearch` | Option caption               | Trigger                                                                                                                                                                                                                                              | Menu access                                           |
| ----------- | ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| 0 (default) | Ctrl+Alt+Letters             | **Ctrl+Alt+letter** or **AltGr+letter** opens the quick-search box with that letter. Ctrl and Alt can then be released and the next letters typed plainly.                                                                                           | Alt+letter opens the underlined menu                  |
| 1           | Alt+Letters                  | **Alt+letter** opens the box                                                                                                                                                                                                                         | F9, F10, or Alt pressed and released, then the letter |
| 2           | Letter only                  | Plain letters jump to the next matching name, without a box. Several letters can be typed; they are forgotten after about 1 s. Example: `rep` → `report_01`, `n` → `notes`; Enter then opens the file under the cursor. The setting applies at once. | Alt+letter                                            |
| 3           | Letters - with search dialog | Plain letters open the box. A `*` typed first (main keyboard, not the keypad) searches anywhere in the name.                                                                                                                                         | Alt+letter                                            |
| 4           | Disabled                     | No key opens quick search. Put `cm_ShowQuickSearch` (2915) on a hotkey.                                                                                                                                                                              | Alt+letter                                            |

In modes 2 and 3 letters no longer reach the command line. It is reached with → (Shift+→ in Brief view).

| Key                                 | Action                                                                      | Internal command                                              | Notes / conditions                                |
| ----------------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------- | ------------------------------------------------- |
| Ctrl+Alt+letter(s), AltGr+letter(s) | Quick search for a name starting with the letters, in the current directory | — (cm_ShowQuickSearch 2915 / cm_QuickSearch 3018 for hotkeys) | Mode 0 only. Edit keys inside the box: §4.2.      |
| Ctrl+S                              | Open the quick-filter box and activate the filter                           | cm_QuickFilter (3019)                                         | Inside the box Ctrl+S toggles the filter          |
| Ctrl+Shift+S                        | Open the quick-filter box with the last used filter                         | cm_QuickFilter (3019), parameter 1                            |                                                   |
| Esc                                 | Remove an active filter (after the box is closed)                           | —                                                             | The first Esc closes the box and keeps the filter |
| Ctrl+F10                            | Show all files, which also removes the filter                               | cm_SrcAllFiles (312)                                          |                                                   |
| F2, Ctrl+R                          | Reread, which also removes the filter                                       | cm_RereadSource (540)                                         | A directory change removes it too                 |

### 2.9 Clipboard and file commands

| Key    | Action                                                                            | Internal command             | Notes / conditions                                                                                                                                                     |
| ------ | --------------------------------------------------------------------------------- | ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ctrl+C | Copy the selected files to the clipboard                                          | cm_CopyToClipboard (2008)    | The selection stays. `UseFastCtrlC=1`: the shell context menu is loaded invisibly and its _Copy_ verb used.                                                            |
| Ctrl+X | Cut the selected files to the clipboard                                           | cm_CutToClipboard (2007)     | Same `UseFastCtrlC` rule                                                                                                                                               |
| Ctrl+V | Paste from the clipboard into the current directory                               | cm_PasteFromClipboard (2009) | Goes through the shell copy engine: no TC dialog; a name conflict shows the shell's own replace dialog, not TC's Overwrite dialog (07 › File clipboard and name lists) |
| Ctrl+L | Calculate the occupied space of the selected files (or the item under the cursor) | cm_GetFileSpace (503)        | On a single file it also shows the `Zone.Identifier` stream                                                                                                            |
| Ctrl+M | Multi-Rename Tool                                                                 | cm_MultiRenameFiles (2400)   |                                                                                                                                                                        |
| Ctrl+Z | Edit the file comment                                                             | cm_EditComment (2700)        | On `..`: the comment of the current directory                                                                                                                          |

### 2.10 FTP and connections

| Key          | Action                                                                              | Internal command               | Notes / conditions                                                                                                                        |
| ------------ | ----------------------------------------------------------------------------------- | ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Ctrl+F       | Connect to an FTP server (saved connections)                                        | cm_FtpConnect (550)            |                                                                                                                                           |
| Ctrl+N       | New FTP connection (enter a URL or host address; also HTTP downloads)               | cm_FtpNew (551)                | The "ftp" quick-connect dialog; an anonymous login then asks "Your e-mail address as password:" once                                      |
| Ctrl+Shift+F | Disconnect from the FTP server, a PORT connection, or some file-system plugins      | cm_FtpDisconnect (552)         | The panel returns to the last local directory; a quick-connect session first asks "Current session not saved, save?" (11 › Disconnecting) |
| Ctrl+Shift+M | Change the FTP transfer mode (binary, text/ASCII, automatic)                        | cm_FtpSelectTransferMode (556) | Not possible through an HTTP proxy                                                                                                        |
| F5, then F2  | Copy in the background: adds the job to the last opened background transfer manager | —                              | "F5 - F2" (help: ftp_menu); F2 is the _F2 Queue_ button of the copy dialog                                                                |
| F2, Ctrl+R   | Force a reread of the cached remote listing                                         | cm_RereadSource (540)          |                                                                                                                                           |

`RestrictInterface` value 64 disables FTP, "(CTRL+N, CTRL+F)".

### 2.11 Window, menus and other input

| Key                                   | Action                                                                         | Internal command      | Notes / conditions                                                                                                |
| ------------------------------------- | ------------------------------------------------------------------------------ | --------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Shift+Esc                             | Minimise Total Commander                                                       | cm_Minimize (2000)    |                                                                                                                   |
| Alt+letter                            | Open the main-menu item whose letter is underlined (`&` in the MNU)            | —                     | Not in quick-search mode 1 (§2.8). Alt+F opens the Files menu with the accelerators underlined (04 › Files menu). |
| Alt pressed and released, then letter | Open the menu                                                                  | —                     | The documented menu route in mode 1                                                                               |
| Menu key                              | Context menu (as Shift+F10)                                                    | cm_ContextMenu (2500) |                                                                                                                   |
| Alt+Tab, then Enter                   | Return to TC while it sits in the system tray                                  | —                     | `AltTabWindow=1` creates an invisible helper window. Under WinNT, Enter after releasing Alt.                      |
| Win+Shift+← / →                       | Windows moves the window to another monitor; TC restores its stored size there | —                     | `RestoreSize` bit 4 (WM_MOVE); `RestoreSize=0` prevents it                                                        |
| Esc during a long directory read      | The main window ignores all input except Esc                                   | —                     |                                                                                                                   |

**Media Center remote and multimedia keys** (`[Configuration] MediaRemote`):

| Value | Mapping                                                                                                                                                                                                       |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | Back (`<-`) = Backspace; `i` = directory hotlist; `>\|` = Tab; `\|<` = Ctrl+Tab; Play/Pause = Command menu (`cm_ShowRemoteMenu`, 2930); Stop = Esc in dialogs, select file in lists; plus the browser buttons |
| 0     | Only the browser buttons: backward, forward, refresh, stop, favorites                                                                                                                                         |
| -1    | Ignore all media keys, including the browser buttons                                                                                                                                                          |

`KeyboardID` switches the keyboard layout when TC is activated or an in-place rename ends: 0 = off, 1 = the default
layout of the locale, or a layout ID such as `$0409` (English, QWERTY), `$0407` (German), `$0807` (Swiss German),
`$040C` (French), `$0408` (Greek).

### 2.12 Commands that have no default key

Commands that the sources mention without any default key, so they need a hotkey, button or menu item: `cm_NextCommand`
(2005), `cm_ShowQuickSearch` (2915) (the way to quick search in mode 4), `cm_ZoomIn` (2953) / `cm_ZoomOut` (2954)
(thumbnail zoom; the mouse equivalent is Ctrl+wheel), `cm_MoveTabLeft` (3015) / `cm_MoveTabRight` (3016), `cm_EditPath`
(2912), `cm_FocusCmdLine` (4003), `cm_SrcActivateTab1…` (5001…), `cm_GoToFirstEntry` (2049), `cm_GoToLast` (2057).
`KEYBOARD.TXT` is the complete default map of the main window, so every other command without a row in §2 has no default
key either.

_Basis: KEYBOARD.TXT (complete main-window and command-line list), WCMD_ENG.MNU, totalcmd.inc; observed on Windows 11:
Alt+F1, Alt+F7, Alt+Enter, Alt+F, Ctrl+Shift+F5, Shift+F10, letter-only quick search, the FTP keys; observed under Wine:
End, Shift+↓, Ctrl+A, Ctrl+C/Ctrl+V, Shift+F6; help: keyboard, cmdline, add_cmdline, drag_drop, proc_show, proc_copy,
proc_renmov, proc_mkdir, proc_delete, proc_editnew, packedfiles, options_match, options_versioninfo, go_back,
proc_select, quick_view, options_branch_view, foldertabs, dlg_configfoldertabs, dlg_quicksearch, dlg_configquicksearch,
ftp_menu, add_menu, local_menus, dlg_config2, dlg_configedit, dlg_configcopydelete, add_btnbar, add_curdir, whats_new,
inisettings1–3; change log for Shift+↑, Shift+Home/End, Shift+PgUp/PgDn and Ctrl+↑ on empty drives._

## 3. Modifier keys with the mouse

Every mouse gesture whose meaning depends on Ctrl, Alt or Shift is listed in 05: clicks and drags in both selection
models in 05 › Mouse selection modes, gestures on headers, path bar, tabs, buttons, wheels and dialog buttons in 05 ›
Mouse gestures by element, and the drag modifiers (Alt/Shift = move, Ctrl+Shift = shortcut, Space over a tree, Shift on
drop targets) in 05 › Drag & drop. The keyboard equivalents of the "Shift = new tab" gestures are in §2.3 (Shift+Enter)
and §4.8 (Shift + choosing a hotlist entry).

_Basis: help: proc_select, drag_drop, foldertabs; see 05 for the gesture tables._

## 4. Keys in dialogs and tool windows

### 4.1 Lister (F3), Quick View panel, separate Quick View

The Lister window and its menus are described in 10 › The Lister window; its key reference is 10 › Keyboard, mouse and
touch.

#### General

| Key                              | Action                                                                                                                           | Notes                                                                                                                                                                                                                                                                                                  |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| F1                               | Help                                                                                                                             |                                                                                                                                                                                                                                                                                                        |
| F2                               | Reload the file                                                                                                                  | File › Reload file                                                                                                                                                                                                                                                                                     |
| F4                               | Open the file in the editor                                                                                                      | `[Lister] Editor=`, else `[Configuration] Editor=`. Not for temporary (extracted or downloaded) files, nor in Image/Multimedia, Explorer Preview or plugin mode. `[Lister] F4Edit`: 0 ignore, 1 default, 2 also close Lister about 0.5 s later when one file is viewed, 3 the same with several files. |
| F11                              | Toggle the maximised window                                                                                                      |                                                                                                                                                                                                                                                                                                        |
| Alt+Enter                        | Toggle full screen                                                                                                               | In media mode: full-screen playback, also by double click; Esc leaves it                                                                                                                                                                                                                               |
| Ctrl+P                           | Print                                                                                                                            |                                                                                                                                                                                                                                                                                                        |
| Esc, Alt+F4, F10, Q              | Close the Lister window                                                                                                          |                                                                                                                                                                                                                                                                                                        |
| N / P                            | Next / previous file                                                                                                             | File › Next File / Previous. Only when several files were opened; with one file they do nothing                                                                                                                                                                                                        |
| Alt+→ / Alt+←                    | Next / previous file                                                                                                             | As N / P; also the `<<` `>>` items at the right of the menu bar, which show the position, e.g. `<< 1/3 >>` after F3 on 3 selected files                                                                                                                                                                |
| 1 … 8                            | Display mode: 1 Text only, 2 Binary, 3 Hex, 4 Image/Multimedia, 5 HTML text (strip tags), 6 Unicode, 7 UTF-8, 8 Explorer Preview | The Options-menu shortcuts. Pressing **4** again cycles through the matching Lister plugins and the internal viewer, or only through the view methods defined for the file type when two or more are defined.                                                                                          |
| A / S / V                        | ANSI / ASCII (DOS) / Variable char width                                                                                         | Options menu                                                                                                                                                                                                                                                                                           |
| W                                | Wrap text                                                                                                                        | Options menu                                                                                                                                                                                                                                                                                           |
| Shift+F10, Menu key, right click | Context menu                                                                                                                     | Without a selection it opens only on a URL                                                                                                                                                                                                                                                             |

#### Text modes (text, binary, hex, HTML, Unicode, UTF-8)

| Key                                  | Action                                                         | Notes                                                         |
| ------------------------------------ | -------------------------------------------------------------- | ------------------------------------------------------------- |
| F6                                   | Text cursor on/off                                             | `[Lister] Caret`                                              |
| F7, Ctrl+F                           | Find                                                           | The search text history is shared with TC                     |
| F3, F5, Shift+F7                     | Find next                                                      |                                                               |
| Shift+F3, Shift+F5                   | Find previous (always backwards)                               |                                                               |
| Ctrl+F3, Ctrl+F5                     | Reverse the search direction                                   |                                                               |
| Ctrl+A                               | Select all                                                     |                                                               |
| Ctrl+C                               | Copy the selection as text                                     | NUL characters become spaces                                  |
| Ctrl+Shift+C                         | Copy the selection as hexadecimal characters                   | Also in the context menu                                      |
| Arrows, Home, End, PgUp, PgDn, Space | Scroll (text cursor off) / move the caret (text cursor on)     |                                                               |
| Ctrl+Home / Ctrl+End                 | Start / end of the file                                        | Text cursor on                                                |
| Shift+arrows                         | Extend the selection                                           | Text cursor on                                                |
| Ctrl+← / Ctrl+→                      | Previous / next word (cursor on); scroll sideways (cursor off) |                                                               |
| Num + / Num -                        | Font size up / down                                            | Also Ctrl+'+' / Ctrl+'-' and Ctrl+wheel (`[Lister] ZoomFont`) |
| Ctrl+0                               | Reset the font size to the stored size                         |                                                               |
| Ctrl+Right Shift / Ctrl+Left Shift   | Right-align / left-align the text                              | Unicode text, or plain text with Arabic or Hebrew encoding    |

#### Image mode

| Key               | Action                           | Notes                                              |
| ----------------- | -------------------------------- | -------------------------------------------------- |
| Num + / Num -     | Zoom in / out                    | Also Ctrl+wheel, or a click on the percent item    |
| Ctrl+0            | Zoom 100 %                       |                                                    |
| F                 | Fit image to window              | Also enlarges small images; also for video windows |
| L                 | Fit only larger images to window |                                                    |
| C                 | Center images                    | Options menu; in media mode C has another meaning  |
| ← / →             | Scroll the image                 |                                                    |
| Shift+← / Shift+→ | Scroll in smaller steps          |                                                    |

#### Media player mode

| Key                                | Action                                                                             | Notes                                                        |
| ---------------------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| E                                  | Single step (1/10 s steps for audio only)                                          |                                                              |
| C                                  | Show / hide the cover image                                                        |                                                              |
| M                                  | Mute / unmute                                                                      |                                                              |
| ↑ / ↓                              | Volume ±1 %                                                                        |                                                              |
| Ctrl+↑/↓, Shift+↑/↓                | Volume ±10 %                                                                       |                                                              |
| Shift+← / Shift+→, Ctrl+← / Ctrl+→ | Jump back / forward by a small (Shift) or large (Ctrl) step, like the jump buttons | The steps are `PlayDelta0..3` (default −60, −10, +10, +60 s) |
| Ctrl+PgDn / Ctrl+PgUp              | Jump to the next / previous chapter mark                                           |                                                              |
| Alt+Enter, Esc                     | Full-screen playback on / leave it                                                 |                                                              |

**Quick View panel (Ctrl+Q)** is a Lister window, so the Lister keys work while it has the focus (e.g. Ctrl+F or F7 to
search). Ctrl+Q again closes it. **Separate Quick View (Ctrl+Shift+Q)** is a Lister window too; its _Options › Save
position_ stores only the quick-view geometry.

### 4.2 Quick search box

Opened by the trigger of §2.8. While it is open:

| Key                       | Action                                                                 | Notes                                                                                                                                     |
| ------------------------- | ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Letters, digits, `*`, `?` | Extend the search text; the cursor jumps to the **next** matching name | Matching: _Exact name match_ options (03 › Quick search and quick filter). `QuickSearchAllowNoMatch=0` rejects a key that gives no match. |
| ↓ / ↑                     | Next / previous match                                                  |                                                                                                                                           |
| Esc                       | Close the box                                                          | The box also closes when another action starts                                                                                            |
| Ctrl+X / Ctrl+C / Ctrl+A  | Cut / copy / select all in the box                                     | Ctrl+Insert also copies                                                                                                                   |
| Ctrl+V, Shift+Insert      | Paste                                                                  | Processed "as if typed", character by character; stops at the first character that would not match                                        |
| Ctrl+S                    | Filter on / off (§4.3)                                                 |                                                                                                                                           |
| Ctrl+Y, Ctrl+Z            | Clear the search text                                                  |                                                                                                                                           |
| Ctrl+W, Ctrl+Backspace    | Delete the word left of the cursor                                     |                                                                                                                                           |
| Ctrl+T                    | Delete the word right of the cursor                                    |                                                                                                                                           |
| Ctrl+Q                    | Toggle the Quick View panel                                            |                                                                                                                                           |
| ← / →                     | Move inside the box                                                    | Also in Brief view, where they formerly moved between columns (changed in the change log of 09.09.25; not observed)                       |

**In a separate tree pane** quick search behaves differently: **Enter** opens the found directory, **Esc** jumps back to
the previous one, **Insert** stays on the new directory and opens it only if the tree is set to open directories
automatically.

### 4.3 Quick filter

| Key                                      | Action                                                                                                       | Notes                 |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------ | --------------------- |
| Ctrl+S                                   | Open the box in filter mode, or toggle the filter inside the box                                             |                       |
| Ctrl+Shift+S                             | Reopen with the last used filter                                                                             | Re-applies it at once |
| Esc                                      | First press: close the box, the filter stays (filter icon in the status bar). Next press: remove the filter. |                       |
| Ctrl+Y, Ctrl+Z                           | Clear the filter text                                                                                        |                       |
| Ctrl+W                                   | Delete the word left of the cursor                                                                           |                       |
| F2, Ctrl+R, Ctrl+F10, a directory change | Remove the filter                                                                                            |                       |

`QuickSearchAutoFilter` (default 0): 0 = the filter starts off, 1 = typing filters automatically (state saved on exit),
−1 / 2 = always off / on at start, not saved. The investigated installation had `QuickSearchAutoFilter=1` in
`wincmd.ini`.

### 4.4 Find Files (Alt+F7, Alt+Shift+F7)

| Key                                      | Action                                                     | Notes                                                                                                         |
| ---------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Esc                                      | Interrupt a running search                                 | Same as _Cancel_                                                                                              |
| Shift+Del                                | Remove the highlighted entry from the _Search for_ history |                                                                                                               |
| Ctrl+C (in the result list)              | Copy the whole result list to the clipboard                |                                                                                                               |
| F3 / F4                                  | View / edit the selected result                            | The _F3 View_ / _F4 Edit_ buttons                                                                             |
| F2                                       | _F2 Search in found files_ checkbox                        | Restricts the next search to the shown results                                                                |
| Shift + _Go to file_ / _Feed to listbox_ | Open in a new tab                                          |                                                                                                               |
| Ctrl+↑ / Ctrl+↓ (Plugins tab)            | Move a rule row up / down                                  |                                                                                                               |
| Num + (panel with fed duplicate results) | "Select duplicate files" dialog                            | In its folder list on the page "Select by folder", Shift+click and Shift+↑/↓ select a range and Space toggles |

Dialog and results: 09 › Find Files.

### 4.5 Multi-Rename Tool (Ctrl+M)

| Key                             | Action                                                               | Notes                                                |
| ------------------------------- | -------------------------------------------------------------------- | ---------------------------------------------------- |
| F2                              | _F2 Load/save settings_ list                                         |                                                      |
| F5                              | Load the rename results for the next rename step                     | The `↻` button                                       |
| F10                             | Name-list menu: Load names from file / Edit names / Configure editor |                                                      |
| Shift+↑ / Shift+↓ (result list) | Move the item up / down (changes the counter order)                  | Drag & drop works too                                |
| Del (result list)               | Remove the file from the rename set                                  |                                                      |
| Shift+Del                       | Remove the highlighted entry from a field history                    |                                                      |
| `1`                             | Toggle _1x_ (replace only the first occurrence)                      | Accelerator of the checkbox (change log: hotkey "1") |

To separate several search/replace strings, type the vertical line (the help gives Alt+124 as the way to type it).
Dialog: 09 › Multi-Rename Tool.

### 4.6 Synchronize directories

The row context menu prints most of these keys.

| Key                                       | Action                                                                                                        | Notes                                                                                                                              |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Ctrl+Shift+L                              | Show button: copy left → right                                                                                | Toggles; works everywhere in the window, also before comparing, except in the path edit boxes                                      |
| Ctrl+Shift+E                              | Show button: equal files                                                                                      | As above                                                                                                                           |
| Ctrl+Shift+N                              | Show button: not equal                                                                                        | As above                                                                                                                           |
| Ctrl+Shift+R                              | Show button: copy right → left                                                                                | As above                                                                                                                           |
| Ctrl+Shift+D                              | Show button: duplicates                                                                                       | As above                                                                                                                           |
| Ctrl+Shift+S                              | Show button: singles                                                                                          | As above                                                                                                                           |
| F2                                        | List of saved synchronize settings                                                                            |                                                                                                                                    |
| Ctrl+D                                    | Mark for copying (default direction)                                                                          | Acts on all selected rows                                                                                                          |
| Ctrl+M                                    | Unmark for copying                                                                                            |                                                                                                                                    |
| Ctrl+L / Ctrl+R                           | Mark for copying left → right / right → left                                                                  |                                                                                                                                    |
| Ctrl+W                                    | Mark for copying in reverse direction                                                                         |                                                                                                                                    |
| Ctrl+Alt+L / Ctrl+Alt+R                   | Copy file properties left → right / right → left…                                                             | Timestamp, attributes and/or NTFS permissions only                                                                                 |
| Ctrl+P                                    | Print selected…                                                                                               |                                                                                                                                    |
| Ctrl+F3                                   | Compare left & right (compare by content)                                                                     | Also double click. Works when the file exists on one side only; not on directory rows                                              |
| F3 / Shift+F3                             | View the left / right file                                                                                    |                                                                                                                                    |
| F4 / Shift+F4                             | Edit the left / right file                                                                                    |                                                                                                                                    |
| F6 / Shift+F6                             | Rename the left / right file                                                                                  | File system only; also two slow clicks on the name (`InplaceRenameSync=1`)                                                         |
| Alt+↓ / Alt+Shift+↓                       | Shell context menu of the left / right file                                                                   | Also Alt+Menu key / Alt+Shift+Menu key                                                                                             |
| Alt+Enter / Alt+Shift+Enter               | Properties of the left / right file                                                                           |                                                                                                                                    |
| Ctrl+PgDn / Ctrl+PgUp                     | Jump to the next / previous subdirectory                                                                      |                                                                                                                                    |
| Space / Shift+Space                       | With several rows selected: act on each row separately                                                        |                                                                                                                                    |
| Ctrl+C                                    | Copy the selected lines to the clipboard                                                                      | Shows % done for large lists                                                                                                       |
| Esc                                       | During a comparison: stop it. Otherwise close the window, but only if no row was checked or unchecked by hand | Alt+F4 or the X button during a comparison stop it without closing the window. What Esc does after manual changes is not recorded. |
| Shift + **OK** (Synchronize confirmation) | Delete directly instead of to the recycle bin                                                                 |                                                                                                                                    |

The keys use the state of Ctrl, Alt and Shift at the moment the key is pressed, not when it is released. Window and
rules: 09 › Synchronize directories.

### 4.7 Compare by content

| Key                   | Action                                                           | Mode                        |
| --------------------- | ---------------------------------------------------------------- | --------------------------- |
| Ctrl+C, Ctrl+Insert   | Copy the selected text                                           | Always                      |
| Ctrl+A                | Select all                                                       | Always                      |
| Ctrl+F, F7            | Search (in both files)                                           | Always                      |
| F3                    | Continue the search                                              | Always                      |
| Shift+F3              | Search backwards; the next F3 searches forwards                  | Always                      |
| Ctrl+F3               | Reverse the search direction                                     | Always                      |
| Ctrl+U                | Swap the panels                                                  | Always                      |
| Shift+F10, Menu key   | Context menu                                                     | Always                      |
| Alt+↑ / Alt+↓         | Previous / next difference                                       | Always                      |
| F6                    | Edit mode on / off                                               | Always                      |
| F9                    | Two-line list on / off                                           | Always                      |
| Ctrl+Tab              | Main panel ↔ two-line list                                       | Always                      |
| Esc, Alt+F4           | Close the window                                                 | Always                      |
| Ctrl+V, Shift+Insert  | Paste                                                            | Edit mode                   |
| Ctrl+S                | Save dialog                                                      | Edit mode                   |
| Ctrl+Z, Alt+Backspace | Undo                                                             | Edit mode                   |
| Ctrl+← / Ctrl+→       | Move the cursor by words                                         | Edit mode                   |
| Alt+← / Alt+→         | Copy the selected text to the left / right panel                 | Edit mode                   |
| Del / Backspace       | Delete the selection or the character right / left of the cursor | Edit mode                   |
| F2 / Shift+F2         | Next / previous difference within a line                         | Edit mode (`CompareF2Mode`) |
| Insert, Space         | Select a line                                                    | Read-only mode              |
| ← / →                 | Scroll by 1 character                                            | Read-only mode              |
| Alt+← / Alt+→         | Scroll by 30 characters                                          | Read-only mode              |

In the two-line list: ←/→, PgUp/PgDn, Home/End and the wheel scroll sideways. Mouse: double click selects a word, triple
click a line (edit mode). Window: 09 › Compare by content.

### 4.8 Directory hotlist (Ctrl+D)

| Key                                    | Action                                                                                               | Notes                                                                                                                                                                                             |
| -------------------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `+` / `-`                              | The _Add/remove current dir_ item: adds the current directory, or removes it if it is already listed | `DirMenuHotkeys=1` (default). Which of the two signs is shown depends on whether the directory is listed (unverified). With `DirMenuHotkeys=0` the letters of the translated menu texts are used. |
| `*`                                    | Configure…                                                                                           | As above                                                                                                                                                                                          |
| Letters                                | Entries whose title contains `&` before a letter                                                     | The `&` makes the next letter the accelerator                                                                                                                                                     |
| Shift+Enter, Shift + choosing an entry | Open the directory in a new tab                                                                      |                                                                                                                                                                                                   |

**Configure dialog ("Change directory menu"):** Shift+↑ / Shift+↓ move the entry under the cursor (drag & drop works
too); a double click on an entry adds or removes the hide character (`?` by default). Editor: 12 › Directory hotlist
editor.

### 4.9 Directory history list (Alt+↓)

| Key                        | Action                                         | Notes                                                     |
| -------------------------- | ---------------------------------------------- | --------------------------------------------------------- |
| ↑ / ↓, Enter               | Choose an entry                                |                                                           |
| Typing                     | Quick search / quick filter on the names       | `QuickSearchHistoryAutoFilter`; Ctrl+S toggles the filter |
| `*` as the first character | Search the whole path instead of the last part |                                                           |
| Shift+Enter                | Open the directory in a new tab                |                                                           |
| Shift+Del                  | Remove the entry from the history              | The context menu has the same item                        |
| Alt+Shift+↓                | Show all entries (no thinning)                 | Also expands _Maximum to show_ to the full list           |
| Ctrl+H                     | Backspace                                      | Other Ctrl+letters do not open quick search here          |

### 4.10 List of open tabs (Ctrl+Shift+A)

| Key                                  | Action                                                | Notes                                                              |
| ------------------------------------ | ----------------------------------------------------- | ------------------------------------------------------------------ |
| Ctrl+Shift+A (again)                 | Switch between showing tab titles and tab directories |                                                                    |
| Ctrl+L                               | Show the most recently visited tabs at the top        | `TabsListLastVisited`                                              |
| Typing                               | Quick search / filter in the list                     | `QuickSearchTabsAutoFilter`; a leading `*` searches the whole path |
| Shift+Enter on a recently closed tab | Restore the tab without focusing it                   |                                                                    |

### 4.11 Thumbnails view

No thumbnail-specific keys are documented. Zoom: Ctrl+mouse wheel (10 %–200 %, 10 % steps), or `cm_ZoomIn` /
`cm_ZoomOut` on a hotkey. The other panel keys apply.

### 4.12 Branch view, search results in the panel

| Key                                     | Action                                                                                                         | Notes                                              |
| --------------------------------------- | -------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| Esc                                     | Abort reading the branch                                                                                       |                                                    |
| Ctrl+B                                  | Leave branch view. On a file in a subdirectory, TC goes to **that** subdirectory, with the cursor on the file. |                                                    |
| Ctrl+Shift+B                            | Branch view of the selected directories                                                                        | Leaving it on `..` restores the original selection |
| F2, Ctrl+R                              | Back to the normal listing of the branch root; also leaves _Feed to listbox_ results                           |                                                    |
| Ctrl+B in search results                | Go to the directory of the file under the cursor                                                               |                                                    |
| Ctrl+↑ / Ctrl+Shift+↑ in search results | New tab; the previous view mode (e.g. Brief) is restored for it                                                |                                                    |

### 4.13 Separate tree and tree view in a panel

| Key                           | Action                                            | Notes                                                                                                                                           |
| ----------------------------- | ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Shift+Tab                     | Between the file list and its separate tree       |                                                                                                                                                 |
| Num + / Num -                 | Expand / collapse the branch                      | Also in the panel tree view (Ctrl+F8)                                                                                                           |
| Shift+F6                      | Rename the directory                              | Separate tree                                                                                                                                   |
| Alt+Enter                     | Properties                                        | Separate tree                                                                                                                                   |
| Shift+F10                     | Context menu                                      | Separate tree; the help lists the right-click context menu among the tree's functions, and Shift+F10 is the general keyboard route (unverified) |
| Ctrl+C / Ctrl+X / Ctrl+V, Del | Copy / cut / paste, delete                        | Separate tree                                                                                                                                   |
| Enter (panel tree view)       | Open the directory in the other panel             | With _Tree: press ENTER to open dir in other window_ (default). Off: the directory opens as the cursor moves.                                   |
| F2, Ctrl+R                    | Rescan a fully loaded tree after external changes |                                                                                                                                                 |

Quick search in the separate tree: §4.2. Trees: 03 › Separate tree, 03 › Tree view inside a panel.

### 4.14 Directory tree dialog (Alt+F10, and the _Tree_ button of Copy/Move/Pack/Unpack)

| Key                            | Action                                                                                      |
| ------------------------------ | ------------------------------------------------------------------------------------------- |
| Alt+F1 / Alt+F2                | Open the drive combo                                                                        |
| Cursor keys                    | Move in the tree                                                                            |
| Enter (or double click, or OK) | Accept: change the source panel (CD tree) or pass the path to the calling dialog            |
| F2, Ctrl+R                     | Re-scan the tree (also when the focus is not on the tree list, like F1)                     |
| Letters                        | Quick search: the cursor goes to the next directory starting with them; `*` and `?` allowed |
| Ctrl+Enter, Ctrl+↓             | Next match                                                                                  |
| Ctrl+↑                         | Previous match                                                                              |
| Esc                            | While the tree is being read ("Reading directories: N (Esc to abort)"): abort               |

Dialog: 12 › Directory Tree dialog.

### 4.15 Current-directory bar (breadcrumb), Alt+F11 / Alt+F12

| Key               | Action                                                                  |
| ----------------- | ----------------------------------------------------------------------- |
| Alt+F11 / Alt+F12 | Put the cursor into the left / right bar                                |
| ← / →, Tab        | Move between the path parts                                             |
| Home / End        | First part (the drive letter) / last part                               |
| Enter, ↓          | Open the directory, or drop down its subdirectory list                  |
| Esc               | Close the list, or leave the bar                                        |
| Enter (edit mode) | Go to the typed path; the box stays open if the path cannot be accessed |

The bar becomes an edit box with a single click outside the path text, or with `cm_EditPath` (no default key). Bar: 03 ›
Current-directory bar (path bar).

### 4.16 Button bars (Alt+Shift+F11 / Alt+Shift+F12)

| Key                                        | Action                                                                            |
| ------------------------------------------ | --------------------------------------------------------------------------------- |
| Cursor keys, Tab / Shift+Tab               | Move between the buttons                                                          |
| Enter                                      | Run the button                                                                    |
| Esc                                        | Leave the bar                                                                     |
| Space, Shift+F10, Menu key                 | The button's context menu                                                         |
| Ctrl+← / Ctrl+→                            | Jump to the button after the next / previous separator, or to the end / beginning |
| Alt+Enter                                  | Open the change dialog for the button                                             |
| Home / End, Enter, Esc on an overflow menu | Navigate in the overflow menu of the vertical bar                                 |

In the _Change button bar_ dialog, Shift+arrow keys move the selected button (14 › Button bars).

### 4.17 Background Transfer Manager

| Key                                                    | Action                                                                                                                 |
| ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------- |
| `+`, Num +                                             | Menu to add jobs: Add URL to download / Add selected items for downloading / for copying / for moving / Edit list file |
| `-`                                                    | Remove the selected queued jobs. With the active job selected: offer to abort it and go on with the next.              |
| Ctrl+V, Shift+Insert                                   | Paste an HTTP URL and download it at once into the active panel's directory                                            |
| Insert, Shift+↑/↓, Shift+Home/End, Ctrl+A, Shift+click | Select several jobs                                                                                                    |

Window: 07 › Background operations.

### 4.18 Copy (F5) and Move (F6) dialogs

| Key                              | Action                                                                                              | Notes                                                                                                            |
| -------------------------------- | --------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| F5 (Copy) / F6 (Move), 2nd press | Select only the file name in the target field, without the path                                     |                                                                                                                  |
| F5 / F6, 3rd press               | Select the name with the extension                                                                  |                                                                                                                  |
| Ctrl+Home                        | Put the caret directly in front of the file name (after the last `\`)                               | Also in the Pack dialog                                                                                          |
| F2                               | _F2 Queue_: add the job to the last opened background transfer manager                              | Right click on the button: move instead of copy (or the reverse)                                                 |
| F7                               | _+ F7_: add the target directory to the target list or remove it; also offers the directory hotlist |                                                                                                                  |
| Alt+↓                            | Open the target list (combobox): saved targets, open tabs, subdirectories of the target panel       | Holding Shift lists the source panel's subdirectories instead; when exactly Shift must be held is not documented |
| F8                               | _+ F8_: define or load a search filter as the copy filter                                           |                                                                                                                  |
| Ctrl+D                           | Directory hotlist inside the dialog                                                                 |                                                                                                                  |

The compact Shift+F5 dialog (copy in the same folder) has no F2 Queue, Options, _+ F7_ or _+ F8_. Dialogs: 07 › Copy
(F5) and its variants.

### 4.19 Overwrite confirmation dialog

| Key                   | Action                                                                                                                                                                                                                          |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Alt+underlined letter | The button: `&Overwrite`, `Overwrite a&ll`, `&Skip`, `&Cancel`, `Overwrite all ol&der`, `S&kip all`, `&Rename`, `A&ppend`, `More Options &>>`. When renaming, the Append button is absent. Default button and focus: Overwrite. |
| F3 / Shift+F3         | View the upper (target) / lower (source) file                                                                                                                                                                                   |
| Alt+F3 / Alt+Shift+F3 | View the file without plugins                                                                                                                                                                                                   |
| Ctrl+F3               | Compare the two files by content                                                                                                                                                                                                |
| Ctrl+Shift+F3         | Use the internal compare tool even if an external one is defined                                                                                                                                                                |

With identical files, _More Options › Compare_ shows only a message box titled "Compare contents" ("The two files have
the same content!") and then returns to the dialog. Dialog: 07 › Name collisions: the Overwrite dialog.

### 4.20 In-place rename (Shift+F6 on one item)

| Key              | Action                                                                                                                                                                                                                |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Shift+F6 (again) | Switch the selection between name only and name+extension. Initial state from `RenameSelOnlyName` (default 0: the whole name with extension is selected first)                                                        |
| Enter            | Rename. Enter (or the small ✓ confirm button at the right end of the edit box, over the Size column) is required; clicking elsewhere outside the edit box cancels. The list re-sorts and the cursor follows the item. |
| Esc              | Cancel                                                                                                                                                                                                                |
| ↑ / ↓            | Jump to the previous / next file; the current file is renamed first if the name was edited                                                                                                                            |
| Ctrl+← / Ctrl+→  | Jump by word; stops at extra non-alphanumeric characters                                                                                                                                                              |

Two slow clicks on a name also start in-place rename (`InplaceRename=1`). Rules: 07 › Rename and move (F6, Shift+F6).

### 4.21 Other dialogs

**Drive list (Alt+F1 / Alt+F2).** Each row shows a letter or character and a description, e.g. on Windows 11:

```text
c                                    (local-disk icon)
d   DVD Drive
+   Computer (drive overview)
*   My Documents (directory)
\   Network Neighborhood
```

A mapped network drive adds a row such as `z  \\localhost\c$\tc-sandbox` (02 › Drive button bar and drive combo box).

| Dialog                                                                                       | Key                    | Action                                                                                                                               |
| -------------------------------------------------------------------------------------------- | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Drive list                                                                                   | Letter                 | Choose that drive                                                                                                                    |
| Drive list                                                                                   | Ctrl+letter            | Choose the **host** drive when a letter is listed twice (terminal server)                                                            |
| Drive list                                                                                   | Shift+F10, Menu key    | Context menu of the drive, directly in the list                                                                                      |
| File comment (Ctrl+Z)                                                                        | F2                     | _F2 OK_: save the comment                                                                                                            |
| File comment                                                                                 | Esc                    | Cancel                                                                                                                               |
| Change attributes                                                                            | F2                     | _F2 Load/save settings_ list                                                                                                         |
| Change attributes                                                                            | Alt+2                  | The _From target (2)_ button: load the attributes from the file under the cursor in the target panel (07 › Change attributes)        |
| Connect to ftp server (Ctrl+F)                                                               | `+` / `-`              | Shortcuts in the connection list (function not documented); ← closes a folder without moving up a line                               |
| Verify checksums                                                                             | Ctrl+↓ / Ctrl+↑        | Next / previous failed file                                                                                                          |
| Verify checksums                                                                             | Ctrl+A                 | Select the whole result list                                                                                                         |
| Verify checksums                                                                             | Ctrl+C                 | Copy the selected lines                                                                                                              |
| Verify checksums                                                                             | Esc                    | Abort, with confirmation                                                                                                             |
| Configuration (Options)                                                                      | Esc                    | Cancel the whole dialog without saving any page (13 › The dialog framework)                                                          |
| Choose command                                                                               | Ctrl+C                 | Copy the command name                                                                                                                |
| Choose command                                                                               | Ctrl+Shift+C           | Copy the whole line with the description                                                                                             |
| Choose command, plugin field picker                                                          | Shift+Home / Shift+End | Supported in the list                                                                                                                |
| Custom columns editor                                                                        | Ctrl+PgUp / Ctrl+PgDn  | Move the column                                                                                                                      |
| Configure Lister › LS-Plugins                                                                | Shift+arrow keys       | Change the plugin order                                                                                                              |
| Configure Lister › view methods by file type                                                 | Space                  | Edit the entry                                                                                                                       |
| Internal associations                                                                        | Shift+cursor keys      | Change the order of the verbs                                                                                                        |
| Change start menu                                                                            | Shift+↑ / Shift+↓      | Move the entry (drag & drop works too)                                                                                               |
| Edit boxes with path auto-complete                                                           | ↑ / ↓, →               | Cycle the suggestions, accept one                                                                                                    |
| Edit boxes with path auto-complete, `AutoCompleteTab` set                                    | Tab, Ctrl+Space        | Cycle the suggestions, accept one (`AutoCompleteTab`: 0 Tab goes to the file list, 1 Tab completes or goes on, 2 Tab only completes) |
| Comboboxes with history (command line, Find, Multi-Rename, Num + mask, Synchronize filter …) | Shift+Del              | Remove the highlighted entry                                                                                                         |
| Windows error box                                                                            | Ctrl+C                 | Copy the message text                                                                                                                |

_Basis: help: listercontents, lister_menufile, lister_menuedit, lister_menuoptions, lister_menupercent,
dlg_listerconfig, quick_view, dlg_quicksearch, dlg_configquicksearch, dlg_search, dlg_searchplugins, dlg_duplicates,
dialog_box___multi_rename_tool, dlg_synchronize_dirs, dlg_synchronize, dlg_compare_contents, dlg_dirmenu,
directoryhotlist, add_hothist, dlg_confighistory, foldertabs, dlg_configthumbs, options_branch_view, show_separatetree,
show_tree, dlg_display, dlg_changetree, add_curdir, add_btnbar, dlg_configbuttonbar,
options_background_transfer_manager, proc_copy, proc_renmov, dlg_overwrite, dlg_edit_comment, dlg_attrib, dlg_verifysfv,
add_drive, dlg_choosecommand, dialog_usercolumns, dlg_usermenu, dlg_config2, updatessupport, whats_new,
what_s_new_continued, inisettings1–3; observed under Wine: Lister menus, the Synchronize row menu, the Overwrite dialog,
in-place rename, the Shift+F5 dialog; observed on Windows 11: Lister N / Alt+→, the drive list, Alt+F10 progress; change
log for the Synchronize Ctrl+C / Esc / modifier rules, Alt+2 and `1`, the FTP list keys, the Background Transfer Manager
selection keys, Ctrl+H in the history, the quick-search ←/→ change, Shift+Home/End in pickers, Shift+cursor in Internal
associations, button-bar Ctrl+←/→, Alt+Enter and the overflow menu._

## 5. Conflicts and context rules

### 5.1 Panel focus versus command-line focus

The command line takes the focus when a printable character is typed (unless a letter quick-search mode is set), when it
is clicked, or through `cm_FocusCmdLine`. In Full view, ← and → already move its caret while the panel has the focus.
**Tab** and **Esc** give the focus back to the panel; **Ctrl+Y** clears the line and keeps the focus in it.

| Key             | Focus in the panel                                                                                                                             | Focus in the command line                                                                         |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Ctrl+A          | Select all files                                                                                                                               | Select the whole line                                                                             |
| Ctrl+C / Ctrl+X | Files to the clipboard                                                                                                                         | Selected text to the clipboard                                                                    |
| Ctrl+V          | Paste files into the current directory                                                                                                         | Paste text                                                                                        |
| Ctrl+T          | New folder tab                                                                                                                                 | Delete the word right of the caret                                                                |
| Ctrl+W          | Close the tab                                                                                                                                  | Delete the word left of the caret                                                                 |
| Tab             | Switch to the other panel                                                                                                                      | Back to the source panel                                                                          |
| ← / →           | Full view: the command-line caret. Brief view: the panel cursor (Shift+←/→ for the caret).                                                     | The caret (Brief view: as in the panel)                                                           |
| ↑ / ↓           | The panel cursor                                                                                                                               | The panel cursor as well                                                                          |
| Enter           | The command line if it holds text, otherwise the item under the cursor. With `ExecCmdLineFocused=1`, the line runs only from the command line. | Execute the line                                                                                  |
| A redefined key | The `[Shortcuts]` command                                                                                                                      | "Some hotkeys like Ctrl+Letter" are not remapped here; the editing keys keep their meaning (§6.1) |

**Not recorded:** what Backspace, Del, Space, Home and End do while the command line holds text but the panel has the
focus. `KEYBOARD.TXT` only says that "nearly all keyboard input is directed to the command line". Sending them to the
command line while it has the focus, and to the panel otherwise, is consistent with the rules above.

### 5.2 Quick search and letters

- **Box open:** the box gets letters, ↑/↓, Esc and its edit keys (§4.2). Any other action closes it.
- **Modes 2 and 3** (letter only, letters with dialog): letters never reach the command line. → (Shift+→ in Brief view)
  gets there. In mode 2 the typed prefix is forgotten after about 1 s.
- **Alt+letter:** in modes 0, 2, 3 and 4 it opens the underlined main-menu item. In mode 1 it starts quick search, and
  the menu is reached with F9, F10, or Alt pressed and released followed by the letter. Alt+Space (the system menu) is
  not intercepted. Alt with non-letter keys (Alt+F-keys, Alt+arrows, Alt+Enter, Alt+Num) keeps its command in every
  mode; the option speaks only of letters.
- **Ctrl+Alt and AltGr:** Windows reports AltGr as Ctrl+Alt, and the help treats AltGr+letter like Ctrl+Alt+letter (mode
  0). What happens on layouts where AltGr+letter produces a character (e.g. `@` on a German keyboard) is not documented
  and was not tested (not recorded); a clone has to choose whether such a combination starts quick search or types the
  character.
- **Keypad versus main keyboard:** only the keypad `+ - * /` select. A leading `*` that means "anywhere in the name" in
  mode 3 must come from the main keyboard.

### 5.3 The same key in different contexts

| Key                               | Main window                                        | Elsewhere                                                                                                                                                                                                                                           |
| --------------------------------- | -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| F2                                | Reread                                             | Copy/Move: _F2 Queue_; Multi-Rename and Attributes: _Load/save settings_; comment dialog: OK; Synchronize: saved settings; tree dialog: rescan; Lister: reload; Compare (edit mode): next difference within the line; Find: _Search in found files_ |
| F3                                | View                                               | Lister, Compare: find next; Overwrite dialog: view the target; Synchronize: view the left file                                                                                                                                                      |
| F5                                | Copy                                               | Copy dialog: select name / name+ext; Multi-Rename: next step; Lister: find next                                                                                                                                                                     |
| F6                                | Rename/move                                        | Move dialog: select name / name+ext; Lister: text cursor; Compare: edit mode; Synchronize: rename the left file                                                                                                                                     |
| F7 / F8                           | New folder / delete                                | Copy dialog: _+ F7_ / _+ F8_; Lister and Compare: F7 = find                                                                                                                                                                                         |
| F9 / F10                          | Menu                                               | Compare: F9 = two-line list; Multi-Rename: F10 = name-list menu; Lister: F10 = close                                                                                                                                                                |
| Shift+F6                          | Rename                                             | In-place rename: toggle the selected part; Synchronize: rename the right file                                                                                                                                                                       |
| Ctrl+F3 / Ctrl+F5                 | Sort by name / date                                | Lister: reverse the search direction; Overwrite dialog and Synchronize: Ctrl+F3 = compare                                                                                                                                                           |
| Num + / Num -                     | Select / unselect group                            | Trees: expand / collapse; Lister: font size or zoom; Background Transfer Manager: Num + = add menu                                                                                                                                                  |
| Ctrl+S / Ctrl+Shift+S             | Quick filter / last filter                         | Compare (edit mode): Ctrl+S = save; Synchronize: Ctrl+Shift+S = _singles_                                                                                                                                                                           |
| Ctrl+D                            | Directory hotlist                                  | Synchronize: mark for copying; Copy dialog: hotlist                                                                                                                                                                                                 |
| Ctrl+L / Ctrl+R / Ctrl+M / Ctrl+W | Occupied space / reread / Multi-Rename / close tab | Synchronize: mark L→R / mark R→L / unmark / reverse; tab list: Ctrl+L = last visited first                                                                                                                                                          |
| Ctrl+U                            | Swap panels                                        | Compare: swap the two files                                                                                                                                                                                                                         |
| Ctrl+Tab                          | Next tab                                           | Compare: main panel ↔ two-line list                                                                                                                                                                                                                 |
| Ctrl+Z                            | Edit comment                                       | Quick search / filter: clear; Compare (edit mode): undo                                                                                                                                                                                             |
| Ctrl+B                            | Branch view                                        | Search results: go to the file's directory                                                                                                                                                                                                          |
| Alt+← / Alt+→                     | Directory history                                  | Lister: previous / next file; Compare: copy the selection to the other side (edit mode) or scroll 30 characters                                                                                                                                     |
| Alt+↓                             | History list                                       | Synchronize: context menu of the left file; Copy dialog: target list                                                                                                                                                                                |
| Alt+Enter                         | Properties                                         | Lister: full screen; button bar: change the button; Synchronize: properties of the left file                                                                                                                                                        |
| Shift+Del                         | Delete the other way                               | Comboboxes and history lists: remove the entry                                                                                                                                                                                                      |
| C (Lister)                        | —                                                  | Image mode: _Center images_; media mode: cover image                                                                                                                                                                                                |
| 4 (Lister)                        | —                                                  | First press: mode 4; further presses: cycle plugins and methods                                                                                                                                                                                     |

### 5.4 Esc

Esc means, depending on the state:

1. Quick-search box open → close it.
2. Quick filter active, box closed → remove the filter.
3. Command line → clear it and return to the panel.
4. A long operation (reading a directory, branch view, Find, the tree cache, Alt+Shift+Enter with the key held) → abort.
5. Lister, Compare, a dialog → close / cancel (Configuration: discard every page).

The order when several states hold at once (e.g. text in the command line **and** an active filter) is not documented
(not recorded). TC also checks the state of the Esc key when an operation starts: if Esc is still down, the operation is
not started ("ESC is pressed - operation aborted!"; 07 › Esc guard).

### 5.5 Who wins between definitions

- A `[Shortcuts]` entry replaces the built-in function of that key in the main window (§6.1).
- Hotkeys that Windows reserves (e.g. Win+E) cannot be assigned, and hotkeys that another program registers system-wide
  never reach TC. The FAQ names GeForce Experience, which takes Alt+F1 and Alt+F5 among others; they are freed in that
  program's own settings (Alt+Z › cog wheel › Keyboard shortcuts).
- Precedence between `[Shortcuts]` and a Start-menu item's _Shortcut key_ is not documented (not recorded).

_Basis: KEYBOARD.TXT; help: cmdline, dlg_quicksearch, dlg_configquicksearch, dlg_configconfirmation,
frequentlyaskedquestions, dlg_usermenu, inisettings1; change log for the Esc-key guard; the context tables combine §2
and §4._

## 6. Redefining keys

### 6.1 Where keys are redefined

Hotkeys are redefined in Configuration › Options › Misc › _Redefine hotkeys (Keyboard remapping)_ (`cm_Confirmation`,
495; 13 › Misc.). The dialog, removing a mapping, aliases, storage, the full list of places where a redefined key does
not take effect, and the commands that read the keyboard state when they run are described in 14 › Redefining hotkeys
and aliases. This section holds the key list and the `wincmd.ini` notation.

In short, for the key map: a `[Shortcuts]` entry replaces the built-in function of the key in the main window, without
any warning when the key is already used internally. Outside the file and tree panels the editing keys (cursor keys,
PgUp/PgDn, Home, End, Del, Backspace, keys that produce a character, Ctrl+C/V/X/Y) keep their meaning, the command line
keeps its own keys (§2.7), and the Quick View panel keeps the Lister keys (§4.1). Other redefined keys, e.g. Ctrl+L or
Ctrl+Alt+Home, work also when the focus is not in a file list (change log 19.06.23, 08.09.23). No remapping exists for
Lister, the dialogs or the tool windows.

### 6.2 Key list of the dialog

```text
(o) Hotkey: [▼] [ ]Ctrl+ [ ]Alt+ [ ]Shift+ [ ]Win+ [key ▾]
```

| Item                     | Rule                                                                                                                                                                                                                                                                                          |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Keys in the list         | F1–F12, A–Z, 0–9, INS, DEL, HOME, END, PGUP, PGDN, SPACE, BACK, TAB, +, -, *, /, ENTER, ESC, LEFT, RIGHT, UP, DOWN, PAUSE, `OEM_.`, `OEM_,`, `OEM_+`, `OEM_-`, `OEM_<\>`, ``OEM_US`~``, `OEM_US[{`, `OEM_US]}`, `OEM_US\|`, `OEM_US;:`, `OEM_US'"`, `OEM_US/?`, `OEM_FR!`, Numeric keypad 0–9 |
| `OEM_…` keys             | The codes depend on the active keyboard layout: `OEM_US[{` is the key labelled `[{` on a US keyboard                                                                                                                                                                                          |
| `+ - * /` and the keypad | The list entries `+`, `-`, `*`, `/` and "Numeric keypad 0–9" are separate from the main-keyboard digits; the keypad digits work as hotkeys only with NumLock on                                                                                                                               |
| Choosing by pressing     | Click the key list twice (it gets the focus and closes), then press the key                                                                                                                                                                                                                   |
| Win+key                  | Allowed unless Windows reserves the combination (e.g. Win+E)                                                                                                                                                                                                                                  |
| Not in the list          | F13–F24: only by editing the ini (§6.3)                                                                                                                                                                                                                                                       |

### 6.3 Hotkey notation in `wincmd.ini`

| Item                 | Rule                                                                                                                                                                                                                                                                                               |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Section              | `[Shortcuts]` "defines keyboard shortcuts replacing the default shortcuts"                                                                                                                                                                                                                         |
| Entry                | `CAS+F2=cm_renameonly` = Ctrl+Alt+Shift+F2 runs `cm_RenameOnly`. Prefix letters **C** = Ctrl, **A** = Alt, **S** = Shift, then `+`, then the key name.                                                                                                                                             |
| Parameters           | A second entry `<same key>_params=`, e.g. `CAS+F2_params=`. Placeholders such as `%P%N` are allowed (18 › Button and command parameters).                                                                                                                                                          |
| Win key              | Section `[ShortcutsWin]`: "Same as [shortcuts], but together with Windows key". There is **no** `W` prefix letter.                                                                                                                                                                                 |
| Subsets of modifiers | The help shows only the full `CAS` form. Writing a subset in the same order (`CS+F7`, `C+Q`) is the natural reading but not stated (unverified).                                                                                                                                                   |
| Key names            | The help shows only `F2`. How the non-letter keys of the key list (§6.2) are spelled in the file is not documented; spellings such as `ADD`, `SUB`, `MUL`, `DIV`, `NUM0`…`NUM9` are unverified. F13–F24 (up to `VK_F24`) are accepted when typed into `[Shortcuts]` by hand (change log 04.10.22). |
| Value                | A `cm_` command, an `em_` user command, a command with parameters (OPENTABS, SELECTFILES, …, also suffix variants such as `SELECTFILEST`, `OPENTABSL`) or an external program. Command names are case-insensitive (`cm_renameonly`).                                                               |
| Redirection          | `[Shortcuts]` and `[ShortcutsWin]` always stay in `wincmd.ini`; `AlternateUserIni=` does not move them.                                                                                                                                                                                            |

The section in the key reference: 19 › `wincmd.ini` reference; the same notation in short: 18 › Hotkey notation
(`[Shortcuts]`).

_Basis: help: dlg_configconfirmation, inisettings, inisettings3; key list observed under Wine; change log as dated._
