# 16: Localisation

Total Commander 11.58 ships with **English built into the executable** and **18 additional languages** as external files
in `<install dir>\LANGUAGE\`. This chapter specifies what a language consists of, how languages are installed and
switched (Configuration › Language page and the `OPENLANGUAGEFILE` command), the formats of the `.LNG`, `.MNU` and
`.INC` files, and indexes the complete extracted translation data delivered alongside this documentation in
`translations/`.

**Related:** 01 › Installation, Start-up; 13 › Display › Language; 14 › Main-menu files (`.MNU`), User commands (`em_`);
15 › Installation; 17 › Internal commands (numbers used as `.INC` keys); 19 › `wincmd.ini` reference
(`[Configuration]`), File inventory and locations.

## 1. Language components

| File                                     | Content                                                                                                                                                              | Required                                                |
| ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| `WCMD_<CODE>.LNG`                        | All user-interface strings (dialogs, messages, buttons, tooltips, hints) addressed by numeric ID                                                                     | yes                                                     |
| `WCMD_<CODE>.MNU`                        | The complete main menu in that language (same grammar as `WCMD_ENG.MNU`)                                                                                             | yes (else English menu)                                 |
| `WCMD_<CODE>.INC`                        | Translated descriptions of internal commands (used by the _Choose command_ dialog and the tooltips of buttons with internal commands) and the command category names | optional                                                |
| `WCMD_<CODE>.CHM`                        | Help in that language                                                                                                                                                | optional (none bundled; English `TOTALCMD.CHM` is used) |
| `wcmd_<lang>.ini` (help: `wcmd_lng.ini`) | Language-specific user commands (`em_…`); their tooltips win over `usercmd.ini` for the same name                                                                    | optional                                                |

- Every other language is at least a pair of files in `LANGUAGE\`, e.g. `WCMD_FRA.LNG` and `WCMD_FRA.MNU` for French.
- English (UI strings and menu) is stored in `TOTALCMD64.EXE` itself. `LANGUAGE\WCMD_ENG.MNU` is the English menu as a
  file (the template for custom menus); there is no `WCMD_ENG.LNG`.
- Unused language files may be deleted to save space.
- A language file may carry a custom name such as `wcmd_test_deu.lng`; the language code is the part after the last `_`
  (here `deu`).
- **Help file lookup** for a language file `X.lng`: first `X.chm` in the same directory as the LNG, then
  `wcmd_<code>.chm`, then `TOTALCMD.CHM`. Switching to a language without its own CHM returns to the default help. A
  help file installed together with a language add-on is used for F1.

_Basis: observed under Wine (language list, file set); help: dlg_configlanguage, dlg_choosecommand; history (help
lookup, custom names)._

## 2. Bundled languages

| Code  | Display name (line 1 of the .LNG)    | Code page | LNG strings        | INC            | MNU            |
| ----- | ------------------------------------ | --------- | ------------------ | -------------- | -------------- |
| `ENG` | English (built-in)                   | —         | built into the EXE | `TOTALCMD.INC` | `WCMD_ENG.MNU` |
| `CHN` | 简体中文 (Simplified Chinese)        | 936       | 2126               | yes            | yes            |
| `CZ`  | Čeština (Czech)                      | 1250      | 2126               | yes            | yes            |
| `DAN` | Dansk                                | 1252      | 2126               | yes            | yes            |
| `DEU` | Deutsch                              | 1252      | 2126               | yes            | yes            |
| `DUT` | Nederlands                           | 1252      | 2126               | yes            | yes            |
| `ESP` | Español (tradicional)                | 1252      | 2126               | yes            | yes            |
| `FRA` | Français                             | 1252      | 2126               | yes            | yes            |
| `HUN` | Magyar (tegezős)                     | 1250      | 2126               | yes            | yes            |
| `ITA` | Italiano                             | 1252      | 2126               | yes            | yes            |
| `KOR` | Korean (한국어 for 10.0)             | 949       | 2126               | yes            | yes            |
| `NOR` | Norsk (Bokmål)                       | 1252      | 2126               | —              | yes            |
| `POL` | Polski                               | 1250      | 2126               | yes            | yes            |
| `ROM` | Română - by Eugen ANTAL - ver. 11.58 | 65001     | 2126               | yes            | yes            |
| `RUS` | Russian (Русский)                    | 1251      | 2126               | yes            | yes            |
| `SK`  | Slovenský (Slovak)                   | 1250      | 2126               | —              | yes            |
| `SVN` | Slovenski (Slovenian)                | 1250      | 2126               | yes            | yes            |
| `SWE` | Svenska                              | 1252      | 2126               | yes            | yes            |
| `UKR` | Ukrainian (Українська)               | 1251      | 2126               | yes            | yes            |

All 18 translations are complete: each defines all **2,126 string IDs** of version 11.58. INC files exist for 16
languages (not for Norwegian and Slovak; TC then shows the English command descriptions). More languages, not included
in the distribution, are offered on the add-on page of [www.ghisler.com](https://www.ghisler.com). None of the bundled
languages is right-to-left.

_Basis: extracted from the 18 bundled files (`translations/summary.json`); help: dlg_configlanguage._

## 3. Installing languages

The installer handles languages in its first two steps (the full installer sequence is in 01 › Installation › Installer
sequence):

| Step | Content                                                                                                                                                                                                                                                                                  |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | "Please select a language/ Bitte wählen Sie eine Sprache/ S.v.p. choisissez une langue:" and a list: English, Deutsch (German), Français (French), Русский (Russian), Nederlands (Dutch), Dansk (Danish), Norsk (Norwegian), Italiano (Italian), … · `[Program info] [Next >>] [Cancel]` |
| 2    | "Do you also want to install all other languages? You can then switch between these languages while the program is running." `(o) Yes ( ) No` · `[<< Back] [Next >>] [Cancel]`                                                                                                           |

```text
┌ Installation Total Commander 64-bit 11.58 ───────────────────┐
│ Install: Total Commander                                      │
│                                                               │
│ Do you also want to install all other languages? You can     │
│ then switch between these languages while the program is      │
│ running.                                                      │
│   (o) Yes                                                     │
│   ( ) No                                                      │
│                                                               │
│              [ << Back ]  [ Next >> ]  [ Cancel ]             │
└───────────────────────────────────────────────────────────────┘
```

- On a first installation the language preselected in step 1 is the system's current user language, if it is included.
  The list shows each language in its own code page.
- _Yes_ in step 2 installs every bundled language file into `LANGUAGE\`, so all of them appear on the Language page.
  What _No_ installs besides the chosen language is not recorded.
- An **update installation** installs only the languages whose `.lng` or `.mnu` file was already present, and does not
  change the language setting.
- Unattended installation: the installer accepts `/L<n>` (language number from `install.inf`, e.g. `L18` = Romanian) and
  `/M1` / `/M0` (multi-language install on / off), among other switches (01 › Installation › Installer command-line
  parameters).
- Additional languages from the add-on page can be installed by opening their archive (auto-install into the program or
  language folder; see 15 › Installation › Automatic installation).

_Basis: observed on Windows 11 (steps 1–2); history (default language, update mode, switches, auto-install)._

## 4. Switching the language

### 4.1 Configuration › Language page

Opened with Configuration › Options › Language (`cm_LanguageConfig`, 499), and by Start › Change Main Menu…, which opens
this page so the `.MNU` file can be chosen and edited.

```text
Change the language/ Sprache wechseln/ Changer de langue
┌──────────────────────────────────────────────────────┐
│English                                               │
│Čeština (Czech) (WCMD_CZ.LNG)                         │
│Dansk (WCMD_DAN.LNG)                                  │
│ …                                                    │
│简体中文 (Simplified Chinese) (WCMD_CHN.LNG)           │
└──────────────────────────────────────────────────────┘
Main menu file:
[                                       ] [>>] [Edit]
[Download]
```

The list, as shipped (English selected):

1. English
2. Čeština (Czech) (WCMD_CZ.LNG)
3. Dansk (WCMD_DAN.LNG)
4. Deutsch (WCMD_DEU.LNG)
5. Español (tradicional) (WCMD_ESP.LNG)
6. Français (WCMD_FRA.LNG)
7. Italiano (WCMD_ITA.LNG)
8. Korean (한국어 for 10.0) (WCMD_KOR.LNG)
9. Magyar (tegezős) (WCMD_HUN.LNG)
10. Nederlands (WCMD_DUT.LNG)
11. Norsk (Bokmål) (WCMD_NOR.LNG)
12. Polski (WCMD_POL.LNG)
13. Română - by Eugen ANTAL - ver. 11.58 (WCMD_ROM.LNG)
14. Russian (Русский) (WCMD_RUS.LNG)
15. Slovenski (Slovenian) (WCMD_SVN.LNG)
16. Slovenský (Slovak) (WCMD_SK.LNG)
17. Svenska (WCMD_SWE.LNG)
18. Ukrainian (Українська) (WCMD_UKR.LNG)
19. 简体中文 (Simplified Chinese) (WCMD_CHN.LNG)

| Control                                                            | Behaviour                                                                                                                                                                                                                                                                                           |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Caption "Change the language/ Sprache wechseln/ Changer de langue" | Fixed trilingual text                                                                                                                                                                                                                                                                               |
| Language list                                                      | Built by scanning `LANGUAGE\WCMD_*.LNG`. Each entry is **line 1 of the file** followed by the file name in parentheses. English (built-in) comes first, without a file name; the rest are sorted alphabetically by display name. Choosing a language **selects the matching `.MNU` automatically**. |
| _Main menu file_ `[edit]`                                          | The `.MNU` file for the main menu. Empty = the built-in default menu.                                                                                                                                                                                                                               |
| `[>>]`                                                             | Browse for another menu file                                                                                                                                                                                                                                                                        |
| `[Edit]`                                                           | Opens the menu file in Notepad; enabled only when a file is set (format: §6 and 14 › Main-menu files (`.MNU`))                                                                                                                                                                                      |
| `[Download]`                                                       | Opens the default web browser on the add-on language page. Its caption is intentionally never translated.                                                                                                                                                                                           |

Storage, in `[Configuration]` of `wincmd.ini`:

| Key           | Value                                                                                                                                                     |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `LanguageINI` | Language file, e.g. `WCMD_DEU.LNG`; empty = built-in English                                                                                              |
| `Mainmenu`    | Custom main-menu location and file name; empty = built-in menu. Choosing a language enters the matching `WCMD_<CODE>.MNU` (exact path form not recorded). |

The new language is applied while the program is running (with _OK_ or _Apply_); no restart is needed. Program updates
overwrite the shipped `.MNU` files, so a customised menu must be saved under a different name and selected here.

### 4.2 `OPENLANGUAGEFILE` command

A command with parameters (17 › Commands with parameters, translation ID −19), usable on buttons, menu items, hotkeys
and the Start menu:

| Form                              | Effect                                                             |
| --------------------------------- | ------------------------------------------------------------------ |
| `OPENLANGUAGEFILE wcmd_deu.lng`   | Loads that LNG and its MNU as a pair from the `LANGUAGE` subfolder |
| `OPENLANGUAGEFILE` (no parameter) | Internal English                                                   |
| `OPENLANGUAGEFILE WCMD_xyz.MNU`   | Changes **only** the main menu                                     |
| `OPENLANGUAGEFILE .MNU`           | Restores the internal menu                                         |

The parameter may be a path in double quotes. Language files can also be loaded from a directory other than `LANGUAGE`;
the help file is then looked up in that directory too (§1).

### 4.3 What a switch affects

- All dialogs, messages, buttons and the main menu; the command descriptions of the _Choose command_ dialog and of
  button tooltips (from the `.INC`); the names of the internal content-plugin fields (strings 1579, 1580, 1742); the
  translations supplied by content plugins are reloaded.
- The help file (§1).
- **Message-box buttons.** `[Configuration] TranslateMessageButtons=1` (default): the buttons of standard Windows
  message boxes (e.g. the Shift+Del confirmation) are shown in TC's language; `0`: in the system language. In dark mode
  they are always translated.
- **Right-to-left languages** (e.g. Arabic, Hebrew add-ons): dialogs, lists and progress windows are mirrored;
  `HELP_BREAK` in a `.MNU` file has no effect.
- Language-specific user commands come from `wcmd_<lang>.ini` (§1).

_Basis: observed under Wine (page layout and list); help: dlg_configlanguage, dlg_configbuttonbar, inisettings1,
inisettings2, dlg_mainmenu; history (sorting, Download caption, quoting, other directories, plugin strings,
right-to-left)._

## 5. `.LNG` file format

### 5.1 Layout

```text
line 1:   <native language name shown in the language list>
line 2:   codepage=<Windows code page number>          (65001 = UTF-8; file may then start with a UTF-8 BOM)
line 3…:  <id>="<text>"
```

### 5.2 Rules (derived from the 18 files)

- **IDs** are decimal integers, unique per file, range 0 … 30012 in 11 ranges (with gaps inside them; 115 contiguous
  runs in all): 0–197 (core messages/prompts), 401–404, 608–723, 1040–1811 (dialog texts), 1900–1922, 2001–2138,
  4001–4006, 5002–5523 (dialog control captions), 5601–6314, 6401–7903 (newer features), 30000–30012.
- **Value** is enclosed in double quotes. The parser is tolerant: a missing opening quote is accepted (seen in ESP, NOR,
  ITA, DAN, HUN, FRA, SVN), and the closing quote is stripped if present. In NOR, the value of ID 2053 continues on the
  next line (how TC reads it: not recorded). All anomalies are listed per file in `translations/summary.json`.
- **Line breaks**: CR LF; files with Unix-style LF line breaks are accepted too.
- **Escapes** inside values: `\n` = line break, `\r` = line break used inside message boxes, `\t` = tab (also used as a
  separator between button groups, see below). Three-digit octal escapes `\nnn` occur in every file (900 occurrences of
  18 different codes in all, about two thirds of them in the scrambled strings 672–676), e.g. `\042` = `"`
  (`Kopieren von \042%s\042 nach`) and `\246` = byte 0xA6 (meaning inferred from use).
