# 08: Archives and file tools

This chapter describes how Total Commander 11.58 x64 opens archives as folders, which operations work inside them, and
the Pack, Unpack and Test functions with their options, engines and packer settings. It also covers the file tools in
the lower half of the Files menu: Split, Combine, Encode, Decode, Create checksum files and Verify checksums, including
the file formats they write and read. The Configuration pages for packers are laid out in chapter 13; this chapter gives
what their settings do.

**Related:** [07](07-file-operations.md) (operand rules, Overwrite dialog, progress window, Background Transfer
Manager), [03](03-file-panels.md) (column header, Quick View), [09](09-search-rename-sync-compare.md) (search in
archives, Synchronize with archives), [10](10-lister-and-viewing.md) (Lister, F3/F4 rules),
[13](13-configuration-dialog.md) (Packer, Zip packer, 7-Zip packer pages), [15](15-plugins.md) (packer plugins),
[17](17-internal-commands.md) (cm_ parameters), [19](19-settings-files-and-command-line.md) (`[Packer]` keys).

## 1. Format support matrix

### 1.1 Operations per format

| Format         | Ext.          | Browse as folder  | Internal unpack                                               | Create                                                                                   | Modify (add/delete)       | Add into a subfolder of the archive            | Encryption                | Multi-volume                                 | SFX                    | Test (CRC)              |
| -------------- | ------------- | ----------------- | ------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------- | ---------------------------------------------- | ------------------------- | -------------------------------------------- | ---------------------- | ----------------------- |
| ZIP            | .zip          | yes               | yes (Info-ZIP-derived unzip; libdeflate)                      | internal (libdeflate; old engine zlib), or external                                      | yes                       | yes (internal)                                 | ZIP 2.0, AES-128/192/256  | create and unpack                            | create (internal stub) | yes                     |
| 7-Zip          | .7z           | yes               | yes (`tc7z64.dll`)                                            | internal (`tc7z64.dll`) or external `7zg.exe`                                            | yes                       | yes, always through the **internal** 7z packer | AES, optionally names too | create (`-v`) and unpack                     | create (internal stub) | yes                     |
| TAR            | .tar          | yes               | yes                                                           | internal                                                                                 | yes                       | yes (internal)                                 | no                        | –                                            | –                      | **no** (TAR has no CRC) |
| GZ             | .gz           | yes               | yes (libdeflate)                                              | internal, one file per archive                                                           | **no**                    | –                                              | no                        | –                                            | –                      | yes                     |
| TGZ            | .tgz, .tar.gz | yes               | yes                                                           | internal (TAR inside GZ in one pass)                                                     | **no**                    | no (see §1.2)                                  | no                        | –                                            | –                      | yes                     |
| CAB            | .cab          | yes               | yes                                                           | **never**                                                                                | **no**                    | –                                              | –                         | –                                            | –                      | yes                     |
| RAR            | .rar          | yes               | yes (`UnRAR64.DLL`, falls back to `tc7z64.dll`)               | external `rar.exe` / `winrar.exe`                                                        | external                  | yes (external RAR)                             | external RAR              | external; multi-part RAR unpacked internally | external               | yes                     |
| ARJ            | .arj          | yes               | yes (internal un-ARJ, **no encrypted members**)               | external `arj32.exe`                                                                     | external                  | no                                             | external ARJ              | external (§4.8)                              | external               | yes                     |
| LHA/LZH        | .lzh          | yes               | yes (incl. `-lh6-`, `-lh7-`)                                  | external `lha32.exe`                                                                     | external                  | no                                             | –                         | –                                            | –                      | yes                     |
| ACE            | .ace          | 32-bit TC only    | `UnACEv2.DLL`, which has **no 64-bit version**, so not in x64 | external `winace.exe`                                                                    | external                  | no                                             | –                         | external                                     | external               | 32-bit TC only          |
| UC2            | .uc2          | yes               | external only                                                 | external `uc.exe`, only via the typed `uc2:` prefix; does **not** work on 64-bit Windows | external                  | yes (UC2)                                      | –                         | –                                            | –                      | –                       |
| ZSTD           | .zst          | yes               | yes                                                           | no                                                                                       | no                        | –                                              | –                         | –                                            | –                      | yes (unverified)        |
| Brotli         | .br           | yes               | yes                                                           | no                                                                                       | no                        | –                                              | –                         | –                                            | –                      | yes (unverified)        |
| BZIP2          | .bz2          | via packer plugin | plugin                                                        | plugin (single file)                                                                     | plugin                    | –                                              | –                         | –                                            | –                      | plugin                  |
| Packer plugins | any           | yes               | plugin                                                        | if the plugin can create                                                                 | if it can modify / delete | some plugins                                   | if it supports encryption | –                                            | some (e.g. SQX)        | plugin                  |

What each packer plugin can do is given by its capability flags (see 15 › Packer plugins). The flags that change
behaviour in this chapter: "can create" (1), "can modify" (2), "multiple files per archive" (4), "can delete" (8),
"options dialog" (16), "detects type by content" (64), "text search inside" (128), "open only with Ctrl+PgDn" (256),
"encryption" (512).

### 1.2 Notes on the matrix

- **Not modifiable at all:** GZ, TGZ and CAB. Files cannot be added to them, deleted from them, or re-packed into them
  after editing (§3).
- **Adding into a subfolder of an archive** works with internal ZIP and TAR, the internal 7z packer (used for this even
  when the internal 7z packer is switched off), external RAR and UC2, and capable packer plugins. One help topic also
  lists TGZ, which contradicts "TGZ cannot be modified"; treat TGZ as not supported.
- **Test column:** the help excludes only TAR. The other entries assume that every format with an internal unpacker can
  be tested.
- **Self-extracting input:** ZIP SFX, 7z SFX, WinRAR SFX and WinACE SFX files (`.exe`, `.com`) open as archives with
  **Ctrl+PgDn** (§2.1).
- **Size limit:** most external packers stop at **2 GB** per archive. The internal ZIP packer writes larger archives
  (ZIP64, WinZip/PKZIP-compatible), which not every unzipper can read. `[Packer] WarnTooBig=1` warns after packing when
  a ZIP or TAR is over 2 GB; its default is 0 on Windows 10 and later.
- **Compression methods the internal unzipper reads:** stored, Deflate, BZIP2, PPMd, LZMA, XZ (method 95), ZSTD and
  Brotli (used in XPI files).
- **Methods the internal ZIP packer writes:** store (rate 0), Deflate (rates 1–9), LZMA (rate 10, only with
  `[Packer] LzmaAllowed=1`; WinZip 12 or later is needed to unpack it).
- **Malformed ZIPs the unzipper accepts:** no CRC in the local header and none after the data (as written by ownCloud);
  UTF-8 names without the UTF-8 flag (as written by Dropbox; see `PreferUtf8ForZip`, §2.3).
- **Directory timestamps** are restored on unpack.
- **Long names:** most old external packers do not support long file names. The internal ZIP packer, Info-ZIP and
  current UC2, RAR, LHA and ACE do; the help recommends the internal ZIP packer.

### 1.3 Internal engines and their files

| Component         | File(s)                                                                           | Role                                                                                                              |
| ----------------- | --------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| New ZIP/GZ engine | modified libdeflate ("libdeflate/libdeflate64")                                   | Fast Deflate packing and unpacking for ZIP and GZ                                                                 |
| Old ZIP engine    | `wcmzip32.dll` (zlib by Jean-loup Gailly)                                         | Legacy Deflate compressor                                                                                         |
| Unzip             | Info-ZIP code by Mark Adler, translated to Pascal                                 | Internal unzipping (credited in the About box)                                                                    |
| LZMA/XZ in ZIP    | `tcmdlzma.dll` / `tclzma64.dll`                                                   | LZMA and XZ methods inside ZIP                                                                                    |
| 7-Zip             | `tc7z.dll` / `tc7z64.dll`                                                         | Internal 7z packing and unpacking; RAR fallback. May be replaced by a newer official `7z.dll` of the same bitness |
| RAR               | `UnRAR.DLL` / `UnRAR64.DLL`                                                       | Internal un-RAR; supports target names over 259 characters                                                        |
| ACE               | `UnACEv2.DLL`                                                                     | Internal un-ACE, 32-bit only                                                                                      |
| AES               | Dr Brian Gladman's AES code (as in WinZip; TC itself has no FIPS-197 certificate) | ZIP AES encryption                                                                                                |
| SHA3              | `tcsha64.dll`                                                                     | Faster SHA3 creation and verification                                                                             |
| ZIP SFX stub      | `sfxhead.sfx` (32-bit)                                                            | Self-extractor header                                                                                             |

_Basis: help only (packedfiles, dlg_pack, dlg_unpack, options_pack, dlg_configpack, dlg_internalzipconfig,
dlg_internal7zipconfig, plugins, aes_encryption_information, unzipsource, inisettings3 `[Packer]`, whats_new); x64
un-ACE greyed observed on screen._

## 2. Archives as folders

### 2.1 Opening an archive

```text
onEnter(file):                                 # Enter or double-click
  if file matches PreferOpenTypes:             # default: common Office-XML types such as *.docx
      open via the Windows association
  elif [Packer] ZIPlikeDirectory=1:            # "Treat archives like directories"
      if a packer plugin with flag 256 owns the extension:
          treat as a normal file (association); only Ctrl+PgDn opens it as an archive
      elif ext = 7z and 7zPreferPlugin=1 and plugin "7zip" or "Total7zip" installed:
          open with that plugin
      elif ext = zip and PluginOverrideZip=1 and a plugin is registered for zip:
          open with the plugin                 # PluginOverrideZip=0: internal unzip always wins
      else:
          open with the internal handler or the registered plugin
  else:
      launch the associated program; if there is none, TC opens the archive itself
```

