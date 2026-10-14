# 17: Internal commands

This chapter lists every internal command of Total Commander 11.58 x64: the **594 `cm_` commands** in 24 categories, the **27 commands with parameters** with their modifier suffixes, and the optional parameters that ordinary `cm_` commands accept. The catalogue is the program's own `TOTALCMD.INC` (program folder), the table that the *Choose command* dialog shows; nothing is collapsed, so every row is one command.

**Related:** 01 › Command system; 14 › The command language, Button bars, User commands (`em_`), The *Choose command* dialog; 06 › Redefining keys; 16 › `.INC` file format (translated descriptions); 18 › Button and command parameters (`%P %N …`); 19 › `wincmd.ini` reference (`[Shortcuts]`), small file formats (`.bar`, `.MNU`, `usercmd.ini`).

## 1. Names, numbers and where they are used

### 1.1 Where commands appear

| Where | Uses | Example |
|---|---|---|
| Button bar files (`.bar`) | Name or number in `cmdN=` | `cmd3=cm_RereadSource` |
| Main menu files (`.MNU`) | Name or number after the caption | `MENUITEM "&Copy...\tF5", cm_Copy` or `…, 905` |
| `[Shortcuts]` / `[ShortcutsWin]` in `wincmd.ini` | Name; a parameter goes into `<key>_params=` | `C+Q=cm_Exit` |
| Start menu, directory hotlist, `usercmd.ini` | Name | `cmd=cm_SrcThumbs` |
| Command line | Name typed and Enter | `cm_SwitchHidSys` |
| External programs | Number, sent as `WM_USER+51` with `wParam = Nr` | `SendMessage(hTC, WM_USER+51, 2001, 0)` |
| Language files (translated `.INC`) | Number is the key; the description is translated | see 16 › `.INC` file format |

Every dispatch path (menus, both button bars, the F-key bar, hotkeys, Start menu, hotlist, command line, external messages) goes through this one table.

### 1.2 Rules a clone must keep

- Names are case-insensitive (`CM_COPY` = `cm_Copy`). The shipped `default.bar` itself writes `cm_Rereadsource` and `cm_srcshort`.
- Numbers are stable across versions. Existing `.bar`, `.MNU` files and scripts refer to them, so a clone must keep every name **and** its number.
- `0` and the category header lines (`[____Source____]=0`) are not commands; the dialog uses them as category separators. Lines starting with `;` are comments.
- Each line has the form `cm_Name=<number>;<English description>`. Some descriptions continue the text of the line above (`(e.g. for tab and background colors)`, `etc.`) or are empty; they are reproduced unchanged below.
- The *Commands with Parameters* group has negative numbers (−2 … −28). TC uses them **only to translate the descriptions**; they cannot be used instead of the command text (the INC says so in a comment). In a `.bar` file, `-2` in a `cmd` field is the manual line-break marker, not `CD`.
- User commands from `usercmd.ini` use the `em_` prefix and are listed in the dialog's last category, `usercmd.ini` (§5). They behave like `cm_` commands wherever a command can be used.
- For scripting, `cm_LeftSwitchToThisCustomView` / `cm_RightSwitchToThisCustomView` take the custom-columns view in `lParam`, counted from 1.

Translations of every description (16 languages) are in `translations/commands_all_languages.csv` (see 16 › Extracted data).

### 1.3 Categories (left pane of the *Choose command* dialog)

| # | Category | Commands | Section |
|---|---|---|---|
| 1 | Source | 22 | §2.1 |
| 2 | Left | 24 | §2.2 |
| 3 | Right | 24 | §2.3 |
| 4 | File Operations | 37 | §2.4 |
| 5 | Configuration | 36 | §2.5 |
| 6 | Network | 6 | §2.6 |
| 7 | Misc | 33 | §2.7 |
| 8 | Parallel Port | 3 | §2.8 |
| 9 | Print | 3 | §2.9 |
| 10 | Mark | 46 | §2.10 |
| 11 | Security | 3 | §2.11 |
| 12 | Clipboard | 15 | §2.12 |
| 13 | FTP | 9 | §2.13 |
| 14 | Navigation | 37 | §2.14 |
| 15 | Help | 6 | §2.15 |
| 16 | Window | 4 | §2.16 |
| 17 | Command Line | 7 | §2.17 |
| 18 | Tools | 15 | §2.18 |
| 19 | View | 51 | §2.19 |
| 20 | User | 10 | §2.20 |
| 21 | Tabs | 69 | §2.21 |
| 22 | Sorting | 44 | §2.22 |
| 23 | Custom Column Views | 49 | §2.23 |
| 24 | View Modes | 41 | §2.24 |
| 25 | Commands with Parameters | 27 | §3 |
| 26 | usercmd.ini | user-defined (`em_…`), empty by default | §5 |
| | All | every command above (first entry of the list) | |

The category title is the text between the underscores of the header line (`[________________File Operations________________]=0`).

### 1.4 Numbered series

Several commands form series of which the INC lists only the first members; the descriptions state how far a series goes.

| Series | Listed | Stated range |
|---|---|---|
| `cm_SrcCustomView1…` / `cm_TrgCustomView1…` | 1–9 (271–279 / 421–429) | "etc. until 299" / "etc. until 449" |
| `cm_LeftCustomView1…` / `cm_RightCustomView1…` | 1–9 (71–79 / 171–179) | not stated |
| `cm_SrcViewMode0…` / `cm_TrgViewMode0…` | 0–9 (8500–8509 / 8750–8759) | "etc. until 8749" / "etc. until 8999" |
| `cm_LeftViewMode0…` / `cm_RightViewMode0…` | 0–9 (8000–8009 / 8250–8259) | "etc. until 8249" / "etc. until 8499" |
| `cm_UserMenu1…` (Start-menu items) | 1–10 (701–710) | "You can add more custom user menu ids in totalcmd.inc!" |
| `cm_GoToDriveA…Z` | A, C, D, E, F, Z (2061, 2063–2066, 2086) | "(etc, define your own if) (you need more drives)": the letters in between follow by position (B = 2062 … Y = 2085; the French `.INC` confirms it with 2062 = "Saute au lecteur B" … 2085 = "Saute au lecteur Y") |
| `cm_SrcActivateTab1…10` / `Trg…` / `Left…` / `Right…` | 1–10 (5001–5010 / 5101–5110 / 5201–5210 / 5301–5310) | "(up to 99 items)" (description of `cm_SrcActivateTab10`); the parameter can address any tab (§4.3) |
| `cm_SrcSortByCol1…` / `Trg…` / `Left…` / `Right…` | 1–10 and 99 (6001–6010, 6099 / 61xx / 62xx / 63xx) | the help names the range "SortByCol1..SortByCol99"; 11–98 follow by position (inferred) |

*Basis: TOTALCMD.INC as shipped (identical to `inc.txt`); help: dlg_choosecommand, dlg_configbuttonbar; history.*

## 2. Command catalogue

Every `cm_` command, by category, in the order of `TOTALCMD.INC`. Optional parameters are in §4.

### 2.1 Source

22 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_SrcComments` | 300 | Source: Show comments |
| `cm_SrcShort` | 301 | Source: Only file names |
| `cm_SrcLong` | 302 | Source: All file details |
| `cm_SrcTree` | 303 | Source: Directory tree |
| `cm_SrcQuickView` | 304 | Source: Quick view panel |
| `cm_SrcQuickInternalOnly` | 306 | Source: Quick view, no plugins |
| `cm_SrcHideQuickView` | 307 | Source: Quick view panel off |
| `cm_SrcExecs` | 311 | Source: Only programs |
| `cm_SrcAllFiles` | 312 | Source: All files |
| `cm_SrcUserSpec` | 313 | Source: Last selected |
| `cm_SrcUserDef` | 314 | Source: Select user type |
| `cm_SrcByName` | 321 | Source: Sort by name |
| `cm_SrcByExt` | 322 | Source: Sort by extension |
| `cm_SrcBySize` | 323 | Source: Sort by size |
| `cm_SrcByDateTime` | 324 | Source: Sort by date |
| `cm_SrcUnsorted` | 325 | Source: Unsorted |
| `cm_SrcNegOrder` | 330 | Source: Reversed order |
| `cm_SrcOpenDrives` | 331 | Source: Open drive list |
| `cm_SrcThumbs` | 269 | Source: Thumbnail view |
| `cm_SrcCustomViewMenu` | 270 | Source: Custom view menu |
| `cm_SrcPathFocus` | 332 | Source: Put focus on path |
| `cm_SrcViewModeList` | 333 | Source: View mode menu |

### 2.2 Left

24 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_LeftComments` | 100 | Left: Show comments |
| `cm_LeftShort` | 101 | Left: Only file names |
| `cm_LeftLong` | 102 | Left: All file details |
| `cm_LeftTree` | 103 | Left: Directory tree |
| `cm_LeftQuickView` | 104 | Left: Quick view panel |
| `cm_LeftQuickInternalOnly` | 106 | Left: Quick view, no plugins |
| `cm_LeftHideQuickView` | 107 | Left: Quick view panel off |
| `cm_LeftExecs` | 111 | Left: Only programs |
| `cm_LeftAllFiles` | 112 | Left: All files |
| `cm_LeftUserSpec` | 113 | Left: Last selected |
| `cm_LeftUserDef` | 114 | Left: Select user type |
| `cm_LeftByName` | 121 | Left: Sort by name |
| `cm_LeftByExt` | 122 | Left: Sort by extension |
| `cm_LeftBySize` | 123 | Left: Sort by size |
| `cm_LeftByDateTime` | 124 | Left: Sort by date |
| `cm_LeftUnsorted` | 125 | Left: Unsorted |
| `cm_LeftNegOrder` | 130 | Left: Reversed order |
| `cm_LeftOpenDrives` | 131 | Left: Open drive list |
| `cm_LeftPathFocus` | 132 | Left: Put focus on path |
| `cm_LeftDirBranch` | 2034 | Left: Branch view |
| `cm_LeftDirBranchSel` | 2047 | Left: Branch view, only selected |
| `cm_LeftThumbs` | 69 | Left: Thumbnail view |
| `cm_LeftCustomViewMenu` | 70 | Left: Custom view menu |
| `cm_LeftViewModeList` | 133 | Left: View mode menu |

