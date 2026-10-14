# 05: Mouse, context menus and drag & drop

This chapter describes how Total Commander reacts to the mouse: the two mouse selection modes, a quick reference of
mouse gestures by window element, every context menu of the main window (files and folders including the Windows shell
items, path bar, drives, column header, folder tabs, history list, button bars), the popup menus that are not context
menus, and the drag & drop rules inside TC and with Explorer and other programs. Keyboard equivalents are in chapter 06;
the functions that a menu item or a drop starts are described in their own chapters.

**Related:** [01](01-overview-and-architecture.md) (operand rule), [02](02-main-window.md) (window regions, button
bars), [03](03-file-panels.md) (panel elements, selection), [06](06-keyboard.md) (keys), [07](07-file-operations.md)
(Copy/Move dialogs, delete, file clipboard), [10](10-lister-and-viewing.md) (internal associations),
[13](13-configuration-dialog.md) (Operation and Misc pages), [14](14-customisation.md) (button-bar editor).

## 1. Mouse selection modes

Configuration › Options › Operation › _Mouse selection mode_ chooses between two models (13 › Operation page):

```text
Mouse selection mode
(o) Use right mouse button (as in NC) - context menu after 1 second
( ) Left mouse button (Windows standard)
      [x] Rubber band selection             (enabled only in left-button mode)
[x] By clicking on icon   [ ] Only on touchscreen
```

### 1.1 Right-button mode (default, Norton Commander style)

| Gesture                                                       | Effect                                                                                                                                                                                                                                          |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Left click                                                    | Moves the cursor onto the item and activates the panel. It does not select                                                                                                                                                                      |
| Left double-click                                             | Opens the item: enters a folder or archive, runs a program, opens a file by its association                                                                                                                                                     |
| **Right click**                                               | **Toggles the selection** of the item and moves the cursor onto it. Observed: the item turns red and the footer updates at once (`3,607 k / 3,607 k in 1 / 1 file(s)` for one file; `… 1 / 2 dir(s)` for a folder)                              |
| Right button **held**                                         | Opens the item's context menu (§3) after `PopupDelay=500` ms; the Operation page and the help speak of "about 1 second". `ContextProgress=1` shows a progress bar while the button is held. A shorter click, or a click with drag, only selects |
| Right-drag                                                    | Selects (or deselects) every item the mouse passes over                                                                                                                                                                                         |
| Shift + right click                                           | Selects the range from the last clicked item                                                                                                                                                                                                    |
| Left-drag                                                     | Drag & drop (§6)                                                                                                                                                                                                                                |
| Shift held **before** a right-drag starts                     | Right-button drag & drop with the drop menu (§6.2) instead of selecting                                                                                                                                                                         |
| Touch screen: hold a finger until a square appears, then drag | Selects the files passed over                                                                                                                                                                                                                   |
| Touch screen: long tap, released without dragging             | Context menu                                                                                                                                                                                                                                    |

### 1.2 Left-button mode (Windows standard)

| Gesture                                                  | Effect                                                                                                              |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Left click                                               | Selects the item (as in Explorer) and moves the cursor                                                              |
| Ctrl + left click                                        | Toggles the item's selection                                                                                        |
| Shift + left click                                       | Selects the range from the last clicked item                                                                        |
| Press **behind** the name of an unselected file and drag | **Rubber band**: a rectangle from the start point selects every item it touches (`UseRubberBandSelection=1`, TC 9+) |
| Left-drag on a name or on an already selected line       | Drag & drop (§6). With rubber band on, files must be grabbed by their names                                         |
| Right click                                              | Context menu at once. The focus moves to the clicked item first, so the menu acts on it (also in the separate tree) |
| Right-drag                                               | Drag & drop with the drop menu (§6.2)                                                                               |

### 1.3 In both modes

- **Click on the icon** toggles the item's selection (_By clicking on icon_, `IconClickSelection=1`); a second click
  removes it. With _Only on touchscreen_ (`IconClickSelection=2`) only touch input does this.
- **Single-click opening** (Operation › _Open files and directories with a single click_, `SingleClickStart=0`): `1` a
  single click starts programs and opens files and folders (web style); `2` a single click opens folders only; add `4`
  so that the text cursor no longer follows the mouse.
- The **wheel** scrolls the list.

### 1.4 Settings