| Trigger                                            | Effect                                                                                                              |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Enter / double-click                               | As above                                                                                                            |
| Shift+Enter on a ZIP                               | The opposite of the "Treat archives like directories" choice (browse ↔ associated program)                          |
| Ctrl+PgDn (`cm_GoToDir`)                           | Always try to open as an archive: unusual extensions, SFX `.exe`/`.com`                                             |
| Ctrl+Left / Ctrl+Right                             | Open in the **target** panel, governed by `[Configuration] CtrlArrowOpenArchive` (below)                            |
| Archive as panel path on the command line          | Opens the archive. With `/A` TC opens its parent folder with the cursor on the archive (19 › Command-line switches) |
| Archive inside a virtual folder (e.g. the Desktop) | Opens as well                                                                                                       |

`PreferOpenTypes` syntax: a leading `+` adds types to the built-in list (`+*.ext1 *.ext2`); without `+` the list is
replaced; types after a pipe symbol are always opened as archives (`*.docx *.xlsx | *.pptx`).

`CtrlArrowOpenArchive` (default **5** = 1 + 4); it does not affect search results fed to the listbox:

| Value | Meaning                                            |
| ----- | -------------------------------------------------- |
| `0`   | Never open                                         |
| `1`   | Open if Enter would open the archive as a folder   |
| `2`   | Always open, except when `ZIPlikeDirectory=0`      |
| `3`   | Always open                                        |
| `+4`  | Put the cursor on the file if it is not opened     |
| `+8`  | Respect `PreferOpenTypes` (only with base value 1) |

Without a matching extension, a packer plugin that detects archives by content (flag 64) can still claim a file.

### 2.2 The archive panel

- The path bar shows `<folder>\<archive>.<ext>\*.*`, e.g. `c:\tc-sandbox\work\dir1.zip\*.*`; inside subfolders
  `…\archive.ext\sub\*.*`.
- The Name column header reads **`[Auto] Name`**. `[Auto]` shows the file-name encoding in use (§2.3); after a manual
  choice it shows that encoding instead. This was seen under Wine and on Windows 11 (entering a plugin ZIP).
- Sizes are the **unpacked** sizes. The `[..]` entry carries the archive file's own date.
- The command-line prompt keeps showing the last real folder (e.g. `c:\tc-sandbox\work>`) while the panel is inside an
  archive.
- A left click on the Name header, including its `[Auto]` part, toggles the sort direction as usual. A **right click on
  `[Auto]`** opens the encoding menu (§2.3).
- The archive behaves like a read-mostly folder; §3 lists what is allowed.

### 2.3 File-name encoding

Right-clicking `[Auto]`, or `cm_ChangeArchiveEncoding` (2948), opens a two-column menu (observed):

| Left column                      | Right column                    |
| -------------------------------- | ------------------------------- |
| • Auto-detect (current)          | UTF-8                           |
| ANSI (local code page) (0)       | ASCII/DOS (local code page) (1) |
| MacOS (2)                        | DOS-USA (437)                   |
| Eastern Europe (1250)            | DOS (852)                       |
| Cyrillic Windows (1251)          | DOS (866)                       |
| Western Latin1 (1252)            | DOS (850)                       |
| Greek (1253)                     | DOS (737)                       |
| Turkish (1254)                   | DOS (857)                       |
| Hebrew (1255)                    | DOS (862)                       |
| Arabic (1256)                    | DOS (864)                       |
| Baltic (1257)                    | DOS (775)                       |
| Vietnamese (1258)                |                                 |
| Chinese Main Land (936)          |                                 |
| Chinese Taiwan (950)             |                                 |
| Japanese (932)                   |                                 |
| Korean (949)                     |                                 |
| Thai (874)                       |                                 |
| DOS-USA (437)                    |                                 |
| DOS-LATIN1 (850)                 |                                 |
| ────                             |                                 |
| Other (enter code page manually) |                                 |

The bullet marks the current choice. The dialog behind _Other_ was not recorded.

Related rules:

- The Unpack dialog has the same override as _Encoding of names_ (§5.3), e.g. for a ZIP with Cyrillic names.
- `[Packer] OverrideCodepage=-1` (default) sets a fixed codepage for names in archives (unpack only).
- `PreferUtf8ForZip=1`: a name that is valid both as UTF-8 and as ANSI is read as UTF-8 even when the UTF-8 flag is
  missing.
- `ZipAnsiNames=0`: legacy (non-UTF-8) names are written in the OEM (DOS) codepage; `1` = ANSI (Windows) codepage, which
  some unpackers cannot handle with accents.

### 2.4 Enter on a file inside an archive

- With `[Packer] ExpertMode=0` (default), Enter shows a **property sheet** for the packed file: full path, compression
  method, ratio, and a _Packer_ field naming the plugin that opened the archive. Alt+Enter shows the same. Its buttons
  include **Unpack and Execute** and **Unpack all and execute**: they extract to TEMP and run the file (e.g. to try a
  program or run an installer from inside an archive). A changed file can be re-packed afterwards.
- With `ExpertMode=1`, Enter runs the file directly.

### 2.5 Nested archives

1. Enter on an archive inside an archive extracts it to `%TEMP%\_tc\` and opens the copy. Unusual extensions and SFX
   files need Ctrl+PgDn.
2. The **path bar and the drive switch to the temporary path**, e.g. `<TEMP>\_tc\sample.tar`.
3. Backspace at the root of the nested archive returns to the outer archive (`…\sample.tar.gz\`) with the cursor on the
   nested archive.
4. Leaving the nested archive (to its parent or another drive) deletes the temporary copy.

Example: `sample.tar.gz` (not `.tgz`) opens as a GZ "folder" with one entry, `sample.tar`, listed at its unpacked size
(40,960 bytes); entering it opens the TAR as above.

### 2.6 Temporary extraction

- F3 on a file inside an archive extracts it to **`%TEMP%\_tc\`** and opens Lister on the copy, e.g.
  `Lister - [<TEMP>\_tc\report_01.txt]` (observed). Editing (F4), running and comparing also work on a temporary copy in
  TEMP (help). The same `_tc` folder holds files viewed from an FTP server (11).
- The help mentions a warning box before F3 extracts; none was recorded in the sandbox test (unverified).
- **Encrypted archives:** the plaintext temp copy of a file from an encrypted archive is overwritten with zero bytes
  before it is deleted (`[Packer] WipeEncrypted=1`; `0` deletes without wiping, which is faster).
- **On exit:** if temporary unpacked files still exist when TC closes, TC lists the first 3 names and where they came
  from.
- **First use:** while `[Configuration] FirstTimeZIP=1`, the first pack or unpack opens Configuration on the Packer page
  first. In the sandbox this page opened once, just before the first file was extracted for F3; this is probably that
  rule (unverified).

### 2.7 Encrypted names and partial archives

- **RAR with encrypted names:** TC asks for the password and then lists the content. In some cases only a pseudo-entry
  `<Encrypted -> F5>` appears; such an archive can only be unpacked completely, with F5 on that entry or with Alt+F9.
- **7z with encrypted names** (§4.7): the password is needed just to list the archive.
- **Leak protection:** names from header-encrypted archives must not leak into tabs, history and similar lists. With
  `[Configuration] LogEncryptedNames=0` (default) they are not written to the operation log; with `1` they are logged
  and a warning tip is shown when the archive is entered.
- **Partial ZIPs:** with `[Packer] OpenPartial=1` (_Open partial ZIP files_), a ZIP that is still downloading can be
  listed. The listing then uses the local headers, because the central directory is missing.

### 2.8 Quick View on an archive

For ZIP, ARJ, LZH and GZ, Quick View (Ctrl+Q, see 03 › Quick View) does not open the archive. It shows the first member
found in this order: `file_id.diz`, any `read*.*`, a `.NFO` file, any `.TXT` file. If none exists, the archive's raw
bytes are shown. `[Configuration] QuickViewUnzipReadMe`: `1` always (default), `-1` only for real archive extensions
(e.g. not `.epub`), `0` never.

_Basis: observed under Wine (sandbox: archive panel, encoding menu, temp extraction, nested archive) and on Windows 11
(`[Auto] Name` header); help: packedfiles, add_tabstopheader, options_unpackall, dlg_configpack, dlg_internal7zipconfig,
inisettings1/2/3, KEYBOARD.TXT, commandlineparameters, whats_new._

## 3. Operations inside an open archive

| Key / action                                          | Behaviour                                                                                                                                                                                                                                                                                                                                        |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **F3** view                                           | Extract to `%TEMP%\_tc\`, show, delete the copy when Lister closes; the archive is unchanged. If a Lister plugin changed the file, TC offers to re-pack it                                                                                                                                                                                       |
| **F4** edit                                           | Extract, edit, re-pack automatically if the file changed. For **TGZ, GZ, CAB** no re-pack is possible and the changed temp file is **kept**. `[Configuration] EditWaitTime=2`: if the editor returns within 2 s (a multi-document editor), TC asks the user to confirm when editing is finished; `0` turns this off, `-1` never shows the dialog |
| **Enter**                                             | Property sheet or run (§2.4)                                                                                                                                                                                                                                                                                                                     |
| **Alt+F9**                                            | Unpack dialog with a mask, also from inside an open archive (§5.1)                                                                                                                                                                                                                                                                               |
| **F5**, source = archive                              | Unpack dialog (§5) for the selected entries; folders are taken recursively. Unpacking straight to an FTP server is allowed: files go to TEMP first and are then uploaded                                                                                                                                                                         |
| **F5**, source = normal folder, target = open archive | Pack dialog (§4) adding at the archive's current subfolder                                                                                                                                                                                                                                                                                       |
| **F6**, target = open archive                         | Pack and delete the sources (move into the archive)                                                                                                                                                                                                                                                                                              |
| **F6** within an archive                              | Not available                                                                                                                                                                                                                                                                                                                                    |
| **Shift+F6**                                          | In-place rename of one file or folder: only inside **ZIP**, and inside 7z with the internal 7z packer (folders included)                                                                                                                                                                                                                         |
| **F8 / Del**                                          | The packer deletes the entries **directly**; there is no Recycle Bin. Not possible for GZ, TGZ, CAB, or for plugins that cannot delete                                                                                                                                                                                                           |
| **Shift+F4** new file                                 | Works inside archives (created, then packed)                                                                                                                                                                                                                                                                                                     |
| F5 between two open archives                          | Repacks directly from one archive into the other                                                                                                                                                                                                                                                                                                 |
| FTP panel → archive                                   | **Not supported**, so that a long download is not lost if packing fails                                                                                                                                                                                                                                                                          |
| Drag & drop                                           | Dropping files on an archive file adds them to it; dropping into an open archive panel packs into it (05 › Drag & drop)                                                                                                                                                                                                                          |

- **Zone.Identifier:** `[Configuration] WantZoneData` bit 1 copies the archive's Zone.Identifier stream to each file
  unpacked internally or by plugins (CHM files excepted).
- Plugins without "can modify" (flag 2) allow no adding and no F4 re-pack; without "can delete" (flag 8) F8 is
  unavailable.

_Basis: help only (packedfiles, proc_copy, proc_delete, proc_renmov, drag_drop, inisettings1/2/3, whats_new); F3
extraction path observed under Wine._

## 4. Pack

### 4.1 Invocation

| Trigger                                                                                         | Effect                                                                          |
| ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Alt+F5, Files › Pack..., `cm_PackFiles` (508), "Pack files" buttons on both default button bars | Pack dialog; _Move to archive_ unchecked (observed)                             |
| Alt+Shift+F5, `cm_MoveToArchive` (2956)                                                         | Pack dialog with _Move to archive_ **checked**                                  |
| `cm_CopyToArchive` (2955)                                                                       | Pack dialog with _Move to archive_ **unchecked**                                |
| "Pack files" in the file/folder context menu (TC's item in the shell menu, 05 › Context menus)  | Pack dialog                                                                     |
| F5 / F6 with an open archive in the target panel                                                | Pack dialog targeting that archive and its current subfolder (§3)               |
| **Ctrl** held while choosing Files › Pack                                                       | The proposed archive goes in the **source** folder instead of the target folder |
| First pack or unpack (`[Configuration] FirstTimeZIP=1`)                                         | Configuration opens on the Packer page first (§2.6)                             |

Operands follow the usual rule (selection, otherwise the item under the cursor; 07 › Operand rules).

### 4.2 Pack dialog

Title **"Pack files"**:

```text
Pack 1 file(s) to the archive                       Compression rate: [6]
[zip:c:\docs.zip                                   ]  ┌ Packer ────────────────┐
[x] Also pack path names (only recursed)              │ (o)ZIP  ( )RAR* ( )TAR │
[x] Recursively pack subdirectories                   │ ( )ARJ* ( )7-ZIP( )GZ  │
[ ] Multiple disk archive (ZIP, 7-ZIP, ARJ, RAR, ACE) │ ( )LHA* ( )ACE* ( )TGZ │
[ ] Move to archive                                   │ * needs external packer│
[ ] Create self extracting archive                    │ [    Configure...    ] │
[ ] Create separate archives, one per selected file/dir└───────────────────────┘
    [x] Leave out base directory when packing folders
