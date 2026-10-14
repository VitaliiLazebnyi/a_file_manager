# 14: Customisation

This chapter describes how the user changes what commands are bound to: the two button bars and their `.bar` files, the Start menu, main-menu (`.MNU`) files, user-defined `em_` commands, the *Choose command* dialog that all these editors share, and the redefinition of hotkeys and command-line aliases. It also defines the command language that buttons, menu items and hotkeys share. The commands themselves are catalogued in 17, the parameter placeholders in 18 and the exact file formats in 19.

**Related:** [02](02-main-window.md) (button bars on screen and in everyday use), [04](04-main-menu.md) (main-menu items), [05](05-mouse-context-menus-drag-drop.md) (button-bar context menus), [06](06-keyboard.md) (key reference, hotkey notation, key list), [12](12-other-tools.md) (directory hotlist editor), [13](13-configuration-dialog.md) (Options pages Misc, Icons, Language), [16](16-localisation.md) (language files), [17](17-internal-commands.md) (command catalogue, commands with parameters, `cm_` parameters), [18](18-syntax-reference.md) (parameter placeholders), [19](19-settings-files-and-command-line.md) (file formats, ini keys).

## 1. Where commands can be bound

Every binding dispatches through the one internal-command table (01 › Command system). Each editor below has a magnifier button that opens *Choose command* (§7).

| Place | Editor (command, Nr) | Stored in | What it can hold | Parameters |
|---|---|---|---|---|
| Main button bar | Configuration › Button Bar… (`cm_ButtonConfig` 498); a button's context menu | The `.bar` file named in `[Buttonbar] Buttonbar=` (default `default.bar`) | The full command language (§2), including subbars | *Parameters* field |
| Vertical button bar | Configuration › Button Bar 2 (Vertical)… (`cm_ButtonConfig2` 583) | The `.bar` file in `[ButtonbarVertical] Buttonbar=` (default `vertical.bar`) | As the main bar | *Parameters* field |
| Start menu | Start › Change Start Menu… (`cm_ChangeStartMenu` 700) | `[user]` in `wincmd.ini` | The command language except subbars | *Parameters* field; own *Shortcut key* |
| Main menu | A text editor, via Configuration › Options › Language › *Edit* (also Start › Change Main Menu…) | A `.MNU` file (`Mainmenu=`) | `cm_` names or numbers, `em_` names | None; use an `em_` command |
| Hotkeys | Options › Misc › *Redefine hotkeys* (`cm_Confirmation` 495) | `[Shortcuts]`, `[ShortcutsWin]` | `cm_`, `em_`, commands with parameters, programs | `<key>_params=` |
| Command-line aliases | Same dialog, *Alias* | `[Alias]` | As hotkeys | *Parameters*, with the alias-only `%A` codes |
| User commands `em_…` | *Choose command* › page `usercmd.ini` (`cm_CommandBrowser` 2924) | `usercmd.ini`, `wcmd_<lang>.ini` | A complete button definition | Yes |
| Directory hotlist | Ctrl+D › Configure… | `[DirMenu]` | `cd <path>` or any command, plus a target path | → 12 › Directory hotlist |
| Internal associations | Files › Internal Associations… | `[Associations]` | Commands per file type | → 10 › Associations |
| View-mode auto-run commands | Options › View Mode | `[ViewModes]` | Commands run on entering a mode | → 03 › View modes |

External programs can also send a command number to TC (`WM_USER+51`, see 17).

*Basis: observed under Wine (editors and menu entries); help: dlg_configbuttonbar, dlg_usermenu, dlg_mainmenu, dlg_configconfirmation, dlg_choosecommand.*

---

## 2. The command language

Buttons, Start-menu items and `em_` definitions share one language for the *Command*, *Parameters* and *Start path* fields. Hotkeys, aliases and internal associations accept the same command forms in their command field.

### 2.1 What the Command field can hold

| Kind | Example | Behaviour |
|---|---|---|
| Program | `notepad.exe`, `c:\tools\x.exe -fixed` | Started with the expanded Parameters, in the Start path, with the chosen window state. Fixed parameters may follow the program name. |
| Internal command | `cm_SrcThumbs`, `300`, `em_notepad` | Executed. A number from `totalcmd.inc` may replace the name (`300` = `cm_SrcComments`). |
| Chain | `cd "c:\windows",cm_SelectAll,cm_Copy` | Items executed in order, separated by commas |
| Change directory | `cd c:\temp\*.txt` | Changes the source panel, optionally with a file filter (§2.3) |
| Command with parameters | `OPENTABS my.tab` | A text command (§2.6) |
| Button bar file (buttons only) | `c:\bars\tools.bar` | A subbar (§3.3) |
| `*` alone | Command `*`, Parameters `%P%N` | Runs the Parameters field as administrator |

### 2.2 Grammar

```
command   := ['*' | '**'] program [fixedParams]    # * = run as administrator, ** = run as other user (Win 7+); full path required
           | '*'                                    # alone: run the Parameters field (e.g. %P%N) as administrator
           | chain
           | 'cd' SP target
chain     := item { ',' item }                      # a comma inside "double quotes" does not separate
item      := 'cm_'name [SP param] | number | 'em_'name [SP params]
           | 'cd' SP '"' path '"' | 'cm_wait' SP ms
target    := path ['\' mask] [SP '/user:' [username]]
           | '"' path-with-wildcards '"' { SP '"' … '"' }
           | 'shell:'Name | '::{GUID}' | 'ftp://'host[/path]
```

### 2.3 Rules

- **Extensions.** `.com` and `.bat` programs need the extension written out, because Windows finds only `.exe` by default. *Change >> › Insert file name…* (buttons) or `>>` (Start menu) browses for the program.
- **Environment variables** `%envvar%` are expanded in the Command field. The Parameters field uses `%|envvar|` instead (18).
- **Elevation.** With `*` or `**` while TC itself is not elevated: TC's own variables such as `%COMMANDER_PATH%` are not inherited, the Start path is usually ignored, and batch files (`.bat`, `.cmd`) may need `cmd.exe /c` in front.
- **Names** are case-insensitive. The shipped `default.bar` writes `cm_Rereadsource` and `cm_srcshort`.
- **Chains.**
  - `cm_wait 1000` pauses 1000 ms between two commands.
  - `cd` can be chained only with the path in double quotes: `cm_SrcShort,cd "c:\Windows"`.
  - Several `em_` commands with parameters can be chained (`em_notepad c:\a.txt,em_notepad c:\b.txt`). An `em_` parameter that contains a comma must be in double quotes. Nested `em_` commands run in the written order.
  - The help says a file mask cannot be used when `cd` is chained; the change log records `cd "c:\path\*.ext"` in a chain as working since 11.09.23 (unverified).
