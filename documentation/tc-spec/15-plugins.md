# 15: Plugins

This chapter describes Total Commander's four plugin types (packer `.wcx`, file system `.wfx`, Lister `.wlx`, content
`.wdx`): how they are installed (automatically from their archive, or by hand), the dialogs that manage them, how they
are registered in `wincmd.ini`, the policies that restrict them, and how each type appears in use, including the _Choose
plugin property_ dialog. It ends with the plugins tried on the Windows 11 test installation. **The plugin programming
interface (the WCX, WFX, WLX and WDX SDKs: exported functions, structures, return codes) is not documented in this
set**; only the behaviour visible in Total Commander is.

**Related:** [01](01-overview-and-architecture.md) (plugins as a concept), [03](03-file-panels.md) (custom columns,
thumbnails, Quick View), [07](07-file-operations.md) (Change attributes, overwrite dialog),
[08](08-archives-and-file-tools.md) (archives, Pack dialog), [09](09-search-rename-sync-compare.md) (Find Files plugin
rules, Multi-Rename fields, plugin compare), [10](10-lister-and-viewing.md) (Lister plugins menu, view methods),
[11](11-ftp-and-network.md) (Network Neighborhood, FTP connect list), [13](13-configuration-dialog.md) (Options ›
Plugins page), [18](18-syntax-reference.md) (content-field syntax, `tc` fields),
[19](19-settings-files-and-command-line.md) (plugin ini sections), [B](B-investigation-and-test-setup.md) (test
plugins).

## 1. Plugin types

### 1.1 The four types

| Type        | File (64-bit build) | Purpose                                                                                           | Examples (help)                                                                                                                                                                            | Used from                                                                      |
| ----------- | ------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| Packer      | `.wcx` (`.wcx64`)   | Unpack, and optionally create and modify, formats not supported internally. Also "pseudo-packers" | bzip2 archives; _diskdir_, which writes a readable list of the selected files with size and date (including subfolders) for disk catalogues; a batch-file generator for the selected files | Enter / Ctrl+PgDn on a file, Files › Pack (§6)                                 |
| File system | `.wfx` (`.wfx64`)   | Access to places without a drive letter, or remote systems                                        | A Windows CE / PocketPC device, a Linux partition, web servers via HTTP, a mail server, the registry, SFTP                                                                                 | Network Neighborhood (§7)                                                      |
| Lister      | `.wlx` (`.wlx64`)   | Display more file formats                                                                         | DBF databases, PDF, source code with syntax highlighting, images                                                                                                                           | F3 Lister, Ctrl+Q Quick View, thumbnails (§8)                                  |
| Content     | `.wdx` (`.wdx64`)   | Extra file properties: to show in file lists, to search for, to put into new names                | MP3 ID tags (artist, title, album), EXIF data of photos (aperture, exposure, flash), creation time, program version                                                                        | Custom columns, Find Files, Multi-Rename Tool, Change attributes and more (§9) |

Built-in properties (size, dates, attributes, version, ID3 tags, …) are offered as the pseudo-plugin **`tc`** wherever
content plugins can be used; its fields are listed in 18 › Content fields.

### 1.2 Other add-ons installed the same way

- **Languages** (e.g. Arabic, Traditional Chinese) come as ZIP files with `.LNG`/`.MNU` (and optionally a help file) and
  are installed by Enter or double-click on the ZIP, like a plugin (16). A help file included with a language is then
  used for F1.
- **Icon libraries** for the button bars and main menu can be installed the same way and become the default library (14
  › Icons and icon libraries).

### 1.3 64-bit plugins

- 64-bit TC loads only 64-bit DLLs, so every plugin needs a 64-bit build. Their files **must** end in `64` (`.wcx64`,
  `.wfx64`, `.wlx64`, `.wdx64`).
- The registration keeps the 32-bit name: the auto-installed Imagine archive contained only `Imagine.wlx64` (plus
  `.wcx64`, `.wdx64`), yet the path was registered as `…\Imagine.wlx`. A 64-bit TC therefore looks for the file with
  `64` appended (inferred); a path stored with the `64` suffix also works.
- 64-bit TC lists only packer, file-system and content plugins that really exist in 64-bit form; for a content field
  whose plugin exists only as 32-bit it shows `<?>`. A missing content plugin gives an error.
- Installing a 32-bit plugin into 64-bit TC shows a special warning.
- Which registered plugins have a 64-bit build is cached in the `…64` sections (§4.3).

### 1.4 Programming interface

Plugins are DLLs written to the published plugin interfaces; the help points to the plugin writer's guides and sample
sources (mostly C, some Delphi) on [www.ghisler.com](https://www.ghisler.com). **Those interfaces are not specified in
this documentation set.** Where TC's behaviour depends on what a plugin reports (capability flags, detect strings, field
lists, supported functions), this chapter states the visible effect only.

_Basis: observed on Windows 11 (64-bit plugins, registered names); help: plugins, dlg_configplugin,
frequentlyaskedquestions; change log for the 64-bit rules._

---

## 2. Installation

### 2.1 Automatic installation

Entering a plugin archive (ZIP or RAR) with **Enter** or a double-click is detected as a plugin installation when the
archive contains the install descriptor **`pluginst.inf`**. `[Configuration] AutoInstallPlugins=0` turns this off. It
also works when the archive is opened through an internal association, and it honours the unpacker the user chose for
it.