| Key (`[Configuration]`)       | Default | Meaning                                                                           | UI                                             |
| ----------------------------- | ------- | --------------------------------------------------------------------------------- | ---------------------------------------------- |
| `UseRightButton`              | 1       | 1 = select with the right button (NC style); 0 = left button (Windows)            | Operation › Mouse selection mode               |
| `UseRubberBandSelection`      | 1       | Rubber band in left-button mode                                                   | Rubber band selection                          |
| `PopupDelay`                  | 500     | Right-button mode: ms until the context menu appears                              | —                                              |
| `ContextProgress`             | 1       | Progress bar while the right button is held                                       | —                                              |
| `IconClickSelection`          | 1       | 1 = a click on the icon selects; 2 = only on a touch screen                       | By clicking on icon / Only on touchscreen      |
| `SingleClickStart`            | 0       | Single-click opening, see §1.3                                                    | Open files and directories with a single click |
| `ExecUseContextMenu`          | 0       | 1 = Enter and double-click open files like the default item of their context menu | —                                              |
| `DropExtensions`              | 1       | Shell drag & drop extensions in the right-button drop menu                        | —                                              |
| `[Confirmation] MouseActions` | 1       | Ask before copying or moving dropped files                                        | Misc › Drag&Drop (copying files with mouse)    |
| `[Confirmation] MouseDelete`  | 1       | Ask before deleting files dropped on _F8 Delete_                                  | Misc › Drag&Drop to the 'F8 Delete' button     |

_Basis: observed on Windows 11 and under Wine (right-click selection, Operation page); help: proc_select, local_menus,
drag_drop, dlg_config2, dlg_configconfirmation, inisettings1–2; change log for PopupDelay, touch and the focus rule._

## 2. Mouse gestures by element

A quick reference. The behaviour behind each gesture is described in the chapter named.