- **Accelerators**: `&` before a letter marks the underlined access key; `&&` is a literal ampersand.
- **printf placeholders** must be kept in order and type: `%s` (string), `%i`/`%d` (integer), `%3i`, `%02i`, `%l`,
  `%02l`, `%c`, and the TC-specific `%p`, `%t`, `%n` in help-style texts.
- **Button lists** for message boxes are one string with captions separated by `;`. Example (ID 13, the overwrite
  prompt, German file):
  `Über&schreiben;&Alle überschreiben;&Überspringen\tA&bbrechen;Alle &älteren überschr.;Alle übers&pringen`. The `\t`
  appears to split the buttons into two groups (inferred, not documented).
- **Option lists** (combo-box contents) are one string with items separated by `|`.
- **Comment lines** start with `{`, `;` or `//`; a commented-out ID (`;1520="…"`) is ignored. Blank lines are ignored.
- **Encoding**: the bytes are interpreted in the declared code page (1250 Central European, 1251 Cyrillic, 1252 Western,
  936 Simplified Chinese GBK, 949 Korean, 65001 UTF-8).

### 5.3 Missing strings

If an ID is absent from the active LNG file, TC is expected to fall back to the built-in English text for that ID
(inferred from the fact that older, incomplete translations keep working; not documented). A clone should therefore ship
an English table with the same IDs and overlay the selected language on top of it.

