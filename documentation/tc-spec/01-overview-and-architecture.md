# 01: Overview and architecture

This chapter says what Total Commander 11.58 x64 is and defines the model the rest of the specification rests on: two
panels with a source and a target, cursor versus selection and the operand rule, the file systems a panel can show, the
command system, the job engine, persistence and plugins. These are given as concepts with pointers to the chapters that
own the details. The chapter also describes in full the installer, the start-up sequence (nag screen, first-start
dialogs) and the main-window title.

**Related:** 02 (main window), 03 (file panels), 07 (file operations), 15 (plugins), 17 (internal commands), 19
(settings files and command line), 20 (implementation guide).

## 1. The product

### 1.1 What Total Commander is

Total Commander (formerly "Wincmd") is a file manager for Windows. Unlike Windows Explorer it uses two fixed file
windows side by side, after the model of the well-known DOS file manager (Norton Commander): keyboard functions follow
that original, and almost every operation copies, moves or compares between the two windows. Around this core it offers:

| Area                    | What it does                                                                                                                                                                                       | Chapter |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| File operations         | Copy, move, rename, delete whole trees; queue and background transfers; attributes, links, comments, properties                                                                                    | 07      |
| Archives                | ZIP, 7Z, TAR, GZ and others handled like folders; built-in ZIP and 7-Zip packers and unpackers for ZIP, ARJ, LZH, GZ, TAR, RAR, ACE, 7Z; external packers; split/combine, encode/decode, checksums | 08      |
| Search, rename, compare | Find Files with full-text search across drives; Multi-Rename Tool; Synchronize directories; Compare by content                                                                                     | 09      |
| Viewing                 | Built-in viewer Lister (F3) for files of any size (text, binary, hex, images, plugins); external editor (F4); associations                                                                         | 10      |
| FTP and network         | Built-in FTP/FTPS client; Windows network functions; PORT/USB cable connection                                                                                                                     | 11      |
| Customisation           | Configurable button bars, Start menu (user commands with the current directory or file as parameter), main menu, hotkeys, command line                                                             | 14      |
| Extensions              | Packer, file-system, Lister and content plugins; language files                                                                                                                                    | 15, 16  |

### 1.2 Product facts

|                                   |                                                                                                                                                                                             |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Product                           | Total Commander (x64) 11.58, 64-bit edition                                                                                                                                                 |
| Release                           | 2026-07-01 (About box: "Total Commander Version 11.58 64 bit (2026-07-01)")                                                                                                                 |
| Copyright                         | © 1993-2026 Christian Ghisler, Ghisler Software GmbH                                                                                                                                        |
| Installer                         | `tcmd1158x64.exe`, from totalcommander.ch / ghisler.com (§12)                                                                                                                               |
| Program file                      | `C:\Program Files\totalcmd\TOTALCMD64.EXE` (default installation folder)                                                                                                                    |
| Settings files                    | `wincmd.ini` and `wcx_ftp.ini`, by default in `%APPDATA%\GHISLER` (§11; location rules in 19)                                                                                               |
| Commands                          | 594 internal `cm_` commands in 24 categories, plus 27 commands with parameters (17)                                                                                                         |
| Licence model                     | Shareware: a 30-day trial, then a licence is required. One licence covers the 64-bit and the 32-bit version. A licensed copy does not show the registration (nag) screen at start (§13.4)   |
| Licence state while documented    | Unregistered evaluation copy ("NOT REGISTERED" in the title bar)                                                                                                                            |
| Hosts used for this specification | A Windows 11 virtual machine (26H2, ARM64 with x64 emulation, 200 % scaling) and macOS through CrossOver (Wine); see Appendix B. Values that depend on the host are collected in Appendix A |

_Basis: observed on Windows 11 (installer, About box); help: whatistotalcmd, registration, licence, asp; TOTALCMD.INC._

## 2. Architecture at a glance

The program is built from a small number of subsystems. Every user action becomes a command; commands act on the panels,
start jobs or open tool windows; panels and jobs reach files only through file-system providers; and all of them read
their settings from one store.