[ ] Encrypt                        [ OK ] [ Tree ] [ Cancel ] [ Help ]
```

- The caption counts operands: "Pack 1 file(s) to the archive" also for a single folder.
- **Default target** (observed): `zip:<target panel path>\<operand name>.zip`, e.g. `zip:c:\docs.zip` for a folder
  `docs`. The help describes the name as built from the target path and the **source folder** name; this presumably
  applies when several items are selected (unverified). Whether a single file's own extension is kept in the name was
  not recorded.
- **Choosing a packer rewrites the field live:** 7-ZIP gives `7z:…\dir1.7z`, TGZ `tgz:…\dir1.tgz`, GZ `gz:c:\*.*.gz` and
  ticks _Create separate archives_ (GZ holds one file).
- **Encrypt** is greyed for formats that cannot encrypt (observed for TGZ).
- _Leave out base directory when packing folders_ is enabled only while _Create separate archives_ is ticked. On screen
  it was shown ticked (and greyed), although the documented initial value is `SkipFirstDir=0`.
- **Packer plugins** that can create archives appear as an extra choice (a combo of their extensions) when installed
  (documented).
- **Configure...** opens Configuration on the chosen packer's page (Zip packer, 7-Zip packer, or Packer; 13), or a
  plugin's own options dialog if it has one (flag 16).
- **Tree** opens the folder tree to pick the target (12 › Directory Tree dialog).
- Remembered non-default options carry a warning icon (§13.2).

### 4.3 Target string

```text
target   := [prefix ":"] archivePath ["/" subfolderInArchive]
prefix   := zip | 7z | arj | lha | rar | uc2 | ace | tar | gz | tgz | <plugin ext> | ext | int
subfolder:= path with "/" as separator      e.g. zip:c:\test.zip/this/is/a/subdir
```

1. **No prefix means no packing:** the files are **copied or moved normally** to the given path. A clone must reproduce
   this, not "fix" it.
2. `ext:` uses the configured **external** ZIP packer (PKZIP or Info-ZIP) even when the internal one is configured;
   `int:` forces the internal ZIP packer. Both apply to ZIP only.
3. `uc2:` typed by hand is the **only** way to create UC2 archives; there is no radio button for it.
4. The subfolder inside the archive follows a **forward slash**. A mixed form also works: in
   `zip:c:\test.zip/this\is\a\subdir` the first `/` ends the archive name.
5. With Info-ZIP as external packer, a long archive name containing spaces **must** be quoted: `zip:"c:\long name.zip"`.
6. A missing archive is created; an existing one gets the files **added**. This is how "add to an existing archive"
   works.
7. Choosing a packer rewrites prefix and extension (§4.2). `[Packer] ExtNeverUppercase=0`: if the base name is all
   uppercase, the extension is uppercased too; `1` turns this off.
8. **Separate archives** use a name mask: `*.*` stands for the full source name, so `gz:c:\*.*.gz` turns `a.txt` into
   `a.txt.gz`. Without a target folder each archive goes next to its original.

### 4.4 Packer choice

- **Radio group:** ZIP, ARJ, LHA, RAR, 7-ZIP, ACE, TAR, GZ, TGZ (`*` = needs an external packer: ARJ, LHA, RAR, ACE),
  plus installed packer plugins.
- **External packers:** if the program is not on `PATH`, its full path must be set on the Packer page (§7.1).
- **Last used:** `[Packer] LastUsedPacker` (32-bit TC) and `LastUsedPacker64` (x64; separate because plugin availability
  differs). `DefPlugin=<ext>` stores the last packer plugin.
- **7z with a 7z plugin installed:** "7-ZIP" = internal packer (or `7zg.exe` when the internal packer is off); "->7z" in
  the plugin list = the plugin.
- **Single-file formats** (GZ, and plugins without "multiple files", flag 4, such as bzip2): choosing one ticks _Create
  separate archives_.
- **TAR + single-file plugin:** TC can build a TAR first and pass it to the plugin, e.g. TAR + bzip2.

### 4.5 Options

| Option                                              | Effect                                                                                                                                                                                    | ini key (default)                                 | `cm_PackFiles` parameter                         |
| --------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- | ------------------------------------------------ |
| Also pack path names (only recursed)                | Selected folders are stored with paths **relative to the source folder**: `[test]` with `document.txt` is stored as `test\document.txt`. Unchecked: all files stored without paths (flat) | `[Packer] ZIPDirectoryOfFile=1`                   | `/D`                                             |
| Recursively pack subdirectories                     | Checked: everything below the selected folders (selecting `[Windows]` also takes `windows\system`). Unchecked: only the files directly in each selected folder                            | `ZIPRecurseSubdirs=1`                             | `/R`                                             |
| Multiple disk archive (ZIP, 7-ZIP, ARJ, RAR, ACE)   | Splits the archive over several media (§4.8)                                                                                                                                              | sizes in `[SplitPerFile]`, `SplitBytesPerFileZip` | `/S`                                             |
| Move to archive                                     | Deletes the sources **only after a successful** pack                                                                                                                                      | –                                                 | `/M`                                             |
| Create self extracting archive                      | Writes an `.exe` (§4.9): ZIP, 7-ZIP, RAR, ACE, ARJ and some plugins (SQX)                                                                                                                 | –                                                 | `/X`                                             |
| Create separate archives, one per selected file/dir | One archive per operand; without a target folder each goes next to its original                                                                                                           | –                                                 | `/A`                                             |
| └ Leave out base directory when packing folders     | Checked: the archive for folder `test folder` holds its **contents**, not `test folder\…`. Not saved; remembered while TC runs                                                            | `SkipFirstDir=0` (initial value)                  | `/B`                                             |
| Encrypt                                             | Encrypts the members (§4.7)                                                                                                                                                               | `PackEncrypted=1` (initial state, §4.7)           | `/C` (method), `/P="pwd"` (needs `/C`)           |
| Compression rate                                    | One-time override for this pack (§4.6)                                                                                                                                                    | `InternalZipRate=6`, `7zRate=6`                   | `/Z0`…`/Z10` (ZIP, GZ, TGZ; GZ and TGZ 1–9 only) |

Further `cm_PackFiles` parameters (full syntax in 17):

- `/T="name"`: target. `/T=""` or `/T="."` packs to the **source** folder with the default name; `/T="c:\path\."` uses
  the default name in that path.
- `/E="ext"`: packer type as shown in the dialog.
- `/F="opts"`: extra 7-Zip options, e.g. `/F="-m0=PPMD -mhc=on"`.
- `/O0`…`/O4`, `/O7`, `/O8`: overwrite mode, numbered as in the F5 copy dialog (07 › Name collisions: the Overwrite
  dialog); the renaming modes 5, 6 and 9 are not supported.
- `/G`: start at once without the dialog.
- Checkbox parameters take an optional `1` or `0`.

**Path names × recursion** (operand = folder `D` containing `f1` and `S\f2`):

| Path names | Recursive | Stored entries                                   |
| ---------- | --------- | ------------------------------------------------ |
| on         | on        | `D\f1`, `D\S\f2`                                 |
| on         | off       | `D\f1`                                           |
| off        | on        | `f1`, `f2` (flat; same-name collisions possible) |
| off        | off       | `f1`                                             |

With _Leave out base directory_ (separate archives, path names on, recursive on) the archive for `D` holds `f1` and
`S\f2`.

### 4.6 Compression rate

| Engine                         | Range in the Pack dialog                           | Meaning                                                                      | Configured default  |
| ------------------------------ | -------------------------------------------------- | ---------------------------------------------------------------------------- | ------------------- |
| Internal ZIP                   | 0–9, plus 10                                       | 0 = store, 1 = fastest … 9 = best, **10 = LZMA** (only with `LzmaAllowed=1`) | `InternalZipRate=6` |
| GZ / TGZ                       | 1–9                                                | Deflate level                                                                | as ZIP              |
| 7-Zip (internal and `7zg.exe`) | 1–9; the 7-Zip page also allows 0 = no compression | Officially 0 and odd values; even values work too                            | `7zRate=6`          |

The default is 6 because 9 is much slower for a gain of a few per mille. The field has no effect on external packers
other than 7-Zip.

### 4.7 Encryption

**Who can encrypt:** internal ZIP, internal 7-Zip, external RAR and ARJ, and packer plugins with encryption support
(e.g. SQX).

**ZIP method** (`[Packer] ZipAES=0` sets the format; where the user picks it in the UI was not recorded):

| Method                       | Notes                                                                                    | `ZipAES` | `/C` |
| ---------------------------- | ---------------------------------------------------------------------------------------- | -------- | ---- |
| ZIP 2.0 (traditional PKWARE) | Weak: easily broken with known plaintext, e.g. a readme encrypted with the same password | 0        | `0`  |
| AES-128                      | WinZip AE format; needs newer WinZip/PKZIP to unpack                                     | 1        | `1`  |
| AES-192                      |                                                                                          | 2        | `2`  |
| AES-256                      |                                                                                          | 3        | `3`  |
| Last method chosen           |                                                                                          | –        | `-1` |

**Initial state of _Encrypt_** (`PackEncrypted`): `0` never checked; `1` (default) checked if the target archive exists
and already holds at least one encrypted file; `2` always checked.

**7z:** with _Also encrypt names_ (`7ZencryptNames=0`, §7.3) names and attributes are encrypted too, and the password is
then needed to **open/list** the archive; otherwise only to unpack or change it.

**Password memory** (pack and unpack): `RememberLastPassword=1` reuses the last password for all archives until TC is
closed, minimized or Windows sleeps (default 0). `KeepPackerPassword` refines this: `1` keep it when TC is minimized,
`2` keep it when the screen saver starts, `3` both, `+4` forget it when the user leaves the archive.

### 4.8 Multi-volume archives

- **Formats:** internal ZIP, 7-Zip, ARJ, RAR, ACE.
- **ZIP versus ARJ:** the ZIP scheme lets the user extract selected files across all volumes; ARJ only allows all files,
  or selected files from one disk at a time. ZIP is recommended.
- **Medium full:** TC asks the user to swap the disk/stick or to give another location.
- **Volume size:** user-defined sizes are kept in `[SplitPerFile]` (shared with Split, §8); the last ZIP volume size in
  `[Configuration] SplitBytesPerFileZip`; for the internal 7z packer the size goes through the `-v` extra parameter
  (§7.3).
- **Unpacking:** multi-part RAR and multi-volume 7z are unpacked internally. Synchronize directories can compare against
  a multi-part ZIP, including by content (09 › Synchronize directories).

### 4.9 Self-extracting archives

**Creation:** tick _Create self extracting archive_, or **rename** an existing `.zip` (or `.7z`) to `.exe`; TC then asks
whether to turn it into a self-extracting archive (prepend the SFX stub).

**Built-in ZIP and 7z self-extractors:** 32-bit programs that also run on 64-bit Windows; distributing them needs no
licence; by default they extract to the **current folder**, and the user can choose another folder before extraction.

**ZIP-SFX command line** (any argument starts extraction at once, without the initial confirmation):

| Argument         | Target         | Existing files                                 |
| ---------------- | -------------- | ---------------------------------------------- |
| `Drive:\Path`    | that path      | Overwrite confirmation shown                   |
| `/S`             | current folder | Overwrite confirmation shown                   |
| `/O`             | current folder | Overwritten **silently**                       |
| `/O Drive:\Path` | that path      | Overwritten silently; `/O` must come **first** |

### 4.10 After packing

1. **Verify (internal ZIP only):** with `[Packer] VerifyZIP=1` (default) the new ZIP is tested at once. The user may
   abort the test; the ZIP is **not** deleted. `0` disables the test.
2. **Archive date:** with _Set archive date to newest file date_ (`ZipSetDateToNewest=0`, §7.1) the archive's
   modification time is set to that of its youngest member. Supported by internal ZIP, 7-Zip, TAR and GZ, and by
   external ZIP (via 7z), 7-Zip, ACE, RAR and LHA. Internal 7z also accepts `-stl`.
3. **Move:** sources are deleted only after success.
4. **Size warning:** see `WarnTooBig` (§1.2).
5. **Result:** there is **no message** on success. The new archive appears in the target panel; the selection state
   afterwards was not recorded.

### 4.11 Layout of the archives produced

**ZIP** (internal packer, rate 6, folder `dir1` with path names on):

|                           | Folder entry       | File entries                                                |
| ------------------------- | ------------------ | ----------------------------------------------------------- |
| Name                      | `dir1/`            | `dir1/report_0N.txt` (`/` separators, base folder included) |
| Method                    | stored             | Deflate (method 8)                                          |
| External (DOS) attributes | `0x10` (directory) | `0x20` (archive)                                            |

All entries: DOS timestamps in **local** time; "version made by" host system 0 (MS-DOS); general-purpose bit flag `2`;
no extra fields; no archive comment. Entries are written in **panel order**.

**TGZ** (with _Create TAR archives for Linux_ on, the default):

| Member  | Mode | uid / gid | User / group names | mtime |
| ------- | ---- | --------- | ------------------ | ----- |
| `dir1/` | 755  | 0 / 0     | empty              | UTC   |
| files   | 644  | 0 / 0     | empty              | UTC   |

### 4.12 Unicode names in ZIP

A name _contains Unicode_ when a character cannot be represented in the legacy (OEM/ANSI) codepage; it is _non-English_
when it has any character above 127. `[Packer] ZipUnicode` (combo _Pack Unicode names_, §7.2):

| Value       | Combo entry                                                             | Rule                                                                                                                                                                                      |
| ----------- | ----------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0 (default) | Ask every time a Unicode name is encountered                            | A dialog asks how to store the names                                                                                                                                                      |
| 1           | Store Unicode names as UTF-8 (Pkzip 4.5/Winzip 11.2 method)             | Only names that contain Unicode are written as UTF-8, with the UTF-8 flag. Old unzippers (Explorer, old TC) still extract them, showing several accented characters per Unicode character |
| 2           | All as UTF-8 if at least one contains Unicode                           | If any name in the batch contains Unicode, **all** names (accented ones too) are UTF-8; otherwise all are legacy                                                                          |
| 3           | All as UTF-8 if at least one contains non-English characters >127       | Like 2, triggered by any character above 127. Use case: sending accented names to a user of another script (Latin → Cyrillic)                                                             |
| 4           | Store Unicode name in extra field (Info-Zip method)                     | The main name stays legacy; the Unicode name goes into Info-ZIP's Unicode Path extra field (ID 0x7075). Suits Unix/Linux recipients; old unzippers keep accented names                    |
| 5           | Store all names containing non-English in extra field                   | Like 4, for every name with a character above 127                                                                                                                                         |
| 6           | Store Unicode characters as '?' (documented; not in the observed combo) | TC ≤ 7.0x behaviour; on unpack `?` becomes `_`. A clone should accept the ini value                                                                                                       |

`Zip83Name=0` (_Use 8.3 short filenames_): `1` stores only the 8.3 alias of long names, for plain DOS unzipping.

### 4.13 Temporary directory and removable media

- `[Packer] InternalzipTemp=`: folder for the internal ZIP packer's temporary files. Default `%TEMP%`; _other_ must name
  an existing folder. Only needed when packing to removable disks.
- `RemovableInTemp=0`: on floppies the new archive is built in TEMP, the old one deleted, and the new one copied to the
  disk; larger removable media are modified directly. `1` always uses the TEMP route.

### 4.14 Packing from a list file (`ZIPFROMLIST`)

The internal command `ZIPFROMLIST <archive name> <filelist>` packs the files named in a list file. Switches: `-m` move;
`-o`, `-os`, `-on` overwrite modes; `-c0`…`-c3` encryption method; `-0`…`-9` rate. The list file name may contain
Unicode; its content may be ANSI, UTF-16 with BOM, or UTF-8 with or without BOM. The archive name may also go in the
parameters field.

_Basis: observed under Wine (dialog, live target rewriting, TGZ Encrypt greyed, no success message, ZIP/TGZ byte layout)
and on Windows 11 (context-menu item); help: packedfiles, dlg_pack, options_pack, dlg_choosecommand,
aes_encryption_information, dlg_internalzipconfig, dlg_internal7zipconfig, inisettings1/2/3, inc.txt, KEYBOARD.TXT,
whats_new, what_s_new_continued._

## 5. Unpack

### 5.1 Invocation

| Trigger                                                                                                                        | Operands                                                                                     | Dialog variant                                                                                                   |
| ------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| F5 / F6 with an archive open in the source panel                                                                               | Selected entries (folders recursively)                                                       | Without _Files to unpack_                                                                                        |
| **Alt+F9** (= Alt+F6), Files › Unpack Specific Files..., `cm_UnpackFiles` (509), "Unpack all" button on the default button bar | The archive under the cursor, or all **selected archives**; also from inside an open archive | With _Files to unpack_                                                                                           |
| Alt+F9 with no archive under the cursor or selected                                                                            | –                                                                                            | Hint box (below, only while `[Configuration] FirstTimeUnpack=1`), then the warning **"No files selected!"** [OK] |

The hint box (observed):

```text
HINT:
If you only want to unpack a part of the files, just DOUBLE CLICK on the archive like on a
directory to show the archive's contents!
Now you can select the files you want to extract and extract them with F5 to the other file window.
                                   [ OK ]