_Basis: extracted from the 18 bundled files; history (LF line breaks); fallback inferred._

## 6. `.MNU` file format

```text
POPUP "&Files"
  MENUITEM "&Change Attributes...", cm_SetAttrib
  MENUITEM "&Pack...\tAlt+F5", cm_PackFiles
  MENUITEM "Test Arch&ive(s)\tAlt+Shift+F9", 518
  POPUP "Prin&t"
    MENUITEM "File &List...", 2027
  END_POPUP
  MENUITEM SEPARATOR
END_POPUP
STARTMENU          ← position where the user's Start menu is inserted
HELP_BREAK         ← following popups are right-aligned (Help)
```

- `MENUITEM "caption\tshortcut text", command`: the command is either a `cm_` name (case-insensitive) or its numeric ID;
  `\t` separates the right-aligned shortcut text (display only: it does not define the hotkey).
- `POPUP` … `END_POPUP` nest to any depth; `MENUITEM SEPARATOR` draws a line.
- The `*.*` item of the Show menu is a live caption replaced with the last user mask.
- All 18 translated menus have **exactly the same structure and commands** as the English one except French, which
  differs slightly in item order; the extracted table aligns every caption by command ID, so every row is filled for
  every language.
- The complete grammar, the placement rules for `STARTMENU` and `HELP_BREAK`, and the full English menu are in 14 ›
  Main-menu files (`.MNU`).