```text
 Input:  keys · mouse · main menu · button bars · F-key bar · command line ·
         Start menu · directory hotlist · WM_USER+51 messages from other programs
                     │   each resolves to cm_… / em_… / program + parameters
                     ▼
 ┌─────────────────────────── Command dispatcher ───────────────────────────┐
 │ cm_ table (name ↔ number ↔ handler ↔ enabled?) · em_ user commands ·     │
 │ external programs with parameter expansion (%P %T %N …)                   │
 └──────┬────────────────┬────────────────────┬─────────────────┬───────────┘
        ▼                ▼                    ▼                 ▼
   Left panel       Right panel          Job engine        Tool windows
   tabs, view,      (same)               copy, move,       Lister, Find Files,
   sort, filter,                         delete, pack…;    Multi-Rename, Sync,
   cursor, selection                     queue, Background Compare, FTP dialogs,
        │                │               Transfer Manager  Configuration
        └───────┬────────┴────────────────────┴─────────────────┘
                ▼
   File-system providers (VFS): local and UNC · archives (built-in, WCX) ·
   FTP · file-system plugins (WFX) · shell folders · result lists
   (search results, branch view, comparison)

   Settings store: wincmd.ini (+ redirected files) · wcx_ftp.ini · *.bar ·
   usercmd.ini · *.tab · tcDirFrq.txt · *.MNU · *.LNG
```

The state a clone has to hold, in outline (the full component tree and data model are in 20 › Component tree and 20 ›
Data model):

| Object      | Holds                                                                                                                                                                                                                                            |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| File entry  | Name, extension, directory flag, size (for a directory: computed size or none), modification, creation and access times, attributes, icon, optional comment, optional link target, provider-specific data                                        |
| Panel       | Side (left or right), an ordered list of tabs, the active tab                                                                                                                                                                                    |
| Tab         | Path and provider, optional caption, lock state (none, locked, locked with directory changes allowed), view type, sort key and direction, display filter, quick filter, view mode, back/forward history, cursor item, scroll position, selection |
| Application | Active side, the visibility flags of the Layout page, separate tree (none, one, two), Quick View on/off, vertical arrangement, panel divider position, dark mode                                                                                 |

_Basis: help: cmdinterface; structure derived from the observed program (detail in 20)._

## 3. Two panels: source and target

### 3.1 Panels and the active panel

- The main window always has **two file panels**, _left_ and _right_. By default they sit side by side; with
  `Show › Vertical Arrangement` they are stacked one above the other (02 › Window composition).
- At any moment exactly one panel is **active**. It is the **source**; the other is the **target**.
  - The active panel's path bar is highlighted. With the default colours both path bars follow the Windows caption
    colours: on Windows 11 the active one is a muted steel blue with white text, the inactive one a lighter grey-blue
    (colours: 02 › Colours; controls: 13 › Color page).
  - Only the active panel shows the solid cursor bar.
  - The command-line prompt shows the source path, e.g. `c:\users>`, `c:\windows>`.
- `Tab` switches the active panel, and so does a click anywhere in a panel.
- Almost every command acts on the **source**. Two-sided operations (Copy F5, Move F6, Pack, Unpack, Split, Combine,
  Encode) offer the **target panel's path** as their default destination.

### 3.2 Addressing variants

Many panel commands exist in four variants that name the panel they act on: `Src…` (active panel), `Trg…` (inactive
panel), `Left…` and `Right…`. Example: `cm_SrcLong` 302 "Source: All file details", `cm_LeftLong` 102,
`cm_RightLong` 202. Plain menu items act on the source. The parameter codes follow the same idea: by default `%P` is the
source path and `%T` the target path, and `%X` switches them to left/right (18 › Button and command parameters).

_Basis: observed on Windows 11 and under Wine; TOTALCMD.INC._

## 4. Cursor, selection and the operand rule

### 4.1 Cursor and selection are separate

- The **cursor** (bar or focus rectangle) marks exactly one item.
- The **selection** is a set of items, drawn in the _Mark colour_ (default **red** text).
- The selection survives cursor movement. Which actions clear or replace it is given per operation in 03 and 07.

### 4.2 The operand rule