```

### 5.2 Unpack dialog

Layout as documented; the dialog was used in the sandbox but its exact captions were not recorded except the
separate-subfolder option:

```text
Unpack specific files from archive to:            ← F5 variant: "Unpack n file(s) to"
[c:\target\                                      ▾]
Files to unpack:                                   ← Alt+F9 variant only
[*.*                                             ▾]
Encoding of names: [Auto ▾]                        ← documented; position unverified
[x] Unpack path names if stored with files
[ ] Unpack each archive to a separate subdir (name of the archive)
[ ] Overwrite existing files
              [ OK ] [ Tree ] [ Cancel ] [ Help ]
```

For encrypted archives TC asks for the password (prompt not recorded).

### 5.3 Fields and options

| Field / option                                                 | Effect                                                                                                                    | ini key                           | `cm_UnpackFiles` parameter                                                                                                                 |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- | --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Target ("Unpack … to")                                         | Default: the target panel path. **Empty** = the archive's own folder. A missing target folder is created (observed)       | –                                 | `/T="path"` (quotes required; `/T="."` = archive location)                                                                                 |
| Files to unpack (Alt+F9 only)                                  | Space-separated wildcards, e.g. `*.doc *.txt`. Names with spaces in double quotes: `"Letter to Mr. Smith.doc"`            | –                                 | `/W="…"`: inner quotes doubled, e.g. `/W="file1.txt ""file 2.txt"""`. `/W=""` unpacks the **selected** entries of an open archive, like F5 |
| Encoding of names                                              | Codepage override for member names (§2.3)                                                                                 | `OverrideCodepage`                | –                                                                                                                                          |
| Unpack path names if stored with files                         | Keeps stored relative paths. Unchecked: every file goes straight into the target (flattened; unverified)                  | `ExtractPathInZIP=1`              | `/D`                                                                                                                                       |
| Overwrite existing files                                       | Checked: existing targets are replaced silently. Unchecked: TC asks per file (07 › Name collisions: the Overwrite dialog) | `UnZIPOverwrite=0`                | `/O0`…`/O4`, `/O7`, `/O8` (5, 6, 9 unsupported)                                                                                            |
| Unpack each archive to a separate subdir (name of the archive) | Each archive goes to `<target>\<archive name without extension>\` (`filename.zip` → `filename`)                           | `UnZIPSeparateSubdirs=-1` (below) | `/S`                                                                                                                                       |
| Password                                                       | ZIP, RAR, internal 7-Zip                                                                                                  | –                                 | `/P="pwd"`                                                                                                                                 |
| Archive (header) password                                      | 7z with encrypted names (internal only)                                                                                   | –                                 | `/A="pwd"`                                                                                                                                 |
| –                                                              | Start without showing the dialog                                                                                          | –                                 | `/G`                                                                                                                                       |

Observed: with _Unpack each archive to a separate subdir_ and the missing target `…\work\unz\`, TC created `unz\sample\`
(archive name without extension), extracted the stored paths below it, and showed **no message**.

`UnZIPSeparateSubdirs` holds the initial state and whether changes are remembered:

| Value          | Initial state                                       | Changes remembered |
| -------------- | --------------------------------------------------- | ------------------ |
| `0`            | off                                                 | yes                |
| `1`            | on                                                  | yes                |
| `-1` (default) | off                                                 | no                 |
| `-2`           | on                                                  | no                 |
| `-3`           | on, but only when more than one archive is selected | no                 |

### 5.4 Which unpacker runs

```text
unpack(archive):
  if a plugin is registered for the extension and the internal handler does not take precedence:
      use the plugin      # ZIP: only if PluginOverrideZip=1; 7z: if 7zPreferPlugin=1 and installed
  ZIP : InternalUnzip=1 -> internal unzip, else external UnZIP= (pkunzip-compatible;
        unzip.exe and 7-Zip are not accepted)
  RAR : InternalUnrar=1 -> UnRAR64.DLL; if it fails to load -> tc7z64.dll; else external RAR=
  ARJ : InternalUnarj=1 -> internal (no encrypted members: those need the external ARJ), else ARJ=
  LZH : InternalUnlzh=1 -> internal, else LHA=
  ACE : InternalUnace=1 -> UnACEv2.DLL (32-bit TC only), else ACE=
  7Z, TAR, GZ, TGZ, CAB, ZST, BR : always internal
  UC2 : external only