| Element                              | Gesture                                                                        | Result                                                                                                                 | Details                               |
| ------------------------------------ | ------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| File list                            | Click, double-click, right click, drags                                        | See §1                                                                                                                 | 03 › Selection                        |
| File list                            | Wheel                                                                          | Scroll                                                                                                                 | —                                     |
| File list (Thumbnails view)          | Ctrl + wheel                                                                   | Zoom the thumbnails, 10 %–200 % in 10 % steps (`ThumbScaleFactor`)                                                     | 03 › Thumbnails                       |
| File list                            | Pointing at a truncated name about 1 s                                         | Tooltip with the full name, if _Show filename in file list as tooltip if truncated_ is on; a click removes it          | 03 › File list rendering              |
| Column header                        | Click                                                                          | Sort by that column; clicking the sort column again reverses it                                                        | 03 › Column header and sorting        |
| Column header                        | Ctrl + click                                                                   | Add the column as an extra sort key; on a column already used, reverse its direction                                   | 03 › Column header and sorting        |
| Column header                        | Shift + click                                                                  | Add the column as an extra sort key; on a column already used, remove it                                               | 03 › Column header and sorting        |
| Column header                        | Drag a separator                                                               | Move the tabstop (kept after _Configuration › Save Position_)                                                          | 03 › Column header and sorting        |
| Column header                        | Double-click a separator (Full or custom columns view)                         | Fit the column left of it to its widest content                                                                        | 03 › Column header and sorting        |
| Column header                        | Right click                                                                    | View menu (§4.3); on `[Auto]` inside an archive, the encoding menu                                                     | §4.3                                  |
| Path bar                             | Hover                                                                          | The path part under the mouse is underlined; a triangle button appears below it after a delay (not while Ctrl is held) | 03 › Current-directory bar (path bar) |
| Path bar                             | Click an underlined part / the triangle button                                 | Go to that directory / drop down its subdirectories                                                                    | 03 › Current-directory bar (path bar) |
| Path bar                             | Single click outside the path text                                             | Edit the path                                                                                                          | 03 › Current-directory bar (path bar) |
| Path bar                             | Double-click                                                                   | Directory hotlist                                                                                                      | 03 › Directory hotlist                |
| Path bar                             | Right click                                                                    | Context menu of the current directory (§4.1)                                                                           | §4.1                                  |
| Path bar                             | Slow right click (held about 1 s)                                              | Directory history                                                                                                      | 03 › Directory history                |
| `▼` history button                   | Click / Shift + click                                                          | History list / history list without thinning (as Alt+Shift+↓)                                                          | 03 › Directory history                |
| Drive combo, drive buttons           | Click / Shift + click                                                          | Change drive / open the drive in a new folder tab                                                                      | 03 › Drive line                       |
| Drive combo, drive buttons           | Right click                                                                    | Drive context menu (§4.2), also inside the open list                                                                   | §4.2                                  |
| Folder tab                           | Click                                                                          | Activate the tab (and its panel, with _Activate target panel when clicking on one of its Tabs_)                        | 03 › Folder tabs                      |
| Folder tab                           | Ctrl + click, middle click, or double-click (with _Close tab on double click_) | Close the tab                                                                                                          | 03 › Folder tabs                      |
| Folder tab                           | Drag                                                                           | Move the tab, also onto the other panel's tab header                                                                   | 03 › Folder tabs                      |
| Tab header, free space               | Double-click or middle click                                                   | New tab                                                                                                                | 03 › Folder tabs                      |
| Folder tab                           | Right click                                                                    | Tab menu (§4.4)                                                                                                        | §4.4                                  |
| Button bar                           | Click / right click                                                            | Run the button / button menu (§4.6)                                                                                    | 02 › Button bars                      |
| Sub-bar button                       | Shift + click                                                                  | The opposite of its _Show as menu_ setting                                                                             | 14 › The _Change button bar_ dialog   |
| Panel separator                      | Drag / right click                                                             | Move the divider / _Show vertical button bar_ when it is hidden                                                        | 02 › Panel divider                    |
| Function-key bar                     | Click                                                                          | Same as the key                                                                                                        | 02 › Function-key bar                 |
| `Alt+F4 Exit` button                 | Shift + click                                                                  | Really close, even when `MinimizeOnClose` includes 4                                                                   | 02 › Function-key bar                 |
| `F8 Delete` button                   | Right click                                                                    | Recycle Bin menu (§4.8)                                                                                                | §4.8                                  |
| X64/X32 context submenu              | Shift held while opening it                                                    | Shows only _Configure_ (§3.5)                                                                                          | §3.5                                  |
| Files › Pack                         | Ctrl held while choosing it                                                    | The source directory is proposed for the archive                                                                       | 08 › Pack                             |
| Copy / Move dialog                   | Right click on **OK** or **F2 Queue**                                          | A menu with _Move_ (in the Copy dialog) or _Copy_ (in the Move dialog)                                                 | 07 › Copy dialog                      |
| Synchronize confirmation             | Shift + **OK**                                                                 | Delete directly instead of to the recycle bin                                                                          | 09 › Synchronize directories          |
| "Select duplicate files" folder list | Shift + click                                                                  | Select a range                                                                                                         | 09 › Find Files                       |
| Find Files results                   | Shift + _Go to file_ / _Feed to listbox_                                       | Show the result in a new tab                                                                                           | 09 › Find Files                       |
| Lister                               | Ctrl + wheel; Ctrl+Alt + wheel; Shift + wheel                                  | Zoom (font or image); scroll by page; scroll sideways                                                                  | 10 › Lister                           |
| Compare by content                   | Ctrl + wheel                                                                   | Scroll the two-line list at the bottom, even when the mouse is not over it                                             | 09 › Compare by content               |

_Basis: observed on Windows 11 and under Wine for the main gestures; help: add_tabstopheader, add_curdir, add_hothist,
foldertabs, add_buttons, add_btnbar, dlg_configbuttonbar, dlg_contextmenuexts, dlg_pack, proc_copy, dlg_synchronize,
dlg_duplicates, dlg_search, listercontents, inisettings1; change log for the Copy-dialog menu._

## 3. File and folder context menu

### 3.1 Opening it

- `Shift+F10`, the context-menu (Apps) key, or `cm_ContextMenu`;
- in right-button mode, holding the right button on the item (§1.1); in left-button mode, a right click (§1.2).

The menu is the **Windows shell context menu** of the operands (the selected items, or the item under the cursor when
nothing is selected; 01 › The operand rule), with TC's own items merged in. While the menu is open, the item it belongs
to is drawn **red**. The first item, in bold, is the default verb; `ExecUseContextMenu=1` makes Enter and double-click
use it.

### 3.2 Windows 11: file

Shift+F10 on Windows 11 opens the **classic** shell menu (not the compact Windows 11 menu). Observed on a file:

```text
<name>                         <- bold, default verb
Edit
Print
Add to Favorites
Scan with Microsoft Defender...
View (Lister)                  <- TC
Open with                 >
Copy as path
Share
Restore previous versions
------------------------------
Send to                   >
------------------------------
Cut
Copy
Pack files                     <- TC
------------------------------
Create shortcut
Delete
Rename
------------------------------
Properties
```