- **One parameter for a `cm_` command** is written after the name (`cm_SrcByName 2`) or, when the command is not chained, in the Parameters field. The parameters each command accepts: 17.
- **`em_` parameter rule.**
  - With the Parameters field empty, the text after the `em_` name is passed unchanged to the inner command and parsed there. Example: `em_notepad %P%N`, with `em_notepad` defined as `notepad.exe`, behaves like Command `notepad.exe`, Parameters `%P%N`.
  - With the Parameters field used, environment variables after the `em_` name are expanded first, and the result is passed on together with the Parameters field.
  - An `em_` command that calls itself (directly or through others) is detected and not executed.
- **Virtual folders:** `cm_OpenDesktop`, `cm_OpenDrives`, `cm_OpenControls`, `cm_OpenFonts`, `cm_OpenNetwork`, `cm_OpenPrinters`, `cm_OpenRecycled`; or `cd shell:Fonts`, `cd ::{GUID}`.
- **`cd` details.**
  - `cd dir\*.txt` also sets the panel's file filter. Several quoted masks are allowed: `cd "test 1.*" "test 2.*"`.
  - `cd path\file` places the cursor on the file. For a document that is also an archive format (e.g. Office files), the `CtrlArrowOpenArchive` setting decides as on the command line; a trailing `\` opens it as an archive.
  - `/user:` (lower case) connects to a share as that user: `cd \\server\share /user:username`. Without a name, TC asks for user name and password.
  - With `cd`, the Start path is applied to the **other** panel (§2.5).
- **FTP:** `cd ftp://ftp.server.com`; `FTPOPEN session` opens a saved connection; `FTPOPEN session|/subdir` connects in the preferred panel unless already connected, then changes to the subdirectory; `FTPOPEN session|*/subdir` does the same in the active panel (11).
- **Malformed input.** A command written as `"notepad.exe"filename.txt` (no space before the parameters) is still split correctly. A trailing space after a file name is ignored.

### 2.4 Parameters field

- The placeholders (`%P`, `%N`, `%S`, list files `%L`…, `%Y`, `%Z`, substrings `:~start,length`, quoting rules, `%X` left/right switch, the alias-only `%A` codes) are defined in 18 › Button and command parameters.
- A leading `?` shows the expanded parameters in a dialog before the program starts; the user can edit them or cancel.
- **Fixed parameters belong in the Command field**, after the program name. A drag & drop onto a button replaces the Parameters field with the dropped names (§3.4), so anything there would be lost.
- Text commands (§2.6) also accept placeholders such as `%P%N` when they are used in hotkeys and internal associations.

### 2.5 Start path and window state

- **Start path** is the working directory. Empty = the source panel's path. **If the Command is `cd <path>`, the Start path is set in the other (target) panel**, so one entry can set both panels.
- **Run minimized / Run maximized** set the window state of a started program (`iconicN` in the files: `1` = minimized; maximized presumably `-1`, not documented).

### 2.6 Commands with parameters

The text commands `CD`, `OPENTABS`, `APPENDTABS`, `SAVETABS*`, `SAVETABS2*`, `FTPOPEN`, `SYNCOPEN`, `LOADSEARCH`, `MULTIRENAME`, `OPENCUSTOMVIEW`, `SELECTFILES`, `SAVESELECTION`, `SAVEDETAILS`, `LOADSELECTION`, `LOADLIST`, `ZIPFROMLIST`, `OPENATTRIBUTES`, `OPENLANGUAGEFILE`, `CM_WAIT`, `OPENBAR`, `OPENBAR1`, `OPENBAR2` and `OPENBARMENU` take their parameter after a space; modifier letters are appended to the name (`OPENTABSL`, `SELECTFILESDUT`). Their full semantics: 17 › Commands with parameters. The bar commands are described in §3.3, the hotkey form of suffixed variants in §8.1.

*Basis: help only (dlg_configbuttonbar, dlg_usermenu, dlg_choosecommand), with the change log for chains, `em_` parameters and `cd` details.*

---

## 3. Button bars

Their appearance, keyboard focus (Alt+Shift+F11 / Alt+Shift+F12), tooltips on hover and showing or hiding the vertical bar are described in 02 › Button bars; the keys inside a focused bar in 06 › Button bars; the context menus in 05 › Horizontal button bar and 05 › Vertical button bar and panel separator. This section covers files, subbars, drops, icons and the editor.

### 3.1 Bar files and the default bar

- There are two bars, each showing the contents of one `.bar` file: the main horizontal bar (`[Buttonbar] Buttonbar=`, default `default.bar`) and the vertical bar (`[ButtonbarVertical] Buttonbar=`, default `vertical.bar`).
- **Which file is loaded:**

```
bar = [Buttonbar] Buttonbar=                     ; the user's default bar
if bar is empty:
    bar = <program dir>\default.bar
    if that file is not writable
       and it does not contain  [options] redirect=0 :
        copy it to the folder of wincmd.ini and use the copy from then on
; the same for vertical.bar; the copy is also made when TC runs elevated
```

- On the Windows 11 test installation the first start copied `default.bar` (977 bytes, byte-identical to the shipped file) and `vertical.bar` (417 bytes) to `%APPDATA%\GHISLER`, next to `wincmd.ini`, and wrote the icon caches `default.br2` and `vertical.br2` (§3.8).
- **Making another bar the default:** choose a `.bar` file with `>>` in *Change button bar* and press OK; TC asks whether the chosen bar should become the default. The default bar is loaded at every start, and again whenever the bar is hidden and shown on the Layout page.
- **Write failure.** If saving a `.bar` file fails, TC offers "Copy it to a directory in your profile" or "Grant yourself write rights (requires admin rights)" (captions from the change log). The new location is stored only for the bar that was being saved.
- **Other instances.** Saving a bar makes every other running TC instance on the PC reload it.
- **Limits:** at most 1000 buttons per bar and 64 KB per `.bar` file.
- `NO.BAR` (shipped) is an empty bar.