### 2.3 Right

24 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_RightComments` | 200 | Right: Show comments |
| `cm_RightShort` | 201 | Right: Only file names |
| `cm_RightLong` | 202 | Right: All file details |
| `cm_RightTree` | 203 | Right: Directory tree |
| `cm_RightQuickView` | 204 | Right: Quick view panel |
| `cm_RightQuickInternalOnly` | 206 | Right: Quick view, no plugins |
| `cm_RightHideQuickView` | 207 | Right: Quick view panel off |
| `cm_RightExecs` | 211 | Right: Only programs |
| `cm_RightAllFiles` | 212 | Right: All files |
| `cm_RightUserSpec` | 213 | Right: Last selected |
| `cm_RightUserDef` | 214 | Right: Select user type |
| `cm_RightByName` | 221 | Right: Sort by name |
| `cm_RightByExt` | 222 | Right: Sort by extension |
| `cm_RightBySize` | 223 | Right: Sort by size |
| `cm_RightByDateTime` | 224 | Right: Sort by date |
| `cm_RightUnsorted` | 225 | Right: Unsorted |
| `cm_RightNegOrder` | 230 | Right: Reversed order |
| `cm_RightOpenDrives` | 231 | Right: Open drive list |
| `cm_RightPathFocus` | 232 | Right: Put focus on path |
| `cm_RightDirBranch` | 2035 | Right: Branch view |
| `cm_RightDirBranchSel` | 2048 | Right: Branch view, only selected |
| `cm_RightThumbs` | 169 | Right: Thumbnail view |
| `cm_RightCustomViewMenu` | 170 | Right: Custom view menu |
| `cm_RightViewModeList` | 233 | Right: View mode menu |

### 2.4 File Operations

37 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_List` | 903 | View with Lister |
| `cm_ListInternalOnly` | 1006 | Lister without plugins/multimedia, single file |
| `cm_ListInternalMulti` | 2933 | Lister without plugins/multimedia, selected |
| `cm_ListOnly` | 2934 | Lister with plugins/multimedia, single file |
| `cm_ListMulti` | 2935 | Lister with plugins/multimedia, selected |
| `cm_ListExternal` | 3026 | Use external file viewer |
| `cm_Edit` | 904 | Edit (Notepad) |
| `cm_EditNewFile` | 2931 | Create+Open new text file |
| `cm_EditFileMenu` | 2943 | Show 'New' menu from context menu |
| `cm_EditExistingFile` | 2932 | Edit file under cursor (Shift ignored) |
| `cm_Copy` | 905 | Copy files |
| `cm_CopySamePanel` | 3100 | Copy within panel |
| `cm_CopyOtherPanel` | 3101 | Copy to other |
| `cm_RenMov` | 906 | Rename/Move files |
| `cm_MkDir` | 907 | Make directory |
| `cm_MkDirOther` | 911 | Make directory in target panel |
| `cm_Delete` | 908 | Delete files |
| `cm_TestArchive` | 518 | Test selected archives |
| `cm_PackFiles` | 508 | Pack files |
| `cm_CopyToArchive` | 2955 | Pack files (copy) |
| `cm_MoveToArchive` | 2956 | Pack files (move) |
| `cm_UnpackFiles` | 509 | Unpack all |
| `cm_RenameOnly` | 1002 | Rename (Shift+F6) |
| `cm_RenameSingleFile` | 1007 | Rename file under cursor |
| `cm_MoveOnly` | 1005 | Move (F6) |
| `cm_Properties` | 1003 | Properties dialog |
| `cm_ModernShare` | 1008 | Windows 10 modern share dialog |
| `cm_CreateShortcut` | 1004 | Create a shortcut |
| `cm_Return` | 1001 | Simulate: Return pressed |
| `cm_OpenAsUser` | 2800 | Open program under cursor as different user |
| `cm_Split` | 560 | Split file into pieces |
| `cm_Combine` | 561 | Combine partial files |
| `cm_Encode` | 562 | Encode MIME/UUE/XXE |
| `cm_Decode` | 563 | Decode MIME/UUE/XXE/BinHex |
| `cm_CRCcreate` | 564 | Create CRC checksums |
| `cm_CRCcheck` | 565 | Verify CRC checksums |
| `cm_SetAttrib` | 502 | Change attributes |

### 2.5 Configuration

36 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_Config` | 490 | Conf: Layout (first page) |
| `cm_LayoutConfig` | 476 | Conf: Layout |
| `cm_DisplayConfig` | 486 | Conf: Display |
| `cm_IconConfig` | 477 | Conf: Icons |
| `cm_FontConfig` | 492 | Conf: Font |
| `cm_ColorConfig` | 494 | Conf: Colors |
| `cm_ConfTabChange` | 497 | Conf: Tabstops/Data formats |
| `cm_DirTabsConfig` | 488 | Conf: Folder tabs |
| `cm_CustomColumnConfig` | 483 | Conf: Custom columns |
| `cm_CustomColumnDlg` | 2920 | Change current custom columns |
| `cm_ConfigViewModes` | 2939 | Conf: View Modes |
| `cm_ConfigViewModeSwitch` | 2940 | Conf: Auto-switch view modes |
| `cm_LanguageConfig` | 499 | Conf: Language |
| `cm_Config2` | 516 | Conf: Operation |
| `cm_EditConfig` | 496 | Conf: Viewer/Editor |
| `cm_ConfigLister` | 3036 | Conf: Lister |
| `cm_CopyConfig` | 487 | Conf: Copy/Delete |
| `cm_RefreshConfig` | 478 | Conf: Refresh file lists |
| `cm_QuickSearchConfig` | 479 | Conf: Quick Search |
| `cm_FtpConfig` | 489 | Conf: FTP options |
| `cm_PluginsConfig` | 484 | Conf: Plugins |
| `cm_ThumbnailsConfig` | 482 | Conf: Thumbnails |
| `cm_LogConfig` | 481 | Conf: Log file |
| `cm_IgnoreConfig` | 480 | Conf: Ignore list |
| `cm_HistoryConfig` | 475 | Conf: History |
| `cm_PackerConfig` | 491 | Conf: Packer |
| `cm_ZipPackerConfig` | 485 | Conf: ZIP packer |
| `cm_7ZipPackerConfig` | 474 | Conf: 7-ZIP packer |
| `cm_Confirmation` | 495 | Conf: Misc, Confirmation |
| `cm_ConfigSavePos` | 493 | Conf: Save position |
| `cm_ButtonConfig` | 498 | Conf: Button bar |
| `cm_ButtonConfig2` | 583 | Conf: Button bar 2 (vertical) |
| `cm_ConfigSaveSettings` | 580 | Save current paths etc. |
| `cm_ConfigChangeIniFiles` | 581 | Open ini files in notepad |
| `cm_ConfigSaveDirHistory` | 582 | Save directory history |
| `cm_ChangeStartMenu` | 700 | Change Start menu |

### 2.6 Network

6 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_NetConnect` | 512 | Network connections |
| `cm_NetDisconnect` | 513 | Disconnect network drives |
| `cm_NetShareDir` | 514 | Share directory |
| `cm_NetUnshareDir` | 515 | Unshare directory |
| `cm_AdministerServer` | 2204 | Connect to admin share to open \\server\c$ etc. |
| `cm_ShowFileUser` | 2203 | Which remote user has opened a local file |

### 2.7 Misc

