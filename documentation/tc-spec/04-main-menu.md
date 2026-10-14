# 04: Main menu

This chapter lists every item of the default English main menu of Total Commander 11.58 in on-screen order: caption,
underlined accelerator letter, printed shortcut, icon, the internal command it runs and what it does. The result column
is deliberately short; each row points to the chapter that describes the function in full. How the menu bar looks is in
02, how keys are bound is in 06, and how the menu is redefined is in 14.

**Related:** [02](02-main-window.md) › Menu bar · [06](06-keyboard.md) Keyboard · [14](14-customisation.md) › Main-menu
files (`.MNU`) · [12](12-other-tools.md) › Help · [17](17-internal-commands.md) Internal commands ·
[19](19-settings-files-and-command-line.md) › Small file formats

## 1. How to read the tables

### 1.1 Menu bar

```text
 Files  Mark  Commands  Net  Show  Configuration  Start                      Help
 ^      ^     ^         ^      ^     ^            ^                          ^
 F      M     C         N      w     o            S                          H
```

| Point                     | Rule                                                                                                                                                                                                                                                                 |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Order                     | Files, Mark, Commands, Net, Show, Configuration, Start, then **Help at the right edge** of the menu bar                                                                                                                                                              |
| Menu-bar accelerators     | `&Files`, `&Mark`, `&Commands`, `&Net`, `Sho&w`, `C&onfiguration`, Start (`S`), `&Help`. Alt+letter opens the menu while quick search does not use Alt+letters (06 › Quick search and quick filter); otherwise F9, F10, or Alt pressed and released, then the letter |
| Where the menu comes from | The English captions are built into the program. The shipped `LANGUAGE\WCMD_ENG.MNU` describes the same menu and is used only when it (or another `.MNU` file) is chosen as main-menu file (13 › Display › Language, `[Configuration] Mainmenu=`)                    |
| Start menu                | The MNU keyword `STARTMENU` inserts the Start menu at its position in the menu bar                                                                                                                                                                                   |
| Help at the right         | The MNU keyword `HELP_BREAK` before the Help popup right-aligns every menu after it (not in right-to-left languages)                                                                                                                                                 |
| Grammar of `.MNU` files   | 14 › Main-menu files (`.MNU`); file format in 19 › Small file formats                                                                                                                                                                                                |

### 1.2 Columns

| Column   | Meaning                                                                                                                                                                                                                                                                                |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Item     | The caption as shown on screen. `▸` = submenu, `────` = separator, `‣` = item of a submenu                                                                                                                                                                                             |
| Accel    | The underlined letter: the character after `&` in the MNU caption. Alt+letter, or the plain letter while the menu is open, chooses the item                                                                                                                                            |
| Shortcut | The text printed at the right (the part after `\t` in the MNU). It is display text only: the binding lives in the key map (06), and a redefined key does not change the printed text                                                                                                   |
| Icon     | Whether the item shows an icon. Icons come from `wcmicons.dll` through the command-to-icon mapping in `WCMICONS.INC`; an item has an icon exactly when its command has a mapping. Size and the "pressed" look are set by `IconsInMenus` (default 17; 02 › Icons, 13 › Display › Icons) |
| Command  | The internal command and its number from `totalcmd.inc` (17). The MNU names some items by number only; the `cm_` name is given here                                                                                                                                                    |
| Result   | What the item does, and where it is described                                                                                                                                                                                                                                          |

### 1.3 States

- **Checked items** (current view, filter, sort, toggles) are drawn with their icon framed, like a pressed button
  (`IconsInMenus` bit 16, part of the default). Items without an icon show a check mark instead (FTP Show Hidden Files,
  Dark<->Normal).
- **Radio groups** in Show: view (Brief / Full / Comments / Custom columns / Thumbnails), file filter (All Files /
  Programs / last mask / Custom / Only Selected Files), sort key (Name / Extension / Time / Size / Unsorted). Defaults
  are marked ● in §6.
- **Greyed items:** FTP Disconnect while no FTP connection is open. Network Connections and Disconnect Network Drives
  exist only when a Windows network is installed (and, for Disconnect, when that network supports the dialog).
- All Show items act on the **source** (active) panel. The old-style menu had separate Left and Right menus for this.

