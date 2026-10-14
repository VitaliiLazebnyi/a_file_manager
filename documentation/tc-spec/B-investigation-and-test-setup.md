# Appendix B: Investigation and test setup

This appendix describes how the facts in this specification were gathered: the sources, the phases of the investigation,
the two hosts and their sandbox folders, the safety rules and their side effects, the test tools, and the conventions
that show where each statement comes from. It helps a reader judge how firm a statement is; nothing in it is needed to
build a clone.

**Related:** [Appendix A](A-host-differences.md) (what was host-specific), [Appendix C](C-change-log.md) (corrections
between editions), [README](README.md) (conventions and known gaps).

## 1. Sources

| Source                                                          | What it is                                                                                                                                                                                          | Used for                                                 |
| --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| The running program                                             | Total Commander (x64) 11.58, released 2026-07-01, © 1993-2026 Christian Ghisler; unregistered evaluation copy ("NOT REGISTERED" in the title)                                                       | Captions, layouts, defaults, observed behaviour          |
| The help                                                        | The program's help file `TOTALCMD.CHM`, converted to one text file per topic (213 topics). Cited by topic name, e.g. _help: dlg_pack_                                                               | Documented behaviour, option semantics, ini keys, limits |
| `KEYBOARD.TXT`                                                  | The program's plain-text key list                                                                                                                                                                   | Keyboard reference (06)                                  |
| `TOTALCMD.INC`                                                  | All 594 internal commands with their numbers                                                                                                                                                        | Internal commands (17)                                   |
| `LANGUAGE\WCMD_ENG.MNU` and the other language files            | Main-menu definition; translations of all 18 bundled languages                                                                                                                                      | Main menu (04), localisation (16)                        |
| `wincmd.ini` of the Wine session, `DEFAULT.BAR`, `VERTICAL.BAR` | Real settings and button-bar files                                                                                                                                                                  | Settings files (19), button bars (02, 14)                |
| `HISTORY.TXT`                                                   | The program's change log                                                                                                                                                                            | Only where no other source covers a point                |
| Raw notes                                                       | Notes written during the sessions: on-screen exploration under Wine (menus, main window, context menus, options, commands, dialogs, keyboard), sandbox tests under Wine, and the Windows 11 session | Checking and filling gaps                                |

_Basis: help file and program data files as listed._

## 2. Phases

1. **On-screen exploration under Wine** (2026-10-10/11). Every menu, submenu, context menu, toolbar, dialog and settings
   page was opened, recorded and closed again without confirming anything. This produced the first edition's
   user-interface reference.
2. **Help and data files.** The help, `KEYBOARD.TXT`, `TOTALCMD.INC`, the menu and language files and the shipped
   settings files were read. This produced the first edition's logic chapters, the internal-command catalogue, the
   syntax and settings references, and the extracted translations (`translations/`).
3. **Sandbox tests under Wine** (2026-10-11). Operations were confirmed for real inside a throw-away folder (§5):
   follow-up prompts, progress windows, files written (inspected down to byte level where useful) and panel state
   afterwards.
4. **Tests on real Windows 11** (2026-10-11). The host-dependent tests were repeated in an isolated virtual machine
   (§6), and the areas Wine could not show were added: Alt keys, the Windows shell, recycle bin, elevation, long paths,
   FTP and FTPS against a local server, all four plugin types, thumbnails, printing, drag & drop with Explorer, network
   shares and NTFS permissions.
5. **Consolidation** (this edition). Every topic is described once, with the corrections of all layers applied (Appendix
   C) and host-specific findings moved to Appendix A.

_Basis: investigation records._

## 3. Host 1: CrossOver on macOS

