# 12: Other tools and dialogs

This chapter covers the smaller tools that have no chapter of their own. These are the Directory Tree dialog (Alt+F10)
with its tree cache, the directory hotlist editor ("Change directory menu"), System Information, the volume-label
dialog, printing of file lists and file contents, the help viewer, the Help menu and About box, and the miscellaneous
commands of the Commands and Files menus. How the hotlist is used for navigation is in chapter 03; printing from Lister
is in chapter 10.

**Related:** 03 (directory hotlist and history navigation, refresh), 04 (Commands, Files and Help menus), 07 (Copy
dialog › Tree, Properties), 10 (printing from Lister), 11 (network commands), 14 (Start-menu editor, Choose command), 16
(help files per language), 17 (cm_ commands and parameters), 19 (`treeinfo*.wc` format, `[DirMenu]`, `[PrintDir]`,
window-geometry keys), A (host differences).

## 1. Directory Tree dialog (Alt+F10)

### 1.1 Two uses

| Opened from                                                                                                          | OK / double click / Enter does                                                                  |
| -------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Commands › CD Tree... (`Alt+F10`, `cm_CDtree` 500)                                                                   | Changes the **source panel** to the chosen folder                                               |
| The [Tree] button of Copy, Move, Pack, Unpack, Split, Combine, Encode, Decode and similar dialogs (07 › Copy dialog) | Copies the chosen path into the calling dialog's edit field. Cancel leaves the field unchanged. |

Opened with Alt+F10, the tree shows the whole folder tree of the current drive, fully expanded, and opens at the current
folder, highlighted by the inverted cursor bar.

### 1.2 Dialog

```text
Directory Tree
[📁 c                                ▾]   [ ] 'Everything'
┌───────────────────────────────────────┐
│[c:\]                                  │
│ ├[Program Files]                      │
│ │ ├[Common Files]                     │
│ │ │ ├[Microsoft Shared]               │
│ │ │ │ └[TextConv]                     │
│ │ │ └[System] ─[ADO] ─[OLE DB]        │
│ │ ├[Internet Explorer]                │
│ │ ├[totalcmd] ─[FILTER64] ─[LANGUAGE] │
│ │ ├[Windows Media Player]             │
│ │ └[Windows NT] ─[Accessories]        │
│ └[Program Files (x86)] …              │
└───────────────────────────────────────┘
[c:\]                                     ← path of the selected folder
Quick search: [__________]  [ F2 re-scan tree ]
[ OK ] [ Cancel ] [ Print... ] [ Help ]
```

- Folders are shown in square brackets and joined by tree lines. The line colour is `TreeLineColor` (`-1` default, `-2`
  invisible), shared with the panel trees and the FTP connect dialog.
- The line under the tree shows the path of the selected folder.
- _F2 re-scan tree_ is a button, so a re-scan also works with the mouse.

### 1.3 Controls and keys

| Control / key                 | Rule                                                                                                                                                                                                                                                                                                                                                          |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Drive combo                   | Chooses the drive whose tree is shown. Alt+F1 or Alt+F2 opens it. Changing the drive clears the quick-search field.                                                                                                                                                                                                                                           |
| 'Everything'                  | Loads the tree from the external indexer _Everything_ instead of scanning, which is much faster. Stored as `EverythingForTree` (default 0). The tree is then sorted with a simple standard sort, not the natural sort. While Everything is busy (e.g. updating its database at start-up) a progress box is shown.                                             |
| Tree list                     | Cursor keys move. Enter, a double click or **OK** accepts.                                                                                                                                                                                                                                                                                                    |
| F2, Ctrl+R, [F2 re-scan tree] | Re-scan the tree and rewrite the cache (§1.4). These keys and F1 work even when the focus is not on the list.                                                                                                                                                                                                                                                 |
| Quick search                  | Typing letters fills the field and jumps to the **next** folder whose name starts with them. Wildcards `*` and `?` work as in panel quick search, so `*test` also finds a folder named `test`. **Ctrl+Enter** or **Ctrl+↓** goes to the next match, **Ctrl+↑** to the previous one. The _Extra lines below cursor_ option (13 › Operation) also applies here. |
| Print...                      | Prints the displayed tree through the print dialog (§5.2).                                                                                                                                                                                                                                                                                                    |
| OK / Cancel / Help            | Accept / close without changes / help topic                                                                                                                                                                                                                                                                                                                   |