1. **Enter** opens the archive like a folder (header `[Auto] Name`; for Imagine the list showed Language, Plugin,
   `Imagine.chm`, `Imagine.wcx64`, `Imagine.wdx64`, `Imagine.wlx64`, `Imagine64.dll`, `Imagine64.exe`, `pluginst.inf`,
   `Readme.txt`, `Whatsnew.txt`). At once a question box appears:

   ```text
   <archive name>                                       ← title
   This archive contains the following Total Commander plugin/addon:
   <description lines from pluginst.inf, several lines, incl. the version>
   Do you want to install it?
                        [ Yes ] [ No ]
   ```

2. **Yes** opens a dialog titled with the plugin description:

   ```text
   Install to:
   [C:\Program Files\totalcmd\plugins\wlx\Imagine                    ]
   [ ] Confirm overwrites
                             [ OK ] [ Tree ] [ Cancel ]
   ```

   The path is editable; **Tree** chooses a folder from the directory tree (12 › Directory Tree dialog); _Confirm
   overwrites_ asks before existing files are replaced.

3. If the folder cannot be created (the program folder is not writable for a normal user):

   ```text
   Error: Directory [C:\Program Files\totalcmd\plugins\wlx\Imagine\] not created!
                    [ OK ] [ 🛡 As Administrator ]
   ```

   **OK** returns to step 2 with the path editable; nothing has been written. **As Administrator** retries with
   elevation (not taken in the test).

4. With a writable path (e.g. `%APPDATA%\GHISLER\plugins\wlx\Imagine`) the files are unpacked and the **registration
   dialog** of the plugin type opens (§2.4). **OK** there registers the plugin.

**No** in step 1 leaves the archive open as a normal folder.

### 2.2 The install descriptor

`pluginst.inf` is a text file in the plugin archive. Its full format is not documented here. What is known from observed
effects and the change log:

- it gives the description shown in the question box (several lines; translated descriptions in other code pages and
  UTF-8 are supported) and, with `version=`, a version shown on a separate line;
- it gives the plugin type and the default folder name used in the proposed path (`…\<type>\<name>`);
- for a packer plugin it lists the extensions to associate (ISO: `iso` and `img`);
- with `type=prg` and `file=WCMICON<unique>.DLL` it installs an icon library, which becomes the default (14 › Icons and
  icon libraries).

A plugin archive may contain several plugin types (Imagine: `.wlx64`, `.wcx64`, `.wdx64`); only the Lister registration
was recorded for it.

### 2.3 Install folder