33 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_GetFileSpace` | 503 | Calculate space |
| `cm_VolumeId` | 505 | Volume label |
| `cm_VersionInfo` | 510 | Version information |
| `cm_ExecuteDOS` | 511 | Open command prompt window |
| `cm_CompareDirs` | 533 | Compare dirs |
| `cm_CompareDirsWithSubdirs` | 536 | Also mark subdirs not present in other dir |
| `cm_ContextMenu` | 2500 | Show context menu |
| `cm_DriveContextMenu` | 3020 | Show drive context menu |
| `cm_ContextMenuInternal` | 2927 | Show context menu for internal associations |
| `cm_ContextMenuInternalCursor` | 2928 | Internal context menu for file under cursor |
| `cm_ShowRemoteMenu` | 2930 | Context menu for Media Center remote control Play/Pause |
| `cm_SyncChangeDir` | 2600 | Synchronous directory changing in both windows |
| `cm_EditComment` | 2700 | Edit file comment |
| `cm_FocusLeft` | 4001 | Focus on left file list |
| `cm_FocusRight` | 4002 | Focus on right file list |
| `cm_FocusSrc` | 4005 | Focus on source file list |
| `cm_FocusTrg` | 4006 | Focus on target file list |
| `cm_FocusCmdLine` | 4003 | Focus on command line |
| `cm_FocusButtonBar` | 4004 | Focus on button bar |
| `cm_FocusLeftTree` | 4007 | Focus on left separate tree |
| `cm_FocusRightTree` | 4008 | Focus on right separate tree |
| `cm_FocusSrcTree` | 4009 | Focus on source separate tree |
| `cm_FocusTrgTree` | 4010 | Focus on target separate tree |
| `cm_FocusMainMenu` | 4011 | Focus on main menu |
| `cm_FocusButtonBarVertical` | 4012 | Focus on vertical button bar |
| `cm_CountDirContent` | 2014 | Calculate space occupied by subdirs in current dir |
| `cm_UnloadPlugins` | 2913 | Unload all plugins |
| `cm_DirMatch` | 534 | Mark newer |
| `cm_Exchange` | 531 | Swap panels |
| `cm_MatchSrc` | 532 | target=Source |
| `cm_ReloadSelThumbs` | 2918 | Re-load selected thumbnails |
| `cm_ReloadBarIcons` | 2945 | Force reload icons in button bars and main menu |
| `cm_ReloadFileIcons` | 2958 | Re-load all file list icons and overlays |

### 2.8 Parallel Port

3 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_DirectCableConnect` | 2300 | Connect to other PC by cable |
| `cm_NTinstallDriver` | 2301 | Install parallel port driver on Windows NT..11 |
| `cm_NTremoveDriver` | 2302 | Remove parallel port driver on Windows NT..11 |

### 2.9 Print

3 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_PrintDir` | 2027 | Print current directory (with preview) |
| `cm_PrintDirSub` | 2028 | Print dir with subdirs |
| `cm_PrintFile` | 504 | Print file |

### 2.10 Mark

46 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_SpreadSelection` | 521 | Select group |
| `cm_SpreadSelectionCurrentExt` | 546 | Select group, pre-load extension under cursor |
| `cm_SelectBoth` | 3311 | Select group: files+folders |
| `cm_SelectFiles` | 3312 | Select group: just files |
| `cm_SelectFolders` | 3313 | Select group: just folders |
| `cm_ShrinkSelection` | 522 | Unselect group |
| `cm_ShrinkSelectionCurrentExt` | 547 | Unselect group, pre-load extension under cursor |
| `cm_ClearFiles` | 3314 | Unselect group: just files |
| `cm_ClearFolders` | 3315 | Unselect group: just folders |
| `cm_ClearSelCfg` | 3316 | Unselect group (files or both, as configured) |
| `cm_SelectAll` | 523 | Select all (files or both, as configured) |
| `cm_SelectAllBoth` | 3301 | Select both files+folders |
| `cm_SelectAllFiles` | 3302 | Select all files |
| `cm_SelectAllFolders` | 3303 | Select all folders |
| `cm_ClearAll` | 524 | Unselect all (files+folders) |
| `cm_ClearAllFiles` | 3304 | Unselect all files |
| `cm_ClearAllFolders` | 3305 | Unselect all folders |
| `cm_ClearAllCfg` | 3306 | Unselect all (files or both, as configured) |
| `cm_ExchangeSelection` | 525 | Invert selection |
| `cm_ExchangeSelBoth` | 3321 | Invert selection (files+folders) |
| `cm_ExchangeSelFiles` | 3322 | Invert selection (files) |
| `cm_ExchangeSelFolders` | 3323 | Invert selection (folders) |
| `cm_SelectCurrentExtension` | 527 | Select all files with same ext. |
| `cm_UnselectCurrentExtension` | 528 | Unselect all files with same ext. |
| `cm_SelectCurrentName` | 541 | Select all files with same name |
| `cm_UnselectCurrentName` | 542 | Unselect all files with same name |
| `cm_SelectCurrentNameExt` | 543 | Select all files with same name+ext. |
| `cm_UnselectCurrentNameExt` | 544 | Unselect all files with same name+ext. |
| `cm_SelectCurrentPath` | 537 | Select all in same path (for branch view+search) |
| `cm_UnselectCurrentPath` | 538 | Unselect all in same path |
| `cm_RestoreSelection` | 529 | Selection before last operation |
| `cm_SaveSelection` | 530 | Temporarily save selection |
| `cm_SaveSelectionToFile` | 2031 | Save file selection to file |
| `cm_SaveSelectionToFileA` | 2041 | Save file selection to file (ANSI) |
| `cm_SaveSelectionToFileW` | 2042 | Save file selection to file (Unicode) |
| `cm_SaveDetailsToFile` | 2039 | Save all shown columns to file |
| `cm_SaveDetailsToFileA` | 2043 | Save all shown columns to file (ANSI) |
| `cm_SaveDetailsToFileW` | 2044 | Save all shown columns to file (Unicode) |
| `cm_SaveHdrDetailsToFile` | 2093 | Save all shown columns to file, with headers |
| `cm_SaveHdrDetailsToFileA` | 2094 | Save all shown columns to file, with headers (ANSI) |
| `cm_SaveHdrDetailsToFileW` | 2095 | Save all shown columns to file, with headers (Unicode) |
| `cm_LoadSelectionFromFile` | 2032 | Read file selection from file |
| `cm_LoadSelectionFromClip` | 2033 | Read file selection from clipboard |
| `cm_Select` | 2936 | Select file under cursor, go to next |
| `cm_UnSelect` | 2937 | Remove selection of file, go to next |
| `cm_Reverse` | 2938 | Reverse selection of file, go to next |

### 2.11 Security

3 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_EditPermissionInfo` | 2200 | Permissions dialog (NTFS) |
| `cm_EditAuditInfo` | 2201 | File auditing (NTFS) |
| `cm_EditOwnerInfo` | 2202 | Take ownership (NTFS) |

### 2.12 Clipboard

15 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_CutToClipboard` | 2007 | Cut selected files to clipboard |
| `cm_CopyToClipboard` | 2008 | Copy selected files to clipboard |
| `cm_PasteFromClipboard` | 2009 | Paste from clipboard to current dir |
| `cm_CopyNamesToClip` | 2017 | Copy filenames to clipboard |
| `cm_CopyFullNamesToClip` | 2018 | Copy names with full path |
| `cm_CopyNetNamesToClip` | 2021 | Copy names with UNC path |
| `cm_CopyPathOfFilesToClip` | 3035 | Copy path name of each file to clipboard |
| `cm_CopySrcPathToClip` | 2029 | Copy source path to clipboard |
| `cm_CopyTrgPathToClip` | 2030 | Copy target path to clipboard |
| `cm_CopyFileDetailsToClip` | 2036 | Copy all shown columns |
| `cm_CopyFpFileDetailsToClip` | 2037 | Copy all columns, with full path |
| `cm_CopyNetFileDetailsToClip` | 2038 | Copy all columns, with UNC path |
| `cm_CopyHdrFileDetailsToClip` | 2090 | Copy all shown columns, with headers |
| `cm_CopyHdrFpFileDetailsToClip` | 2091 | Copy all columns, with headers+full path |
| `cm_CopyHdrNetFileDetailsToClip` | 2092 | Copy all columns, with headers+UNC path |

### 2.13 FTP

9 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_FtpConnect` | 550 | Connect to FTP |
| `cm_FtpNew` | 551 | New FTP connection |
| `cm_FtpDisconnect` | 552 | Disconnect from FTP |
| `cm_FtpHiddenFiles` | 553 | Show hidden FTP files |
| `cm_FtpAbort` | 554 | Abort current FTP command |
| `cm_FtpResumeDownload` | 555 | Resume aborted download |
| `cm_FtpSelectTransferMode` | 556 | Select Binary, ASCII or Auto mode |
| `cm_FtpAddToList` | 557 | Add selected files to download list |
| `cm_FtpDownloadList` | 558 | Download files in download list |

### 2.14 Navigation

37 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_GoToPreviousDir` | 570 | Go back |
| `cm_GoToNextDir` | 571 | Go forward |
| `cm_DirectoryHistory` | 572 | History list |
| `cm_DirectoryHistoryNoThinning` | 575 | History list, unfiltered |
| `cm_GoToPreviousLocalDir` | 573 | Go back, no ftp |
| `cm_GoToNextLocalDir` | 574 | Go forward, no ftp |
| `cm_DirectoryHotlist` | 526 | Directory popup menu |
| `cm_GoToRoot` | 2001 | Go to root directory |
| `cm_GoToParent` | 2002 | Go to parent directory |
| `cm_GoToDir` | 2003 | Open dir or zip under cursor |
| `cm_OpenDesktop` | 2121 | Desktop folder |
| `cm_OpenDrives` | 2122 | My computer |
| `cm_OpenControls` | 2123 | Control panel |
| `cm_OpenFonts` | 2124 | Fonts folder |
| `cm_OpenNetwork` | 2125 | Network neighborhood |
| `cm_OpenPrinters` | 2126 | Printers folder |
| `cm_OpenRecycled` | 2127 | Recycle bin |
| `cm_CDtree` | 500 | Popup directory tree |
| `cm_TransferLeft` | 2024 | Transfer dir under cursor to left window |
| `cm_TransferRight` | 2025 | Transfer dir under cursor to right window |
| `cm_EditPath` | 2912 | Edit path field above file list |
| `cm_GoToFirstEntry` | 2049 | Place cursor on first folder or file |
| `cm_GoToFirstFile` | 2050 | Place cursor on first file in list |
| `cm_GoToNextDrive` | 2051 | Go one drive up (C->D) |
| `cm_GoToPreviousDrive` | 2052 | Go one drive down |
| `cm_GoToNextSelected` | 2053 | Go to next selected file |
| `cm_GoToPrevSelected` | 2054 | Go to previous selected file |
| `cm_GoToNext` | 2055 | Go to next file |
| `cm_GoToPrev` | 2056 | Go to previous file |
| `cm_GoToLast` | 2057 | Go to last file |
| `cm_GoToDriveA` | 2061 | Switch to drive A |
| `cm_GoToDriveC` | 2063 | Switch to drive C |
| `cm_GoToDriveD` | 2064 | Switch to drive D |
| `cm_GoToDriveE` | 2065 | Switch to drive E |
| `cm_GoToDriveF` | 2066 | (etc, define your own if) |
| `cm_GoToDriveZ` | 2086 | (you need more drives) |
| `cm_OpenDriveByIndex` | 3025 | Open 1st, 2nd etc. displayed drive (in button bar or alternatively in combobox) |

