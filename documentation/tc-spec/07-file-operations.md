# 07: File operations

This chapter specifies every operation that changes files from the file panels: copy, move and rename, new folders and
new files, delete, attributes, shortcuts, NTFS permissions and streams, file comments and the file clipboard, plus the
two information boxes Properties and Calculate occupied space. For each operation it gives the dialog layout, the rules
that decide the result, the follow-up prompts and errors, and the state of the panels afterwards. Background jobs (F2
Queue, the Background button and the Background Transfer Manager) are also described here.

**Related:** 01 (operand rule and job engine as concepts), 03 (selection, refresh, comments view, hidden files), 05
(drag & drop, context menus), 06 (complete key reference), 08 (pack and unpack when an archive is involved), 09
(Multi-Rename Tool, Compare by content, Find Files filters), 10 (F4/Shift+F4 editor launching), 11 (FTP transfers), 12
(Directory Tree dialog), 13 (Configuration pages Copy/Delete, Operation, Misc), 17 (`cm_` commands), 18 (placeholders
and masks), 19 (`wincmd.ini` keys, `descript.ion` format), Appendix A (host differences).

## 1. Common rules

### 1.1 Operand rules

- **Source** is the active panel, **target** the other panel.
- The **operand set** is the selection if it is not empty, otherwise the item under the cursor. `[..]` is never an
  operand; Ctrl+A never selects it. Only Alt+Enter (§12) and Ctrl+Z (§11) on `[..]` act on the current folder itself.
- Dialog headings count files plus folders: `Copy N file(s) to`. A single **file** gives `Copy "name" to`; a single
  **folder** still gives `Copy 1 file(s) to`.
- The **counter strip** of the Copy and Move dialogs (§2.2) shows the total size, the number of files and the number of
  folders. The folder count includes the selected folders themselves **and** all their subfolders: one folder holding 13
  files shows `6.68 k  13  1`; a folder holding one 15-byte file and one subfolder shows `15 b  1  2`.
- Hidden and system files can be operands only while the panel shows them (§9.6).
- Every OK in an operation dialog creates a **job**. It runs in the foreground with a progress window (§3), or in the
  background (§5).

### 1.2 Where each operation works

| Operation                | Local / network file system  | Source panel shows an archive                                                     | Target panel shows an archive                               | FTP / file-system plugin                                                                                                                                                                                         |
| ------------------------ | ---------------------------- | --------------------------------------------------------------------------------- | ----------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Copy F5                  | yes                          | the Unpack dialog opens instead (08 › Unpack)                                     | the Pack dialog opens instead (08 › Pack)                   | upload or download (11 › Transfers). Archive → FTP works: the files are unpacked to a temp folder, then uploaded. **FTP → archive is refused**, because a failed pack after a long download would lose the data. |
| Move F6                  | yes                          | unavailable, except Shift+F6 renaming of a single file or folder inside a **ZIP** | pack, then delete the source ("move to archive", 08 › Pack) | 11 › File operations on the server                                                                                                                                                                               |
| Delete F8                | yes (recycle bin if enabled) | the packer deletes **directly**, never to the recycle bin                         | —                                                           | 11 › File operations on the server                                                                                                                                                                               |
| New folder F7            | yes                          | only **ZIP, RAR, TAR**                                                            | —                                                           | 11 › File operations on the server                                                                                                                                                                               |
| New file Shift+F4        | yes, also several at once    | an empty temp file, then TC asks to pack it                                       | —                                                           | a temp file, then TC asks to upload it; several at once is **not** available                                                                                                                                     |
| Change attributes        | yes                          | not available                                                                     | —                                                           | FTP: the _Change UNIX attributes_ dialog (§10.7)                                                                                                                                                                 |
| Calculate occupied space | yes                          | not available                                                                     | —                                                           | —                                                                                                                                                                                                                |
| File comments            | normal files only            | no                                                                                | —                                                           | no (neither FTP nor plugins)                                                                                                                                                                                     |

### 1.3 Selection and refresh after an operation

- Every file operation first **saves the current selection**. `Num /` (`cm_RestoreSelection`, "Selection before last
  operation") brings it back. There is one slot, overwritten by each operation (03 › Saving and restoring the
  selection).
- Items that were fully processed are deselected. A copy filter leaves excluded files selected (§2.5). Skipping a
  read-only file in a delete cleared the selection (§9.3).
- TC re-reads the affected panels after its own foreground operations. Exceptions seen: creating several folders with
  `|` (§7.5). After a background job the help warns that F2 or Ctrl+R may be needed (§5.1).
- Where the cursor goes after each operation is listed in §15.

### 1.4 Esc guard

Before an operation starts, and while it runs, TC checks whether the Esc key is physically held down. If it is, it
aborts:

```text
Total Commander
(✗)  ESC is pressed - operation aborted!
     The ESC key seems to be stuck - press to release!
                       [ OK ]
```

- Nothing is done and the source selection stays. Releasing Esc clears the state.
- `ESCcheck=1` (default) enables the check before copying.
- The guard reacts only to a key that is really down: a copy started right after a normal Esc press runs normally. (The
  box was produced in the Wine session by a lost key-up; see A › Artefacts not to copy.)

### 1.5 Access denied and "As Administrator"

When a write operation fails for lack of rights, TC offers to repeat it **"As Administrator"**: for copy (Windows 2000
and newer), delete and new folder (XP and newer). The shield buttons start the helper `tcmadmin.exe`, which performs the
operation with another user's rights, or elevated when the user is already an administrator.

**Entering a folder that denies access** (NTFS _deny_ ACL):

```text
Total Commander
Access denied on file
c:\tc-sandbox\B\locked_target!
            [ OK ]  [ 🛡 As Administrator ]
```

OK keeps the panel where it was.

**Typing such a folder as the copy target:**

```text
(⚠)  The given target path
     c:\tc-sandbox\B\locked_target
     is invalid!
                       [ OK ]
```

The Copy dialog closes and nothing is copied (title not recorded).