### 3.3 Windows 11: folder

```text
[<name>]                       <- bold
Open
Open in new process
Pin to Quick access
Open command window here
Scan with Microsoft Defender...
View (Lister)                  <- TC
------------------------------
Give access to            >
Restore previous versions
Include in library        >
Pin to Start
Copy as path
------------------------------
Send to                   >
------------------------------
Cut
Copy
Pack files                     <- TC
------------------------------
Create shortcut
Delete
Rename
------------------------------
Properties
```

All other items come from Windows and the installed shell extensions, so their list depends on the system.

### 3.4 TC's items and rules

- **View (Lister)** opens the operands in Lister (10 › Lister). **Pack files** opens the Pack dialog (08 › Pack).
- **Internal associations** add their verbs (the _Action_ captions) to the menu; with several files selected, the open
  verb uses the first matching association per file, the other verbs come from the first association that matches
  **all** selected files (10 › Internal associations). `cm_ContextMenuInternal` shows a menu with only the
  internal-association items for the selection, `cm_ContextMenuInternalCursor` for the file under the cursor.
- **Cut / Copy** put the files on the clipboard; **Paste** is in the context menu of the target path (§4.1). Clipboard
  rules: 07 › File clipboard.
- `cm_EditFileMenu` shows the shell's _New_ submenu of the context menu directly.
- **In the FTP client** the context menu can add the selected files to the download list for later download (11 ›
  Download later).

### 3.5 X64/X32 submenu and shell-extension configuration

- On 64-bit Windows, **32-bit** TC adds a submenu **"X64"** to the menus of files and folders, so that 64-bit shell
  extensions can be used. **64-bit** TC adds **"X32"** for 32-bit extensions. The menus observed with 64-bit TC on
  Windows 11 had no X32 item; whether it appears when 32-bit shell extensions are installed was not tested.
- `X64menu` switches the submenu on or off (default 1 in the 32-bit version only); `X64WaitTime=15` is the number of
  seconds to wait for the helper `tcmdx64`.
- The submenu holds **Configure**, which opens _Configure context menu shell extensions_:

```text
Available context menu shell extensions:
[ list of the extensions not excluded                         ]
            [ Exclude ]   [ Include ]
Exclude these extensions from the menu:
[ list of the excluded extensions                             ]
                               [ OK ] [ Cancel ] [ Help ]
```

- _Exclude_ moves the extensions selected in the upper list to the lower list; _Include_ moves them back. OK saves,
  Cancel discards.
- The excluded names are stored in `[IgnoreMenuExtensions]`. Fewer extensions make the submenu load faster.
- Holding **Shift** while opening the submenu shows **only** _Configure_. This is the way out when a broken extension
  makes the submenu crash.

### 3.6 When the context menu crashes

When the main context menu or Alt+Enter crashes (FAQ):

1. Disable the non-Microsoft context-menu extensions one by one with ShellExView.
2. For 32-bit TC on 64-bit Windows, tick "Show 32-bit extensions" in ShellExView.
3. Re-enable the harmless ones afterwards.

_Basis: observed on Windows 11 (menus, red item) and under Wine (red item, TC items); help: local_menus,
dlg_contextmenuexts, internal_associations, frequentlyaskedquestions, inisettings2–3._

## 4. Context menus of other elements

### 4.1 Path bar (current directory)

- A right click on the current-directory bar opens the **shell context menu of the current folder itself**: the folder's
  name in bold as the default item, followed by the shell's items (Cut, Copy, Paste when files are on the clipboard,
  Rename, New ▸, Properties and the like). The exact Windows 11 list was not recorded.
- A **slow right click** (held about 1 s) opens the directory history instead (03 › Directory history).

### 4.2 Drive combo box and drive buttons

- A right click on a drive in the drive combo (closed, or directly on an entry of the open list, without switching
  drives first) or on a drive button opens the **shell context menu of the drive root**. On Windows it offers
  formatting, copying disks, sharing the whole disk, Properties and the other shell items.
- `cm_DriveContextMenu` opens it from the keyboard.

### 4.3 Column header

A right click on the header opens the view menu (observed):

```text
Brief                          Ctrl+F1
* Full                         Ctrl+F2      (* = check mark on the current view)
Comments                       Ctrl+Shift+F2
Thumbnail View                 Ctrl+Shift+F1
-------------------------------------------
Configure custom columns...
-------------------------------------------
<user custom-column views, if any>
<custom-column views of the current file-system plugin, if any>
```