```

7-Zip configured as the external ZIP packer is used for packing only; it never unpacks for TC.

### 5.5 Damaged members and limits

- **Bad CRC:** a member whose CRC fails is **deleted** after extraction by default. With _Keep damaged files (bad CRC)_
  (`[Packer] NoDelete=1`) it is kept, and the user should check it.
- The internal unpackers support long file names; internal UnRAR also handles target paths over 259 characters.
- Directory timestamps are restored.

_Basis: observed under Wine (hint box, "No files selected!", separate-subfolder result); help: packedfiles,
options_unpackall, dlg_unpack, dlg_choosecommand, dlg_configpack, dlg_internalzipconfig, inisettings1/3, KEYBOARD.TXT,
what_s_new_continued._

## 6. Test archives

Files › Test Archive(s), **Alt+Shift+F9**, `cm_TestArchive` (518).

- Every selected archive (or the one under the cursor) is tested: each member is unpacked **to memory** and its CRC
  compared with the stored one.
- **Good archive:** no message at all.
- **TAR** cannot be tested (no CRC in the format).
- **Damaged archive** (observed with `corrupt.zip`): a progress window, then an error box titled with the archive's
  name. **OK** continues the test, which then finished silently; **Cancel** has the focus.

```text
Verify (CRC check):
From: y:\…\C\corrupt.zip
To:   inside\hello.txt
[                                     ]
[                                     ]
0 / 3                 0 b / 1.2 k
[ Pause ] [ Cancel ] [ Background ]
```

```text
corrupt.zip                                         ← title = the archive's name
(!)  Error in packed file c:\tc-sandbox\C\corrupt.zip
                         [ OK ] [ Cancel ]          ← Cancel has the focus
