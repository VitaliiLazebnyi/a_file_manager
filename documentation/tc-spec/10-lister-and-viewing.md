# 10: Lister, viewing and editing

This chapter covers how Total Commander shows and edits files. It describes the F3 / F4 / Shift+F4 commands and how they
pick a program, then the internal viewer Lister in full: window, menus, all display modes, start-up detection, fonts and
encodings, keys, search, context menu, image and media modes, Lister plugins, printing and the Configure Lister dialog.
The last sections cover the two association systems: Windows associations, and TC-only internal associations. Between
them they decide what Enter, Alt+F3 and the file context menu start.

**Related:** 03 (Quick View panel, separate tree), 05 (file context menu, "View (Lister)"), 06 (key reference), 07 (file
operations, long paths), 08 (archives as folders, temporary extraction), 11 (FTP temporary files), 13 (Configuration ›
Edit/View and Color pages), 15 (installing and managing Lister plugins), 17 (cm_List… and cm_Edit parameters), 18
(placeholders, RegEx dialect), 19 (`[Lister]`, `[ListerModes]`, `[Associations]`, `[Extensions]` keys; `/S=L` switch).

## 1. Entry points for viewing and editing

### 1.1 Keys and commands

| Key                 | Command                                                                              | What opens                                                                                                                                                                                                                  |
| ------------------- | ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| F3                  | `cm_List` (903)                                                                      | As set by `[Configuration] Viewertype`: `0` = Lister with the file under the cursor; `1` (default) = Lister with the selected files; `2` = external viewer. The F3 button of the function-key bar follows the same setting. |
| Shift+F3            | —                                                                                    | Lister with the other internal method. With the default setting, F3 shows the selected files and Shift+F3 only the file under the cursor. Several files can be shown only by the internal viewer.                           |
| Alt+F3              | —                                                                                    | The alternative viewer: the external viewer when F3 is internal, Lister when F3 is external (§1.4).                                                                                                                         |
| Alt+Shift+F3        | `cm_ListInternalOnly` (1006)                                                         | Lister with **no plugins and no multimedia**, file under the cursor.                                                                                                                                                        |
| —                   | `cm_ListInternalMulti` (2933)                                                        | The same for the selected files.                                                                                                                                                                                            |
| —                   | `cm_ListOnly` (2934) / `cm_ListMulti` (2935)                                         | Lister with plugins and multimedia: single file / selected files.                                                                                                                                                           |
| —                   | `cm_ListExternal` (3026)                                                             | External viewer; accepts one optional file name.                                                                                                                                                                            |
| F4                  | `cm_Edit` (904)                                                                      | The editor with the file under the cursor (§15).                                                                                                                                                                            |
| Shift+F4            | `cm_EditNewFile` (2931)                                                              | Asks for a name, creates the file, opens the editor (§16).                                                                                                                                                                  |
| Enter, double click | —                                                                                    | The associated program (§17).                                                                                                                                                                                               |
| Ctrl+Q              | `cm_SrcQuickView` (304); `cm_SrcQuickInternalOnly` (306) without plugins             | Lister embedded in the other panel (§2.6).                                                                                                                                                                                  |
| Ctrl+Shift+Q        | `cm_SeparateQuickView` (2941); `cm_SeparateQuickInternalOnly` (2942) without plugins | A separate Lister window that follows the panel cursor (§2.6).                                                                                                                                                              |

With no selection, the "selected files" methods use the file under the cursor. F3 also works on a **folder**. That is
useful only with Lister plugins that accept folders; what Lister shows for a folder without such a plugin was not
recorded.

### 1.2 Choosing the F3 method (Configuration › Edit/View)

The page layout is in 13 › Edit/View. Its controls have these effects:

| Control                                                         | Default         | Effect                                                                                                                                  |
| --------------------------------------------------------------- | --------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| [Configure internal viewer...]                                  | —               | Opens "Configure Lister" (§14).                                                                                                         |
| External viewer `[none] [>>]`                                   | `none`          | `[Configuration] Viewer=`. The viewer used for Alt+F3 when no per-extension viewer is set. `none` (or empty) means the internal viewer. |
| [Associations...]                                               | —               | Per-extension viewers for Alt+F3, edited in the Associate dialog layout and stored in `wincmd.ini [Extensions]` (§17.4).                |
| Hotkeys › Internal Viewer with file under cursor `[Shift+F3 ▾]` | Shift+F3        | Chooses which key opens Lister with the file under the cursor (other combo entries not recorded).                                       |
| Hotkeys › Internal viewer with selected files                   | F3 (static)     | The other of F3 / Shift+F3. With n and p the user steps through these files.                                                            |
| Hotkeys › External viewer                                       | Alt+F3 (static) | —                                                                                                                                       |
| Editor for F4 `[notepad.exe] [>>]`                              | `notepad.exe`   | `[Configuration] Editor=` (§15.1).                                                                                                      |
| [ ] Plugins/FTP: Automatically re-upload changed files          | off             | `AutoReUpload` (§15.4).                                                                                                                 |

`Viewertype=2` (external viewer on F3) is a documented value. The control that sets it was not recorded.

### 1.3 Other ways to open Lister

- The default vertical button bar has a `cm_List` button ("View with Lister"; 02 › Button bars).
- The Windows file and folder context menus carry TC's item "View (Lister)" (05 › File and folder context menu).
- Find Files results: [F3 View] (09 › Find Files).
- Synchronize dirs: View left `F3` / View right `Shift+F3` (09 › Synchronize directories).
- Multi-Rename Tool › _Result list_ opens Lister on `%TEMP%\_tc\renlog.txt` (09 › Multi-Rename Tool).
- Alt+Enter on an FTP panel opens Lister with the raw server listing from a temporary file such as `%TEMP%\FTP2A7A.tmp`
  (11 › Listing: MLSD or LIST, hidden files, raw listing).
- `cm_List <file>` (e.g. `cm_List c:\windows\wincmd.ini`) always opens that file. `cm_List`, `cm_ListOnly` and
  `cm_ListInternalOnly` take the `/S=L` options (below) before the name, written with a leading slash and without
  `S=L:`, e.g. `cm_List /T1V file_name` for text mode with the variable-width font. `cm_ListMulti` and
  `cm_ListInternalMulti` accept options plus at most one file name (17 › Commands with parameters).
- Command line `totalcmd.exe /S=L <full path>` starts a separate Lister. An HTML file may carry a bookmark
  (`c:\test\test.html#bookmark`). Options follow after a colon, e.g. `/S=L:AT1C1250` (19 › Command-line switches):

  | Option          | Meaning                                                                                   |
  | --------------- | ----------------------------------------------------------------------------------------- |
  | `A` / `S` / `V` | ANSI / ASCII (DOS) / variable-width text                                                  |
  | `F`             | Full screen (as Alt+Enter)                                                                |
  | `T1`…`T8`       | View mode 1–8 (§3)                                                                        |
  | `C<nr>`         | Codepage, e.g. `C1251`                                                                    |
  | `N`             | Auto-detect, but no multimedia and no plugins                                             |
  | `P<x>`          | As the **last** option: use plugin `x` as named in the Lister title, e.g. `/S=L:Piclview` |

### 1.4 External viewer (Alt+F3) and viewer associations

When the external viewer is called (Alt+F3, or F3 with `Viewertype=2`), TC chooses the program as follows (order as
documented):

1. The viewer associated with the file's extension in `[Extensions]` (Edit/View › Associations..., §17.4).
2. If there is none, the Windows quick-view handler.
3. If there is no quick-view handler either, the default viewer `Viewer=`. With `Viewer=none` (the default), the
   internal viewer is used.

The external viewer gets only one file. Several files are possible only in Lister.

### 1.5 Files that are not plain local files

- **Archive members** (F3 in an archive opened as a folder) are unpacked first to `%TEMP%\_tc\`. If `TEMP` does not
  exist, the TC program directory is used instead. Lister then shows the copy, and its title shows the temporary path,
  e.g. `Lister - [<TEMP>\_tc\report_01.txt]`. The `_tc` folder is removed when TC exits, if it is empty. Nested
  archives: 08 › Archives as folders.
- **FTP and file-system plugins:** F3 downloads the file to `%TEMP%\_tc\` and opens the copy. On FTP the log box shows
  the transfer line, e.g.
  `Copied (<date time>): ftp://127.0.0.1:2121/pub/report_01.txt -> <TEMP>\_tc\report_01.txt 300 bytes, 17 kbytes/s` (11
  › Editing and viewing remote files).
- A temporary copy can be kept with Lister's File › _Save as..._ (§2.3). F4 inside Lister is disabled for temporary
  files (§13).
- **Desktop folder** (`cm_OpenDesktop`): viewing and editing do not work there (12 › Miscellaneous commands).
- **Long paths** (more than 260 characters): F3 opens the file, and the Lister title shows the full path, cut off by the
  window width.

_Basis: observed on Windows 11 and under Wine (keys, Edit/View page, temporary copies); help: proc_show, dlg_configedit,
keyboard, dlg_choosecommand, commandlineparameters, lister_menufile, options_open_desktop, inisettings1–3, whats_new,
what_s_new_continued; KEYBOARD.TXT; inc.txt. The Alt+F3 order (§1.4) is help only._

## 2. The Lister window

### 2.1 Window model