The dialog position and size are saved as `TreeDlg…` keys in the screen-resolution section of `wincmd.ini` (19 ›
Window-geometry keys). The dialog cannot be closed while a scan is still running.

### 1.4 Reading the tree and the tree cache

The tree dialog, and a panel tree with _Always load complete directory tree_, work from a cache file instead of scanning
the disk each time.

**Reading.** When no cache exists, or on a re-scan, a progress box counts the folders:

```text
Reading directories: 14250 (Esc to abort)
```

The number counts up while the drive is scanned (14250 for a Windows 11 `C:`). Esc aborts while the box has the focus,
not while another program has it; the close button of the box also aborts. Then the dialog opens.

**Cache location** (when `TreeFileLocation=` is not set):

| Drive                                                          | Cache file                                                                                                                                                   |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Network shares, and the drive that holds the Windows directory | The thumbnail-cache location, normally `%LOCALAPPDATA%\GHISLER\`, with the drive letter appended: for `C:` the file is `%LOCALAPPDATA%\GHISLER\treeinfoC.wc` |
| Other drives                                                   | `treeinfo.wc` in the root of the drive if it is writable, otherwise `%LOCALAPPDATA%\GHISLER\`                                                                |

- The cache file has the **Hidden** attribute (3,694,580 bytes for the Windows 11 `C:`).
- `TreeFileLocation=` sets another location, e.g. `c:\somedir\treeinfo%D%.wc`. The placeholders must be upper case,
  otherwise TC reads them as environment variables:
  - `%D%`: the drive letter, or the share root with `\` replaced by `_`;
  - `%R%`: the root path;
  - `%L%`: the volume label.
- `TreeFileLocation=%R%treeinfo.wc` brings back the old rule (always the drive root), also for shares and the Windows
  drive.
- `TreeFileLocationE=` sets the location for drive E only, and `TreeFileLocation__server_share=` for one share. Both
  work only when `TreeFileLocation=` is set too.

**Keeping it current.**

- When folders are created, renamed or deleted from TC, only the cache file is updated; the drive is not re-scanned. The
  update runs in a background thread with lowered priority.
- The automatic update happens only while the file is at most `TreeUpdateLimit` KB (default 2048). Larger trees are
  updated only by a re-scan.
- With `IgnoreLinks` containing 8, a re-scan does not follow links (junctions, reparse points). Recursive links are
  always ignored.
- A re-scan with _'Everything'_ ticked does not delete the cache file.

The file format (one `[relative\path]` line per folder, plain text) is in 19 › `treeinfo*.wc`.

_Basis: observed on Windows 11 (progress box, cache file, geometry) and under Wine (dialog); help: dlg_changetree,
options_cdtree, show_tree, inisettings1, inisettings2, inisettings3; HISTORY.TXT (keys, Everything, location rule
22.11.11, abort, update thread)._

## 2. Directory hotlist editor

### 2.1 The hotlist menu

The hotlist (bookmarks) opens with Ctrl+D (`cm_DirectoryHotlist` 526), Commands › Directory Hotlist, a double click on a
panel's path bar, or the `*` button next to the path (03 › Directory hotlist). It pops up at the top left of the active
file list:

```text
(user entries and submenus)
────────
+ Add current dir
* Configure...
```

- The first fixed item adds the current folder, or removes it when it is already listed ("Add/remove current dir" in the
  help). An entry can be added straight into a submenu; it then goes to the end of that submenu, before any submenu it
  contains.
- With `DirMenuHotkeys=1` (default) the fixed items use the accelerators `+`, `-` and `*`. `0` uses the letters of the
  translated menu texts.
- The entry of the current folder is marked, and so is every submenu that contains it.
- `cm_DirectoryHotlist` parameters set where the menu opens: `0` top left of the active panel; `1` at the mouse cursor;
  `2` / `3` below the right / left hotlist button (or the top-right corner of that file list); `4` / `5` the same for
  the active / inactive panel. Adding `8` shows line numbers, also in the configuration dialog when it is opened from
  this menu.
- Choosing an entry, Shift+Enter (open in a new tab) and the other navigation rules are in 03 › Directory hotlist.

**Configure...** opens the editor below.

### 2.2 "Change directory menu" dialog

```text
Change directory menu
Directory menu:                     (number of the current entry)
┌────────────────────────────────────────┐   [ Add Item...    ]
│                                        │   [ Add submenu... ]
│                                        │   [ Delete Item    ]
│                                        │   [ Change Title...]
│                                        │
│                                        │   [ OK ] [ Cancel ] [ Help ]
└────────────────────────────────────────┘
Command:      [cd c:\path                          ▾] [🔍]
Target path:  [                                     ]
[ ] Hide menu items starting with this character: [?]
Double click menu item to hide/show it (add/remove the character)
```

- Selecting an entry shows its command and target path in the fields below.
- _Change Title..._ is disabled until an entry is selected.
- The 1-based number of the current entry (as in `[DirMenu]`) is shown above the list. `DirMenuLast=` remembers the last
  entry shown, and the editor reopens there.
- The layout follows the Start-menu editor (14 › The _Change start menu_ dialog).

### 2.3 Editing entries

| Action          | Rule                                                                                                                    |
| --------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Move an entry   | Shift+↑ / Shift+↓ on the entry, or drag it with the mouse                                                               |
| Add Item...     | Asks for the title first. `&` underlines the next letter. A title of a single `-` makes a separator line.               |
| Add submenu...  | Asks for the title. A submenu is listed with a dash before its name (`-Title`); its end is listed as two dashes (`--`). |
| Delete Item     | Deletes the selected entry                                                                                              |
| Change Title... | Renames the selected entry                                                                                              |
| OK              | Saves to `wincmd.ini`                                                                                                   |
| Cancel          | Discards **all** changes made in the dialog, including deletions                                                        |

### 2.4 Command and target path

- **Command:** normally `cd <path>`, which changes the source panel.
  - Ending the path with `\:` (or `\\:`) goes to the **parent** folder and puts the cursor on the named folder, e.g.
    `cd D:\Dir\Focusme\:`.
  - Any internal command can be used instead, picked from the drop-down, e.g. `cm_OpenDesktop` to switch to the Desktop.
    The 🔍 button next to the field opens a browse dialog; whether it browses folders or commands was not recorded.
  - Environment variables work, e.g. `cd %commander_path%`.
- **Target path:** optional. It is set in the **other** panel at the same time, so one entry can set both panels. It is
  written as a plain path or as `cd path`.

### 2.5 Hiding entries

- With _Hide menu items starting with this character_ ticked, entries and whole submenus whose title starts with the
  chosen character are hidden from the Ctrl+D menu.
- The character is typed in the small field. The default is `?`; any character except `-` is allowed.
- A **double click** on an entry adds or removes the character, which hides or shows it.
- Stored as `MenuHideChar=`. A leading dash stores the option as disabled while keeping the character.

### 2.6 Storage and limits

`[DirMenu]` uses the same item keys as the Start menu `[user]`, numbered from 1 (format: 19 › `[user]` (Start menu) and
`[DirMenu]` (directory hotlist)):

```ini
[DirMenu]
menu1=&Windows
cmd1=cd c:\windows
path1=d:\backup          ; optional target-panel path
menu2=-Projects          ; submenu start
menu3=App
cmd3=cd d:\src\app\:     ; parent folder, cursor on "app"
menu4=--                 ; submenu end
menu5=-                  ; separator
menu6=?Secret            ; hidden while the hide character "?" is active
```

- At most **2000** entries. Windows limits an ini section to 64 KB in ANSI files and 128 KB in UTF-16 files. TC warns
  when the list does not fit.
- When an entry is added to a submenu or deleted, TC rewrites the whole section in order. If writing the section fails,
  a backup is saved as `DIR*.TMP` in `%TEMP%`.
- Shift-dragging a folder onto a button bar makes a button that changes to that folder (14 › The _Change button bar_
  dialog).

_Basis: observed on screen under Wine (menu and dialog, empty list); help: directoryhotlist, dlg_dirmenu,
dlg_choosecommand, inisettings1, inisettings3, frequentlyaskedquestions; HISTORY.TXT (limits, submenu add, line numbers,
DirMenuLast, backup)._

## 3. System Information

Commands › System Information... (`cm_SysInfo` 506) opens a read-only dialog with three tabs and the buttons [OK]
[Help]. The values sit in grey read-only boxes.

```text
System Information
[ Hardware ][ Software ][ Network ]
  CPU type:            [VirtualApple @ 2.50GHz, Rev. 11264      ]
  BIOS version:        [01.01.70                                ]
  Display driver:      [Apple M4 Max                            ]
  Display resolution:  [1728x1117x16m (32 bit)                  ]
  Current printer:     [-                                       ]
  COM ports: [0]       LPT ports: [0]
  Installed RAM:       [131,071 M (128 G)                       ]
                                              [ OK ] [ Help ]