### 2.15 Help

6 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_HelpIndex` | 610 | Help index |
| `cm_Keyboard` | 620 | Keyboard help |
| `cm_Register` | 630 | Registration info |
| `cm_VisitHomepage` | 640 | Visit https://www.ghisler.com/ |
| `cm_CheckForUpdates` | 650 | Check for new versions |
| `cm_About` | 690 | Help/About Total Commander |

### 2.16 Window

4 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_Exit` | 24340 | Exit Total Commander |
| `cm_Minimize` | 2000 | Minimize Total Commander |
| `cm_Maximize` | 2015 | Maximize Total Commander |
| `cm_Restore` | 2016 | Restore normal size |

### 2.17 Command Line

7 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_ClearCmdLine` | 2004 | Clear command line |
| `cm_NextCommand` | 2005 | Next command line |
| `cm_PrevCommand` | 2006 | Previous command line |
| `cm_AddPathToCmdline` | 2019 | Copy path to command line |
| `cm_AddFileNameToCmdline` | 3021 | Copy file name only to command line |
| `cm_AddPathAndFileNameToCmdline` | 3022 | Copy path+file name to command line |
| `cm_ShowCmdLineHistory` | 3023 | Open/close command line history |

### 2.18 Tools

15 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_MultiRenameFiles` | 2400 | Rename multiple files |
| `cm_SysInfo` | 506 | System information |
| `cm_OpenTransferManager` | 559 | Background transfer manager |
| `cm_SearchFor` | 501 | Search for |
| `cm_SearchForInCurDir` | 517 | Search in directory under the cursor |
| `cm_SearchStandalone` | 545 | Search in separate process |
| `cm_FileSync` | 2020 | Synchronize directories |
| `cm_Associate` | 507 | Associate |
| `cm_InternalAssociate` | 519 | Define internal associations |
| `cm_CompareFilesByContent` | 2022 | File comparison |
| `cm_IntCompareFilesByContent` | 2040 | Use internal compare tool |
| `cm_CommandBrowser` | 2924 | Browse internal commands |
| `cm_SeparateQuickView` | 2941 | Separate quick view window |
| `cm_SeparateQuickInternalOnly` | 2942 | Separate quick view, no plugins |
| `cm_UpdateQuickView` | 2946 | Reload file in current quick view |

### 2.19 View

51 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_VisButtonBar` | 2901 | Show/hide button bar |
| `cm_VisButtonBar2` | 2944 | Show/hide vertical button bar |
| `cm_VisDriveButtons` | 2902 | Show/hide drive button bars |
| `cm_VisTwoDriveButtons` | 2903 | Show/hide two drive bars |
| `cm_VisFlatDriveButtons` | 2904 | Buttons: Flat/normal mode |
| `cm_VisFlatInterface` | 2905 | Interface: Flat/normal mode |
| `cm_VisDriveCombo` | 2906 | Show/hide drive combobox |
| `cm_VisCurDir` | 2907 | Show/hide current directory |
| `cm_VisBreadCrumbs` | 2926 | Show/hide Breadcrumb bar |
| `cm_VisTabHeader` | 2908 | Show/hide tab header (sorting) |
| `cm_VisStatusBar` | 2909 | Show/hide status bar |
| `cm_VisCmdLine` | 2910 | Show/hide Command line |
| `cm_VisKeyButtons` | 2911 | Show/hide function key buttons |
| `cm_ShowHint` | 2914 | Show file tip window |
| `cm_ShowQuickSearch` | 2915 | Show name search window |
| `cm_QuickSearch` | 3018 | Show name search window, quick filter off |
| `cm_QuickFilter` | 3019 | Show name search window, quick filter on |
| `cm_VerticalPanels` | 305 | File windows above each other |
| `cm_SwitchLongNames` | 2010 | Turn long names on and off |
| `cm_RereadSource` | 540 | Reread source |
| `cm_ShowOnlySelected` | 2023 | Hide files which aren't selected |
| `cm_SwitchHidSys` | 2011 | Turn hidden/system files on and off |
| `cm_SwitchHid` | 3013 | Turn hidden files on and off |
| `cm_SwitchSys` | 3014 | Turn system files on and off |
| `cm_Switch83Names` | 2013 | Turn 8.3 names lowercase on/off |
| `cm_SwitchDirSort` | 2012 | Turn directory sorting by name on/off |
| `cm_DirBranch` | 2026 | Show all files in current dir and all subdirs |
| `cm_DirBranchSel` | 2046 | Show selected files, and all in selected subdirs |
| `cm_50Percent` | 909 | Window separator at 50% |
| `cm_100Percent` | 910 | Window separator at 100% |
| `cm_VisDirTabs` | 2916 | Show/hide folder tabs |
| `cm_VisXPthemeBackground` | 2923 | Show/hide XP theme background |
| `cm_SwitchOverlayIcons` | 2917 | Switch icon overlays on/off |
| `cm_VisHistHotButtons` | 2919 | Show/hide dir history+hotlist |
| `cm_SwitchWatchDirs` | 2921 | Enable/disable WatchDirs auto-refresh temporarily |
| `cm_SwitchIgnoreList` | 2922 | Enable/disable ignore list file to not show file names |
| `cm_SwitchX64Redirection` | 2925 | 64-bit Windows: Redirect 32-bit system32 dir off/on |
| `cm_SeparateTreeOff` | 3200 | Disable separate tree panel |
| `cm_SeparateTree1` | 3201 | One separate tree panel |
| `cm_SeparateTree2` | 3202 | Two separate tree panels |
| `cm_SwitchSeparateTree` | 3203 | Switch through tree panel options |
| `cm_ToggleSeparateTree1` | 3204 | One separate tree panel on/off |
| `cm_ToggleSeparateTree2` | 3205 | Two separate tree panels on/off |
| `cm_ChangeArchiveEncoding` | 2948 | Show popup menu to change archive name encoding |
| `cm_SwitchDarkMode` | 2950 | Turn dark mode on and off |
| `cm_EnableDarkMode` | 2951 | Turn dark mode on |
| `cm_DisableDarkMode` | 2952 | Turn dark mode off |
| `cm_SwitchColorsByFileType` | 2957 | Enable/disable color filters |
| `cm_SwitchFileTipWindows` | 2959 | Enable/disable file tooltips |
| `cm_ZoomIn` | 2953 | Enlarge thumbnails (max 200%) |
| `cm_ZoomOut` | 2954 | Make thumbnails smaller (min 10%) |

### 2.20 User

10 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_UserMenu1` | 701 | Start first menu item in Start menu |
| `cm_UserMenu2` | 702 | Second item |
| `cm_UserMenu3` | 703 | Third item |
| `cm_UserMenu4` | 704 | etc. |
| `cm_UserMenu5` | 705 |  |
| `cm_UserMenu6` | 706 |  |
| `cm_UserMenu7` | 707 |  |
| `cm_UserMenu8` | 708 | You can add more |
| `cm_UserMenu9` | 709 | custom user menu ids |
| `cm_UserMenu10` | 710 | in totalcmd.inc! |

### 2.21 Tabs