|                  |                                                                                                                                                                                                                                                                                                        |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Host             | macOS on Apple Silicon → CrossOver 26.3 → bottle "TotalCommander" (Windows 10 type). System Information reported "Wine: Windows 10 Professional", `10.0 (Build 19045)`, CPU `VirtualApple @ 2.50GHz`, display driver `Apple M4 Max`, display `1728x1117x16m (32 bit)`, 128 GB RAM, computer name `MAC` |
| Display          | 96 DPI                                                                                                                                                                                                                                                                                                 |
| Program          | `C:\Program Files\totalcmd\totalcmd64.exe`                                                                                                                                                                                                                                                             |
| Settings         | `C:\users\crossover\AppData\Roaming\GHISLER\wincmd.ini` and `…\wcx_ftp.ini` (Windows user `crossover`)                                                                                                                                                                                                 |
| Drives           | `c` (the bottle's drive C), `y` (the Mac home folder, so `~/tc-sandbox` appeared as `Y:\tc-sandbox`), `z`                                                                                                                                                                                              |
| Temporary folder | `c:\users\crossover\AppData\Local\Temp`                                                                                                                                                                                                                                                                |
| Clock            | The bottle ran at UTC+9                                                                                                                                                                                                                                                                                |
| Input limits     | No Alt key, some Ctrl combinations taken by macOS, no modifier-only events (Appendix A › Keys the host intercepted)                                                                                                                                                                                    |

_Basis: observed under Wine._

## 4. Safety rules

### 4.1 On-screen exploration

- Every dialog was left with **Cancel**, **Close** or **Esc**.
- Configuration was always cancelled; no setting was saved.
- Dialogs that would touch the network or the system were **not opened at all** under Wine: the Windows network and
  share dialogs (Network Connections, Disconnect, Share, Unshare, Show Admin Shares), Print, the update check and the
  command prompt. No FTP connection was opened under Wine; the FTP dialogs were shown and cancelled.

### 4.2 Sandbox tests under Wine

- Every confirmed operation (copy, move, rename, delete, pack, unpack, split, combine, encode, decode, checksums,
  multi-rename, synchronize and so on) had its source **and** target inside `Y:\tc-sandbox`.
- Deletions were permanent deletions (Shift+F8) inside the sandbox, so nothing went to the system Trash.
- Commands that would write outside the sandbox were avoided: building the directory-tree cache on the home drive,
  changing the hotlist, Save Settings, launching editors.

### 4.3 Tests on Windows 11

- The VM was **isolated**: its network was set to _Disconnected_, and folder, cloud/volume and printer sharing with the
  Mac were turned off after TC was installed.
- The network was switched on only to download TC, Python with its packages and the official plugins, and disconnected
  again before any test.
- Every confirmed operation used `C:\tc-sandbox` inside the VM.
- The FTP tests used a local server bound to **127.0.0.1 only** (§7.1).
- Network functions used only the VM's own shares (`\\localhost`, including its admin share `C$`).
- Printing went to _Microsoft Print to PDF_; the PDF was saved in the sandbox.
- `wincmd.ini` was backed up before any setting was changed.

### 4.4 Writes and side effects outside the sandboxes

Under Wine (all harmless):

- _Configuration › Dark<->Normal_ was clicked once by mistake and toggled straight back.
- An Alt+Enter arrived as Enter and opened the bottle's dummy `C:\windows\win.ini` in Wine Notepad; nothing was edited.
- Viewing files inside archives and running the Multi-Rename Tool made TC write its usual temporary files
  (`%TEMP%\_tc\…`, `renlog.txt`) inside the bottle.
- TC updated its own history sections in `wincmd.ini` (folder history, search and rename history) as part of normal use.

On Windows 11:

- the TC installation, and Python with its packages (per user);
- TC's settings folder `%APPDATA%\GHISLER`: the first-start files, the installed plugins under
  `%APPDATA%\GHISLER\plugins` and their registration, the saved FTP sessions, and the settings changes that were tested
  live;
- the directory-tree cache `%LOCALAPPDATA%\GHISLER\treeinfoC.wc`;
- TC's temporary files in `%TEMP%` (`_tc\`, `FTP2A7A.tmp`);
- a temporary drive mapping `Z:`, removed again.

Attempts that wrote nothing: a copy into `C:\Program Files\` (aborted at the access-denied prompt), and the first plugin
installation into the program folder ("Directory … not created!"). Dark mode was switched on and straight back off. The
Windows Defender Firewall prompt was cancelled.

_Basis: investigation records._

## 5. The Wine sandbox

A dummy folder `~/tc-sandbox` on the Mac, filled with generated test data, seen in TC as **`Y:\tc-sandbox`** (TC writes
the path in lower case, `y:\tc-sandbox\…`).

| Folder | Content and use                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `A`    | Source side. `docs` with 13 test files (`A very long…`, `config.ini`, `data.csv`, `multi.dot…`, `no_extension`, `notes.md`, `readme.html`, `report_01.txt` …; several contain "Lorem" text); `photos`; `bin\random_1MB.bin` (1,048,576 bytes); `dups` with duplicate files (`copy1.txt` …) and `sub\`; `deep\level1\level2\level3\`; `readonly.txt` (read-only); `.hidden_file.txt`; an empty folder `empty_dir2` and folders holding only a `.keep` file |
| `B`    | Target side. `docs` with deliberate conflicts: `report_0N.txt` of different ages (e.g. `report_03` newer on the right), `only_in_B`                                                                                                                                                                                                                                                                                                                       |
| `C`    | Archive tests: `corrupt.zip` (3 entries, e.g. `inside\hello.txt`), `sample.tar.gz` (a 40,960-byte tar inside)                                                                                                                                                                                                                                                                                                                                             |
| `work` | Scratch area for new folders, renames, deletes, attributes, packing, encode/decode (`encoded.b64`, a MIME file naming `decoded.txt`), comments; `photos\IMG_1001.jpg` … `IMG_1008.jpg` for the Multi-Rename Tool                                                                                                                                                                                                                                          |

_Basis: observed under Wine._

## 6. The Windows 11 virtual machine

|                 |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Host            | Parallels Desktop 27 on the Mac, VM "Windows 11"                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Windows         | Windows 11 26H2, build 26300, ARM64; TC 64-bit runs under x64 emulation                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| Display         | Scaling 200 % (DPI 192)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| Windows user    | `cm0k`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Program         | `tcmd1158x64.exe`, downloaded from totalcommander.ch inside the VM and installed to `C:\Program Files\totalcmd` (Start-menu shortcuts created, desktop shortcut unticked; settings in _Application data_, i.e. `%APPDATA%\GHISLER`)                                                                                                                                                                                                                                                                                                                                                                                                         |
| Sandbox         | `C:\tc-sandbox`, created with a PowerShell script (`make.ps1`). Sub-folders `A`, `B`, `work` and `ftproot`. Test objects included `B\locked_target` (a folder with an NTFS ACL _deny_), a path longer than 260 characters holding `long_path_file.txt`, `A\hidden.txt` (Hidden attribute), `.hidden_dot.txt` (dot name, no attribute), `readme.html` with an explicit ACE `BUILTIN\Guests:(R)`, `notes.md` with a 13-byte alternate data stream `notes.md:extra`, `A\images\` with `red.png`, `green.png`, `blue.png` and `photo_exif.jpg` (Exif _Make_ "TestCam"), and a file meant to have a non-ASCII name (`utf8_…txt`, see Appendix A) |
| FTP root        | `C:\tc-sandbox\ftproot`, served by the local FTP servers (e.g. `pub\report_01.txt`, `docs`, `random_1MB.bin`, `.hidden_on_server.txt`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Network targets | Only the VM itself: `\\localhost\c$\tc-sandbox`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Date            | 2026-10-11                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |

_Basis: observed on Windows 11._

## 7. Test tools

### 7.1 Local FTP and FTPS servers

|               | Plain FTP                                                                                                                                                         | FTPS                                                                                             |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Address       | `127.0.0.1:2121`                                                                                                                                                  | `127.0.0.1:2122`                                                                                 |
| Security      | none                                                                                                                                                              | explicit TLS (`AUTH TLS`), self-signed certificate, CN=localhost, Organisation "tc-sandbox test" |
| Login         | anonymous, full write rights to `C:\tc-sandbox\ftproot`                                                                                                           | the same                                                                                         |
| Passive ports | 60000–60099                                                                                                                                                       | 60000–60099                                                                                      |
| Software      | pyftpdlib 2.2.0 under Python 3.12.7 x64 (python.org, per-user silent install), with pyOpenSSL 26.4.0 and cryptography 50.0.2; Pillow 12.3.0 was installed as well |                                                                                                  |

The servers listened on the loopback address only, with the VM network disconnected.

### 7.2 Plugins

Official archives from plugins.ghisler.com / totalcommander.ch, installed through TC's own auto-install (15):

| Archive                   | Type                 | Plugin            | Used                                    |
| ------------------------- | -------------------- | ----------------- | --------------------------------------- |
| `iso_plugin.zip`          | packer (`.wcx`)      | ISO               | Installed, associations `iso` and `img` |
| `wcx_xz12.zip`            | packer (`.wcx`)      | XZ                | Downloaded (no result recorded)         |
| `wfx_registry.zip`        | file system (`.wfx`) | Registry          | Installed and browsed                   |
| `sftpplug.zip`            | file system (`.wfx`) | Secure FTP        | Installed, never connected              |
| `wlx_imagine_x64.zip`     | Lister (`.wlx`)      | Imagine           | Installed, default JPG viewer           |
| `wdx_exif.zip`            | content (`.wdx`)     | Exif              | Installed, used in Find Files           |
| `wdx_NTFSFileStreams.zip` | content (`.wdx`)     | NTFS file streams | Downloaded (no result recorded)         |

### 7.3 Other aids

- `icacls` to read the ACLs of copied files.
- _Microsoft Print to PDF_ as the printer.
- The VM's own shares (`\\localhost`, `C$`) and a temporary mapping to `Z:` for the network functions.

_Basis: observed on Windows 11._

## 8. Provenance conventions of this edition

### 8.1 The _Basis_ line

Each `##` section of a chapter ends with one line in italics naming where its facts come from, for example _Basis:
observed on Windows 11 and under Wine; help: proc_copy, dlg_overwrite._

| Wording                                                                     | Meaning                                                         |
| --------------------------------------------------------------------------- | --------------------------------------------------------------- |
| observed on Windows 11                                                      | Seen in the Windows 11 session (§6)                             |
| observed under Wine                                                         | Seen in the sandbox tests or on screen under CrossOver (§3, §5) |
| help: `<topic>`                                                             | Taken from that topic of the program's help                     |
| help only                                                                   | Nothing in the section was observed; it rests on the help       |
| `HISTORY.TXT`                                                               | Taken from the program's change log                             |
| `KEYBOARD.TXT`, `WCMD_ENG.MNU`, `TOTALCMD.INC`, `DEFAULT.BAR`, `wincmd.ini` | Taken from that program data file                               |

Inline, only genuinely uncertain points are marked:

- **(unverified)**: plausible, but no source confirms it;
- **(not recorded)**: the case was seen, but this detail was not written down;
- **(depends on DPI/font; see Appendix A)**: the Windows 11 value is given; it changes with DPI and fonts.

Host artefacts (Wine/CrossOver and test-setup effects) do not appear in the topical chapters; Appendix A collects them.

### 8.2 Precedence when sources disagree

1. Observed on real Windows 11.
2. Observed in the hands-on sandbox tests under Wine, unless it is a Wine artefact.
3. Observed on screen under Wine, unless it depends on DPI, fonts or the host.
4. The program's help.
5. The change log (`HISTORY.TXT`), only where nothing else covers a point.

A lower-ranked source still contributes every detail it adds that no higher-ranked source contradicts.

### 8.3 Other conventions

- **Defaults** are the values of a fresh installation: one first start, no user changes.
- Text in quotation marks is the exact on-screen wording, including capitalisation and punctuation. English UI strings
  are built into the executable and are given as seen; translations come from the bundled language files.
- Dates, times and sizes in examples are those of the test hosts and their sandboxes.
- The first edition marked facts inline as _(observed)_, _(documented)_, _(help: topic)_, _(HIST)_ or _(inferred)_,
  added patch notes such as "(observed, see 22 §2.8)", and ended several chapters with "Corrections to existing
  chapters". This edition replaces these with the _Basis_ lines above and the change log in Appendix C.

_Basis: editorial conventions of this edition._