```

The sample values were recorded under Wine on a virtual machine, so they show the value formats only.

| Tab      | Field                                                                           | Meaning and format                                                                                                                           |
| -------- | ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Hardware | CPU type                                                                        | Processor type, with details read from the registry                                                                                          |
|          | BIOS version                                                                    | The revision date of the system BIOS. When it cannot be read, general BIOS information (the BIOS version string) is shown instead.           |
|          | Display driver                                                                  | The current display driver                                                                                                                   |
|          | Display resolution                                                              | Width x height x number of colours, then the colour depth: `1728x1117x16m (32 bit)`                                                          |
|          | Current printer                                                                 | The default printer; `-` when there is none                                                                                                  |
|          | COM ports / LPT ports                                                           | Number of serial / parallel ports                                                                                                            |
|          | Installed RAM                                                                   | Installed memory, e.g. `131,071 M (128 G)`                                                                                                   |
| Software | Windows version                                                                 | The Windows version and edition (Home, Professional …); Windows 11 is recognised as such                                                     |
|          | Windows mode                                                                    | The internal version and build number: `10.0 (Build 19045)`                                                                                  |
|          | ProductId                                                                       | Windows 10 and later: the product ID and, when known, the release name, e.g. `1709, Fall Creators 2017`. Observed: `0`.                      |
|          | Swap file                                                                       | Maximum size of the page file: `131,072 M max.`                                                                                              |
|          | Free memory                                                                     | The _unallocated_ memory and the "memory load" percentage, because total free memory is meaningless on current Windows: `75,067 M (58 %)`    |
|          | Free resources                                                                  | The lower of the free GDI and USER resources, both in brackets: `99% (G=99%,U=99%)`. Not meaningful on NT.                                   |
|          | Time since Win start                                                            | Uptime: `130h 19m 21s`. On XP and older the counter wraps to 0 after about 50 days.                                                          |
|          | Temporary dir                                                                   | `%TEMP%`                                                                                                                                     |
| Network  | Primary network / Secondary net                                                 | The installed networks. Observed: `absent`. A network not directly supported by Windows (e.g. pure TCP/IP) shows "No network installed".     |
|          | _Microsoft network or compatible_: User name, Computer name, Workgroup, Comment | Present only with a Microsoft network. Comment shows the computer description that the user can set in Windows. Unicode names are supported. |

On NT-based Windows some BIOS-derived values can be garbage, because NT offers no BIOS calls.

_Basis: observed on screen under Wine; help: options_sysinfo, dlg_sysinfo, dlg_sysinfosoft, dlg_network; HISTORY.TXT
(CPU from registry, edition, Windows 11, Comment, Unicode)._

## 4. Volume label

Commands › Volume Label... (`cm_VolumeId` 505) sets the label of the drive shown in the **source** panel.

```text
Set volume label - c:\
Volume label
[                              ]
              [ OK ] [ Cancel ]