- _Configure custom columns..._ opens the Custom columns page (13 › Custom columns page). The view types are described
  in 03 › View types.
- **Inside an archive** the Name header reads `[Auto] Name`, `[Auto]` being the archive's file-name encoding. A left
  click on the header (including `[Auto]`) sorts as usual; a **right click on `[Auto]`** opens the file-name **encoding
  menu** instead (`cm_ChangeArchiveEncoding`): Auto-detect, UTF-8, ANSI and ASCII/DOS (local code page), MacOS, the
  Windows code pages 1250–1258, 936, 950, 932, 949, 874, the DOS code pages, KOI8-R, and _Other (enter code page
  manually)_. Its full two-column layout is in 08 › Archives as folders.

### 4.4 Folder tabs

A right click on a tab (`cm_DirTabsShowMenu` from the keyboard) opens (observed):

```text
Duplicate this tab                       Ctrl+T
Rename/Lock tab
Lock this tab
Locked, but directory changes allowed
-------------------------------------------
Copy tab to other panel
-------------------------------------------
Save tabs to file
Save tabs on both sides to file
Load tabs from file, keep current
Load tabs from file, replace tabs
-------------------------------------------
Close this tab                           Ctrl+W
Close all tabs                           Ctrl+Shift+W
Close duplicate tabs
Show list of all tabs                    Ctrl+Shift+A
-------------------------------------------
Configure view modes
-------------------------------------------
* <default>                              (the view modes; * = current)
```

| Item                                                | Effect (03 › Folder tabs)                                                                                                |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Duplicate this tab                                  | New tab with the same directory in this panel                                                                            |
| Rename/Lock tab                                     | Opens the _Rename_ dialog below                                                                                          |
| Lock this tab                                       | Locked: directory changes open a new tab                                                                                 |
| Locked, but directory changes allowed               | Returns to the saved directory when switching tabs and back, on the root button, or on a click on the already active tab |
| Copy tab to other panel                             | New tab with this directory in the other panel                                                                           |
| Save tabs to file / Save tabs on both sides to file | Write a `.tab` file of this panel / both panels                                                                          |
| Load tabs from file, keep current / replace tabs    | Append / replace from a `.tab` file                                                                                      |
| Close this tab                                      | Closes the tab that was right-clicked                                                                                    |
| Close all tabs                                      | Closes all tabs except locked ones; the current directory is kept                                                        |
| Close duplicate tabs                                | Keeps one tab per directory                                                                                              |
| Recently closed tabs ▸                              | Shown only if a tab has been closed since TC started; reopens those tabs                                                 |
| Show list of all tabs                               | The tab list (as Ctrl+Shift+A)                                                                                           |
| Configure view modes                                | Opens the View Mode page (13 › View Mode page)                                                                           |
| _list of view modes_                                | Switches the tab to that user view mode (03 › View modes)                                                                |

**Rename/Lock tab** opens the dialog "Rename":

```text
New name:
[windows                                    ]
[ ] Lock this tab
[ ] Locked, but directory changes allowed
                               [  OK  ] [ Cancel ]
```

### 4.5 History and hotlist lists

The list opened with the `▼` button (or Alt+↓) has its own context menu. Its functions: open the folder in a new tab, in
the other panel, or both; remove the entry from the history or from the frequently-used list; copy the path to the
clipboard; show all entries when history thinning is on (including folders only passed through); reverse the order
(history at the top or bottom); show or hide the frequently-used list. Exact captions not recorded (03 › Directory
history).

### 4.6 Horizontal button bar

| Where                                                  | Menu (observed)                                                                                                                  |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| Empty area                                             | `Change...` / ── / `Set default icon library`                                                                                    |
| Button that runs an external program (e.g. Notepad)    | `Notepad` (runs the button; the caption is its tooltip) / `As Administrator` / ── / `Change...` / `Delete` / ── / `Cut` / `Copy` |
| Button that runs an internal command (e.g. Search for) | `Search for` (runs it) / ── / `Change...` / `Delete` / ── / `Cut` / `Copy` (no _As Administrator_)                               |

- `Change...` opens the single-button dialog for that button (14 › The single-button dialog; its layout was not
  observed). On empty space it opens _Change button bar_ for the whole bar (14 › The _Change button bar_ dialog).