- Lister is a separate top-level window. Any number of Lister windows can be open at once; the only limit is memory. All
  of them close when TC exits.
- **File size:** up to 2^63 bytes. The text, binary, hex, HTML and Unicode modes **stream** the file: only the visible
  part plus a buffer is held in memory, and more is read while scrolling. Bitmaps are the exception: an image is loaded
  completely.
- **Close:** Esc, Alt+F4, F10 or Q.

### 2.2 Title bar

| Situation                                | Title                                                                                                                                                                                                        |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Normal                                   | `Lister - [<full path>]`, e.g. `Lister - [c:\windows\win.ini]`. The drive letter was lower case in every recorded title; its case follows `DrivesShowUpcase` (default -1, 02 › Drive icons and letter case). |
| Explorer preview handler in use (mode 8) | contains `<Explorer>` (not when the thumbnail-provider fallback is used)                                                                                                                                     |
| Media file with tag data                 | Track name and artist                                                                                                                                                                                        |
| Separate quick view (Ctrl+Shift+Q)       | `Lister*`: an asterisk after "Lister"                                                                                                                                                                        |
| A Lister plugin shows the file           | `Lister (<plugin>) - [<path>]`, e.g. `Lister (imagine) - [<path>]`                                                                                                                                           |

The title is also updated when n / p move to a file that cannot be read.

### 2.3 Menu bar

```text
Lister - [c:\windows\win.ini]                                      [_][□][X]
File  Edit  Options  Plugins  Encoding  Help              << 1/3 >>   100 %
┌──────────────────────────────────────────────────────────────────────────┐
│[mail]                                                                    │
│mapi=1                                                                    │
│...                                                                       │
└──────────────────────────────────────────────────────────────────────────┘
```

`<< 1/3 >>` (previous · position / count · next) appears only when several files were opened. The percent item `100 %`
stands at the far right (§2.5).

| Menu     | Items (shortcut)                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| File     | Open... · Save as... · Next File `N` · Previous `P` · Print... `Ctrl+P` · Print setup... · Reload file `F2` · ──── · Close `Esc`                                                                                                                                                                                                                                                                                                                              |
| Edit     | Copy as text `Ctrl+C` · Select all `Ctrl+A` · ──── · Find `F7` · Find next `F5`                                                                                                                                                                                                                                                                                                                                                                               |
| Options  | 1 Text only `1` · 2 Binary (fixed line length) `2` · 3 Hex `3` · 4 Image/Multimedia `4` · 5 HTML text (strip tags) `5` · 6 Unicode `6` · 7 UTF-8 `7` · 8 Explorer Preview `8` · ──── · ANSI (Windows charset) `A` · ASCII (DOS Charset) `S` · Variable char width `V` · ──── · Wrap text `W` · Show text cursor `F6` · ──── · Fit image to window `F` · Fit only larger images to window `L` · Center images `C` · ──── · Configure... · ──── · Save position |
| Plugins  | Internal (no plugins) · the Lister plugins (§11.1)                                                                                                                                                                                                                                                                                                                                                                                                            |
| Encoding | As configured for current Font · ANSI (local code page) (0) · … · Other (enter code page manually) (§5.2)                                                                                                                                                                                                                                                                                                                                                     |
| Help     | Help                                                                                                                                                                                                                                                                                                                                                                                                                                                          |

- In text mode the image items (Fit…, Center) are disabled. For a text file the observed check marks were _1 Text only_,
  _ANSI_, _Wrap text_ and _Show text cursor_.
- In image mode the **Encoding** menu is greyed.

**File menu behaviour:**

| Item                      | Behaviour                                                                                                                    |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Open...                   | Loads one file into this Lister window.                                                                                      |
| Save as...                | Saves the shown file under another name. Meant mainly for temporary files: files viewed with F3 from an archive or from FTP. |
| Next File / Previous      | As N / P (§2.4).                                                                                                             |
| Print... / Print setup... | §12. The help calls the second item "Print options".                                                                         |
| Reload file               | Re-reads the file from disk.                                                                                                 |
| Close                     | As Esc / Q / Alt+F4.                                                                                                         |

The Edit menu is described in §7 and §8, the Options menu in §3–§5 and §9, Configure... in §14. **Save position** writes
the window geometry (§2.7).

### 2.4 Multi-file sessions

When Lister was opened with several files (F3 with a selection under the default setting):

- **N** or File › Next File goes to the next file, **P** or File › Previous to the previous one. **Alt+→ / Alt+←** and
  the `<<` / `>>` menu items do the same.
- The counter in `<< 1/3 >>` shows the position.
- With **one** file, N and Alt+→ do nothing.
- In media mode the files form a **playlist**: when playback ends, Lister moves on to the next file by itself.

### 2.5 Position and zoom item

- In text, binary and hex modes the item (`xxx %`) shows the position of the **last visible line** as a percentage of
  the file.
- Clicking it opens "Go to position (in %)" with an edit field, [OK] and [Cancel]. Decimals are accepted with `.` or `,`
  (e.g. `50.5`, `20,7`).
- After a search, the item goes back to the previous position value.
- In image mode it shows the zoom factor, e.g. `100.0 %` (100 % = actual size). With _Fit image to window_ on, it shows
  the factor that was applied when F was pressed.
- For videos it does not show a file position. What it shows instead is not documented.

### 2.6 Embedded Lister: Quick View panel and separate quick view

- The **Quick View panel** (Ctrl+Q; 03 › Quick View) is a Lister embedded in the inactive panel. It takes the Lister
  keys (e.g. Ctrl+F or F7 to search). These keep their Lister meaning even when the user redefines them in the main
  window: F2…F7 alone or with Shift, Ctrl+C/A/F/P, Ctrl+Home/End/PgUp/PgDn, Ctrl+Shift+←/→. The bar above it shows the
  file name followed by the Lister plugin's name, or the track and artist for music. On a folder it shows the occupied
  space.
- The **separate quick view** (Ctrl+Shift+Q) is a Lister window that reloads whenever the panel cursor moves. Its title
  is `Lister*`.

### 2.7 Geometry

- Options › _Save position_ writes `[Lister] x`, `y`, `dx`, `dy` and `Maximized`. In a separate quick view it writes
  `QuickX`, `QuickY`, `QuickDx`, `QuickDy` and `QuickMaximized` instead, and leaves the normal Lister geometry alone.
- **F11** toggles the maximised window. **Alt+Enter** toggles full screen.
- With `[Configuration] SameScreenAsTC` bit 2 set (default `1` = bit 1 only), Lister opens on the same monitor as the
  main window.

_Basis: observed on Windows 11 and under Wine; help: listercontents, lister_menufile, lister_menupercent,
lister_menuoptions, quick_view, inisettings2, inisettings3; HISTORY.TXT (title, percent item, Quick View key list)._

## 3. Display modes

### 3.1 Mode list

The modes are chosen with Options › 1–8 or the keys **1**…**8**.

| #   | Mode                       | Summary                                                                                                 |
| --- | -------------------------- | ------------------------------------------------------------------------------------------------------- |
| 1   | Text only                  | Text with line breaks interpreted (§3.2)                                                                |
| 2   | Binary (fixed line length) | A continuous character stream cut into fixed-length lines (§3.3)                                        |
| 3   | Hex                        | Offset, 16 bytes in hex, the same bytes as characters (§3.4)                                            |
| 4   | Image/Multimedia           | Image (§9), media player (§10) or Lister plugin (§11). Pressing **4** again cycles through the plugins. |
| 5   | HTML text (strip tags)     | Tags removed, links shown (§3.5)                                                                        |
| 6   | Unicode                    | UTF-16: every character takes 2 bytes, as written by Regedit or Notepad on NT                           |
| 7   | UTF-8                      | 1–4 bytes per character. Word wrap works here too.                                                      |
| 8   | Explorer Preview           | Explorer preview handler, or thumbnail provider (§3.6)                                                  |
| —   | RTF                        | Not a numbered mode (§3.7)                                                                              |

### 3.2 Text