```

- The current label is shown to the right of the drive combo box (02 › Drive combo).
- **Length:** up to 11 characters; on NTFS up to 32. Non-Latin text (e.g. Cyrillic) is allowed.
- **Not allowed:** `?` `/` `|` `¦` `.` `,` `;` `:` `+` `=` `<` `>` `[` `]` `(` `)` `&` `^` `*` `"` `\`
- Changing the label of a system drive may need administrator rights. While TC asks for them, OK and Cancel are
  disabled.

_Basis: observed on screen under Wine (dialog); help: options_volume_label; HISTORY.TXT (administrator rights,
Cyrillic)._

## 5. Printing

### 5.1 Files › Print

| Item                      | Command                 | Rule                                                                                                                                                                                                                                                                                                            |
| ------------------------- | ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| File List...              | `cm_PrintDir` (2027)    | Opens the print dialog with a preview (§5.2). What is printed follows the panel view: **Brief** = names only, **Full** = all details, **Tree** = the whole displayed tree. In a file list only the **selected** files are printed. Observed: the preview listed only the selection / the item under the cursor. |
| File List With Subdirs... | `cm_PrintDirSub` (2028) | Prints the selected files and folders **including their subfolders**. TC first asks for the **depth** (`-1` = unlimited) and for the files to include, e.g. `*.doc *.txt`, or `*.* \| *.bak *.~*` to leave out backup files (18 › File masks). Not available over FTP or parallel-port connections.             |
| File Contents (Ctrl+F9)   | `cm_PrintFile` (504)    | Prints the selected files through their Windows **"print" association** (10 › Associations). Files without one must be printed from an editor. Not available inside archives.                                                                                                                                   |