### 3.2 Layout rules

- The main bar wraps onto further rows when its buttons do not fit. `[Buttonbar] BarLimitLines=0` caps the number of rows (0 = no limit).
- A **manual line break** entry (§3.9) forces a new row. How a line break lays out in the vertical bar is not documented; the shipped `vertical.bar` starts with two of them, which most likely produce the space above its first button.
- When the vertical bar is too tall for the window, an **overflow (triangle) button** appears; the remaining buttons open from it as a popup menu. Space, Shift+F10 or the context-menu key on the overflow button opens that menu.
- A **separator** is a thin gap.

### 3.3 Subbars and bar menus

A button whose command is a `.bar` file (or `OPENBAR…`) is a **subbar** button.

| Situation | Effect |
|---|---|
| Click, *Show as menu* off | The bar the button is in switches to the linked file |
| Click, *Show as menu* on | The linked bar opens as a drop-down menu below the button |
| Shift+click | The opposite of the *Show as menu* setting |
| `OPENBAR file.bar` | Loads the file into the bar the button is in. `OPENBAR1` = into the main bar, `OPENBAR2` = into the vertical bar. Parameter `*` = the default bar of that bar (`OPENBAR1 *`). |
| `OPENBARMENU file.bar` | Opens the file as a drop-down menu. `.\name.bar` = a file in the current directory; `*` = the default bar. The file may also be given in the Parameters field. Works also when no main button bar is shown. |
| Internal association `**path\file.bar` | Opens that bar as a menu for the file type (10 › Associations); use `%P%N` in its buttons to pass the file |