_Basis: extracted from the 19 bundled `.MNU` files; help: dlg_mainmenu._

## 7. `.INC` file format (translated command descriptions)

```text
All="Alle"                       ← category names (English key = text before '=')
Source="Quelle"
…
300="Quelle: Zeige Kommentare"   ← <command number>="<description>"
…
-2="Wechsle ins angegebene Verzeichnis"   ← commands with parameters, by their negative number
```

- The English source is `TOTALCMD.INC` (`[____Category____]=0` headers, then `cm_Name=<number>;<description>`; see 17 ›
  Names, numbers and where they are used). Translated INC files key descriptions by **number only**; names stay English.
- **Category keys** (the English key before `=`): `All`, `Source`, `Left`, `Right`, `FileOperations`, `Configuration`,
  `Network`, `Misc`, `ParallelPort`, `Print`, `Mark`, `Security`, `Clipboard`, `FTP`, `Navigation`, `Help`, `Window`,
  `CommandLine`, `Tools`, `View`, `User`, `Tabs`, `Custom column views`, `Sorting`, `Commands with parameters`,
  `View modes`.
- The 27 commands with parameters are translated under their negative numbers −2 … −28 (17 › Commands with parameters);
  the Italian file lacks −10 and −28, the Slovenian file −28.
- A translated INC may also contain numbers that are not in `TOTALCMD.INC` (e.g. `2062`, `2067`…`2085` in the French
  file, `430`…`449` in the Hungarian file).