The same print dialog also prints the Directory Tree (§1.3, [Print...]) and the result list of Synchronize dirs (09 ›
Synchronize directories). Printing a file from Lister uses a different dialog (10 › Printing from Lister).

### 5.2 Print directory dialog

A resizable window titled **"Print directory"** with a live preview. The controls are listed as recorded; their exact
arrangement was not recorded:

```text
Print directory
Font [Arial ▾] [12 ▾] [B] [i]    Show: [Page 1 ▾]   [Fit to window width ▾]
[Microsoft Print to PDF              ▾]  [ Setup... ] [ Margins... ] [ Print... ]   [ ] Duplex
┌ preview ───────────────────────────────────────────────────────┐
│ c:\tc-sandbox\A\images\ - Page 1/1                             │
│ green.png   782  10/11/2026 12:55 -a--                         │
│                                                                │
│ 0 k in 1 files                                                 │
└────────────────────────────────────────────────────────────────┘
```

| Control                    | Rule                                                                                                                                                                                         |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Font: name, size, [B], [i] | The print font. Every change re-flows the preview. Each character is placed individually, so the spacing matches the printer even when a printer font is replaced by another font on screen. |
| Show: page                 | Which page the preview shows                                                                                                                                                                 |
| Show: scaling              | Fit to window width (default) · Fit to window size · 25 % · 50 % · 75 % · 100 %. Affects only the preview, not the print.                                                                    |
| Printer combo              | The printer to use. Fonts, spacing and margins depend on it, so it must be chosen **here, before printing**, not in the final Windows Print dialog; otherwise preview and print differ.      |
| Setup...                   | Page format, resolution and other printer settings; also to be set before printing. Defaults can be set in the Windows printer settings.                                                     |
| Margins...                 | Opens "Print margins and header" (§5.3)                                                                                                                                                      |
| Print...                   | Opens the standard Windows Print dialog (§5.4)                                                                                                                                               |
| Duplex                     | Manual two-sided printing (§5.4)                                                                                                                                                             |
| Preview                    | Shows the pages. The margin lines can be **dragged** with the mouse.                                                                                                                         |

The preview shows a header line (`%d - Page %p/%t` by default, e.g. `c:\tc-sandbox\A\images\ - Page 1/1`), the rows in
the panel's format, and a footer with the totals (`0 k in 1 files`).

The dialog settings are saved automatically in `[PrintDir]`. The window geometry is saved as `Print…` keys in the
screen-resolution section (19 › Window-geometry keys).

### 5.3 Print margins and header

```text
Print margins and header
Left [0.79] in    Right [0.79] in    Top [0.79] in    Bottom [0.79] in
Header [0.20] in
Header text: [%d - Page %p/%t                           ]
Example: %d - Page %p/%t -> c:\ - Page 1/3
                                    [ OK ] [ Cancel ]
```

- The defaults above are in inches (observed on Windows 11 with US settings; the unit presumably follows the Windows
  measurement setting, unverified).
- A margin of `0` means the smallest margin the printer supports.
- An **empty header text** turns the header off.