**Writing where elevation is needed** (a file copied into `C:\Program Files\`): the "Copy:" progress window appears,
then:

```text
Access denied on file
c:\Program Files\system.txt!
[ Skip ]                [ Retry ]   [ Abort ]
[ Skip all ]            [ Rename ]
[ 🛡 As Administrator ] [ 🛡 All as Administrator ]
```

**Abort** cancelled the job with nothing written. A folder that cannot be created shows
`Error: Directory [<path>\] not created!` [OK] [🛡 As Administrator] (seen when a plugin install folder could not be
created, 15 › Installation).

| Key                 | Default | Effect                                                                                                                                                                                                                                    |
| ------------------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AdminTimeout`      | 180     | Seconds without activity after which `tcmadmin.exe` ends. While it lives the password is not asked again; it never ends while busy (e.g. a background copy as admin). `0` = never time out; `-1` = disable "As Administrator" completely. |
| `AlwaysAsAdmin`     | 0       | 1 = after the user once chose _All as Administrator_, every later item runs as admin.                                                                                                                                                     |
| `CopyDirsAsAdmin`   | 1       | A directory that cannot be copied: 0 = skip it, 1 = ask, 2 = always try the admin functions.                                                                                                                                              |
| `XPMoveMethodAdmin` | 1       | Like `XPMoveMethod` (§6.5), for moves done through `tcmadmin.exe`.                                                                                                                                                                        |

The _As Administrator_ route itself was not taken in the tests.

### 1.6 Long paths

- TC enters folders whose path is longer than 260 characters; the path bar then shows the end of the path with scroll
  arrows (03 › Current-directory bar (path bar)).
- F3 opens files there (the Lister title shows the full path), and F5 copied a file out of such a path to a short one
  without error.
- For target names longer than 259 characters, `LongNameCopy` decides: 0 = always warn (default), 1 = never warn, 2 =
  warn only if the source name is not already longer than 259, 3 = refuse long names.

_Basis: observed on Windows 11 (§1.4–1.6) and under Wine; help: proc_copy, proc_delete, proc_mkdir, proc_renmov,
proc_select, inisettings1–3._

## 2. Copy (F5) and its variants

### 2.1 Entry points

| Trigger                               | Command                    | Behaviour                                                                                              |
| ------------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------ |
| F5                                    | `cm_Copy` (905)            | Copy the operand set to the target (dialog §2.2). Folders are copied recursively.                      |
| Shift+F5                              | `cm_CopySamePanel` (3100)  | Copy within the same folder under a new name (§2.11).                                                  |
| Ctrl+Shift+F5                         | `cm_CreateShortcut` (1004) | Create `.lnk` shortcuts in the target (§2.12).                                                         |
| Alt+F5 / Alt+Shift+F5                 | —                          | Pack / pack and delete (08 › Pack).                                                                    |
| Alt+F9 (Alt+F6)                       | —                          | Unpack the archive under the cursor or the selected archives (08 › Unpack).                            |
| Left-drag onto the other panel        | —                          | Opens this Copy dialog with the target set to that panel's path plus the file name (05 › Drag & drop). |
| Ctrl+C / Ctrl+X, then Ctrl+V          | `cm_CopyToClipboard` etc.  | Copy or move through the clipboard (§14).                                                              |
| _F2 Queue_ in the dialog              | —                          | Append the job to the last opened Background Transfer Manager (§5).                                    |
| **Right-click** on _OK_ or _F2 Queue_ | —                          | Runs the **other** operation: move from the Copy dialog, copy from the Move dialog.                    |

### 2.2 Copy dialog

**Before the dialog:** while Configuration › Operation › _Calculate space occupied by subdirectories › before
copying/deleting_ is on (default), the selected folders are measured in the background while the dialog is already open
(`CountMarked`, `CountMarkedInDialog`). The computed size is written into the Size column and the folder is drawn as
selected (red), e.g. `[docs]` showed `6,841`.

Title "Total Commander":

```text
Copy 1 file(s) to
[c:\tc-sandbox\B\*.*                                  ▾] [+ F7]
Only files of this type:                6.68 k   [▤] 13   [📁] 1
[                                                     ▾] [+ F8]
[ ] Copy NTFS permissions (may need administrator rights)   [ ] Verify
[  OK  ] [ F2 Queue ] [ Tree ] [ Cancel ] [ Options >> ]
```

| Element                 | Behaviour                                                                                                                                                                                              |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Heading                 | `Copy N file(s) to`, or `Copy "name" to` for a single file (§1.1)                                                                                                                                      |
| Target combo            | Target path plus file mask, preselected. Rules in §2.3.                                                                                                                                                |
| `+ F7`                  | Popup `Add current dir (Position=0)` · `Directory hotlist (Ctrl+D)`. The first adds the current target folder to the stored target list, or removes it if it is already there.                         |
| Only files of this type | Copy filter (§2.5)                                                                                                                                                                                     |
| `+ F8`                  | Opens "Define selection" to define or load a saved search as the filter (§2.5)                                                                                                                         |
| Counter strip           | Total size, files (`▤`), folders (`📁`), computed in the background when the dialog opens. Sizes use units: `15 b` (bytes), `6.68 k`, `11.06 M`. A single file shows `15 b  1  0`.                     |
| Copy NTFS permissions   | §2.6                                                                                                                                                                                                   |
| Verify                  | §2.6                                                                                                                                                                                                   |
| F2 Queue                | §5                                                                                                                                                                                                     |
| Tree                    | Opens the Directory Tree dialog to pick the target folder (12 › Directory Tree dialog (Alt+F10)). To pick a folder on another drive, type the drive with its colon (`d:`) into the target field first. |
| Options >>              | Expands the dialog downward with _Advanced options_ (§2.7)                                                                                                                                             |

**Conditional elements:**

- **Keep relative paths** appears when copying out of a branch view (Ctrl+B, 03 › Branch view) or out of search results
  (_Feed to listbox_, 09 › Feed to listbox (search-result panel)): each file goes to
  `target\<path relative to the current folder>\name`, so the tree structure is kept. From search results the entire
  path is kept, the drive letter becoming a folder name (`C:` → `C`), and the choice is not remembered between sessions
  (change log). `RelativePathCopy` (default 2) is a sum: 1 = on at start, 2 = remembered while TC runs, 4 = remembered
  after closing, 8 = do not copy the drive letter or UNC server from search results; −1 hides the option.
- **Copy to ALL these locations** appears when folders or links are selected in the target panel (§2.8).
- **Rename each file separately** appears for Shift+F5 (and Shift+F6) with several files; TC then asks for each new name
  in turn.
- With _Use copy+paste via Explorer_ (§2.9) a reduced dialog is shown, with only confirm and cancel. The Move dialog is
  reduced the same way.

### 2.3 Target field

**Default:** the target panel's path plus `*.*`; for a single file, `<target path>\<name>`, fully selected.

**How the field is read:**

- It is a **path plus a file mask**. The mask may contain wildcards (§2.4). A plain new name renames the copy. An empty
  mask means `*.*`: names are kept. Example: `*.new` changes every extension to `new`.
- **Empty path** = the source folder, which makes the copy a copy-with-rename in place. `..` and `\` are accepted and
  are relative to the **source** folder.
- A target folder that does not exist is **created silently**, several levels at once (`…\work\newdir\sub\` created both
  levels and copied the file, with no question).
- A target the user may not write to is rejected ("…is invalid!", §1.5).
- `CopyToDirWarn=1` (default): warn when the target name given for a file is the name of an existing folder (message
  text not recorded).

**Editing aids:**

- **Auto-complete:** typing or pasting a path drops down a suggestion list (`…\work\dir2\` offered
  `…\work\dir2\ro.txt`). ↑/↓ cycle the suggestions; Tab behaviour follows `AutoCompleteTab` (06 › Keys in dialogs and
  tool windows).
- F5 pressed again selects only the file name; a third time also its extension. Ctrl+Home puts the caret just after the
  last `\`.
- **Alt+↓** opens the list: the stored target list (`[TargetList]`, maintained with `+ F7`), all open tabs, and the
  target panel's subfolders. Holding Shift lists the source panel's subfolders instead (help: what's new; when exactly
  Shift must be held is not stated).
- Ctrl+D opens the directory hotlist inside the dialog; F7, F8 and F2 press `+ F7`, `+ F8` and _F2 Queue_.

### 2.4 Wildcard target names

The target mask is split at its last `.` into a name mask and an extension mask; the source name is split the same way.
Each half is expanded separately, with a read position `p` in the source part:

```text
expand(src, mask):
  out = ""; p = 0; i = 0
  while i < len(mask):
    c = mask[i]
    if c == '?':                          # the source char at this position
        if p < len(src): out += src[p]
        p += 1; i += 1
    elif c == '*' and mask[i+1] == '*':   # "**": insert the WHOLE source part
        out += src; p = len(src); i += 2
    elif c == '*' and mask[i+1] == '?':   # "*?": rewind the read position, emit nothing
        p = 0; i += 2
    elif c == '*':                        # the rest of the source part from p
        out += src[p:]; p = len(src); i += 1
    else:                                 # a literal REPLACES the char at p
        out += c; p += 1; i += 1
  return out
target = expand(srcName, nameMask) + "." + expand(srcExt, extMask)
```

| Mask                 | Source     | Result                | Rule                                         |
| -------------------- | ---------- | --------------------- | -------------------------------------------- |
| `h?.txt`             | `test.txt` | `he.txt`              | `?` keeps the char at its position           |
| `f*.txt`             | `test.txt` | `fest.txt`            | `*` takes the rest from the current position |
| `F*Rest.*`           | `test.txt` | `FestRest.txt`        | text after `*` is appended                   |
| `start_**_rest.*`    | `test.txt` | `start_test_rest.txt` | `**` inserts the whole name after a prefix   |
| `start_*?do*_rest.*` | `name.txt` | `start_dome_rest.txt` | `*?` rewinds to the start of the name        |

The same rules apply to Move (F6), to Shift+F6 with several files, and (unverified) to the right-hand side of the
related-files syntax `A>B` (18 › File masks and selection types).

### 2.5 Only files of this type (copy filter)

Syntax: `include-masks [| exclude-masks]`, masks separated by spaces; folder patterns end in `\`. Full mask grammar: 18
› Find Files and copy-filter forms.

| Filter                       | Effect                                                                                                                       |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `*.txt *.doc`                | Only these types, in subfolders as well                                                                                      |
| `*.* \| *.bak *.old`         | Everything except `.bak` and `.old`                                                                                          |
| `*.* \| somedir1\ somedir2\` | Skip subfolders with these names, wherever they are                                                                          |
| `*.* \somedir1\`             | Files in the base folder, plus the **direct** subfolders named `somedir1` (a leading `\` anchors to the base folder)         |
| `*.* \somedir1\**\`          | As above, plus all folders below them                                                                                        |
| `*.* somedir1\`              | Files in the base folder, plus folders named `somedir1` **at any depth**                                                     |
| `*.* somedir1\**\`           | As above, plus all their subfolders                                                                                          |
| `… \| \` (appended)          | Exclude the files of the base folder itself                                                                                  |
| `… \| **\` (appended)        | Do not create folders from which no file was copied. Combinable: `\| \ **\`                                                  |
| `*.jpg>*.cr2`                | **Related files:** the JPGs, plus each CR2 that has a matching JPG in the same folder. Append `\|**\` to skip empty folders. |

- The filter applies only to the selected files and to the files inside selected folders.
- **`+ F8`** defines or loads a saved search (Find Files in "define" mode, 09 › Find Files) as the filter, so files can
  be filtered by size, date/time or content-plugin fields. These fields of a saved search are **ignored** as a copy
  filter: _Search in_, _Only search in selected directories/files_, _Everything_, _Search archives_, _Search in
  subdirectories_.

**Selection after a filtered copy:**

| Item                                                          | State afterwards                                                              |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| File excluded by the filter                                   | **Stays selected**, so it can be handled next with another filter             |
| File copied                                                   | Deselected                                                                    |
| Folder that was entered                                       | **Deselected**, even if it was only partly copied or nothing in it was copied |
| Folder skipped completely by the filter (e.g. `\| somedir1\`) | Stays selected                                                                |

### 2.6 NTFS permissions, alternate streams, Verify

**Copy NTFS permissions** copies the ACLs (read/write permissions), the owner, and the auditing information when it can
be read. Checked with `icacls` on a source with the explicit entry `BUILTIN\Guests:(R)` and an alternate data stream
`notes.md:extra` (13 bytes):

| F5 with …                             | ACL of the copy                                                     | Alternate data stream |
| ------------------------------------- | ------------------------------------------------------------------- | --------------------- |
| `[x] Copy NTFS permissions`           | `BUILTIN\Guests:(R)` plus the **target folder's** inherited entries | copied                |
| `[ ] Copy NTFS permissions` (default) | only the target folder's inherited entries                          | copied                |

- Alternate data streams are copied **by default**, independently of the permissions option (`CopyStreams=1`; always on
  with the default ReadFile/WriteFile method).
- The owner and auditing parts were not checked.
- The `Zone.Identifier` stream follows `WantZoneData` (default 7): bit 1 copies it from the source or archive to the
  targets when copying or unpacking internally or through plugins (not for CHM); the other bits concern downloads (11 ›
  Zone identifiers on downloads).

**Verify:**

- After each file is written, TC reads it again with the **disk cache bypassed** and compares checksums: **BLAKE3** if
  available, otherwise **MD5**.
- The box starts from Configuration › Copy/Delete › _Verify after copy (MD5/BLAKE3 checksum)_ (`VerifyCopy=0`).
- It works with every copy method except _copy+paste via Explorer_. `VerifyEnabled=0` hides the function completely.

### 2.7 Advanced options (Options >>)

```text
┌ Advanced options ─────────────────────────────────────────────┐
│ Overwrite options                                         [📌] │
│ [1. Ask user                                         ▾] [💾]   │
│ [ ] Skip all which cannot be opened for reading               │
│ [ ] Overwrite/Delete read only/hidden/system                  │
│ [ ] Copy to all selected folders/links in the target panel    │
└───────────────────────────────────────────────────────────────┘
```

| Element                                                | Behaviour                                                                                                              |
| ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------- |
| Overwrite options                                      | Default answer for name collisions in this job; the list is in §4.4                                                    |
| `📌`                                                   | Keeps the extension open (pinned) for later dialogs (`ShowCopyOptions=1` always shows it)                              |
| `💾`                                                   | Stores the chosen overwrite mode as the default (`CopyOverwriteDefault`)                                               |
| Skip all which cannot be opened for reading            | Skips unreadable source files without asking (semantics from the caption; not documented, unverified)                  |
| Overwrite/Delete read only/hidden/system               | Ignore the read-only, hidden and system attributes when overwriting or moving: the extra prompts of §4.8 are not shown |
| Copy to all selected folders/links in the target panel | Enabled only while the target panel has a selection (§2.8)                                                             |

### 2.8 Several targets

- **Folders and/or links selected in the target panel:** the option to copy to ALL these locations appears. These copies
  run through the Background Transfer Manager.
- **Normal files selected in the target panel** (e.g. after _Feed to listbox_, 09 › Feed to listbox (search-result
  panel)): TC copies into the folders that contain those files. Since 11.55 this respects _Keep relative paths_.

### 2.9 Copy method

Configuration › Copy/Delete (13 › Operation › Copy/Delete) decides how file data is copied:

```text
if ExplorerForCopy=1  ("Use copy+paste via Explorer (only in case of copy problems)"):
    copy through Explorer; reduced F5/F6 dialogs;
    no comment copying, no extended overwrite/rename options, no Verify
elif "Use standard copy method (recommended)"  (default):
    Win9x/ME → built-in ReadFile/WriteFile;  NT … Windows 11 → CopyFileEx
else:  # expert group
    if drive in CopyCompatDrives (letters; "\" = Network Neighborhood; "*" = all)
       or (CopyCompatUsbSticks=1 and the drive is a super-floppy USB stick):
        compatibility mode = CopyFileEx (not on 9x)
    elif "Also use big file copy mode (not using cache)" and file size > huge block size:
        unbuffered copy with CopyHugeBlockSize[Other]
    else:
        built-in ReadFile/WriteFile with CopyBlockSize[Other]
    "same disk" ⇔ source and target letters are in one group of SamePartitions
```

| Key                                       | Default                   | Meaning                                                                                                        |
| ----------------------------------------- | ------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `CopyBlockSize`                           | 32 (minimum)              | Buffer in KiB, same physical disk (UI: _Buffer sizes for small files_, same disk)                              |
| `CopyBlockSizeOther`                      | 32                        | Buffer in KiB, different disks                                                                                 |
| `CopyHugeBlockSize`                       | unset = big-file mode off | Minimum 10 MB; only larger files use the mode (UI proposes 10240 k)                                            |
| `CopyHugeBlockSizeOther`                  | —                         | Between disks (UI proposes 64 k; the help says "minimum 256 kB" and also recommends 32, which is inconsistent) |
| `SamePartitions`                          | —                         | Groups of letters on one physical disk, e.g. `CDE,FGH`                                                         |
| `CopyCompatDrives`, `CopyCompatUsbSticks` | —, 1                      | Compatibility mode drives; USB sticks                                                                          |
| `CopyDefaultMethod`                       | 1                         | Always use the default method (currently compatibility mode) on NT                                             |
| `ExplorerForCopy`                         | 0                         | 1 = F5/F6 through Explorer copy+paste                                                                          |

- Explorer mode exists for virus scanners that slow down every copier except Explorer.
- Compatibility mode is for USB sticks and other exotic drives; without it copying to or from sticks on XP is very slow
  because there is no cache.
- Big-file mode bypasses the cache: good on hard disks, possibly slow on USB drives, and some vendor disk drivers are
  buggy in it.
- The help advises a larger buffer on one disk than between two disks, so the head does not keep jumping.

### 2.10 Other copy settings

| Key                                            | Default         | Effect                                                                                                                                                                                                                                             |
| ---------------------------------------------- | --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AlwaysCopyInBackground`                       | 0               | 1 = always copy in the background; 2 = always use the Background Transfer Manager                                                                                                                                                                  |
| `CountMarked`                                  | 1               | Count the files in subfolders before copy/delete, which allows the total progress bar; 0 = faster. UI: _Calculate space occupied by subdirectories › before copying/deleting_                                                                      |
| `CountMarkedInDialog`, `CountMarkedBackground` | = `CountMarked` | The same, for the F5 counter strip and for the transfer manager                                                                                                                                                                                    |
| `SizeCheck`                                    | 1               | Check that the target has enough free space before copying                                                                                                                                                                                         |
| `CopyAllTimes`                                 | 0               | 1 = also copy creation and last-access times; by default only the last-modified time is copied                                                                                                                                                     |
| `CopyDirTimeStamp`                             | 0               | Copy the folders' last-modified time (UI: _Copy date/time of directories_); also when unpacking explicitly packed folders. With the default, copied folders get the time of the copy. NTFS may change a folder's time when files inside it change. |
| `CopyLinks`                                    | 0               | Junctions/links: 0 = copy as folders (or ignore with `IgnoreLinks` bit 1); 1 = copy the link unchanged; 2 = copy it and re-point a target on the link's own drive to the target drive. Link targets are not checked.                               |
| `CopySparseFiles`                              | 0               | 1 = copy only the non-zero parts of sparse files                                                                                                                                                                                                   |
| `SubdirCopyOrder`                              | 4               | Order of files inside copied subfolders: 4 = unsorted (file-system order); 0…3 = ascending by name, ext, size, date; −1…−4 descending; 5 = as the active panel                                                                                     |
| `SkippedFileCopy`                              | 1               | 1 = first copy every file that needs no question and skip those with errors, asking at the end; 0 = copy in order and ask when needed; ≥ 100 = like 1, but the user is also asked during that many ms at the start                                 |
| `ThumbsCopyDel`                                | 1               | Copy/delete cached thumbnails together with their files (UI: Thumbnails › _Copy/delete thumbnails with files_)                                                                                                                                     |
| `CopyComments`                                 | 6               | Flag 8 = copy and move comments with their files (§11.3)                                                                                                                                                                                           |
| `CopyStayOnFile`                               | 0               | §2.11                                                                                                                                                                                                                                              |
| `AppendLnk`                                    | 2               | §2.12                                                                                                                                                                                                                                              |

### 2.11 Copy within the same folder (Shift+F5)

```text
Copy "ro.txt" to
[ro.txt                                      ▾]     ← name only, selected
[ ] Copy NTFS permissions (may need administrator rights)
[ ] Verify
[ OK ] [ Tree ] [ Cancel ]
```

- There is **no** F2 Queue, Options >>, `+ F7` / `+ F8` or counter strip.
- The initial selection follows `RenameSelOnlyName` (§6.2).
- After OK the cursor is on the new file; `CopyStayOnFile=1` keeps it on the original.
- With several files, _Rename each file separately_ asks for each new name in turn.

### 2.12 Create shortcut (Ctrl+Shift+F5)

```text
Create shortcut of "long_path_file.txt" as
[c:\tc-sandbox\B\long_path_file.lnk                    ▾] [+ F7]
Only files of this type:
[                                                       ▾] [+ F8]
[ OK ] [ Tree ] [ Cancel ] [ Options >> ]
```

- The proposal is the target panel's path plus the item's name, named by `AppendLnk` (default 2): 0 = `file.ext` →
  `file.lnk`; 1 = `file.ext` → `file.ext.lnk`; 2 = like 0 for files and like 1 for folders. With the default, `.txt` was
  replaced by `.lnk`.
- **Options >>** shows the same _Advanced options_ block as Copy (§2.7); _Copy to all selected folders/links in the
  target panel_ was greyed.
- Result: `long_path_file.lnk`, 2,513 bytes, created in the target panel's folder and listed with Ext `lnk` (TC shows
  the extension that Explorer hides).
- If the `.lnk` already exists, the Overwrite dialog (§4) shows `<LNK> -> <source file>` for the new link, to make clear
  that the source itself is not copied (change log, 11.58).

### 2.13 Append

To append file A to file B: keep the overwrite confirmation on (Misc › _Overwriting files_), copy A with the target name
B, and choose **Append** in the Overwrite dialog. `AppendWarning=1` (default) asks once more before appending (text not
recorded); 0 skips that question. Append is not offered when the collision comes from a rename (§6.4).

_Basis: observed under Wine and on Windows 11 (dialogs, shortcuts, NTFS permissions); help: proc_copy, add_trgpath,
add_filemask, dlg_configcopydelete, inisettings1–3; change log ("Keep relative paths" in search results, `<LNK>` in the
Overwrite dialog)._

## 3. Progress window and job sequence

### 3.1 Progress window

```text
Copy:
From: c:\tc-sandbox\A\docs\report_01.txt
To:   c:\tc-sandbox\B\docs\report_01.txt
[                               ]   0 %     ← current file
[█████                          ]  16 %     ← total
7 / 14                       6.6 k          ← items done / items; total size
[ Pause ] [ Cancel ] [ Background ]
```

- The title line names the operation: `Copy:`, `Rename/Move:`, `Deleting:` (exact positions of the elements were not
  recorded).
- **Items** = files + folders (13 files + 1 folder = 14).
- A single file gives one bar (`0 %`), the counter `0 / 1` and [Pause] [Cancel] [Background].
- Clicking a count switches it to the **remaining** value, shown with a leading minus sign.
- Hovering over a shortened name shows the full name.
- The second (total) bar needs the pre-count (`CountMarked`). `ShowProgressBarSpeed=1` shows the transfer speed inside
  the bar; `NewStyleProgress` chooses the system progress bar (1, default on XP and later), TC's own (0), or an
  unsegmented system bar (2).
- **Background** moves the running job into a background thread (§5.1).

### 3.2 Processing order

Items are processed in name order, case-insensitive. Copying the folder `docs` handled `A very long…`, `config.ini`,
`data.csv`, `multi.dot…`, `no_extension`, `notes.md`, `readme.html`, then `report_01`, which was the first conflict
(counter `7 / 14`). Inside subfolders the order follows `SubdirCopyOrder` (§2.10). Observed overwrite conflicts were
asked in this processing order.

### 3.3 Job sequence

1. OK in the dialog (or F2 Queue, §5) creates the job.
2. Pre-count of the folder contents (`CountMarked`) and free-space check (`SizeCheck`).
3. Esc held down → the Esc box (§1.4); nothing is done, selection kept.
4. Target path denied → "The given target path … is invalid!" (§1.5); the dialog closes, nothing is copied.
5. Missing target folders are created silently, several levels at once.
6. The progress window opens.
7. Target folder = source folder → "You cannot copy a file to itself!" [OK] (information box); nothing is copied.
8. For each item, in processing order:
   - the target exists → the overwrite rules (§4); a read-only, hidden or system target may ask again (§4.8);
   - access denied → the error box with Skip / Retry / Abort / Skip all / Rename / As Administrator / All as
     Administrator (§1.5);
   - copy the data with the chosen method (§2.9); verify if _Verify_ is on; progress update.
9. When done: the operation is written to the file-operation log if that is enabled (off by default; 13 › Operation ›
   Log file); the configured sound plays if the job took longer than the threshold (`SoundDelay`, default −10 = off; 13
   › Custom sounds); processed items are deselected; the panels are re-read.

The relative order of steps 2–5 was not recorded.

### 3.4 State after a copy

- The source selection is removed (excluded files of a filtered copy stay selected, §2.5).
- A folder size computed for the dialog stays in the Size column.
- The target folder's date is updated (it changed).
- Copied **files** keep their last-modified time. Copied **folders** show the time of the copy (`CopyDirTimeStamp=0`).
- Attributes are copied: a read-only source arrived as `ra--`.
- Comments are not copied with the default settings (§11.3).

_Basis: observed under Wine and on Windows 11; help: proc_copy, inisettings1 (`CountMarked`, `SizeCheck`, `SoundDelay`,
`NewStyleProgress`)._

## 4. Name collisions: the Overwrite dialog

### 4.1 When it appears

```text
on name collision(src, dst):
  if method == ExplorerCopy: Explorer decides (no TC options, no comments)
  mode = sticky "… all" choice made earlier in this job, else the Options>> default
  if mode == Ask:
      if [Confirmation] OverwriteFiles == 1: show the Overwrite dialog
      else: overwrite                                       (unverified)
  apply mode (§4.3)
  if dst will be overwritten:
      dst read-only    and OverwriteReadonly == 1 → ask again (§4.8)
      dst hidden/system and OverwriteHidSys  == 1 → ask again (§4.8)
      (both skipped when Options>> "Overwrite/Delete read only/hidden/system" is on)
```

- _Overwrite all_ still triggers the separate read-only and hidden/system questions.
- `OverwriteHidSysNotReadonly=0`: no extra question for hidden/system files that are not also read-only (standard copy
  method only).
- In a background job the dialog appears next to the job window (§5.2).

### 4.2 Dialog

Title "Total Commander", modal over the progress window:

```text
┌ Overwrite: ──────────────────────────────────────┐
│ c:\tc-sandbox\B\docs\report_01.txt               │
│      385 bytes, 01/01/2026 19:00:00         [✗]  │   red ✗ = the file that will be replaced
└──────────────────────────────────────────────────┘
                         ⇧                             orange arrow
┌ With file: ──────────────────────────────────────┐
│ c:\tc-sandbox\A\docs\report_01.txt               │
│      385 bytes, 01/01/2026 19:00:00         [✓]  │   green ✓ = the file being copied
└──────────────────────────────────────────────────┘
[ ] Thumbnails   [ ] Custom fields  [+]
[ Overwrite ] [ Overwrite all ]        [ Skip     ]
[ Cancel    ] [ Overwrite all older ]  [ Skip all ]
[ Rename    ] [ Append ]               [ More Options >> ]
```

- **Overwrite:** the target's details; **With file:** the source's. Sizes are exact (`385 bytes`); date and time are
  local, with seconds. `VersionInOverwrite=1` adds the file version information (set 0 on slow networks).
- **Overwrite** is the default button and has the focus.
- Accelerators: `&Overwrite`, `Overwrite a&ll`, `&Skip`, `&Cancel`, `Overwrite all ol&der`, `S&kip all`, `&Rename`,
  `A&ppend`, `More Options &>>`.
- **More Options >>** opens a popup menu below the button:

```text
Compare
Rename existing target file
Auto-rename &copied
Auto-rename tar&get files
Rename older target files, skip newer
────────
Overwrite all older and of the same age
Copy all &larger files (overwrite smaller)
Copy all s&maller files (overwrite larger)
```

### 4.3 Choices

| Choice                                          | Scope           | Rule                                                                                                                                                                                                                                                                                                              |
| ----------------------------------------------- | --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Overwrite**                                   | this file       | Replace the target                                                                                                                                                                                                                                                                                                |
| **Overwrite all**                               | rest of the job | Replace every colliding target (attribute prompts still apply)                                                                                                                                                                                                                                                    |
| **Skip**                                        | this file       | Keep the target, go on with the next file (observed: next conflict, counter `8 / 14`)                                                                                                                                                                                                                             |
| **Skip all**                                    | rest of the job | Skip every file that already exists                                                                                                                                                                                                                                                                               |
| **Cancel**                                      | job             | Abort the whole operation                                                                                                                                                                                                                                                                                         |
| **Overwrite all older**                         | rest of the job | Copy only when the source is **newer**. The internal **version resource** (EXE, DLL, …) is compared first, the last-modified time only when there is none. Observed: an older target was overwritten, a newer (and larger) one kept **silently**.                                                                 |
| **Rename**                                      | this file       | Ask for a new name for the copied file                                                                                                                                                                                                                                                                            |
| **Append**                                      | this file       | Append the source to the end of the target (§2.13)                                                                                                                                                                                                                                                                |
| _More ›_ **Compare**                            | —               | Compare the two files by content; no decision is taken. For identical files only a box titled "Compare contents" appears: "The two files have the same content!", a source-path line and a target-path line, [OK]; then the Overwrite dialog returns. Otherwise the compare tool opens (09 › Compare by content). |
| … **Rename existing target file**               | this file       | Ask for a new name for the target, rename it, then copy                                                                                                                                                                                                                                                           |
| … **Auto-rename copied**                        | rest of the job | The **copied** file gets a numbered name (§4.5)                                                                                                                                                                                                                                                                   |
| … **Auto-rename target files**                  | rest of the job | The **existing** target gets a numbered name first, then the source is copied                                                                                                                                                                                                                                     |
| … **Rename older target files, skip newer**     | rest of the job | Source older → skip. Source newer → auto-rename the target, then copy. Equal age is not specified.                                                                                                                                                                                                                |
| … **Overwrite all older and of the same age**   | rest of the job | Copy when the source is newer or of the same age                                                                                                                                                                                                                                                                  |
| … **Copy all larger files (overwrite smaller)** | rest of the job | Copy only when size(source) > size(target)                                                                                                                                                                                                                                                                        |
| … **Copy all smaller files (overwrite larger)** | rest of the job | Copy only when size(source) < size(target)                                                                                                                                                                                                                                                                        |

### 4.4 Default overwrite mode

The Options >> list presets the same rules for the whole job. In `CopyOverwriteDefault` numbering (default 1):

1. Ask user
2. Overwrite all
3. Skip all
4. Overwrite all older
5. Auto-rename copied
6. Auto-rename target files
7. Copy all larger files (overwrite smaller)
8. Copy all smaller files (overwrite larger)
9. Rename older target files, skip newer

The help documents only 1–8; the 9th entry exists in 11.58. _Overwrite all older and of the same age_ exists only in the
dialog's menu. `CopyOverwriteDefault=0` behaves like 1 but does not reset the confirmation options when files are added
to the background manager (§5.6).

### 4.5 Auto-rename names

`AutoRenameMode` (default **3**, also used by the Multi-Rename Tool) is a sum of flags:

| Flag | Meaning                                                                        |
| ---- | ------------------------------------------------------------------------------ |
| 1    | A space before the number: `name (2).txt`                                      |
| 2    | Start at (2), not (1)                                                          |
| 4    | Always append a new number, instead of increasing a number already in the name |

The default gives `name (2).ext`, `name (3).ext`, …; observed: `report_01 (2).txt`. (The help's base form is
`filename(1).ext`.)

### 4.6 Thumbnails and custom fields

- **[x] Thumbnails** (`ThumbsInDlg`) grows the dialog **upward**: each group gets a preview box at the right, about
  78×78 px at 96 DPI (depends on DPI; see A › Values that depend on DPI and fonts), taken from the thumbnail cache; text
  files show a miniature of their text. The ✗/✓ marker moves to the preview's bottom-right corner. The thumbnails/icons
  have the normal shell context menu.
- **[x] Custom fields** (`CustomFieldsInDlg`) shows extra fields per file type; with none defined nothing changes.
- **`[+]`** opens "Custom fields by file type": "File types (sort by drag&drop, edit with `<spacebar>`):", a list,
  [Add...] [Edit...] [Delete] [OK] [Cancel]. **Add...** opens "Specify file type": "Specify file type, e.g. *.txt, or
  RegEx with leading '<', like <(a|b)" (combo), "Or select predefined selection type:" (list), [Define...] [OK]
  [Cancel]. Fields may come from content plugins (15 › Content plugins in use); they are stored in
  `[OverwriteCustomField]`.

### 4.7 Keys

| Key                   | Action                                                                          |
| --------------------- | ------------------------------------------------------------------------------- |
| Alt+underlined letter | The button                                                                      |
| F3 / Shift+F3         | View the target (upper) / source (lower) file in Lister                         |
| Alt+F3 / Alt+Shift+F3 | The same without plugins                                                        |
| Ctrl+F3               | Compare the two files by content                                                |
| Ctrl+Shift+F3         | Use the internal compare tool even when an external one is set (`Comparetool=`) |

### 4.8 Read-only, hidden and system targets

After **Overwrite** on a read-only target (title not recorded):

```text
The file c:\…\dir2\ro.txt
is READ ONLY!
Do you want to overwrite it anyway?
[ Overwrite ] [ All ] [ Skip ] [ Cancel ]
```

A hidden or system target asks in the same way when `OverwriteHidSys=1` (overwrite wording not recorded; the delete
variant is in §9.2). Configuration › Misc. › _Get confirmation before_ (13 › Misc.) › _Overwriting/Deleting read-only
files_ (`OverwriteReadonly`) and _Overwriting/Deleting hidden/system files_ (`OverwriteHidSys`) switch these questions;
both are on by default.

_Basis: observed under Wine and on Windows 11; help: dlg_overwrite, proc_copy, dlg_configconfirmation, inisettings1–3._

## 5. Background operations

### 5.1 Routes into the background

| Route                                                                 | Behaviour                                                                                                                                                                                                                                            |
| --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Background** button in a progress window                            | Moves the running job into a background thread. Works for copy, delete, pack/unpack of ZIP, TAR, RAR and 7Z, external packers and some packer plugins. A background job can be brought back to the foreground only while no other TC dialog is open. |
| **F2 Queue** in the Copy/Move dialog                                  | Appends the job to the **last opened** Background Transfer Manager, opening one if none is open. A sequential queue is faster than parallel background copies of big files.                                                                          |
| `AlwaysCopyInBackground`                                              | 1 = always copy in the background; 2 = always through the transfer manager                                                                                                                                                                           |
| `AlwaysPackInBackground` / `AlwaysUnpackInBackground`                 | 1 = ZIP only; 2 = ZIP and external packers; 3 = like 2, external packers minimised (08 › Pack, 08 › Unpack)                                                                                                                                          |
| _Download in background (separate thread)_ in the FTP download dialog | Opens a **separate** manager that closes itself when done (11 › Background transfers)                                                                                                                                                                |
| Copy to several target folders (§2.8)                                 | Runs through the transfer manager                                                                                                                                                                                                                    |

After a background job the panels may not show the changes; the help says F2 or Ctrl+R may be needed. After a queued
copy the panels were re-read when the job ended.

### 5.2 Background Transfer Manager

Commands › Background Transfer Manager... (`cm_OpenTransferManager`, 559) opens it empty: title "Total Commander",
status line `-`, bars `0%` and `?`, an empty list. F2 Queue opens it with the job running:

```text
┌ photos (Copy) ───────────────────────────────────────────────┐   title "<first item> (Copy)"; "(READY)" when idle
│ Copy:                                                        │   status line
│ [                                              ]  0%         │   current file
│ [                                              ]  ?          │   total ("?" while unknown)
│ ┌──────────────────────────────────────────────────────────┐ │
│ │copy:c:\tc-sandbox\A\photos -> c:\tc-sandbox\B\photos     │ │   job list, active job first
│ │copy:c:\tc-sandbox\A\docs -> c:\tc-sandbox\B\docs         │ │
│ └──────────────────────────────────────────────────────────┘ │
│ [+] [-] [ Pause ]  [ ] Speed limit [5.0] kB/s                │   Pause ⇄ Start
└──────────────────────────────────────────────────────────────┘
```

- F2 Queue **starts the job at once** (not paused).
- The list holds one `copy:<source> -> <target>` line per job. A single job was also listed with a second line
  `copyflags:0` (Wine session).
- The manager processes **one job at a time**, top to bottom.
- A name collision shows the normal Overwrite dialog (§4), docked **under** the manager window.
- When everything is done, both bars are reset, the title shows "(READY)" (full title text not recorded) and the window
  **stays open** (the session difference is in A › Defaults that differed between the sessions).
- Position: `RememberTransferManagerPos=0` (default) opens it at the top of the screen with a varying left position; 1
  remembers position and size (set through the system menu).

### 5.3 Controls

| Element                      | Behaviour                                                                                                                                                                      |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Progress bar 1               | The current file                                                                                                                                                               |
| Progress bar 2               | Overall progress, when known (not e.g. for folder downloads from FTP)                                                                                                          |
| List                         | Queued jobs, the active one first. **Reorder by drag & drop while paused.**                                                                                                    |
| `+` (or Num + in the window) | Menu to add jobs (§5.4)                                                                                                                                                        |
| `-`                          | First (active) item selected: offer to **abort the current transfer and go on with the next**. Other items selected: **remove** them. The active job itself cannot be removed. |
| Pause / Start                | Pause suspends the active transfer; the button then reads **Start**. Jobs added while paused are **appended** and run one after the other after Start.                         |
| Speed limit                  | Throttles uploads, downloads **and** copies. `SpeedLimit` keeps the last value (5.0 KB/s); `SpeedLimitEnabled=1` activates the limit as soon as the manager opens (default 0). |
| Ctrl+V / Shift+Insert        | Paste an HTTP URL and download it **at once** into the active panel's current folder                                                                                           |
| Info line                    | `BackgroundSpeed` (default 2): 0 = the name, 1 = the speed, 2 = both alternating                                                                                               |

### 5.4 Adding jobs

The `[+]` menu can contain:

| Item                               | When                                                                           | Effect                                                                                                                                             |
| ---------------------------------- | ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Add URL to download                | always                                                                         | Asks for a URL such as `http://www.server.com/file.zip`. The pseudo-entry `sleep:<ms>` inserts a pause (`sleep:10000` waits 10 s).                 |
| Add selected items for downloading | only while an FTP panel is connected and items are selected                    | Downloads them in the background (11 › Background transfers)                                                                                       |
| Add selected items for copying     | —                                                                              | Copy (disk → disk) the selected items                                                                                                              |
| Add selected items for moving      | —                                                                              | Move (disk → disk) the selected items                                                                                                              |
| Edit list file                     | after _FTP download from list_ was used (11 › Net › FTP Download From List...) | Edit the list file the manager reads. Lines appended to its end while it runs are queued automatically. The file must be ANSI or UTF-8 with a BOM. |

Recorded with local panels and no list in use, the menu held _Add selected items for copying_ · _Add selected items for
moving_ · _Add URL to download_.

### 5.5 Pre-count

`CountMarkedBackground` (= `CountMarked` when unset) counts the files of a queued job in advance for the total bar;
until then the total shows `?`.

### 5.6 Overwrite memory

How long a sticky answer such as _Overwrite all_ lasts in the manager, `BackgroundCopyFlags` (default 1):

| Value | Behaviour                                                           |
| ----- | ------------------------------------------------------------------- |
| 0     | Stays valid for files added later (the TC ≤ 8.01 behaviour)         |
| 1     | Reset when the list reaches its end                                 |
| 2     | Reset every time files are added, so the user always confirms again |

With `CopyOverwriteDefault` unset or 1, the confirmation options are taken from the expanded copy dialog each time files
are added; with 0 they are not reset.

_Basis: observed on Windows 11 (real queue) and under Wine (single job); help: options_background_transfer_manager,
proc_copy, proc_delete, inisettings1–2._

## 6. Rename and move (F6, Shift+F6)

### 6.1 F6 dialog

`cm_RenMov` (906); `cm_MoveOnly` (1005) is the F6 move, `cm_RenameOnly` (1002) the Shift+F6 rename (17 › Command
catalogue).

- Identical to the Copy dialog (§2.2) except for the heading `Rename/Move N file(s) to`: same target field, counter
  strip, filter, NTFS-permission and Verify boxes, Tree, F2 Queue and _Advanced options_.
- F6 pressed again selects only the name, a third time also the extension.
- **Empty target folder** = the source folder, so the items are renamed in place. **No file mask** = names kept.
  Wildcards follow §2.4.
- Right-click on OK or F2 Queue copies instead of moving.
- With _copy+paste via Explorer_ (§2.9) a reduced OK/Cancel dialog is shown.
- Moving into an archive packs and then deletes the source (08 › Pack).
- `MoveToDirWarn=1` (default): F6 and Shift+F6 warn when the target given for a file is the name of an existing folder
  (text not recorded).
- Moving a folder with one subfolder showed the counter `15 b  1  2` (§1.1). After the move the cursor goes to the next
  item.

### 6.2 In-place rename (Shift+F6 on one item)

```text
│ [name.ext                            ][✓] │   edit box over the Name+Ext columns;
                                               the ✓ (confirm) button sits over the Size column
```

| Step                            | Effect                                                                                                                      |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| 1st Shift+F6                    | The **whole** name including the extension is selected (`RenameSelOnlyName=0`, default; 1 = name only). Typing replaces it. |
| Shift+F6 again                  | Toggles to the name part only (without `.txt`), and back                                                                    |
| Enter or ✓                      | Renames. **Enter is required**; the list re-sorts and the cursor follows the renamed item.                                  |
| Esc, or a click outside the box | Cancels                                                                                                                     |
| ↑ / ↓                           | Jump to the previous / next file; the current file is renamed first if its name was edited (`RenameUpDown=1`)               |
| Ctrl+← / Ctrl+→                 | Jump by word in the box                                                                                                     |

- Two slow clicks on a name also start in-place rename (`InplaceRename=1`; 0 disables).
- `InplaceOkButton`: 1 = ✓ on the right (default), 2 = on the left, 0 = none.
- Renaming sets the archive attribute (`SetArchiveBitOnRename=1`).
- Renaming a `.zip` to `.exe` makes TC ask whether to build a self-extracting ZIP; **Yes** converts the file (text not
  recorded).
- Inside a **ZIP**, Shift+F6 renames a single file or folder; otherwise renaming inside archives is unavailable.

### 6.3 Shift+F6 with several items

A dialog takes a wildcard mask (§2.4), with the option **Rename each file separately**, which asks for each new name
(layout not recorded). For rule-based renaming use the Multi-Rename Tool (Ctrl+M, 09 › Multi-Rename Tool).

### 6.4 Name conflicts during rename or move

Renaming onto an existing name opens a **"Rename/Move:"** progress window (with From/To lines) and then the Overwrite
dialog (§4) **without the Append button**:

```text
[ Overwrite ] [ Overwrite all ]        [ Skip     ]
[ Cancel    ] [ Overwrite all older ]  [ Skip all ]
[ Rename    ] [ More Options >> ]
```

The _More Options >>_ menu is the same as for copying; _Auto-rename copied_ produced `report_01 (2).txt`.

### 6.5 Permissions when moving

`XPMoveMethod` applies to moves within one drive (default 1 on XP and later, 0 otherwise):

| Value | Behaviour                                                                            |
| ----- | ------------------------------------------------------------------------------------ |
| 0     | Keep the file permissions                                                            |
| 1     | Use the target folder's permissions                                                  |
| 2     | Like 1; moved folders also re-apply the target permissions to everything inside them |

### 6.6 Moves as administrator

`XPMoveMethodAdmin` (default 1) applies the same choice to moves done through `tcmadmin.exe` (§1.5).

_Basis: observed under Wine; help: proc_renmov, proc_copy, frequentlyaskedquestions, inisettings1–3._

## 7. New folder (F7, Shift+F7)

### 7.1 Dialog

F7 (`cm_MkDir`, 907) creates the folder in the source panel; Shift+F7 (`cm_MkDirOther`, 911) in the target panel. Title
"Total Commander":

```text
New folder (directory)
[dir3                                        ▾] [±]
                              [  OK  ] [ Cancel ]
```

- The combo is pre-filled with the name of the item under the cursor, fully selected, so similar names are easy to type.
  On `[..]` it is empty.
- History: `[MkDirHistory]`, up to `MaxItemsInComboBox` entries (20, max 500).
- `NewFolderOverPanel=1` (default) places the dialog over the panel where the folder is created; 0 centres it over TC.

### 7.2 Names

- **Nested:** `a\b\c` creates every missing level.
- **Several at once:** `dir1|dir2|dir3`, or absolute paths `c:\dir1|c:\dir2|c:\dir3`; each part may be nested. `p|q\s`
  created `p`, `q` and `q\s`.
- **Placeholders:** when the text starts with `<`, the Multi-Rename placeholders apply (18 › Rename and new-folder
  placeholders), e.g. `<[Y]-[M]-[D] downloads` → `2017-09-22 downloads`, `<Copy of [N]` → `Copy of <name under cursor>`.
  Date/time placeholders use the moment **the dialog was opened**; the Multi-Rename modifiers `[T1]`…`[T4]` change that.
  `[F]` / `[f]` (title case) leave an alphanumeric `[C]` value unchanged.

### 7.3 Counter ranges and optional digit

- A range `<from-to>` must be the **very first** thing in the field, with `[C]` in the name. `dir<1-3>[C]` is not a
  range; it is taken as a literal name.
- While a valid range is typed, a **two-line live preview** under the field shows the first and the last name,
  zero-padded to the width of the end value:

```text
New folder (directory)
[<1-10>[C]                                   ▾] [±]
01 ...                                              ← first name
10                                                  ← last name
```

- `[C:n]` pads to n digits. `["prefix"C"postfix"]` adds text around the number, and the **first** item of the range then
  has no index at all.
- `[C]` **without** a range (file system only, not archives or FTP) is an _optional digit_: TC creates the first name
  that does not exist yet.

| Input                        | Preview             | Creates                                                         |
| ---------------------------- | ------------------- | --------------------------------------------------------------- |
| `<1-10>[C]`                  | `01 ...` / `10`     | `01` … `10` as previewed (not run; the help writes `1, 2 … 10`) |
| `<1-3>[C]`                   | `1 ...` / `3`       | `1` … `3`                                                       |
| `<1-3>dir[C]`                | `dir1 ...` / `dir3` | `dir1`, `dir2`, `dir3`                                          |
| `<1-250>Project No [C:3]`    |                     | `Project No 001` … `Project No 250`                             |
| `<5-8>Example [C] folder`    |                     | `Example 5 folder` … `Example 8 folder`                         |
| `<1-30>[Y]-[M]-[C:2] photos` |                     | `2017-09-01 photos` … `2017-09-30 photos`                       |
| `<1-3>test[" ("C")"]`        |                     | `test`, `test (2)`, `test (3)`                                  |
| `<test[C]`                   |                     | the first free one of `test`, `test2`, `test3`, …               |
| `<test[" ("C")"]`            |                     | the first free one of `test`, `test (2)`, `test (3)`, …         |

### 7.4 Placeholder menu (`±`)

Two columns, code and meaning:

| Code           | Meaning                                                                                                              |
| -------------- | -------------------------------------------------------------------------------------------------------------------- |
| `[N]`          | Name                                                                                                                 |
| `<1-10>[C]`    | Counter                                                                                                              |
| `[YMD]`        | Date                                                                                                                 |
| `[hms]`        | Time                                                                                                                 |
| `[=?]`         | Plugins                                                                                                              |
| ────           |                                                                                                                      |
| `[P]`          | Parent folder                                                                                                        |
| `[G]`          | Grandparent folder                                                                                                   |
| `[A]`          | Name with extension                                                                                                  |
| `[E]`          | Extension                                                                                                            |
| `[d]`          | Date (country settings)                                                                                              |
| `[t]`          | Time (country settings)                                                                                              |
| `[S]`          | Size                                                                                                                 |
| `[U]`          | All characters after this position in uppercase                                                                      |
| `[L]`          | All characters after this position in lowercase                                                                      |
| `[F]`          | First letter of each word uppercase after this position                                                              |
| `[f]`          | First letter of each word uppercase after this position (English in Titles)                                          |
| `[n]`          | All characters after this position again as in original name                                                         |
| `[%USERNAME%]` | "User name: `<name>`" (any environment variable)                                                                     |
| `[[]`          | Square bracket: open                                                                                                 |
| `[]]`          | Square bracket: close                                                                                                |
| `[X]`          | Clipboard contents; the menu shows the current clipboard text as the label; absent while the clipboard holds no text |

### 7.5 Result and errors

- A range created all names, re-read the panel and put the cursor on the **last** folder created (`dir3`). The
  single-folder case was not recorded.
- `p|q\s` created the folders, but the panel was **not** re-read until Ctrl+R.
- In archives only ZIP, RAR and TAR allow new folders. A failure on the file system (XP and newer) offers "As
  Administrator" (§1.5).
- `InheritCaseSensitiveDir` (default 1): whether a new folder inherits the "case-sensitive names" flag of its parent: 0
  = never, 1 = only when no admin rights are needed, 2 = always.

_Basis: observed under Wine; help: proc_mkdir, inisettings1–3._

## 8. New file (Shift+F4)

Shift+F4 (`cm_EditNewFile`, 2931) asks for a name, creates the file and opens it in the editor. The whole flow (name
history `[NewFileHistory]`, `EditNewName=`, several names with `|` or quotes, placeholders, counter ranges and the
optional-digit `[C]`, the temp-file round trip in archives, on FTP and in file-system plugins) is described in 10 › New
text file (Shift+F4). Its name rules are the same as for new folders (§7.2–7.3); where it works is in §1.2. Other file
types are created with **New ›** in the context menu of the panel background or the path (05 › Path bar (current
directory)).

_Basis: help only (proc_editnew)._

## 9. Delete (F8, Del, Shift+F8)

### 9.1 Recycle bin or direct deletion

| _F8/Del deletes to recycle bin (Shift=directly)_ (`UseTrash`) | F8 / Del / drop on the F8 button         | Shift+F8 / Shift+Del |
| ------------------------------------------------------------- | ---------------------------------------- | -------------------- |
| on (default)                                                  | To the recycle bin, if the drive has one | Directly             |
| off                                                           | Directly                                 | To the recycle bin   |

- `cm_Delete` (908). Deleting inside an archive always deletes directly, through the packer (08 › Operations inside an
  open archive).
- _Use Explorer delete method (faster, cannot handle comments)_ (`Win95Delete`) takes the choice away from TC, so the
  recycle-bin option is unavailable; this method does not keep file comments in step.
- Whether a drive has a recycle bin and how large it may grow are Windows settings.
- The F8 button's context menu is the Recycle Bin's menu. Dropping files on the F8 button deletes them, after an extra
  question when Misc › _Drag&Drop to the 'F8 Delete' button_ (`MouseDelete`) is on (05 › F8 Delete button).
- Cached thumbnails are deleted with their files (`ThumbsCopyDel=1`).

### 9.2 Questions

**To the recycle bin** (F8 on Windows 11, default settings):

```text
Total Commander
(?)  Do you really want to move the selected file
     .hidden_dot.txt to the recycle bin?
            [ Yes ]  [ No ]  [ Cancel ]
```

**Direct deletion** (Shift+F8):

```text
Permanently delete
(?)  Do you really want to delete the selected file
     report_01 (2).txt?
            [ Yes ]  [ No ]  [ Cancel ]
```

- For a folder: "Do you really want to delete the selected directory q?" (on one line for a short name).
- For several items the text names the count of selected files/directories (exact wording not recorded).
- The item is drawn red (selected) while the question is shown. **Cancel** or **No** leaves everything unchanged and
  keeps the selection.

**Non-empty folder** (after Yes, over a progress window "Deleting:" / "Deleting:`<path>`" with one bar and [Pause] …
[Background]), while Misc › _Deleting non-empty directories_ (`deleteDirs`) is on:

```text
The directory c:\tc-sandbox\work\q is not empty!
Do you want to delete it with all its files and subdirectories?
[ Delete ] [ All ] [ Skip ] [ Cancel ]
```

**Read-only file**, while _Overwriting/Deleting read-only files_ (`OverwriteReadonly`) is on:

```text
Delete:
File c:\tc-sandbox\work\ro.txt
is READ ONLY!
Delete anyway?
[ Delete ] [ All ] [ Skip ] [ Cancel ]
```

**Hidden or system file**, while _Overwriting/Deleting hidden/system files_ (`OverwriteHidSys`) is on (this protects
e.g. the swap file):

```text
Delete:
File c:\tc-sandbox\A\hidden.txt
has either the attribute HIDDEN or SYSTEM!
Delete anyway?
[ Delete ] [ All ] [ Skip ] [ Cancel ]
```

### 9.3 Flow

```text
confirm "delete …?"                                (always; §9.2)
if recycling with the Vista+ method (§9.4):
    move whole items to the bin; NO read-only / hidden / system / non-empty questions
else for each item (progress window "Deleting:", Background button available):
    folder not empty and deleteDirs=1  → ask for THIS folder (everything inside goes)
    read-only and OverwriteReadonly=1  → ask again
    hidden/system and OverwriteHidSys=1 → ask again
    delete; the Cancel button works at any time
    failure (XP … 11)                  → offer "As Administrator" (§1.5)
drop on the F8 button: an extra question first if MouseDelete=1
```

- Recycling one small file on Windows 11 ran **silently**, with no progress window, and a **read-only** file was
  recycled **without** the read-only question.
- **Skip** on the read-only question kept the file and cleared the selection.
- After a deletion the cursor goes to the **next** item, or to the **previous** one when the last item of the list was
  deleted.
- The folder count for the progress bars comes from the pre-count (_before copying/deleting_, `CountMarked`).

### 9.4 Delete method keys

| Key           | Default | Effect                                                                                                                                                                                                                                                                          |
| ------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `UseTrash`    | 1       | §9.1                                                                                                                                                                                                                                                                            |
| `Win95Delete` | −1      | 0 = TC's own delete, which honours all options; 1 = Explorer's method; −1 = Explorer's method only while CleanSweep runs, otherwise TC's own                                                                                                                                    |
| `VistaDelete` | −1      | 1 = the Vista+ recycle method: whole folders go to the bin and there are **no** warnings for read-only, hidden, system or non-empty items; 0 = the old per-file method (slow); −1 = the new method if available, with TC's own confirmation shown when Explorer's is turned off |
| `DeleteDelay` | 0       | Milliseconds to wait after each recycle-bin delete (a workaround for CleanSweep crashes)                                                                                                                                                                                        |

### 9.5 When no recycle bin is used

When the drive has no recycle bin, plain F8 asks the direct-deletion question ("Do you really want to delete the
selected directory `<name>`?", title not recorded; observed only on a host without a recycle bin, A › Artefacts not to
copy). Whenever deletion goes to the recycle bin, the recycle-bin wording of §9.2 is used.

### 9.6 Hidden and system files

Hidden and system files are operands only while the panel shows them (Configuration › Display, or `cm_SwitchHidSys`).
Their display (red `!` overlay, `--h-` / `---s` in the Attr column, footer counts) and the example listing of `C:\` are
in 03 › Hidden and system items. Deleting or overwriting them asks again while _Overwriting/Deleting hidden/system
files_ is on (§9.2, §4.8).

_Basis: observed on Windows 11 (recycle bin, hidden/system) and under Wine (direct deletion, non-empty folder,
read-only); help: proc_delete, dlg_configcopydelete, dlg_configconfirmation, drag_drop, local_menus, inisettings1–3._

## 10. Change attributes

### 10.1 Dialog

Files › Change Attributes... (`cm_SetAttrib`, 502), also `OPENATTRIBUTES` (§10.6). Title `Change attributes: <name>` for
one item, `Change attributes: <count>` for several (`Change attributes: 5`). The sketch shows the several-items state:

```text
[ ] Recurse subdirectories
┌ Change attributes ────────────────────────────┐
│ [■] a  Archive                                │
│ [■] r  Read only                              │
│ [■] h  Hidden                                 │
│ [■] s  System                                 │
│ (gray = unchanged, checked = set attribute)   │
└───────────────────────────────────────────────┘
┌───────────────────────────────────────────────┐
│ [ ] Change date/time:            [ Current ]  │
│ Date: [MM/dd/yyyy]   Time: [HH:mm:ss] [>>]    │
└───────────────────────────────────────────────┘
[ ] Change plugin attributes:   [F2 Load/save settings ▾]
┌───────────────────────────────────────────────┐
│ Plugin:  Property:      Value:                │
│ [tc ▾]   [comment ▾]    [__________] [>>] [+] │
│ [ More attributes ] [ Fewer attributes ]      │
└───────────────────────────────────────────────┘
┌ Load from file under cursor ──────────────────────────┐
│ [ From active panel (source) (1) ] [ From target (2) ] │
└───────────────────────────────────────────────────────┘
          [ OK ] [ Cancel ] [ Help ]
```

|                 | One item                                                        | Several items                               |
| --------------- | --------------------------------------------------------------- | ------------------------------------------- |
| Attribute boxes | The item's actual state (e.g. `a` ✓, `r` ✓)                     | All four in the grey third state            |
| Date / Time     | Pre-filled with the item's timestamp (`10/11/2026`, `09:58:52`) | Grey hint texts `MM/dd/yyyy` and `HH:mm:ss` |

**Operands:** the operand set. **Recurse subdirectories** also changes the files inside selected folders; without it
only the folders themselves change. Not available in archives; on FTP the UNIX dialog appears (§10.7).

**OK** applies the changes; the Attr column shows them at once (unticking `r` on `ro.txt` gave `-a--`). **Cancel**
changes nothing.

### 10.2 Attribute boxes

Tri-state, applied to every operand: **grey** = unchanged, **checked** = set, **unchecked** = cleared.

- **a** Archive: Windows sets it whenever a file changes; renaming in TC also sets it (`SetArchiveBitOnRename=1`).
- **r** Read only: TC can still delete or overwrite the file but asks first (§4.8, §9.2).
- **h** Hidden: not shown in a `dir` listing; TC shows such files only when configured to.
- **s** System: e.g. `pagefile.sys`, `swapfile.sys`; defragmenters do not move such files.

### 10.3 Date and time

- **Change date/time** must be ticked for the fields to apply. **Current** fills in the present date and time.
- **Date** uses the format shown by the letters. **Partial entry:** any letter a–z (no accents) is a placeholder that
  keeps that part: with the format `YYYY.MM.dd`, `YYYY.05.dd` or `aaaa.05.aa` changes only the month.
- **Time:** the seconds may be left out (they become 0); fractions up to 3 digits are allowed. **Partial entry:** the
  letters b–o and q–z (not `a` and `p`, which mean am/pm) with any separators: `hh:10:ss` and `xy.10.xy` both change
  only the minutes.
- **`>>`** opens the "Change date/time:" picker: a date combo with calendar `[10/11/2026 ▾]`, a time spin box
  `[10:00:24 ▲▼]`, [OK] [Cancel].

### 10.4 Plugin attributes

- Rows of Plugin / Property / Value; only **writable** properties are listed (content plugins, 15 › Content plugins in
  use). For `tc`: `comment`, `creationdate`, `creationtime`, `writedate`, `writetime`, `accessdate`, `accesstime`,
  `compressed`, `encrypted`, `sparse`.
- Adding the first row ticks _Change plugin attributes_ automatically. _More attributes_ / _Fewer attributes_ add or
  remove rows.
- `>>` is a value editor; `+` reads the value from another plugin field (e.g. sets the comment to the short name).
- **F2 Load/save settings** (also F2): `F2 Load/save settings` / `Save settings` / `Delete entry`, plus the saved
  presets. Presets are stored in `[attrplugin]`.

### 10.5 Load from file under cursor

| Button                         | Source of the values                                  | Restriction                                                            |
| ------------------------------ | ----------------------------------------------------- | ---------------------------------------------------------------------- |
| From active panel (source) (1) | The file under the cursor in the last active panel    | The standard a/r/h/s are loaded only when no plugin options are chosen |
| From target (2)                | The file under the cursor in the target panel (Alt+2) | Only when that cursor is not on `[..]`                                 |

### 10.6 `OPENATTRIBUTES`

`OPENATTRIBUTES <params>` opens the dialog pre-filled:

| Token                                              | Meaning                                                                                                     |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `=` (first)                                        | Apply immediately                                                                                           |
| `+a` / `-a`, `+r` / `-r`, `+h` / `-h`, `+s` / `-s` | Set / clear the attribute                                                                                   |
| `+f` / `-f`                                        | Apply to the files in folders (Recurse) or not                                                              |
| `+d<date>` / `+t<time>`                            | Fill the date / time field; the value ends at a space or at the end; an empty value is allowed              |
| `+c`                                               | Current date and time. `+c +t` changes **only the date** (`+t` with an empty value empties the time field). |
| `+L`, `+L1` (any case)                             | Load from the file under the cursor                                                                         |
| `+L2`                                              | Load from the file under the cursor in the other panel                                                      |
| `<Settings>` (last)                                | Load the saved plugin-options preset of that name                                                           |

### 10.7 Change UNIX attributes (FTP)

When the source panel is an FTP connection, the command opens _Change UNIX attributes_ instead (layout not recorded). TC
sends `SITE chmod xyz file.ext`, which only some UNIX servers support.

- Owner, Group and World each have **Read**, **Write** and **Execute**. World needs Read for a file to be web-readable;
  CGI scripts need Execute; on a folder, Execute allows entering it.
- **Set UID / Set GID** run the program with its owner's or group's rights. **Sticky** (e.g. `/tmp`): only the file
  owner, the folder owner or the admin may rename or delete.
- Tri-state boxes: **black check** = set, **grey check** = unchanged, **empty** = clear.
- The file list shows three octal digits (owner, group, world), each the sum 4 = r, 2 = w, 1 = x: `754` = owner `rwx`,
  group `r-x`, world `r--`.

_Basis: observed under Wine (dialog, single/several items, picker); help: options_setattr, dlg_attrib,
dialog_unix_attribs, inisettings2–3._

## 11. File comments (Ctrl+Z)

### 11.1 Dialog

Files › Edit Comment... (`cm_EditComment`, 2700) or Ctrl+Z, on the item under the cursor. On `[..]` it edits the comment
of the current folder itself. Title "File comment":

```text
Edit comment for:
sel.txt
┌──────────────────────────────────────────────▲┐
│                                              ││   multi-line edit box with a vertical scroll bar
└──────────────────────────────────────────────▼┘
[ ] Use OEM (DOS) font (disabled)    <n>   [ F2 OK ] [ Cancel ] [ Help ]
```

- `<n>` is a live character count; a line break (CRLF) counts 2.
- Limit: **4095** characters with `descript.ion`. Above **511** TC beeps and shows the count in **bold**, because other
  tools may not handle longer comments.
- **F2** (or _F2 OK_) saves; **Esc** cancels.
- _Use OEM (DOS) font_ shows the text in a DOS font, for `files.bbs` and ASCII art.
- Comments work only for normal files: not inside archives, on FTP or in plugins.
- Saving re-reads both panels (which also ends a "Comparison:" view, 09 › Compare directories and Mark newer). The other
  panel is not re-read when it shows the result of a search in an archive, a file-system plugin or an FTP connection
  (change log).

### 11.2 Storage

- Comments live in `descript.ion` or `files.bbs` in the file's folder, one line per file: the name, a space, the
  comment, CRLF; names with spaces are quoted (4DOS convention). Byte-level format: 19 › `descript.ion` and `files.bbs`.
- A new comment uses the **preferred** type (Configuration › Operation › _File comments_, preferred type default _Plain
  text+UTF16_, `CommentPreferredFormat=4`). If only a file of the other type exists, the comment is written there.
- Encoding: plain ANSI by default; UTF-16 or UTF-8 only when the name or the comment holds characters outside the
  current code page. `Selection list ü` on `sel.txt` was written as `sel.txt Selection list ü` + CRLF in cp1252 (`ü` =
  0xFC).
- **Multi-line** comments are converted to the file's format. In `descript.ion` the lines are joined with a literal
  `\n`, and the bytes `0x04 0xC2` (multi-line marker) precede the CRLF: `ro.txt first line\nsecond line` + `04 C2` +
  CRLF.
- A newly created `descript.ion` gets the **Hidden** attribute, so it is not listed while hidden files are off.

### 11.3 Comment settings

`CopyComments` (default 6) is a sum of flags:

| Flag | Meaning                                                                                     | UI (Operation › File comments)   |
| ---- | ------------------------------------------------------------------------------------------- | -------------------------------- |
| 1    | Default type `files.bbs`                                                                    | preferred type _files.bbs (DOS)_ |
| 2    | Default type `descript.ion` (wins over 1)                                                   | other preferred types            |
| 4    | Read both types                                                                             | _Read from both_ (on)            |
| 8    | Copy and move comments together with their files (the comment files themselves are skipped) | _Copy comments with files_ (off) |
| 16   | DOS charset for `descript.ion` (`files.bbs` is always DOS)                                  | _DOS charset_ (off)              |

- With the default, copying a commented file did **not** copy its comment: no `descript.ion` appeared in the target.
- The Explorer copy and Explorer delete methods (§2.9, §9.1) do not maintain comments.

### 11.4 Display

Show › Comments (Ctrl+Shift+F2) shows the comments in the panel (03 › View types › Comments): name and extension, then
the comment from the Size column on, multi-line comments on one line. With Display › _Win32-style tips with file
comments_, hovering over a name shows the comment. `OleComments` (default 1) also reads Explorer comments (NTFS streams,
Word documents).

_Basis: observed under Wine; help: dlg_edit_comment, edit_comment, dlg_configcopydelete, inisettings1; change log
(Ctrl+Z on `[..]`, 2022; other panel not re-read, 2023)._

## 12. Properties (Alt+Enter)

Files › Properties... (`cm_VersionInfo`, 510) or Alt+Enter opens the system **property sheet** of the item under the
cursor, the same as in Explorer. `cm_Properties` (1003, "Properties dialog") is also listed (17 › Command catalogue).

- On `[..]` it shows the properties of the current folder.
- The sheet belongs to Windows. On Windows 11 a file's sheet had the tabs **General / Digital Signatures / Security /
  Details / Previous Versions**. The _Details_ page shows the version information if the file has one.
- The _General_ tab (recorded for `win.ini`): name edit box; File type (_Configuration Settings_); Open with
  (_notepad.exe_) [Change...]; Location (`C:\windows`); Size (`34 bytes`); Created, Modified, Accessed in long date
  format ("Sunday, October 11, 2026 1:19:22 AM"); Attributes [ ] Read Only [ ] Hidden [x] Archive; [OK] [Cancel]
  [Apply].
- Current Windows versions also share and unshare folders from this sheet (11 › Share and unshare).

_Basis: observed on Windows 11 and under Wine; help: options_versioninfo; KEYBOARD.TXT._

## 13. Calculate occupied space (Ctrl+L)

Files › Calculate Occupied Space... (`cm_GetFileSpace`, 503) or Ctrl+L measures the selected files and folders with all
their subfolders, or the item under the cursor when nothing is selected. With 3 files selected it used the selection,
not the cursor item. Not available in archives.

```text
(i) Total space occupied:
    23,332,990 bytes in 101 file(s),
    in 14 directories
    (= 22,786k, 22M)

    Actual space used (considering cluster size)
    on source drive: 23,560,192 Bytes
    Required on target drive: 23,560,192 Bytes

    c:\ : 1,439,946,852 k of 7,811,085,600 k free
                                   [ OK ]
```

- **Total space occupied:** the raw bytes, files and folders.
- **Actual space used:** the sizes rounded up to the cluster size of the **source** drive and of the **target** drive
  (the space really needed there). The space of the directory entries themselves is not counted.
- The last line gives the free space of the source drive.
- For a single 23-byte file on NTFS the box read `23 bytes in 1 file(s)` with no folder line and no `(= …)` line;
  `on source drive: 4,096 Bytes`, `Required on target drive: 4,096 Bytes`, `c:\ : 231,586,400 k of 266,811,388 k free`.
- On a single file the box also shows its `Zone.Identifier` stream data (change log 2021). Other alternate streams
  (`notes.md:extra`) were not mentioned.
- A measured folder's size is written into the Size column and the folder is drawn as selected.

Other ways to size folders (Space on an unselected folder, Alt+Shift+Enter `cm_CountDirContent` for every folder of the
current folder, the pre-count before copy/delete, `Everythingforsize`) are in 03 › Counting rules.

_Basis: observed on Windows 11 (NTFS) and under Wine; help: options_memory, frequentlyaskedquestions, inisettings1;
change log._

## 14. File clipboard and name lists

### 14.1 Files on the clipboard

| Key    | Command                        | Behaviour                                                                                                                           |
| ------ | ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| Ctrl+C | `cm_CopyToClipboard` (2008)    | Put the operand files on the clipboard for copying. The selection stays and nothing visible happens.                                |
| Ctrl+X | `cm_CutToClipboard` (2007)     | The same, for moving                                                                                                                |
| Ctrl+V | `cm_PasteFromClipboard` (2009) | Paste into the current folder of the active panel; also _Paste_ in the context menu of the path (05 › Path bar (current directory)) |

- Ctrl+C and Ctrl+X run the shell's _Copy_ / _Cut_ verb of the context menu without showing it. `UseFastCtrlC=1`
  (default) loads the menu without shell extensions (very fast, no Explorer copy extensions); 0 loads the full menu
  (slower, allows copy extensions).
- A file-list format is placed; whether a plain-text format is placed as well was not recorded on Windows (A › Artefacts
  not to copy).
- **Ctrl+V** pastes at once with no TC dialog, and the panel is re-read.
- Pasting goes through the **system shell's** copy engine, so a name conflict shows the shell's own replace dialog, not
  TC's Overwrite dialog, and TC's copy options (overwrite modes, Verify, comments) do not apply. The dialog's look and
  wording are the platform's (A › Artefacts not to copy).

### 14.2 Names to the clipboard (Mark menu)

Each item is one line, with no header and no line break after the last line. Folders get a trailing `\`.

| Menu item                           | Command                             | Line format                                                                                                                    | Example                                                                                        |
| ----------------------------------- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| Copy Selected Names To Clipboard    | `cm_CopyNamesToClip` (2017)         | `name.ext`                                                                                                                     | `dir1\`, `ro.txt`                                                                              |
| Copy Names With Path To Clipboard   | `cm_CopyFullNamesToClip` (2018)     | full path                                                                                                                      | `c:\tc-sandbox\work\dir1\`, `c:\tc-sandbox\work\ro.txt`                                        |
| Copy To Clipboard With All Details  | `cm_CopyFileDetailsToClip` (2036)   | all shown columns: `name<TAB>size<TAB>date<TAB>attrs`, name and ext joined, size in raw bytes or `<DIR>`, date as in the panel | `dir1\<TAB><DIR><TAB>10/11/2026 09:58<TAB>----`, `ro.txt<TAB>15<TAB>10/11/2026 09:58<TAB>-a--` |
| Copy To Clipboard With Path+Details | `cm_CopyFpFileDetailsToClip` (2037) | the same, with the full path in the first field                                                                                | `c:\tc-sandbox\work\ro.txt<TAB>15<TAB>…`                                                       |

Further variants (UNC paths, with headers, path of each file) exist only as commands (17 › Command catalogue). Saving
and loading selections to files and from the clipboard: 03 › Selection files.

_Basis: observed under Wine; help: local_menus, options_mark, inisettings2; KEYBOARD.TXT._

## 15. State changes at a glance

| Operation                                 | Selection afterwards                                           | Cursor afterwards                                        | Panels                                                                  |
| ----------------------------------------- | -------------------------------------------------------------- | -------------------------------------------------------- | ----------------------------------------------------------------------- |
| Copy F5, job done                         | Source selection removed (filter-excluded files stay selected) | —                                                        | Re-read; target folder's new date shown; computed folder size kept      |
| Copy aborted by the Esc guard             | Kept                                                           | —                                                        | Unchanged                                                               |
| Copy into an access-denied folder         | —                                                              | —                                                        | "…is invalid!"; dialog closes; nothing copied                           |
| Copy into `C:\Program Files\`, Abort      | —                                                              | —                                                        | Job cancelled; nothing written                                          |
| F5 with / without _Copy NTFS permissions_ | —                                                              | —                                                        | Explicit ACE copied / not copied; alternate stream copied in both cases |
| F2 Queue                                  | —                                                              | —                                                        | Manager starts the job at once; re-read when the job ends               |
| F2 Queue while the manager is paused      | —                                                              | —                                                        | Job appended; runs after Start; "(READY)" when all are done             |
| Shift+F5                                  | —                                                              | On the new file (`CopyStayOnFile=0`)                     | New file listed                                                         |
| Ctrl+Shift+F5                             | —                                                              | —                                                        | `.lnk` created in the target panel's folder                             |
| Move F6                                   | —                                                              | Next item                                                | Re-read                                                                 |
| In-place rename                           | —                                                              | Follows the renamed item (list re-sorted)                | Re-read                                                                 |
| New folder, range `<1-3>dir[C]`           | —                                                              | On the last folder created                               | Re-read                                                                 |
| New folder `p\|q\s`                       | —                                                              | —                                                        | Not re-read until Ctrl+R                                                |
| Delete (one item)                         | —                                                              | Next item; the previous one if the last item was deleted | Re-read                                                                 |
| Delete, read-only file, Skip              | Cleared                                                        | —                                                        | —                                                                       |
| Delete question, Cancel                   | Kept                                                           | —                                                        | Unchanged                                                               |
| F8 on one small file (recycle bin)        | —                                                              | —                                                        | Moved silently, no progress window; read-only file without a question   |
| Shift+F8 on a hidden file                 | —                                                              | —                                                        | Question, "Deleting:" progress, HIDDEN-or-SYSTEM question               |
| Entering an access-denied folder, OK      | —                                                              | Panel stays where it was                                 | —                                                                       |
| Change attributes                         | —                                                              | —                                                        | Attr column updated at once                                             |
| Save a comment                            | —                                                              | —                                                        | Both panels re-read (ends a comparison view)                            |
| Ctrl+L                                    | Measured folder drawn selected                                 | —                                                        | Folder size written into the Size column                                |
| Ctrl+C / Ctrl+X                           | Kept                                                           | —                                                        | —                                                                       |
| Ctrl+V                                    | —                                                              | —                                                        | Re-read                                                                 |

_Basis: observed on Windows 11 and under Wine._