### 1.4 Captions that differ from WCMD_ENG.MNU

The built-in English menu and `WCMD_ENG.MNU` differ only in letter case or a trailing `...`:

| On screen                                      | In WCMD_ENG.MNU                      |
| ---------------------------------------------- | ------------------------------------ |
| Files › Print › File list...                   | `File &List...`                      |
| Files › Print › File list with subdirs...      | `File List With &Subdirs...`         |
| Files › Print › File contents                  | `File Con&tents`                     |
| Commands › Search in separate Process...       | `Search in separate &process...`     |
| Show › Thumbnail View                          | `Thumbnai&l view`                    |
| Configuration › Change Settings Files Directly | `&Change Settings Files Directly...` |

_Basis: menu read on screen under Wine and checked against WCMD_ENG.MNU, WCMICONS.INC and totalcmd.inc; on Windows 11,
Alt+F showed the Files menu with exactly these items, accelerators and shortcuts. Help: add_menu, dlg_mainmenu,
dlg_configlanguage, inisettings1 (`IconsInMenus`, `Mainmenu`)._

## 2. Files menu (`&Files`)

| Item                                            | Accel                                 | Shortcut     | Icon          | Command                           | Result                                                                                                                                                                                                             |
| ----------------------------------------------- | ------------------------------------- | ------------ | ------------- | --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Change Attributes...                            | C                                     |              | yes (`r-hs`)  | `cm_SetAttrib` (502)              | Dialog "Change attributes: `<name>`"; with several items "Change attributes: `<count>`" → 07 › Change attributes                                                                                                   |
| Pack...                                         | P                                     | Alt+F5       | yes           | `cm_PackFiles` (508)              | "Pack files" dialog for the selected files. Holding Ctrl while choosing the item proposes the source directory for the archive → 08 › Pack                                                                         |
| Unpack Specific Files...                        | U                                     | Alt+F9       | yes           | `cm_UnpackFiles` (509)            | Unpack dialog (with a "Files to unpack" mask) for the archive under the cursor or the selected archives. With no archive: first a "HINT:" box (while `FirstTimeUnpack=1`), then "No files selected!" → 08 › Unpack |
| Test Archive(s)                                 | i                                     | Alt+Shift+F9 | yes           | `cm_TestArchive` (518)            | Tests the selected archives; no message on success; a damaged archive gives "Error in packed file `<path>`" [OK] [Cancel] → 08 › Test archives                                                                     |
| Compare By Content...                           | y                                     |              | yes           | `cm_CompareFilesByContent` (2022) | "Compare contents" window for two files → 09 › Compare by content                                                                                                                                                  |
| Associate With...                               | A                                     |              |               | `cm_Associate` (507)              | Windows-association dialog "Associate" → 10 › Associations                                                                                                                                                         |
| Internal Associations (Total Commander Only)... | l                                     |              |               | `cm_InternalAssociate` (519)      | "Internal Associations" dialog → 10 › Associations                                                                                                                                                                 |
| Properties...                                   | `.` (the first dot: `Properties&...`) | Alt+Enter    |               | `cm_VersionInfo` (510)            | The Windows Properties sheet of the item (tabs General / Digital Signatures / Security / Details / Previous Versions for a file); version information on Details → 07 › Properties                                 |
| Calculate Occupied Space...                     | O                                     | Ctrl+L       |               | `cm_GetFileSpace` (503)           | Message box with the totals of the selection (or the item under the cursor); not available inside archives → 07 › Calculate occupied space                                                                         |
| Multi-Rename Tool...                            | R                                     | Ctrl+M       | yes           | `cm_MultiRenameFiles` (2400)      | "Multi-Rename Tool" window → 09 › Multi-Rename Tool                                                                                                                                                                |
| Edit Comment...                                 | n                                     | Ctrl+Z       |               | `cm_EditComment` (2700)           | "File comment" dialog (`descript.ion`) → 07 › File comments                                                                                                                                                        |
| Print ▸                                         | t                                     |              |               | — (submenu)                       | Three print commands; not available inside archives                                                                                                                                                                |
| ‣ File list...                                  | L                                     |              | yes (printer) | `cm_PrintDir` (2027)              | "Print directory" preview window for the selected files (names, full details or the tree, following the view) → 12 › Printing                                                                                      |
| ‣ File list with subdirs...                     | S                                     |              | yes (printer) | `cm_PrintDirSub` (2028)           | As above including subdirectories; asks for the depth (-1 = unlimited) and a file mask; not on FTP or PORT connections → 12 › Printing                                                                             |
| ‣ File contents                                 | t                                     | Ctrl+F9      | yes (printer) | `cm_PrintFile` (504)              | Prints the selected files through their associated print verb → 12 › Printing                                                                                                                                      |
| ────                                            |                                       |              |               |                                   |                                                                                                                                                                                                                    |
| Split File...                                   | S                                     |              | yes           | `cm_Split` (560)                  | "Split" dialog → 08 › Split file                                                                                                                                                                                   |
| Combine Files...                                | m                                     |              | yes           | `cm_Combine` (561)                | "Combine" dialog → 08 › Combine files                                                                                                                                                                              |
| Encode File (MIME,UUE,XXE)...                   | E                                     |              | yes           | `cm_Encode` (562)                 | "Encode" dialog → 08 › Encode and decode                                                                                                                                                                           |
| Decode File (MIME,UUE,XXE,BinHex)...            | D                                     |              | yes           | `cm_Decode` (563)                 | Dialog "Decode the file `<name>` to directory:", then decoding → 08 › Encode and decode                                                                                                                            |
| Create Checksum File(s) (CRC32, MD5, SHA1)...   | h                                     |              |               | `cm_CRCcreate` (564)              | "Create CRC-checksum file" dialog → 08 › Create checksum files                                                                                                                                                     |
| Verify Checksums (from checksum files)          | V                                     |              | yes (Σ)       | `cm_CRCcheck` (565)               | "Verify checksums" window; if no checksum source applies: "Please select only SFV, MD5 or SHA files!" → 08 › Verify checksums                                                                                      |
| ────                                            |                                       |              |               |                                   |                                                                                                                                                                                                                    |
| Quit                                            | Q                                     | Alt+F4       |               | `cm_Exit` (24340)                 | Closes Total Commander, saving the settings that are configured to be saved on exit. Always closes, even when `MinimizeOnClose` makes Alt+F4 minimise → 19 › What is saved when                                    |