- The proposed folder is `<PluginBaseDir>\<type>\<name>\`, with `<type>` = `wcx`, `wfx`, `wlx` or `wdx`. With
  `[Configuration] PluginBaseDir=%COMMANDER_PATH%\plugins`, a packer plugin `sample_packer` is offered
  `%COMMANDER_PATH%\plugins\wcx\sample_packer\`.
- Without `PluginBaseDir`, the first proposal on Windows 11 was `C:\Program Files\totalcmd\plugins\wlx\Imagine` (=
  `%COMMANDER_PATH%\plugins\<type>\<name>`).
- After that install was redirected to `%APPDATA%\GHISLER\plugins\wlx\Imagine`, every later plugin was proposed under
  `%APPDATA%\GHISLER\plugins\<type>\<name>` (e.g. `…\wdx\wdx_exif`): TC stores the base of the folder actually used as
  `PluginBaseDir` (inferred from these proposals and change-log fixes to that write).
- The registered path keeps environment variables **unexpanded**, e.g.
  `%APPDATA%\GHISLER\plugins\wlx\Imagine\Imagine.wlx`.
- When installing into the TC folder or the language folder, TC first unloads `tcmatch.dll` and closes its help file, so
  these files can be replaced.
- Zone data (the "downloaded from the Internet" stream) is not copied to the unpacked files when the plugin comes from a
  known trusted site.

### 2.4 Registration step by type

| Type                 | Dialog after unpacking                                                            | New entry                                                                                                    |
| -------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Lister (`.wlx`)      | "Lister plugins" (§3.4)                                                           | Already added and selected; path stored unexpanded, e.g. `%APPDATA%\GHISLER\plugins\wlx\Imagine\Imagine.wlx` |
| Packer (`.wcx`)      | The Associate dialog (§3.2), **once for each extension** listed in `pluginst.inf` | The `.wcx` path in _Associate with_                                                                          |
| File system (`.wfx`) | "File system plugins" (§3.3)                                                      | A line `<root name>  -  <path>`                                                                              |
| Content (`.wdx`)     | "Content plugins" (§3.5)                                                          | Not recorded in detail                                                                                       |

**ISO packer plugin.** After "Install to:" `[%APPDATA%\GHISLER\plugins\wcx\iso]` the Associate dialog opened for `iso`:

```text
All files with extension (ending with):   [iso                    ▾]
Associate with:
[%APPDATA%\GHISLER\plugins\wcx\iso\iso.wcx                         ]
┌──────────────────────────────────────────────────────────┐
│ (none)                                                   │
│ (the plugin)                                             │
└──────────────────────────────────────────────────────────┘
[ New type... ] [ Delete ]            [ OK ] [ Cancel ] [ Help ]
```

**OK** moved on to the next extension (`img`); OK there finished the installation.

### 2.5 Re-installing and updates

- When the plugin is already installed, TC finds its old location (also when the stored path contains an environment
  variable, and when a 64-bit or combined plugin replaces a 32-bit one) and shows a warning; the warning is skipped when
  the old plugin folder no longer exists although the plugin is still registered. The warning's wording was not
  recorded.
- Installing a plugin clears the `…64` sections of `wincmd.ini`, so the list of 64-bit plugins is rebuilt (§4.3).

### 2.6 Manual installation

1. Unpack the plugin to a folder, e.g. `c:\Totalcmd\Plugins`.
2. Open Configuration › Options › **Plugins** (`cm_PluginsConfig` 484) and press **Configure** for the type (§3).
3. Packer: associate each extension with the `.wcx` file. File system, Lister, content: **Add** the DLL.

Each plugin also ships a readme with its own instructions.

_Basis: observed on Windows 11 (Imagine, ISO, Registry, Secure FTP, Exif); help: plugins, dlg_configplugin,
frequentlyaskedquestions, inisettings1, inisettings2; change log._

---

## 3. Managing plugins: Options › Plugins

The page's place in the Options dialog is in 13 › Plugins. What each control does:

```text
┌ Download new plugins from ghisler.com ─────────────────────────────────────┐
│ Opens your default WEB browser with the plugins page. Installation: After  │
│ downloading the plugin ZIP file, open it in Total Commander with ENTER and │
│ follow the instructions.                                      [ Download ] │
├ Packer plugins (.WCX) ─────────────────────────────────────────────────────┤
│ Packer plugins are used to open archives not supported internally by       │
│ Total Commander.                                              [Configure]  │
├ File system plugins (.WFX) ────────────────────────────────────────────────┤
│ File system plugins allow access to disks inaccessible by Windows, e.g.    │
│ Linux file systems, or to external devices like Palm/PocketPC. [Configure] │
├ Lister plugins (.WLX) ─────────────────────────────────────────────────────┤
│ Lister plugins allow to display file formats like images, spreadsheets,    │
│ databases etc. in Lister (F3, Ctrl+Q)                         [Configure]  │
├ Content plugins (.WDX) ────────────────────────────────────────────────────┤
│ Content plugins allow to display extended file details like mp3 tags or    │
│ image attributes in file lists, or use them in search and rename tool.     │
│                                                               [Configure]  │
└────────────────────────────────────────────────────────────────────────────┘
```

| Button                    | Opens                                                                                                                                                |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Download**              | The default web browser on the plugins page of ghisler.com (plugins tested by the author; new ones are discussed in the plugins forum)               |
| Packer **Configure**      | The Associate dialog for packer plugins (§3.2). The Packer page's button _Configure packer extension WCXs_ leads to the same function (13 › Packer). |
| File system **Configure** | "File system plugins" (§3.3)                                                                                                                         |
| Lister **Configure**      | "Lister plugins" (§3.4); also reached from Configure Lister › _LS-Plugins_ (10)                                                                      |
| Content **Configure**     | "Content plugins" (§3.5)                                                                                                                             |

The help also lists an item "FS-Plugins" for installing file-system plugins; the 11.58 page has no separate control for
it beyond the file-system _Configure_ button.

### 3.1 Common behaviour of the list dialogs

- The three list dialogs share one layout: a label and list of installed plugins, then [Add] [Remove] [Rename] [OK]
  [Cancel]; the Lister and content dialogs also have [^] [v] to reorder.
- **Add** chooses a plugin file and appends it to the list. **Remove** takes the selected entry off the list (whether
  the files are deleted was not recorded; unverified that they are kept).
- **Rename** changes the name of a file-system plugin (its root name in Network Neighborhood). It was disabled in the
  observed Lister and content dialogs, whose plugins are stored by number.
- **OK** writes the list to `wincmd.ini` (§4); **Cancel** discards the changes.

### 3.2 Packer plugins: the Associate dialog

Layout as in §2.4 (the same dialog as Files › Associate With, see 10 › Associations).

| Control                                     | Behaviour                                                                                                                          |
| ------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| **All files with extension (ending with):** | Editable combo; the extension without `*.` (a leading dot does not matter). If it already has a plugin, the plugin is shown below. |
| **Associate with:**                         | Path of the `.wcx` to use for that extension                                                                                       |
| List                                        | `(none)` and the installed packer plugins                                                                                          |
| **New type...**                             | Browses for a plugin file (unverified for the packer variant; in the Windows-association variant it browses for a program)         |
| **Delete**                                  | Sets the extension to `(none)`, i.e. removes the plugin from that extension                                                        |
| **OK** / **Cancel** / **Help**              | Store / discard / help                                                                                                             |

Storage: one `[PackerPlugins]` line per extension (§4.1).

### 3.3 File system plugins

```text
File system plugins                                  ← title
Installed file system plugins:
┌────────────────────────────────────────────────────────────────────┐
│ Registry  -  %APPDATA%\GHISLER\plugins\wfx\registry\Registry.wfx   │
│ Secure FTP  -  …\wfx\sftpplug\sftpplug.wfx                         │
└────────────────────────────────────────────────────────────────────┘
[ Add ] [ Remove ] [ Rename ]                        [ OK ] [ Cancel ]
```

Each line is `<root name>  -  <path>`: two spaces, a dash, two spaces. The root name is the folder name shown in Network
Neighborhood (§7.1). No reorder buttons.

### 3.4 Lister plugins

"Lister plugins:" list, [^] [v], [Add] [Remove] [Rename] (disabled), [OK] [Cancel]. **The order matters:** Lister tries
the plugins in list order (§8). Besides [^] [v], **Shift+↑/↓** moves the selected plugin.

### 3.5 Content plugins

"Content plugins" list, [^] [v], [Add] [Remove] [Rename] (disabled), [OK] [Cancel]. The order is the order in which the
plugins appear in the plugin lists of §9.

_Basis: observed under Wine (page and empty dialogs) and on Windows 11 (dialogs with entries during auto-install); help:
dlg_configplugin, dlg_listerconfig, dlg_assotiate, dlg_configpack; change log._

---

## 4. Registration in `wincmd.ini`

The keys are listed in 19 › Plugin sections; their meaning for a clone:

### 4.1 Sections

| Section                                                                                 | Line format                                                    | Notes                                                                                                                                                                                         |
| --------------------------------------------------------------------------------------- | -------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `[PackerPlugins]`                                                                       | `<ext>=<flags>,<path>`, e.g. `bz2=27,c:\totalcmd\bzip2dll.dll` | One line per extension. `flags` is the sum of capability bits (§4.2); **TC computes it when it first loads the DLL**, and users must not enter it by hand.                                    |
| `[FileSystemPlugins]`                                                                   | `<name>=<path>`                                                | Stored by name; the name is the root folder in Network Neighborhood                                                                                                                           |
| `[ListerPlugins]`                                                                       | `<n>=<path>`, `<n>_detect=<detect string>`                     | 0-based, in list order. The detect string lets TC decide whether the plugin can handle a file **without loading the DLL**.                                                                    |
| `[ContentPlugins]`                                                                      | `<n>=<path>`, `<n>_detect=`, `<n>_flags=`, `<n>_date=`         | `_flags` caches what the plugin reported about its fields (`ContentGetSupportedFieldFlags`); `_date` is the DOS timestamp of the DLL the flags belong to, so they are re-read after an update |
| `[PackerPlugins64]`, `[FileSystemPlugins64]`, `[ListerPlugins64]`, `[ContentPlugins64]` | see §4.3                                                       | Cache of which plugins have a 64-bit build                                                                                                                                                    |
| `[ReplaceIniLocation]`                                                                  | `<plugin file.ext>=<ini file or dir\>`                         | §4.4                                                                                                                                                                                          |

- These sections always stay in `wincmd.ini`: `AlternateUserIni` does not move them (19 › Several ini files).
- Paths may contain environment variables, which are kept unexpanded (§2.3).

### 4.2 Packer capability flags

| Bit | Meaning                               | Effect in TC                                                                                              |
| --- | ------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| 1   | Can create new archives               | Without it the extension is not offered as a pack target                                                  |
| 2   | Can modify existing archives          | Without it no adding to the archive and no re-pack after F4                                               |
| 4   | Can hold several files in one archive | Without it: single-file mode; separate archives are forced, and `TAR.<ext>` chaining is possible          |
| 8   | Can delete files from an archive      | Without it F8 is unavailable inside the archive                                                           |
| 16  | Has an options dialog                 | _Configure_ in the Pack dialog (08)                                                                       |
| 32  | Supports packing in memory            | —                                                                                                         |
| 64  | Detects the archive type by content   | Archives are recognised by content as well as by extension (e.g. with Ctrl+PgDn on unusual extensions)    |
| 128 | Allows text search in archives        | Find Files can search text inside such archives; also used by compare by content in Synchronize dirs (09) |
| 256 | Do not open with Enter                | The archive opens only with Ctrl+PgDn                                                                     |
| 512 | Supports encryption                   | Offered for _Encrypt_ in the Pack dialog (08)                                                             |

Example: `27` = 1 + 2 + 8 + 16.

### 4.3 64-bit index sections

- `$checksum$=` is the Adler-32 checksum of the corresponding section without `64` in its name, read as a whole with
  `GetPrivateProfileSection`. When it no longer matches (plugins were added or removed), the `…64` section is rebuilt.
  Installing a plugin clears these sections (§2.5).
- `[PackerPlugins64]`: `exts=<extensions that have a 64-bit version>`. `[ContentPlugins64]`, `[ListerPlugins64]`:
  `<n>=1` per plugin index with a 64-bit version. `[FileSystemPlugins64]`: `<name>=1`.
- A fresh Windows 11 ini, before any plugin was installed, already held `[FileSystemPlugins64] $checksum$=3014672`, and
  `[ContentPlugins64]` and `[ListerPlugins64]` (the same checksum value was seen under Wine, with empty base sections).
- 64-bit plugins also work when `wincmd.ini` is read-only and these sections cannot be written.

### 4.4 Plugin ini files

TC tells each plugin the name of its own ini file. `[ReplaceIniLocation]` overrides that per plugin: the key is the
plugin's file name without path, with the extension as configured (e.g. `sftpplug.wfx`); the value is a new ini file or
a directory ending in `\` (the plugin may use only the path). Special values: `*` = the default name, redirected to the
user profile if that location is not writable (default for packer, file-system and Lister plugins); `-` = the default
name, never redirected (default for content plugins). `RestrictInterface` bit 8192 turns the redirection off (§5).

_Basis: help only (inisettings1–3), plus the observed fresh ini on Windows 11._

---

## 5. Policy and runtime control

| Setting or command                                    | Effect                                                                                                                                                                                                                  |
| ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `[Configuration] AutoInstallPlugins=0`                | No automatic installation on entering a plugin archive (§2.1)                                                                                                                                                           |
| `RestrictInterface` bit 256                           | Disables file-system plugins                                                                                                                                                                                            |
| `RestrictInterface` bit 2048                          | Only plugins signed by ghisler are allowed                                                                                                                                                                              |
| `RestrictInterface` bit 4096                          | Only plugins with a valid digital signature are allowed                                                                                                                                                                 |
| `RestrictInterface` 6144 (2048 + 4096)                | No plugins at all                                                                                                                                                                                                       |
| `RestrictInterface` bit 8192                          | Plugin ini files are not redirected to the user profile (§4.4)                                                                                                                                                          |
| `DllLoad=`                                            | DLL search method for plugins and Explorer extensions: `-1` never from the current directory (most secure); `0` (default) only for the context menu; `1` always also from the current directory (as TC 7.55a and older) |
| `cm_UnloadPlugins` (2913)                             | Parameter `0`: unload all plugin types except the tcmatch DLL; otherwise a sum: 1 packer, 2 file system, 4 Lister, 8 content, 16 external tcmatch DLL                                                                   |
| `DisconnectOnSuspend` bit 2                           | Disconnects all file-system plugins that have a Disconnect function when the PC suspends                                                                                                                                |
| `x64DisableRedirection=1`                             | Turns off the `system32` → `syswow64` redirection; can make plugins fail                                                                                                                                                |
| Log file, _Pack/Unpack/Test archives_                 | Includes packer-plugin operations                                                                                                                                                                                       |
| Log file, _File system plugins_ (`LogOptions` bit 64) | Logs all file-system plugin operations; not in the default `LogOptions=7198` (13 › Log file)                                                                                                                            |

- Packer plugins can pack and unpack in the background only if they were written to support it (07 › Background).
- The properties sheet of a file inside an archive names the packer plugin that opened the archive.

_Basis: help only (inisettings1, inisettings2, dlg_choosecommand, dlgconfiglogfile)._

---

## 6. Packer plugins in use

Archive handling in general is in 08; the plugin-specific rules:

- **Opening.** A file whose extension is registered in `[PackerPlugins]` opens like a folder with Enter or a
  double-click (when _Treat archives like directories_ is on), unless the plugin has flag 256, in which case only
  **Ctrl+PgDn** opens it. Ctrl+PgDn also opens archives with an unusual extension (08 › Archives as folders).
- **ZIP.** The internal unzip always takes precedence over a packer plugin for ZIP unless
  `[Packer] PluginOverrideZip=1`.
- **7z.** With `[Packer] 7zPreferPlugin=1` (_Prefer 7-Zip plugin if installed_ on the 7-Zip packer page) and one of the
  plugins _7zip_ or _Total7zip_ installed, entering a `.7z` uses the plugin; this also applies when Synchronize dirs
  adds files to a 7z archive. In the Pack dialog, "7-ZIP" chooses the internal packer (or `7zg.exe`) and the plugin
  entry "7z" chooses the plugin. The ZIP packer page's "7z" option calls `7zg.exe`/`7z.exe` to create ZIP files, not 7z
  archives (08 › Packer configuration).
- **Packing.** Plugins with flag 1 appear as packer choices in the Pack dialog (08 › Pack); flag 16 enables its
  _Configure_ button. `[Packer] DefPlugin=` remembers the last used packer plugin (e.g. `cab`), and `LastUsedPacker64=`
  the last packer in 64-bit TC, which is kept separately because not every packer plugin exists in 64-bit.
- **Effects of missing flags** (single-file mode, no F8, no re-pack): §4.2. A single-file plugin such as bzip2 packs one
  file per archive.
- **Encryption and SFX.** _Encrypt_ and _Create self-extracting archive_ in the Pack dialog also work with plugins that
  support them (e.g. SQX).
- **Search and compare.** Find Files searches inside plugin archives as folders; searching for text inside them needs
  flag 128, which Synchronize dirs also uses to compare by content (09).
- **Internal associations** can name a packer: `**ext` browses the file with the packer (plugin or internal) registered
  for extension `ext` (10 › Associations).
- **Viewing.** A file viewed from an archive and changed with a Lister plugin can be re-packed (§8).

_Basis: help only (packedfiles, dlg_pack, dlg_configpack, dlg_internal7zipconfig, dlg_internalzipconfig, inisettings3,
dialog_box__edit_file_type_internal); change log._

---

## 7. File-system plugins in use

### 7.1 Network Neighborhood

File-system plugins are reached through **Network Neighborhood** (Alt+F1 › `\`, path `\\Network\*.*`; 11 › Network
Neighborhood). Observed with two plugins installed:

```text
[Registry]               <DIR>     ← installed .wfx plugins, each with its own icon
[Secure FTP]             <DIR>
[Network (WORKGROUP)]    <DIR>
<Refresh>                <lnk>
```

### 7.2 Inside a plugin (Registry plugin)

- The path is `\\\<root name>\…` (three backslashes): `\\\Registry\*.*`, then e.g.
  `\\\Registry\HKEY_CURRENT_USER\AppEvents`.
- **Root:** `[HKEY_CLASSES_ROOT]`, `[HKEY_CURRENT_CONFIG]`, `[HKEY_CURRENT_USER]`, `[HKEY_LOCAL_MACHINE]`,
  `[HKEY_USERS]`, and the entries "Connect to remote registry" and "Search the entire registry".
- **Inside a key:** subkeys as folders with dates, plus the pseudo-entries "-Add Value-" and "-Search-".
- **Columns:** the plugin defines its own columns: Name, Ext, Type, Size, Date, Value.
- **Command line:** the prompt reads `\\\Registry\HKEY_CURRENT_USER\AppEvents>`. While a plugin path is active, a line
  typed on the command line goes to the plugin first; only if the plugin does not handle it does TC process it. With the
  SFTP plugin, lower-case `cd directory` is handled by the plugin and upper-case `CD directory` by TC; this depends on
  the plugin. With the Registry plugin, `cd c:\…` was **not** executed; the panel had to be switched to the drive with
  Alt+F1 › `c` first.

The Secure FTP plugin was installed but no connection was made with it.

### 7.3 Integration rules

| Area             | Rule                                                                                                                                                                                                                                                                                                                                                                       | Details             |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------- |
| Custom columns   | A plugin may offer its own column sets: Options › Custom columns › _Configure columns for file system_ lists `<General>` and the plugins that support it; _Switch to this view when using this plugin_ (`AutoLoad=1`); `[=<fs>.field]` addresses the plugin's own fields; stored in `[CustomFields_<PluginName>]`. The header context menu also offers the plugin's views. | 03 › Custom columns |
| FTP connect list | Since 11.50 a stored session's host may be `\\\Pluginname\Path`, so the list also serves as bookmarks                                                                                                                                                                                                                                                                      | 11                  |
| Passwords        | Plugins can store passwords under the FTP master password, in `[\|FSPlugin\|PluginName]` of `wcx_ftp.ini`                                                                                                                                                                                                                                                                  | 11                  |
| Disconnect       | Ctrl+Shift+F (`cm_FtpDisconnect`) also disconnects plugins that have a Disconnect function; `DisconnectOnSuspend` bit 2                                                                                                                                                                                                                                                    | 11                  |
| View / edit      | F3/F4 work on temporary copies; `AutoReUpload` decides how changed files are uploaded again                                                                                                                                                                                                                                                                                | 10                  |
| New file         | Shift+F4 creates an empty file in TEMP, opens the editor, and after saving asks whether to upload it                                                                                                                                                                                                                                                                       | 07 › New file       |
| Comments         | File comments (Ctrl+Z) are not available in plugins                                                                                                                                                                                                                                                                                                                        | 07 › File comments  |
| Content plugins  | Do not work inside file-system plugins                                                                                                                                                                                                                                                                                                                                     | §9.2                |
| Thumbnails       | Some file-system plugins support thumbnails; in virtual folders thumbnails cannot come from Lister plugins                                                                                                                                                                                                                                                                 | 03 › Thumbnails     |
| Find Files       | Start paths may be plugin paths; several paths must all belong to the same plugin                                                                                                                                                                                                                                                                                          | 09                  |
| Synchronize dirs | A local directory can be compared with a plugin directory; compare by content uses the plugin's checksum functions                                                                                                                                                                                                                                                         | 09                  |
| Parameters       | `%v` = the virtual name in plugins such as "virtual panel" (`%N` gives the real file it points to); `%V` = the same with the full path including the plugin name                                                                                                                                                                                                           | 18                  |
| Ignore list      | `*:filename` = in every file-system plugin; `pluginname:filename` = in one plugin                                                                                                                                                                                                                                                                                          | 13 › Ignore list    |
| Refresh          | `/` in the no-refresh drive lists stands for file-system plugins                                                                                                                                                                                                                                                                                                           | 13 › Refresh        |
| Icons            | Folder-tab icons (`DirTabIcons` bit 16) and history-list icons for plugin locations                                                                                                                                                                                                                                                                                        | 13                  |
| Breadcrumb       | Hover delay `BreadcrumbDelayPlugin=500`                                                                                                                                                                                                                                                                                                                                    | 03                  |
| Auto switch mode | Sub-rule `P` = a file-system plugin, e.g. `\\\Secure FTP\connection`                                                                                                                                                                                                                                                                                                       | 03 › View modes     |
| Policy           | `RestrictInterface` bit 256 disables them; log category 64                                                                                                                                                                                                                                                                                                                 | §5                  |

_Basis: observed on Windows 11 (Network Neighborhood, Registry plugin); help: plugins, add_cmdline,
dlg_configcustomcolumns, dlg_connectdetails, edit_comment, proc_editnew, show_thumbnails, dlg_configignorelist,
dlg_configrefresh, dlg_configautomodeswitch, dlg_configbuttonbar, inisettings1–3._

---

## 8. Lister plugins in use

The Lister itself is in 10; the plugin rules:

- **Choice of plugin.** With _Use plugins or load bitmaps as graphics at startup_ on (`BmpStartup=1`, Configure Lister ›
  Multimedia), F3 and Ctrl+Q try the Lister plugins in list order (§3.4); a plugin whose detect string rejects the file
  is skipped without being loaded. _Define view method by file type_ (`[ListerModes]`, method `<pluginname>`) can name a
  plugin per file type (10 › View methods by file type).
- **Plugins menu** in Lister, built per file in up to three sections: _Internal (no plugins)_ together with the plugins
  defined for this type in _Define view method by file type_; then the plugins whose detect string matches; then all
  other plugins. Choosing a plugin that cannot show the file changes nothing.
- **Key 4** cycles through the matching plugins and the internal multimedia view.
- **Without plugins:** Alt+Shift+F3 (`cm_ListInternalOnly` 1006, single file) and `cm_ListInternalMulti` 2933 open
  Lister with no plugins or multimedia; `cm_ListOnly` 2934 / `cm_ListMulti` 2935 allow them. Quick View has
  `cm_SrcQuickInternalOnly` (306; left 106, right 206) and `cm_SeparateQuickInternalOnly` 2942. In the overwrite dialog,
  Alt+F3 / Alt+Shift+F3 view the file without plugins.
- **Exclusions:** `[Lister] NoPluginFileTypes=` = these types are never opened with a plugin (the internal image viewer
  may still show them), except when mode 4 is chosen explicitly; `NoMediaFileTypes=` excludes them from video, audio,
  image and plugin display, with the same exception.
- **Command line:** `/S=L:P<name>` as the **last** sub-option chooses the plugin by the name shown in the Lister title,
  e.g. `/S=L:Piclview` (19 › Command-line switches).
- **Title and header.** A plugin view is titled `Lister (<plugin>) - [<path>]`; the Quick View header shows the file
  name followed by the plugin name.
- **F4** inside Lister is unavailable in plugin mode.
- **Archives.** A file viewed from an archive and modified with a Lister plugin can be re-packed into the archive when
  Lister closes (08).
- **Thumbnails.** _Get from Lister plugins for:_ (`ThumbOptions` bit 2, `ThumbPlgTypes=*.*`) extracts thumbnails through
  Lister plugins that support thumbnail extraction (older plugins may need an update); not in virtual folders (03 ›
  Thumbnails).

**Observed (Imagine).** After installation Imagine became the **default viewer for JPG**: title
`Lister (imagine) - [<path>]`, the plugin's own toolbar, and its status bar, e.g. "3/4 640 x 480 x 24 BPP JPEG - JFIF
Compliant … Exif … 100% … Load time: 0.04 seconds". The **Plugins** menu read `Internal (no plugins)` · `✓ Imagine`.
Choosing _Internal (no plugins)_ switched to the built-in image view: title `Lister - [<path>]`, zoom `100.0 %` at the
right of the menu bar.

_Basis: observed on Windows 11 (Imagine); help: lister_menuplugins, dlg_listerconfig, listercontents, proc_show,
quick_view, commandlineparameters, dlg_configthumbs, packedfiles, dlg_overwrite, inisettings3._

---

## 9. Content plugins in use

### 9.1 Where fields are used

Fields are written `[=plugin.field.unit]` (e.g. `[=tc.size.bkM2]`); the syntax, units and formatters are in 18 › Content
fields. Where content-plugin fields can be used, and the control that inserts one:

| Place                  | Control                                                                                                 | Storage                                    | Details             |
| ---------------------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------ | ------------------- |
| Custom columns         | `[+]` in the column editor                                                                              | `[CustomFields]`                           | 03 › Custom columns |
| Multi-Rename Tool      | `[=?] Plugin` button; `[?#-#]` in the `#` range menu                                                    | `[rename]` (field names stored in English) | 09                  |
| Find Files › Plugins   | Rule rows Plugin / Property / OP / Value                                                                | saved searches                             | 09; §9.3            |
| Find Files › General   | _Plugins:_ `[+]`: the _Find text_ is searched in the chosen fields (e.g. PDF text, comments)            | `[SearchCustomField]`                      | 09                  |
| Find Files › Advanced  | _Find duplicate files_ › _same plugin fields_                                                           | `[PluginDuplicates]`                       | 09                  |
| Synchronize dirs       | Plugin compare `[++]` / `[>>]` (content plugins decide equality)                                        | `[CompareCustomField]`                     | 09                  |
| Change attributes      | _Change plugin attributes_ (only writable properties; `+` reads a value from another field)             | `[attrplugin]`                             | 07                  |
| Overwrite dialog       | _Custom fields_ `+`                                                                                     | `[OverwriteCustomField]`                   | 07                  |
| File tooltips          | Display page, _User-defined_ `[+]`, per file type                                                       | `[HintsCustomField]`                       | 03                  |
| Thumbnails             | _Show custom fields below thumbnails_ `Add...`; _Fields by type_                                        | `[ThumbsCustomField]`                      | 03                  |
| Copy filter, selection | A saved search with plugin rules, used as a copy filter (F5 › `+ F8`) or as a predefined selection type | —                                          | 07, 03              |

### 9.2 Restrictions

- Content plugins work only on the **normal file system** (files and directories), not in virtual folders such as the
  Desktop, on FTP connections, on files inside archives, or inside file-system plugins. The Multi-Rename Tool does not
  preview plugin fields in virtual folders.
- Slow fields can be loaded on demand: `cm_LoadAllOnDemandFields`, `cm_LoadSelOnDemandFields`,
  `cm_ContentStopLoadFields` (03).
- Characters that are invalid in file names and come from plugin fields are replaced in the Multi-Rename Tool (e.g. `:`
  → `.`) unless `MrtReplacePluginChars=0`.
- A missing plugin gives an error; in 64-bit TC a field of a plugin found only as 32-bit shows `<?>` (§1.3).

### 9.3 Find Files › Plugins with a real plugin

The page itself is described in 09 › Find Files. Observed with the Exif plugin installed:

```text
[x] Search in plugins      Combine with: (o) AND (all match)   ( ) OR (any match)
Plugin:        Property:              OP:            Value:
[exif     ▾]   [Make             ▾]   [contains ▾]   [TestCam            ]
[ More rules ] [ Fewer rules ]
```

- **Plugin** offered `tc` and `exif`.
- **Property** listed the plugin's fields: Width, Height, BitsPerSample, DateTimeStr, Date, Time, DateOriginal, …, Make,
  Model, Orientation, ImageDescription, UserComment, ….
- **OP** for string fields: contains · !contains · cont.(case) · !cont.(case) · = · != · =(case) · !=(case) · regex ·
  !regex. Numeric fields default to `>`.
- The search _Make contains "TestCam"_ found exactly `photo_exif.jpg`, the one sandbox JPG with that camera make.

### 9.4 The _Choose plugin property_ dialog

Opened by the controls in §9.1 (`[=?]`, `[+]`, `Add...`). It picks a field of an installed content plugin, or of `tc`.

```text
Plugins:          Properties:
┌─────────────┐  ┌──────────────────────────────────────────────────┐
│ All plugins │  │ ==== tc ====                                     │
│ tc          │  │ Ab fullname      Ab name       Ab ext   …        │
│ exif        │  │ #  size ▸ (units)   1.1.2000 creationdate ▸ …    │
└─────────────┘  └──────────────────────────────────────────────────┘
Filter: [______]   <preview of the field for the current file>    [ OK ] [ Cancel ]
```

| Element         | Behaviour                                                                                                                                                                        |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Plugins:**    | _All plugins_, `tc`, then the installed content plugins. In _All plugins_ each plugin starts with a node `==== name ====`.                                                       |
| **Properties:** | The fields of the chosen plugin, each with a type symbol (below). Fields that offer units or display formats are expandable nodes listing them (units: 18 › Content fields).     |
| **Filter:**     | Shows only properties containing the typed word, live                                                                                                                            |
| Preview         | Behind the filter: the value of the selected field for the current file (with a name field, the file name)                                                                       |
| **OK**          | Inserts the choice: as `[=plugin.field.unit]` (e.g. `[=tc.size.bkM2]`) in rename masks, custom columns and field lists; as the plugin/property pair in search and attribute rows |

| Symbol     | Field type           |
| ---------- | -------------------- |
| `Ab`       | Text                 |
| `#`        | Numeric              |
| `1.1.2000` | Date                 |
| `12:35`    | Time                 |
| `1/0`      | Boolean (true/false) |
| `1 2 3`    | Multiple choice      |

Its position is saved as `PluginSel*` in the resolution section.

_Basis: observed on Windows 11 (Exif in Find Files) and under Wine (Choose plugin property with `tc`); help: plugins,
dlg_searchplugins, dlg_choosepluginfield, dialog_usercolumns, dialog_box___multi_rename_tool, dlg_advancedsearch,
dlg_synchronize_dirs, dlg_attrib, dlg_overwrite, dlg_display, dlg_configthumbs, inisettings1, inisettings3._

---

## 10. Plugins in the test installation

Official archives from plugins.ghisler.com / totalcommander.ch, opened with Enter on Windows 11 (test setup: Appendix
B).

| Archive                   | Plugin            | Type                                           | Result                                                                                                                      |
| ------------------------- | ----------------- | ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `wlx_imagine_x64.zip`     | Imagine           | Lister (archive also holds `.wcx64`, `.wdx64`) | Installed after redirecting from the program folder to `%APPDATA%\GHISLER\plugins\wlx\Imagine`; default viewer for JPG (§8) |
| `iso_plugin.zip`          | ISO               | Packer                                         | Installed to `%APPDATA%\GHISLER\plugins\wcx\iso`; Associate dialog for `iso`, then `img` (§2.4)                             |
| `wfx_registry.zip`        | Registry          | File system                                    | Installed; browsed in Network Neighborhood (§7.2)                                                                           |
| `sftpplug.zip`            | Secure FTP        | File system                                    | Installed (`…\wfx\sftpplug\sftpplug.wfx`); not connected                                                                    |
| `wdx_exif.zip`            | Exif              | Content                                        | Installed to `…\wdx\wdx_exif`; used in Find Files (§9.3)                                                                    |
| `wcx_xz12.zip`            | xz                | Packer                                         | Downloaded; installation not recorded                                                                                       |
| `wdx_NTFSFileStreams.zip` | NTFS File Streams | Content                                        | Downloaded; installation not recorded                                                                                       |

State after a successful install: files unpacked to `…\plugins\<type>\<name>`, the plugin registered in its `wincmd.ini`
section. A failed install into the program folder writes nothing.

_Basis: observed on Windows 11._