- Commands missing from a translated INC show the English description. Counting also the entries present with an empty
  text `""` (whose display is not recorded), 77–101 commands per language have no translation, mostly newer commands and
  numbered series.
- Without any INC for the language (NOR, SK), button tooltips for internal commands use the translated main-menu caption
  when the command is in the main menu, and the English description otherwise (inferred from the change log).

_Basis: extracted from the 16 bundled `.INC` files and `TOTALCMD.INC`; history (tooltips without INC)._

## 8. Extracted data (in `translations/`)

| File                                   | Content                                                                                                              |
| -------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `ui_strings_all_languages.csv`         | 2,126 rows × 18 languages: `id` + one column per language (UTF-8 with BOM, opens in Excel)                           |
| `menus_all_languages.csv`              | Every main-menu caption (109 popups/items) with type, depth, command ID, the English caption and all 18 translations |
| `commands_all_languages.csv`           | All 594 internal commands: category, `cm_` name, number, English description, 16 translations                        |
| `command_categories_all_languages.csv` | The command category names in all languages                                                                          |
| `json/lng_<CODE>.json`                 | One JSON per language: name, code page, `strings` {id: text}                                                         |
| `utf8/WCMD_<CODE>.LNG / .MNU / .INC`   | Faithful UTF-8 conversions of every original file (comments kept)                                                    |
| `summary.json`                         | Counts per language, structure checks, parser anomalies                                                              |

Strings are stored exactly as in the files (escape sequences such as `\n`, `\t` and `&` accelerators are kept
literally).

_Basis: extraction delivered with this documentation._

## 9. Sample: the same strings in all 18 languages

### 9.1 ID 2

| Lang | Text                                      |
| ---- | ----------------------------------------- |
| CHN  | `新建文件夹`                              |
| CZ   | `Nová složka (adresář)`                   |
| DAN  | `Ny mappe (directory):`                   |
| DEU  | `Neuer Ordner (Verzeichnis)`              |
| DUT  | `Nieuwe map (directory)`                  |
| ESP  | `Nuevo directorio`                        |
| FRA  | `Nouveau¦x répertoire¦s`                  |
| HUN  | `Új mappa`                                |
| ITA  | `Nuova cartella`                          |
| KOR  | `새 폴더 (디렉토리)`                      |
| NOR  | `Ny mappe (katalog)`                      |
| POL  | `Nowy katalog (folder)`                   |
| ROM  | `Creare folder nou:` and a trailing space |
| RUS  | `Создать новый каталог (папку):`          |
| SK   | `Nový priečinok:`                         |
| SVN  | `Nova mapa`                               |
| SWE  | `Ny mapp:`                                |
| UKR  | `Нова тека (директорія):`                 |