- Buttons that open a bar as a menu carry a small arrow overlay (`PopupOverlay=1`). `PopupIconSize=` sets the icon size in bar menus (default: the bar's own icon size).
- **Bar shown as a menu:** an entry with an empty command is a separator, even if it has an icon or tooltip, except that an entry with no command but a tooltip text is shown as a text line; separators at the start of the bar are hidden. An entry with a command and a tooltip but no icon is shown as a text item. `cm_` and `em_` commands with parameters work there. Space or Shift+F10 on a menu item opens its context menu; for a program item it has the extra entry "cd path of program".
- **Editing subbars** (in *Change button bar*): *Change >> › Add subbar >>* asks for an existing or a new bar name (`.bar` is appended when no extension is given) and opens **a second editor window** for that bar. Circular references are allowed (bar 1 → bar 2 → bar 3 → bar 1), but a bar must not be edited in two windows at once. To link a **different** bar at a position that already has one, clear the old file name first. The change log also names *Edit .bar file >>*, which opens the selected subbar for editing; it was not in the observed menu, where the current button was a program.
- While a subbar is being edited, the *Button bar* file name is locked (§3.6).

### 3.4 Drag and drop onto a bar

| Gesture | Effect |
|---|---|
| Drop file(s) onto a button | That button's program starts with the dropped file (or the first marked file) as its parameter, replacing the Parameters field. Also allowed for `em_` buttons without parameters. |
| Drop onto empty bar space, or drop with **Shift** held | A new button for the file is inserted at the drop position |
| Drop a `.bar` file to insert | The new button is a subbar button |
| Drop a `.lnk` file to insert | The icon is taken from the link's icon file; if the link names none, from the `.lnk` itself (e.g. links to Windows apps) |
| Drop a `.url` file to insert | The icon is taken from `[InternetShortcut] IconFile=` of the file |

The drop rules for panels and other targets: 05 › Drag & drop.

### 3.5 Editing from the bar itself

The context menus are listed in 05 › Horizontal button bar and 05 › Vertical button bar and panel separator. Their editing items:

- **Change…** on a button opens the single-button dialog (§3.7); on empty space it opens *Change button bar* for that bar (*Change vertical button bar…* on the vertical bar).
- **Delete** removes the button after a confirmation that names the button.
- **Cut** / **Copy** put the button definition on the clipboard; it can be pasted into another bar. The internal number of an `em_` command (≥ 10000) is not copied.
- A separator can be turned into a line break from its context menu.
- **Set default icon library** (empty space): §3.8.
- **Hide button bar** (vertical bar only) asks for confirmation.

### 3.6 The *Change button bar* dialog

Opened by Configuration › Button Bar… / Button Bar 2 (Vertical)…, or *Change…* on empty bar space. The vertical bar uses the same dialog with `vertical.bar`.

```
Button bar: [<path>\default.bar                               ] [>>]
            ┌─────────────────────────────────────────────┐ ┌ Appearance ─────────┐
[ Add... ]  │ ⟳ │ ▦ ▤ ▣ ⑂ │ ⇶ │ ✱ │ ← → │ ▼ ▲ │ FTP URL │ ✎ │ │ Size: [24]          │
[ Delete ]  └[<]────────────────────────────────────────[>]┘ │ [x] XP style        │
                                                            │ [x] Flat icons      │
                                                            │ [x] Small icons [16]│
                                                            └─────────────────────┘
Command:    [notepad.exe                          ] [🔍]     [ Change >> ]
Parameters: [                                     ]          [ ] Run minimized
Start path: [                                     ]          [ ] Run maximized
Icon file:  [notepad.exe                          ] [>>]
Icon:       [0    ] [ icons of the icon file … ][<][>]  [->.ico]
Tooltip:    [Notepad                              ]
                                              [ OK ] [ Cancel ] [ Help ]
```

| Field | Behaviour |
|---|---|
| **Button bar** + `>>` | Path of the bar being edited; `>>` loads another bar (and on OK offers to make it the default, §3.1). The name can be changed only for the default bar; it is locked while a subbar is being edited. |
| Preview strip | The bar as raw icons, scrollable with `[<]` `[>]`. Click a button to edit it. **Shift+←/→** or dragging moves the selected button. |
| **Size** | Button size in pixels; 32 corresponds to the normal icon size. 24 in the observed installation. Stored per screen DPI (`Buttonheight`, `Buttonheight<dpi>`, `DefaultDpi`; depends on DPI, see Appendix A). |
| **XP style** | Draw the buttons with the current visual theme (`XPstyle=1`) |
| **Flat icons** | No 3-D frame; themed toolbar buttons supported (`FlatIcons=1`) |
| **Small icons** [16] | Checked: icons are scaled to the given size (`SmallIcons=1`, `SmallIconSize=16`). Unchecked: icons are scaled to the button size. |
| **Add…** | Inserts a new entry **directly after** the current one |
| **Delete** | Removes the current entry |
| **Command** + 🔍 | Command text (§2). 🔍 opens *Choose command*. If the field already **ends** with a comma, the chosen command is **appended**; if it **starts** with a comma followed by a command, the chosen command is **put in front**; otherwise it replaces the field. |
| **Change >>** | Menu: *Insert file name…* (browse for a program), *Insert separator*, *Insert line break*, *Add Subbar >>* (§3.3) |
| **Parameters** | §2.4 |
| **Start path** | §2.5 |
| **Run minimized / Run maximized** | Window state (§2.5) |
| **Show as menu** | Only for `.bar` targets: show the linked bar as a popup menu instead of switching to it (§3.3). Most likely stored in the same `iconicK` flag as Run minimized (`1`); its position in the dialog was not recorded. |
| **Icon file** + `>>` | File to take the icon from (exe, dll, icl or ico). For a program, the program itself. For internal commands use `wcmicons.dll` **without a path**, so that the default-library substitution works (§3.8). `@anyname.ext` = the default icon of extension `.ext` (useful for Windows Store apps). Environment variables are allowed. |
| **Icon** | Shows every icon in the icon file. The index field is an edit box: typing a number selects that icon; clearing it does not change the selection. **Negative numbers are resource IDs**; if an icon with that ID exists it is shown in the list. |
| **->.ico** | Extracts the shown icon to a separate `.ico` file and puts that file into *Icon file* (hold **Shift** to leave *Icon file* unchanged). Icons then show even when the original file is unreachable (e.g. on a network drive), and `.ico` files load faster than exe or dll files, mainly because of virus scanners. |
| **Tooltip** | Hint text (`menuK`). `\|` is a line break, `\|\|` a literal `\|`, and **a single space suppresses the tooltip** (also in the context menu and the delete confirmation, which then show no text). When empty: a `cm_` button shows the command's translated description; an `em_` button shows the tooltip of its definition, taken from `wcmd_<lang>.ini` before `usercmd.ini`. `\|` is interpreted only in user-written tooltips, not in derived ones. |
| **OK** | Writes the `.bar` file and notifies other instances (§3.1) |
| **Cancel** | Discards the changes |

### 3.7 The single-button dialog

*Change…* in a button's context menu opens a dialog with the fields of the lower part of *Change button bar*: Command, Change >>, Parameters, Start path, the window-state boxes, Icon file, Icon, ->.ico and Tooltip, with OK, Cancel and Help. OK saves the bar file at once.

### 3.8 Icons and icon libraries

- **`wcmicons.dll`** in the program folder holds the default icons for internal commands. **`WCMICONS.INC`** maps command numbers to icon indices in its `[mappings]` section, as `<command nr>=<icon index>` (about 230 lines), e.g. `540=0` (Reread source), `301=3`, `302=4`, `907=29` (Make directory). The mapping gives the main-menu icons and the default icon when a command is chosen for a button or an `em_` definition. The shipped bars use exactly these indices.
- **Several libraries.** A second library (`wcmicon2.dll`, "TCNewLib1", flat "new" icons) is shipped. At the first start the user chooses between them:

```
Default icon library for button bar and main menu:
(o) 1: wcmicons.dll                       ▣▣▣▣▣▣  (sample icons)
( ) 2: [wcmicon2.dll: TCNewLib1      ▾]   ▢▢▢▢▢▢  (sample icons)
                                       [ OK ] [ Cancel ]
```

  The choice is stored as `[Buttonbar] DefaultLib=` (default `wcmicons.dll`) and `FirstTimeIconLib=0` is written. *Set default icon library* (Icons page, or a bar's empty-space context menu) changes it later. The library ships icons in 16, 24, 32 and 48 px.
- **Substitution.** Every button whose icon file is `wcmicons.dll` **without a path** draws the icon with the same index from the chosen library. A library may ship its own `.inc` file; if its index for a command differs from `WCMICONS.INC`, the button keeps that library and does not follow later changes. When such an `.inc` exists, it is used for the **whole main menu**. If the selected library disappears, TC falls back to `wcmicons.dll`. A missing `WCMICON*.DLL` is treated like main-menu icons turned off.
- **Installing a library as an add-on.** An auto-install package (15 › Automatic installation) with `type=prg` and a file named `WCMICON<unique>.DLL` makes that library the default and reloads the bars.
- **Icon cache.** TC keeps a binary cache per bar file, `<bar name>.br2` (DIB bitmaps), next to the bar file; on Windows 11 `default.br2` (77,710 bytes) and `vertical.br2` (25,906 bytes) at 200 % scaling. `[ButtonbarCache] IconDll_<barfile>=` (e.g. `IconDll_default.bar=`) remembers the library the bar was last drawn with, to decide whether the cache must be rebuilt; it is rebuilt when the bar or the library changes. `cm_ReloadBarIcons` (2945) forces a reload of the icons of both bars and the main menu; the bar stays on the subbar currently shown.
- **Icons in the Start menu and main menu.** For `em_` commands, icons are shown only when they come from `wcmicons.dll` (no index = the first icon), `.ico` files, `shell32.dll`, `imageres.dll` or the TC executable (`%COMMANDER_EXE%` or the program name without path); negative indices (resource IDs) work. Other exe and dll files are not used, for speed (virus scanners). A Start-menu item for `cm_UserMenuN` can get an icon through `WCMICONS.INC`, e.g. a line `710=81` gives the 10th item icon 81, unless its `em_` command defines its own.

### 3.9 Semantics of a `.bar` file

A `.bar` file is an INI file (ANSI or UTF-16) with one `[Buttonbar]` section; entries are numbered 1…`Buttoncount`. The key-by-key format and the raw shipped files are in 19 › `.bar` files.

| Entry kind | Stored as | Behaviour |
|---|---|---|
| Separator | `buttonK=` empty and no `cmdK` (an `iconicK` may be present) | Thin gap |
| Manual line break | `buttonK=` empty and `cmdK=-2` | New row (§3.2). `-2` here is not the pseudo-number of `CD` (§7.4). |
| Program | `cmdK=<exe> [fixed params]`, icon usually the program | §2 |
| Internal command(s) | `cmdK=cm_…` / `em_…` / number / chain, icon `wcmicons.dll,<index>` | §2 |
| Subbar / bar menu | `cmdK=<file.bar>` or `OPENBAR…` / `OPENBARMENU …`; `iconicK=1` = show as menu | §3.3 |

The other keys: `buttonK` (icon `file[,index]`, index 0 when omitted), `paramK`, `pathK`, `menuK` (tooltip; empty = command description), `iconicK` (`0` normal, `1` minimized or show as menu). An optional `[options] redirect=0` turns off the copy to the `wincmd.ini` folder (§3.1).

Reading and writing: read `Buttoncount`, then entries 1…N, treating missing keys as empty; keep unknown keys and the `[options]` section when rewriting.

**Shipped bars** (the defaults a clone shows). `DEFAULT.BAR`, 26 entries (18 buttons, 8 separators); tooltips come from the command descriptions except #26:

| # | Icon (`wcmicons.dll` index) | Command | # | Icon | Command |
|---|---|---|---|---|---|
| 1 | 0 | `cm_Rereadsource` (540) | 14 | — | separator |
| 2 | — | separator | 15 | 30 | `cm_PackFiles` (508) |
| 3 | 3 | `cm_srcshort` (301) | 16 | 31 | `cm_UnpackFiles` (509) |
| 4 | 4 | `cm_srclong` (302) | 17 | — | separator |
| 5 | 26 | `cm_SrcThumbs` (269) | 18 | 16 | `cm_FtpConnect` (550) |
| 6 | 51 | `cm_SwitchSeparateTree` (3203) | 19 | 17 | `cm_FtpNew` (551) |
| 7 | — | separator | 20 | — | separator |
| 8 | 50 | `cm_DirBranch` (2026) | 21 | 47 | `cm_SearchFor` (501) |
| 9 | — | separator | 22 | 46 | `cm_MultiRenameFiles` (2400) |
| 10 | 11 | `cm_ExchangeSelection` (525) | 23 | 48 | `cm_FileSync` (2020) |
| 11 | — | separator | 24 | 45 | `cm_CopyFullNamesToClip` (2018) |
| 12 | 18 | `cm_GotoPreviousDir` (570) | 25 | — | separator |
| 13 | 19 | `cm_GotoNextDir` (571) | 26 | `notepad.exe` | `notepad.exe`, tooltip `menu26=Notepad` |

`VERTICAL.BAR`, 9 entries, each with `iconicK=0`: two line breaks (`cmdK=-2`), `cm_List` (903, icon 27), `cm_Edit` (904, icon 28), `cm_Copy` (905, icon 62), `cm_RenMov` (906, icon 63), a separator, `cm_PackFiles` (508, icon 30), `cm_MkDir` (907, icon 29).

### 3.10 Bar settings in `wincmd.ini`

`[Buttonbar]` (main bar); `[ButtonbarVertical]` uses the same key names. Full reference: 19 › `[Buttonbar]`.

| Key | Default | Meaning |
|---|---|---|
| `Buttonbar=` | — | Bar file; empty = `default.bar` / `vertical.bar` (§3.1) |
| `Buttonheight=`, `Buttonheight<dpi>=`, `DefaultDpi=` | — | Button size per DPI |
| `SmallIcons=` | 1 | Small-icon mode |
| `SmallIconSize=`, `SmallIconSize<dpi>=` | 16 | Icon size in small-icon mode |
| `FlatIcons=` | 1 | Flat (1) or 3-D (0) |
| `XPstyle=` | 1 | Themed buttons |
| `BarLimitLines=` | 0 | Maximum rows; 0 = unlimited |
| `DefaultLib=` | `wcmicons.dll` | Default icon library for both bars and the main menu |
| `PopupIconSize=` | bar's icon size | Icon size in bar drop-down menus |
| `PopupOverlay=` | 1 | Arrow overlay on buttons that open a menu |
| `[ButtonbarCache] IconDll_<barfile>=` | empty | Library last used to draw that bar |

*Basis: observed under Wine (dialog, context menus) and on Windows 11 (first-start files, icon-library chooser); help: add_btnbar, dlg_configbuttonbar, options_configbuttonbar, drag_drop, dlg_configicons, inisettings3; DEFAULT.BAR, VERTICAL.BAR, NO.BAR, WCMICONS.INC; change log.*

---

## 4. Start menu

### 4.1 The menu

- The **Start** menu sits in the menu bar where the `.MNU` file has `STARTMENU` (§5). The user's items appear **above** the two fixed entries *Change Start Menu…* (`cm_ChangeStartMenu` 700) and *Change Main Menu…* (opens Configuration › Options › Language, §5.1).
- Items are entries in `[user]`; submenus and separators are possible. `&` in a title marks the accelerator.
- An item runs its command with the file under the cursor available through the parameters (§2.4).
- **By command:** `cm_UserMenu1` … `cm_UserMenu10` (701–710) run the 1st…10th item. More IDs (711 …) can be declared in `totalcmd.inc`.
- **Icons:** items have no icon field; an item shows the icon of its `cm_` or `em_` command under the rules of §3.8.
- **Shortcut key:** each item can carry its own hotkey (§4.2). Precedence between it and a `[Shortcuts]` entry for the same key is not documented.

### 4.2 The *Change start menu* dialog

```
Start menu:
┌───────────────────────────────────┐  [ Add Item...     ]
│                                   │  [ Add submenu...  ]
│                                   │  [ Delete Item     ]
│                                   │  [ Change Title... ]
└───────────────────────────────────┘  [ OK ] [ Cancel ] [ Help ]
Command:      [                       ] [🔍] [>>]
Parameters:   [                       ]
Start path:   [                       ]
Shortcut key: [                     ▾]
[ ] run minimized     [ ] maximized
? as the first parameter: invokes dialog to enter parameters
%p: inserts actual source path          %t: the actual target path
%n: inserts file name under the cursor  %%: the percent sign
```

| Control | Behaviour |
|---|---|
| **Start menu** list | All entries in order; selecting one shows its data below. Submenus show with a leading `-`, a submenu end as `--`. **Shift+↑/↓** or dragging moves an entry. The number of the current item (1-based, as in `wincmd.ini`) is shown above the list. |
| **Add Item…** | Asks for a title. `&` underlines the next letter. A title of a single `-` makes a separator. |
| **Add submenu…** | Asks for a title and starts a submenu |
| **Delete Item** | Removes the entry. **Cancel** undoes **all** changes made in the dialog. |
| **Change Title…** | Renames the entry |
| **Command** + 🔍 + `>>` | The command language of §2, **except subbars**. `>>` browses for a file; 🔍 opens *Choose command* (with the same append/prepend rule for commas as on buttons). |
| **Parameters** | §2.4, without the alias-only `%A` codes. The caption's short list simplifies: lower-case `%p`, `%t`, `%n` insert the **8.3** forms; the long forms are `%P`, `%T`, `%N` (18). |
| **Start path** | Empty = the source path; with a `cd` command, the path is set in the **other** panel |
| **Shortcut key** | Hotkey that runs the item |
| **run minimized / maximized** | Window state |
| **OK** | Writes `[user]` to `wincmd.ini`. If that fails, TC offers to copy the ini files to the user profile. |

The dialog's position is saved as `MenuChange*` in the resolution section; it is separate from the position of the hotlist editor.

### 4.3 Storage

`[user]` in `wincmd.ini`, 1-based: `menuN` title (`-` = separator, `-Name` = submenu start, `--` = submenu end), `cmdN`, `paramN`, `pathN`, `iconicN` (`1` = minimized), `keyN` (shortcut key). `[DirMenu]` (the directory hotlist) uses the same item keys. Format: 19 › `[user]`.

*Basis: observed under Wine (dialog and menu); help: dlg_usermenu, menu_starter, inisettings3; totalcmd.inc; change log.*

---

## 5. Main-menu files (`.MNU`)

### 5.1 Selecting and editing a menu file

- The main menu is read from the file in `[Configuration] Mainmenu=`. Empty = the menu built into the program (English).
- Configuration › Options › **Language** (13): choosing a language selects its `WCMD_xxx.MNU` automatically. *Main menu file* `[…] [>>] [Edit]`: `>>` browses for a file, **Edit** (enabled when a file is set) opens it in Notepad. Start › *Change Main Menu…* opens this page.
- `OPENLANGUAGEFILE WCMD_xyz.MNU` switches only the menu; `OPENLANGUAGEFILE .MNU` restores the internal menu (16).
- **Updates overwrite the shipped `.MNU` files.** A customised menu must be saved under another name and selected on the Language page.

### 5.2 Grammar

```
menufile   := { line }                          # plain text, CRLF; free indentation; blank lines allowed
line       := 'POPUP' SP quoted                 # opens a (sub)menu; POPUPs nest
            | 'MENUITEM' SP quoted SP? ',' SP? id
            | 'MENUITEM SEPARATOR'
            | 'END_POPUP'                       # closes the innermost POPUP
            | 'STARTMENU'                       # menu-bar level only
            | 'HELP_BREAK'                      # menu-bar level only
quoted     := '"' text '"'                      # '&x' = accelerator (underlined, Alt+x); '\t' = tab
id         := 'cm_'name | 'em_'name | number    # number = value from totalcmd.inc
```

### 5.3 Rules

- Top-level `POPUP`s are the menu-bar entries; nested `POPUP`s are submenus. A POPUP title may also contain `\t` (e.g. `"Separate Tree\tCtrl+Shift+F8"`).
- `\t` in an item text becomes a tab: the text after it is the right-aligned shortcut column. It is display text only; keys are defined in `[Shortcuts]` (§8) and a remapped key does not change what the menu prints.
- **Identifiers.** `cm_` names are resolved through **`totalcmd.inc`**, which **must be present at runtime** when an external menu file is used. Numbers from `totalcmd.inc` may be used instead of names; names are case-insensitive (the shipped file mixes `cm_Clearall`, `cm_exchange`, …). User commands `em_…` are allowed. Only identifiers in `totalcmd.inc`, plus `em_` commands, are valid. Prefix convention: `cm_Src…` acts on the source panel, `cm_Left…` on the left, `cm_Right…` on the right.
- **No parameters.** A menu item cannot pass a parameter to a command (commands that take `0`/`1`/`2` elsewhere take none from the main menu). To run a command or program with parameters from the menu, define an `em_` command (§6).
- **`STARTMENU`** inserts the user's Start menu (§4) at that position of the menu bar.
- **`HELP_BREAK`** right-aligns every menu after it. `STARTMENU` must not directly follow `HELP_BREAK`. `HELP_BREAK` has no effect in right-to-left languages.
- **Icons:** with *Show icons for commands in the main menu* on (Icons page, 13), each item shows the `wcmicons.dll` icon mapped to its command number by `WCMICONS.INC`, or by a library's own `.inc` (§3.8).

### 5.4 Dynamic parts

Not in the file: the checked and radio state of items (e.g. in Show, following the panel state); the `*.*` item, whose caption is replaced by the last user mask; the contents of *Custom Columns Mode* and *Custom View Modes*, which are generated submenus; and the Start menu inserted at `STARTMENU`.

### 5.5 The shipped English menu

`LANGUAGE\WCMD_ENG.MNU` defines, in order: `POPUP "&Files"` (with a nested `POPUP "Prin&t"`), `"&Mark"`, `"&Commands"`, `"&Net"`, `"Sho&w"` (with a nested `POPUP "Separate Tree\tCtrl+Shift+F8"`), `"C&onfiguration"`, then `STARTMENU`, `HELP_BREAK` and `POPUP "&Help"`. Items refer to commands partly by name and partly by number (e.g. `MENUITEM "Test Arch&ive(s)\tAlt+Shift+F9",518`, `MENUITEM "&Quit\tAlt+F4", 24340`). Every item with its caption, accelerator, shortcut text and command: 04; the raw file: 19 › `.MNU` files.

*Basis: observed under Wine (Language page, Start menu entries); help: dlg_mainmenu, dlg_configlanguage, menu_starter, dlg_configicons; LANGUAGE/WCMD_ENG.MNU, TOTALCMD.INC; change log.*

---

## 6. User commands (`em_`)

### 6.1 Concept

An `em_` command is a named, complete button definition (Command, Parameters, Start path, icon, tooltip, window state). It can be used wherever a `cm_` command can: main menu, hotkeys, aliases, buttons, Start menu, directory hotlist, internal associations and view-mode auto-run commands. Its main use is to run a program **with parameters** from places that cannot hold parameters themselves, such as the main menu.

### 6.2 Defining

User commands are managed on the pages **usercmd.ini** (and, when the language provides one, **wcmd_<lang>.ini**) of *Choose command* (§7). Only there do these buttons appear:

| Button | Effect |
|---|---|
| **New…** | Defines a new command `em_<name>` in a definition dialog with the fields of a button (§3.6): Command (with 🔍), Parameters, Start path, Icon file and Icon (with `->.ico`, which also exports icons from exe/dll files), Tooltip, window state |
| **Edit…** | Opens the same dialog for the selected command |
| **Delete** | Deletes the selected command |
| **Rename/Copy…** | Renames the command, or copies it under a new name. Lines longer than 259 characters are preserved. |

If writing to `usercmd.ini` fails during Delete, Rename or Copy, an error is shown.

### 6.3 Execution rules

- Parameters after the name and in the Parameters field: §2.3 (`em_` parameter rule). An `em_` command can contain other `em_` commands, also as its first command; recursion is detected and blocked; nested commands run in the written order.
- `em_` commands receive internal numbers ≥ 10000 at run time. They are not stable identifiers and are never copied to the clipboard.
- **Tooltip** on a button without its own tooltip: the definition's tooltip; when the same `em_` name exists in both files, `wcmd_<lang>.ini` wins. `|` in it becomes a line break.
- **Icons** in the Start menu and main menu: §3.8.

### 6.4 Storage

One section per command in `usercmd.ini` (location not documented, presumably next to `wincmd.ini` (unverified); not created by the first start, so the page is empty in a fresh installation), named after the command, e.g. `[em_recurse]` with `cmd=…`. Only `cmd=` is attested; the other keys presumably mirror a `.bar` entry without the number (`button=`, `param=`, `path=`, `menu=`, `iconic=`) (unverified). A language can ship its own `wcmd_<lang>.ini` with `em_` commands. Format: 19 › `usercmd.ini`.

*Basis: help only (dlg_choosecommand, dlg_configbuttonbar, dlg_usermenu), with the change log for recursion, numbering, tooltips and icons.*

---

## 7. The *Choose command* dialog

### 7.1 Purpose and entry points

The dialog picks an internal command from `totalcmd.inc`, or an `em_` command, and manages user commands. It opens from the 🔍 button in the button-bar editors, the single-button dialog, the Start-menu editor, the hotkey/alias remapping, the `em_` definition dialog, the directory hotlist editor and the view-mode auto-run field, and on its own with `cm_CommandBrowser` (2924). Its position is saved as `CmdSelX/Y/DX/DY/Max` in the resolution section.

### 7.2 Layout

A resizable dialog:

```
┌ Category ─────────┐ ┌ Command ───────────────┬─ Nr. ─┬─ Description ──────────────────┐
│ All               │ │ Source ====            │       │                                │
│ Source            │ │ cm_SrcComments         │ 300   │ Source: Show comments          │
│ Left              │ │ cm_SrcShort            │ 301   │ Source: Only file names        │
│ …                 │ │ …                      │       │                                │
│ usercmd.ini       │ │                        │       │                                │
└───────────────────┘ └────────────────────────┴───────┴────────────────────────────────┘
Filter: [__________]      [ New... ] [ Edit... ] [ Delete ] [ Rename/Copy... ]   [ OK ] [ Cancel ]
                          (only on the usercmd.ini / wcmd_<lang>.ini pages)
```

### 7.3 Elements

| Element | Behaviour |
|---|---|
| **Category** list (left) | *All* first, then the categories (§7.4), then the user-command pages. Its width adapts to the longest name, up to half the minimum window width. |
| Command list | Columns **Command**, **Nr.** (numeric value) and **Description** (translated). In *All*, each category starts with a header row `Name ====`. Opened from hotkey remapping, the first entry is *Default command (no remapping)*. |
| **Filter** | Has the focus when the dialog opens. Shows only commands containing the typed word, live. Shift+Home/End work in it. |
| **Ctrl+C** | Copies the command name: in the list, from the right-click menu, and from the filter box when no text is selected there |
| **Ctrl+Shift+C** | Copies the whole line including the description. Shift+double-click and Shift+OK also copy. |
| **OK** / double-click | Returns the chosen command to the calling field (§3.6 for the comma rules) |

### 7.4 Categories

The categories come from the separator lines of `totalcmd.inc`, which look like `[________________Source________________]=0`; the text between the underscores is the title. Other lines read `cm_Name=<number>;<English description>`; lines starting with `;` are comments. The language file supplies the translated descriptions (16).

| Category | Entries | Category | Entries |
|---|---|---|---|
| Source | 22 | Navigation | 37 |
| Left | 24 | Help | 6 |
| Right | 24 | Window | 4 |
| File Operations | 37 | Command Line | 7 |
| Configuration | 36 | Tools | 15 |
| Network | 6 | View | 51 |
| Misc | 33 | User | 10 |
| Parallel Port | 3 | Tabs | 69 |
| Print | 3 | Sorting | 44 |
| Mark | 46 | Custom Column Views | 49 |
| Security | 3 | View Modes | 41 |
| Clipboard | 15 | Commands with Parameters | 27 |
| FTP | 9 | usercmd.ini | user-defined; empty by default |

The commands of each category: 17.

**Commands with Parameters.** This category lists the text commands of §2.6, each with its parameter syntax and the modifiers it supports. In `totalcmd.inc` they carry negative pseudo-numbers −2 … −28; a comment there states that these "are just used for translation and cannot be used instead of the commands". For example, `-2` in a `.bar` `cmd` field is the line-break marker, not `CD`.

*Basis: observed under Wine (layout); help: dlg_choosecommand; TOTALCMD.INC; change log.*

---

## 8. Redefining hotkeys and aliases

The key list of the dialog and the `[Shortcuts]` notation are in 06 › Hotkey notation; the page's other controls in 13 › Misc.

### 8.1 The dialog

Configuration › Options › Misc › *Redefine hotkeys (Keyboard remapping)* (`cm_Confirmation` 495):

```
(o) Hotkey: [▼] [ ]Ctrl+ [ ]Alt+ [ ]Shift+ [ ]Win+ [key           ▾]
( ) Alias:  [                ▾]
Command:    [Default command (no remapping)          ] [🔍] [✓]
Parameters: [                                         ]
```

A mapping binds a **hotkey** or a command-line **alias** to a `cm_` command, an `em_` command, a command with parameters, or an external program, plus optional parameters.

| Step | Rule |
|---|---|
| Choose the key | Tick the modifiers and choose the key in the list. To pick a key by pressing it: click the list twice (this focuses it and closes it), then press the key. Win+key works unless Windows reserves the combination (e.g. Win+E). `OEM_…` codes depend on the keyboard layout (`OEM_US[{` = the key labelled `[{` on a US keyboard). Keypad digits 0–9 work only with NumLock on. |
| `[▼]` | Lists the mappings defined so far (empty by default). Choosing one loads it for editing. Esc closes the list and keeps the last chosen hotkey. |
| Command | Type it, or use 🔍 (*Choose command*). Its first entry, *Default command (no remapping)*, undefines the key. |
| Parameters | Passed to the command; not every command takes parameters (17). Placeholders such as `%P%N` are allowed. **Suffix variants** such as `OPENTABSL` or `SELECTFILEST` are set up by choosing the base command (`OPENTABS`, `SELECTFILES`) and writing the suffix as the **first token** of Parameters: `L filename.tab`, `T *.txt`. |
| `[✓]` | Stores the mapping. With an existing mapping selected, the button shows a red **X** and removes it. |

The dialog does **not** warn when a hotkey is already used internally, because TC handles its internal hotkeys through a separate, faster mechanism. A `[Shortcuts]` entry replaces the built-in function of that key in the main window.

### 8.2 Removing a mapping

Any of: choose the key in `[▼]`, then *Default command (no remapping)* (the help also calls it "the very first option (Predefined command)") and confirm with the checkmark; or choose the key and click the red X; or delete the line in `wincmd.ini`.

### 8.3 Aliases

*Alias* defines a word for the command line, e.g. `np` for Notepad. Typing the alias, optionally followed by words, runs the command; the words are available as `%A`, `%A<n>` … in Parameters (18 › Alias-only codes). Example: alias `op`, Command `totalcmd.exe`, Parameters `/L=%A1 /R=%A2`; typing `op c:\dir1 d:\dir2` runs `totalcmd.exe /L=c:\dir1 /R=d:\dir2`. The name `RedirectSection` is reserved and refused.

### 8.4 Storage

`[Shortcuts]` holds `<keyname>=<command>` (e.g. `CAS+F2=cm_RenameOnly`) and an optional `<keyname>_params=`; combinations with the Windows key go into `[ShortcutsWin]` with the same syntax. F13…F24 work when typed into `[Shortcuts]` by hand. `[Alias]` holds one key per alias; its value layout is not documented (presumably the same command plus `_params` pattern, unverified). `AlternateUserIni` does not move these sections. Format: 19 › `[Shortcuts]`.

### 8.5 Where redefined keys do not take effect

The help gives no list of protected keys. Documented limits:

- Only keys in the dialog's list can be chosen there; F13–F24 only by editing the ini.
- `[Shortcuts]` applies to the main window. No remapping exists for Lister, dialogs or tool windows.
- Hotkeys that Windows reserves, or that another program registers system-wide (the FAQ names GeForce Experience, which takes Alt+F1 and Alt+F5 among others), never reach TC.
- Some hotkeys such as Ctrl+letter are not remapped while the cursor is in the command line.

Rules from the change log, which keep text editing and dialogs working:

| Rule | Date |
|---|---|
| Outside the file and tree panels (e.g. in the command line or a combobox), these redefined keys are ignored, with or without Shift: the cursor keys, PgUp/PgDn, Home, End, Del, Backspace, and every key or combination that produces a visible character | 18.03.08 |
| The same applies to redefined Ctrl+C, Ctrl+V, Ctrl+X and Ctrl+Y | 17.11.23 |
| In the command line and the drive comboboxes, Enter, Tab, Space and Insert behave as if they were not redefined | 06.10.23 |
| In the command line, Ctrl+Shift+Enter, Ctrl+E/K/W/T, Ctrl+↓, Alt+F8, Esc, Ctrl+←/→ and Ctrl+Shift+←/→ keep their command-line meaning even if redefined, unless they were redefined to a command-line command | 29.01.24, 30.01.24 |
| Ctrl+Del keeps working outside the file lists even when redefined | 22.01.24 |
| In the Quick View panel these keep their Lister meaning even if redefined: F2…F7 alone or with Shift, Ctrl+C/A/F/P, Ctrl+Home/End/PgUp/PgDn, Ctrl+Shift+←/→ | 15.12.23, 21.01.24 |
| Other redefined keys (e.g. Ctrl+L) do work when the focus is not in a file list | 19.06.23 |

### 8.6 Interactions

- **Other places that bind keys:** the Start menu's *Shortcut key* (`keyN=` in `[user]`), the `&` accelerators of `.MNU` captions and hotlist titles, and the hotlist's own hotkeys (12).
- **Commands that read the keyboard state when they run** behave differently when bound to a key with modifiers: `cm_SrcSortByCol1…99` without parameter (Shift = secondary sort on/off, Ctrl = flip its direction); `cm_SwitchToNextTab` without parameter (with Ctrl it follows *Ctrl+Tab switches to last visited*); `SELECTFILES` with the `S` modifier (Shift also marks folders).

*Basis: observed under Wine (dialog layout, key list); help: dlg_configconfirmation, dlg_choosecommand, inisettings3, frequentlyaskedquestions; change log.*