- `Delete` removes only the button, not the file it points to; the confirmation reads `Delete: Command: <name>` (change
  log).
- `Cut` / `Copy` put the button definition on the clipboard; it can be pasted into another bar or into the editor.
- `Set default icon library` opens the icon-library chooser (02 › Which bar file is loaded).
- Further items (change log; not seen on the default buttons): `cd <path of program>` for a program button whose command
  has a path, and `Edit linked button bar...` for a button that opens another bar.
- From the keyboard the menu opens with Space, Shift+F10 or the context-menu key on a focused button (02 › Using the
  bars).

### 4.7 Vertical button bar and panel separator

| Where                                             | Menu (observed)                                                                          |
| ------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Button                                            | `View with Lister` (runs the button) / ── / `Change...` / `Delete` / ── / `Cut` / `Copy` |
| Empty area (between or below the icons)           | `Change vertical button bar...` / ── / `Hide button bar` / `Set default icon library`    |
| Panel separator, while the vertical bar is hidden | `Show vertical button bar`                                                               |

_Hide button bar_ asks for confirmation before hiding the bar (change log; text not recorded).

### 4.8 F8 Delete button

A right click on `F8 Delete` opens the menu of the **Recycle Bin** (help; not recorded on Windows). The other
function-key buttons have no context menu.

### 4.9 Context menus in tool windows and dialogs

| Where                                                       | Menu                                                                                                                                                                                                                                                            | Details                      |
| ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------- |
| Synchronize directories, result rows                        | Mark for copying (default direction / left to right / right to left / reverse), Unmark, Copy file properties, Print selected, Compare left & right, View/Edit/Rename left or right, left/right context menu and properties, Delete left / right / on both sides | 09 › Synchronize directories |
| Copy (F5) / Move (F6) dialog, right click on OK or F2 Queue | _Move_ / _Copy_                                                                                                                                                                                                                                                 | 07 › Copy dialog             |
| Lister                                                      | Text items such as _Copy as text_, _Copy as hexadecimal_, _Copy URL_, _Open in default browser_ (`[Lister] PopupItems=127`); whether an empty text area has a menu is unverified (A › Artefacts not to copy)                                                    | 10 › Lister                  |
| FTP panel                                                   | Add files to the download list                                                                                                                                                                                                                                  | 11 › Download later          |

### 4.10 Places without a context menu

- The status line (observed).
- The function-key bar, except `F8 Delete` (§4.8) (observed).
- An empty Synchronize-directories result list (observed); a populated list has the menu of §4.9.

_Basis: observed on Windows 11 and under Wine (header, tab, button-bar menus, places without menus); help: local_menus,
add_curdir, add_drive, add_drivebuttons, add_tabstopheader, foldertabs, add_hothist, add_btnbar, add_buttons; change log
for the button-bar items and the Lister menu._

## 5. Popup menus that are not context menus

These open with a left click. They are listed here so that all menus of the window can be found in one place.

| Trigger                                           | Menu                                                                                                                                                      | Details                                 |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| Path bar `▾` (left end)                           | The shell's desktop namespace: Desktop, My Computer ▸ (drives), the recycle bin, Documents ▸ and further virtual folders (the list depends on the system) | 03 › Current-directory bar (path bar)   |
| Path bar `*`                                      | Directory hotlist: the user's entries / ── / `+ Add current dir` / `* Configure...`; heading "Directory hotlist (Ctrl+D)" when opened from the button     | 03 › Directory hotlist                  |
| Path bar `▼`                                      | History: frequently used folders with counts (e.g. `c: 8`, `c:\users 2`) / ── / recently visited folders, the current one marked with a green arrow       | 03 › Directory history                  |
| Drive combo                                       | The drive list (02 › Drive combo box)                                                                                                                     | 02                                      |
| Copy dialog `+ F7` button                         | `Add current dir (Position=0)` / `Directory hotlist (Ctrl+D)`                                                                                             | 07 › Copy dialog                        |
| New-folder and rename `±` button                  | Placeholder menu                                                                                                                                          | 18 › Rename and new-folder placeholders |
| Synchronize dialog folder button                  | `Add current directories and settings to list...` plus the saved sync sets                                                                                | 09 › Synchronize directories            |
| Compare tool `Sync: 1`                            | "Method for comparing text within a line:" options                                                                                                        | 09 › Compare by content                 |
| Multi-Rename list button (F10)                    | `Load names from file...` / `Edit names...` / `Configure editor...`                                                                                       | 09 › Multi-Rename Tool                  |
| Button-bar editor `Change >>`                     | `Insert file name...` / `Insert separator` / `Insert line break` / `Add Subbar >>`                                                                        | 14 › The _Change button bar_ dialog     |
| Button that opens a bar as a menu (`OPENBARMENU`) | The bar's buttons as a drop-down menu (icon size `PopupIconSize`)                                                                                         | 14 › The _Change button bar_ dialog     |
| Vertical-bar overflow button                      | The buttons that do not fit                                                                                                                               | 02 › Vertical button bar                |