### 9.2 ID 6

| Lang | Text                                                     |
| ---- | -------------------------------------------------------- |
| CHN  | `您确实要删除这个文件吗?\r\r%s`                          |
| CZ   | `Opravdu chcete odstranit soubor %s?`                    |
| DAN  | `Er du sikker på, at du vil slette den valgte fil %s ?`  |
| DEU  | `Soll die markierte Datei %s wirklich gelöscht werden?`  |
| DUT  | `Wil je het geselecteerde bestand %s echt wissen?`       |
| ESP  | `¿Realmente quiere eliminar el fichero seleccionado %s?` |
| FRA  | `Voulez-vous vraiment supprimer le fichier choisi %s ?`  |
| HUN  | `Tényleg törlöd a(z) %s fájlt?`                          |
| ITA  | `Eliminare il file selezionato %s ?`                     |
| KOR  | `%s 파일을 정말로 삭제할까요?`                           |
| NOR  | `Vil du virkelig slette filen %s?`                       |
| POL  | `Czy rzeczywiście chcesz usunąć wybrany plik %s?`        |
| ROM  | `Doriți să ștergeți fișierul selectat: \r[%s] ?`         |
| RUS  | `Вы действительно хотите удалить\rфайл \042%s\042 ?`     |
| SK   | `Naozaj chcete odstrániť súbor „%s“?`                    |
| SVN  | `Ali res želite izbrisati izbrano datoteko %s?`          |
| SWE  | `Ska filen '%s' verkligen tas bort?`                     |
| UKR  | `Ви дійсно хочете видалити файл \042%s\042 ?`            |

### 9.3 ID 7

| Lang | Text                                                          |
| ---- | ------------------------------------------------------------- |
| CHN  | `您确实要删除这个文件夹吗?\r\r%s`                             |
| CZ   | `Opravdu chcete odstranit složku %s?`                         |
| DAN  | `Er du sikker på, at du vil slette den valgte mappe %s ?`     |
| DEU  | `Soll das markierte Verzeichnis %s wirklich gelöscht werden?` |
| DUT  | `Wil je de geselecteerde directory %s echt wissen?`           |
| ESP  | `¿Realmente quiere eliminar el directorio seleccionado %s?`   |
| FRA  | `Voulez-vous vraiment supprimer le répertoire choisi %s ?`    |
| HUN  | `Tényleg törlöd a(z) %s mappát?`                              |
| ITA  | `Eliminare la cartella selezionata %s ?`                      |
| KOR  | `%s 폴더를 정말로 삭제할까요?`                                |
| NOR  | `Vil du virkelig slette mappen %s?`                           |
| POL  | `Czy rzeczywiście chcesz usunąć wybrany katalog %s?`          |
| ROM  | `Doriți să ștergeți folderul selectat: \r[%s] ?`              |
| RUS  | `Вы действительно хотите удалить\rкаталог \042%s\042 ?`       |
| SK   | `Naozaj chcete odstrániť priečinok „%s“?`                     |
| SVN  | `Ali res želite izbrisati izbrano mapo %s?`                   |
| SWE  | `Ska mappen %s verkligen tas bort?`                           |
| UKR  | `Ви дійсно хочете видалити директорію \042%s\042 ?`           |

### 9.4 ID 12

