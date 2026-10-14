# 09: Search, rename, synchronize, compare

This chapter specifies Total Commander's bulk search and comparison tools: Find Files (Alt+F7) with its result handling, duplicate finder and saved searches; the Multi-Rename Tool (Ctrl+M); the panel commands Compare Directories (Shift+F2) and Mark Newer, Hide Same Files; Synchronize Directories, including synchronizing with an FTP server; and the internal Compare by content tool. For each tool it gives the window, every control, the matching or comparison rules, the state changes it causes, and the settings it keeps.

**Related:** 03 File panels (selection, branch view, display filters), 06 Keyboard (key reference for these tools), 07 File operations (Copy filter, Overwrite dialog, auto-rename), 11 FTP and network (FTP client, MLSD, server features), 15 Plugins (content plugins, Choose plugin property), 17 Internal commands, 18 Syntax reference (placeholder grammar, file masks, regular expressions, plugin-rule operators, content fields), 19 Settings files and command line.

## 1. Entry points

| Feature | Command (id) | Default key / menu | Parameter and command-line forms |
|---|---|---|---|
| Find Files | `cm_SearchFor` (501) | Alt+F7; Commands › Search… | `LOADSEARCH <name>` opens a saved search; `LOADSEARCH =<name>` also starts it; `LOADSEARCH ==<name>` starts it and feeds the results to the listbox when done |
| Find Files in the directory under the cursor | `cm_SearchForInCurDir` (517) | — | — |
| Find Files in a separate process | `cm_SearchStandalone` (545) | Alt+Shift+F7; Commands › Search in separate process… | `totalcmd.exe /S=F "c:\start path"`, with optional parameters after `:`: `S<n>` sorts the results by 1 name, 2 extension, 3 size, 4 date/time (negative = descending); `S*` takes the sort order from the running TC; `L<name>` loads a saved search, `L=<name>` loads and starts it, `L==<name>` also feeds the results to the listbox. `L…` must come last, e.g. `/S=F:S1Lname` |
| Multi-Rename Tool | `cm_MultiRenameFiles` (2400) | Ctrl+M; Files › Multi-Rename Tool… | `MULTIRENAME <saved>` opens with saved settings (an unknown name gives the defaults); `MULTIRENAME =<saved>` renames at once; `MULTIRENAME ==<saved>` renames and closes the tool if successful; `MULTIRENAME <UNDO>` opens and offers to undo the last operation; `MULTIRENAME ==<UNDO>` undoes without asking, unless a saved setting with that literal name exists |
| Compare directories | `cm_CompareDirs` (533) | Shift+F2; Mark › Compare Directories | — |
| Compare, also marking subdirectories missing on the other side | `cm_CompareDirsWithSubdirs` (536) | — | — |
| Mark newer, hide same | `cm_DirMatch` (534) | Mark › Mark Newer, Hide Same Files | — |
| Synchronize directories | `cm_FileSync` (2020) | Commands › Synchronize Dirs… | `SYNCOPEN <name>` opens a saved set; `SYNCOPEN =<name>` also compares at once; `SYNCOPEN =` compares at once with the last options. Command line: `/S=S <dir1> <dir2>`, `/S=S:<name>`, `/S=S:=<name>` (compare at once), `/S=S:=` (compare the passed directories with the last options); `/O=<listfile>` passes the list for *Only selected* |
| Compare by content | `cm_CompareFilesByContent` (2022) | Files › Compare By Content…; Ctrl+F3 in Synchronize and in the Overwrite dialog | `/S=C <file1> <file2>`; button parameters `%C1` / `%C2` pick the files by the same rules (§6.1) |
| Compare by content with the internal tool | `cm_IntCompareFilesByContent` (2040) | Ctrl+Shift+F3 in the Overwrite dialog | Uses the internal tool even when `Comparetool=` names an external one |

- The standalone Find, Synchronize and Compare windows (started with `/S=…`) can be started minimized or maximized.
- The command-line switches are listed in 19 › Command-line switches; the `cm_` commands in 17 › Command catalogue, and `LOADSEARCH`, `MULTIRENAME`, `SYNCOPEN` in 17 › Commands with parameters.

*Basis: help: options_search, commandlineparameters, options_compare, options_marknewer, dlg_overwrite; inc.txt; WCMD_ENG.MNU; HISTORY.TXT.*

## 2. Find Files

### 2.1 Window and modes

Find Files is a resizable window titled **"Find Files"** with four tabs, **General**, **Advanced**, **Plugins** and **Load/Save**, and a fixed button column on the right: **[Start search] [Cancel] [Help]**. Alt+F7 opens it on the General tab with *Search in* pre-filled with the current path of the active panel.

The same dialog runs in three modes:

| Mode | Opened by | Differences |
|---|---|---|
| Internal | Alt+F7, `cm_SearchFor` | Runs inside TC. Results can be fed to the active panel (§2.11). TC is not usable for other work while the search runs; use the separate process for that. |
| Separate process | Alt+Shift+F7, `/S=F` | Runs as its own program, so TC stays usable and several searches can run in parallel. Title **"Find Files (separate)"**, plus the name of loaded settings. FTP start paths are **not available**. *Only search in selected directories/files* is evaluated when the dialog opens; as soon as the focus moves to another window, the option is **unchecked** and a warning icon is shown, because the panel selection may change. Later selection changes never affect a running search. Feed to listbox and *Search in found files* work. Searching in fed search results and in selected files works too. |
| Template ("Define selection") | The **Define...** button of the selection dialogs (Num+ / Num−, Show › Custom, the Copy dialog's *Only files of this type*, the Synchronize *Search filter*, colour definitions) | Title **"Define selection"**, buttons **[Save] [Cancel] [Help]**. *Search in*, its `>>` and **Drives** are disabled. The saved definition becomes a saved search, usable as a **selection type** (§2.9). |

### 2.2 General tab

```
Search for:  [                                                  ▾]
Search in:   [c:\users                                      ▾] [>>] [Drives]
[ ] RegEx          [ ] Only search in selected directories/files   (disabled if none)
[ ] 'Everything'   [ ] Search archives (all except for UC2)
                   Search in subdirectories:  [all (unlimited depth) ▾]
────────────────────────────────────────────────────────────────────
[ ] Find text:  [                                                ▾]
     [ ] Whole words only                [x] ANSI charset (Windows)
     [ ] Case sensitive                  [ ] ASCII charset (DOS)
     [ ] RegEx (2)                       [ ] Unicode UTF16
     [ ] Hex                             [ ] UTF8
     [ ] Find files NOT containing the text [ ] Office xml (docx, xlsx, odt etc.)
                                    [±] [ ] Plugins:
Search results:          [<] [>] [ ] F2 Search in found files/folders
```

- **Search in subdirectories** offers `all (unlimited depth)` (default), `current dir only`, `1 level(s)`, `2 level(s)`, … (upper limit not recorded). Depth counts from each start path.
- The *Find text* sub-options are enabled only while *Find text* is checked. *ANSI charset* is ticked by default.
- `[<] [>]` and *F2 Search in found files/folders* act on result sets (§2.10).

### 2.3 "Search for"

The field is an editable combo. Its history holds up to `MaxItemsInComboBox` entries (default 20, max 500) of at most 2046 characters each, stored in `[SearchName]`; **Shift+Del** removes the highlighted history entry.

It accepts the Find Files mask language, whose grammar is in 18 › Find Files and copy-filter forms (core wildcards and `|`: 18 › Core syntax):

- several masks separated by spaces, with `*` and `?` (`*.bak *.sik *.old`; `*wof*.doc` = names containing "wof" with the extension `.doc`); names with spaces unquoted when there is no `|` (the whole string and each part are tried), quoted when there is one;
- `|` followed by exclude masks;
- a token without wildcards **and without a dot** is a substring match (`Smith` finds "Letter to Mr. Smith.doc"); a token **with a dot** is an **exact name match**, so searching `.ini` in `c:\users` gives "[No files found]";
- `\**\` in path patterns, and directory (traverse) filters ending in `\` (`name\`, `\name\`, `.\name\`, `\`, `…\**\`), including `| \` (exclude the base directory) and `|**\` (skip directories without hits);
- a start path typed here instead of in *Search in*;
- the prefixes `ev:` / `ed:`, which hand the string to *Everything* (§2.13) and tick the *Everything* checkbox automatically;
- a `>` typed before saving a search, which leaves this field unchanged when the saved search is loaded later (§2.9).

With the **RegEx** checkbox (the first one on the tab), the whole field is one regular expression matched against file names, case-insensitive by default (18 › Regular expressions).

### 2.4 "Search in": start paths, drives, list files

- Several start paths are separated by `;`. They must all be of **one kind**: all local, all FTP (e.g. `0:/home/u/a;0:/home/u/b`) or all from the same file-system plugin. Local and FTP may not be mixed.
- The start may be **inside an archive**. Environment variables and network paths are accepted. Folders under "My Computer" / "Network Neighborhood" that point to real directories are searched.
- **`>>`** opens the Windows **"Browse for Folder"** dialog (a tree from Desktop; [Make New Folder] [OK] [Cancel]).
- **Drives** opens **"Select drives"**: a "Drives to search:" multi-select list of the drive letters, plus [Local Harddisks] (selects all local disks) [OK] [Cancel]. With `HideRemovableNoMedia` bit 4, removable drives without media are not offered. Its position (`DriveSel*`) is stored relative to the Find dialog.
- **`>`** when saving works as in *Search for*: the field stays unchanged when the search is loaded.

**List-file search `@c:\path\list.txt`.** The file may be ANSI, UTF-8 with BOM or UTF-16 with BOM. It holds one entry per line: an absolute path, or a path relative to the list file's folder. Lines may contain wildcards or regular expressions.

| Line in the list | Depth ≥ 1 level or all | Depth "current dir only" |
|---|---|---|
| `c:\testdir\filename.txt` | only that file (depth irrelevant) | only that file |
| `c:\testdir\` | searches **inside** it for *Search for*; the directory itself is not a result | returns `c:\testdir` **itself**; *Search for* is ignored |
| `c:\testdir\*.txt *.doc` | searches `c:\testdir` for these masks; *Search for* is ignored for this line | line ignored |
| `c:\testdir\<regex` | regex search in `c:\testdir`; *Search for* is ignored for this line | line ignored |

With depth "current dir only" the search behaves like loading a file list: only the listed items are found, never their contents, and *Search for* is ignored.

### 2.5 Location options

| Option | Semantics |
|---|---|
| **Only search in selected directories/files** | Only the items selected in the **active panel** are searched; selected directories recursively, subject to the depth. Disabled when nothing is selected. Started from a search-result panel (§2.11), the dialog behaves as if all listed files were selected. Separate process: see §2.1. |
| **'Everything'** | Use the external *Everything* index (§2.13). Shown according to `UseEverything`: −1 hidden, 0 disabled, 1 (default) enabled if present. |
| **Search archives** (all except for UC2) | Treat archives as folders: ZIP, ARJ, LZH, RAR, TAR, GZ, CAB, ACE, 7Z, packer plugins that declare the "searchable" capability (128), and extra masks from `SearchInFiles=` (e.g. `*.EXE *.JAR`). Text can be searched inside archives too. Members are extracted, searched and deleted on the fly; members under 1 MB of ZIP, RAR and 7Z are unpacked to memory. The checkbox shows a warning "!" icon when it was left enabled from an earlier search (`ShowWarningIcons=1`). |
| **Search in subdirectories** | `all (unlimited depth)` / `current dir only` / `1…n level(s)`, counted from each start path. |
| Hidden/system folders | When hidden/system files are not displayed in the panels, the normal search does **not** descend into hidden/system folders. Everything results include them. |
| Directory links | `IgnoreLinks` bit 8 makes the search skip junctions/directory links (not with Everything). |

### 2.6 "Find text" (content search)

- **Escapes:** `\t` = tab, `\n` = line break, `\\` = a literal backslash. They work in all encodings.
- **Whole words only.**
- **Case sensitive.** Without it, case variants match (`Windows` with the option finds only "Windows", not "WINDOWS").
- **RegEx (2).** The text is a regular expression, matched line by line; supported in ANSI, UTF-16, UTF-8 and Office-XML modes (dialect: 18 › Regular expressions).
- **Hex.** The text is a hex byte string (`00 FF 12`); quoted literal text can be mixed in (`"PK"0102`). Without *Case sensitive*, a byte that is the code of a **lowercase** letter also matches its uppercase variant (`6B` finds `k` and `K`); typing the uppercase code matches only uppercase.
- **Find files NOT containing the text.** Inverts the text criterion; all other criteria must still match.
- **Encodings** may be combined; a file matches if the text is found in **any** chosen encoding:

| Option | Meaning |
|---|---|
| ANSI charset (Windows) | the system ANSI code page (ticked by default) |
| ASCII charset (DOS) | the text is converted to the OEM code page (e.g. `£` moves to its DOS code) |
| Unicode UTF16 | 2 bytes per unit |
| UTF8 | 1–4 bytes per character |
| Office xml (docx, xlsx, odt etc.), and EPUB | These ZIP containers are searched without *Search archives*, even nested in other archives. Their XML/HTML parts are searched twice: as they are, and with all tags removed. In the stripped variant entities such as `&lt;` are decoded and `</w:p>` / `</text:p>` become line breaks, so text split by formatting is still found. UTF-8 is used internally; regex is supported. |
| `[±]` / Plugins: … | The *Find text* string is searched in the content-plugin fields chosen with `±` (e.g. PDF text, comments). The definitions are stored in `[SearchCustomField]`; `xexts=` masks pick the plugin per file (regex allowed there). |

**`WarnSearchText`** controls what happens when the text cannot be represented in a ticked 8-bit encoding (ANSI/ASCII): `1` (default) warn; `0` no warning; `-1` silently drop the affected encodings and search with the others (e.g. Unicode) if ticked; `2` warn and drop.

**`LastSearchOptions`.** The last text options are kept while TC runs and saved on exit as a bit sum: 1 whole words, 2 case, 4 RegEx (2), 8 Hex, 16 NOT containing, 32 ANSI, 64 ASCII, 128 UTF-16, 256 UTF-8, 512 Office xml, 1024 search archives, 2048 text in plugins. A fresh installation writes `LastSearchOptions=0`.

### 2.7 Advanced tab

```
[ ] Date between:   [          ][>>]   and [<today's date>][>>]
[ ] Not older than: [1 ⇅]  [day(s) ▾]      units: Minute(s) | hour(s) | day(s) | week(s) | month(s) | year(s)
[ ] Older than:     [1 ⇅]  [day(s) ▾]
─────────────────────────────────────
[ ] File size:  [= ▾] [1 ⇅] [kbytes ▾]       ops: = | > | <   units: bytes | kbytes | Mbytes | Gbytes
─────────────────────────────────────
[ ] Attributes:  [■] Archive  [■] Hidden  [■] Directory  [■] Encrypted
                 [■] Read only [■] System [■] Compressed        (tri-state, enabled with the checkbox)
─────────────────────────────────────
[ ] Find duplicate files:
     [x] same name   [x] same size   [ ] same contents
     [ ] same plugin fields: [                         ▾] [+]
```

All enabled criteria are **ANDed** with each other and with the General and Plugins tabs.

| Criterion | Rule |
|---|---|
| **Date between** *from* / *to* | Last-modified date in the range. Either bound may be given alone. `>>` opens a date picker. The second field is pre-filled with today's date in the system date format. |
| **Not older than** *n unit* | mtime ≥ now − n·unit. |
| **Older than** *n unit* | mtime < now − n·unit. ANDed with *Not older than* this gives a window (older than 7 days but not older than 14). For units of days and longer the cut-off is **midnight**, not the current time of day. |
| **File size** `=` / `>` / `<` *value unit* | Units bytes, kbytes, Mbytes, Gbytes, each ×1024. Fractional values are allowed (`0.1` Gbytes). |
| **Attributes** | Archive, Read only, Hidden, System, Directory, Compressed, Encrypted, each tri-state: checked = must be set, cleared = must not be set, grey = don't care (inferred from the tri-state boxes). |
| **Find duplicate files** | See below. |

**Duplicate finder**

- Sub-criteria, all **ANDed**: **same name**; **same size**; **same contents** (byte-identical, verified by checksum: BLAKE3 in current versions, MD5 earlier); **same plugin fields** `[=plugin.field(.unit)]…`, where several fields must **all** be equal and a range suffix compares a substring (`[=tc.name:1-3]` = the first 3 characters).
- OR-combination of fields is deliberately not offered: equality would not be transitive (files 1 and 2 could share A, files 2 and 3 share B, while 1 and 3 differ).
- Files whose plugin field is **empty** are ignored (e.g. `[=tc.comment]` without a comment). A missing closing `]` is an error. The field history is kept in `[PluginDuplicates]`.
- If the duplicate option is on but no sub-criterion is ticked, the duplicate option is switched off rather than defaulting to "same name".
- **Output:** files are grouped by equality and the groups are separated by **dashed lines**. Groups are sorted by the **first enabled criterion** in the order name → size (also for "same contents") → first plugin field; items within a group by full path. Each line reads `<name>  -  <folder>\` (name, two spaces, a dash, two spaces, folder), e.g. `copy1.txt  -  c:\tc-sandbox\A\dups\`.
- Aborting a duplicate search **clears** the result list, so no non-duplicates remain. Copying or saving the result list puts an empty line between groups.

### 2.8 Plugins tab (content-plugin rules)

```
[ ] Search in plugins:      Combine with: (o) AND (all match)   ( ) OR (any match)
┌──────────────────────────────────────────────────────────────┐
│ Plugin:   Property:        OP:            Value:             │
│ [tc ▾]    [fullname ▾]     [contains ▾]   [_______________]  │
│ [ More rules ]  [ Fewer rules ]                       [^][v] │
└──────────────────────────────────────────────────────────────┘
```

- Content plugins work only on the **real file system**: not on desktop virtual folders, FTP, archive contents or file-system plugins.
- **Search in plugins** enables or disables the whole rule list without clearing it.
- **Combine with:** **AND (all match)**, e.g. size > 1 MB AND size < 2 MB; **OR (any match)**, e.g. hidden OR system.
- **A rule row** is Plugin / Property / OP / Value, with a unit selector for some numeric fields. The **Plugin** combo lists `tc` (the built-in pseudo-plugin) and every installed content plugin; **Property** lists the fields of the chosen plugin (the `tc` fields: 18 › Built-in fields (pseudo-plugin `tc`)). Date and time values use the format shown in the file panels.
- **OP** offers the operators that fit the field type (18 › Plugin-rule operators): for text fields `contains`, `!contains`, `cont.(case)`, `!cont.(case)`, `=`, `!=`, `=(case)`, `!=(case)`, `regex`, `!regex`; numeric, date and time fields add `>`, `<`, `>=`, `<=`, and `>` is preselected when such a field is chosen.
- **More rules** appends a row; **Fewer rules** deletes the last row. Rows are reordered with **Ctrl+Up / Ctrl+Down** or the `[^] [v]` buttons; with AND or OR the order does not change the result.
- With the Exif content plugin installed, the rule *exif / Make / contains / TestCam* found exactly the one JPG with that camera make (the observed field list: 15 › Find Files › Plugins with a real plugin).

### 2.9 Load/Save tab and saved searches

```
Previous searches:
┌───────────────────────────────────┐
│                                   │
└───────────────────────────────────┘
      [ Load ]   [ Save ]   [ Delete ]
```

- **Previous searches** lists the saved searches (`[Searches]`). For each, the dialog shows a summary of the non-default settings: dates, archives (shown as "zip"), size, attributes, duplicates ("2x"), depth ("D<="), plugins.
- **Load** applies the selected search and switches to the General tab. A `>` stored in *Search for* / *Search in* leaves the current value of that field in place.
- **Save** asks for a name and saves all tabs. **Delete** removes the selected entry.
- **A saved search is a reusable selection type.** It is used as the Copy filter (07 › Only files of this type (copy filter)), as a selection pattern `>name` in Num+ / Num− (03 › Select and unselect group), as a Synchronize filter (§5.3), in colour definitions (13 › Define colors by file type), in the duplicate selection dialog (§2.12), and by `LOADSEARCH`.
- Used **as a Copy filter**, these General-tab fields are **ignored**: *Search in*, *Only search in selected directories/files*, *Everything*, *Search archives*, *Search in subdirectories*.

### 2.10 Running a search and the result list

**Start search** runs the search; the window grows downward to show the results:

```
Search results:          [<] [>] [ ] F2 Search in found files/folders
┌─────────────────────────────────────────────────────────────────┐
│[6 files and 0 directories found]                                │ ← first line, selected
│c:\tc-sandbox\A\copy1.txt                                        │ ← one full path per line, sorted by path
│…                                                                │
└─────────────────────────────────────────────────────────────────┘
[ F3 View ] [ F4 Edit ] [ New search ] [ Go to file ] [ Feed to listbox ]
[6 files and 0 directories found]                                   ← status line
```

- While searching, the list shows "[Searching...]" and the status line shows the directory being searched. **Clicking a part of that path** offers, after confirmation, to **skip** that directory.
- Without hits the list shows "[No files found]". With hits, its **first line** is the summary `[N files and M directories found]` (selected), followed by one full path per line, sorted by path; the status line repeats the summary. Duplicate results use the format of §2.7.
- After the search, the status line shows the date, time and size of the focused result (they are not shown in the list).
- **Esc** or **Cancel** aborts a running search. **Cancel** when idle closes the dialog and saves its position (`Search*` keys in the screen-resolution section).

**Result list actions**

| Action | Effect |
|---|---|
| Double-click a result | Go to its directory in the panel |
| **F3 View** / **F4 Edit** (also the keys) | View (10) or edit the focused result; an editor started here gets `%COMMANDER_OPEN%=find` (19 › Variables defined by TC) |
| Ctrl+C in the list | Copy the whole result list as text |
| Right-click | The shell context menu of the file, including the internal associations and the x64 submenu |
| `[<]` / `[>]` | Step back and forward through the earlier result sets of this session |
| **New search** | Clear the results and return to the form |
| **Go to file** | Close the dialog, change the panel to the result's directory and put the cursor on it. With **Shift**, in a new tab. If exactly one file was found, it is used even when not focused. |
| **Feed to listbox** | §2.11 |

**F2 Search in found files/folders** (checkbox): the next search runs only over the displayed results. With depth ≥ 1, listed **directories are searched inside** and are not themselves results; with depth "current dir only", only the listed files/directories can be found, never their contents.

### 2.11 Feed to listbox (search-result panel)

**Feed to listbox** puts all results into the **active (source) panel** as a virtual list, and closes the dialog. With **Shift** it opens in a new tab.

| Panel part | Content |
|---|---|
| Drive line | `Search result:`, the drive combo is empty |
| Path bar | empty |
| Name column | **full paths** |
| Ext / Size / Date / Attr | empty |
| Footer | the details of the item under the cursor, e.g. `y:\…\copy1.txt   19 05/02/2026 09:00 -a--` |

- Normal operations work on the real files: copy, move, delete, Multi-Rename, F5 with *Keep relative paths* (the copy then keeps the entire path; `RelativePathCopy` bit 8 omits the drive letter / UNC server). Searching again with *Only search in selected* treats all listed files as selected.
- **Backspace** returns to the previous real directory. **F2 / Ctrl+R** (reread) also leaves the result mode. **Ctrl+B** goes to the directory of the file under the cursor, as when leaving branch view (03 › Branch view); whether Ctrl+B also works in the dialog's result list is unverified.
- **Archives:** if all results come from **one** archive, the archive members are listed; otherwise the **archives themselves** are listed.
- Also works for FTP results (not all servers handle relative paths) and file-system-plugin results.
- **Duplicate results** keep their groups and dashed separators in the panel. The panel can switch to any custom-columns view and back without losing them. **Num+** then opens "Select duplicate files" (§2.12) instead of the normal selection dialog.
- A panel-type query reports 0 for a normal panel, 1 for search results, 2 for duplicate results.
- A saved list can be loaded into the same kind of panel with the command `LOADLIST <filename>` (modifier 0 = no error dialogs; 17 › Commands with parameters, list format: 19 › List files).

**Keeping results.** With `SearchKeepLast=1` (default) the last results are kept when the dialog is closed with Cancel or Go to file, but **not** after Feed to listbox. When results are restored, the cursor position and the scroll position in the list are restored too.

### 2.12 "Select duplicate files" dialog

Num+ in a panel holding fed duplicate results opens this dialog. Its two tabs are combined: only files in folders checked on the second tab can be selected (inferred).

**Tab Files**

1. **Select by name/extension** works like the normal selection mask: `*.doc *.xls`; `*.* | *.doc *.xls`; `<regex`; `>saved search` (picked with `>>`).
2. **Remove selection by name/extension** uses the same syntax and is applied **after** step 1; it deselects matches.
3. **Select by date/time**, evaluated **within each duplicate group**:

| Option | Selects |
|---|---|
| All older files | every file older than the newest file(s) of the group |
| All newer files | every file newer than the oldest file(s) |
| Just the oldest file | the oldest file; several on a tie |
| Just the newest file | the newest file; several on a tie |

4. **Select by file size**, also per group:

| Option | Selects |
|---|---|
| All larger than the smallest file | every file larger than the smallest file(s) |
| All smaller than the largest file | every file smaller than the largest file(s) |
| Just the largest file | the largest file(s) |
| Just the smallest file | the smallest file(s) |

**Tab Select by folder**

- **Choose folders in which files can be selected:** a checklist of all folders in the results. **Shift+Click** selects a range; **Space** toggles.
- **Also select all subfolders (manually and with pattern):** (de)selecting a folder also (de)selects its subfolders.
- **Select folder by pattern:** a substring or wildcard pattern; **Select** / **Remove** apply it to the folder list. With **Apply this pattern only to the direct parent directory** it is tested against the last path component only (`Windows` matches `c:\Windows\System32` only while this option is off). History: `[DirSelection]`.
- **All / None / Reverse** act on the folder list.

**Leave at least one file in each group unselected** with three ordered methods 1, 2, 3, each chosen from date/time, size or position in the list:

```
for each group G:
    S = files of G selected by the rules above
    if S == G:                                  # would select every copy
        for method in (m1, m2, m3):
            keep = files of G picked by method  # e.g. newest / largest / first in list
            if keep discriminates (not all files of G tie): break
        unselect one file of keep               # at least one copy stays unselected
```

**Buttons:** **OK** applies and closes; **Apply** applies and keeps the dialog open; **Cancel** closes without changes; **Help**. Geometry: `SelectDuplicates*`.

### 2.13 Everything integration

- **Requirements:** *Everything* running, or startable via `Everything=` (default `Everything.exe -startup`, searched in the TC folder; file parameters such as `-config` need a full path). Named instances: `UseEverythingInstance=` together with `-instance "name"` in `Everything=`. Ticking the box while Everything is not installed offers to download it.
- Everything reads only names from the NTFS MFT; it works on NTFS drives and indexed network shares, and searches starting inside an indexed subfolder are supported. Size and date-range criteria are passed to Everything (accelerated) only with Everything 1.4 or newer. Attributes, plugin fields and contents are always verified by TC afterwards.
- Results arrive in chunks of 10 000, so a huge result set can be aborted. The status bar shows the command sent and the percentage transferred and verified.
- Differences from the normal search: Everything ignores TC's hidden/system display setting; its regex does **not** support atomic groups `(?>…)`; `IgnoreLinks` bit 8 is not applied.

### 2.14 What is remembered, and ini keys

- **On reopening** in the same session, *Search for*, *Search in* and *Find text* (with its checkbox) are remembered. The **Advanced** tab is reset: duplicates off, date, size and attribute filters off, the date range ending today.
- The text options persist as `LastSearchOptions` (§2.6); the dialog position is saved on close.

| Key | Default | Effect |
|---|---|---|
| `LastSearchOptions` | 0 | text-search option bits (§2.6) |
| `WarnSearchText` | 1 | §2.6 |
| `SearchKeepLast` | 1 | keep results on close (§2.11) |
| `SearchInFiles` | — | extra masks searched as archives |
| `UseEverything` / `Everything` / `UseEverythingInstance` | 1 / `Everything.exe -startup` / — | §2.13 |
| `IgnoreLinks` | 0 | bit 8: skip directory links in Find |
| `HideRemovableNoMedia` | 0 | bit 4: Drives dialog |
| `MaxItemsInComboBox` | 20 | history length (max 500) |
| `ShowWarningIcons` | 1 | "!" next to risky remembered options |
| `RelativePathCopy` | 2 | bit 8: do not copy the drive letter / UNC server from search results |
| `[Searches]` | — | saved searches |
| `[SearchName]`, `[SearchIn]`, `[SearchText]` | — | field histories |
| `[SearchCustomField]` | — | plugins for *Find text – Plugins* |
| `[PluginDuplicates]` | — | history of *same plugin fields* |
| `[DirSelection]` | — | folder patterns of the duplicate selection dialog |
| `Search*`, `DriveSel*`, `SelectDuplicates*`, `PluginSel*` | — | window geometry (`DriveSel*` relative to the Find dialog) |

All keys are described in 19 › Find Files and *Everything* and 19 › History sections.

### 2.15 Keys

| Key | Action |
|---|---|
| Esc | Interrupt a running search (same as *Cancel*) |
| Shift+Del | Remove the highlighted entry from a field history |
| F2 | Toggle *F2 Search in found files/folders* |
| F3 / F4 | View / edit the selected result |
| Ctrl+C (result list) | Copy the whole result list |
| Shift + *Go to file* / *Feed to listbox* | Open in a new tab |
| Ctrl+Up / Ctrl+Down (Plugins tab) | Move a rule row |
| Num+ (panel with fed duplicate results) | "Select duplicate files" |

The same keys appear in 06 › Find Files (Alt+F7, Alt+Shift+F7).

*Basis: observed on Windows 11 (Alt+F7 opening, Exif plugin rules) and in sandbox tests under Wine (text search, results, duplicates, Feed to listbox, reopening); on screen under Wine (layout, template mode); help: dlg_search, dlg_advancedsearch, dlg_searchplugins, dlg_srch_loadsave, dlg_duplicates, options_search, reg_ex, inisettings1–3; inc.txt; HISTORY.TXT.*

## 3. Multi-Rename Tool

### 3.1 Window and scope

A modeless, resizable window titled **"Multi-Rename Tool"**:

```
┌ Rename mask: file name ─────┐┌ Extension ──┐┌ Search & Replace ──────────────┐┌ Define counter [C] ┐
│[[N]                      ▾] ││[[E]       ] ││Search for:   [               ▾]││Start at: [1 ⇅]    │
│[[N] Name] [+] [[YMD] Date]  ││[[E] Ext.]   ││Replace with: [               ▾]││Step by:  [1 ⇅]    │
│[[N#-#] Range][#][[hms] Time]││[[E#-#]Range]││[ ]^ [ ]1x [x][E] [ ]RegEx [ ]Subst.││Digits:  [1 ▾]│
│[[C] Counter] [[=?] Plugin]  ││[[C] Counter]│└ Upper/lowercase ───────────────┘└────────────────────┘
└─────────────────────────────┘└─────────────┘ [Unchanged ▾] [?] [▤]          [F2 Load/save settings ▾]
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│↑Old name   Ext.  New name                   Size     Date                   Location             │
│ IMG_1001   jpg   Photo_110_2025-12-01.jpg   …        12/01/2025 10:00:00    y:\…\work\photos\    │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
Please press 'Start!' to start renaming!         [↻] [ Start! ] [ Undo ] [ Result list ] [ Close ]
```

- **Items:** the selected files/folders of the active panel, or the item under the cursor.
- **Panel kinds:** normal folders, **branch view** and **search results** (with sort by name in branch view, it sorts by name only, not by relative path); **FTP** (forward slashes may move files into *existing* remote directories, never overwriting there; a lost connection can be resumed); **MTP** devices. **Not** inside archives: error "Not supported".
- **Initial settings** follow `MultiRenameLoadSettings`: empty = the last used settings of this TC session (not kept after TC closes); `<name>` = those saved settings; an unknown name = the defaults. Reopening the tool in the same session therefore keeps the last masks and counter values.
- The file panel behind the tool is **not refreshed** while the tool is open.

### 3.2 Rename pipeline

For each item:

```
name = expand(NameMask) ; ext = expand(ExtMask)
full = ext == "" ? name : name + "." + ext
full = SearchReplace(full)         # §3.5; scope controlled by [E]
full = CaseConversion(full)        # §3.6; applied last
strip trailing "\" and "/"; control characters (< 32) coming from plugins become spaces
if full contains "\": move into that relative (or absolute) folder, creating missing folders
```

- **Two masks:** the result is *fields of the name mask* + "." + *fields of the extension mask*. They are separate so that an extension is not removed by accident. Any placeholder may be used in either box.
- **Empty extension mask:** no dot is added (inferred from the help's folder example `[A2-5]` with an empty extension mask).
- **Errors:** if a mask is invalid for a file (bad placeholder, no EXIF date with `[T4]`, `[X]` with an empty clipboard …), the New name column shows **`<Error!>`** for that file.
- Placeholders are **case-sensitive** (`[N]` ≠ `[n]`, `[M]` month ≠ `[m]` minute, `[D]` day ≠ `[d]` date, `[C]` counter ≠ `[c]` count). Text outside `[...]` is copied literally.

### 3.3 Mask fields, insert buttons and menus

- The **name mask** is an editable combo with a history (`[RenameTemplates]`); **Shift+Del** removes an entry. The **extension** field starts as `[E]`.
- **[N] Name**, **[YMD] Date**, **[hms] Time**, **[C] Counter**, **[E] Ext.** and **[=?] Plugin** insert their placeholder at the cursor, replacing selected text. **[=?] Plugin** opens "Choose plugin property" (15 › The *Choose plugin property* dialog).
- **`+`** (next to [N] Name) opens the menu of less common fields:

| Code | Menu label |
|---|---|
| `[P]` | Parent folder |
| `[G]` | Grandparent folder |
| `[A]` | Name with extension |
| `[E]` | Extension |
| `[d]` | Date (country settings) |
| `[t]` | Time (country settings) |
| `[S]` | Size |
| `[U]` | All characters after this position in uppercase |
| `[L]` | All characters after this position in lowercase |
| `[F]` | First letter of each word uppercase after this position |
| `[f]` | First letter of each word uppercase after this position (English in Titles) |
| `[n]` | All characters after this position again as in original name |
| `[%USERNAME%]` | User name: *current user name* |
| `[[]` | Square bracket: open |
| `[]]` | Square bracket: close |
| `[X]` | *current clipboard text* |
| `[I]` | Folders only (on/off): The name [N] includes the extension, [E] is not used |

- **`#`** (next to [N#-#] Range) opens the range menu: `[#-#]` Full path+name · `[P#-#]` Parent folder · `[G#-#]` Grandparent folder · `[A#-#]` Name with extension · `[E#-#]` Extension · `[?#-#]` Content plugins · `[X#-#]` *clipboard text*.
- **[N#-#] Range** / **[E#-#] Range** open a picker "Select the characters to insert:" that writes the range syntax: the actual name as editable text in which characters are selected with the mouse; `[ ] Measure first character from the end`; `[ ] Measure last character from the end`; `[ ] Use [first,length] instead of [first-last]`; a live result label (e.g. `1-9`); [OK] [Cancel].
- **`?`** opens the help page "Dialog box - Multi-rename tool". **`▤`** (F10) opens the name-list menu (§3.8).

### 3.4 Placeholders accepted by the masks

Both masks accept the whole placeholder language; its grammar and every form are in 18 › Rename and new-folder placeholders. The tool uses these groups:

| Group | Placeholders | Syntax |
|---|---|---|
| Literal text and brackets | any text outside `[...]`; `[[]`, `[]]` | 18 › Grammar |
| Ranges | `[N2-5]`, `[N2,5]`, `[N-8-5]`, `[N02-9]` …, on `N`, `E`, `A`, `P`, `G`, `X`, `B`, the bare `[2-5]`, plugin fields and environment variables | 18 › Range forms |
| Name and path parts | `[N]` `[E]` `[A]` `[2-5]` `[P]` `[G]` `[B0]`…`[B9]` `[B+0]`…`[B+9]` `[S]`; folder-dot switch `[I]` / `[I0]` | 18 › Name and path parts |
| Counter | `[C]` (Define counter, §3.7), inline `[C10+5:3]`, `[C:a]`, `[C+1/100]`, `[Caa+1]`; counts `[c]`, `[c2]`, `[c3]` | 18 › Counter |
| Date and time | sources `[T1]` (default here) … `[T4]` with offsets such as `[T1+60m]`; fields `[Y]` `[y]` `[M]` `[D]` `[h]` `[H]` `[i]` `[m]` `[s]` `[v]` `[d]` `[t]` `[YMD]` `[hms]` | 18 › Date and time |
| Case switches | `[U]` `[L]` `[F]` `[f]` `[n]`, and `[u]` (must come first) | 18 › Case switches |
| Environment and clipboard | `[%x%]`, `[%x%\]`, `[%x%_]`, `[X]` (cached; an error when the clipboard is empty), `[X+]` | 18 › Environment and clipboard |
| Content-plugin fields | `[=plugin.field.unit]`, with ranges, `"prefix"…"suffix"` and `._fmt` number formats; invalid characters replaced unless `MrtReplacePluginChars=0`; not previewed in virtual folders | 18 › Content-plugin fields |

Behaviour of the tool around them:

- Each item is numbered in the **current order of the result list** (§3.9).
- `[T4]` skips files without an EXIF or MP4 date; an invalid placeholder for a file shows `<Error!>` (§3.2).
- A `\` in the result moves the item into that folder, creating it (§3.2); `[C+1/100]\[N]` thus distributes files into subfolders of 100.

### 3.5 Search & Replace

Applied **after** the masks and **before** the case conversion, to the assembled name. Matching rules and the RegEx replacement syntax: 18 › Search & Replace in the Multi-Rename Tool (regular expressions: 18 › Regular expressions).

| Control | Effect |
|---|---|
| **Search for** / **Replace with** | Combos with histories `[RenameSearchFind]` / `[RenameSearchReplace]` (leading and trailing spaces are preserved). Not case-sensitive; `*` and `?` are wildcards; several pairs are separated by `\|` in **both** fields (`ä\|ö\|ü` → `ae\|oe\|ue`) |
| **`^`** | Respect upper/lowercase (off by default) |
| **`1x`** | Replace only the first occurrence (hotkey `1`) |
| **`[E]`** | Also search the extension (on by default). Off: only the name-mask result is searched, or, with names loaded from a file (§3.8), everything from the last dot on is protected |
| **RegEx** | *Search for* is a regular expression; *Replace with* may use `$1`, `$2`, … and `\U`, `\L`, `\F`, `\n` before a `$n`. Ticking it enables *Subst.* |
| **Subst.** | The whole name (within the `[E]` scope) is replaced by *Replace with*; without it only the matched part is replaced |

Observed: search `IMG_(\d)(\d+)`, replace `pic-$2-$1`, *RegEx* ticked → `IMG_1001.jpg` previews as `pic-001-1.jpg`.

### 3.6 Upper/lowercase

The combobox is applied **last**, to the whole string **including the extension**: *All UPPERCASE* after the replace above gives `PIC-001-1.JPG`.

- Options: `Unchanged` · `All lowercase` · `All UPPERCASE` · `First letter uppercase` (rest lower) · `First of each word uppercase` · `First of each word uppercase (English in Titles)`.
- For "First of each word", `/` and `\` also start a new word.
- *English in Titles* keeps the small words of `LowercaseStrings` lowercase except as the first or last word; the list, its label and the `!` variant are described under `[f]` in 18 › Case switches.
- To change only part of the name, use the case switches `[U]` `[L]` `[F]` `[f]` `[n]` in the mask instead.

### 3.7 Define counter

- **Start at** (number of the first file), **Step by** (may be negative), **Digits** (`1` … `10`, or `a` = automatic width from the number of items; >1 pads with leading zeros).
- The files are numbered in the order of the result list.

### 3.8 Name-list menu (`▤`, F10)

- **Load names from file...**: new names are read from a text file, one per line, assigned in list order (line *i* → item *i*, inferred). ANSI, UTF-8 (with BOM) and UTF-16 are accepted, with Windows or Unix line breaks. While names come from a list, mask-only buttons such as `[E]` are disabled.
- **Edit names...**: writes the current *target* names to a temporary `.txt` file and opens it in the editor; when the editor closes, the edited names are read back. Encoding per `RenameEditUnicode`: `0` ANSI, unless the names need several code pages; `1` always Unicode. Notepad on Windows 10 and later always gets UTF-16 with BOM; the returned file is also accepted as BOM-less UTF-8. The editor is started with `%COMMANDER_OPEN%=mrtlist` (19 › Variables defined by TC).
- **Configure editor...**: sets `MultiRenameEdit=`. The editor must save plain text.

### 3.9 Result list (live preview)

- Columns: **Old name** | **Ext.** | **New name** (with extension) | **Size** | **Date** (with seconds) | **Location** (folder path with a trailing `\`). Tab stops: `RenameTabs` (extension, new name, size, date, location).
- **Live preview:** every change to a field is shown at once; nothing is renamed before **Start!**. The preview does **not** show collision auto-renames (§3.10).
- Click a header to sort (old name, extension, size, date). **Drag and drop** or **Shift+Up / Shift+Down** move single items; this order drives `[C]`. **Del** removes an item from the rename set.
- **`↻`** (F5, "next step") loads the computed new names as the new old names, so several rule sets can be chained on the same items; this also works after collision auto-renaming.
- Example: mask `Photo_[C]_[Y]-[M]-[D]`, Start at 110, Step by 15, Digits 1 previews `Photo_110_2025-12-01.jpg`, `Photo_125_2025-12-02.jpg`, … (date = modification date, counter in list order).

### 3.10 Start!, collisions, Undo, Result list

**Start!** renames the items in list order. A successful run shows **no message**: the preview list is **emptied**, the status text stays "Please press 'Start!' to start renaming!", and **Undo** and **Result list** become enabled.

**Name conflicts**

- A conflict is two items getting the same target, or a target that already exists, including one inside a subfolder target such as `subdir\[N]`. A warning is shown, offering **auto-rename** to `name (2).ext`, `name (3).ext`, … in the format of `AutoRenameMode` (bit sum, default 3: 1 = a space before `(n)`, 2 = start at `(2)` instead of `(1)`, 4 = always append a new number instead of incrementing an existing `(n)`; the same scheme as 07 › Auto-rename names).
- No auto-rename is applied when old and new name are equal or differ only in case.
- Conflicts are re-checked during the run (e.g. for files that appear meanwhile).
- **Temporary collisions** inside the set (swapping `1.txt` ↔ `2.txt`, shifting `1,2,3` → `2,3,4`) are resolved through temporary names.

**Other rules**

- Missing target folders are created; Undo does **not** remove them.
- After renaming, the archive attribute is set unless `SetArchiveBitOnRename=0`; attribute errors are ignored.
- With `LongNameCopy=3`, names longer than 259 characters are not created.
- A locked source file is not retried endlessly.

**Undo**

- First asks, in a box titled "Total Commander" with a question icon: "Undo the following rename action:" followed by the list of `old -> new` pairs (`IMG_1001.jpg -> Photo_110_2025-12-01.jpg` …), [Yes] [No].
- **Yes** restores the names silently, processing the files in **reverse order** (last renamed first); Undo and Result list are disabled again.
- Works even after the tool was closed: reopen it with any file. `MultiRenameUndoHistoryLen` (default 20) sets how many operations can be undone; 0 disables Undo.

**Result list** opens Lister (10) on **`%TEMP%\_tc\renlog.txt`** (19 › Multi-Rename result log (`renlog.txt`)), one line per renamed file, old full path and new name both quoted and joined by ` -> `:

```
"c:\tc-sandbox\work\photos\IMG_1001.jpg" -> "Photo_110_2025-12-01.jpg"
```

**Close** closes the tool without further action.

### 3.11 Saved settings and persistence

The **F2 Load/save settings** combobox lists, below its caption: `<default>` · `Save settings` · `Delete entry` · the saved names (sorted).

- **`<default>`** resets to "no change": mask `[N]`, extension `[E]`, search and replace empty, `1x` and `[E]` reset, Start at 1, Step by 1, Digits 1, case Unchanged. The combo then shows `<default>`.
- **Save settings** stores everything under a name in `[rename]`; names are at most 252 characters; plugin-field names are stored in English.
- **Delete entry** deletes the last selected entry. Selecting a saved name loads it (also `MULTIRENAME <name>`, §1).
- Other storage: `[RenameTemplates]` (name-mask history), `[RenameSearchFind]`, `[RenameSearchReplace]`, `RenameTabs`, geometry `Rename*`, `PluginSel*` (the Choose plugin property dialog). Keys: `MultiRenameLoadSettings`, `MultiRenameUndoHistoryLen`, `MultiRenameEdit`, `RenameEditUnicode`, `MrtReplacePluginChars`, `SetArchiveBitOnRename`, `AutoRenameMode`, `LowercaseStrings` (19 › Multi-Rename Tool; saved sets: 19 › Saved tool settings and drive names).

### 3.12 Keys

| Key | Action |
|---|---|
| F2 | Open *F2 Load/save settings* |
| F5 | Next step (`↻`) |
| F10 | Name-list menu |
| Shift+Up / Shift+Down (result list) | Move the item (changes the counter order) |
| Del (result list) | Remove the item from the rename set |
| Shift+Del | Remove the highlighted entry from a field history |
| `1` | Toggle *1x* |

The `|` separating several search/replace strings is typed normally (the help gives Alt+124). The same keys appear in 06 › Multi-Rename Tool (Ctrl+M).

*Basis: observed in sandbox tests under Wine (runs, Undo, renlog, menus, defaults) and on screen under Wine (layout); help: dialog_box___multi_rename_tool, multi_rename_tool, reg_ex, inisettings1–3; HISTORY.TXT.*

## 4. Compare directories and Mark newer

Two panel commands compare the source and target directories without opening a dialog and without copying anything.

| Command | Marks | Hides | Path captions |
|---|---|---|---|
| **Compare Directories** (`cm_CompareDirs`, Shift+F2) | In each panel, files that are **newer** than their namesake on the other side, and files **missing** on the other side (marked on the side where they exist). Only newer files are marked, not every differing file (Norton Commander behaviour). | nothing | unchanged |
| `cm_CompareDirsWithSubdirs` | Like Compare Directories, and also subdirectories absent on the other side | nothing | unchanged (unverified) |
| **Mark Newer, Hide Same Files** (`cm_DirMatch`) | Of the differing files only the newer; files missing on one side are marked on the other | files that are **the same** on both sides (hidden from view only, **never deleted**) | `Comparison: <path>\*.*` on both panels |

**Observed** with left `A\docs` and right `B\docs`, where `only_in_B` exists only on the right and `report_03` is newer on the right:

- **Shift+F2:** the right panel got `only_in_B` and `report_03` selected; the left got nothing (its `report_03` is older). The right panel's **previous selection was replaced**. The selection totals updated; the captions and the full listing stayed.
- **Mark Newer, Hide Same Files:** the same marks; the captions changed to `Comparison: c:\tc-sandbox\A\docs\*.*` / `Comparison: c:\tc-sandbox\B\docs\*.*`; the left showed only `report_03` (unselected) and the right only `only_in_B` and `report_03` (selected). The footers counted only the visible files (`0 k / 1 k in 0 / 1 file(s)`).

**Ending the comparison view** (the `Comparison: ` prefix means the list is shown only partly):

- In a panel, the first **Ctrl+R** (or F2) restores the normal caption and the second the full list.
- Anything that rereads the panel ends it: saving a file comment, which rereads both panels, ended it in the other panel.
- The help also lists: switching away from TC and back, minimizing and restoring TC, and changing directory or drive.

The help does not define "the same"; a clone should compare name, size and timestamp (inferred). `1hourdif=1` (13 › NTFS daylight saving correction) makes every compare function treat timestamps that differ by exactly one hour as equal.

*Basis: observed in sandbox tests under Wine; help: options_compare, options_marknewer, inisettings1; inc.txt.*

## 5. Synchronize directories

### 5.1 Window and workflow

A resizable window titled **"Synchronize directories"**:

```
[★] [c:\users\                     ] [>>]  [*.*      ▾] [1x] [c:\                         ] [>>]
[ Compare ]   [ ] Asymmetric     ┌ Show: ─────────────────────────────┐   [ Synchronize... ] (disabled)
[ ] Only selected  [ ] Subdirs   │ [→] [=] [≠] [←]  [duplicates]      │   [ Close ]
 (in main window)  [ ] by content│                  [singles]         │
[ ] Empty directories [ ] ignore date └────────────────────────────────┘   6/9 dups\sub
┌──────────────────────────────────────────────────────────────────────────────────┐
│↑Name        Size    Date        <=>   Date          Size    Name                 │
└──────────────────────────────────────────────────────────────────────────────────┘
Please press 'Compare' to start
```

- **Top row:** `★` (saved sets, §5.2), the left path with a `>>` folder picker, the wildcard combo with the filter button (§5.3), the right path with `>>`. Both paths start as the paths of the two panels. Paths may contain environment variables.
- *Only selected (in main window)* is disabled when nothing is selected in the panels. **Synchronize...** stays disabled until a comparison has found something to do.
- Next to *by content*, a plugin-compare button appears when both sides are in the file system (§5.4). With an FTP side, an **FTP time offset** group appears (§5.10).
- On first use all compare options were unchecked; the help lists `SyncFlags=1` (Subdirs on) as the default (which applies to a fresh Windows installation is unverified).
- Right-clicking the empty list shows no menu.

**What can be paired:** two directories; a directory and an archive; two archives (by content not for all types); a local directory and an FTP directory; a local directory and a parallel/USB-port connection (11 › PORT connection (USB or parallel cable)); a local directory and a file-system-plugin directory.

**Workflow**

1. Choose both paths and, if needed, the wildcard filter.
2. Set the compare options.
3. Click **Compare**. While it runs, the *Synchronize* button becomes **Pause**, and then **Start** to resume.
4. Choose what to **Show** (§5.7).
5. Adjust the copy directions (§5.6).
6. Click **Synchronize...** (§5.9). **Only visible rows are processed.**

Checking a CD-R against its originals needs *by content*.

### 5.2 Saved sync sets (`★`, F2)

- `★` (or **F2**) opens a menu: `Add current directories and settings to list...`, followed by the saved sets, sorted by name. Choosing one loads it (also `SYNCOPEN`, §1).
- **FTP connections cannot be saved.** *Only selected* is stored in a separate list file whose name TC asks for; when such a set is loaded, the list file's name replaces the text "(in main window)".
- Storage, section `[SyncOptions]`:

```
<name>_L=D:\              left path
<name>_R=E:\              right path
<name>_Wcs=*.*            wildcards
<name>_Flags=b1|b2|b3|b4  e.g. 11|63|-8
   b1 compare options: 1 Subdirs, 2 By content, 4 Ignore dates, 8 Asymmetric, 16 Empty dirs
   b2 display options: 1 L→R, 2 Equal, 4 Not equal, 8 R→L, 16 Dupes, 32 Singles
   b3 sort column (negative = reversed)
   b4 filter match mode 1…6 (negative = hide matching), §5.3
```

- The last-used state is kept in `SyncFlags` (§5.4), `SyncButtons` (§5.7) and `SyncMatch` (§5.3).

### 5.3 Filter

**Wildcard combo** (up to 1022 characters) accepts:

- the standard include/exclude mask syntax with `|` (18 › Core syntax);
- `<regex`;
- a saved search name;
- directory filters as in Find Files: `sub\`, `\sub1\sub2\`, `**` (18 › Find Files and copy-filter forms);
- paths relative to the sync base: `\sub\*.ext`, `\*.ext` (base directory only), `\subdir*\*.ext`.

**Filter button.** Its caption shows the match mode (`1x`, `2x`, …); clicking it opens **"Search filter"**:

```
Specify file type, e.g. *.txt, or RegEx with leading '<', like <(a|b)
[*.*                                            ▾]
Or select predefined selection type:
┌──────────────────────────────────────────────┐
│ (saved searches)                             │
└──────────────────────────────────────────────┘
Search must match: [on at least one side    ▾]   (enabled only for a RegEx or saved search)
[ ] Hide files which match the criteria
                   [ Define... ] [ OK ] [ Cancel ]
```

**Match mode** matters when a filter can match one side but not the other (regular expressions, saved searches such as "maximum 14 days old" when an old file was edited on one side only):

| Caption | `SyncMatch` / b4 | "Search must match" | A row is shown when… |
|---|---|---|---|
| `1x` | 1 | on at least one side | the filter matches on at least one side |
| `2x` | 2 | on both sides (if present) | it matches on both sides (pairs), or on the single file (singles) |
| `<-` | 3 | on the left if present, leave out files only on the right | it matches the left file; right-only files are not shown |
| `<+` | 4 | on the left, if not present on the right | it matches the left file; for right-only files it must match the right file |
| `->` | 5 | (mirror of 3) | it matches the right file; left-only files are not shown |
| `+>` | 6 | (mirror of 4) | it matches the right file; for left-only files it must match the left file |
| `!` + any of the above | negative | *Hide files which match the criteria* | inverted: rows whose files match are **hidden** |

### 5.4 Compare options

Options marked † need a new **Compare** to take effect.

| Option | `SyncFlags` bit | Semantics |
|---|---|---|
| **Subdirs** † | 1 | recurse into subdirectories |
| **by content** † | 2 | file pairs with equal size and date (only equal size with *ignore date*) are also compared by content (§5.5) |
| **ignore date** † | 4 | timestamps are not compared; same name and size count as identical, and with *by content* also equal content. Such results are only "equal" / "not equal": the direction must be set by the user |
| **Asymmetric** | 8 | the right side is to become a copy of the left: right-only files are marked for **deletion**. Meant for backups; do not use it to synchronize a desktop and a notebook |
| **Empty directories** | 16 | also synchronize directories: in symmetric mode a directory missing on one side is created from the other; in asymmetric mode a directory missing on the left is deleted on the right, and one missing on the right is created from the left |
| plugin compare `[++]` / `[>>]` | 32 (needs 2) | content plugins decide equality (§5.5). `[++]` = active, `[>>]` = inactive but available |
| **Only selected (in main window)** | — | compare only the items selected in TC before the dialog was opened; selecting on one side is enough. Saving stores them in a list file (§5.2) |

**Exclusions**

- `SyncHideHiddenSystem`: 0 never hide; 1 hide when both files are hidden/system; 2 hide when either is; +4 also follow the main program's hidden/system display setting.
- `SyncIgnoreJunctions=1` excludes directory junctions; a same-named real directory on the other side then shows its files as "singles". (`IgnoreLinks` does not apply here.)
- Symbolic links are always ignored, to avoid loops.
- Items on the ignore list are not synchronized (13 › Operation › Ignore list).

### 5.5 Comparison algorithm

```
for each relative path present on L and/or R (after filters):
    if only on L:  L_ONLY  → default copy L→R                     (green →)
    if only on R:  R_ONLY  → symmetric: default copy R→L          (blue ←)
                             asymmetric: delete on R              (blue, ✕)
    if names differ only in case and a side is case-insensitive:
                   EXCLUDED (slashed circle), never synced
    both present:
       if not ignoreDate:
           dt = mtimeL - mtimeR            # FTP: after applying the dt=…h offset
           sameTime = |dt| <= 3 s  or (1hourdif=1 and |dt| == 3600 s)
           if not sameTime: newer side wins → copy L→R (green) or R→L (blue)
           elif sizeL == sizeR:
               byContent ? (pending "?" → compare → EQUAL "=" | DIFFERENT "≠") : EQUAL
           elif FTP and sizeL - count(CRLF in L) == sizeR:
               UNIX_TEXT_EQUAL (special symbol)
           else DIFFERENT (red ≠, no default direction)
       else:                                # ignoreDate
           if sizeL == sizeR: byContent ? compare → EQUAL | DIFFERENT : EQUAL
           else DIFFERENT (red ≠, no direction; the user must choose)
       if plugin compare is active (both sides in the file system):
           equality is decided by the plugin method(s) instead of the bytes
```

- **Tolerance:** the help says differences of 1–3 seconds are ignored, to absorb NTFS↔FAT32 rounding; treat |Δ| ≤ 3 s as equal.
- **Case:** when both sides support case-sensitive names (two case-sensitive local folders, or local and FTP/plugin), the comparison is case-sensitive.

**By content: where the data comes from**

- **Local files:** byte comparison.
- **FTP:** only if the server announces `XCRC`, `XMD5`, `MD5` or `XSHA1` in `FEAT`. TC computes the same checksum locally and compares; for text files with differing sizes CRs are not counted. Otherwise *by content* is greyed.
- **File-system plugins:** the plugin's checksum functions (e.g. SHA256/512 or plugin-specific); the plugin must return checksums for both the remote and the local file.
- **Archives:** ZIP (also multi-part), ARJ, LHA, TAR, RAR (also solid), 7z, and packer plugins with search capability. Solid archives are read in their stored order; for two solid or plugin archives, the right one is unpacked and SHA1-hashed first, then the left one.

**Plugin compare** (only when both sides are in the file system): a list of `[=plugin.function]` items. Several items must **all** match (AND, default); if the string starts with `|`, at least one must match (OR). The built-in `[=tc.compare as text]` compares as plain text, like Compare by content, and ignores the type of line breaks (CRLF/LF/CR). Definitions are kept in `[CompareCustomField]`.

### 5.6 Result list

**Layout**

- Columns: Name | Size | Date | `<=>` (direction) | Date | Size | Name. Tab stops: `SyncTabs` (size, date, direction, date, size, right name).
- Each subdirectory starts with a **grey group-header row** (`bin\`, `deep\level1\level2\level3\`, `dups\sub\`). Only folders that contain listed files get a header; a chain of nested folders without files of their own collapses into one header.
- Dates are shown in the system short-date format with seconds (`MM/DD/YY hh:mm:ss` with a US locale), also for FTP sides.
- Clicking a header sorts by name, size or date; when the chosen side has no file in a row, the other side's file is used.
- Selected rows are drawn with `SyncSelBack`.

**Text colour** shows the computed default; the **middle symbol** shows the current action (the same glyphs are on the Show buttons):

| Colour | Meaning |
|---|---|
| green | copy L→R (left only, or newer on the left) |
| blue | copy R→L (right only, or newer on the right), or delete on the right in asymmetric mode (cross symbol) |
| red | different, no direction |
| black | identical |

| Symbol | Meaning |
|---|---|
| `→` | copy L→R |
| `=` | equal |
| `≠` | different, no default direction |
| `←` | copy R→L |
| `✕` | delete on the right (asymmetric) |
| FTP text symbol | identical only if the remote file is a Unix text file (§5.10) |
| `?` | by-content pair not compared yet |
| slashed circle | excluded from sync (e.g. names that differ only in case) |

**Choosing what to copy**

- By default all rows with a default direction (the **newer** files and singles) are checked for copying.
- **Click** the checkbox between the columns to toggle one row; **double-click the arrow** to reverse its direction.
- **Space / Shift+Space** with several rows selected act on each row separately.
- The context menu sets the direction for all selected rows.

**Context menu** (right-click on a result row). Its items act on (1) all selected rows, (2) the row under the cursor, (3) deletion of the selected rows:

```
Mark for copying (default direction)            Ctrl+D
Unmark for copying                              Ctrl+M
Mark for copying -> (left to right)             Ctrl+L
Mark for copying <- (right to left)             Ctrl+R
Mark for copying in reverse direction           Ctrl+W
Copy file properties -> (left to right)...      Ctrl+Alt+L
Copy file properties <- (right to left)...      Ctrl+Alt+R
────────
Print selected...                               Ctrl+P
Compare left & right                            Ctrl+F3
────────
View left                                       F3
View right                                      Shift+F3
Edit left                                       F4
Edit right                                      Shift+F4
Rename left                                     F6
Rename right                                    Shift+F6
────────
Left context menu                               Alt+Down
Right context menu                              Alt+Shift+Down
Left properties                                 Alt+Enter
Right properties                                Alt+Shift+Enter
────────
<- Delete left
-> Delete right
Delete on both sides
```

- **Compare by content** of a pair: **Ctrl+F3** or double-click on the row; it opens the compare tool (§6) and works even when the file exists on only one side. To compare two unrelated files, select one on each side and choose **Compare left & right**.
- **Copy file properties** copies only the timestamp, attributes and/or NTFS permissions to the other side; if the files become equal, the row turns `=` (or `≠`).
- **Set local file date to remote date** (FTP only): see §5.10.
- **Rename** works only in the file system: F6 / Shift+F6, or two slow clicks on the name (`InplaceRenameSync=1`).
- **View / Edit** open Lister (10) and the editor; an editor started with F4 / Shift+F4 or from the context menu gets `%COMMANDER_OPEN%=sync` (19 › Variables defined by TC).
- **Delete:** with *Empty directories* on, empty directories are removed too.
- What *Print selected...* prints was not recorded.

**Navigation:** Ctrl+PgDn / Ctrl+PgUp jump to the next / previous subdirectory.

**Subdirectory indicator** (next to the Show group, e.g. `6/9 dups\sub`): the index of the subdirectory (0 = base) and the total, plus its name. It refers to the focused row if visible, otherwise to the topmost visible row, and stays visible after the comparison. **Right-click** on it scrolls to the next subdirectory (making it the top row), **left-click** to the previous one.

### 5.7 Show filter

The Show buttons act at once, without a new comparison:

| Button | Shortcut | `SyncButtons` bit | Shows |
|---|---|---|---|
| `→` (green) | Ctrl+Shift+L | 1 | rows whose computed direction is L→R |
| `=` | Ctrl+Shift+E | 2 | equal rows |
| `≠` (red) | Ctrl+Shift+N | 4 | different rows without a default direction |
| `←` (blue) | Ctrl+Shift+R | 8 | R→L rows (or deletions, asymmetric) |
| duplicates | Ctrl+Shift+D | 16 | files present on **both** sides |
| singles | Ctrl+Shift+S | 32 | files present on **one** side |

- The shortcuts do not work while the focus is in a path edit box. The default bit sum is 63 (all down).
- When any button hides rows, the status bar shows a filter symbol and the number of hidden rows at its right, and the footer shows displayed **and** total counts.
- If *duplicates* or *singles* is up when the dialog opens, it carries an exclamation mark. If both are up when the dialog is closed (nothing would be shown), both are down at the next open.

### 5.8 Status line (footer)

- Before a comparison: "Please press 'Compare' to start". With nothing found: `Files found: 0`.
- While comparing: the number of left and right directories visited. While comparing by content: files compared / total, bytes compared / total and a percentage (also in the taskbar).
- After the comparison: the number of rows with files and the breakdown, e.g. `Files found: 38  (Identical: 20, Different: 1, Unique left: 16, Unique right: 1)`: **Identical** = pairs considered equal, **Different** = pairs considered different, **Unique left / right** = files on one side only. The help adds, in square brackets, the total files found (L+R) and directories found/scanned (not recorded in the observed lines). Directories are not counted as rows.
- A comparison longer than 10 s ends with a yellow taskbar progress bar.
- Directory read errors are reported per `SyncWarnErrors`: 0 never; 1 (default) on read failure (e.g. lost network connection); 2 on access denied; 3 both.

### 5.9 The "Synchronize" dialog and the run

**Synchronize...** opens a dialog titled **"Synchronize"**:

```
[x] Left to right: Copy 16 files, total size: 6,363,930 bytes
    [c:\tc-sandbox\B                              ] [>>]
[x] Right to left: Copy 2 files, total size: 2,527 bytes
    [c:\tc-sandbox\A                              ] [>>]
[ ] Right: Delete 0 file(s)                  (greyed when 0)
[ ] Right: Delete all empty directories      (greyed unless asymmetric)
──────────────────────────────────────────────────────
[x] Confirm overwrites
[ ] Verify
[ ] Copy NTFS permissions (may need administrator rights)
                  [ OK ] [ Cancel ]
```

| Element | Semantics |
|---|---|
| **Left to right** target | Target for the checked left files. Default: the right path, so older right files are overwritten. Any folder is allowed. With a `zip:` prefix the files are packed into that ZIP; no other packer is supported. |
| **Right to left** target | The same for the checked right files. |
| **Right: Delete xxx file(s)** | Asymmetric only: delete the checked (✕) right files that no longer exist on the left. |
| **Right: Delete all empty directories** | Asymmetric only: delete empty directories on the right, **including** ones that still exist on the left. |
| **Confirm overwrites** | Ask before overwriting targets (`[Confirmation] SyncConfirmOverwrite`, default 1). |
| **Verify** | Verify the copies, as in the Copy dialog (07 › NTFS permissions, alternate streams, Verify). |
| **Copy NTFS permissions** | Copy the NTFS permissions; may need administrator rights (07 › NTFS permissions, alternate streams, Verify). |
| **OK** | Run the operations. **Shift+OK** deletes **directly** instead of to the recycle bin (Shift also works in the delete confirmation). |

**Running it**

1. **Right-to-left** copies run first, in a progress window captioned **"Right -> Left"** (`1 / 2`).
2. With *Confirm overwrites* on, the normal Overwrite dialog (07 › Name collisions: the Overwrite dialog) appears for an existing target.
3. Then **"Left -> Right"** runs.
4. Afterwards, with `SyncRecompareAfterCopy=1` (default), the comparison re-runs by itself (here: `Identical: 38 …`). With `0` the list is cleared and the user must click Compare.

- New directories get the source directories' timestamps (file system ↔ file system).
- With *Empty directories* off, empty source folders are **not** created; folders that hold only a `.keep` file are (they contain a file).
- A user-defined "copy/delete complete" sound may play.

### 5.10 Synchronizing with FTP

The FTP client is described in 11; the `wcx_ftp.ini` keys these rules rely on are listed in 11 › Synchronize with an FTP server and 19 › `wcx_ftp.ini`. This section gives the synchronize rules.

**First use.** With an FTP panel, a warning box (title not recorded) appears first:

```
Synchronize with FTP:
WARNING: This function changes the local file date/time even when uploading!
Please read the help about it before proceeding!
                            [ OK ]
```

**OK** also opens the help topic **"Synchronize dirs with FTP and MLSD command"**. This is the one-time warning controlled by `FirstFTPSync=1` (first FTP sync) and `FirstMLSDsync=1` (first sync over MLSD) (inferred). The window then has an **FTP time offset** group, shown only for local↔network comparisons:

```
┌ FTP time offset ──────────────────┐
│ dT= [0] h   [x] mdtm   [x] utc    │
└───────────────────────────────────┘
```

Against a test server without checksum commands, *by content* was greyed. The result line read `Files found: 6 (Identical: 1, Different: 0, Unique left: 1, Unique right: 4)`, with seconds in the times. Running *Synchronize...* against the server was not recorded.

**The timestamp problem.** An uploaded file normally gets the **server's current time**, so the pair looks different again right after syncing.

```
after a successful upload of L to R:
    if mdtm is ticked and the server supports MDTM <time>, MFMT or SITE UTIME:
        set remote time := local time          # MFMT / SITE UTIME preferred when available;
                                               # SITE UTIME (two variants) is the fallback
    elif not ignoreDate and SyncAllowChangeLocalTime (wcx_ftp.ini, default 1):
        set local mtime(L) := listed mtime(R)
```

- **mdtm** enables setting the remote time; **utc** sends that time as UTC, which most servers expect (some want local time). They correspond to `wcx_ftp.ini MDTM` (default 3 = both on; used only by Synchronize); `SpecialFlags` can force one of the three commands (11 › Synchronize with an FTP server). Timestamps can also be pushed to file-system plugins that support it.
- **Consequence of changing local times:** never synchronize that local directory with more than one location (another local directory or a second FTP site), because every upload changes local times. Not done when *ignore date* is on.

**Time zone `dT= … h`.** The hour offset between the user and the server, **positive when the server is to the west**, negative when east (New York → California = 3; Germany → California = 9). It is stored **per server name** (`wcx_ftp.ini [TimeZone]`), so all connections to that host share it, and separately for MLSD listings. With **MLSD** listings (the default) times are UTC, so the offset **must be 0**.

**MLSD vs LIST**

- MLSD gives 1-second resolution, UTC times and a standardized format.
- Syncs made with TC 7.50a or older were based on LIST times (no seconds, older files date only), so such pairs may now show as newer/older. If they are known to be identical, use **Set local file date to remote date**.
- Some old servers report symbolic links as plain files/directories under MLSD; synchronize ignores links to avoid loops but cannot detect these. For such servers switch off *Use MLSD for directory listings* in the connection settings (11 › "FTP: connection details" dialog; 11 › Listing: MLSD or LIST, hidden files, raw listing).

**Set local file date to remote date** (context menu, FTP only): copies the remote timestamps to the selected local files, so same-size files then compare equal. Meant for files known to be identical, e.g. uploaded with another program.

**Case of names**

- Uploading over a remote file whose name differs only in case keeps the **existing remote name**; to change the case, delete the remote file first (select, right-click › delete).
- For files not yet on the server, the user chooses to keep the name or convert it to lowercase (`wcx_ftp.ini LowercaseUpload`).
- If both `index.htm` and `INDEX.HTM` exist remotely, the exact-name match is synced and the rest is shown red and ignored (it can still be viewed or deleted).

**Unix text files.** When timestamps are equal but sizes differ, TC counts the line ends of the local file and computes the Unix-style size (`localSize − count(CR LF)`). If it matches the remote size, the row shows the special FTP text symbol: identical only if the remote is a Unix text file.

**Saving:** FTP connections cannot be saved as sync sets.

### 5.11 Keys and ini keys

| Key | Action |
|---|---|
| Ctrl+Shift+L / E / N / R / D / S | Toggle the Show buttons (§5.7); not in path edit boxes |
| F2 | Saved sync sets menu |
| Ctrl+D / Ctrl+M | Mark / unmark for copying (default direction) |
| Ctrl+L / Ctrl+R / Ctrl+W | Mark L→R / R→L / reverse direction |
| Ctrl+Alt+L / Ctrl+Alt+R | Copy file properties L→R / R→L |
| Ctrl+P | Print selected |
| Ctrl+F3, double-click | Compare by content / compare left & right |
| F3 / Shift+F3 | View left / right |
| F4 / Shift+F4 | Edit left / right |
| F6 / Shift+F6 | Rename left / right |
| Alt+Down / Alt+Shift+Down | Shell context menu of the left / right file |
| Alt+Enter / Alt+Shift+Enter | Properties of the left / right file |
| Ctrl+PgDn / Ctrl+PgUp | Next / previous subdirectory |
| Space / Shift+Space | With several rows selected: act on each row |
| Shift + OK (Synchronize dialog) | Delete directly instead of to the recycle bin |

| Key | Default | Effect |
|---|---|---|
| `SyncFlags` | 1 | last compare options (§5.4) |
| `SyncButtons` | 63 | last Show buttons (§5.7) |
| `SyncMatch` | 1 | last match mode (§5.3) |
| `SyncHideHiddenSystem` | 0 | §5.4 |
| `SyncIgnoreJunctions` | 0 | §5.4 |
| `SyncRecompareAfterCopy` | 1 | §5.9 |
| `SyncWarnErrors` | 1 | §5.8 |
| `InplaceRenameSync` | 1 | rename by two clicks |
| `[Confirmation] SyncConfirmOverwrite` | 1 | default of *Confirm overwrites* |
| `FirstFTPSync`, `FirstMLSDsync` | 1 | one-time FTP warnings |
| `1hourdif` | 0 | exact 1-hour differences count as equal |
| `[SyncOptions]` | — | saved sets (§5.2) |
| `[CompareCustomField]` | — | plugin compare definitions |
| `SyncTabs`, `Sync*` | — | tab stops, window geometry |
| `[Colors] SyncSelBack` | −1 | background of selected rows |
| `wcx_ftp.ini`: `SyncAllowChangeLocalTime`, `MDTM`, `LowercaseUpload`, `[TimeZone]` | 1, 3, 0, — | §5.10; 11 › Synchronize with an FTP server |

The keys are described in 19 › Synchronize directories and 19 › Saved tool settings and drive names; the same window keys appear in 06 › Synchronize directories.

### 5.12 Related: synchronous directory changing

`cm_SyncChangeDir` (2600, "Synchronous directory changing in both windows") makes a directory change in one panel repeat in the other. `SyncChangeDirMode` (default 2):

| Value | Effect |
|---|---|
| 0 | turn the mode off when the other panel has no same-named directory |
| 1 | keep the mode on |
| +2 | beep on the first failed attempt |
| +4 | suspend while inside a one-sided directory (or going up when the other parent has a different name); resume on returning to the base directory or jumping elsewhere (bookmark, button …). A button with `cm_SyncChangeDir` shows a pause overlay `‖` |

When Enter is pressed on a directory that does not exist on the other side, TC does not enter it; the mode is turned off only on the next attempt.

*Basis: observed in sandbox tests under Wine (comparison, rows, context menu, Synchronize dialog and run), on screen under Wine (layout, Search filter) and on Windows 11 (FTP warning, time offset group, FTP result); help: synchronize_dirs, dlg_synchronize_dirs, dlg_synchronize, sync_ftp, synchronize_mlsd, wcx_ftp_ini_settings, inisettings1–3; inc.txt; HISTORY.TXT.*

## 6. Compare by content

### 6.1 Opening and choosing the files

```
sel = selected files in the active panel
if |sel| >= 2:   compare sel[0], sel[1]
elif |sel| == 1:
    tsel = selected files in the target panel
    if |tsel| >= 1: compare sel[0], tsel[0]
    else:           compare sel[0], <target dir>\<same name>   (if it exists)
else:            compare <file under cursor>, <target dir>\<same name>
```

- The target panel's cursor file is never used.
- If `Comparetool=` is set (e.g. WinMerge), the external tool is started instead; `cm_IntCompareFilesByContent` always uses the internal one.
- The tool also opens from Synchronize (Ctrl+F3, double-click, §5.6) and from the Overwrite dialog (*More Options › Compare*, Ctrl+F3; Ctrl+Shift+F3 forces the internal tool; 07 › Name collisions: the Overwrite dialog).
- The window opens and **compares at once**. Other files can be typed, picked with `>>`, or **dropped** (one or two names) onto the path boxes, followed by **Compare**.
- **Identical files** give only a message box titled "Compare contents": "The two files have the same content!" (from the Overwrite dialog, TC then returns to that dialog).

### 6.2 Window

A modeless, resizable window titled **"Compare contents"**:

```
[left file path                                     ] [>>] | [right file path                         ] [>>]
[ Compare ] [ Next difference ] [ Previous difference ] [ Font ] [🔭][🔭…] [ ] Binary   | [ ] Case sensitive
[ Edit mode ] [ ] Show only differences, with extra lines: [2 ▾] [ Sync: 1 ] [▭] [💾] [ ANSI<->ANSI ] | [x] Ignore repeated spaces
                                                                                       | [x] Ignore frequent lines
┌──────────────────────────────────┬──────────────────────────────────┐
│ left text                        │ right text                       │  (line-aligned, synchronised scrolling)
└──────────────────────────────────┴──────────────────────────────────┘
┌─────────────────────────────────────────────────────────────────────┐
│ current line of the active side                                     │  (two-line list)
│ matching line of the other side                                     │
└─────────────────────────────────────────────────────────────────────┘
[≡] status line
```

| Control | Function |
|---|---|
| **Compare** | Compare the two named files |
| **Next / Previous difference** | Jump to the next / previous difference; a contiguous block of differing lines counts as **one** |
| **Font** | Font of the two panes (`CompFontName`, `CompFontSize`, `CompFontStyle`; `CompCharSet` is not used on NT-based Windows) |
| `🔭` / `🔭…` | Search in **both** files at once / continue the search |
| **Binary** | Force binary mode (§6.3); a **8/16/24/32 Bytes** selector appears in binary mode |
| **Edit mode** | §6.6 (F6) |
| **Show only differences, with extra lines: n** | §6.5 |
| **Sync: n** | Within-line method menu (§6.4) |
| `▭` | Show the two panes above each other (`CompareVertical`) |
| `💾` | Open the save dialog for changed files; disabled until something is edited |
| **ANSI<->ANSI** | Choose Encoding (§6.8); the caption shows the two encodings |
| **Case sensitive**, **Ignore repeated spaces**, **Ignore frequent lines** | §6.4 |
| **Copy ->** / **Copy <-**, **Undo** | Edit mode only (§6.6) |

Defaults: *Case sensitive* off, *Ignore repeated spaces* **on**, *Ignore frequent lines* **on**, *Binary* off.

### 6.3 Loading, mode and encodings

- **Text vs binary:** text files are shown in text mode, binary files in hex mode. **Binary** forces fixed-width hex lines of 8/16/24/32 bytes (`CompareBytesPerLine`, default 8).
- **Memory:** files up to `MaxCompareSizeInMem` (default 1 048 576 bytes) are loaded entirely, so the originals stay editable by other programs. Larger files are **memory-mapped** and stay **locked** during the comparison. Files over 2 GB are supported (64-bit).
- **Encodings** are detected by BOM: `FF FE` UTF-16 LE; `FE FF` UTF-16 BE ("Unicode MacOS"); `EF BB BF` UTF-8. UTF-8 is also detected from an HTML `<meta … charset=UTF-8>`, an XML `encoding="UTF-8"` or a CSS `@charset "utf-8"` header, and per `CompareUtf8Detect`: 0 BOM only; 1 (default) at least one valid multi-byte sequence, or the header; 2 no invalid sequence. Any mix of ANSI, UTF-8 and UTF-16 LE/BE can be compared.

### 6.4 Comparison rules

**Line alignment.** After a difference the comparison re-synchronizes on matching lines. `CompareFindLines` sets how many: 0 no re-sync (line i ↔ line i, differences only within lines); 1 (default) one matching line suffices; ≥2 two passes, first a multi-line anchor, then single-line matches inside.

**Ignore frequent lines** (`CompareIgnoreRepeatedLines=1`): when looking for re-sync anchors, lines that occur very often (e.g. `begin` / `end`) are not used. This gives better results when whole paragraphs were added or removed; turn it off for lists with meaningful repeated lines.

**Line equality**

- **Ignore repeated spaces** (`CompareIgnoreRepSpace=1`): runs of spaces/tabs count as one, and leading/trailing whitespace is ignored (`"test1   test2   "` equals `"test1 test2"`; `"a     b"` equals `"a b"`). This only decides whether two lines are *equal*; once a line is marked different (or is being edited), the character-level diff inside it is exact.
- **Case sensitive** (`CompareCaseSensitive=0`): off = lines differing only in case are equal (Pascal, Basic); on = they differ (C).
- `CompareSkipLineNumbers=1` skips all digits at the start of each line (numbered listings).
- These three options have **no effect in binary mode**.

**Within-line diff** (the **Sync: n** button, menu "Method for comparing text within a line:", `CompareResync`):

| n | Menu item | Method |
|---|---|---|
| 1 (default) | Find inserted text within a line (re-synchronize) | after a difference, look for at least 3 matching characters and continue there, even mid-word (TC 10 behaviour) |
| 2 | Find inserted text only at spaces | re-sync only at spaces |
| 3 | Find inserted text only at user-defined separators: `., ;:_+-*/\?!(){}[]"'@` | re-sync only at `CompareResyncSeparators` (default `., ;:_+-*/\?!()[]{}"'@`, including a space); **Edit user-defined separators...** changes them |
| 0 | Comparison at fixed positions (e.g. for tables) | no re-sync |

The within-line comparison covers at most 4096 characters per line; lines themselves may be longer.

### 6.5 Display

- The window opens scrolled to the **first difference**, near the top, with the cursor line highlighted.
- **Changed lines:** the line number and the changed characters are red, diffed at character level (`jump[s]` vs `jump[ed]`). With *Case sensitive* off, `quick` / `QUICK` is not highlighted.
- **Inserted lines:** red on one side, with an empty grey filler row (no number) on the other. Lines past the end of the shorter file show a red line-number stub (e.g. `11:`).
- **Show only differences, with extra lines: n** (`CompareExtraLines=2`): only differing or edited lines plus n context lines above and below, in hunks separated by thin horizontal lines. The checkbox is hidden in edit mode; leave edit mode briefly to toggle it.
- **Two-line list** (`CompareTwoLineList=1`; F9 or the icon at the left of the status line toggles it): the current line of the active side above the matching line of the other side. Scroll it sideways with Left/Right, PgUp/PgDn, Home/End or the mouse wheel; **Ctrl+Tab** jumps between the main panes and the list; Ctrl+wheel scrolls it even when the mouse is elsewhere (Ctrl+Alt+wheel still scrolls by page).
- **Layout:** side by side, or above each other (`CompareVertical=1`); the divider position is kept in `CompareDivider` (per mille, default 500).
- **Colours** (Configuration › Color › *Compare by contents*, 13 › Display › Color): `[Colors] CompareText`, `CompareTextSel` (text-mode differences, selected), `CompareBinary`, `CompareBinarySel` (binary mode), `CompareDifferenceBack` (lines with differences: −2 slightly different, −1 same as normal, else RGB; default −2), `CompareNormalBack`, `CompareNormalText`, `CompareSelBack`, `CompareSelText` (−1 = the Windows colours), `CompareSearchLine` (underlined search hits).

### 6.6 Edit mode and saving

- **Edit mode** (button or F6) makes both files editable; text and Unicode files are supported. The panes stay aligned automatically.
- New or changed lines get line number **0**; existing lines keep their original numbers.
- **Copy ->** / **Copy <-** (visible only in edit mode; also Alt+Right / Alt+Left) copy the selected text, or the whole current line when nothing is selected, to the other side (right, or lower in the vertical layout), replacing the corresponding lines. Typically used with Next/Previous difference.
- **Undo** (Ctrl+Z or Alt+Backspace) can go back to the original state; before undoing, the cursor moves to where the last change happened.
- **Paste** (edit mode only) pastes text; a paste taking over 2 s shows an abortable progress (the abort does not revert).
- **F2 / Shift+F2** go to the next / previous difference within the line, per `CompareF2Mode`: 0 stay in the line; 1 (default) continue on the next line with differences; 2 wrap within the line.
- **Saving** (`💾` or Ctrl+S): when closing or re-comparing with unsaved changes, the user is asked. Line ends are written in the **majority** style of the original (mostly CRLF with a few LF → all CRLF). A BOM is written only if the original had one, unless `CompareAlwaysSaveWithBom=1`. With `CompareSaveOriginal=1` (default) the original is copied to `name.bak` and then `name` is overwritten, which preserves streams and attributes; with `0`, TC writes `name.tmp`, renames the original to `name.bak` and the `.tmp` to `name` (written once; the file stays intact on a write error). `CompareDeleteBak=1` deletes the last `.bak` of each side when the tool closes.

### 6.7 Context menu, search, windows

- **Context menu** (right-click, Shift+F10, Menu key): **Copy selection to clipboard** (in binary mode `00` bytes become spaces); **Paste here** (edit mode); **Resync comparison from here** (select one line on each side first; they become a forced alignment anchor; after edits, Undo can then only go back to this point); **Swap Panels** (Ctrl+U, also while editing).
- **Search** in both files at once: Ctrl+F or F7; F3 continues; Shift+F3 searches backwards once (the next F3 goes forwards); Ctrl+F3 reverses the direction. Hits are underlined in the `CompareSearchLine` colour.
- The tool is modeless: several compare windows may be open while TC stays usable. It closes with Esc, Alt+F4 or the title-bar close button. `SameScreenAsTC` bit 4 keeps it on TC's monitor. Geometry: `Compare*`.

### 6.8 "Choose Encoding" dialog

Opened by the **ANSI<->ANSI** button; possible only **before** a file has been modified.

```
Left:   (o) ANSI (plain text)       Right:  (o) ANSI (plain text)
        ( ) Unicode (UTF-16)                ( ) Unicode (UTF-16)
        ( ) Unicode MacOS                   ( ) Unicode MacOS
        ( ) UTF-8                           ( ) UTF-8
                     [ OK ] [ Cancel ] [ Help ]
```

| Option | Meaning |
|---|---|
| ANSI (plain text) | 8-bit text; the chosen **font's** charset decides the code page |
| Unicode (UTF-16) | 2 bytes per unit (rarely 4); BOM `FF FE` |
| Unicode MacOS | UTF-16 with odd/even bytes swapped (big-endian); BOM `FE FF`. Use it when the BOM is missing |
| UTF-8 | 1–4 bytes per character; BOM `EF BB BF`; HTML/XML/CSS headers are auto-detected |

**OK** switches to the chosen encodings; **Cancel** changes nothing.

### 6.9 Keys

| Key | Action | Mode |
|---|---|---|
| Ctrl+C, Ctrl+Insert | Copy the selected text | always |
| Ctrl+A | Select all | always |
| Ctrl+F, F7 | Search in both files | always |
| F3 / Shift+F3 / Ctrl+F3 | Continue / backwards once / reverse direction | always |
| Ctrl+U | Swap panels | always |
| Shift+F10, Menu key | Context menu | always |
| Alt+Up / Alt+Down | Previous / next difference | always |
| F6 | Edit mode on/off | always |
| F9 | Two-line list on/off | always |
| Ctrl+Tab | Main panes ↔ two-line list | always |
| Esc, Alt+F4 | Close | always |
| Ctrl+V, Shift+Insert | Paste | edit |
| Ctrl+S | Save dialog | edit |
| Ctrl+Z, Alt+Backspace | Undo | edit |
| Ctrl+Left / Ctrl+Right | Move by word | edit |
| Alt+Left / Alt+Right | Copy the selection to the left / right pane | edit |
| Del / Backspace | Delete the selection, or the character right / left of the cursor | edit |
| Double-click / triple-click | Select word / line | edit |
| F2 / Shift+F2 | Next / previous difference within the line | edit |
| Insert, Space | Select a line | read-only |
| Left / Right | Scroll by 1 character | read-only |
| Alt+Left / Alt+Right | Scroll by 30 characters | read-only |

Tilting the mouse wheel scrolls sideways (faster with Ctrl). The same keys appear in 06 › Compare by content.

### 6.10 Ini keys

`CompareCaseSensitive=0`, `CompareIgnoreRepSpace=1`, `CompareIgnoreRepeatedLines=1`, `CompareFindLines=1`, `CompareResync=1`, `CompareResyncSeparators`, `CompareSkipLineNumbers=0`, `CompareExtraLines=2`, `CompareF2Mode=1`, `CompareTwoLineList=1`, `CompareVertical=0`, `CompareBytesPerLine=8`, `CompareUtf8Detect=1`, `CompareAlwaysSaveWithBom=0`, `CompareSaveOriginal=1`, `CompareDeleteBak=0`, `MaxCompareSizeInMem=1048576`, `Comparetool=`, `SameScreenAsTC` (bit 4); window `Compare*`, `CompareDivider=500`; font `CompFont*`; colours in `[Colors]` (§6.5). Details: 19 › Compare by content and 19 › `[Colors]` and `[ColorsDark]`.

*Basis: observed in sandbox tests under Wine (opening, rendering, defaults, identical files) and on screen under Wine (layout, Sync menu, Choose Encoding); help: compare_by_content, dlg_compare_contents, dialog_choose_encoding, inisettings1–3; HISTORY.TXT.*