_Basis: observed under Wine (popup contents); help: add_hothist, dlg_configbuttonbar._

## 6. Drag & drop

### 6.1 Starting a drag

- Select the files, press the left button on them and move the mouse; a single file can be dragged directly. In
  right-button mode a right-drag selects, so right-button drag & drop needs Shift held **before** the drag starts; in
  left-button mode with rubber band on, files must be grabbed by their names or an already selected line (§1).
- Sources: the file lists (also inside archives, FTP connections and file-system plugins, which can be dragged out to
  the Desktop), the separate tree (to an archive, a file list, the drive button bar and folder tabs), folder tabs (to
  rearrange them).
- The **mouse pointer** shows what will happen:

| Pointer                                                    | Meaning                                                                    |
| ---------------------------------------------------------- | -------------------------------------------------------------------------- |
| Arrow with three small squares                             | The target accepts the files: **copy**                                     |
| Minus sign `-` in the drag cursor                          | **Move**                                                                   |
| Link arrow in the drag cursor                              | **Create shortcuts**                                                       |
| Slashed circle                                             | The target does not accept a drop (wrong program, or wrong file extension) |
| Small arrow in the file symbol, over free tab-header space | The dragged folders become new tabs                                        |

### 6.2 Gestures and modifiers

| During the drop                                                                     | Operation                                                                                                                                                |
| ----------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Left-drag, no modifier                                                              | **Copy**                                                                                                                                                 |
| **Alt** or **Shift** held                                                           | **Move**                                                                                                                                                 |
| **Ctrl+Shift** held                                                                 | **Create shortcuts** of the files (also onto the Desktop or into Explorer)                                                                               |
| Left-drag, press the right button too, then **release the left button first**       | **Move**                                                                                                                                                 |
| Right-drag (left-button mode, or right-button mode with Shift held before starting) | On release a **drop menu** offers copy, move and create shortcut (captions not recorded); shell drag & drop extensions are added when `DropExtensions=1` |
| Right button held while dropping on `F8 Delete`                                     | As Shift + drop: delete directly, bypassing the recycle bin (change log)                                                                                 |

### 6.3 Confirmation

| Setting (Misc page)                                                  | Default | Effect                                         |
| -------------------------------------------------------------------- | ------- | ---------------------------------------------- |
| Drag&Drop (copying files with mouse) (`[Confirmation] MouseActions`) | on      | A drop opens the normal copy/move dialog first |
| Drag&Drop to the 'F8 Delete' button (`MouseDelete`)                  | on      | A drop on _F8 Delete_ asks before deleting     |

- **Inside TC** (confirmation on): left-dragging a file onto the other panel opens the normal **Copy dialog**,
  `Copy "<name>" to`, with the target set to that panel's path plus the file name (observed; dialog in 07 › Copy
  dialog). A move uses the Rename/Move dialog in the same way (unverified).
- With _Drag&Drop_ confirmation **off**, a drop copies or moves **at once**, without the target dialog.

### 6.4 Drop targets inside TC

