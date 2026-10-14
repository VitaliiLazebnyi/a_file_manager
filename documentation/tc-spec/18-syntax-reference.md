# 18: Syntax reference

This chapter defines the small languages that recur across the program: rename and new-folder placeholders, file masks
and selection types, the regular-expression dialect, plugin-rule operators, content-field references, the parameter
placeholders of buttons and commands (`%P %N …`), hotkey notation, path and drive syntax, and menu-entry conventions. A
clone should implement each of them once and reuse it everywhere; the dialogs that use them are described in their own
chapters.

**Related:** 07 › New folder (F7, Shift+F7), New file (Shift+F4); 09 › Find Files, Multi-Rename Tool, Synchronize
directories; 14 › The command language, Button bars, Start menu, User commands (`em_`), Redefining hotkeys and aliases;
06 › Notation, Redefining keys; 15 › Content plugins in use; 17 › Commands with parameters; 19 › `wincmd.ini` reference,
Environment variables.

## 1. Rename and new-folder placeholders

### 1.1 Where they are used

- Multi-Rename Tool: the name mask and the extension mask (dialog, insert menus and pipeline: 09 › Multi-Rename Tool).
- F7 New folder (its `±` menu inserts them; `[T3]` is the default time source there) and Shift+F4 New file (07).
- `%$DATE:…%` uses the same date/time letters (19 › Environment variables).
- The Copy/Move target mask is usually a wildcard mask (`*.bak`); whether bracket placeholders work there is not
  recorded.