69 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_OpenNewTab` | 3001 | Open new tab |
| `cm_OpenNewTabBg` | 3002 | Open new tab in background |
| `cm_OpenNewTabOther` | 3027 | Open new tab (other window) |
| `cm_OpenNewTabBgOther` | 3028 | Open new tab in background (other window) |
| `cm_OpenDirInNewTab` | 3003 | Open dir under cursor in tab |
| `cm_OpenDirInNewTabOther` | 3004 | Open dir under cursor (other window) |
| `cm_SwitchToNextTab` | 3005 | Switch to next Tab (as Ctrl+Tab) |
| `cm_SwitchToPreviousTab` | 3006 | Switch to previous Tab (Ctrl+Shift+Tab) |
| `cm_MoveTabLeft` | 3015 | Move current tab to the left |
| `cm_MoveTabRight` | 3016 | Move current tab to the right |
| `cm_CloseCurrentTab` | 3007 | Close tab |
| `cm_CloseAllTabs` | 3008 | Close all |
| `cm_CloseDuplicateTabs` | 3017 | Close duplicate tabs |
| `cm_DirTabsShowMenu` | 3009 | Show tab menu |
| `cm_RenameTab` | 3024 | Rename current tab |
| `cm_ToggleLockCurrentTab` | 3010 | Turn on/off tab locking |
| `cm_ToggleLockDcaCurrentTab` | 3012 | Same but with dir changes allowed |
| `cm_SetTabOptionNormal` | 3029 | Turn off tab locking |
| `cm_SetTabOptionPathLocked` | 3030 | Turn on tab locking |
| `cm_SetTabOptionPathResets` | 3031 | Turn on tab locking with dir changes allowed |
| `cm_SetAllTabsOptionNormal` | 3032 | Turn off tab locking for all tabs |
| `cm_SetAllTabsOptionPathLocked` | 3033 | Turn on tab locking for all tabs |
| `cm_SetAllTabsOptionPathResets` | 3034 | Turn on tab locking with dir changes allowed for all tabs |
| `cm_ExchangeWithTabs` | 535 | Swap all Tabs |
| `cm_GoToLockedDir` | 3011 | Go to the base dir of locked tab  |
| `cm_SrcTabsList` | 5515 | Source: Show list of all open tabs |
| `cm_TrgTabsList` | 5516 | Target: Show list of all open tabs |
| `cm_LeftTabsList` | 5517 | Left: Show list of all open tabs |
| `cm_RightTabsList` | 5518 | Right: Show list of all open tabs |
| `cm_SrcActivateTab1` | 5001 | Activate first tab |
| `cm_SrcActivateTab2` | 5002 | Activate second tab |
| `cm_SrcActivateTab3` | 5003 | (Source window) |
| `cm_SrcActivateTab4` | 5004 | etc. |
| `cm_SrcActivateTab5` | 5005 |  |
| `cm_SrcActivateTab6` | 5006 |  |
| `cm_SrcActivateTab7` | 5007 |  |
| `cm_SrcActivateTab8` | 5008 |  |
| `cm_SrcActivateTab9` | 5009 |  |
| `cm_SrcActivateTab10` | 5010 | (up to 99 items) |
| `cm_TrgActivateTab1` | 5101 | Activate first tab |
| `cm_TrgActivateTab2` | 5102 | Activate second tab |
| `cm_TrgActivateTab3` | 5103 | (Target window) |
| `cm_TrgActivateTab4` | 5104 | etc. |
| `cm_TrgActivateTab5` | 5105 |  |
| `cm_TrgActivateTab6` | 5106 |  |
| `cm_TrgActivateTab7` | 5107 |  |
| `cm_TrgActivateTab8` | 5108 |  |
| `cm_TrgActivateTab9` | 5109 |  |
| `cm_TrgActivateTab10` | 5110 |  |
| `cm_LeftActivateTab1` | 5201 | Activate first tab |
| `cm_LeftActivateTab2` | 5202 | Activate second tab |
| `cm_LeftActivateTab3` | 5203 | (Left window) |
| `cm_LeftActivateTab4` | 5204 | etc. |
| `cm_LeftActivateTab5` | 5205 |  |
| `cm_LeftActivateTab6` | 5206 |  |
| `cm_LeftActivateTab7` | 5207 |  |
| `cm_LeftActivateTab8` | 5208 |  |
| `cm_LeftActivateTab9` | 5209 |  |
| `cm_LeftActivateTab10` | 5210 |  |
| `cm_RightActivateTab1` | 5301 | Activate first tab |
| `cm_RightActivateTab2` | 5302 | Activate second tab |
| `cm_RightActivateTab3` | 5303 | (Right window) |
| `cm_RightActivateTab4` | 5304 | etc. |
| `cm_RightActivateTab5` | 5305 |  |
| `cm_RightActivateTab6` | 5306 |  |
| `cm_RightActivateTab7` | 5307 |  |
| `cm_RightActivateTab8` | 5308 |  |
| `cm_RightActivateTab9` | 5309 |  |
| `cm_RightActivateTab10` | 5310 |  |

### 2.22 Sorting

44 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_SrcSortByCol1` | 6001 | Sort by first column |
| `cm_SrcSortByCol2` | 6002 | Sort by second column |
| `cm_SrcSortByCol3` | 6003 | (source window) |
| `cm_SrcSortByCol4` | 6004 | etc. |
| `cm_SrcSortByCol5` | 6005 |  |
| `cm_SrcSortByCol6` | 6006 |  |
| `cm_SrcSortByCol7` | 6007 |  |
| `cm_SrcSortByCol8` | 6008 |  |
| `cm_SrcSortByCol9` | 6009 |  |
| `cm_SrcSortByCol10` | 6010 |  |
| `cm_SrcSortByCol99` | 6099 |  |
| `cm_TrgSortByCol1` | 6101 | Sort by first column |
| `cm_TrgSortByCol2` | 6102 | Sort by second column |
| `cm_TrgSortByCol3` | 6103 | (target window) |
| `cm_TrgSortByCol4` | 6104 | etc. |
| `cm_TrgSortByCol5` | 6105 |  |
| `cm_TrgSortByCol6` | 6106 |  |
| `cm_TrgSortByCol7` | 6107 |  |
| `cm_TrgSortByCol8` | 6108 |  |
| `cm_TrgSortByCol9` | 6109 |  |
| `cm_TrgSortByCol10` | 6110 |  |
| `cm_TrgSortByCol99` | 6199 |  |
| `cm_LeftSortByCol1` | 6201 | Sort by first column |
| `cm_LeftSortByCol2` | 6202 | Sort by second column |
| `cm_LeftSortByCol3` | 6203 | (left window) |
| `cm_LeftSortByCol4` | 6204 | etc. |
| `cm_LeftSortByCol5` | 6205 |  |
| `cm_LeftSortByCol6` | 6206 |  |
| `cm_LeftSortByCol7` | 6207 |  |
| `cm_LeftSortByCol8` | 6208 |  |
| `cm_LeftSortByCol9` | 6209 |  |
| `cm_LeftSortByCol10` | 6210 |  |
| `cm_LeftSortByCol99` | 6299 |  |
| `cm_RightSortByCol1` | 6301 | Sort by first column |
| `cm_RightSortByCol2` | 6302 | Sort by second column |
| `cm_RightSortByCol3` | 6303 | (right window) |
| `cm_RightSortByCol4` | 6304 | etc. |
| `cm_RightSortByCol5` | 6305 |  |
| `cm_RightSortByCol6` | 6306 |  |
| `cm_RightSortByCol7` | 6307 |  |
| `cm_RightSortByCol8` | 6308 |  |
| `cm_RightSortByCol9` | 6309 |  |
| `cm_RightSortByCol10` | 6310 |  |
| `cm_RightSortByCol99` | 6399 |  |

### 2.23 Custom Column Views