An operation works on **the selection if there is one, otherwise on the item under the cursor**. `[..]` can never be
selected. Dialog wording follows the rule: `Copy N file(s) to` counts files and folders; a single selected or cursor
**file** gives `Copy "name" to`, a single **folder** still gives `Copy 1 file(s) to`; similarly "Pack 1 file(s) to the
archive"; for F8 "Do you really want to move the selected file `<name>` to the recycle bin?", and for a direct deletion
"Do you really want to delete the selected directory `<name>`?". Detailed operand rules per command: 07 › Operand rules.

### 4.3 Mouse and keyboard selection (concept)

- The default **mouse selection mode** is "Use right mouse button (as in NC) - context menu after 1 second" (Norton
  Commander style):
  - a **right click toggles** the selection of the clicked item;
  - **holding** the right button for about 1 s opens the context menu;
  - `Shift+F10` or the Apps key opens the context menu from the keyboard.
- The alternative "Left mouse button (Windows standard)" behaves like Explorer and enables _Rubber band selection_. Both
  are set on Configuration › Operation (13 › Operation page). Full mouse model: 05 › Mouse selection modes.
- _Selection (with Num +)_: "Also select directories" (default) lets group selection include folders; "Select files
  only" restricts it to files.
- Keys, groups, same-extension selection and selection files: 03 › Selection.

### 4.4 The saved selection