The two blanks inside "Encode File (MIME…" and "Decode File (MIME…" are part of the captions.

_Basis: observed under Wine (all items opened except Print › File list with subdirs and File contents) and on Windows 11
(Properties, Print › File list); help: menu_files, options_setattr, options_pack, options_unpackall,
options_testarchives, compare_by_content, options_assotiate, internal_associations, options_versioninfo, options_memory,
multi_rename_tool, edit_comment, options_print, dlg_filessplit, dlg_filescombine, dlg_filesencode, dlg_filesdecode,
dlg_createsfv, dlg_verifysfv, options_exit, inisettings1._

## 3. Mark menu (`&Mark`)

| Item                                | Accel | Shortcut   | Icon          | Command                             | Result                                                                                                                                                                                                                                                 |
| ----------------------------------- | ----- | ---------- | ------------- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Select Group...                     | G     | Num +      | yes (`*+`)    | `cm_SpreadSelection` (521)          | "Expand selection" mask dialog → 03 › Selection                                                                                                                                                                                                        |
| Unselect Group...                   | U     | Num -      | yes (`*-`)    | `cm_ShrinkSelection` (522)          | "Shrink selection" mask dialog → 03 › Selection                                                                                                                                                                                                        |
| Select All                          | A     | Ctrl Num + | yes (`*`)     | `cm_SelectAll` (523)                | Selects all files (and folders, as configured); `[..]` is never selected → 03 › Selection                                                                                                                                                              |
| Unselect All                        | n     | Ctrl Num - |               | `cm_ClearAll` (524)                 | Clears the selection of files and folders → 03 › Selection                                                                                                                                                                                             |
| Invert Selection                    | I     | Num *      | yes           | `cm_ExchangeSelection` (525)        | → 03 › Selection                                                                                                                                                                                                                                       |
| Select All With Same Extension      | x     | Alt Num +  | yes (`*.EXT`) | `cm_SelectCurrentExtension` (527)   | Selects all files with the extension of the file under the cursor → 03 › Selection                                                                                                                                                                     |
| ────                                |       |            |               |                                     |                                                                                                                                                                                                                                                        |
| Save Selection                      | S     |            | yes           | `cm_SaveSelection` (530)            | Saves the selection in memory → 03 › Saving and restoring the selection                                                                                                                                                                                |
| Restore Selection                   | R     | Num /      | yes           | `cm_RestoreSelection` (529)         | Restores the saved selection, or the one before the last file operation → 03 › Saving and restoring the selection                                                                                                                                      |
| Save Selection To File              | v     |            |               | `cm_SaveSelectionToFile` (2031)     | Save dialog; writes the selected names as UTF-16LE with BOM, one per line (CRLF, none after the last), folders with a trailing `\`. ANSI / Unicode variants: `cm_SaveSelectionToFileA` (2041), `cm_SaveSelectionToFileW` (2042) → 03 › Selection files |
| Load Selection From File            | L     |            |               | `cm_LoadSelectionFromFile` (2032)   | Open dialog; selects the listed names → 03 › Selection files                                                                                                                                                                                           |
| ────                                |       |            |               |                                     |                                                                                                                                                                                                                                                        |
| Copy Selected Names To Clipboard    | y     |            | yes           | `cm_CopyNamesToClip` (2017)         | Text: one `name.ext` per line, folders with a trailing `\` → 07 › Names to the clipboard (Mark menu)                                                                                                                                                   |
| Copy Names With Path To Clipboard   | P     |            | yes           | `cm_CopyFullNamesToClip` (2018)     | Text: one full path per line, folders with a trailing `\` → 07 › Names to the clipboard (Mark menu)                                                                                                                                                    |
| Copy To Clipboard With All Details  | D     |            | yes           | `cm_CopyFileDetailsToClip` (2036)   | Text: all shown columns, tab-separated, e.g. `ro.txt<TAB>15<TAB>10/11/2026 09:58<TAB>-a--` → 07 › Names to the clipboard (Mark menu)                                                                                                                   |
| Copy To Clipboard With Path+Details | b     |            | yes           | `cm_CopyFpFileDetailsToClip` (2037) | As above with the full path in the first field → 07 › Names to the clipboard (Mark menu)                                                                                                                                                               |
| ────                                |       |            |               |                                     |                                                                                                                                                                                                                                                        |
| Compare Directories                 | C     | Shift+F2   | yes           | `cm_CompareDirs` (533)              | In both panels selects only the files that are newer than their counterpart or missing on the other side, replacing the previous selection; captions unchanged → 09 › Compare directories and Mark newer                                               |
| Mark Newer, Hide Same Files         | M     |            | yes           | `cm_DirMatch` (534)                 | As Compare Directories, and hides identical files; both captions read "Comparison: `<path>\*.*`" until the panel is reread → 09 › Compare directories and Mark newer                                                                                   |

The four _Copy … To Clipboard_ items write one line per item, with no header line and no line break after the last line.

_Basis: observed under Wine (all items; selection files and clipboard formats tested); help: menu_mark, options_mark,
options_compare, options_marknewer, proc_select._

## 4. Commands menu (`&Commands`)

| Item                           | Accel | Shortcut       | Icon             | Command                        | Result                                                                                                                                               |
| ------------------------------ | ----- | -------------- | ---------------- | ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| CD Tree...                     | T     | Alt+F10        | yes              | `cm_CDtree` (500)              | "Directory Tree" dialog of the current drive; OK or double click changes the source panel → 12 › Directory Tree dialog                               |
| Search...                      | S     | Alt+F7         | yes (binoculars) | `cm_SearchFor` (501)           | "Find Files" on the General tab, _Search in_ pre-filled with the current path → 09 › Find Files                                                      |
| Search in separate Process...  | P     | Alt+Shift+F7   | yes (binoculars) | `cm_SearchStandalone` (545)    | The same dialog as a separate program, titled "Find Files (separate)"; TC stays usable and several searches can run; no FTP search → 09 › Find Files |
| Volume Label...                | V     |                |                  | `cm_VolumeId` (505)            | "Set volume label - c:\" → 12 › Volume label                                                                                                         |
| System Information...          | I     |                |                  | `cm_SysInfo` (506)             | "System Information" → 12 › System Information                                                                                                       |
| Synchronize Dirs...            | y     |                | yes              | `cm_FileSync` (2020)           | "Synchronize directories" window → 09 › Synchronize directories                                                                                      |
| Directory Hotlist              | H     | Ctrl+D         |                  | `cm_DirectoryHotlist` (526)    | Popup menu of saved directories → 03 › Navigation, directory history and hotlist; editor in 12 › Directory hotlist editor                            |
| Go Back                        | B     | Alt+Left Arrow | yes (←)          | `cm_GoToPreviousDir` (570)     | Previous directory of the panel's history (50 per panel) → 03 › Navigation, directory history and hotlist                                            |
| ────                           |       |                |                  |                                |                                                                                                                                                      |
| Open command prompt window     | d     |                |                  | `cm_ExecuteDOS` (511)          | Starts the program in `COMSPEC` (normally `cmd.exe`) in the source directory → 12 › Miscellaneous commands                                           |
| ────                           |       |                |                  |                                |                                                                                                                                                      |
| Branch View (With Subdirs)     | a     | Ctrl+B         | yes              | `cm_DirBranch` (2026)          | Flat list of the current directory and all subdirectories; Esc aborts reading → 03 › Branch view                                                     |
| Open Desktop Folder            | O     |                |                  | `cm_OpenDesktop` (2121)        | Opens the Desktop virtual folder in the source panel; viewing and editing do not work there → 12 › Miscellaneous commands                            |
| Background Transfer Manager... | M     |                | yes              | `cm_OpenTransferManager` (559) | Background transfer window → 07 › Background operations                                                                                              |
| ────                           |       |                |                  |                                |                                                                                                                                                      |
| Source<->Target                | `<`   | Ctrl+U         | yes (⇄)          | `cm_Exchange` (531)            | Swaps the directories of the two panels; settings such as the sort order are retained → 12 › Miscellaneous commands                                  |
| Target=Source                  | `=`   |                | yes (`=`)        | `cm_MatchSrc` (532)            | The target panel shows the source path → 12 › Miscellaneous commands                                                                                 |

_Basis: observed under Wine (Search in separate Process and Open command prompt window not run), Alt+F7 result observed
on Windows 11; help: menu_fileactions, options_cdtree, options_search, options_volume_label, options_sysinfo,
synchronize_dirs, directoryhotlist, go_back, options_startdos, options_branch_view, options_open_desktop,
options_background_transfer_manager, options_swap, options_match._

## 5. Net menu (`&Net`)

| Item                           | Accel | Shortcut     | Icon      | Command                        | Result                                                                                                                                                                    |
| ------------------------------ | ----- | ------------ | --------- | ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Network Connections...         | N     |              | yes       | `cm_NetConnect` (512)          | The Windows "Map Network Drive" wizard; after a drive is mapped, the active panel switches to it → 11 › Windows network functions                                         |
| Disconnect Network Drives...   | D     |              | yes       | `cm_NetDisconnect` (513)       | The Windows "Disconnect Network Drives" list, [OK] [Cancel] → 11 › Windows network functions                                                                              |
| Share Current Directory...     | C     |              |           | `cm_NetShareDir` (514)         | The Windows Properties sheet of the current folder, with its Sharing tab → 11 › Windows network functions                                                                 |
| Unshare Directory...           | U     |              |           | `cm_NetUnshareDir` (515)       | Per the help, unshares the directory under the cursor; on current Windows the Sharing tab of the Properties sheet does this → 11 › Windows network functions              |
| Show Admin Shares              | A     |              |           | `cm_AdministerServer` (2204)   | Lists the administrative shares of the server, e.g. `[ADMIN$]`, `[C$]`, `[IPC$]` at `\\localhost\*.*` → 11 › Windows network functions                                    |
| ────                           |       |              |           |                                |                                                                                                                                                                           |
| FTP Connect...                 | F     | Ctrl+F       | yes (FTP) | `cm_FtpConnect` (550)          | "Connect to ftp server" with the saved connections → 11 › "Connect to ftp server" dialog (Ctrl+F)                                                                         |
| FTP New Connection...          | P     | Ctrl+N       | yes (URL) | `cm_FtpNew` (551)              | "ftp" quick-connect dialog (URL or host) → 11 › Quick connect                                                                                                             |
| FTP Disconnect                 | e     | Ctrl+Shift+F |           | `cm_FtpDisconnect` (552)       | Greyed without an FTP connection. Closes the connection; the panel returns to the last local directory → 11 › Disconnecting                                               |
| FTP Show Hidden Files          | w     |              |           | `cm_FtpHiddenFiles` (553)      | Toggle; check mark when on → 11 › Listing: MLSD or LIST, hidden files, raw listing                                                                                        |
| FTP Download From List...      | L     |              |           | `cm_FtpDownloadList` (558)     | "File name of download list:" [file] [>>], pre-filled with the last list used (default `ftplist.txt`); OK connects and downloads → 11 › Download list and HTTP downloads  |
| PORT Connection To Other PC... | O     |              |           | `cm_DirectCableConnect` (2300) | "PORT" connection dialog (client/server); [Test] without a cable opens a "USB" window with [Abort], then "Connect failed!" → 11 › PORT connection (USB or parallel cable) |

_Basis: observed on Windows 11 (all items except Unshare Directory, which was not run) and under Wine (FTP dialogs
opened, Windows network items not run); help: menu_net, options_connectnet, options_disconnectnet, options_share,
options_unshare, show_admin_shares, ftp_menu, port_connection._

## 6. Show menu (`Sho&w`)

| Item                          | Accel | Shortcut      | Icon            | Command                                                 | Default | Result                                                                                                                                                             |
| ----------------------------- | ----- | ------------- | --------------- | ------------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Brief                         | B     | Ctrl+F1       | yes             | `cm_SrcShort` (301)                                     |         | File names only → 03 › View types                                                                                                                                  |
| Full                          | F     | Ctrl+F2       | yes             | `cm_SrcLong` (302)                                      | ●       | All file details → 03 › View types                                                                                                                                 |
| Comments                      | m     | Ctrl+Shift+F2 | yes             | `cm_SrcComments` (300)                                  |         | Names with their file comments → 03 › View types                                                                                                                   |
| Custom Columns Mode ▸         | d     | Shift+F1      | yes             | `cm_SrcCustomViewMenu` (270)                            |         | Submenu: the defined column sets, then "Configure custom columns..." (`cm_CustomColumnConfig`, 483) → 03 › View types; definition in 13 › Display › Custom columns |
| Custom View Modes ▸           |       |               | yes             | `cm_SrcViewModeList` (333)                              |         | Submenu: "`<default>`", the defined view modes, ────, "Configure view modes" (hammer icon, `cm_ConfigViewModes`, 2939) → 03 › View modes                           |
| Tree                          | T     | Ctrl+F8       | yes             | `cm_SrcTree` (303)                                      |         | Directory tree in the panel → 03 › View types                                                                                                                      |
| Separate Tree ▸               |       | Ctrl+Shift+F8 |                 | — (submenu; the key runs `cm_SwitchSeparateTree`, 3203) |         | Three choices below → 03 › Separate tree                                                                                                                           |
| ‣ 0 (None)                    | 0     |               | yes             | `cm_SeparateTreeOff` (3200)                             |         | No separate tree                                                                                                                                                   |
| ‣ 1 (One For Both Panels)     | 1     |               | yes             | `cm_SeparateTree1` (3201)                               |         | One tree, following the active panel                                                                                                                               |
| ‣ 2 (Two, One For Each Panel) | 2     |               | yes             | `cm_SeparateTree2` (3202)                               |         | A tree for each panel                                                                                                                                              |
| Thumbnail View                | l     | Ctrl+Shift+F1 | yes             | `cm_SrcThumbs` (269)                                    |         | Thumbnails → 03 › View types                                                                                                                                       |
| Quick View Panel              | Q     | Ctrl+Q        | yes (magnifier) | `cm_SrcQuickView` (304)                                 |         | The other panel shows the file under the cursor → 03 › Quick View                                                                                                  |
| Vertical Arrangement          | V     |               | yes             | `cm_VerticalPanels` (305)                               |         | Toggle: panels above each other; the vertical button bar moves to the right edge → 03 › Vertical arrangement                                                       |
| New Folder Tab                | w     | Ctrl+T        | yes             | `cm_OpenNewTab` (3001)                                  |         | New tab in the active panel → 03 › Folder tabs                                                                                                                     |
| ────                          |       |               |                 |                                                         |         |                                                                                                                                                                    |
| All Files                     | A     | Ctrl+F10      | yes             | `cm_SrcAllFiles` (312)                                  | ●       | No filter; also clears a quick filter → 03 › Show files of type                                                                                                    |
| Programs                      | P     | Ctrl+F11      | yes (EXE)       | `cm_SrcExecs` (311)                                     |         | Programs only → 03 › Show files of type                                                                                                                            |
| `*.*` (the last mask used)    |       |               | yes             | `cm_SrcUserSpec` (313)                                  |         | Reapplies the last user mask; the caption shows that mask → 03 › Show files of type                                                                                |
| Custom...                     | C     | Ctrl+F12      | yes             | `cm_SrcUserDef` (314)                                   |         | Dialog "Enter file types (e.g. _.doc;_.txt)" → 03 › Show files of type                                                                                             |
| Only Selected Files           | O     |               | yes             | `cm_ShowOnlySelected` (2023)                            |         | Hides the files that are not selected → 03 › Only Selected Files                                                                                                   |
| ────                          |       |               |                 |                                                         |         |                                                                                                                                                                    |
| Name                          | N     | Ctrl+F3       | yes             | `cm_SrcByName` (321)                                    | ●       | Sort by name → 03 › Column header and sorting                                                                                                                      |
| Extension                     | x     | Ctrl+F4       | yes             | `cm_SrcByExt` (322)                                     |         | Sort by extension                                                                                                                                                  |
| Time                          | i     | Ctrl+F5       | yes             | `cm_SrcByDateTime` (324)                                |         | Sort by date/time                                                                                                                                                  |
| Size                          | S     | Ctrl+F6       | yes             | `cm_SrcBySize` (323)                                    |         | Sort by size                                                                                                                                                       |
| Unsorted                      | U     | Ctrl+F7       | yes             | `cm_SrcUnsorted` (325)                                  |         | Directory order                                                                                                                                                    |
| ────                          |       |               |                 |                                                         |         |                                                                                                                                                                    |
| Reversed Order                | R     |               | yes             | `cm_SrcNegOrder` (330)                                  |         | Toggle: reverses the sort direction → 03 › Column header and sorting                                                                                               |
| ────                          |       |               |                 |                                                         |         |                                                                                                                                                                    |
| Reread Source                 | e     | Ctrl+R        | yes             | `cm_RereadSource` (540)                                 |         | Rereads the source panel; also removes a quick filter → 03 › Refresh                                                                                               |

- In the MNU, _Custom Columns Mode_ and _Custom View Modes_ are plain items (commands 270 and 333); the program expands
  them into submenus. _Separate Tree_ is a `POPUP` whose title carries the shortcut text
  (`"Separate Tree\tCtrl+Shift+F8"`); the popup itself has no command.
- _Custom View Modes_ and _Separate Tree_ have no accelerator.

_Basis: observed under Wine (all items); help: menu_show, show_shortlong, show_customcolumns, show_customviewmodes,
show_tree, show_separatetree, show_thumbnails, quick_view, vertical_alignment, cm_new_folder_tab, show_files,
only_selected, show_sort, reread_source._

## 7. Configuration menu (`C&onfiguration`)

| Item                           | Accel | Icon         | Command                         | Result                                                                                                                                                                                            |
| ------------------------------ | ----- | ------------ | ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Options...                     | O     | yes (hammer) | `cm_Config` (490)               | Configuration dialog, Layout page → 13 › Layout                                                                                                                                                   |
| Button Bar...                  | B     | yes          | `cm_ButtonConfig` (498)         | "Change button bar" for the horizontal bar (`default.bar`) → 14 › Button bars                                                                                                                     |
| Button Bar 2 (Vertical)...     | 2     | yes          | `cm_ButtonConfig2` (583)        | "Change button bar" for the vertical bar (`vertical.bar`) → 14 › Button bars                                                                                                                      |
| Change Settings Files Directly | C     | yes          | `cm_ConfigChangeIniFiles` (581) | Opens `wincmd.ini` and `wcx_ftp.ini` for editing (command description: "Open ini files in notepad"); most changes take effect only after TC is closed and restarted → 19 › `wincmd.ini` reference |
| Dark<->Normal                  | D     |              | `cm_SwitchDarkMode` (2950)      | Toggles dark mode (check mark when dark); permanent unless dark mode follows the Windows setting → 02 › Dark mode                                                                                 |
| Save Position                  | S     |              | `cm_ConfigSavePos` (493)        | Saves window position, size, the tabstops and the panel divider of the current mode, per screen resolution → 19 › What is saved when                                                              |
| Save Settings                  | v     |              | `cm_ConfigSaveSettings` (580)   | Saves display settings and directories even if auto-save is off, plus position, size and tabstops → 19 › What is saved when                                                                       |

No item has a shortcut.

_Basis: observed under Wine (Change Settings Files Directly, Save Position and Save Settings not run); Dark<->Normal
also on Windows 11; help: menu_configuration, options_config, options_configbuttonbar, change_settings_files_directly,
dark___normal, options_configsaveposition, save_settings._

## 8. Start menu (`&Start`)

The user's own items (defined in _Change Start Menu_) appear **above** two fixed items:

```text
 Start
 ├ <user item 1>          cm_UserMenu1 (701)
 ├ <user item 2>          cm_UserMenu2 (702)  …
 ├ ────
 ├ Change Start Menu...   (S)   hammer icon
 └ Change Main Menu...    (M)