49 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_SrcCustomView1` | 271 | Source: Custom columns 1 |
| `cm_SrcCustomView2` | 272 | (user defined columns) |
| `cm_SrcCustomView3` | 273 | etc. |
| `cm_SrcCustomView4` | 274 |  |
| `cm_SrcCustomView5` | 275 |  |
| `cm_SrcCustomView6` | 276 |  |
| `cm_SrcCustomView7` | 277 |  |
| `cm_SrcCustomView8` | 278 |  |
| `cm_SrcCustomView9` | 279 | etc. until 299 |
| `cm_TrgCustomView1` | 421 | Target: Custom columns 1 |
| `cm_TrgCustomView2` | 422 | (user defined columns) |
| `cm_TrgCustomView3` | 423 | etc. |
| `cm_TrgCustomView4` | 424 |  |
| `cm_TrgCustomView5` | 425 |  |
| `cm_TrgCustomView6` | 426 |  |
| `cm_TrgCustomView7` | 427 |  |
| `cm_TrgCustomView8` | 428 |  |
| `cm_TrgCustomView9` | 429 | etc. until 449 |
| `cm_LeftCustomView1` | 71 | Left: Custom columns 1 |
| `cm_LeftCustomView2` | 72 | (user defined columns) |
| `cm_LeftCustomView3` | 73 | etc. |
| `cm_LeftCustomView4` | 74 |  |
| `cm_LeftCustomView5` | 75 |  |
| `cm_LeftCustomView6` | 76 |  |
| `cm_LeftCustomView7` | 77 |  |
| `cm_LeftCustomView8` | 78 |  |
| `cm_LeftCustomView9` | 79 |  |
| `cm_RightCustomView1` | 171 | Right: Custom columns 1 |
| `cm_RightCustomView2` | 172 | (user defined columns) |
| `cm_RightCustomView3` | 173 | etc. |
| `cm_RightCustomView4` | 174 |  |
| `cm_RightCustomView5` | 175 |  |
| `cm_RightCustomView6` | 176 |  |
| `cm_RightCustomView7` | 177 |  |
| `cm_RightCustomView8` | 178 |  |
| `cm_RightCustomView9` | 179 |  |
| `cm_SrcNextCustomView` | 5501 | Source: Next custom view |
| `cm_SrcPrevCustomView` | 5502 | Source: Previous custom view |
| `cm_TrgNextCustomView` | 5503 | Target: Next custom view |
| `cm_TrgPrevCustomView` | 5504 | Target: Previous custom view |
| `cm_LeftNextCustomView` | 5505 | Left: Next custom view |
| `cm_LeftPrevCustomView` | 5506 | Left: Previous custom view |
| `cm_RightNextCustomView` | 5507 | Right: Next custom view |
| `cm_RightPrevCustomView` | 5508 | Right: Previous custom view |
| `cm_LoadAllOnDemandFields` | 5512 | Load on demand fields for all files |
| `cm_LoadSelOnDemandFields` | 5513 | Load on demand fields for selected files |
| `cm_ContentStopLoadFields` | 5514 | Stop loading on demand fields |
| `cm_LeftSwitchToThisCustomView` | 5510 | For scripting, lparam=view |
| `cm_RightSwitchToThisCustomView` | 5511 | For scripting, lparam=view |

### 2.24 View Modes

41 commands.

| Command | Nr | Description |
|---|---:|---|
| `cm_ToggleAutoViewModeSwitch` | 2947 | Turn automatic view mode switching on/off |
| `cm_SrcViewMode0` | 8500 | Source: Default view mode (no colors or icons) |
| `cm_SrcViewMode1` | 8501 | Source: View mode 1 |
| `cm_SrcViewMode2` | 8502 | (e.g. for tab and background colors) |
| `cm_SrcViewMode3` | 8503 | etc. |
| `cm_SrcViewMode4` | 8504 |  |
| `cm_SrcViewMode5` | 8505 |  |
| `cm_SrcViewMode6` | 8506 |  |
| `cm_SrcViewMode7` | 8507 |  |
| `cm_SrcViewMode8` | 8508 |  |
| `cm_SrcViewMode9` | 8509 | etc. until 8749 |
| `cm_TrgViewMode0` | 8750 | Target: Default view mode (no colors or icons) |
| `cm_TrgViewMode1` | 8751 | Target: View mode 1 |
| `cm_TrgViewMode2` | 8752 | (e.g. for tab and background colors) |
| `cm_TrgViewMode3` | 8753 | etc. |
| `cm_TrgViewMode4` | 8754 |  |
| `cm_TrgViewMode5` | 8755 |  |
| `cm_TrgViewMode6` | 8756 |  |
| `cm_TrgViewMode7` | 8757 |  |
| `cm_TrgViewMode8` | 8758 |  |
| `cm_TrgViewMode9` | 8759 | etc. until 8999 |
| `cm_LeftViewMode0` | 8000 | Left: Default view mode (no colors or icons) |
| `cm_LeftViewMode1` | 8001 | Left: View mode 1 |
| `cm_LeftViewMode2` | 8002 | (e.g. for tab and background colors) |
| `cm_LeftViewMode3` | 8003 | etc. |
| `cm_LeftViewMode4` | 8004 |  |
| `cm_LeftViewMode5` | 8005 |  |
| `cm_LeftViewMode6` | 8006 |  |
| `cm_LeftViewMode7` | 8007 |  |
| `cm_LeftViewMode8` | 8008 |  |
| `cm_LeftViewMode9` | 8009 | etc. until 8249 |
| `cm_RightViewMode0` | 8250 | Right: Default view mode (no colors or icons) |
| `cm_RightViewMode1` | 8251 | Right: View mode 1 |
| `cm_RightViewMode2` | 8252 | (e.g. for tab and background colors) |
| `cm_RightViewMode3` | 8253 | etc. |
| `cm_RightViewMode4` | 8254 |  |
| `cm_RightViewMode5` | 8255 |  |
| `cm_RightViewMode6` | 8256 |  |
| `cm_RightViewMode7` | 8257 |  |
| `cm_RightViewMode8` | 8258 |  |
| `cm_RightViewMode9` | 8259 | etc. until 8499 |

*Basis: TOTALCMD.INC as shipped; every row checked by script against `inc.txt` (594 rows).*

## 3. Commands with parameters

These text commands are typed into the *Command* field of a button, menu item, Start-menu item, hotkey or `em_` command, followed by a space and the parameter. They are not `cm_` commands: the INC lists them in the category *Commands with Parameters* with negative numbers that serve only to translate the descriptions (§1.2).

### 3.1 The 27 commands

Columns *Command*, *Parameter* and *Description* are the INC text verbatim.

| Command | Parameter | Translation ID | Description |
|---|---|---:|---|
| `CD` | `<directory>` | -2 | Switch to the given directory |
| `OPENTABS` | `<filename>` | -3 | Open tabs from saved .tab file (supports modifiers L and R) |
| `APPENDTABS` | `<filename>` | -4 | Append tabs to existing tabs (supports modifiers L and R) |
| `FTPOPEN` | `<conf. ftp server>` | -5 | Open stored ftp connection |
| `SYNCOPEN` | `<sync operation>` | -6 | Open stored sync operation |
| `LOADSEARCH` | `<stored search>` | -7 | Open stored search operation |
| `OPENBAR` | `<filename>` | -8 | Load button bar from file |
| `MULTIRENAME` | `<operation name>` | -9 | Open stored multi-rename operation |
| `OPENCUSTOMVIEW` | `<view name>` | -10 | Switch to custom columns view (supports modifiers L, R, S, T and B) |
| `SELECTFILES` | `<*.ext *.ex2>` | -11 | Select files of specified types (supports modifiers D, B, U, L, R, T and S) |
| `CM_WAIT` | `<time>` | -12 | Wait x milliseconds |
| `SAVETABS` | `<filename>` | -13 | Save tabs to .tab file, active side |
| `SAVETABSL` | `<filename>` | -14 | Save tabs to .tab file, left side |
| `SAVETABSR` | `<filename>` | -15 | Save tabs to .tab file, right side |
| `SAVETABS2` | `<filename>` | -16 | Save tabs to .tab file, both sides (active=first) |
| `SAVETABS2L` | `<filename>` | -17 | Save tabs to .tab file, both sides (left=first) |
| `SAVETABS2R` | `<filename>` | -18 | Save tabs to .tab file, both sides (right=first) |
| `OPENLANGUAGEFILE` | `<wcmd_xyz.lng>` | -19 | Open specific LNG/MNU file pair from 'language' subdir |
| `OPENBAR1` | `<filename>` | -20 | Load main button bar from file |
| `OPENBAR2` | `<filename>` | -21 | Load vertical button bar from file |
| `SAVESELECTION` | `<filename>` | -22 | Save selection to file (supports modifiers A and W) |
| `SAVEDETAILS` | `<filename>` | -23 | Save selection with all details to file (supports modifiers A, W and H) |
| `LOADSELECTION` | `<filename>` | -24 | Load selection from file |
| `LOADLIST` | `<filename>` | -25 | Load complete list (like search result) from file (supports modifier 0 = no error dialogs) |
| `ZIPFROMLIST` | `<archive name> <filelist>` | -26 | Pack files from list (supports parameters -m, -o, -os, -on, -c0..-c3 and -0..-9) |
| `OPENATTRIBUTES` | `<parameters>` | -27 | Change Attributes dialog: +f (subfolders), +a/-a +r/-r +h/-h +s/-s +L/+L2 +c +dDate +tTime Plugin_settings |
| `OPENBARMENU` | `<filename>` | -28 | Open button bar file as dropdown menu |

### 3.2 Modifier suffixes

A modifier is appended directly to the command name, with no space: `OPENTABSL`, `SELECTFILESDUT`, `SAVEDETAILSHW`.

| Command | Suffixes | Meaning |
|---|---|---|
| OPENTABS, APPENDTABS | L, R | Open or append the tabs on the left / right side instead of the active side. With no parameter a file-open dialog asks for the `.tab` file. |
| OPENCUSTOMVIEW | L, R, S, T, B | Left / right / source / target / both panels, e.g. `OPENCUSTOMVIEWL my_view`. The view name is case-sensitive; the first custom-columns view with that name is used. |
| SELECTFILES | D, B, U, L, R, T, S | D = only folders, B = files and folders, U = unselect instead of select, L / R = left / right panel, T = target panel, S = also mark folders when Shift is held while the command runs. Any meaningful combination is allowed (`selectfilesD`, `selectfilesDUT`). |
| SAVETABS, SAVETABS2 | L, R | `SAVETABS` / `L` / `R` save one side (active / left / right); `SAVETABS2` / `2L` / `2R` save both sides, with the active / left / right side written first. Separate INC entries (§3.1). |
| OPENBAR | 1, 2 | `OPENBAR` loads into the bar that contains the button; `OPENBAR1` = main (horizontal) bar, `OPENBAR2` = vertical bar. Separate INC entries. |
| SAVESELECTION | A, W | A = save as ANSI, W = save as UTF-16. No suffix: depends on the OS (Unicode on NT-based Windows). |
| SAVEDETAILS | H, A, W | H (directly after DETAILS) = write a header line. A / W as above. |
| LOADLIST | 0 | `LOADLIST0` shows no error messages for files that cannot be found. |

### 3.3 Leading `=` in the parameter

| Command | `=name` | `==name` |
|---|---|---|
| SYNCOPEN | Start the comparison immediately. `=` alone compares the current directories with the last-used options. | — |
| LOADSEARCH | Start the search immediately. | Show the results directly in the file panel (empty list if nothing is found). |
| MULTIRENAME | Start renaming immediately if the settings load. The special name `<UNDO>` reverses the last multi-rename. | Also close the tool when there were no errors. |
| OPENATTRIBUTES | `=` at the start of the parameters applies the attributes without showing the dialog. | — |

### 3.4 Rules per command

- **CD** `<directory>`
  - Changes the source panel to the directory. `cd dir\*.txt` also sets the panel's file filter, but not when `cd` is combined with other commands in a chain; in a chain the path is written in double quotes: `cd "c:\windows",cm_SelectAll,cm_Copy`.
  - Accepts virtual folders (`cd shell:Fonts`, `cd ::{GUID}`), UNC paths and `cd ftp://ftp.server.com`.
  - `/user:` (lower case) connects to a share as the given user; without a name TC asks for user name and password: `cd \\server\share /user:username`.
  - On a button, when the command is `cd drive:\directory`, the button's *Start path* is set in the **other** panel, so one button can set both panels.