| Drop onto                                                             | Result                                                                                                                                                                                                                                                                                                                                                                                        |
| --------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The other panel (its background)                                      | Into that panel's directory. If the visible list is full of directory entries, drop slightly above or below them to reach the directory itself                                                                                                                                                                                                                                                |
| A subdirectory or archive in a panel (drawn **framed** while hovered) | Into that subdirectory, or **added** to that archive                                                                                                                                                                                                                                                                                                                                          |
| Drive combo, drive buttons                                            | Into that drive's current directory                                                                                                                                                                                                                                                                                                                                                           |
| Path bar                                                              | Onto an individual path part; or hover over it: the underline **flashes**, then the part's subdirectory list opens and the files can be dropped on a subdirectory there. FTP locations work as a target for files and archives                                                                                                                                                                |
| Folder tab                                                            | Into that tab's directory (copy or move)                                                                                                                                                                                                                                                                                                                                                      |
| Free space of the tab header                                          | Each dragged **folder** becomes a new tab (pointer with a small arrow in the file symbol)                                                                                                                                                                                                                                                                                                     |
| Separate tree or tree panel                                           | Onto the node under the pointer. **Space** expands or collapses the branch during the drag; resting about 1 s over a collapsed node expands it, and the cursor flashes so the user can stop the expansion                                                                                                                                                                                     |
| `F3 View` / `F4 Edit` / `F8 Delete`                                   | The same as clicking the button: view / edit / delete the dropped files (`F8` asks per `MouseDelete`)                                                                                                                                                                                                                                                                                         |
| Button-bar **button**                                                 | Starts the button's program with the dropped file (or the first selected file) as its parameter; the dropped names replace the button's Parameters field, so fixed parameters belong in the Command field. Also for `em_` buttons without parameters                                                                                                                                          |
| Button-bar **empty space**, or a drop with **Shift** held             | **Inserts** a new button for the file at the drop position: a folder gives a `cd` button; a `.bar` file a sub-bar button; a file-system plugin root a button with the plugin's icon; a `.url` file takes its icon from `[InternetShortcut] IconFile`; a `.lnk` without an icon reference takes the link's own icon. Paths below the TC directory are stored relative, as `%COMMANDER_PATH%\…` |
| Command line                                                          | Adds the file's **short (8.3) name**; with **Shift** held, the name with its full path. (Ctrl+Enter in a panel adds the long name instead.)                                                                                                                                                                                                                                                   |

While dragging near the border of a list, the list **scrolls by itself**, at two speeds depending on how close the
pointer is to the border; this also works for right-button drags and drags coming from outside TC.

### 6.5 With Explorer, the Desktop and other programs

Observed on Windows 11:

| Direction                                                          | Result                                                                                                                                     |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ |
| TC panel → Explorer window of **another folder on the same drive** | The file was **moved** (Explorer's default on the same volume), with **no** TC prompt; TC's list was updated and no longer showed the file |
| Explorer → TC panel                                                | TC shows its **own** confirmation box (below), not the Copy dialog; **Yes** copies                                                         |

```text
Total Commander                                    <- title
(?)  Copy 1 file(s) to
     c:\tc-sandbox\A\images\
                  [ Yes ] [ No ]
```

With Ctrl+Shift held when dropping from Explorer, the box asks "Create shortcuts of … files in" instead (change log;
exact text unverified).

Rules from the help:

- Files can be dropped on the Desktop and into Explorer folders; Ctrl+Shift creates links there. Dragging out of
  archives, FTP connections and file-system plugins to the Desktop also works (TC provides the files).
- Other programs that accept drops (e.g. Paint, WordPad) take the files. Trash cans **delete** them.
- A single file dropped on a **printer** in the Printers folder is printed through its "print" association.
- Files cannot be dropped on a **taskbar** button, but hovering there brings that program to the front so the drop can
  be made in its window.
- **Elevated TC**: when TC runs "as administrator", Windows blocks drag & drop between TC and the Desktop/Explorer,
  which run with normal rights. Both "Run as administrator" switches in the shortcut's properties must be off.

### 6.6 Drag & drop inside dialogs

| Dialog                                                                                         | Use                                                                                      |
| ---------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Colours by file type, internal associations, Lister view methods, custom-column configurations | Reorder the list entries ("sort by drag&drop") (03, 10, 13)                              |
| Multi-Rename Tool result list                                                                  | Reorder files, which changes the counter order (09 › Multi-Rename Tool)                  |
| Background Transfer Manager                                                                    | Reorder queued jobs while paused (07 › Background Transfer Manager)                      |
| Directory hotlist _Configure_                                                                  | Move entries (12 › Directory hotlist editor)                                             |
| Compare by content                                                                             | Drop one or two file names on the path boxes (09 › Compare by content)                   |
| FTP connect dialog                                                                             | Move several connections in one operation (11 › "Connect to ftp server" dialog (Ctrl+F)) |

_Basis: observed on Windows 11 (Explorer in both directions) and under Wine (drag onto the other panel, Copy dialog);
help: drag_drop, foldertabs, frequentlyaskedquestions, dlg_configconfirmation, dlg_configbuttonbar, inisettings1,
inisettings3; change log for auto-scroll, tree expansion, breadcrumb flashing, button icons from dropped files,
right-button drop on F8 and the Ctrl+Shift box._