| Lang | Text                                                                         |
| ---- | ---------------------------------------------------------------------------- |
| CHN  | `目标文件已存在:\r%s\r是否要替换?`                                           |
| CZ   | `Cíl již existuje:\r%s\rChcete ho přepsat?`                                  |
| DAN  | `Destination findes allerede:\r%s\rVil du overskrive?`                       |
| DEU  | `Zieldatei existiert bereits:\r%s\rWollen Sie die Datei überschreiben?`      |
| DUT  | `Het bestand bestaat reeds:\r%s\rWil je het overschrijven?`                  |
| ESP  | `El destino ya existe:\r%s\r¿Quiere reemplazarlo?`                           |
| FRA  | `Fichier de destination existe déjà :\r%s\rVoulez-vous écraser ce fichier ?` |
| HUN  | `A célfájl már létezik:\r%s\rFelülírod?`                                     |
| ITA  | `Il file di destinazione esiste :\n%s\nSovrascrivere?`                       |
| KOR  | `대상이 이미 존재합니다:\r%s\r덮어쓸까요?`                                   |
| NOR  | `Destinasjon eksisterer allerede:\r%s\rVil du erstatte?`                     |
| POL  | `Docelowy element już istnieje:\r%s\rCzy chcesz go zastąpić?`                |
| ROM  | `Fișierul există deja în «destinație» :\r[%s]\rÎl suprascrieți ?`            |
| RUS  | `Файл \042%s\042\rуже существует. Хотите его заменить?`                      |
| SK   | `Cieľ už existuje:\r%s\rChcete ho prepísať?`                                 |
| SVN  | `Cilj že obstaja:\r%s\rAli ga želite prepisati?`                             |
| SWE  | `Destinationsfilen\r'%s'\rfinns redan. Skriva över?`                         |
| UKR  | `Об'єкт вже існує: \042%s\042\r Замінити?`                                   |

### 9.5 ID 14

| Lang | Text                                |
| ---- | ----------------------------------- |
| CHN  | `用户中止!`                         |
| CZ   | `Akce byla zrušena uživatelem.`     |
| DAN  | `Brugerafbrydelse!`                 |
| DEU  | `Abbruch durch den Benutzer!`       |
| DUT  | `Geannuleerd door gebruiker!`       |
| ESP  | `¡Cancelado por el usuario!`        |
| FRA  | `Interruption par l'utilisateur !`  |
| HUN  | `Felhasználói megszakítás`          |
| ITA  | `Stop utente!`                      |
| KOR  | `사용자에 의해 중단되었습니다!`     |
| NOR  | `Avbrutt av bruker!`                |
| POL  | `Przerwano na życzenie użytkownika` |
| ROM  | `Întrerupt de utilizator!`          |
| RUS  | `Прервано пользователем.`           |
| SK   | `Prerušené používateľom.`           |
| SVN  | `Sprožili ste prekinitev!`          |
| SWE  | `Användaravbrott!`                  |
| UKR  | `Скасовано користувачем!`           |

### 9.6 ID 17

| Lang | Text                                            |
| ---- | ----------------------------------------------- |
| CHN  | `找不到符合的项目!`                             |
| CZ   | `Výběru neodpovídá žádná položka.`              |
| DAN  | `Ingen fundet!`                                 |
| DEU  | `Keine passenden Einträge gefunden!`            |
| DUT  | `Geen overeenkomsten gevonden!`                 |
| ESP  | `¡No se encontraron equivalentes!`              |
| FRA  | `Pas de fichiers ad-hoc trouvés !`              |
| HUN  | `Nincs ilyen!`                                  |
| ITA  | `Nessuna corrispondenza trovata!`               |
| KOR  | `아무것도 일치하지 않습니다!`                   |
| NOR  | `Ingen funnet!`                                 |
| POL  | `Nie znaleziono pasujących!`                    |
| ROM  | `Nu există nici un fișier de tipul specificat!` |
| RUS  | `Такие файлы не найдены.`                       |
| SK   | `Nenašlo sa.`                                   |
| SVN  | `Ni najdenih ujemanj!`                          |
| SWE  | `Hittar ingen sådan!`                           |
| UKR  | `Збігів не знайдено!`                           |

_Basis: extracted from the 18 bundled `.LNG` files._

## 10. About the English base strings

The English UI strings (the reference column a clone needs) are **not shipped as a file**: they are compiled into
`TOTALCMD64.EXE`, and Ghisler's language page lists English only as "included in the standard package". They were
deliberately not extracted from the executable. Practical routes for a clone:

1. Use the English captions documented throughout chapters 02–15 (all observed on screen), plus `WCMD_ENG.MNU` and
   `TOTALCMD.INC`, which _are_ English.
2. Reconstruct the remaining English texts per ID from the 18 translations (e.g. German + French + Dutch) and verify
   against the running program.

_Basis: investigation decision; vendor language page._