- **FTPOPEN** `<session>` opens a connection saved in the FTP connect dialog. `FTPOPEN session|/subdir` connects (in the preferred panel) unless already connected and then changes to the subdirectory; `FTPOPEN session|*/subdir` does the same but always in the active panel (e.g. from Ctrl+D).
- **CM_WAIT** `<ms>` pauses inside a chain: `cm_SelectAll,cm_wait 1000,cm_Copy`. The help also lists it among the `cm_` commands with a parameter as `cm_Wait`.
- **OPENBAR**, **OPENBAR1**, **OPENBAR2**, **OPENBARMENU** take a `.bar` file; `*` stands for the default bar defined for the main / vertical bar (`OPENBAR1 *`). OPENBARMENU opens the bar as a drop-down menu and works only while a top button bar exists; a bar in the current directory must be written `.\filename.bar`.
- **SELECTFILES** takes masks such as `*.txt *.doc`, or a saved selection type as `>name` (mask syntax: 18 › File masks and selection types).
- **SAVESELECTION**, **SAVEDETAILS** write the selected names (with all details) to the file; **LOADSELECTION** restores a selection and reads ANSI and UTF-16 files.
- **LOADLIST**: one name per line; names without a path are relative to the current directory; wildcards allowed, regular expressions not. File details are read automatically and the panel shows the list like a search result. The start-up form `LOADLIST:path\listfile.txt` can be used instead of a directory when starting TC (19 › Command-line switches).
- **ZIPFROMLIST**: the *Command* field holds the zip name and the *Parameters* field the list file. Alternatively the zip name goes at the start of the parameters, in double quotes if it has spaces. The list is one file per line, in ANSI, UTF-16 or UTF-8 (BOM optional for UTF-8). `%F` can supply the selected files of the active panel. Switches go before the zip name, in the Command field only: `-m` move, `-o` overwrite without asking, `-os` skip all, `-on` overwrite all older, `-0`…`-9` compression rate, `-c0` ZIP 2.0 encryption, `-c1` AES-128, `-c2` AES-192, `-c3` AES-256, `-c0pass`…`-c3pass` encrypt with the given password.
- **OPENATTRIBUTES** presets the Change Attributes dialog (07 › Change attributes): `+a`/`-a`, `+r`/`-r`, `+h`/`-h`, `+s`/`-s` set or clear a bit; `+f`/`-f` do or do not apply to files in subfolders; `+d` / `+t` set the date / time field (INC form `+dDate`, `+tTime`; the token must be followed by a space or end the parameters); `+c` uses the current date and time (`+c +t` changes only the date); `+L` or `+L1` (either case) loads the attributes from the file under the cursor, `+L2` from the file under the cursor in the other panel; a trailing `<Settings>` loads saved plugin options; a leading `=` applies without the dialog (§3.3).
- **OPENLANGUAGEFILE** `<wcmd_xyz.lng>` loads an LNG/MNU pair; `<file>.MNU` changes only the menu (16 › Switching the language).

### 3.5 General rules

- The parameter follows after one space; suffix letters are appended to the name (§3.2).
- These commands work on buttons, menu items, Start-menu items, hotkeys (also Win-key hotkeys in `[ShortcutsWin]`) and in `em_` definitions, including their suffix variants (`SELECTFILEST`, `OPENTABSL`).
- When used in internal associations and user-defined hotkeys they also accept placeholders such as `%P%N` (18 › Button and command parameters).
- SAVETABS, SAVETABSL, SAVETABSR, SAVETABS2, SAVETABS2L, SAVETABS2R, SELECTFILES, LOADSELECTION and OPENLANGUAGEFILE accept a path in double quotes directly in the Command field.

*Basis: TOTALCMD.INC; help: dlg_configbuttonbar, dlg_choosecommand, options_setattr; history (quotes, placeholders, hotkey use).*

## 4. Parameters of `cm_` commands

### 4.1 How a parameter is given

Many ordinary `cm_` commands take an optional parameter after a space, for example `cm_Copy /V0 /B2`, `cm_SrcByName 2`, `cm_Exit 1` or `cm_SwitchHidSys 5`. It is written after the name in the Command field, or in the *Parameters* field (the latter only when the command is not part of a chain). Observed on Windows: `cm_SwitchHidSys 5` (set, do not save) showed hidden and system files; `cm_ZoomIn 200` doubled the thumbnail size immediately and `cm_ZoomOut 100` restored it.

### 4.2 Patterns

| Pattern | Commands | Values |
|---|---|---|
| Dialog options as `/` switches | `cm_Copy`, `cm_RenMov`, `cm_PackFiles`, `cm_UnpackFiles`, `cm_Edit`, `cm_MkDir`, `cm_CreateShortcut` | each checkbox takes `1`/`0`; `G` = go immediately; `T="…"` = target |
| Tri-state toggle with no-save | `cm_SwitchHidSys`, `cm_SwitchLongNames`, `cm_Vis…`, … (§4.4) | `0`/none toggle, `1` set, `2` or `-1` reset; `+4` = do not save to wincmd.ini |
| Tri-state toggle (always saved) | `cm_*Thumbs`, `cm_*QuickView`, `cm_DirBranch`, `cm_VerticalPanels`, `cm_SyncChangeDir`, … (§4.4) | `0`/none toggle, `1` set, `2` or `-1` reset |
| Sort | `cm_*ByName/ByExt/BySize/ByDateTime` | `0` toggle, `1` asc, `2` desc, `+4` add as extra sort column, `8` store, `9` restore |
| Count / index | `cm_Select`, `cm_SelectAll*`, `cm_GoToFirstEntry`, `cm_*ActivateTab*`, `cm_OpenDriveByIndex` | numbers; negative counts from the end |
| Bit sum | `cm_Exit`, `cm_UnloadPlugins`, `cm_Copy…FileDetailsToClip` … | add the values together |

### 4.3 Commands and their parameters

`*` stands for `Src`, `Left`, `Right` (and `Trg` where noted).