| Placeholder | Meaning                      |
| ----------- | ---------------------------- |
| `%p`        | Current page                 |
| `%t`        | Total number of pages        |
| `%d`        | Base directory of the list   |
| `%D`        | Current date                 |
| `%T`        | Current time (at print time) |
| `%%`        | A percent sign               |

### 5.4 Printing and duplex

- **Print...** opens the Windows Print dialog. Its range choices are **All**, **Pages** (a page range) and
  **Selection**, which here means the current page. Observed: with "Microsoft Print to PDF", Windows asked "Save Print
  Output As" and wrote a PDF (90 KB for one page).
- **Duplex** (manual):
  1. TC prints every second page.
  2. It asks the user to put the printed sheets back in, so that the sheet printed first is fed first again, this time
     on its back.
  3. It prints the remaining pages.

_Basis: observed on Windows 11 (dialog, margins, PDF output); help: options_print, print_dialog, dlg_changetree,
inisettings3; MNU._

## 6. Help

### 6.1 Help menu

The Help menu is right-aligned on the menu bar (04 › Help menu). Index, Keyboard and Registration Info carry a `[?]`
icon.

| Item                     | Accel. | Key | Command                    | Action                                                                                                                                                                                                                      |
| ------------------------ | ------ | --- | -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Index                    | I      | F1  | `cm_HelpIndex` (610)       | Opens the help viewer at "Total Commander Help Index". In dark mode, F1 opens `totalcmddark.chm` instead, if that file (a separate download) is next to `totalcmd.chm`.                                                     |
| Keyboard                 | K      |     | `cm_Keyboard` (620)        | Help topic "Keyboard layout"                                                                                                                                                                                                |
| Registration Info        | R      |     | `cm_Register` (630)        | Help topic on ordering and registering                                                                                                                                                                                      |
| Visit Totalcmd's Website | V      |     | `cm_VisitHomepage` (640)   | Opens <https://www.ghisler.com/> in the default browser                                                                                                                                                                     |
| Check for updates now    | C      |     | `cm_CheckForUpdates` (650) | Checks for a new version at once. If there is none, it offers to switch the automatic update check on or off (`AutoUpdateCheck`: 0 off, 1 release and beta versions, 2 release versions only; 19 › `[Configuration]` keys). |
| ────                     |        |     |                            |                                                                                                                                                                                                                             |
| About Total Commander... | A      |     | `cm_About` (690)           | The About box (§6.3)                                                                                                                                                                                                        |

### 6.2 Help viewer