```

| Item                 | Accel           | Icon         | Command                                                     | Result                                                                                                                                                          |
| -------------------- | --------------- | ------------ | ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| user items           | per title (`&`) | per command  | `cm_UserMenu1`… (701…)                                      | Run the item's command with its parameters, start path, shortcut key and window state; the file under the cursor can be passed as a parameter → 14 › Start menu |
| Change Start Menu... | S               | yes (hammer) | `cm_ChangeStartMenu` (700)                                  | "Change start menu" editor → 14 › Start menu                                                                                                                    |
| Change Main Menu...  | M               |              | — (not recorded; the same page as `cm_LanguageConfig`, 499) | Opens Configuration › Language with the main-menu file (`.MNU`) field and [Edit] → 14 › Main-menu files (`.MNU`)                                                |

`cm_UserMenu1`…`cm_UserMenu10` (701–710) are predefined; more numbers can be declared in `totalcmd.inc`.

_Basis: observed under Wine (no user items defined); help: menu_starter, dlg_usermenu, dlg_mainmenu, add_menu._

## 9. Help menu (`&Help`), right-aligned

| Item                     | Accel | Shortcut | Icon    | Command                    | Result                                                                                                                                                               |
| ------------------------ | ----- | -------- | ------- | -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Index                    | I     | F1       | yes (?) | `cm_HelpIndex` (610)       | Help viewer (window title "Total Commander") on "Total Commander Help Index" → 12 › Help viewer                                                                      |
| Keyboard                 | K     |          | yes (?) | `cm_Keyboard` (620)        | Help topic "Keyboard layout" (the key list of 06) → 12 › Help viewer                                                                                                 |
| Registration Info        | R     |          | yes (?) | `cm_Register` (630)        | Help topic "Ordering / Registering" → 12 › Help viewer                                                                                                               |
| Visit Totalcmd's Website | V     |          |         | `cm_VisitHomepage` (640)   | Opens `https://www.ghisler.com/` in the default browser → 12 › Help menu                                                                                             |
| Check for updates now    | C     |          |         | `cm_CheckForUpdates` (650) | Looks for a new version at once; if there is none, offers to switch the automatic update check on or off → 12 › Help menu                                            |
| ────                     |       |          |         |                            |                                                                                                                                                                      |
| About Total Commander... | A     |          |         | `cm_About` (690)           | Message box with the version and date, copyright and credits, registration state, the paths of the settings files in use and the program file; [OK] → 12 › About box |

_Basis: observed on Windows 11 and under Wine (Visit Totalcmd's Website and Check for updates now not run); help:
menu_help, main_index, keyboard, registration, about_box._