There is one in-memory selection slot. `Mark › Save Selection` writes the current selection into it, and **every file
operation saves the selection into it automatically before it runs**. `Mark › Restore Selection` (`Num /`, "Selection
before last operation") brings it back.

### 4.5 Directory sizes during selection

With _Calculate space occupied by subdirectories › when selecting with the space bar_ on (default), **Space** on a
directory selects it, calculates its total size and writes that size into the Size column in place of `<DIR>` (drawn in
the mark colour). With _› before copying/deleting_ on (default), the same calculation runs before Copy and Delete so
that progress bars and free-space checks are accurate. Each calculation is a fresh snapshot: the same folder showed
11,604,818 before a Copy dialog and 11,613,426 after a later recalculation. Calculate occupied space as a command: 07 ›
Calculate occupied space.

_Basis: observed on Windows 11 and under Wine; help: proc_select, dlg_config (Operation page)._

## 5. Panel state (concept)

Each panel shows its list through a stack of independent settings. Their behaviour is described in 03; the concepts are:

- **Display filter**: which files are listed at all: all files (default), programs, a user mask, a custom filter or
  saved selection template, or only the selected files. A **quick filter** (Ctrl+S) is a temporary name filter typed at
  the bottom of the panel, and a global **ignore list** can hide names everywhere. The path bar always shows the active
  mask, e.g. `c:\users\*.*`. → 03 › Show files of type, 03 › Quick search and quick filter.
- **Sort order**: by name, extension, time, size or unsorted, optionally reversed; directories are always listed before
  files and `[..]` first; several name-comparison methods. → 03 › Column header and sorting.
- **View type**: brief, full, comments, custom columns, thumbnails or tree; independently, zero, one or two separate
  tree panes, and Quick View (Ctrl+Q) replacing the _other_ panel with a viewer. **View modes** are named presets
  (columns, sort, colours, tab icon, commands) that _Auto switch_ rules can apply. → 03 › View types, 03 › View modes
  and auto switch.
- **Folder tabs**: each panel holds an ordered list of tabs, each with its own path, view, sort, filter and history;
  tabs can be locked and saved to `.tab` files. → 03 › Folder tabs.
- **Directory history and hotlist**: each panel keeps a back/forward history and a list of frequently used and recently
  visited folders; the directory hotlist is a user menu of saved folders. → 03 › Navigation, directory history and
  hotlist, 12 › Directory hotlist editor.

_Basis: observed under Wine and on Windows 11; detail and sources in 03._

## 6. File systems shown in a panel

A panel always shows a list from one **file-system provider**. The path bar, the drive line and the command-line prompt
show which one.

| Source                                           | How to get there                                                                                                                                                                                                                                                                                                                                                                          | Path display                                                                                                                                                                                                                                                                               |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Local or mapped drive                            | Drive combo or drive buttons, `\`, `..`, typing a path                                                                                                                                                                                                                                                                                                                                    | `c:\windows\*.*`; the prompt shows `c:\windows>`                                                                                                                                                                                                                                           |
| UNC network path                                 | Typing `\\server\share` (e.g. `cd \\localhost\c$\tc-sandbox\B` on the command line), Network Neighborhood                                                                                                                                                                                                                                                                                 | `\\localhost\c$\tc-sandbox\B\*.*`; the drive combo shows the network icon and `\`; the prompt reads `\\localhost\c$\tc-sandbox\B>`. Backspace at the share root goes up to the server, `\\localhost\*.*`                                                                                   |
| Network Neighborhood                             | Drive list entry `\` (Alt+F1 › `\`)                                                                                                                                                                                                                                                                                                                                                       | `\\Network\*.*`; lists the installed file-system plugins, the Windows network (`[Network (WORKGROUP)]`) and `<Refresh>`                                                                                                                                                                    |
| Archive (ZIP, 7Z, TAR, GZ, … and packer plugins) | Enter or Ctrl+PgDn on an archive, with _Treat archives like directories_ on                                                                                                                                                                                                                                                                                                               | `c:\x\a.zip\sub\*.*`; the Name header reads `[Auto] Name`; the prompt keeps showing the last real directory (`c:\x>`). An archive inside an archive is extracted to `%TEMP%\_tc\` and opened there, so the path bar and the drive switch to that temporary path (08 › Archives as folders) |
| FTP connection                                   | Net › FTP Connect (Ctrl+F), Net › FTP New Connection (Ctrl+N)                                                                                                                                                                                                                                                                                                                             | The path bar shows the connection number and the server path, `0:/pub/*.*`; the drive line shows `ftp://127.0.0.1:2121`; the prompt reads `0:/pub/>` (11 › The connected panel)                                                                                                            |
| File-system plugin (`.WFX`)                      | Network Neighborhood                                                                                                                                                                                                                                                                                                                                                                      | The plugin's root name, e.g. `\\\Registry\*.*`; the prompt reads e.g. `\\\Registry\HKEY_CURRENT_USER\AppEvents>`. A plugin may define its own columns (15 › File-system plugins)                                                                                                           |
| Shell virtual folders                            | The special-folder menu (`▾` at the left of the path bar): Desktop, My Computer ▸ (drives), Documents ▸ and the host's other top-level shell folders (03 › Current-directory bar (path bar); the list observed under Wine is in A › Host shell and environment); drive-list entries `+` (Computer, drive overview) and `*` (My Documents); the separate tree shows the same shell folders | A virtual path such as `\\Desktop` (exact form unverified)                                                                                                                                                                                                                                 |
| Search results                                   | Find Files › Feed to listbox                                                                                                                                                                                                                                                                                                                                                              | The drive line shows `Search result:`, the path bar is empty, and the Name column holds full paths (09 › Find Files)                                                                                                                                                                       |
| Branch view                                      | Ctrl+B                                                                                                                                                                                                                                                                                                                                                                                    | The same path, listing the whole subtree (03 › Branch view)                                                                                                                                                                                                                                |
| Comparison view                                  | Mark › Mark Newer, Hide Same Files                                                                                                                                                                                                                                                                                                                                                        | Caption `Comparison: c:\…\*.*`. Plain Mark › Compare Directories (Shift+F2) leaves the captions unchanged (09 › Compare directories)                                                                                                                                                       |

A clone needs a **VFS abstraction** that provides: list entries (name, extension, size, times, attributes, flags), read
stream, write stream, rename, delete, make directory, set attributes and query free space. Each provider declares which
of these it supports, and the UI greys out or refuses the commands that do not apply. Example: while a file-system
plugin path is active, a `cd c:\…` typed on the command line is not executed; the panel must first be switched to a
drive.

_Basis: observed on Windows 11 (UNC, Network Neighborhood, FTP, plugins) and under Wine (archives, search results,
comparison)._

## 7. Command system

### 7.1 Internal commands

Every action of the program is an **internal command** with a name and a number, e.g. `cm_Copy` = 905 "Copy files". The
table (594 commands, from `TOTALCMD.INC`) is the single dispatch point for menus, the main and vertical button bars, the
F-key bar, keyboard shortcuts, the Start menu, the directory hotlist and external programs, which send the number as
`WM_USER+51` (`SendMessage(hTC, WM_USER+51, 2001, 0)`). The catalogue and the commands with parameters are in 17.

### 7.2 What a button, menu entry or key can hold

- an internal command (`cm_…`), optionally with parameters;
- a user command (`em_…`, defined in `usercmd.ini`);
- an external program with **Parameters**, **Start path**, _Run minimized_ / _Run maximized_, **Icon file** with index
  and **Tooltip**;
- a command with a parameter, such as `CD <dir>`, `OPENTABS <file>` or `SELECTFILES <masks>`.

Editors for these: 14 › The _Change button bar_ dialog, 14 › The _Change start menu_ dialog, 14 › User commands.

### 7.3 Parameters

Placeholders are expanded when the command runs: `%P` source path, `%T` target path, `%N` name under the cursor, `%%` a
literal `%`, and many more; a `?` as the first character of the parameters shows a dialog to edit them first. Upper-case
codes insert long names; the lower-case forms (`%p`, `%t`, `%n`, …) insert the short 8.3 form (on an FTP connection `%p`
and `%t` give the URL). Full list: 18 › Button and command parameters.

### 7.4 Remapping and aliases

Configuration › Misc assigns any key combination to any command with parameters, and defines command-line **aliases** (a
word typed on the command line that runs a command). → 14 › Redefining hotkeys and aliases, 06 › Redefining keys.

_Basis: TOTALCMD.INC; observed under Wine (menus, bars); help: dlg_configbuttonbar, dlg_usermenu._

## 8. Job engine (concept)

- File operations (copy, move, delete, pack, unpack, test, split, combine, encode, checksums, synchronize) run as
  **jobs** with a progress window.
- A job can run in the foreground or be handed to the **Background Transfer Manager** with the _F2 Queue_ button of the
  Copy/Move dialog. The manager window opens and starts the first job at once; its title is `<first item> (Copy)`. Jobs
  added while it is paused are appended to its list and run one after the other after _Start_; when all are done the
  window stays open with "(READY)" in its title. The list shows the active job at the top; `+` opens a menu to add jobs
  (Add selected items for copying, … for moving, Add URL to download), `-` removes the selected queued jobs (with the
  active job selected it offers to abort it and continue with the next), and there are _Pause_ / _Start_ and a _Speed
  limit_ in kB/s. → 07 › Background Transfer Manager.
- Before a job starts, TC can **calculate the occupied space** of the selected folders (§4.5).
- **Conflicts** are resolved by an overwrite policy, chosen in the dialog or per conflict: 1. Ask user, 2. Overwrite
  all, 3. Skip all, 4. Overwrite all older, 5. Auto-rename copied, 6. Auto-rename target files, 7. Copy all larger files
  (overwrite smaller), 8. Copy all smaller files (overwrite larger), 9. Rename older target files, skip newer. → 07 ›
  Name collisions: the Overwrite dialog.
- **Confirmations** are configurable (Misc › Get confirmation before …; 13 › Misc page).
- **Delete** moves to the recycle bin by default; with `Shift` it deletes directly ("Permanently delete"). → 07 ›
  Delete.

_Basis: observed on Windows 11 and under Wine; help: proc_copy, options_background_transfer_manager._

## 9. Viewing, editing and opening files (concept)

- `F3` opens **Lister**, the internal multi-format viewer: text, binary, hex, image/multimedia, HTML as text, Unicode,
  UTF-8, Explorer preview and Lister plugins. Other viewers can be configured. → 10 › Lister.
- `F4` opens the configured editor (default `notepad.exe`). → 10 › Entry points for viewing and editing.
- `Enter` opens a file through the Windows associations or TC's **internal associations** (Files › Internal
  Associations). Internal associations take precedence, except for **exe, com, bat, cmd and lnk** files, whose default
  action cannot be overridden. For archive extensions that open like directories, _Open_ can be redefined only with
  `***command`, and the extension must be listed explicitly in the mask. → 10 › Associations.
- With _Treat archives like directories_ on, archives open like folders (§6).

_Basis: help: listercontents, internal_associations, proc_edit; observed under Wine._

## 10. Plugins (concept)

| Type        | File extension | Purpose                                                                                                   |
| ----------- | -------------- | --------------------------------------------------------------------------------------------------------- |
| Packer      | `.WCX`         | Open, and optionally create or modify, archive formats that are not built in                              |
| File system | `.WFX`         | Browse parts of the PC or remote systems not reachable by drive letter; used through Network Neighborhood |
| Lister      | `.WLX`         | Extra file formats in Lister (F3) and Quick View (Ctrl+Q)                                                 |
| Content     | `.WDX`         | Extra file properties for custom columns, search, the Multi-Rename Tool and attributes                    |

The built-in content fields form the pseudo-plugin **`tc`** (18 › Content fields). A plugin is installed by opening its
ZIP with Enter: TC reads `pluginst.inf`, asks whether to install it, proposes a folder `…\plugins\<type>\<name>`,
unpacks the files and opens the registration dialog for that plugin type (15 › Installation). Additional languages are
installed the same way (16).

_Basis: observed on Windows 11 (all four types installed); help: plugins._

## 11. Persistence (concept)

- Most settings live in **`wincmd.ini`**, by default in `%APPDATA%\GHISLER`. Whole sections can be moved to other files
  with `AlternateUserIni=` and `RedirectSection=`.
- Some settings live elsewhere: button bars in `.bar` files, user commands in `usercmd.ini`, saved tabs in `.tab` files,
  frequently used folders in `tcDirFrq.txt`, the main menu in `.MNU` files, translations in `.LNG` files.
- The FTP client is separate: **`wcx_ftp.ini`** holds the connections **and** all FTP options, the firewall definition,
  server types, time-zone offsets and the master-password verifier. Section redirections written inside `wcx_ftp.ini`
  are ignored.
- On exit TC saves what _Save on exit_ asks for (Configuration › Operation: Directories, Panels, Old command lines; all
  on by default) plus the histories and frequently used folders (History page).
- `Configuration › Save Position` writes only the window position and size, the column tabstops and the panel divider of
  the current mode. `Configuration › Save Settings` writes the display settings, the current directories and the
  position; the help does not say that it writes the histories.
- `Configuration › Change Settings Files Directly` opens the ini files in the editor.

File locations, every key and "what is saved when": 19.

_Basis: help: inisettings, save_settings, options_configsaveposition, change_settings_files_directly; observed on
Windows 11 (default location)._

## 12. Installation

### 12.1 Installer sequence

1. Windows asks for elevation: UAC prompt "Total Commander Installer", _Verified publisher: Ghisler Software GmbH_.
2. The installer covers the screen with a dark-blue backdrop: "Total Commander 64-bit 11.58" at the top left, "Copyright
   © 1993-2026 by Christian Ghisler, All Rights reserved" at the bottom left.
3. A wizard dialog titled "Installation Total Commander 64-bit 11.58" runs through the steps below. Its header reads
   "Install: Total Commander", with a floppy-disk icon.

```text
Installation Total Commander 64-bit 11.58
┌──────────────────────────────────────────────────────────────┐
│ [floppy]  Install: Total Commander                           │
├──────────────────────────────────────────────────────────────┤
│  <step content, see table>                                   │
│                                                              │
│                [Program info]  [Next >>]  [Cancel]           │ ← step 1
└──────────────────────────────────────────────────────────────┘
```

| Step | Content                                                                                                                                                                                                                                            | Buttons                             |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------- |
| 1    | "Please select a language/ Bitte wählen Sie eine Sprache/ S.v.p. choisissez une langue:" and a list: English, Deutsch (German), Français (French), Русский (Russian), Nederlands (Dutch), Dansk (Danish), Norsk (Norwegian), Italiano (Italian), … | `[Program info] [Next >>] [Cancel]` |
| 2    | "Do you also want to install all other languages? You can then switch between these languages while the program is running." `(o) Yes ( ) No`                                                                                                      | `[<< Back] [Next >>] [Cancel]`      |
| 3    | "Please enter target directory for installation:" `[C:\Program Files\totalcmd] [...]`                                                                                                                                                              | (not recorded)                      |
| 4    | "You can define your own location for the settings (.ini files). This is only recommended for advanced users." `[Change ini file location]` (§12.2)                                                                                                | (not recorded)                      |
| 5    | "Create shortcut icons (lnk files):" `[x] In the Windows Start menu` `[x] On the Desktop` · "Create for:" `(o) This user: [<user name> ▾]` `( ) All users`                                                                                         | (not recorded)                      |
| 6    | Progress: "Installing file:" with two bars (current file %, total %), then "Creating program group..."                                                                                                                                             | `[Cancel]`                          |
| 7    | Message box "Installation successful!" (information icon)                                                                                                                                                                                          | `[OK]`                              |

The default target folder comes from `%TotalcmdDefaultDir%`, which is `c:\program files` on NT-based systems, giving
`C:\Program Files\totalcmd`.

### 12.2 Change ini file location

The button in step 4 opens:

```text
You can now define where the Total Commander settings should be stored
(wincmd.ini and wcx_ftp.ini):                                   [ Help ]
( ) Windows directory                                            (greyed)
( ) Program directory                                            (greyed)
(o) Application data (user-specific application data)
( ) Documents and Settings (user-specific documents)
( ) User-defined directory: [                         ] [...]
[x] Set this location for all users on this system
```

- _Application data_ (`%APPDATA%\GHISLER`) is the default.
- _Windows directory_ and _Program directory_ are greyed unless one of them is the current location (then it stays
  enabled so that it can be changed).
- The installer writes the chosen location to the registry (`IniFileName`, `FtpIniName`); how TC then finds its ini
  files is in 19 › File inventory and locations.

### 12.3 Result

- Program files in the target folder, with all other languages when step 2 was answered _Yes_.
- Start-menu entries "Total Commander 64 bit" and "Uninstall or Repair Total Commander"; a desktop icon only if _On the
  Desktop_ was ticked.
- The settings folder content after the first start: 19 › Files written on first start.

### 12.4 Installer command-line parameters

All parameters must be passed **in one group after a single slash**, e.g. `/AHN"testuser"D0G` (auto-install, hidden,
user "testuser", no desktop icon, create group). Flags take `1` or `0` (`G1`, `G0`).

| Parameter                | Meaning                                                                                                                                               |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `A`                      | Automatic installation (no questions)                                                                                                                 |
| `H`                      | Hidden (invisible) installation                                                                                                                       |
| `L<n>`                   | Language number from `install.inf`, e.g. `L18` = Romanian                                                                                             |
| `M`                      | Install all languages (multi-language)                                                                                                                |
| `G`                      | Create the program group (Start menu)                                                                                                                 |
| `D`                      | Create the desktop icon                                                                                                                               |
| `U`                      | Update if the target exists                                                                                                                           |
| `K`                      | Install the key file `wincmd.key` located in the installer's own directory                                                                            |
| `N"user"`                | User for the desktop and Start-menu shortcuts; `N*` = all users                                                                                       |
| `I"dir"`                 | Directory of the ini files (the file name is appended); `I".\"` = program directory. `I1…` sets it for all users, `I0` writes nothing to the registry |
| `S`                      | Install nothing into system folders (Windows or System)                                                                                               |
| `R`                      | Add no uninstall information to the registry (portable installation)                                                                                  |
| `W0` / `W1` / `W2`       | Target-folder write protection: unchanged / give the current user write rights / write rights for elevated users only                                 |
| `Z"c:\path\content.zip"` | Load the installation data from this ZIP                                                                                                              |
| `F`                      | Override the previous installation directory                                                                                                          |
| last parameter           | A target path, e.g. `installername.exe /F "c:\totalcmdnew"`                                                                                           |

`install.inf` can also request an invisible automatic installation with `[auto]` `auto=1` and `hidden=1`.

### 12.5 Uninstall and repair

The Start-menu entry "Uninstall or Repair Total Commander" runs the uninstaller (`tcunin64.exe` for the 64-bit version,
`tcuninst.exe` for the 32-bit one). What it deletes from the settings folder: 19 › File inventory and locations.

_Basis: observed on Windows 11 (§12.1–12.3); help: what_s_new_continued (installer parameters A–K); change log
(parameters N, I, S, R, W, Z, F, default directory, greyed options, uninstaller)._

## 13. Start-up

### 13.1 Start-up sequence

```text
start:
    locate and read wincmd.ini / wcx_ftp.ini                       (19)
    if wincmd.ini is missing:
        copy maintemplate.txt / ftptemplate.txt from the program folder if present,
        otherwise use the built-in defaults                       (19)
    if unregistered:
        show the nag screen (§13.2); the main window is not usable until it is passed
    if first start after installation:
        open Configuration on the Layout page (§13.3)
        after it closes, show the icon-library chooser (§13.3)
        write the one-time flags as 0
    main window ready, title as in §14
```

On the first start after a fresh installation the observed order was: nag screen → Configuration on **Layout** →
icon-library chooser → main window, with **both panels at `c:\`**. During this start TC creates its settings folder
(`wincmd.ini`, copies of the `.bar` files, the `.br2` icon caches): 19 › Files written on first start. Initial window
size and placement: 02 › Window geometry.

### 13.2 Nag screen (unregistered copy)

On every start an unregistered copy shows this window in front of the main window:

```text
Total Commander version 11.58
(shareware text)
[ Program information ]  [ Registration info ]
Please press button Nr. 3 to start the program!
[ 1 ]  [ 2 ]  [ 3 ]                          (with card logos)
```

- The user must press the button whose number the text names. The number changes from start to start.
- The 1-2-3 buttons are bold; the window is not resizable; it is translated into the current UI language.
- What a wrong number, _Program information_ and _Registration info_ do was not recorded.
- A clone does not need to reproduce the nag screen (20 › What can be left out).

### 13.3 First-start dialogs

1. **Configuration** (the Options dialog, 13) opens by itself on the **Layout** page.
2. After it is closed, the **icon-library chooser** appears (title not recorded). It is the same choice as _Set default
   icon library_ on the Icons page and in the button-bar context menu.

```text
Default icon library for button bar and main menu:
(o) 1: wcmicons.dll                       ▣▣▣▣▣▣  (row of sample icons)
( ) 2: [wcmicon2.dll: TCNewLib1      ▾]   ▢▢▢▢▢▢  (row of the flat "new" icons)
                                       [ OK ] [ Cancel ]
```

- Option 1 is the classic library, option 2 the flat "new" icons; choosing an entry in the drop-down selects option 2
  automatically.
- The choice is stored as `[Buttonbar] DefaultLib=` (default `wcmicons.dll`); buttons whose icon file is `wcmicons.dll`
  without a path then draw from the chosen library at the same index (14 › The _Change button bar_ dialog).
- The dialog is shown once: afterwards `[Configuration] FirstTimeIconLib=0` is written.

One-time flags in `[Configuration]` (each shows its dialog once and is then written as `0`): `FirstTime` (release notes
of a new version), `FirstTimeIconLib` (icon library), `FirstTimeZIP`, `FirstTimeUnpack`, `FirstFTPSync`,
`FirstMLSDsync`. In the fresh installation `FirstTime=0` and `FirstTimeIconLib=0` were in the ini after the first start,
and no release-notes window was part of the recorded sequence (19 › `[Configuration]` keys).

### 13.4 Registration (concept)

- The licence is a key file, **`wincmd.key`** (1024 bytes). Installing a new version over a registered one keeps the
  registration; the key file must be kept. The installer can install it with `/K` (§12.4).
- A registered copy shows no nag screen and no "- NOT REGISTERED" in the title. Help › About shows "Registered by:" with
  "Unregistered evaluation copy. / Please register!" in an unregistered copy (12 › About box).
- How to order: Help › Registration Info.

_Basis: observed on Windows 11 (nag screen also under Wine); help: asp, updatessupport, registration, dlg_configicons;
change log (nag-screen properties, icon-library chooser behaviour, key file)._

## 14. Window title

Format of the main-window title:

```text
Total Commander (x64) 11.58 - NOT REGISTERED
```

- `(x64)` marks the 64-bit edition; `11.58` is the version; `- NOT REGISTERED` appears only in an unregistered copy.
- There is **no** prefix before "Total Commander" (a user-name prefix seen under Wine is a host artefact; Appendix A).
- With several running instances TC adds an instance number (`[Configuration] ShowInstanceNr=1`, the default; `0` turns
  it off). Its exact form was not recorded.
- `[Configuration] TitleExtraText=` adds user text: `*text` in front of the title, `-text` in front without the instance
  number, `$text` behind the title.

_Basis: observed on Windows 11; help: inisettings (ShowInstanceNr, TitleExtraText)._