- CR (#13), LF (#10) and CR+LF each count as **one** line break.
- **Wrap on** (_Wrap text_, key **W**, `[Lister] Wrap=1`, default): lines are wrapped at **word boundaries** after at
  most `TextWidth` characters (Configure › _Display width › Text_, default **81**; the Options-menu help topic says 80).
- **Wrap off:** a line is still cut at `UnwrapWidth` characters (default 1024, maximum 16384). The help gives 512 as the
  limit for Unicode text.
- Tab stops are `TabWidth` columns wide (default 8).
- Observed: a monospace ANSI font, wrapped, with the text cursor shown.

### 3.3 Binary

- The file is cut into lines of exactly `binwidth` characters (Configure › _Display width › Binary_, default **75**; the
  Options-menu help topic says 74). Line ends are not interpreted. Meant for executables and other non-text files.
- Observed on Windows 11: CR and LF are shown as dots, and lines break at 75 characters.
- With `ReplaceWrongWidthChars=1` (default), characters whose glyph has the wrong width for the fixed-pitch font are
  replaced by dots. This applies to binary and hex modes.

### 3.4 Hex

Each line holds an 8-digit hex offset (32-bit, bytes from the start of the file) and a colon. Then come 16 bytes in hex,
with `|` after the 8th byte, and then the same 16 bytes as characters. Control characters and other non-printables show
as `.`. As recorded on Windows 11:

```text
00000000: 52 65 70 6F 72 74 20 31|0D 0A 4C 6F 72 65 6D 20 | Report 1..Lorem
```

A short last line is padded so that the character column stays aligned (in this second sample the separator before the
character column was not recorded; use `|` as above):

```text
00000000: 5B 6D 61 69 6C 5D 0D 0A|6D 61 70 69 3D 31 0D 0A   [mail]..mapi=1..
00000010: 5B 66 6F 6E 74 73 5D 0D|0A 64 75 6D 6D 79 3D 30   [fonts]..dummy=0
00000020: 0D 0A                                              ..
```

A selection is highlighted in both the hex part and the character part.

### 3.5 HTML text (strip tags)

- All tags are removed and links are shown.
- Links are drawn in `LinkColor`, inside `{ }` when `LinkBraces=1` (Configure › _Show links in HTML with surrounding {
  }_, default on).
- A **relative** link opens the linked file in Lister. An **absolute** link (`http://…`) opens in the default browser.
  Over an external link the mouse cursor becomes an arrow with a small "e".
- UTF-8 and UTF-16 HTML are decoded when the file has the matching `META HTTP-EQUIV` header.
- With `HTMLAsText=0` (_Show HTML as text with links_ off), HTML files open as plain source text. Mode 5 can still be
  chosen by hand.

### 3.6 Explorer Preview

- Uses the Explorer preview handler (`IPreviewHandler`), including third-party handlers.
- If the type has no preview handler, Lister uses the thumbnail provider (`IThumbnailProvider`) instead, provided _Use
  thumbnail providers_ (`ThumbnailProviders=1`) is on. Thumbnail providers can be asked for a given size, so they often
  give a usable full-size image.
- The mode is available only with _Use preview handlers from Explorer_ (`PreviewHandlers`) on.
- The title shows `<Explorer>` only while a preview handler is used.

### 3.7 RTF

- With `RTF=1` (Configure › _RTF_, default on), RTF files are recognised and shown through the Microsoft RTF control,
  the engine WordPad uses.
- Embedded images and objects are **not** shown.

_Basis: observed on Windows 11 and under Wine; help: lister_menuoptions, listercontents, dlg_listerconfig, inisettings3;
what_s_new_continued, whats_new; HISTORY.TXT (`<Explorer>` rule)._

## 4. Choosing the mode at start-up

### 4.1 Start-up word

`[Lister] Startup` = mode + font. These are the radio groups _Display at startup_ and _Font at startup_ on Configure
Lister › General.

| Part                  | Values                                                  |
| --------------------- | ------------------------------------------------------- |
| Mode (`Startup & 15`) | 0 auto-detect (default), 1 text, 2 binary, 3 hex        |
| Font (`Startup & 48`) | 0 auto-detect (default), 16 ANSI, 32 ASCII, 48 variable |

- _Display at startup = Autodetect_ tells text files from binary files only "in a limited way".
- _Font at startup = Autodetect_ tries to tell ANSI text from ASCII/DOS text.
- UTF-8 text is detected by its valid UTF-8 multi-byte sequences.
- Neither heuristic is documented further, so a clone must choose its own.

### 4.2 Detection switches

| Key (Configure › Multimedia)                                                  | Default        | With 1                                               | With 0                                            |
| ----------------------------------------------------------------------------- | -------------- | ---------------------------------------------------- | ------------------------------------------------- |
| `BmpStartup` (_Use plugins or load bitmaps as graphics at startup_)           | 1              | Images, and files a plugin accepts, open graphically | They open as text/binary; mode 4 still shows them |
| `Multimedia` (_Multimedia (AVI,WAV,...)_)                                     | 1              | Audio and video are loaded and played                | They open as binary; mode 4 still plays them      |
| `RTF`                                                                         | 1              | RTF detection on                                     | Shown as text                                     |
| `HTMLAsText` (_Show HTML as text with links_)                                 | 1              | HTML opens in mode 5                                 | HTML opens as source                              |
| `ModeByfileType` (_Define view method by file type_)                          | 1              | `[ListerModes]` rules are applied first (§11.3)      | Rules ignored                                     |
| `IView` (_Use Irfanview/Xnview to load graphics other than BMP_), `IViewPath` | off (observed) | Other image formats go through IrfanView/XnView      | Only the internal formats                         |

The internal image formats are BMP, JPG, GIF and PNG. `AutoRotate=1` (default) rotates JPGs according to their EXIF
orientation.

### 4.3 Type lists and vetoes

- **IrfanView/XnView types.** These go to the external converter (with `IView=1`) even without extra configuration:
  jfif, tga, tif, tiff, pcx, ani, acr, cam, clp, cpt, cur, dcx, dib, eps, g3, iff, img, lbm, lwf, pbm, pgm, pcd, ppm,
  psd, psp, ps, ras, rle, sfw, iw44, djvu, rgb, dcm, wbmp, mos, kdc, xbm, xpm, swf, fpx, sgi, jp2, j2k.
  - IrfanView 2.90 or later, or XnView 1.14 or later, is required. Converting large images this way uses a lot of
    memory.
  - _Additional Irfanview/Xnview file types_ (`IviewAdditionalTypes`) adds types with the syntax
    `include-masks | exclude-masks`. Example: `*.jpg | *.tga *.tif *.tiff` sends JPG to IrfanView and keeps TGA and TIF
    away from it.
  - A type the program already supports that is listed there (e.g. `*.tif`) is no longer detected **by content**.
- **Additional multimedia file types** (`MediaAdditionalTypes`) use the same `include | exclude` syntax, e.g.
  `*.mkv *.wmv | *.mp3 *.mp4`.
- **Global vetoes.** Both are overridden when the user explicitly chooses Options › 4.
  - `NoMediaFileTypes=` (e.g. `*.jpg *.avi`): these types never open as video, audio, image or plugin.
  - `NoPluginFileTypes=`: these types never open in a plugin, though the internal image viewer may still show them.
- **WMF** is disabled in Lister and in thumbnails, for security reasons. `[Configuration] WmfAllowed`:

  | Value        | Effect                                                          |
  | ------------ | --------------------------------------------------------------- |
  | -1 (default) | Folder thumbnails if the Windows patch is installed, but no WMF |
  | 0            | No WMF and no folder thumbnails at all                          |
  | 1            | WMF in Lister and thumbnails                                    |
  | 2            | Folder thumbnails allowed                                       |
  | 3            | Both                                                            |

### 4.4 Reference algorithm

The help documents the options but not their order. The order below is inferred from them:

```text
open(file, internalOnly):
  if internalOnly:                                   # Alt+Shift+F3, /S=L:N, cm_ListInternal…
      return startupTextMode()                       # no plugins, no multimedia
  if ModeByfileType and rule = firstMatching([ListerModes]):
      return first method of rule                    # '4' later cycles as in §11.3
  if BmpStartup and type not in NoMediaFileTypes:
      for p in ListerPlugins in list order:          # detect string checked before loading
          if type not in NoPluginFileTypes and p.detect(file) and p.load(file):
              return plugin p
      if internalImage(file) or iviewType(file):     return image
      if Multimedia and mediaType(file):             return mediaPlayer
  if RTF and isRtf(file):                            return rtf
  if HTMLAsText and isHtml(file):                    return htmlText
  return startupTextMode()

startupTextMode(): mode = Startup & 15   (0 = auto-detect text vs binary)
                   font = Startup & 48   (0 = auto-detect ANSI vs ASCII)
```

A mode chosen by a `[ListerModes]` rule (text, binary, hex) must **not** switch to HTML or RTF afterwards because of
content detection.

_Basis: observed on screen under Wine (defaults); help: dlg_listerconfig, lister_menuoptions, listercontents,
inisettings2, inisettings3; what_s_new_continued; HISTORY.TXT 09.09.20 (rule-chosen modes)._

## 5. Fonts, character sets and encodings

### 5.1 Font slots

| Key | Option                 | Font key | Meaning                                                                   |
| --- | ---------------------- | -------- | ------------------------------------------------------------------------- |
| A   | ANSI (Windows charset) | `Font1`  | The Windows codepage; for files created under Windows                     |
| S   | ASCII (DOS Charset)    | `Font2`  | The OEM codepage: DOS box-drawing characters and DOS umlauts              |
| V   | Variable char width    | `Font3`  | Proportional; text only, best for prose without tables or aligned columns |

- If the font chosen for ASCII cannot show OEM characters, the text is shown as ANSI. The exception is when the user
  explicitly chose to use such a font for ASCII: TC asks whether to force the font to ASCII/DOS when it does not contain
  that encoding.
- On NT-based Windows the character set can be forced to ASCII/DOS even for a non-DOS font. The Windows font dialog
  wrongly lists non-DOS fonts in the DOS font picker.
- Several font families are used, so Cyrillic and Eastern European text get correct glyphs.
- **Default fonts:** with `OldDefaultFonts=0` (default; _Use old non-scalable default fonts_ off), scalable fonts are
  used: Consolas for ANSI and ASCII, Verdana for Variable. With `1`, the old bitmap fonts are used (SYSTEM_FIXED_FONT
  etc.).
- **Font INI format:** `FontN=name,size,attrs`, e.g. `Font1=Arial,-15,b`. In the attributes, `b` = bold, `i` = italic, a
  plain number = codepage, `W<n>` = weight, `D<n>` = the DPI the size was saved for.
- The font size can be changed while viewing (§6.2). Ctrl+0 returns to the stored size.

### 5.2 Encoding menu

The Encoding menu overrides the codepage of the current font. The choice is stored in `[Lister] Codepage`, where `-1`
(default) means _As configured for current Font_. The menu is greyed in image mode.

| Entry                                                                                                                                                                       | Codepage                                                                              |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| ● As configured for current Font                                                                                                                                            | -1: the A / S / V font decides                                                        |
| ANSI (local code page) (0)                                                                                                                                                  | 0: the system codepage for non-Unicode programs, e.g. Russian when that is configured |
| ASCII/DOS (local code page) (1)                                                                                                                                             | 1: the local OEM codepage                                                             |
| MacOS (2)                                                                                                                                                                   | 2: said not to work on Windows 9x/ME                                                  |
| Eastern Europe (1250) · Cyrillic Windows (1251) · Western Latin1 (1252) · Greek (1253) · Turkish (1254) · Hebrew (1255) · Arabic (1256) · Baltic (1257) · Vietnamese (1258) | The Windows codepage shown in brackets                                                |
| Chinese Main Land (936) · Chinese Taiwan (950) · Japanese (932) · Korean (949) · Thai (874)                                                                                 | As above                                                                              |
| DOS-USA (437) · DOS-LATIN1 (850) · Cyrillic KOI8-R (20866)                                                                                                                  | As above                                                                              |
| ────                                                                                                                                                                        |                                                                                       |
| Other (enter code page manually)                                                                                                                                            | See below                                                                             |

**Other (enter code page manually)** accepts two forms:

- A bare number (e.g. `866`) is used **temporarily**.
- `Name (number)` (e.g. `Cyrillic DOS (866)`) is **added to the menu permanently**. User entries are stored in
  `UserEncodings=` as `Name (n)|Name2 (m)`.

The installed codepage numbers can be looked up in the Windows regional settings.

### 5.3 Right-to-left text

- For Unicode text (UTF-16 or UTF-8), or plain text in an Arabic or Hebrew codepage, **Ctrl+Right Shift** right-aligns
  the text and **Ctrl+Left Shift** left-aligns it.
- `Uniscribe=1` (default) uses Uniscribe for Unicode and foreign codepages, which handles right-to-left text correctly.
  `2` uses it always, also where it is not needed.
- `[Configuration] HebrewListerFix=1` corrects the selection coordinates for English text on Hebrew Windows when
  Uniscribe is not used.

_Basis: observed on screen under Wine (menu); help: lister_menuoptions, lister__encoding_menu, dlg_listerconfig,
listercontents, inisettings1, inisettings3, whats_new._

## 6. Keyboard, mouse and touch

### 6.1 General keys

| Key                              | Action                                                                                                                  |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| F1                               | Help                                                                                                                    |
| F2                               | Reload the file (File › Reload file)                                                                                    |
| F4                               | Edit the file in the editor (§13)                                                                                       |
| F11                              | Toggle the maximised window                                                                                             |
| Alt+Enter                        | Toggle full screen (in media mode: full-screen playback, §10.2)                                                         |
| Ctrl+P                           | Print (§12)                                                                                                             |
| Esc, Alt+F4, F10, Q              | Close Lister                                                                                                            |
| N / P, Alt+→ / Alt+←             | Next / previous file (only with several files, §2.4)                                                                    |
| 1 … 8                            | Display mode (§3)                                                                                                       |
| A / S / V                        | ANSI / ASCII / Variable font                                                                                            |
| W                                | Wrap text                                                                                                               |
| F6                               | Text cursor on / off                                                                                                    |
| F / L / C                        | Fit image to window / Fit only larger images / Center images (image mode). In media mode C has another meaning (§10.2). |
| Shift+F10, menu key, right click | Context menu (§7.2)                                                                                                     |

No key remapping is documented for Lister; `[Shortcuts]` applies only to the main window.

### 6.2 Text modes

Navigation depends on whether the text cursor is shown. **F6** (Options › _Show text cursor_, `Caret=1`, default on)
toggles it. The text cursor is for selecting and copying only; there is no editing.

| Key                                  | Text cursor off                              | Text cursor on          |
| ------------------------------------ | -------------------------------------------- | ----------------------- |
| Arrows, Home, End, PgUp, PgDn, Space | Scroll the view                              | Move the cursor         |
| Ctrl+Home / Ctrl+End                 | —                                            | Start / end of the file |
| Shift+arrows                         | —                                            | Extend the selection    |
| Ctrl+← / Ctrl+→                      | Scroll sideways                              | Previous / next word    |
| Ctrl+A                               | Select all                                   | Select all              |
| Ctrl+C                               | Copy the selection as text                   | Same                    |
| Ctrl+Shift+C                         | Copy the selection as hexadecimal characters | Same                    |
| F7, Ctrl+F                           | Find (§8)                                    | Same                    |
| F3, F5, Shift+F7                     | Find next                                    | Same                    |
| Shift+F3, Shift+F5                   | Find previous (always backwards)             | Same                    |
| Ctrl+F3, Ctrl+F5                     | Find in the reverse of the current direction | Same                    |
| Num + / Num −, Ctrl+'+' / Ctrl+'−'   | Font size up / down                          | Same                    |
| Ctrl+0                               | Reset the font size to the stored size       | Same                    |

### 6.3 Mouse

- The wheel scrolls vertically, Shift+wheel horizontally. Tilting the wheel left or right scrolls sideways on mice that
  support it.
- `ZoomFont=1` (default): Ctrl+wheel zooms the font (and the image in image mode), and Ctrl+Alt+wheel scrolls page by
  page.
- `ZoomFont=-1` swaps the two combinations. `ZoomFont=0` turns wheel zoom off; the other combination still scrolls fast.

### 6.4 Touch screen

- With no text selected, dragging a finger scrolls.
- A vertical flick starts auto-scroll; a tap stops it.
- A double tap selects a word, which can then be extended by dragging. A tap behind the text removes the selection.

_Basis: observed on Windows 11 (N, Alt+→, 1–3, F7) and under Wine (menu shortcuts); help: listercontents,
lister_menuedit, inisettings3, whats_new; HISTORY.TXT (Quick View keys)._

## 7. Selection, clipboard and context menu

### 7.1 Selection and clipboard

- _Copy as text_ (Ctrl+C) copies the selection. Every NUL character (#0) becomes a space (#32).
- _Select all_ (Ctrl+A) selects the whole file for copying.
- Ctrl+Shift+C, or the context menu, copies the selection as **hex values**.

### 7.2 Context menu rules

The menu opens with a right click, Shift+F10 or the menu key.

- **With text selected**, it offers:
  - copy as text;
  - copy as hex;
  - search the web (Google) for the selection;
  - if the selection is a URL: copy the URL, download its target, or open it in the default browser.
- **With no selection**, it opens **only on a URL**. That URL is selected automatically first. A URL here is text
  starting with `http://`, `https://` or `www.`, or alphanumeric text with at least one dot before its end. Anywhere
  else, a right click does nothing; an observed right click on plain text opened no menu.
- In HTML mode it also offers _Copy all URLs_.
- In media mode the context menu switches the audio and subtitle streams.

### 7.3 Allowed items (`[Lister] PopupItems`)

A sum of bits; default 127 (all items):

| Bit | Item                                     |
| --- | ---------------------------------------- |
| 1   | Copy as text                             |
| 2   | Copy as hexadecimal                      |
| 4   | Copy URL                                 |
| 8   | Copy all URLs                            |
| 16  | Download target in an HTML document      |
| 32  | Download target in a plain-text document |
| 64  | Open in the default browser              |

### 7.4 User items

- Syntax: `Contextmenu<n>=Title|target`, e.g.
  `Contextmenu1=Search for selected text with Google|http://www.google.com/search?q=%s`. The built-in Google item is
  customised this way (unverified whether `Contextmenu1` replaces it or adds a second item).
- `%s` is replaced by the selected text.
- If the target contains `http://` or `https://`, characters that are not allowed in URLs are written as `%hh`.
- The target may also be a program with parameters: `Contextmenu1=Title|c:\path\program.exe parameters`. A program path
  with spaces must be in double quotes: `Contextmenu1=Title|"c:\path with spaces\program.exe" parameters`.

_Basis: observed under Wine (no menu on plain text); help: listercontents, lister_menuedit, inisettings3, whats_new,
what_s_new_continued; HISTORY.TXT 11.09.13._

## 8. Search

### 8.1 Find dialog

F7, Ctrl+F or Edit › Find opens:

```text
Lister
Enter search text:
[                                            ▾]
[ ] Whole words only        [ ] Case sensitive
[ ] Search backwards        [ ] Search hex string
[ ] RegEx
              [ OK ] [ Cancel ] [ Help ]
```

All options are off by default. The combo keeps the search history.

### 8.2 Pattern rules

- The search starts **at the current position**, forwards unless _Search backwards_ is ticked.
- **Whole words only:** a match must not be part of a longer word (`man` does not match in `manager`).
- **Case sensitive:** exact case.
- **Search hex string:** the pattern is hex bytes, e.g. `00 FF 12`. Mixed mode with quoted literal text is allowed:
  `"PK"0102`.
- **RegEx:** regular expressions (18 › Regular expressions).
- **Escapes** in plain (non-hex) patterns:

  | Escape | Meaning                            |
  | ------ | ---------------------------------- |
  | `\t`   | Tab                                |
  | `\n`   | Line break; matches **CR LF only** |
  | `\\`   | One backslash                      |

### 8.3 Result and repeating

- The found text is shown **inverted**. The view scrolls so that the found line sits `SearchGoBack` lines below the top
  border (Configure › _Search result: Lines from top of list_, default 3).
- F3, F5 or Shift+F7 find the next match. Shift+F3 and Shift+F5 always search backwards. Ctrl+F3 and Ctrl+F5 reverse the
  current direction.
- The current search string is stored **both in TC and in Lister** for later searches; the history is shared.

_Basis: observed on Windows 11 (dialog) and under Wine; help: lister_menuedit, listercontents, dlg_listerconfig,
inisettings3._

## 9. Image mode

- Observed: a JPG is drawn at the **top left at 100 %**; the percent item reads `100.0 %`; the Encoding menu is greyed.
- **Zoom:**
  - Num + / Num − or Ctrl+wheel zoom in and out. Ctrl+0 resets the zoom to 100 %.
  - The zoom factor can also be entered by clicking the percent item.
- **Scrolling:** ← / → scroll the image; Shift+← / Shift+→ scroll in smaller steps.
- **Fitting** (both stored in `ShrinkBitmap`, default 0 = neither):

  | Key | Option                                                | Effect                                                                                                                        |
  | --- | ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
  | F   | _Fit image to window_ (`ShrinkBitmap=1`)              | Scales the image to the window and keeps the aspect ratio. It **enlarges** small images too. It also works for video windows. |
  | L   | _Fit only larger images to window_ (`ShrinkBitmap=2`) | Shrinks only images that are larger than the window.                                                                          |

- _Center images_ (`CenterBitmap=1`, key C) centres the image. Otherwise it is drawn at the top left (default `0`).
- Animated GIFs use a minimum frame delay of `GifMinDelay` ms (default 80).
- Formats: §4.2–§4.3. Printing images: §12.1.

_Basis: observed under Wine and on Windows 11; help: listercontents, lister_menuoptions, lister_menupercent,
inisettings3, whats_new._

## 10. Media player mode

### 10.1 Playback

- Audio and video play through Windows media codecs (DirectShow).
- With several files open, playback moves on to the next file automatically (§2.4).
- **Tags:** track name and artist are read from id3v1, id3v2.2, id3v2.3/2.4, ape, flac, wav, ogg and m4a tags and shown
  in the title bar.
- **Cover:** with `AlbumArt=1` (default), the cover image comes from the track's tags, or from a file named `cover.jpg`,
  `folder.jpg`, `cover.png` or `folder.png` in the same folder. A button shows or hides it.
- A `.cue` file with the same name as the media file supplies track positions and names, for seeking in long
  compilations.
- Chapters are shown as tick marks below the seek bar.
- Four jump buttons move by `PlayDelta0..3` seconds (default −60, −10, +10, +60).
- The colours of the player controls are `MediaFgColor` / `MediaBgColor` (§14.3).

### 10.2 Keys

| Key                                | Action                                                  |
| ---------------------------------- | ------------------------------------------------------- |
| E                                  | Single step: one video frame, or 1/10 s for audio only  |
| C                                  | Show / hide the cover image                             |
| M                                  | Mute / unmute                                           |
| ↑ / ↓                              | Volume +1 % / −1 %                                      |
| Ctrl+↑/↓, Shift+↑/↓                | Volume ±10 %                                            |
| Shift+← / Shift+→, Ctrl+← / Ctrl+→ | Rewind / fast forward                                   |
| Ctrl+PgDn / Ctrl+PgUp              | Next / previous chapter mark                            |
| F                                  | Fit the video to the window                             |
| Alt+Enter, double click            | Full-screen playback; leave it the same way or with Esc |

### 10.3 Player state

- `PlayerVolume` is the last volume, 0–100 (default 100).
- **Resume position:** for a track at least `SavePositionLimit` seconds long (default 600 = 10 minutes), the last
  position is saved in `[LastTracks]` as `date-time=offset_seconds,track file name`. `-1` turns this off.
- `StopInMainThread` (Windows XP only) stops the player in the main thread (`1`, default) or in a background thread
  (`0`).

### 10.4 Filter strategy (Configure Lister › Player)

`PreloadFilterType32` / `PreloadFilterType64`:

| Value       | UI choice                          | Rule                                                                                              |
| ----------- | ---------------------------------- | ------------------------------------------------------------------------------------------------- |
| 0           | Use default system filters         | Windows chooses the filters. Few formats work.                                                    |
| 1 (default) | Recommended filters (LAV, ffdshow) | Prefer LAV Video/Audio; if they are missing, ffdshow; otherwise the standard filters.             |
| -1          | Old Video for Windows player       | The playback method of TC 9.51 and older.                                                         |
| 2           | User defined                       | Uses the source and decoder lists below. If loading fails with them, the system filters are used. |

- LAV, ffdshow and DirectVobSub also work **without installation** when copied into `filter32` or `filter64` under the
  TC directory. `Filter32dir=` / `Filter64dir=` set other locations. `PreferFiltersFromFile=1` (default) prefers the
  filters in those folders over versions registered in Windows.
- **Source filters** (`PreloadInputFilters32/64`): recommended are "LAV Filter Source" and "Haali Media Splitter". _Add_
  lists the available source filters. Its entry "*.grf (Graphedit)" loads a filter graph saved by GraphEdit or Graph
  Studio instead. The output filter must support **windowless** playback. _Remove_ deletes the selected filter or graph
  file.
- **Decoder filters (audio/video)** (`PreloadFilters32/64`): these CLSIDs are loaded into the filter graph before the
  file is rendered. Windows tries the loaded filters first and then searches the system. `|` separates alternatives (the
  first that loads wins) and `,` separates groups, e.g. `video1|video2,audio1|audio2`. The default is LAV Video/Audio,
  or ffdshow when LAV is absent.
- Observed default lists, when no filters were installed: source
  `(not installed) {B98D13E7-55DB-4385-A33D-09FD1BA26338}`; decoders
  `(not installed) {EE30215D-164F-4A92-A4EB-9D4C13390F9F}` and `(not installed) {E8E73B6B-4CB3-44A4-BE99-4F7BCB96E491}`.
- _Download filters..._ opens a page on the TC website that lists the recommended filters.

_Basis: observed on screen under Wine (Player tab); help: listercontents, dlg_listerconfig, inisettings3, whats_new._

## 11. Lister plugins and view methods by file type

Installing plugins and the "Lister plugins" list are in 15 › Managing plugins: Options › Plugins. This section covers
how Lister uses them.

### 11.1 Plugins menu

The menu is built for each file and has up to three sections:

1. **Internal (no plugins)**, which switches to the internal viewer (e.g. for images or multimedia). Next to it come the
   plugins assigned to this file type under _Define view method by file type_ (§11.3).
2. Plugins whose **detect string** matches this file.
3. All other plugins. These are the least likely to work.

The plugin in use is checked. Choosing a plugin that cannot show the file **changes nothing**.

Observed on Windows 11 with the Imagine plugin installed, on a JPG:

- Imagine had become the default viewer for JPG. The title read `Lister (imagine) - [<path>]`, and the plugin added its
  own toolbar and status bar, e.g. "3/4 640 x 480 x 24 BPP JPEG - JFIF Compliant … Exif … 100% … Load time: 0.04
  seconds".
- The menu read `Internal (no plugins)` · `✓ Imagine`.
- _Internal (no plugins)_ switched to the built-in image view: title `Lister - [<path>]`, zoom `100.0 %`.

### 11.2 Order and cycling

- Plugins are tried in the order of the _LS-Plugins_ list. In that list, Shift+arrows (or the [^] [v] buttons) change
  the order.
- Storage: `[ListerPlugins] n=<path>`, `n_detect=<detect string>` (64-bit: `[ListerPlugins64]`). The detect string lets
  TC decide whether a plugin can handle a file **without loading it**.
- Pressing **4** repeatedly cycles through all matching plugins and the internal viewer.

### 11.3 View methods by file type

_Define view method by file type..._ (Configure › Multimedia, enabled by `ModeByfileType=1`) opens **"Lister: view
methods by file type"**:

```text
Lister: view methods by file type
File types (sort by drag&drop, edit with <spacebar>):
┌───────────────────────────────────┐  [ Add...  ]
│                                   │  [ Edit... ]
│                                   │  [ Delete  ]
│                                   │
│                                   │  [   OK    ]
└───────────────────────────────────┘  [ Cancel  ]
```

- **Add...** first asks for the file type in "Specify file type" (the layout of §17.5). How the methods are then picked
  was not recorded.
- Order by drag & drop; Space edits the entry.
- Storage `[ListerModes]`: `0exts=*.ext`, `0fields=<methods>`, then `1exts`, `1fields` and so on. Rules are tested **in
  numbered order; the first match wins**.
- `fields` is a comma-separated list of methods:

  | Method         | Meaning                                               |
  | -------------- | ----------------------------------------------------- |
  | `1`…`8`        | The Options-menu modes                                |
  | `4`            | Multimedia, auto-detect                               |
  | `4i`           | Multimedia with the internal viewer only (no plugins) |
  | `<pluginname>` | That plugin                                           |

- **Exactly one method:** F3 opens the file with it, and **4** cycles through _all_ Lister plugins and multimedia
  methods that support the type.
- **Two or more methods:** **4** cycles **only** through the listed methods.
- Typical use: types with several possible views, such as icons versus program structure for executables, or all JPGs
  with the internal image viewer.

_Basis: observed on Windows 11 (Imagine) and under Wine (dialogs); help: lister_menuplugins, dlg_listerconfig,
inisettings3, whats_new._

## 12. Printing from Lister

### 12.1 File › Print... (Ctrl+P)

- **Text, binary or hex mode:** the output follows the **current display mode**. The user prints one of:
  - the whole file;
  - the selected text;
  - a range of pages.
- **Images** (JPG, PNG and GIF with the internal image viewer):
  - With _Fit image to window_, the image is scaled to the print area (paper minus margins), and **enlarged** if it is
    smaller.
  - With _Fit only larger images to window_, it is shrunk only when it is larger than the area; otherwise it prints 1:1.
  - The zoom factor is not used for printing. With no fit mode the image presumably prints 1:1 (unverified).

### 12.2 Print setup (Print options)

| Control         | Rule                                                                                                                                                                                          |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Printer         | The target printer. It decides which fonts are offered.                                                                                                                                       |
| Font › Fixed    | For the ANSI and ASCII modes; stored in `Font4` (e.g. `Courier New,18,b`)                                                                                                                     |
| Font › Variable | For the Variable mode; stored in `Font5` (e.g. `Arial,20`)                                                                                                                                    |
| Margins         | `LeftMargin`, `RightMargin`, `TopMargin`, `BottomMargin` in **1/10 mm**, defaults 200 / 0 / 200 / 200. A margin below the printer's physical minimum is raised to that minimum when printing. |

In ASCII mode, characters are converted **OEM → ANSI before printing**. The layout of this dialog was not recorded.
File-list printing is a different dialog (12 › Printing).

_Basis: help only: lister_menufile, dlg_printoptions_lister, lister_menuoptions, inisettings3, whats_new._

## 13. F4 inside Lister

- **F4** opens the current file in the editor: `[Lister] Editor=`, or `[Configuration] Editor=` when that is empty
  (default `notepad.exe`).
- F4 is **unavailable**:
  - for temporary files (extracted from an archive, or downloaded);
  - in Image/Multimedia mode;
  - in Explorer Preview mode;
  - in plugin mode.
- `[Lister] F4Edit`:

  | Value       | Behaviour                                                                    |
  | ----------- | ---------------------------------------------------------------------------- |
  | 0           | Ignore F4                                                                    |
  | 1 (default) | Open the editor, except in the cases above                                   |
  | 2           | As 1, then close Lister about 0.5 s later when only one file is being viewed |
  | 3           | As 2, also in multi-file sessions                                            |

_Basis: help only: listercontents, inisettings3, whats_new._

## 14. Configure Lister

### 14.1 Dialog

Opened by Lister › Options › Configure..., by Configuration › Edit/View › [Configure internal viewer...], or by
`cm_ConfigLister` (3036). Three tabs; observed defaults shown:

```text
Configure Lister
[ General ][ Multimedia ][ Player ]

General
  Display at startup:  ( ) Text  ( ) Binary  ( ) Hex  (•) Autodetect
  Font at startup:     ( ) ANSI  ( ) ASCII   ( ) Variable  (•) Autodetect
  Font:   ANSI:     [x] default  [Font...]
          ASCII:    [x] default  [Font...]
          Variable: [x] default  [Font...]
          [ ] Use old non-scalable default fonts
  Display width (characters per line):  Text: [81]   Binary: [75]
  Search result:  Lines from top of list: [3 ⇕]

Multimedia  ("Multimedia display")
  [x] Use plugins or load bitmaps as graphics at startup
  [x] Multimedia (AVI,WAV,...)            [x] RTF
  [ ] Use Irfanview/Xnview to load graphics other than BMP
      Path: [i_view32.exe            ] [>>]          (disabled while unticked)
  [x] Show HTML as text with links        [ LS-Plugins ]
  [x] Show links in HTML with surrounding { }
  [x] Use preview handlers from Explorer
  [x] Use thumbnail providers
  [x] [ Define view method by file type... ]
  Additional Irfanview/Xnview file types: [                    ]
  Additional multimedia file types:       [                    ]

Player  ("Internal Media Player")
  ( ) Use default system filters
  (•) Recommended filters (LAV, ffdshow)
  ( ) Old Video for Windows player
  ( ) User defined:                       [ Download filters... ]
  Source filters:                  ┌──────────────────────┐ [ Add ] [ Remove ]
                                   └──────────────────────┘
  Decoder filters (audio/video):   ┌──────────────────────┐ [ Add ] [ Remove ]
                                   └──────────────────────┘
                                       [ OK ] [ Cancel ] [ Help ]
```

- **LS-Plugins** opens "Lister plugins": a "Lister plugins:" list, [^] [v], [Add] [Remove] [Rename] (Rename disabled),
  [OK] [Cancel] (15 › Managing plugins: Options › Plugins).
- **Define view method by file type...** opens the dialog of §11.3.

### 14.2 Option → key → effect

| UI option                                          | Key (`[Lister]` unless stated)                    | Default       | Effect                                            |
| -------------------------------------------------- | ------------------------------------------------- | ------------- | ------------------------------------------------- |
| Display at startup / Font at startup               | `Startup`                                         | 0             | §4.1                                              |
| Font ANSI / ASCII / Variable                       | `Font1` / `Font2` / `Font3`                       | default fonts | §5.1                                              |
| Use old non-scalable default fonts                 | `OldDefaultFonts`                                 | 0             | §5.1                                              |
| Display width Text / Binary                        | `TextWidth` / `binwidth`                          | 81 / 75       | Wrap width / binary line length (§3.2, §3.3)      |
| Search result: lines from top                      | `SearchGoBack`                                    | 3             | §8.3                                              |
| Use plugins or load bitmaps as graphics at startup | `BmpStartup`                                      | 1             | §4.2                                              |
| Multimedia (AVI,WAV,...)                           | `Multimedia`                                      | 1             | §4.2                                              |
| RTF                                                | `RTF`                                             | 1             | §3.7                                              |
| Use Irfanview/Xnview… + Path                       | `IView`, `IViewPath`                              | off           | §4.2–§4.3                                         |
| Show HTML as text with links                       | `HTMLAsText`                                      | 1             | §3.5                                              |
| Show links in HTML with surrounding { }            | `LinkBraces`                                      | 1             | §3.5                                              |
| LS-Plugins                                         | `[ListerPlugins]` (`[ListerPlugins64]`)           | —             | §11.2                                             |
| Use preview handlers from Explorer                 | `PreviewHandlers`                                 | on (observed) | Turns mode 8 on or off (§3.6)                     |
| Use thumbnail providers                            | `ThumbnailProviders`                              | 1             | Thumbnail providers as the mode-8 fallback (§3.6) |
| Define view method by file type                    | `ModeByfileType`, `[ListerModes]`                 | 1             | §11.3                                             |
| Additional Irfanview/Xnview file types             | `IviewAdditionalTypes`                            | empty         | `include \| exclude` syntax (§4.3)                |
| Additional multimedia file types                   | `MediaAdditionalTypes`                            | empty         | `include \| exclude` syntax (§4.3)                |
| Player radio buttons                               | `PreloadFilterType32/64`                          | 1             | §10.4                                             |
| Source / decoder filters                           | `PreloadInputFilters32/64`, `PreloadFilters32/64` | LAV / ffdshow | §10.4                                             |
| Options › Wrap text                                | `Wrap`                                            | 1             | §3.2                                              |
| Options › Show text cursor                         | `Caret`                                           | 1             | §6.2                                              |
| Options › Fit image / Fit only larger              | `ShrinkBitmap` (1 / 2)                            | 0             | §9                                                |
| Options › Center images                            | `CenterBitmap`                                    | 0             | §9                                                |
| Encoding menu                                      | `Codepage`, `UserEncodings`                       | -1            | §5.2                                              |
| File › Print setup                                 | `Font4`, `Font5`, `*Margin`                       | see §12.2     | §12.2                                             |

The `PreviewHandlers` and `IView` defaults are those seen in the dialog of a fresh installation. The INI reference lists
`PreviewHandlers=0` and `IView=1` as example values.

### 14.3 Colours and other keys

- **Colours** (Configuration › Color › _Others › Lister_: Text color, Background color, Selected text, Selected
  background, Link color, Media player controls: Text, Media player controls: Background; 13 › Color):

  | Key                             | Default                          |
  | ------------------------------- | -------------------------------- |
  | `FgColor` / `BgColor`           | Windows text / background colour |
  | `FgSelColor`                    | the background colour            |
  | `BgSelColor`                    | the text colour                  |
  | `LinkColor`                     | 8388608 (128 × 65536, dark blue) |
  | `MediaFgColor` / `MediaBgColor` | button text / button face colour |

  `[ListerDark]` repeats `BgColor`, `FgColor`, `BgSelColor`, `FgSelColor` and `LinkColor` for dark mode.

- `TabWidth=8`, `UnwrapWidth=1024`, `ReplaceWrongWidthChars=1`, `GifMinDelay=80`, `AutoRotate=1`, `AlbumArt=1`,
  `Uniscribe=1`, `ZoomFont=1`, `PopupItems=127`, `Contextmenu<n>`, `Editor=`, `F4Edit=1`: see the sections above.
- `[Configuration] PreventScrollbarCrash` works around a Windows 8.1 scroll-bar crash in Lister (on by default on
  Windows 8.1).

_Basis: observed on screen under Wine (dialog and defaults); help: dlg_listerconfig, lister_menuoptions, inisettings2,
inisettings3._

## 15. Edit (F4)

### 15.1 Editor and parameters

- F4 starts the editor `[Configuration] Editor=` (default `notepad.exe`) with the file under the cursor. Notepad is
  meant for text files of limited size.
- For other file types, use Enter or a double click, which open the associated program (§17).
- How the file name is passed depends on the Editor field:

  | Editor field                | File name passed                                                                          |
  | --------------------------- | ----------------------------------------------------------------------------------------- |
  | `editor.exe "%1"`           | The long name, always in double quotes                                                    |
  | `editor.exe %1`             | The short 8.3 name if one exists; otherwise the long name, quoted when it contains spaces |
  | `editor.exe` (no parameter) | On NT-based Windows the long name, quoted only when it contains spaces                    |

- `>>` browses for the program.

### 15.2 Editing inside an archive

1. The file under the cursor is unpacked to a temporary file and opened in the editor.
2. When the editor closes and the file has changed, TC asks whether to re-pack it into the archive.
3. **Yes** updates the archive and erases the temporary file. **No** erases the temporary file and leaves the archive
   unchanged.

### 15.3 Multi-document editors

If the editor was already running, it may take the file over and the new process ends almost at once. TC then cannot
tell when editing ends. It shows a small dialog with the file name instead; **Close** in it continues with step 2 above.

`[Configuration] EditWaitTime` (default 2) applies to files edited from an archive or an FTP server:

- If the editor process ends within this many seconds, TC assumes a multi-document editor and shows the dialog.
- `0` turns the check off.
- `-1` never shows the dialog, e.g. when the file is passed to the program by DDE.

### 15.4 FTP and file-system plugins: re-upload

F4 (and F3) on an FTP or plugin file work on a temporary copy. _Plugins/FTP: Automatically re-upload changed files_
(`[Configuration] AutoReUpload`) decides how changes go back:

| Value       | Checkbox | Behaviour                                                                                 |
| ----------- | -------- | ----------------------------------------------------------------------------------------- |
| 0           | off      | Re-upload only after the editor closes, and only if the user confirms (TC 8.0x behaviour) |
| 1 (default) | off      | On the first re-upload, ask the user whether to switch to automatic re-upload             |
| 2           | on       | Re-upload automatically **each time** the file is saved in the editor                     |

What happens after an automatic re-upload on FTP is in 11 › Editing and viewing remote files.

### 15.5 `cm_Edit` parameters

`cm_Edit` takes switches after a slash. Full syntax: 17 › Commands with parameters.

| Switch             | Meaning                                                                                                                                                                                                                                          |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `C`                | Create files that do not exist yet. With several names or a range, the editor is not started (`L0` is implied).                                                                                                                                  |
| `T`, `T="c:\path"` | As `C`, but copy a template: the first file with the same extension from the user's template directory, or from the given one. With no template file, the new file is empty.                                                                     |
| `N="name"`         | The file names to open or create, separated by `\|` or each in double quotes and separated by spaces. If any name is quoted, the whole parameter goes in angle brackets: `N=<"name 1" "name 2">`. An existing file is opened, never overwritten. |
| `G`                | Create immediately (with `C` or `T`)                                                                                                                                                                                                             |
| `L0`…`L3`          | Launch: `L0` do not launch (with `C` / `T`); `L1` default editor (the default, except with `C` / `T`); `L2` associated program including internal associations; `L3` associated program without internal associations                            |
| `V="verb"`         | With `L2` / `L3`: the verb to use, e.g. `open` or `edit`. Empty means the default verb.                                                                                                                                                          |

_Basis: help only: proc_edit, dlg_configedit, inisettings1, dlg_choosecommand, what_s_new_continued._

## 16. New text file (Shift+F4)

### 16.1 Flow

1. TC asks for the name of the new file. The input history is `[NewFileHistory]`. When the cursor is on a folder,
   `EditNewName=` supplies the proposed name. The layout of the name dialog was not recorded.
2. TC creates the file and opens it in the editor, **unless the editor is set to `none`**.
3. Other file types are created with **New ›** in the context menu of the panel background or the current path
   (`cm_EditFileMenu`; 05 › Context menus).

`cm_EditNewFile 1` creates the file without opening the editor.

### 16.2 Archives, FTP and file-system plugins

Shift+F4 works there too. TC creates an empty file in `TEMP` and opens it in the editor. After it is saved, TC asks
whether to pack it into the archive or upload it to the server.

### 16.3 Several files, placeholders and ranges

**Several names** (local file system only; the **editor is not started**):

- `file 1.txt|file 2.txt|file 3.txt`
- `"file 1.txt" "file 2.txt" "file 3.txt"`
- `"file 1.txt"|"file 2.txt"|"file 3.txt"`

**Placeholders.** A name starting with `<` takes the Multi-Rename placeholders (18 › Rename and new-folder
placeholders). Some can be picked from the [+] button next to the edit field. They **cannot be combined with `|`**; a
counter range is used instead.

- A range in `<>` at the start, with `[C]`, creates several files and does not start the editor.
- `[C]` takes optional prefix and suffix text, `["prefix"C"suffix"]`. With it, the first file of the range gets no
  index.
- `[C]` without a range creates the first free name with an optional number (file system only).
- `[F]` and `[f]` (first letter of each word upper case) leave an alphanumeric `[C]` counter unchanged.
- All date and time placeholders use the time the dialog was opened, unless the modifiers `[T1]`…`[T4]` say otherwise
  (18 › Rename and new-folder placeholders).

| Input                                 | Creates                                                             |
| ------------------------------------- | ------------------------------------------------------------------- |
| `<[Y]-[M]-[D] todo notes.txt`         | `2017-09-22 todo notes.txt`                                         |
| `<Copy of [N]`                        | `Copy of name`, where name is the item under the cursor             |
| `<1-10>[C].txt`                       | `1.txt` … `10.txt`                                                  |
| `<1-250>ToDo No [C:3].txt`            | `ToDo No 001.txt` … `ToDo No 250.txt`                               |
| `<5-8>Example [C] text file.txt`      | `Example 5 text file.txt` … `Example 8 text file.txt`               |
| `<1-3>[Y]-[M]-[D] todo notes [C].txt` | `2017-09-22 todo notes 1.txt` … `… 3.txt`                           |
| `<1-3>test[" ("C")"].txt`             | `test.txt`, `test (2).txt`, `test (3).txt`                          |
| `<test[C].txt`                        | The first free one of `test.txt`, `test2.txt`, `test3.txt`, …       |
| `<test[" ("C")"].txt`                 | The first free one of `test.txt`, `test (2).txt`, `test (3).txt`, … |

The same name rules apply to new folders (07 › New folder).

_Basis: help only: proc_editnew, inisettings1, dlg_choosecommand._

## 17. Associations

### 17.1 How Enter and a double click choose the program

1. **Internal associations** (TC only, §17.5–§17.8) are checked first, in list order.
   - Exception: for **exe, com, bat, cmd and lnk** files the default verb cannot be overridden.
   - Archive extensions that open like folders can have their _Open_ redefined only with `***command` (§17.7).
2. Otherwise the **Windows association** is used (§17.2). TC reads both `HKEY_CLASSES_ROOT` and the per-user Explorer
   overrides under `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts`.
3. With no association at all, Windows shows its own chooser. Observed: Enter on a `.md` file without an association
   opened Windows' "Select an app to open this .md file".

The icon of the associated program is shown left of the file name when the Display/Icons options say so (13 › Icons).

### 17.2 Windows associations (Files › Associate With...)

`cm_Associate` (507) writes **Windows** associations, which also work in Explorer and the Start menu. They are stored in
the registry, which also holds verbs such as Print.

```text
Associate
All files with extension (ending with):  [exe                     ▾]
Associate with:
[                                                            ]
┌────────────────────────────────────────────────────────────┐
│ (none)                                                     │
│ … registered file types …                                  │
└────────────────────────────────────────────────────────────┘
[ New type... ] [ Delete ]              [ OK ] [ Cancel ] [ Help ]
```

| Control                                | Rule                                                                                                                                                                                                                                                                            |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| All files with extension (ending with) | Typed without `*`; a leading dot is optional. An existing association is shown below.                                                                                                                                                                                           |
| Associate with                         | The program; typed with its path, or picked from the list of registered types.                                                                                                                                                                                                  |
| New type...                            | Browse for a program (`*.exe`). Typing `*.com` Enter in the browser lists other kinds of program.                                                                                                                                                                               |
| Edit type...                           | Extra verbs for the selected type (§17.3). Not available for viewer associations (§17.4). Not seen in the observed dialog.                                                                                                                                                      |
| Delete                                 | Sets the association to "(none)".                                                                                                                                                                                                                                               |
| Replace with: PhotoViewer.dll          | Shown only on Windows 10 when the Photos app owns a type such as `.jpg`. When ticked, a double click opens the desktop Windows Photo Viewer instead, because the Photos app cannot step to the next or previous image when another program starts it. INI: `ReplacePhotoApp=1`. |
| OK                                     | Writes the registry plus `win.ini`. For viewer associations it writes `wincmd.ini` (§17.4).                                                                                                                                                                                     |
| Cancel                                 | Discards all changes.                                                                                                                                                                                                                                                           |

**Limits:**

- TC can read the per-user Explorer overrides (created by Explorer's "Open with") but cannot create or change them.
- Once the user has used **"Open with › Always"**, Windows blocks changes to that association, and _Associate With..._
  has no effect. Only internal associations can override it then.

The same dialog opens during packer-plugin installation, once for each extension listed in the plugin's `pluginst.inf`.
_Associate with_ then holds the plugin's `.wcx` path, and the list holds `(none)` and the plugin (15 › Installation).

### 17.3 Edit file type and Edit action (Windows)

**Edit file type (system):**

| Control                            | Rule                                                                                                    |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Change icon                        | The icon shown in TC and Explorer                                                                       |
| Type name                          | The registry type name; read-only                                                                       |
| Description of type                | Shown to the user, e.g. in _Open with_                                                                  |
| Open                               | The program for the _open_ verb. Bold = the default verb. Without DDE the command needs `%1` or `"%1"`. |
| DDE                                | Use DDE for this verb; ticking it opens Edit action                                                     |
| Verb list, New..., Edit..., Remove | The other verbs                                                                                         |
| Set as default                     | Makes the selected verb the default (Enter / double click)                                              |
| OK / Cancel                        | A verb is saved when its own dialog closes. Cancel discards only this dialog's changes.                 |

**Edit action (system):**

| Field                                       | Rule                                                                                                                           |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Action (verb)                               | e.g. `open`, `print`                                                                                                           |
| Action description                          | The context-menu text; on non-English systems the translated verb                                                              |
| Command                                     | The program; needs `%1` / `"%1"` unless DDE is used                                                                            |
| Use DDE                                     | Pass the file name by DDE, so one program instance can open several files (e.g. Word)                                          |
| DDE Message                                 | e.g. `[FileOpen("%1")]`                                                                                                        |
| DDE Application                             | e.g. `WinWord`                                                                                                                 |
| DDE Message when application is not running | e.g. Excel _Print_: `[open("%1")][print()][quit()]` when Excel is not running, but `[open("%1")][print()][close()]` when it is |
| DDE Topic                                   | Usually `System`                                                                                                               |
| OK                                          | Saves the verb to the registry                                                                                                 |

### 17.4 Viewer associations (Alt+F3)

- Configuration › Edit/View › [Associations...] opens the Associate dialog layout (§17.2), but for **viewers**. Edit
  type is not available there.
- They are stored in `wincmd.ini [Extensions]`, one line per extension: `bat=c:\windows\notepad.exe ^.bat`. The `^.bat`
  part is optional; `"%1"` may be used instead.
- Use: §1.4.

### 17.5 Internal associations: dialog chain

Files › Internal Associations (Total Commander Only)... (`cm_InternalAssociate`, 519):

```text
Internal Associations
File types (sort by drag&drop, edit with <spacebar>):
┌──────────────────────────────────┐  [ Add...  ]
│                                  │  [ Edit... ]
│                                  │  [ Delete  ]
│                                  │
│                                  │  [   OK    ]
│                                  │  [ Cancel  ]
└──────────────────────────────────┘
[ ] Load extra commands from all matching types
```

1. **Add...** opens "Specify file type". Its mask field is pre-filled with the extension under the cursor (e.g.
   `*.exe`), and it has a list of predefined selection types plus [Define...]:

   ```text
   Specify file type
   [*.exe                                   ▾]
   Or select predefined selection type:
   ┌──────────────────────────────┐
   │ (saved selection types)      │
   └──────────────────────────────┘
   [ Define... ]               [ OK ] [ Cancel ]
   ```

   It follows the Select Group dialog (03 › Selection). Whether its prompt line is the same as there was not recorded.
   _Define..._ creates a saved search to use as the type.

2. **OK** opens **"Edit file type"**:

   ```text
   Edit file type
   [icon] [ Change icon ]
   Type name:            [*.exe                    ] [>>]
   Description of type:  [                         ]   (disabled)
   Actions:
   Open  [                                        ] [>>]
   ┌──────────────────────────────┐  [ New...  ] [ Edit... ] [ Remove ]
   │ (other verbs)                │  [ Set as default ]  [^] [v]
   └──────────────────────────────┘
                                   [ OK ] [ Cancel ] [ Help ]
   ```

3. **New...** or **Edit...** opens **"Edit action - \*.exe"**: `Action (verb):` `[ ]`,
   `Action (description [context menu]):` `[ ]`, `Command (program):` `[ ] [>>]`, [OK] [Cancel] [Help].

- **Edit...** in the list, a double click or Space on an entry goes straight to Edit file type. **Delete** removes the
  entry.
- **OK** in the list dialog saves; **Cancel** closes without saving.

### 17.6 Internal associations: matching

- **Purpose:** associations that work only inside TC, e.g. for a portable installation on a USB stick.
  `%commander_drive%` / `%commander_path%` give paths independent of the drive letter.
- **The list order is the priority.** The first matching filter wins. Example: a `*.zip` entry above a "read-only" entry
  wins for read-only ZIP files.
- **Type name:** a mask (e.g. `*.txt`) or a saved search, changed with `>>`.
- **Quick disable:** clicking the leading `*` of a `*.ext` entry turns it into `-.ext`, which then matches only a file
  literally named `-.ext`. Clicking again re-enables it.
- **Several files of different types selected:**
  - **Open** (Enter): _each file_ uses its own first matching association. With `*.txt → notepad` and
    `*.txt *.rtf → winword`, Open on test.txt + test.rtf starts Notepad for the TXT and Word for the RTF.
  - **Every other verb:** the context menu is built from the **first association that matches _all_ selected files**.
    With `*.txt → Edit text=notepad.exe` and `*.txt *.rtf → Edit all=Winword.exe`, the menu for test.txt + test.rtf
    shows "Edit all", which opens both files in Word.
- **Load extra commands from all matching types** (`AssociationMultiVerbs`):
  - Off: only the first matching type's verbs are shown.
  - On: also every extra verb (not Open) of all other matching types.
  - Example: `*.txt Edit: notepad.exe` and `*.* Wordpad: wordpad.exe` give only "Edit" on text files when off, and both
    "Edit" and "Wordpad" when on.

### 17.7 Internal associations: commands

- **Icon:** empty = the icon of the Open program; `%1` or `**` = the icon TC would show without an internal association;
  e.g. `notepad.exe,-1` = an icon from a file (a negative number is an icon index, a positive one a resource id).
- _Description of type_ and, in Edit action, _Action description_ and all DDE fields are not used for internal
  associations.
- **Open** is **always the default verb** (Enter). The command must contain `%1` / `"%1"` or `%2`. The difference shows
  only with several selected files:
  - `%1`: the program is started **once per file**;
  - `%2`: **all files are passed to one** instance (if the program accepts several files).
- **Special values** for a command:

  | Value             | Meaning                                                                                                                           |
  | ----------------- | --------------------------------------------------------------------------------------------------------------------------------- |
  | `*`               | Enter shows a menu of the other verbs                                                                                             |
  | `**`              | Open with the system default association                                                                                          |
  | `*verb`           | Run that system verb, e.g. `*open`                                                                                                |
  | `**ext`           | Browse the file with the packer (plugin or internal) registered for extension `ext`                                               |
  | `**internal_ext`  | Browse with an internal packer, e.g. `**internal_zip`                                                                             |
  | `**internal_sha`  | Run _Verify checksums_ on the file, e.g. for `*.sha256sum` (08 › Verify checksums)                                                |
  | `**path\file.bar` | Open that button bar as a drop-down menu. Needs at least one visible button bar. `%P%N` etc. pass the file to the button command. |
  | `***command`      | Run an internal command, e.g. `***cm_List %1`                                                                                     |

- **Archive extensions** such as `.zip` (opened like folders) can have _Open_ redefined only with `***command`, and the
  extension must be written explicitly in the type mask (`*.zip *.rar`).
- The `>>` button next to Open opens a program picker, or the _Choose command_ dialog when the field holds `***` (14 ›
  The _Choose command_ dialog).
- **Save semantics:** a verb is saved when its own dialog closes. **Cancel** on Edit file type discards only that
  dialog's changes.

### 17.8 Storage

Internal associations are stored in `wincmd.ini [Associations]` and applied in numbered order (19 › `[Associations]`):

```ini
Filter1=*.txt
Filter1_open=""%windir%\notepad.exe" "%1""
Filter1_View=""%commander_path%\totalcmd.exe" /S=L "%1""
Filter1.icon=notepad.exe,-1
```

`[Associations]` and `[Extensions]` are among the sections that stay in the main `wincmd.ini` even when other sections
are redirected to an alternate ini file (19 › INI rules).

_Basis: observed on Windows 11 (Associate during plugin install, "Select an app") and under Wine (dialogs); help:
options_assotiate, dlg_assotiate, dlg_edit_file_type, dlg_edit_action, internal_associations,
dialog_box__edit_file_type_internal, proc_edit, inisettings, inisettings1, inisettings2, inisettings3._