```

- **Explorer check** (`[Packer] ZipTestWarnExplorer`, default `0`): with `1` the test also warns about ZIPs that Windows
  7–11 Explorer cannot extract (an Explorer bug with certain Deflate streams, typical of old libdeflate builds). The
  check was on by default when it was introduced; its default became `0` once the bug was fixed in the Windows 11 24H2
  Explorer.
- Test runs are logged when the _Pack/Unpack/Test archives_ log category is on (13 › Log file).

_Basis: observed under Wine (sandbox); help: options_testarchives, inisettings3, whats_new; HISTORY.TXT
(`ZipTestWarnExplorer` default)._

## 7. Packer configuration: effects

The pages themselves are in 13 › Packer, Zip packer, 7-Zip packer. All keys are in `[Packer]` unless stated.

### 7.1 Packer page (`cm_PackerConfig` 491)

| Setting (caption)                                       | Effect                                                                                                                         | ini (default)          |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | ---------------------- |
| Treat archives like directories                         | Enter opens archives as folders (§2.1); off: the associated program is launched, or TC opens the archive if none is associated | `ZIPlikeDirectory=1`   |
| Set archive date to newest file date                    | §4.10                                                                                                                          | `ZipSetDateToNewest=0` |
| ARJ packer `[arj32.exe]`                                | Path of the ARJ packer (recommended `ARJ32.EXE`)                                                                               | `ARJ=`                 |
| Use internal un-ARJ if possible                         | Internal un-ARJ; cannot handle encrypted members                                                                               | `InternalUnarj=1`      |
| Pass long filenames to ARJ (ARJ 2.55 or later required) | Long names are passed to ARJ when packing                                                                                      | `ARJlongnames=0`       |
| LHA packer `[lha32.exe]`                                | Creates `.lzh`                                                                                                                 | `LHA=`                 |
| Use internal un-LZH if possible                         | Internal un-LZH                                                                                                                | `InternalUnlzh=1`      |
| RAR Packer `[rar.exe]`                                  | Creates `.rar` (help recommends `winrar.exe`)                                                                                  | `RAR=`                 |
| Use internal un-RAR if possible                         | `UnRAR64.DLL`, fallback `tc7z64.dll`                                                                                           | `InternalUnrar=1`      |
| UC2 Packer `[uc.exe]`                                   | Creates `.uc2`; does not work on 64-bit Windows                                                                                | `UC2=`                 |
| ACE (>= 2.04) `[winace.exe]`                            | Creates `.ace` (the help still says ACE ≥ 1.2b; the on-screen label applies)                                                   | `ACE=`                 |
| Use internal un-ACE if possible                         | `UnACEv2.DLL`; no 64-bit DLL, so **greyed** in x64                                                                             | `InternalUnace=1`      |
| `>>` buttons                                            | File-open dialog to browse for the packer                                                                                      | –                      |
| Create TAR archives for Linux (unchecked: for SunOS)    | Changes only how names **over 99 characters** are stored: GNU tar style (Linux) or SunOS style                                 | `LinuxCompatible=1`    |
| Packer plugins: Configure packer extension WCXs         | Packer-plugin associations (15 › Packer plugins)                                                                               | `[PackerPlugins]`      |

### 7.2 Zip packer page (`cm_ZipPackerConfig` 485)

| Setting (caption)                                                                             | Effect                                                                                                                                                                                                                                                                                                                                                                   | ini (default)       |
| --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------- |
| ZIP packer `[pkzip.exe]`                                                                      | External ZIP packer (PKZIP-compatible by default)                                                                                                                                                                                                                                                                                                                        | `ZIP=`              |
| Use internal ZIP packer                                                                       | Use the internal packer; enables the post-pack verify (§4.10)                                                                                                                                                                                                                                                                                                            | `InternalZIP=1`     |
| 7Z                                                                                            | The external packer is `7zg.exe` (preferred) or `7z.exe`, used to create **ZIP** (not 7z) archives. Switches such as `-mcu=on` may follow the program name; commands such as `a` may not. Packing only                                                                                                                                                                   | `zip7z=0`           |
| Use ZIP-NT 2.01                                                                               | The external packer is Info-ZIP (ZIP-NT) 2.0.1 or later. `zipnt`: 0 = no, 1 = 2.0.1 patched by TC, 2 = unrecognized version. TC patches an unpatched 2.0.1 automatically (without the patch names with spaces fail). For later versions TC asks whether to use it anyway; answer yes and test with names containing spaces. Long names with spaces must be quoted (§4.3) | `zipnt=0`           |
| ZIP unpacker `[pkunzip.exe]`                                                                  | Must be pkunzip-compatible; `unzip.exe` and 7-Zip are rejected                                                                                                                                                                                                                                                                                                           | `UnZIP=`            |
| Always use internal unzipping (if possible)                                                   | The internal unzip is always used                                                                                                                                                                                                                                                                                                                                        | `InternalUnzip=1`   |
| Internal ZIP compression (0-9): normal (6) / maximum (9) / fastest (1) / other [6] (0 = none) | Default rate of the internal ZIP packer (§4.6)                                                                                                                                                                                                                                                                                                                           | `InternalZipRate=6` |
| Directory for temporary files (internal ZIP): default / other                                 | §4.13                                                                                                                                                                                                                                                                                                                                                                    | `InternalzipTemp=`  |
| Use 8.3 short filenames                                                                       | §4.12                                                                                                                                                                                                                                                                                                                                                                    | `Zip83Name=0`       |
| Open partial ZIP files                                                                        | §2.7                                                                                                                                                                                                                                                                                                                                                                     | `OpenPartial=0`     |
| Keep damaged files (bad CRC)                                                                  | §5.5                                                                                                                                                                                                                                                                                                                                                                     | `NoDelete=0`        |
| Pack Unicode names                                                                            | §4.12                                                                                                                                                                                                                                                                                                                                                                    | `ZipUnicode=0`      |

The compression, temp-folder and _Additional Settings_ options apply to the internal ZIP packer only. _Set ZIP date to
newest file date_ has moved to the Packer page.

### 7.3 7-Zip packer page (`cm_7ZipPackerConfig` 474)

| Setting (caption)                                                                | Effect                                                                                                                                                                                                                                                            | ini (default)                                                                                      |
| -------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| 7-Zip packer `[7zg.exe]`                                                         | Path to `7zg.exe`; needed only for external 7-Zip                                                                                                                                                                                                                 | `7zip=`                                                                                            |
| Use internal 7-Zip packer                                                        | Use `tc7z64.dll`. Even when off, the internal packer is used to pack **into a subfolder** of a 7z archive                                                                                                                                                         | `7zInternal=1`                                                                                     |
| Prefer 7-Zip plugin if installed                                                 | Enter opens 7z archives with the 7zip/Total7zip plugin; in the Pack dialog "7-ZIP" = internal/`7zg.exe`, "->7z" = plugin (§2.1, §4.4)                                                                                                                             | `7zPreferPlugin=1`                                                                                 |
| Extra parameters                                                                 | Passed to internal and external 7-Zip. Internal accepts only `-m…` switches plus `-slp` (large pages), `-stl` (archive date = newest file), `-v` (volume size). Forms: long `-mx=9`, short `-mx9`, bare `-mx` = the DLL default for that switch (`-mx` = `-mx=9`) | – (also `/F=`)                                                                                     |
| 7-Zip compression: normal (6) / maximum (9) / fastest (1) / other [6] (0 = none) | §4.6                                                                                                                                                                                                                                                              | `7zRate=6`                                                                                         |
| Compression method `[LZMA2 *]`                                                   | LZMA2 (recommended), LZMA, PPMd, BZip2                                                                                                                                                                                                                            | `7zMethod=LZMA2`                                                                                   |
| Dictionary size / Word size `[default]`                                          | Defaults depend on method **and** rate; the default entry carries `*`. After Apply they are saved **per method and rate**                                                                                                                                         | `7ZdictSize<method>_<rate>` (>0 MB, <0 kB, 0 = default), `7ZwordSize<method>_<rate>` (0 = default) |
| Create solid archive                                                             | All files compressed as one stream: better ratio, slower extraction of single files and slower updates                                                                                                                                                            | `7zSolid=1`                                                                                        |
| Solid block size `[16384 M *]`                                                   | Smaller blocks: slightly bigger archive, faster single-file extraction and update. Default depends on method and rate                                                                                                                                             | `7zSolidSize<method>_<rate>` (MB)                                                                  |
| Number of CPU threads `[2] / n`                                                  | Faster packing, more RAM. The maximum `n` depends on the machine, presumably its logical CPUs (16 on the test machine)                                                                                                                                            | `7zThreads=2`                                                                                      |
| Memory usage: for compression / for decompression                                | Live estimate (682 M / 66 M with the defaults on the test machine). 32-bit processes are limited to 2 GB in total; if allocation fails there is an error and the user must reduce the dictionary or threads                                                       | –                                                                                                  |
| Also encrypt names                                                               | §4.7                                                                                                                                                                                                                                                              | `7ZencryptNames=0`                                                                                 |

These settings apply to the internal packer and to `7zg.exe`.

_Basis: page captions and defaults observed on screen under Wine; effects from help (dlg_configpack,
dlg_internalzipconfig, dlg_internal7zipconfig, inisettings3)._

## 8. Split file

Files › Split File..., `cm_Split` (560). Input: the single file under the cursor. With nothing usable (e.g. the cursor
on a folder) TC shows "No files selected!" [OK].

### 8.1 Dialog

Title **"Split"**:

```text
Split the file 'random_1MB.bin' to directory:
[<other panel's path>                         ]
Bytes per file:  [            ▾]
[ ] Delete files on target disk (removable disks only)      ← greyed for fixed disks
                    [ OK ] [ Tree ] [ Cancel ]
```

- **Target:** default the other panel's path; **empty** = the current (source) folder.
- **Bytes per file** is an editable combo, **empty** by default. List: `Automatic` · `1.44 MB (3.5")` · `1.2 MB (5.25")`
  · `720 k (3.5")` · `360 k (5.25")` · `100 MB (ZIP)` · `250 MB (ZIP)` · `650 MB (CD-R)` · `700 MB (CD-R)`.
- **Typed size:** bytes, or a number with `k`, `M` or `G`, binary (1k = 1024 bytes, 1M = 1024 k, 1G = 1024 M).
- **Automatic:** on a removable target each part uses the medium's whole free space; on a hard disk the parts are 1.44
  MB (3½" floppy size; exact byte count not recorded).
- **Presets:** `360 k` = **362,496 bytes** per part (observed), i.e. the usable capacity of a formatted 360 k floppy
  rather than 360 × 1024. The byte values of the other presets were not recorded (1.44 MB is presumably 1,457,664,
  unverified).
- **Persistence:** user-defined sizes are stored in `[SplitPerFile]`, the last size in
  `[Configuration] SplitBytesPerFile=0`.
- **Delete files on target disk (removable disks only):** before writing, all files in the target folder **and below**
  are deleted; TC first lists them and asks for confirmation.

### 8.2 Part names and sizes

The base name is kept and the extension **replaced** by `.001`, `.002`, … `.999`, so there are at most **999 parts**.
Parts and source files over 2 GB are supported. Example (`360 k`, 1,048,576-byte file):

| File             | Size    |
| ---------------- | ------- |
| `random_1MB.001` | 362,496 |
| `random_1MB.002` | 362,496 |
| `random_1MB.003` | 323,584 |
| `random_1MB.crc` | 55      |

### 8.3 The `.crc` file

TC writes `<base>.crc` next to the parts. It holds three lines, each ending in CRLF, with the CRC32 as 8 **upper-case**
hex digits:

```text
filename=random_1MB.bin
size=1048576
crc32=A51F2139
```

The file is needed only by TC's Combine (§9). Other tools can join the parts without it, e.g.
`copy /b part.001 + part.002 + part.003 original.dat`.

### 8.4 Result

A box titled "Split": "Split of c:\tc-sandbox\A\bin\random_1MB.bin succeeded!" [OK] (the full source path).

_Basis: observed under Wine (sandbox and on screen); help: dlg_filessplit, inisettings2/3, what_s_new_continued._

## 9. Combine files

Files › Combine Files..., `cm_Combine` (561). The cursor must be on the **first** part.

Title **"Combine"**:

```text
Combine random_1MB.001 and all files with ascending names to the following directory:
[<other panel's path>                         ]
                    [ OK ] [ Tree ] [ Cancel ]
```

- **Target:** default the other panel's path; **empty** = the current folder.
- **Finding the series:** TC collects successive names with an ascending counter until the next name does not exist.

| Pattern                         | Example                                                 |
| ------------------------------- | ------------------------------------------------------- |
| Numeric extension               | `file.001`, `file.002`, `file.003`, …                   |
| Letter suffix (Unix `split -b`) | `fileaa`, `fileab`, `fileac`, …                         |
| Numeric counter inside the name | `filename.00000.zip.part`, `filename.00001.zip.part`, … |

```text
parts = [first]
loop: next = increment(counter in name)   # decimal of the same width, or letters a..z with carry (az -> ba)
      if exists(dir/next): parts.append(next) else break
```

- **`.crc` file:** TC looks for `<base>.crc` in the folder of any of the parts. If found, the combined file gets the
  **original name stored in it** and is **verified** against its size and CRC32. Without a `.crc` file the output name
  is not documented; presumably the part name without its counter extension (unverified).
- **Result** (observed): a box titled **`Combine - <number of parts>`**, e.g. "Combine - 3", reading "Combine of
  random_1MB.bin succeeded (CRC checksum OK)!".

_Basis: observed under Wine (sandbox); help: dlg_filescombine._

## 10. Encode and decode

### 10.1 Encode

Files › Encode File (MIME,UUE,XXE)..., `cm_Encode` (562). Input: the file under the cursor.

Title **"Encode"**:

```text
Encode the file decoded.txt to directory:
[<other panel's path>                        ]
┌ Encode as ──────────┐  Lines per file: [      ]
│ (o) MIME (Base64)   │  Bytes per file: [      ]
│ ( ) UUEncode        │  (Note: header size is not counted)
│ ( ) XXEncode        │
└─────────────────────┘
          [ OK ] [ Tree ] [ Cancel ] [ Help ]
```

| Method        | Output extension | Remark                                         |
| ------------- | ---------------- | ---------------------------------------------- |
| MIME (Base64) | `.B64`           | Internet mail format                           |
| UUEncode      | `.UUE`           | Old and widespread, but some servers mangle it |
| XXEncode      | `.XXE`           | Avoids UUE's problems, but rare                |

- **Output name:** base name kept, extension replaced (observed: `decoded.txt` → `decoded.uue`, written in lower case).
  **Empty** target = current folder.
- **Last method:** `[Configuration] EncodeMethod=0` (0 MIME, 1 UUE, 2 XXE).
- **Lines per file:** encoded lines per output file; empty or 0 = a single output file (`EncodeLinesPerFile=0`). Header
  lines (original file name etc.) are not counted.
- **Bytes per file:** size of each part; headers are not counted, so parts are slightly larger. The names of multi-part
  output were not recorded; Decode expects numbered names such as `file001.uue` (§10.3).

### 10.2 Encoded output format

UUEncode output (observed, CRLF line ends):

```text
begin 644 decoded.txt
M…                                     ← 61-character lines starting with "M"
…                                      ← a final shorter line
`                                      ← a line with a backquote
end
sum -r/size 22181/1100
```

The last line gives the `sum -r` checksum and the size of the original file (1,100 bytes here).

### 10.3 Decode

Files › Decode File (MIME,UUE,XXE,BinHex)..., `cm_Decode` (563). Formats: MIME/Base64, UUEncode, XXEncode, BinHex 4.0,
yEnc. Input: the cursor on the encoded file or on its **first** part; further parts are found by an ascending counter as
in Combine (`file001.uue`, `file002.uue`, … or `fileaa`, `fileab`, …).

Title **"Decode"**:

```text
Decode the file encoded.b64 to directory:
[<other panel's path>                         ]
[ ] Auto-rename decoded files
            [ OK ] [ Tree ] [ Cancel ]
```

- **Output name** comes from the encoded data (e.g. the MIME header `filename="decoded.txt"`). Invalid file-name
  characters become `_`.
- **Name clash:** the Overwrite dialog appears (07 › Name collisions: the Overwrite dialog); its _Auto-rename copied_
  creates `name(2)`, `name(3)`, …. _Auto-rename decoded files_ presumably applies this without asking (unverified).
- **Empty** target = current folder.
- **Missing target folder:** rejected; the Decode dialog then **closes** and must be opened again (Copy, by contrast,
  creates missing folders):

```text
Decode                                             ← title
The given target path
c:\tc-sandbox\work\dec\
is invalid!
                 [ OK ]
```

- **Success:** no message. The MIME test produced the correct 1,100-byte file.

_Basis: observed under Wine (sandbox: both dialogs, UUE output, MIME decode, invalid target); help: dlg_filesencode,
dlg_filesdecode, inisettings1, what_s_new_continued._

## 11. Create checksum files

Files › Create Checksum File(s) (CRC32, MD5, SHA1)..., `cm_CRCcreate` (564). Operands: the selection or the item under
the cursor; selected folders are processed **recursively**.

### 11.1 Dialog

Title **"Create CRC-checksum file"**:

```text
Save CRC file(s) to:
[c:\windows\notepad.exe.sfv                         ]
[ ] Create separate checksum files for each file
[ ] Create separate checksum files for each directory
[ ] Always use UTF-8 in names
[ ] Unix format: line breaks, '/' in paths
┌ Checksum method: ───────────────────────────────────────┐
│ (o) CRC32 (SFV)   ( ) SHA224   ( ) SHA3_224             │
│ ( ) MD5           ( ) SHA256   ( ) SHA3_256             │
│ ( ) SHA1          ( ) SHA384   ( ) SHA3_384             │
│ ( ) BLAKE3        ( ) SHA512   ( ) SHA3_512             │
└─────────────────────────────────────────────────────────┘
                                   [ OK ] [ Cancel ]
```

### 11.2 Methods

| Method      | `[Configuration] Lastmd5` | Extension                           | Notes                                                            |
| ----------- | ------------------------- | ----------------------------------- | ---------------------------------------------------------------- |
| CRC32 (SFV) | 0                         | `.sfv`                              | Fastest, least secure                                            |
| MD5         | 1                         | `.md5`                              | Lower-case hex                                                   |
| SHA1        | 2                         | `.sha`                              |                                                                  |
| SHA256      | 3                         | `.sha256`                           | SHA2                                                             |
| SHA512      | 4                         | not recorded (presumably `.sha512`) |                                                                  |
| SHA224      | 5                         | not recorded                        |                                                                  |
| SHA384      | 6                         | not recorded                        |                                                                  |
| SHA3_256    | 7                         | not recorded                        | Via `tcsha64.dll`                                                |
| SHA3_512    | 8                         | not recorded                        |                                                                  |
| SHA3_224    | 9                         | not recorded                        |                                                                  |
| SHA3_384    | 10                        | not recorded                        |                                                                  |
| BLAKE3      | 11                        | `.bk3`                              | Fastest cryptographically safe hash; multi-threaded in 64-bit TC |

- The extension in _Save CRC file(s) to_ follows the method radio button **live** (`.sfv`, `.md5`, `.sha`, `.sha256`
  observed).
- The **last used method** is preselected next time (`Lastmd5`).
- `[Configuration] CrcBlake3BlockSize=1024` (64-bit TC on SSDs only), block size in MB: `0` = 256 kB without memory
  mapping (the TC ≤ 11.51 method; default on CPUs with fewer than 8 logical cores, sometimes faster than 1024); `1` = 1
  MB without multi-threading; `≥ 2` multi-threaded; `2047` maximum.

### 11.3 Target name and file options

**Save CRC file(s) to** takes the target path **and** file name. Proposals (observed):

| Operands      | Proposal                                                               |
| ------------- | ---------------------------------------------------------------------- |
| One file      | `<source folder>\<file name>.<ext>`, e.g. `c:\windows\notepad.exe.sfv` |
| Several items | `<source folder>\<source folder name>.<ext>`, e.g. `work.md5`          |

| Option                                            | Effect                                                                                                                                                                                                                     | ini (default)          |
| ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- |
| (neither separate option)                         | One checksum file for all files                                                                                                                                                                                            | –                      |
| Create separate checksum files for each file      | One checksum file per file. The name **must contain `*`**: with two (`*.*.sfv`) the checksum extension is **appended** (`test.txt` → `test.txt.sfv`); with one (`*.sfv`) the file's extension is **replaced** (`test.sfv`) | `CrcSeparateFiles=0`   |
| Create separate checksum files for each directory | One checksum file per folder in which files were hashed, written into that folder; the **target path is ignored**                                                                                                          | `CrcSeparateFolders=0` |
| (default proposal for either separate option)     | `CrcAppendExt=1`: append the checksum extension; `0`: replace the file's extension                                                                                                                                         | `CrcAppendExt=1`       |
| Always use UTF-8 in names                         | Normally UTF-8 is used only when a name has characters outside the current codepage (e.g. Cyrillic, Chinese); checked: always. A clone should write a BOM, since Verify reads UTF-8 only with BOM (unverified)             | `CrcForceUtf8=0`       |
| Unix format: line breaks, '/' in paths            | Default: CRLF and `\` between folders (`Directory\File`); checked: LF and `/` (`Directory/File`)                                                                                                                           | `CrcForwardSlashes=0`  |

### 11.4 Checksum file format

MD5 and SHA lines (observed for MD5 and SHA256):

```text
<lower-case hex digest> *<name>          ← followed by CRLF
```

- `*` is the binary-mode marker (md5sum/sha*sum style); MD5 has 32 hex digits.
- `<name>` is relative to the checksum file's folder. When the checksum file is saved in a different folder, `<name>`
  carries no path at all (observed).
- SFV lines (not recorded; de-facto standard so that other tools can read them): optional comment lines starting with
  `;`, then `<name> <8 hex digits>`.

### 11.5 Result

The job has a Background button (help); no result message was recorded. After creation the **source selection is
cleared** (observed).

_Basis: observed under Wine (sandbox and on screen: proposals, live extension, remembered method, cleared selection,
MD5/SHA256 format); help: dlg_createsfv, inisettings1, whats_new, what_s_new_continued._

## 12. Verify checksums

Files › Verify Checksums (from checksum files), `cm_CRCcheck` (565).

### 12.1 Input modes

```text
verify():
  if the selection / cursor holds checksum files (*.sfv *.md5 *.sha* *.bk3 + ChecksumExtraTypes):
      mode = FILES       # each listed file is located relative to the checksum file and hashed
  elif the clipboard holds a hex hash and the cursor is on a normal file:
      mode = CLIPBOARD   # hash the cursor file, compare with the clipboard
  elif the selected / cursor file names contain a CRC32 in square brackets ("Movie [1A2B3C4D].mkv"):
      mode = NAME
  else:
      error box "Please select only SFV, MD5 or SHA files!" [OK]
```

`[Configuration] ChecksumExtraTypes=` adds patterns such as `*.sum *.crc32`.

### 12.2 Checksum-file formats accepted

- **Encodings:** ANSI, UTF-8 **with BOM**, UTF-16 with or without BOM.
- **Algorithms:** CRC32, MD5, SHA1, SHA2 (224/256/384/512), SHA3 (224/256/384/512), BLAKE3 (any digest length).
- **Line forms:** the SFV and `hash *name` forms of §11.4; OpenSSL style (`SHA256(name)= …`, also SHA224, SHA384,
  SHA3-224/256/384/512); and a checksum taken from a stream, `<checksum>  -` (two spaces and a dash).

### 12.3 Hash-length disambiguation (clipboard and name modes)

| Hex digits | Candidates               |
| ---------- | ------------------------ |
| 8          | CRC32                    |
| 32         | MD5                      |
| 40         | SHA1                     |
| 56         | SHA224, SHA3_224         |
| 64         | SHA256, SHA3_256, BLAKE3 |
| 96         | SHA384, SHA3_384         |
| 128        | SHA512, SHA3_512         |

When several algorithms share a length, the user must pick the right one in the dialog, otherwise an error is shown;
ticking all suitable methods also works but is much slower. Preselection: `[Configuration] PreferHashType256=1` for
256-bit hashes (1 SHA2, 2 SHA3, 3 SHA2+SHA3, 4 BLAKE3, 5 BLAKE3+SHA2, 6 BLAKE3+SHA3, 7 all three);
`PreferHashTypeOther=1` for other lengths (1 SHA2, 2 SHA3, 3 both). Adding 16 to either key stops dialog changes from
being saved.

### 12.4 Verify window

```text
MD5: Errors: 1                                        ← title "<METHOD>: Errors: N"
┌──────────────────────────────────────────────────────┐
│ <checksum file>:                                     │
│ OK:  random_1MB.001                                  │
│ Cannot open input file random_1MB.bin!               │ ← red
│                                                      │
│ Errors: 1                                            │
│ OK: n, not found: n, read error: n, wrong checksum: n│ ← red when there are errors
└──────────────────────────────────────────────────────┘
[▲] [▼]   [ ] Only Errors              [ Close ] [ Background ]
```

- **Title:** `<METHOD>: Errors: N`, e.g. `MD5: Errors: 1`, `SHA2_256: Errors: 0`.
- **Rows:** a `<checksum file>:` line, one row per file (`OK:  <name>` with two spaces, or a red error such as
  `Cannot open input file <name>!`), a blank line, `Errors: N`, and the summary, e.g.
  `OK: 3, not found: 0, read error: 0, wrong checksum: 0`. The wording of a wrong-checksum row was not recorded.
- **Only Errors:** shows just the failing rows plus the summary.
- **▲ / ▼** (bottom left) jump to the previous / next failure and appear **only when there are errors**; Ctrl+Up /
  Ctrl+Down do the same.
- **Failures** are **selected in the active file panel** and highlighted in the window.
- The window is non-modal and runs in the background, so the user can keep working in TC.

| Key                 | Action                                   |
| ------------------- | ---------------------------------------- |
| Ctrl+Down / Ctrl+Up | Next / previous failure                  |
| Ctrl+A              | Select the whole result list             |
| Ctrl+C              | Copy the selected lines to the clipboard |
| Esc                 | Abort, with confirmation                 |

_Basis: observed under Wine (sandbox: window, title, rows, buttons; on screen: error box); help: dlg_verifysfv,
inisettings1/2, whats_new, what_s_new_continued._

## 13. Background operation and interactions

### 13.1 Background operation

- Pack and unpack progress windows (ZIP, TAR, RAR, 7Z, external packers, capable plugins) and the Test progress window
  have a **Background** button. A background job can be brought back to the foreground if no other TC dialog is open (07
  › Background Transfer Manager).
- After a background job the panel may be stale; refresh with F2 or Ctrl+R.
- `[Configuration] AlwaysPackInBackground` / `AlwaysUnpackInBackground`: `0` off; `1` internal zip/unzip in the
  background; `2` also external (un)packers; `3` like 2, with external programs minimized.
- Packer plugins can work in the background only if they were written to support it (15).

### 13.2 Interactions with other features

- **Search:** Find Files can search inside archives (all formats except UC2); text search inside packer-plugin archives
  needs flag 128; `[Configuration] SearchInFiles=` adds archive types such as `*.EXE *.JAR` (09 › Find Files).
- **Logging:** the _Pack/Unpack/Test archives_ log category records these jobs; names inside header-encrypted archives
  are left out unless `LogEncryptedNames=1` (§2.7).
- **Warning icons:** remembered non-default options in the Pack and Unpack dialogs get an exclamation icon
  (`ShowWarningIcons=1`).
- **Junctions:** `IgnoreLinks` bit 2 makes the internal packers (ZIP, TAR) skip junctions and reparse points to folders.
- **Icons:** an internal association's icon takes precedence over the internal packer icon (e.g. for `*.rar`; 10 ›
  Internal associations).
- **Plugin installation:** entering a plugin's ZIP that contains `pluginst.inf` offers to install it; for a packer
  plugin the Associate dialog follows once per extension (15 › Installation).

### 13.3 State changes at a glance

| Operation                   | Selection afterwards                       | Panels / files                                                         |
| --------------------------- | ------------------------------------------ | ---------------------------------------------------------------------- |
| Pack (success)              | not recorded                               | No message; archive appears in the target panel                        |
| Pack with _Move to archive_ | –                                          | Sources deleted after success                                          |
| Enter on archive            | –                                          | Panel path inside the archive; `[Auto] Name` header                    |
| Enter on nested archive     | –                                          | Panel and drive switch to `%TEMP%\_tc\…`; temp copy deleted on leaving |
| Unpack (Alt+F9 / F5)        | not recorded                               | No message; missing target created                                     |
| Test archive, good          | –                                          | No message                                                             |
| Split                       | –                                          | "Split of … succeeded!"; parts and `.crc` in the target                |
| Combine                     | –                                          | "Combine - n" box                                                      |
| Decode                      | –                                          | No message; invalid target closes the dialog                           |
| Create checksum file        | **Source selection cleared**               | Checksum file written                                                  |
| Verify checksums            | Failing files selected in the active panel | Non-modal window                                                       |

_Basis: observed under Wine (sandbox state changes); help: packedfiles, options_pack, proc_copy, dlg_pack, plugins,
inisettings1/2, what_s_new_continued, whats_new; plugin installation observed on Windows 11._