Everything outside `[…]` is literal text. A `\` in the result moves the item into a subfolder, which is created if
missing.

### 1.2 Grammar

```text
mask        := { literal | "[" cmdseq "]" }
literal     := any character except "["
cmdseq      := cmd { cmd }        # several date/time letters may share one bracket: [YMD], [hms]
range       := [pad] pos [ "-" [pos] | "," len ]
pad         := "0" | " "          # left-fill to the requested width with zeros / spaces
pos         := ["-"] digits       # 1 = first char; "-k" = k-th character from the end
len         := digits
```

- `[[]` and `[]]` insert literal brackets. `[]]` cannot share its brackets with other commands.
- Positions count characters; a double-byte or surrogate-pair character counts as **one**.
- **Order of application** in the Multi-Rename Tool: **masks → search/replace → case conversion**. The case conversion
  also applies to the extension: _All UPPERCASE_ after the replacement `pic-$2-$1` turned `IMG_1001.jpg` into
  `PIC-001-1.JPG`.

### 1.3 Range forms

Shown on `[N…]`; the same forms apply to every letter listed below the table.

| Form      | Result                                                                |
| --------- | --------------------------------------------------------------------- |
| `[N1]`    | First character                                                       |
| `[N-5]`   | The 5th-last character (a single character counted from the end)      |
| `[N2-5]`  | Characters 2 to 5 (4 characters)                                      |
| `[N2,5]`  | 5 characters starting at position 2 (`[first,length]` mode)           |
| `[N2-]`   | From position 2 to the end                                            |
| `[N02-9]` | Characters 2–9, left-filled with zeros to width 8: "abc" → `000000bc` |
| `[N 2-9]` | The same, filled with spaces: "abc" → six spaces, then `bc`           |
| `[N-8,5]` | 5 characters starting at the 8th-last                                 |
| `[N-8-5]` | 8th-last to 5th-last                                                  |
| `[N2--5]` | 2nd to 5th-last                                                       |
| `[N-5-]`  | 5th-last to the end                                                   |

- Ranges apply to `N`, `E` (e.g. `[E1-3]`), `A`, `P`, `G`, `X`, to the bare full-path form `[2-5]`, to `B` (after `_`:
  `[B2_2-5]`), to plugin fields (after `:`) and to environment variables (`[%x%1-5]`).
- Zero / space padding works for plugin fields and for `N`, `E`, `P`, `G`.
- The range buttons of the Multi-Rename Tool open a range picker that writes this syntax; its options are _measure first
  character from the end_, _measure last character from the end_ and _use [first,length]_.

### 1.4 Name and path parts

| Placeholder                                             | Value                                                                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `[N]`                                                   | Old name without extension                                                                                                                                                                                                                                                                                                                                                                          |
| `[E]`                                                   | Old extension (without the dot)                                                                                                                                                                                                                                                                                                                                                                     |
| `[A]`                                                   | Name **with** extension, no path (mainly for folders, e.g. name mask `[A2-5]` with an empty extension mask)                                                                                                                                                                                                                                                                                         |
| `[2-5]` (range without a letter; menu template `[#-#]`) | Characters of the full path + name + extension (`[2-5]`, `[5-]`, …)                                                                                                                                                                                                                                                                                                                                 |
| `[P]`                                                   | Parent folder name (`c:\directory\file.txt` → `directory`)                                                                                                                                                                                                                                                                                                                                          |
| `[G]`                                                   | Grandparent folder name                                                                                                                                                                                                                                                                                                                                                                             |
| `[B0]`…`[B9]`                                           | Folder from the path, counted from the **right**: `[B0]` = `[P]`, `[B1]` = `[G]`, `[B2]` = great-grandparent …; range form `[B2_2-5]`                                                                                                                                                                                                                                                               |
| `[B+0]`…`[B+9]`                                         | Folder from the path, counted from the **left**: `[B+0]` = drive letter, `[B+1]` = first folder …; range form `[B+1_2-5]`                                                                                                                                                                                                                                                                           |
| `[P#-#]` `[G#-#]` `[A#-#]` `[E#-#]` `[X#-#]`            | Ranges of parent, grandparent, name + ext, ext, clipboard text (e.g. `[P2-5]`, `[A2-5]`)                                                                                                                                                                                                                                                                                                            |
| `[?#-#]`                                                | Range of a content-plugin value; the resulting syntax is `[=plugin.field.unit:4-7]`                                                                                                                                                                                                                                                                                                                 |
| `[S]`                                                   | File size in bytes                                                                                                                                                                                                                                                                                                                                                                                  |
| `[I]`, `[I1]` / `[I0]`                                  | **Folder-dot switch** ("Folders only (on/off): The name [N] includes the extension, [E] is not used"). From this position on, folders are not treated as having an extension, so `[N]` is the whole folder name and `[E]` is empty. `[I0]` switches back; each further `[I]` toggles. The position in the mask matters. Typical mask: `[I][N2-5]` with extension `[E]` for mixed files and folders. |

### 1.5 Counter

| Form                      | Meaning                                                                                                                                                 |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `[C]`                     | Counter using **Define counter**: _Start at_, _Step by_ (may be negative), _Digits_ (zero-padded width; `a` = automatic width from the number of items) |
| `[C10+5:3]`               | Inline: start 10, step 5, width 3                                                                                                                       |
| `[C10]`, `[C+5]`, `[C:3]` | Partial inline definitions. Any inline option makes the tool **ignore all** Define-counter fields for that `[C]`.                                       |
| `[C:a]`, `[C10+10:a]`     | Automatic width from the number of files; combinable with other inline options                                                                          |
| `[C+1/100]`               | Fractional counter: increases only every 100 items. `[C+1/100]\[N]` distributes files into subfolders `1`, `2`, … of 100 files each                     |
| `[Caa+1]`                 | Alphabetic counter starting at `aa` (`aa`, `ab`, …); the width comes from the start string                                                              |
| `[c]` / `[c1]`            | Total number of files/folders in the list ("File [C] of [c]")                                                                                           |
| `[c2]`                    | The same, padded to the Define-counter _Digits_                                                                                                         |
| `[c3]`                    | Last value the Define-counter counter will reach                                                                                                        |

Numbering follows the **current order of the result list**; that order can be changed by clicking column headers, by
drag and drop, or with **Shift+Up/Down**. With Start 110, Step 15, Digits 1, the mask `Photo_[C]_[Y]-[M]-[D]` gave
`Photo_110_2025-12-01.jpg`, `Photo_125_2025-12-02.jpg`, … (date = file modification date).

### 1.6 Date and time

**Time-source switches** apply to every date/time field _after_ their position:

| Switch                 | Source                                                                                                                                                                                                                                   |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `[T1]`                 | File last-modified time (default in the Multi-Rename Tool)                                                                                                                                                                               |
| `[T2]`                 | Current time when the dialog was opened                                                                                                                                                                                                  |
| `[T3]`                 | Current time when the rename options were last changed (default in F7 New folder)                                                                                                                                                        |
| `[T4]`                 | EXIF date for images (first found of DATETIME_ORIGINAL, DATETIME_DIGITIZED, DATETIME; JPEG and HEIC) or the MP4 recording date (from `mvhd`, stored as UTC, so it shifts with the time zone). Files without such a date are **skipped**. |
| `[T1+60m]`, `[T1-10h]` | Offset on any of `T1`–`T4`: sign, value, unit `s` seconds, `m` minutes, `h` hours, `D` days, `M` months, `Y` years                                                                                                                       |

**Fields:**

| Field          | Value                                                                |
| -------------- | -------------------------------------------------------------------- |
| `[YMD]`        | Date `YYYYMMDD`                                                      |
| `[Y]` / `[y]`  | Year, 4 / 2 digits                                                   |
| `[M]`, `[D]`   | Month, day (2 digits)                                                |
| `[hms]`        | Time `hhmmss`                                                        |
| `[h]` / `[H]`  | Hour, 24-hour (00–23) / 12-hour (01–12), 2 digits                    |
| `[m]`, `[s]`   | Minute, second (2 digits)                                            |
| `[v]`          | Milliseconds (3 digits)                                              |
| `[i]` / `[i1]` | English `am`/`pm` indicator / only `a` or `p`                        |
| `[d]`          | Date in the control-panel (country) format, with `/` replaced by `-` |
| `[t]`          | Time in the control-panel format, with `:` replaced by `.`           |

### 1.7 Case switches

Each applies from its position on, until the next switch.

| Switch | Effect                                                                                                                                                                                                                                                                                                                                            |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `[U]`  | UPPER case                                                                                                                                                                                                                                                                                                                                        |
| `[L]`  | lower case                                                                                                                                                                                                                                                                                                                                        |
| `[F]`  | First Letter Of Each Word upper case, rest lower                                                                                                                                                                                                                                                                                                  |
| `[f]`  | Like `[F]` with English title rules: the words listed in `[Configuration] LowercaseStrings` (default `English in Titles:a,an,the,at,by,for,in,of,on,to,from,up,and,as,but,or,nor,yet,so,vs`) stay lower case, except as first or last word (a `!` before the `:` allows a lower-case last word). Applies to literal text as well as placeholders. |
| `[n]`  | Back to the original case                                                                                                                                                                                                                                                                                                                         |
| `[u]`  | Convert decomposed Unicode characters to precomposed ones (a + combining ^ → â). Must be the **first** placeholder.                                                                                                                                                                                                                               |

### 1.8 Environment and clipboard

| Form       | Value                                                                                                                                                                                                                                                                                               |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `[%VAR%]`  | Environment variable (e.g. `[%USERNAME%]`); ranges such as `[%VAR%1-5]`                                                                                                                                                                                                                             |
| `[%VAR%\]` | Only the last part of a path held in the variable (`c:\temp` → `temp`)                                                                                                                                                                                                                              |
| `[%VAR%_]` | Every `\` replaced by the given character (here `_`), and `:` removed                                                                                                                                                                                                                               |
| `[X]`      | Clipboard text, with the characters `*?:\|"<>` replaced by `_`. The value is **cached**: it is re-read only when the name field changes or `+`/`#` is clicked. An error is shown if the clipboard is empty or holds an empty string. The F7 `±` menu omits `[X]` while the clipboard holds no text. |
| `[X+]`     | Like `[X]`, but empty instead of an error                                                                                                                                                                                                                                                           |

### 1.9 Content-plugin fields

| Form                                      | Value                                                                                                                                                                                                                                                                    |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `[=plugin.field]`, `[=plugin.field.unit]` | A content-plugin field, e.g. `[=tc.writedate.Y-M-D]`. The unit is a field unit (§5.2) or, for date/time, a formatter such as `YMD hms`. `v` (milliseconds) works only in combined date+time fields, e.g. `[=tc.writedate.Y-M-D h-m-s.v]`. `[=?]` opens the field picker. |
| `[=plugin.field.unit:4-7]`                | Part of the field; all `[N]` range forms, including `0`/space padding (`[=tc.size:01-8]`)                                                                                                                                                                                |
| `[="prefix"plugin.field.unit"suffix"]`    | Prefix and suffix are emitted **only** when the field exists and has a valid value                                                                                                                                                                                       |
| `[=plugin.field._fmt]`                    | Numeric formatting (below)                                                                                                                                                                                                                                               |

The `_fmt` string is `_` + type + optional `0` (keep leading zeros) + optional group length (1 digit) + optional
separator (1 character):

- Types: `d` decimal (default), `x` lower-case hex, `X` upper-case hex, `o` octal, `b` binary.
- Default separator: the control-panel thousands separator for decimal, a space otherwise.
- Examples: `_x2` → `01 FF AB CE`; `_x04` → `0000 0000 01FF ABCE`; `_d3,` → `1,234,567`.

Characters from plugins that are invalid in file names are replaced automatically (e.g. `:` → `.`) unless
`MrtReplacePluginChars=0`. Plugin fields are not previewed in virtual folders.

### 1.10 New folder: ranges and several names

These forms apply only to the F7 New-folder field (07 › New folder):

| Input         | Result                                                                                                                                                                                                                  |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `<1-10>[C]`   | A range `<a-b>` must be the **first** thing in the field; it creates the names a…b, zero-padded to the width of b: `01` … `10`. A two-line preview under the field shows the first and the last name (`01 ...` / `10`). |
| `<1-3>dir[C]` | The rest of the field is the mask: `dir1`, `dir2`, `dir3`; the cursor goes to the last one created                                                                                                                      |
| `dir<1-3>[C]` | Not at the start, so the text is a literal name (no preview)                                                                                                                                                            |
| `p\|q\s`      | `\|` separates several new folders and `\` nests them: `p`, `q`, `q\s`                                                                                                                                                  |

### 1.11 Search & Replace in the Multi-Rename Tool

Applied **after** the masks, to the assembled name.

- **Matching:** not case-sensitive by default; `*` (any run) and `?` (one character) act as wildcards; a leading `*` is
  allowed (`*x` replaces everything up to and including the first `x`).
- **Several pairs:** separate the strings with `|` in _both_ fields; they are paired by position: `ä|ö|ü` → `ae|oe|ue`.
- **`^`** (respect upper/lower case): case-sensitive matching, so upper case can map differently (`Ä` → `AE`).
- **`1x`** replaces only the **first** occurrence.
- **`[E]`** includes the extension in the search scope. When unchecked, only the result of the file-name mask is
  searched; with names loaded from a file, everything from the last dot onward is protected (this is how to replace
  every dot except the extension dot).
- **RegEx:** _Search for_ is a regular expression (§3). _Replace with_ refers to subexpressions as `$1`, `$2`, … (up to
  89), and `\U`, `\L`, `\F`, `\n` directly before a `$n` convert only that part (upper, lower, first letter of each word
  upper, unchanged): `\U$2 - \L$1.mp3`; `\L$1 $2` lower-cases only `$1`. Example: search `IMG_(\d)(\d+)`, replace
  `pic-$2-$1` → `pic-001-1.jpg`.
- **Subst.** (enabled when RegEx is ticked): the **whole name** (within the `[E]` scope) is replaced by _Replace with_,
  with RegEx its expanded subexpressions; without it only the matched part is replaced. Example: search
  `(.*) - (.*)\.mp3`, replace `$2 - $1.mp3`.

_Basis: observed under Wine (Multi-Rename runs, F7 ranges and `|`, case after replace); help:
dialog_box___multi_rename_tool, proc_mkdir, reg_ex; history (padding, `[T4]`, `[X]` caching, plugin-character
replacement)._

## 2. File masks and selection types

### 2.1 Where masks are used

Num+ / Num− (_Select group_ / _Unselect group_) and `SELECTFILES`, Show › Custom (Ctrl+F12), the Copy/Move filter ("Only
files of this type"), Find Files _Search for_, the Synchronize filter, colours by file type, auto-switch rules of view
modes and the Ignore list. The same core syntax applies everywhere; Find Files and the copy filter add the directory
forms of §2.4.

### 2.2 Core syntax

- `*` matches any run of characters (including none) and `?` exactly one character.
- Several masks are separated by **spaces** or `;` (`*.doc;*.txt`, `*.jpg *.png`). A mask in double quotes keeps its
  spaces.
- `|` separates includes from excludes: `include-masks | exclude-masks`. `|` is used because it cannot occur in a file
  name. An **empty include part** means "everything": `|*.exe` selects everything except programs.
- An exclude mask ending in `\` matches **folders**: `*.* | .cvs\` hides folders named `.cvs`, `| .git\` skips `.git`
  folders; `*.txt | *\` shows only text files and no folders at all.
- A **leading `<`** makes the whole string a regular expression (§3): `<(a|b)`. The selection dialog says so in its
  caption: "Specify file type, e.g. *.txt, or RegEx with leading '<', like <(a|b)".
- A **predefined selection type** (a saved search) can be chosen instead of a mask. It brings in the whole template:
  dates, sizes, attributes, content rules and plugin rules. `SELECTFILES >name` uses one by name (17 › Commands with
  parameters).

| Mask                       | Effect                                                 |
| -------------------------- | ------------------------------------------------------ |
| `w*.*\|*.bak *.old`        | Everything starting with `w`, except `.bak` and `.old` |
| `\|*.exe`                  | Everything except programs                             |
| `*.* \| *.bak *.tmp`       | Everything except `.bak` and `.tmp` files              |
| `*.bmp *.gif *.jpg`        | Only these images                                      |
| `*.* \| *.bmp *.gif *.jpg` | Everything except these images                         |
| `*.* \| .cvs\`             | Hide directories named `.cvs`                          |
| `*.txt \| *\`              | Only text files, no folders                            |

### 2.3 Selection-only forms (Num+, Num−, `SELECTFILES`)

- **Path-limited masks** (useful in branch view): `\sub1\sub2\*.ext` or `\*.ext` are relative to the **base** directory;
  `sub1\sub2\*.ext` (no leading `\`) matches that path below **any** subdirectory; `**` matches any number of directory
  levels (`subdir\**\*.txt` matches `subdir\subdir2\subdir3\test.txt`).
- **Related files** `A>B`: selects the files matching `A`, plus each file matching `B` whose name can be derived from a
  selected `A` file in the **same directory**. `*.jpg>*.cr2` selects `IMG_1057.JPG` together with `IMG_1057.CR2`;
  `*.jpg>crw*.cr2` pairs `IMG_1057.JPG` with `CRW_1057.CR2` (the `B` mask acts like a rename mask, inferred). The same
  form works as a copy filter.
- The mask history is stored in `[Selection]`; Shift+Del removes the highlighted history entry.

### 2.4 Find Files and copy-filter forms

**Tokenizing (Find Files _Search for_):**

1. Split at `|`: tokens before the first `|` are **include** tokens, tokens after it are **exclude** tokens.
2. Split each part at spaces; a token in double quotes keeps its spaces.
3. Without `|`, names with spaces need no quotes: TC matches **both** the entire string as one name **and** each
   space-separated part (`Letter to Mr. Smith.doc` finds that file; `test text.txt` finds "test text.txt" and also
   matches on `test` and `text.txt`).
4. With `|`, names containing spaces **must** be quoted.

**File-name tokens:**

| Token shape                     | Interpretation                                                                                                                  |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Contains `*` or `?`             | Wildcard match against the whole name                                                                                           |
| No wildcard, **no dot**         | Substring match (implicitly `*token*`, so `abc` → `*abc*`): `Smith` finds "Letter to Mr. Smith.doc"                             |
| No wildcard, **contains a dot** | **Exact name match**: `abc.txt` finds only `abc.txt`, `win.ini` only `win.ini`; `.ini` finds only a file literally named `.ini` |
| `*n.ini`                        | The name must end with `n` before the dot (the `*` sits only on the left)                                                       |
| Contains `\**\`                 | Inside a path pattern, `**` stands for any number of directory levels: `dir1\**\dir2\*.dll`                                     |

A file matches if it matches **at least one** include token and **no** exclude token; an empty include part (`| *.bak`)
behaves like `*`.

**Directory tokens** (ending in `\`) control which directories are searched or copied:

| Token                            | Scope                                                                                                                                                                                                                                          |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `name\`, `a\b\` (no leading `\`) | A directory (or relative chain) **anywhere below** the start directory. As an include, files in the start directory itself are included as well (newer behaviour; the help example `windows\ system32\ *.ini` reads "only" those directories). |
| `\name\`, `\a\b\` (leading `\`)  | Only a directory **directly in the start directory** (or a chain starting there). `\test1\test2\` finds files in the root plus in `root\test1\test2`, although `test1` itself is not searched.                                                 |
| `.\name\`                        | Same as a leading `\`                                                                                                                                                                                                                          |
| `\` alone                        | The **base directory** itself: `*.ext \| \` finds matching files only in subdirectories                                                                                                                                                        |
| `…\**\` at the end               | Also all subdirectories of the matched directory (`\subdir1\subdir2\**\`)                                                                                                                                                                      |
| Wildcards in directory names     | Allowed: `\| _vti*\`                                                                                                                                                                                                                           |
| `\|**\` appended                 | Skip (do not list / do not create) directories in which no file was found or copied ("no empty folders"); combinable: `\| \ **\`                                                                                                               |

As includes, directory tokens restrict the search to those directories; as excludes, they prevent descending into them,
and their whole subtree is excluded.

| Search for / filter        | Finds / copies                                                                                    |
| -------------------------- | ------------------------------------------------------------------------------------------------- |
| `*.bak *.sik *.old`        | Any of the three extensions                                                                       |
| `w*.* \| *.bak *.old`      | Names starting with `w`, except .bak/.old                                                         |
| `*.ini \| windows\`        | Ini files, except in directories named "windows" and their subtrees                               |
| `*.htm? \| _vti*\`         | HTML files outside `_vti*` directories                                                            |
| `windows\ system32\ *.ini` | Ini files in directories `windows\` and `system32\`                                               |
| `totalcmd\**\ \| \`        | Everything inside any `totalcmd` directory tree; the base directory itself excluded               |
| `*.* \somedir1\`           | Files in the base directory, plus the **direct** subfolders named `somedir1`                      |
| `*.* somedir1\**\`         | Files in the base directory, plus folders named `somedir1` at any depth and everything below them |

**Find-only prefixes:**

- `ev:` passes the rest of the string **unchanged** to _Everything_, in Everything's own syntax (`ev:<c:|d:> *.mp3`);
  the _Search in_ field is ignored, and TC still applies all other dialog criteria to the results.
- `ed:` does the same but restricted to the _Search in_ directories and _Search in subdirectories_: TC prepends
  `path:<dir>` and, for a limited depth, `parents:<n`. When _Search in_ is empty, TC writes the start path it used into
  that field. Using `ev:` or `ed:` ticks the _Everything_ checkbox.
- A start path may be typed into _Search for_ instead of _Search in_.
- A `>` in _Search for_ when a search is **saved** means: when that saved search is loaded later, _Search for_ is left
  unchanged.
- With the _RegEx_ checkbox, the whole field is one regular expression matched against file names (case-insensitive by
  default).

_Basis: observed under Wine (selection dialog caption); help: proc_select, show_files, dlg_search, dlg_srch_loadsave,
proc_copy, whats_new; history._

## 3. Regular expressions

### 3.1 Engine and scope

The engine is **TRegExpr** (Andrey V. Sorokin's Delphi library), a Perl-like dialect. It is used in Find Files (names
and contents), Lister search, the Multi-Rename Tool, selection masks (with a leading `<`), sync filters, plugin `regex`
/ `!regex` rules, and colour filters and similar settings, where entered expressions are validated.

### 3.2 Matching model

- **Single line.** Matching is done within one line (text search) or one name, so multi-line modifiers are irrelevant.
- **Default case.** For file names the default is case-insensitive, as if `(?i)` were given.
- **Unanchored.** A regex matches **anywhere** (`test` finds "test" anywhere in a name or line) unless `^` / `$` are
  used.

### 3.3 Syntax

| Category                   | Syntax                                                                                                                                                                                                                                                                                                                                         |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Metacharacters             | `. \ ( ) [ ] { } ^ $ + * ?`; inside a class also `-`                                                                                                                                                                                                                                                                                           |
| Escapes                    | `\t` tab; `\xnn` character with hex code nn (`\x20` = space); `\x{nnnn}` Unicode code point (needed for characters outside the ANSI code page, since names are Unicode); `\[` `\\` `\.` literals                                                                                                                                               |
| Classes                    | `[aeiou]`, ranges `[a-z]`, negation `[^aeiou]`; `M[ae][iy]er` finds Mayer, Meyer, Maier, Meier                                                                                                                                                                                                                                                 |
| Shorthands                 | `.` any character; `\w` word char (letter/digit/`_`), `\W`; `\d`, `\D`; `\s` whitespace/word separator, `\S`; `\b` word boundary, `\B`                                                                                                                                                                                                         |
| Anchors                    | `^` start, `$` end (of line or name)                                                                                                                                                                                                                                                                                                           |
| Quantifiers                | `?` 0–1, `*` 0+, `+` 1+, `{n}`, `{n,}`, `{n,m}`; greedy by default; a trailing `?` makes them lazy: on "abbbbc", `b+` finds "bbbb", `b+?` finds "b"                                                                                                                                                                                            |
| Alternation                | `(John\|James\|Peter)`                                                                                                                                                                                                                                                                                                                         |
| Look-around                | `(?=…)`, `(?!…)`, `(?<=…)`, `(?<!…)`: positive/negative look-ahead/behind, e.g. `q(?=u)`, `q(?!u)`, `(?<=a)q`, `(?<!a)q`; `q(?!u)` matches the q in "Iraq" but not in "question"                                                                                                                                                               |
| Back-references            | `\1` … `\n` re-match the _text_ of a group: `\s([0-9]+) \1\s` (a number repeated), `(.+)\1+` (finds `abab`)                                                                                                                                                                                                                                    |
| Subroutine calls           | `(?n)` re-applies the _pattern_ of group n; `(?&name)` for named groups. `([a-z]+)_(?1)` matches `abc_def`, `([a-z]+)_\1` does not                                                                                                                                                                                                             |
| Groups                     | Up to **89** capturing subexpressions; `(?:…)` non-capturing (`(?:.*)_(.*)` captures only part2 as `$1`); `(?>…)` atomic (`a(?>bc\|b)c` finds "abcc" but not "abc"; not supported by Everything); `(?P<name>…)` or `(?'name'…)` named; `(?P=name)` named back-reference; `(?#…)` comment; `(?R)` recursion (`a(?R)?z` matches `az`, `aazz`, …) |
| Modifiers                  | `(?i)` / `(?-i)` case-insensitive / case-sensitive; `(?g)` / `(?-g)` greedy on/off (with `-g`, `+` behaves like `+?`). Other modifiers are irrelevant                                                                                                                                                                                          |
| Replacement (Multi-Rename) | `$1`…`$n` group text; `\U`, `\L`, `\F` before `$n` (upper, lower, first letter of each word upper); `\n` = unchanged (§1.11)                                                                                                                                                                                                                   |

### 3.4 Restrictions

- Look-ahead is allowed only at the **end** of the expression and look-behind only at the **start**; otherwise an error
  is shown.
- The pathological pattern `^??` is rewritten to `^?` to avoid a crash.

_Basis: help: reg_ex, dialog_box___multi_rename_tool, proc_select, dlg_search; history._

## 4. Plugin-rule operators (search templates)

Used on the Plugins page of Find Files and wherever a saved search is used as a selection type. A rule is _Plugin /
Property / OP / Value [/ unit]_; plugin `tc` is the built-in pseudo-plugin (§5.3). Values for date and time use the
format shown in the file panels.

| Field type            | Operators                                                                                                   |
| --------------------- | ----------------------------------------------------------------------------------------------------------- |
| String                | `contains`, `!contains`, `cont.(case)`, `!cont.(case)`, `=`, `!=`, `=(case)`, `!=(case)`, `regex`, `!regex` |
| Numeric / date / time | `=`, `!=`, `>`, `<`, `>=`, `<=`                                                                             |
| Boolean               | `=`                                                                                                         |
| Multiple choice       | `=`, `!=`                                                                                                   |

| OP                            | Meaning                                            |
| ----------------------------- | -------------------------------------------------- |
| `=`, `!=`                     | Equal / not equal (case-insensitive for strings)   |
| `=(case)`, `!=(case)`         | Case-sensitive equal / not equal                   |
| `>`, `<`, `>=`, `<=`          | Ordered comparison (numeric, date and time fields) |
| `contains`, `!contains`       | Substring present / absent (case-insensitive)      |
| `cont.(case)`, `!cont.(case)` | Case-sensitive substring present / absent          |
| `regex`, `!regex`             | Regular expression (§3) matches / does not match   |

Rules are combined with **AND (all match)** or **OR (any match)**. Rule order affects evaluation cost, not the result.
Numeric fields default to OP `>` when chosen.

_Basis: observed on Windows 11 (Exif plugin rule) and under Wine (operator lists); help: dlg_searchplugins._

## 5. Content fields

### 5.1 Field references

`[=pluginname.fieldname.unit]`, e.g. `[=tc.size.bkM2]`, `[=tc.writedate.Y-M-D]`. The same reference is used in the
Multi-Rename Tool (§1.9) and in custom columns (03 › Custom columns); plugin rules (§4) pick plugin, field and unit from
lists.

### 5.2 Units

| Field type | Units                                                                                                                                                                                        |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `size`     | `<default>`, `bytes`, `kbytes`, `Mbytes`, `Gbytes`, `bkM`, `bkM2` (x.x), `bkMG`, `bkMG2` (x.x), `bkMGT`, `bkMGT2` (x.x), `bkMG3` (x.xx), `bkMGT3` (x.xx)                                     |
| `*date`    | `<default>`, `YMD hms`, `Y-M-D h-m-s`, `D.M.Y h:m:s`, `D-M-Y h:m:s`, `M/D/Y h:m:s`, `D/M/Y h:m:s`, `Y/M/D h:m:s`, `YMD`, `Y-M-D`, `D.M.Y`, `D-M-Y`, `M/D/Y`, `Y/M/D`, `D/M/Y`, `Y`, `M`, `D` |
| `*time`    | `<default>`, `hms`, `h.m.s`, `h:m:s`, `h.m`, `h:m`, `a.m.sP`, `h`, `m`, `s`                                                                                                                  |

### 5.3 Built-in fields (pseudo-plugin `tc`)

| Field                                                                                 | Type                     | Notes                  |
| ------------------------------------------------------------------------------------- | ------------------------ | ---------------------- |
| fullname                                                                              | string                   | name.ext               |
| name                                                                                  | string                   | without ext            |
| ext                                                                                   | string                   |                        |
| dosname                                                                               | string                   | 8.3 name               |
| comment                                                                               | string                   | descript.ion           |
| path                                                                                  | string                   |                        |
| size                                                                                  | number                   | units in §5.2          |
| creationdate, creationtime                                                            | date / time              |                        |
| writedate, writetime                                                                  | date / time              |                        |
| accessdate, accesstime                                                                | date / time              |                        |
| attributes                                                                            | number                   | bit mask               |
| attributestr                                                                          | string                   | e.g. `-a--`            |
| archive, read only, hidden, system, directory, compressed, encrypted, sparse, offline | boolean                  |                        |
| versionstring                                                                         | string                   | EXE/DLL version        |
| versionnr                                                                             | number                   |                        |
| file type                                                                             | multiple choice          |                        |
| random number                                                                         | number                   |                        |
| decode html characters (text) / (utf-8) / (utf-16)                                    | string                   |                        |
| path length                                                                           | number                   |                        |
| case sensitive name                                                                   | boolean                  |                        |
| case sensitive in folder                                                              | boolean                  |                        |
| ZoneId, HostUrl, ReferrerUrl                                                          | number / string / string | Mark-of-the-Web stream |
| Tag Present, Title, Artist, Album, Release Year, Description, Track Nr, Genre         | mixed                    | Media tags             |

_Basis: observed under Wine (field and unit lists in the plugin-field picker); help: dlg_choosepluginfield,
dialog_box___multi_rename_tool._

## 6. Button and command parameters

### 6.1 Where they apply

These placeholders apply to the **Parameters** field of buttons, Start-menu items and `em_` commands, and to the
parameters of internal associations, hotkeys (`<key>_params=`) and aliases typed on the command line. Commands with
parameters (`OPENBARMENU`, `SELECTFILES` …) accept them too when used in internal associations and user-defined hotkeys
(17 › Commands with parameters). The **Command** field uses ordinary `%envvar%` instead (14 › The command language).

### 6.2 Expansion

```text
run(entry):
  params = entry.parameters
  if params starts with "?":                      # "?" must be the first parameter
      params = expand(rest of params)
      show dialog with the expanded text; the user may edit it, or cancel (nothing runs)
  else:
      params = expand(params)
  if the expansion needs a list file (%L, %F, …):
      write the list to TEMP; append its name; delete it when the started program exits
  start entry.command with params, in entry.startPath (default: the source path), with the chosen window state
```

**Case rule.** An **upper-case** letter inserts long names and paths; the **lower-case** letter inserts the 8.3 short
form. This holds for `%P/%p`, `%T/%t`, `%N/%n`, `%M/%m`, `%O/%o`, `%E/%e`, `%B/%b`, `%S/%s`. On FTP connections, `%p`
and `%t` insert the FTP URL of the directory.

**Source / target.** By default "source" is the active panel and "target" the other one. `%X` switches the following
parameters to **left / right** (`%P`/`%p` = left path, `%T`/`%t` = right path, `%N`/`%n` = left name, `%M`/`%m` = right
name, `%S`/`%s` = left selection, `%R`/`%r` = right selection); `%x` switches back to source / target. Example:
`%X%P %T` passes the left and right paths (e.g. to an external sync tool); `%X%P %x%P` passes the left path and then the
source path.

### 6.3 Single values

| Code                   | Inserts                                                                                                                                                                                                                                 |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `%P` / `%p`            | Source path **with** trailing `\` (long / short)                                                                                                                                                                                        |
| `%T` / `%t`            | Target path with trailing `\` (long / short)                                                                                                                                                                                            |
| `%N` / `%n`            | Name under the cursor in the source panel (long / 8.3)                                                                                                                                                                                  |
| `%M` / `%m`            | Name under the cursor in the target panel (long / 8.3)                                                                                                                                                                                  |
| `%O` / `%o`            | Current name without extension                                                                                                                                                                                                          |
| `%E` / `%e`            | Current extension, without the dot                                                                                                                                                                                                      |
| `%B`, `%B0` … `%B9`    | Directory names of the source path, counted from the end: `%B`/`%B0` = parent, `%B1` = grandparent, … Includes the relative path of branch view or of a search result.                                                                  |
| `%BT`, `%BT0` … `%BT9` | The same for the **target** path, without the branch-view part                                                                                                                                                                          |
| `%B-`, `%B-0` … `%B-9` | Like `%B`, but **without** the branch-view relative path. Empty in search results.                                                                                                                                                      |
| `%B+`, `%B+0` … `%B+9` | Counted from the **start**: `%B+` = drive with `:`, `%B+0` = drive letter without `:`, `%B+1` = first directory (or share), `%B+2` = second directory, …                                                                                |
| `%C1`                  | First selected file, or the file under the cursor (like the first file of Compare by content)                                                                                                                                           |
| `%C2`                  | Second selected file; otherwise the first selected in the target panel; otherwise the file with the same name in the target panel. **When the right panel is active and fewer than 2 files are selected, `%C1` and `%C2` are swapped.** |
| `%C3` … `%C9`          | 3rd … 9th selected file in the source panel; empty if fewer are selected                                                                                                                                                                |
| `%c1` … `%c9`          | As `%C…`, with 8.3 names and paths                                                                                                                                                                                                      |
| `%v`                   | For file-system plugins such as "virtual panel": the virtual name (`%N` gives the name of the real file the entry points to)                                                                                                            |
| `%V`                   | As `%v`, including the full path with the plugin name                                                                                                                                                                                   |
| `%%`                   | A literal `%`                                                                                                                                                                                                                           |
| `%\|envvar\|`          | The value of an environment variable (any kind in 19 › Environment variables, e.g. `%\|windir\|`, `%\|$DESKTOP\|`). Plain `%envvar%` is not possible here, because `%` starts placeholders.                                             |

### 6.4 Multi-file values

| Code         | Inserts                                                                                                                                                                                               |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `%S` / `%s`  | All selected names, space-separated (long / 8.3). Names with spaces are quoted, and so are names containing `=` (needed for batch files). Mind the **32767-character** command-line limit.            |
| `%S<n>`      | The first n selected names (`%S10`)                                                                                                                                                                   |
| `%S+<n>`     | The n-th selected name (`%S+10`)                                                                                                                                                                      |
| `%S+<n>-<m>` | Names n through m (`%S+10-12`). Without `m`: from n to the end.                                                                                                                                       |
| `%S-<n>`     | The n-th from the end (`%S-10`)                                                                                                                                                                       |
| `%S-<n>-<m>` | From the n-th-last to the m-th-last (`%S-10-9`). Without `m`: to the end.                                                                                                                             |
| `%P%S`       | All selected names with the source path. They are quoted automatically; **do not add quotes yourself**. Any path code (`%P`, `%p`, `%T`, `%t`) directly before `%S`/`%s` is applied to **each** name. |
| `%R` / `%r`  | Like `%S`, for the selection in the **target** panel (`%T%R` with the path)                                                                                                                           |

**Quoting and affixes:**

- If the user writes `"%S"` (in quotes), every name is quoted individually: `"name1" "name2"`.
- Inside quotes, `%S`, `%R`, `%P%S` and `%T%R` accept affixes: `"before%Sbeforeext%Eafterext"` puts `before` in front of
  each name, `beforeext` before the last dot of each name, and `afterext` after each extension.
- `%Q` anywhere turns **off** the automatic quoting of combinations such as `%P%N` for names that contain spaces; the
  user must then quote them.
- `%q` removes all double quotes from `%A1`, `%A2`… and from `%|envvar|`; each occurrence toggles this on and off.

### 6.5 List files

Each of these codes writes the selected files and folders to a temporary list file in TEMP and appends the file's
**name** to the parameters. **Only one list per command** is supported. The file is deleted when the started program
exits. Adding `%a` also includes the **target panel's** selection.

| Code          | Content of each line                                         | Encoding                |
| ------------- | ------------------------------------------------------------ | ----------------------- |
| `%L`          | Long name with full path (`c:\Program Files\Long name.exe`)  | ANSI                    |
| `%l`          | Short (8.3) name with full path (`C:\PROGRA~1\LONGNA~1.EXE`) | ANSI                    |
| `%F`          | Long name without path                                       | ANSI                    |
| `%f`          | Short name without path                                      | ANSI                    |
| `%D`          | Short name with full path                                    | DOS (OEM) character set |
| `%d`          | Short name without path                                      | DOS (OEM) character set |
| `%UL` / `%UF` | As `%L` / `%F`                                               | UTF-8 with BOM          |
| `%WL` / `%WF` | As `%L` / `%F`                                               | UTF-16 with BOM         |

### 6.6 Empty-selection and archive modifiers

These can appear anywhere in the parameters.

| Code      | Effect                                                                                                                          |
| --------- | ------------------------------------------------------------------------------------------------------------------------------- |
| (default) | When nothing is selected, list and multi-file codes fall back to the **file under the cursor**                                  |
| `%Y`      | When nothing is selected, pass an **empty** list or empty multi-file value instead                                              |
| `%y`      | When nothing is selected, drop **only** the list parameter and pass the remaining parameters                                    |
| `%Y%y`    | Like `%y` when something is selected or the cursor is on `..`; otherwise the file under the cursor is used                      |
| `%Z`      | Inside an archive, `%P` / `%T` pass the **archive file** as the path (e.g. `%Z%P`). Without `%Z`, archive paths are not passed. |

### 6.7 Substrings

Any placeholder can carry a cmd.exe-style substring suffix `:~start,length`:

- `%N:~2,5` skips 2 characters and takes 5.
- Negative values count from the end: `%N:~-8,5`; `%P:~0,-1` drops the trailing backslash.
- With no length, everything from `start` to the end is taken (`%P:~4`).
- To write digits directly after the length, end the length with another `~`: `%N:~2,5~2`.
- **Start `-0` is special.** `%N:~-0,20` takes the first 20 characters of the name **without** its extension;
  `%N:~-0,-20` takes the first 20 characters of the **extension**. If the file has no extension, `-0,n` still takes the
  name.
- With `%P%S`, the substring applies to the **file name**, not to path plus name.

### 6.8 Alias-only codes

Aliases are defined with the hotkey dialog (14 › Redefining hotkeys and aliases); the words typed after the alias on the
command line are its parameters.

| Code                 | Inserts                                                                                                           |
| -------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `%A`                 | Everything typed after the alias                                                                                  |
| `%A<n>`              | The n-th parameter (`%A5`)                                                                                        |
| `%A-<n>`             | The n-th-last parameter (`%A-3`)                                                                                  |
| `%A<n>+` or `%A<n>-` | Parameter n and all after it (`%A5+`). A negative n counts from the end: `%A-5-` = from the 5th-last to the last. |
| `%A<n>-<m>`          | Parameters n through m (`%A3-5`)                                                                                  |
| `%A-<n>-<m>`         | From the n-th-last to the m-th-last (`%A-5-3`)                                                                    |

Example: alias `op` with Command `totalcmd.exe` and Parameters `/L=%A1 /R=%A2`. Typing `op c:\dir1 d:\dir2` runs
`totalcmd.exe /L=c:\dir1 /R=d:\dir2`.

### 6.9 The Start-menu editor's hint

The _Change start menu_ dialog prints a simplified hint under its fields:

```text
? as the first parameter: invokes dialog to enter parameters
%p: inserts actual source path          %t: the actual target path
%n: inserts file name under the cursor  %%: the percent sign
```

The hint names only these four codes and uses the lower-case forms, which strictly insert the **short 8.3** path or
name; the long forms are `%P`, `%T`, `%N`. All codes of this section work there.

_Basis: observed under Wine (Start-menu hint); help: dlg_configbuttonbar, dlg_usermenu, env_vars; history (`=` quoting,
`"%S"`, `-0` without extension, `%P%S` substrings)._

## 7. Hotkey notation (`[Shortcuts]`)

- An entry is a key name with modifier prefixes: `C` = Ctrl, `A` = Alt, `S` = Shift, then `+` and the key:
  `CAS+F2=cm_RenameOnly`. The help shows only the full `CAS` form; subsets in the same order (`C+Q=cm_SrcQuickView`,
  `CS+F7`) are the natural reading (unverified).
- There is no Win prefix: combinations with the Windows key go into the separate section **`[ShortcutsWin]`** with the
  same syntax.
- A parameter for the command is stored in a separate key `<mods>+<key>_params=`, e.g. `CAS+F2_params=`; placeholders
  (§6) are allowed there.
- Key names as listed in the _Redefine hotkeys_ dialog: `F1`…`F12`, `A`…`Z`, `0`…`9`, `INS`, `DEL`, `HOME`, `END`,
  `PGUP`, `PGDN`, `SPACE`, `BACK`, `TAB`, `+`, `-`, `*`, `/`, `ENTER`, `ESC`, `LEFT`, `RIGHT`, `UP`, `DOWN`, `PAUSE`,
  OEM keys (names with an underscore such as `OEM_…`), and "Numeric keypad 0–9". How the keypad and the other non-letter
  keys are spelled in the ini file is not documented (spellings such as `ADD`, `NUM0` are unverified).
- `F13`…`F24` are accepted when typed into `[Shortcuts]` by hand. The keypad digits work as hotkeys only with NumLock
  on.
- Values: a `cm_` or `em_` command, a command with parameters including suffix variants (`SELECTFILEST`, `OPENTABSL`),
  or an external program. Full rules: 06 › Redefining keys.

_Basis: help: inisettings3, dlg_configconfirmation; history (F13–F24, keypad, OEM names, suffix variants)._

## 8. Path and drive syntax

| Location             | Path shown in the path bar                                                                             | Notes                                                                                                                                                                         |
| -------------------- | ------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Local folder         | `<drive in lower case>:\<path>\<mask>`, e.g. `c:\windows\*.*`                                          | Root: `c:\*.*`                                                                                                                                                                |
| Archive              | `c:\x\a.zip\dir\*.*`                                                                                   | The archive is a path component                                                                                                                                               |
| FTP connection       | `<connection number>:<server path with />`, e.g. `0:/*.*` at the server root, `0:/pub/*.*` in a folder | Command-line prompt `0:/pub/>`; drive line `ftp://127.0.0.1:2121` or `ftps://…` for TLS; typed addresses use `ftp://host/dir`. The virtual root of FTP connections is `\ftp`. |
| Network Neighborhood | `\\Network\*.*`                                                                                        | Lists the file-system plugins, the network and `<Refresh>`                                                                                                                    |
| File-system plugin   | `\\\<plugin root>\…`, e.g. `\\\Registry\*.*`                                                           | Prompt e.g. `\\\Registry\HKEY_CURRENT_USER\AppEvents>`                                                                                                                        |
| UNC                  | `\\server\share\…`; a server's share list `\\localhost\*.*`                                            | `cd \\localhost\c$\tc-sandbox\B` opens it directly                                                                                                                            |

- **Drive list** (Alt+F1 / Alt+F2) special entries: `+` = Computer (drive overview), `*` = My Documents, `\` = Network
  Neighborhood; a mapped drive adds a row such as `z  \\localhost\c$\tc-sandbox`. `cm_*OpenDrives` accepts `\` (root),
  `.` (parent) and `[` (network) as parameters (17 › Parameters of `cm_` commands).
- **Pack target**: `<packer>:<path>` (`zip:c:\a.zip`, `7z:c:\a.7z`, `tgz:c:\dir\name.tgz`, `gz:c:\*.*.gz`). The default
  target is `zip:<other panel's path>\<cursor name>.zip`; switching the packer rewrites prefix and extension
  (`7z:…\dir1.7z`, `tgz:…\dir1.tgz`).
- **Virtual folders** in commands: `cd shell:Name` and `cd ::{GUID}`.

_Basis: observed on Windows 11 (FTP, plugins, Network Neighborhood, UNC, drive list) and under Wine (local and archive
paths, pack targets)._

## 9. Menu-entry conventions (hotlist, Start menu)

The directory hotlist (`[DirMenu]`) and the Start menu (`[user]`) number their items with the same keys:

| Key / value       | Meaning                                                                                                                                    |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `menuN=Title`     | Item caption; `&` underlines the next letter                                                                                               |
| `cmdN=cd c:\path` | The command (any command, e.g. `cm_OpenDesktop`)                                                                                           |
| `pathN=…`         | Hotlist: optional path set at the same time in the **other** panel (as `path` or `cd path`). Start menu: the start path (14 › Start menu). |
| `menuN=-`         | Separator                                                                                                                                  |
| `menuN=-Title`    | Starts a submenu                                                                                                                           |
| `menuN=--`        | Ends a submenu                                                                                                                             |

Hotlist only:

| Form                  | Meaning                                                                                                                                                                                       |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cd D:\Dir\Focusme\:` | A command ending in `\:` (or `\\:`) goes to the **parent** and puts the cursor on that folder                                                                                                 |
| `menuN=?Secret`       | Hidden while the hide character (default `?`, any character except `-`; `MenuHideChar`) is active. In the hotlist editor a double-click toggles the character on an entry or a whole submenu. |

```ini
[DirMenu]
menu1=&Windows
cmd1=cd c:\windows
path1=d:\backup          ; optional target-panel path
menu2=-Projects          ; submenu start
menu3=App
cmd3=cd d:\src\app\:     ; parent + focus "app"
menu4=--                 ; submenu end
menu5=-                  ; separator
menu6=?Secret            ; hidden while the hide character "?" is active
```

Editors: 12 › Directory hotlist editor, 14 › Start menu; file formats: 19 › `wincmd.ini` reference.

_Basis: help: directoryhotlist, dlg_dirmenu, dlg_usermenu, inisettings1._