- The help is a compiled HTML Help file (`TOTALCMD.CHM`, or a language's `WCMD_<CODE>.CHM`; 16 › Language components)
  shown in the Windows HTML Help viewer. The window is titled "Total Commander".
- **Toolbar:** Hide · Back · Forward · Home · Options · Print.
- **Left pane tabs:** Contents · Index · Search. The Contents tree:
  - Help Index
  - Introduction (What is Total Commander?, What's new)
  - General Information
  - Operation (User interface, Keyboard layout, Menus ▸ Files / Mark / Commands / Net / Show / Configuration / Start,
    File operations, Pack files, Local menus, Drag & Drop, FTP, Direct cable connection through USB / parallel port, The
    internal file lister (F3), Multi-rename tool, Frequently asked questions, Plugins, Folder tabs, Regular expressions)
  - Configuration and Switches
  - Credits (Credits, What is Info-ZIP?)
- The **Help** button of every dialog opens the topic for that dialog. Tool windows such as the Multi-Rename Tool (`?`
  button) and Lister (F1, Help › Help) do the same.

### 6.3 About box

A message box with an information icon and a single [OK]:

```text
Total Commander Version 11.58 64 bit (2026-07-01)
Copyright © 1993-2026 by Christian Ghisler
This product uses a commercially licensed version of the
SoundTouch audio processing library.
Unzip code programmed by the INFO-ZIP group.
See help file for details.
Registered by:
Unregistered evaluation copy.
Please register!
e-mail: support@ghisler.com
Settings files:
C:\Users\<user>\AppData\Roaming\GHISLER\wincmd.ini
C:\Users\<user>\AppData\Roaming\GHISLER\wcx_ftp.ini
Program file:
C:\Program Files\totalcmd\TOTALCMD64.EXE
                                                  [OK]
```

- The two settings paths are the actual locations of `wincmd.ini` and `wcx_ftp.ini` (here the default per-user location;
  19 › File inventory and locations).
- The program file name is shown as Windows reports it, here in upper case (`TOTALCMD64.EXE`).
- In a registered copy, the registration name takes the place of "Unregistered evaluation copy. / Please register!"
  (unverified).

_Basis: observed on Windows 11 and under Wine; help: menu_help, about_box, registration, inisettings1, whats_new,
what_s_new_continued; MNU._

## 7. Miscellaneous commands

| Command                                          | Menu / key       | Behaviour                                                                                                                                                                                                                                                                                                                  |
| ------------------------------------------------ | ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Open command prompt window (`cm_ExecuteDOS` 511) | Commands         | Starts the program in `%COMSPEC%` (normally `cmd.exe`; `command.com` on Windows 9x; or a replacement such as 4DOS/4NT) in the **source** directory.                                                                                                                                                                        |
| Open Desktop Folder (`cm_OpenDesktop` 2121)      | Commands         | Shows the virtual Desktop folder in the source panel, for browsing places such as "My Computer" and starting Desktop links. Viewing and editing do not work there.                                                                                                                                                         |
| Source<->Target (`cm_Exchange` 531)              | Commands, Ctrl+U | Swaps the contents of the left and right panels. The help says settings such as the sort order "are retained"; it does not say whether they stay with the side or move with the contents. **Ctrl+Shift+U** (`cm_ExchangeWithTabs` 535) also swaps the folder tabs.                                                         |
| Target=Source (`cm_MatchSrc` 532)                | Commands         | The target panel shows the source path. **Ctrl+← / Ctrl+→** open the folder or archive under the cursor in the other panel; when the cursor is not on a folder or archive, they act like Target=Source.                                                                                                                    |
| Reread source (`cm_RereadSource` 540)            | Show, F2, Ctrl+R | Re-reads the active panel **and the drive bar**: after changing a removable disk, after another program or computer wrote to the folder, or after other users changed files on a connected FTP server (03 › Refresh).                                                                                                      |
| Quit (`cm_Exit` 24340)                           | Files, Alt+F4    | Saves the current directories and settings to `wincmd.ini`, as far as the _Save on exit_ options ask for them (19 › What is saved when), and exits. `MinimizeOnClose` (sum: 1 = the [X] button, 2 = Alt+F4, 4 = the "Alt+F4 Exit" button) minimises instead of closing. **Holding Shift, or Files › Quit, always closes.** |

`cm_Exit` takes a sum of flags: 0 = just exit; 1 = exit and restart TC; 2 = restart and switch between the 32-bit and
64-bit versions; 4 = save directories, tabs and panel views even when saving is switched off; 8 = pass the current left
and right directories and the file under the cursor to the new instance; 16 = restart as administrator (17 › Commands
with parameters).

**Commands described elsewhere:**

| Command                                                                                                      | Chapter                          |
| ------------------------------------------------------------------------------------------------------------ | -------------------------------- |
| Properties (Alt+Enter, `cm_VersionInfo` 510): the Windows property sheet, version info on the _Details_ page | 07 › Properties                  |
| Calculate Occupied Space (Ctrl+L)                                                                            | 07 › Calculate occupied space    |
| Background Transfer Manager                                                                                  | 07 › Background Transfer Manager |
| Search, Search in separate process, Synchronize Dirs                                                         | 09                               |
| Branch View, Go Back, Directory history                                                                      | 03                               |
| Network connections, Disconnect network drives, Share / Unshare directory, Show admin shares                 | 11 › Windows network functions   |
| Change Start Menu, Choose command                                                                            | 14                               |
| Save position, Save settings, Change settings files directly                                                 | 13, 19                           |

_Basis: observed on screen under Wine (menu entries; the commands themselves were not run); help: options_startdos,
options_open_desktop, options_swap, options_match, reread_source, proc_newread, proc_quit, options_exit,
options_versioninfo, dlg_choosecommand, inisettings1; KEYBOARD.TXT; MNU; inc.txt._