| Command(s) | Parameter semantics |
|---|---|
| `cm_Copy`, `cm_RenMov` | Every dialog option, as `/`-prefixed switches. Checkbox options take `1` or `0` (`V0` = verify off). `P` copy NTFS permissions · `V` verify · `B0` foreground (overrides `AlwaysCopyInBackground`), `B1` background (like F5 › Enter › Background), `B2` background transfer manager · `O0`…`O9` overwrite mode (numbers as in the dialog) · `R` keep relative paths from branch view (`R`/`R1` yes, `R0` no) · `S` skip all unreadable files · `H` overwrite or delete hidden/system/read-only files (`H0` does not re-enable confirmations turned off on the Misc page) · `A` copy to all folders selected in the target panel · `G` start immediately · `T="path"` target: must be quoted and end in `\`, or in a wildcard mask to rename · `W="wildcards"` copy only these types; quotes inside are doubled. Example: `cm_Copy /V0H1T="c:\test\"W="""a test.*"" test2.*"` |
| `cm_CreateShortcut` | `O`, `G`, `T`, `W` as for cm_Copy. With `T`, a missing `\*.lnk` or `\*.*.lnk` is appended. |
| `cm_PackFiles` | `T="archive"`: `T=""` or `T="."` = source directory with the default name; `T="c:\path\."` = that path with the default name · `D` store paths (recursed only) · `R` recurse · `S` multi-volume (ZIP, 7-Zip, ARJ, RAR, ACE) · `M` move · `X` self-extracting · `O0`…`O4`, `O7`, `O8` overwrite modes (5, 6, 9 not supported) · `A` one archive per selected item · `B` leave out the base folder · `C` encryption: 0 ZIP 2.0, 1/2/3 AES-128/192/256, −1 last used · `P="password"` (needs `C`) · `G` go · `E="ext"` packer type as in the Pack dialog · `F="opts"` extra 7-Zip options (e.g. `/F="-m0=PPMD -mhc=on"`) · `Z0`…`Z10` ZIP level (0 stored, 10 LZMA; GZ/TGZ use 1…9) |
| `cm_UnpackFiles` | `T="path"`, which must be quoted; `T="."` = next to the archive · `D` with paths · `O0`…`O4`, `O7`, `O8` · `S` one subfolder per archive · `P="pwd"` (ZIP, RAR, internal 7-Zip) · `A="pwd"` archive password for encrypted names (internal 7-Zip) · `G` go · `W="wildcards"` with doubled inner quotes (`/W="file1.txt ""file 2.txt"" file3.txt"`); `/W=""` unpacks the selected files of an open archive (like F5) |
| `cm_Edit` | `C` create the file if missing; with several names (or a range) the editor is not started (implies `L0`) · `T` like C, but copies the first template with the same extension from the user's template folder (empty file if none) · `T="c:\dir"` own template folder · `N="a\|b"`, `N=<a\|b>` or `N=<"a" "b">` names (angle brackets are needed when any name is quoted; the "+" templates of the New-file dialog work too); an existing file is only opened · `G` create immediately (with C/T) · `L0` do not launch (with C/T), `L1` default editor (default except with C/T), `L2` associated program including internal associations, `L3` associated program without internal ones · `V="verb"` verb for L2/L3 (`V=""` default verb). With L1, WinExec is used without V, ShellExecuteEx with V; L2/L3 always use ShellExecuteEx. |
| `cm_MkDir` | `N="…"` names, same quoting rules (`N=<"a"\|"b">`); F7 "+" templates allowed · `G` go · `L0` just create, `L1` create and place the cursor on it (the last one), `L2` create and open (the last one) · `S="dir"` base folder, created if missing · `s="dir"` base folder, must exist · `W` no warning on failure |
| `cm_List`, `cm_ListOnly`, `cm_ListInternalOnly` | A file name, optionally preceded by `/options` (as in the command-line switch `/S=L:`, without `S=L:`), e.g. `cm_List /T1V name` for text mode with a variable-width font |
| `cm_ListMulti`, `cm_ListInternalMulti` | Options plus at most one file name |
| `cm_ListExternal` | One optional file name |
| `cm_Wait` (= `CM_WAIT`, §3.4) | Delay in ms before the next command |
| `cm_Select`, `cm_Unselect`, `cm_Reverse` | Act on the next x files from the cursor |
| `cm_SelectAll`, `cm_SelectAllBoth`, `cm_SelectAllFolders`, `cm_SelectAllFiles`, `cm_ClearAll`, `cm_ClearAllFolders`, `cm_ClearAllFiles`, `cm_ClearAllCfg` | `0` = all; `n≥1` = every n-th line downward from the cursor (`cm_SelectAllFolders 2` = every second folder); `n≤−1` = upward |
| `cm_GoToFirstEntry`, `cm_GoToFirstFile` | Go n entries down from the first entry or first file (`1` = the second one) |
| `cm_LeftSwitchToThisCustomView`, `cm_RightSwitchToThisCustomView` | Custom view to switch to |
| `cm_SearchForInCurDir` | Drive letter to search |
| `cm_100Percent` | Width in percent for the active panel (e.g. 60) |
| `cm_50Percent` | Percent **added** to the active panel's width (`-10` turns 50 % into 40 %) |
| `cm_*ViewModeList` | `0` = default mode; `>0` = user mode with that index; text = first mode with that name |
| `cm_RereadSource` | `1` = refresh even if nothing changed (reload icons and overlays); `2` = re-apply the automatic view-mode switch; `3` = both |
| `cm_SwitchToNextTab` | `0`/none: without Ctrl always the next tab (differs from Ctrl+Tab); with Ctrl like Ctrl+Tab (honours "Ctrl+Tab switches to last visited") · `1` = last visited open tab (closed tabs are not reopened) · `2` = always the next tab |
| `cm_UnloadPlugins` | `0` = all types except tcmatch; otherwise a sum: 1 packer, 2 file system, 4 Lister, 8 content, 16 external tcmatch dll |
| `cm_*ActivateTab*` (* = Src, Trg, Left, Right) | `x>0` = tab x (`cm_SrcActivateTab1 5` activates tab 5); `x<0` = counted from the end (`-1` = last tab) |
| `cm_CloseCurrentTab` | `1` = close a locked tab without asking; `2` = then switch to the tab on the left |
| `cm_CloseAllTabs` | `1` = unlocked tabs, no confirmation; `2` = also locked tabs, with confirmation; `3` = also locked tabs, without confirmation |
| `cm_Copy…FileDetailsToClip` (6 variants: plain, `Fp`, `Net`, `Hdr`, `HdrFp`, `HdrNet`) | Column bit mask: 1 = name+ext, 2 = 1st extra column, 4 = 2nd, 8 = 3rd, … (`1` alone = full list with headers, kept for compatibility) |
| `cm_*OpenDrives` (also `cm_OpenDrives`) | Drive letter, or its number (65 = A, 66 = B, …), `\` = root, `.` = parent, `[` = network |
| `cm_OpenDriveByIndex` | 1…99 = n-th drive-letter button from the start (drive letters only) · 101+ = n-th button of any kind (101 = first) · −2…−99 = counted from the last drive letter · ≤ −101 = from the last button (−101 = last, −102 = second-last). Without a drive bar, ≤ −101 counts from the end of the drive combo (−101 = Network, −102 = Documents …). |
| `cm_ZoomIn`, `cm_ZoomOut` | Absolute thumbnail zoom in % (`cm_ZoomIn 150`) |
| `cm_*ByName`, `cm_*ByExt`, `cm_*BySize`, `cm_*ByDateTime` (* = Src, Trg, Left, Right) | `0`/none toggle, `1` ascending, `2` descending · `+4` add as an extra sort column (`cm_SrcBySize 5`) · `8` store the current sort order, direction and extra sort columns · `9` restore them |
| `cm_*NegOrder` | `0` toggle, `1` set, `-1`/`2` reset, `8` store, `9` restore |
| `cm_*SortByCol1` … `cm_*SortByCol99` (* = Src, Trg, Left, Right) | `0`/none: toggle and honour the keyboard (Shift = secondary sort on/off, Ctrl = flip the secondary direction). Other values ignore the keyboard: `1` ascending, `2` descending, `3` toggle, `+4` reverse the secondary direction, `+8` secondary sort on/off. |
| `cm_*UserSpec` | `8` store the current filter (including All / Programs); `9` restore it |
| `cm_EditNewFile` | `1` = create the file but do not open the editor |
| `cm_QuickFilter` | `1` = open with the last used filter |
| `cm_Exit` | `0`/none = just exit. Otherwise a sum of: `1` restart; `2` restart switching between 32 and 64 bit; `4` save directories, tabs and panels even if disabled; `8` pass the current directories and the file under the cursor to the new instance; `16` restart as administrator |
| `cm_CompareDirs`, `cm_CompareDirsWithSubdirs` | `0` = select files missing on the other side, newer, or with a different size at an equal timestamp · `1` = only missing files · `2` = different sizes plus missing files |
| `cm_*TabsList` (* = Src, Trg, Left, Right) | `0` = list by tab titles · `1` = by tab paths (quick search gets a leading `*`) · `2` = open quick search in the list (+1 for paths). Ctrl+Shift+A toggles between titles and paths. |
| `cm_DirectoryHotlist` | `0` = top-left of the active panel · `1` = at the mouse · `2` / `3` = below the right / left hotlist button (or the panel's top-right corner) · `4` / `5` = the same for the source / target panel · `+8` = show line numbers (also in the configuration dialog opened from the list) |

### 4.4 Tri-state commands

**With optional no-save.** Parameters: `0` or none = toggle, `1` = set, `-1` or `2` = reset. **Add 4 to keep the change out of wincmd.ini** (use 2 as the reset base, so 6, not 3). The commands: `cm_SwitchLongNames`, `cm_SwitchHidSys`, `cm_SwitchHid`, `cm_SwitchSys`, `cm_Switch83Names`, `cm_SwitchDirSort`, `cm_SwitchOverlayIcons`, `cm_SwitchIgnoreList`, `cm_SwitchX64Redirection`, `cm_SwitchFileTipWindows`, `cm_SwitchColorsByFileType`, `cm_ToggleAutoViewModeSwitch`, and the display toggles `cm_Vis…` (`cm_VisButtonBar`, `cm_VisButtonBar2`, `cm_VisDriveButtons`, `cm_VisTwoDriveButtons`, `cm_VisFlatDriveButtons`, `cm_VisFlatInterface`, `cm_VisDriveCombo`, `cm_VisCurDir`, `cm_VisBreadCrumbs`, `cm_VisTabHeader`, `cm_VisStatusBar`, `cm_VisCmdLine`, `cm_VisKeyButtons`, `cm_VisDirTabs`, `cm_VisXPthemeBackground`, `cm_VisHistHotButtons`; `cm_VisitHomepage` is not one of them).

**Without the no-save option.** The same three values, no +4: `cm_FtpHiddenFiles`, `cm_*Comments`, `cm_DirBranch`, `cm_LeftDirBranch`, `cm_RightDirBranch`, `cm_DirBranchSel`, `cm_LeftDirBranchSel`, `cm_RightDirBranchSel`, `cm_SrcThumbs` / `cm_LeftThumbs` / `cm_RightThumbs`, `cm_*QuickView`, `cm_*QuickInternalOnly`, `cm_SeparateQuickView`, `cm_SeparateQuickInternalOnly`, `cm_SyncChangeDir`, `cm_SwitchWatchDirs`, `cm_VerticalPanels`, `cm_ShowCmdLineHistory`.

*Basis: observed on Windows 11 (`cm_SwitchHidSys 5`, `cm_ZoomIn 200`); help: dlg_choosecommand, dlg_configbuttonbar.*

## 5. User commands (`em_`)

- User commands use the prefix `em_` and are defined in the *Choose command* dialog on the `usercmd.ini` page (definition dialog, storage and editing: 14 › User commands (`em_`)). A fresh installation has no `usercmd.ini` entries.
- Each section `[em_Name]` of `usercmd.ini` defines one command; `cmd=` is attested, and the other keys mirror a button definition (command, parameters, start path, icon, tooltip, window state).
- An `em_` command can be used anywhere a `cm_` command can (main menu, hotkeys, buttons, Start menu, internal associations, view-mode auto-run) and, unlike a plain menu item or hotkey, can run a program **with parameters**.
- Its internal number is assigned at run time (10000 and up) and is not stable; it cannot be used like a `cm_` number.
- A language can ship its own `wcmd_<lang>.ini` with more `em_` commands; when the same name exists in both files, the tooltip comes from `wcmd_<lang>.ini` (16 › Language components).

*Basis: help: dlg_choosecommand, dlg_configbuttonbar; history.*
