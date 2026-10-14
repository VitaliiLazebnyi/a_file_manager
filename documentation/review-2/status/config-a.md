# Fix round 2 — status of config-a

Area: `Sources/Plugins/Configuration`, `SystemTools`, `ViewOptions`, `MacIntegration` and their tests. Work list:
`documentation/review-2/findings/config.md`, the entries whose first file is in those directories (plus C064, C065 and
C128, which name no file and are about this area).

File names below are short for: `PE` = Configuration/ParameterExpansion.swift, `SL` = Configuration/ShellLine.swift
(new), `CP` = Configuration/ChildProcess.swift (new), `CR` = Configuration/CommandRunner.swift, `CL` =
Configuration/CommandLanguage.swift, `ST` = Configuration/SettingsTransfer.swift (new), `CC` =
Configuration/ConfigurationCenter.swift, `CM` = Configuration/ConfigurationModels.swift, `CPl` =
Configuration/ConfigurationPlugin.swift, `STP` = SystemTools/SystemToolsPlugin.swift, `SCL` =
SystemTools/CommandLine.swift, `SI` = SystemTools/SystemInformation.swift, `DL` = SystemTools/DirectoryList.swift, `VO`
= ViewOptions/ViewOptionsPlugin.swift, `MI` = MacIntegration/MacIntegrationPlugin.swift.

## 1. Findings and verdicts

| ID   | Status            | Note                                                                                                                                                                                                                                                                                                                              |
| ---- | ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| C001 | fixed             | MI: Open With asks Launch Services in a job, through `BlockingCalls`, so it ends when cancelled.                                                                                                                                                                                                                                  |
| C002 | fixed             | PE, SL, CR, CP. A value is never written into the shell line: it is an `ExpandedPiece.value`, handed to the shell as an argument and referred to as `"${__afm_N}"`. All quoting helpers work on Unicode scalars. Tested against real `/bin/zsh -c` and `/bin/sh -c`.                                                              |
| C003 | fixed             | MI: applications looked up in a job; Reveal hands Finder at most 1000 items, off the main thread; Share refuses more than 1000. STP: its Open With lookup (already a job) now ends when cancelled.                                                                                                                                |
| C013 | fixed             | ST, CC, CPl: keys checked, values checked by kind, summary shown, nothing stored without the user's answer (also with a file given as argument), parts that run code or change trust need a tick each, 16 MB cap. Hotlist entries are listed and need a tick; restricting what a hotlist entry may run is Places (cross-request). |
| C014 | fixed             | As C013: user commands, Start menu and key bindings are separate parts, off by default; trusted certificates likewise.                                                                                                                                                                                                            |
| C015 | fixed             | As C013. Imported connections get a new number unless identical to the stored one, so a stored password cannot be redirected. Binding the keychain item to host/port/user is Network (cross-request).                                                                                                                             |
| C016 | fixed             | PE: only ASCII blanks the user wrote are trimmed from the ends of the line; a value keeps every character.                                                                                                                                                                                                                        |
| C017 | fixed             | SL: `ShellContext` follows `$(…)`, backticks, `$'…'`, comments, here-documents, `${…}`, arithmetic. A reference is written where it is safe (`$(…)` included); inside `$'…'`, backticks, a comment, a here-document, after a backslash, in arithmetic the command is refused with an explanation.                                 |
| C018 | duplicate of C017 |                                                                                                                                                                                                                                                                                                                                   |
| C019 | fixed             | PE: `number()` saturates; `slice` and the substring closure cannot overflow.                                                                                                                                                                                                                                                      |
| C020 | duplicate of C019 |                                                                                                                                                                                                                                                                                                                                   |
| C021 | duplicate of C002 |                                                                                                                                                                                                                                                                                                                                   |
| C022 | duplicate of C002 | Also the `-` + combining mark case: the `./` guard looks at the first scalar.                                                                                                                                                                                                                                                     |
| C023 | fixed             | Verdict on C002; same fix. `%\|VAR\|` and `%VAR%` values are data too (CL `environmentPieces`).                                                                                                                                                                                                                                   |
| C026 | fixed             | STP: Print's enabled closure is `isLocal() && model().hasOperandFile`.                                                                                                                                                                                                                                                            |
| C027 | fixed             | CR: the marked names are gathered only for a text with a code that needs them (`ParameterExpander.usesSelection`); in a list of 5000 items or more they are gathered and expanded off the main thread.                                                                                                                            |
| C030 | fixed             | MI: operands picked out and paths joined off the main thread for a long list.                                                                                                                                                                                                                                                     |
| C031 | fixed             | MI: log lines name at most 8 paths, else the count; every line is one line and bounded.                                                                                                                                                                                                                                           |
| C032 | fixed             | MI `follow`: a cursor move with marks costs a comparison of three numbers; without marks it shows the cursor file; marks are gathered off the main thread when they or the list change.                                                                                                                                           |
| C033 | fixed             | MI: the folders to refresh are worked out in the tags job.                                                                                                                                                                                                                                                                        |
| C035 | duplicate of C013 | Remote tabs are a part of their own that needs a tick.                                                                                                                                                                                                                                                                            |
| C036 | duplicate of C032 |                                                                                                                                                                                                                                                                                                                                   |
| C038 | fixed             | DL: `ListCollector` lists with the cancellation flag. The MultiRename lines of this finding are another area.                                                                                                                                                                                                                     |
| C041 | fixed             | CR: the chain of calling commands is carried through every `cm_wait` and waited program; plus a depth limit (16) and a step limit (1000) per run, and a command to stop waiting chains.                                                                                                                                           |
| C042 | fixed             | Verdict on C041. The case through a waited program uses the same carried chain; tested with `cm_wait`, not with a real program in the loop.                                                                                                                                                                                       |
| C043 | fixed             | CR, CP, STP, SystemTools/Support.swift: always `/bin/zsh -l -c` (or `/bin/sh -c`); exit status 126/127 of a user command is reported.                                                                                                                                                                                             |
| C044 | fixed             | CR, CP: no thread waits for a child (`DispatchSource` on its exit); waiting chains can be stopped (`afm_StopUserCommands`).                                                                                                                                                                                                       |
| C045 | fixed             | As C043; the PATH of a non-zsh login shell is asked for once, off the main thread, and passed on.                                                                                                                                                                                                                                 |
| C046 | fixed             | Verdict on C044.                                                                                                                                                                                                                                                                                                                  |
| C047 | fixed             | CR `applicationLine(for:)`: the first word is taken as a shell word (`ShellWords.firstWord`), the path is passed as a value.                                                                                                                                                                                                      |
| C048 | fixed             | CR: for a bare name the shell itself decides (`command -v`), with the login shell's PATH. SCL/STP: `TypedCommand.application` gets `LoginShell.searchPath`.                                                                                                                                                                       |
| C049 | duplicate of C016 |                                                                                                                                                                                                                                                                                                                                   |
| C050 | fixed             | PE: a name with CR or LF refuses the command (`ExpandedParameters.problem`); `%F` names beginning with `-` get `./`. No NUL-separated list code was added.                                                                                                                                                                        |
| C051 | duplicate of C032 |                                                                                                                                                                                                                                                                                                                                   |
| C053 | fixed             | STP/SCL: option "Remember the command lines that were run", a line beginning with a blank is never remembered. ST/CC: export leaves histories out unless ticked and is written 0600.                                                                                                                                              |
| C054 | fixed             | SCL: a bare `X.app` means the installed application first; the panel's folder only when none is installed or by path.                                                                                                                                                                                                             |
| C055 | fixed             | STP, SI: volume questions, rename, eject, the Open With lookup and System Information go through `BlockingCalls.answer` with the job's cancellation flag, so the job ends when cancelled. Not tested with a real stale mount.                                                                                                     |
| C056 | duplicate of C026 |                                                                                                                                                                                                                                                                                                                                   |
| C062 | fixed             | VO: display filters and Only Selected are worked out off the main thread from 20,000 entries on. Select All / Invert / Restore are `PanelModel` and the Selection plugin: other area (cross-request).                                                                                                                             |
| C063 | fixed             | VO `sortInBackground`: a stale result leads to another background sort, never to a sort on the main thread.                                                                                                                                                                                                                       |
| C064 | fixed             | VO: the one closure in this area that decoded JSON per call (`lastCustomFilter` enabled) now only asks whether the key is stored. Closures of other plugins are other areas.                                                                                                                                                      |
| C065 | fixed             | CP: arguments are handed over byte for byte (`posix_spawn`); the `./` guard is applied only where a shell word begins.                                                                                                                                                                                                            |
| C066 | fixed             | CC: `synchronize()` runs off the main thread. Export and import never called it.                                                                                                                                                                                                                                                  |
| C083 | duplicate of C027 | The tab part of this entry is FolderTabs.                                                                                                                                                                                                                                                                                         |
| C084 | duplicate of C044 |                                                                                                                                                                                                                                                                                                                                   |
| C085 | duplicate of C047 |                                                                                                                                                                                                                                                                                                                                   |
| C086 | fixed             | ST `SettingsExportOptions`: histories, connections and trusted certificates only when asked for.                                                                                                                                                                                                                                  |
| C087 | fixed             | ST `CheckedSettings.read`: 16 MB.                                                                                                                                                                                                                                                                                                 |
| C088 | fixed             | PE: names inside the user's quotes get the `./` guard when the quote begins a word.                                                                                                                                                                                                                                               |
| C089 | duplicate of C003 |                                                                                                                                                                                                                                                                                                                                   |
| C090 | duplicate of C032 |                                                                                                                                                                                                                                                                                                                                   |
| C091 | duplicate of C001 |                                                                                                                                                                                                                                                                                                                                   |
| C095 | duplicate of C054 |                                                                                                                                                                                                                                                                                                                                   |
| C098 | fixed             | CL: values of `%VAR%` are data like any other.                                                                                                                                                                                                                                                                                    |
| C099 | not a defect      | A leaked temp folder after pid reuse, as the entry says. List files are now 0600 in a 0700 folder.                                                                                                                                                                                                                                |
| C100 | refuted           | The direct case was already caught; still is (existing test).                                                                                                                                                                                                                                                                     |
| C101 | fixed             | CP: `posix_spawn` instead of Foundation's `Process`; test with a precomposed `é`.                                                                                                                                                                                                                                                 |
| C102 | fixed             | CR: list files are written and removed on one serial queue; at quit only lists older than the grace time are removed.                                                                                                                                                                                                             |
| C103 | fixed             | CM, CC: at most 500 Start-menu entries and 2000 user commands are used from stored data; import refuses more. `Hotlist.limit` is Places.                                                                                                                                                                                          |
| C104 | fixed             | CM: a second damage is kept too (`.unreadable.previous`); the copies are not exported and not imported; Reset removes them.                                                                                                                                                                                                       |
| C105 | fixed             | ST: export is 0600 and leaves private items out by default. The tree cache part is Places.                                                                                                                                                                                                                                        |
| C106 | fixed             | CP: `E2BIG` is reported as "The command line is too long … use a list file (%L)".                                                                                                                                                                                                                                                 |
| C107 | fixed             | PE/SL: the guard is applied where the lexer says a word begins.                                                                                                                                                                                                                                                                   |
| C108 | fixed             | SL: an empty value is still a reference (an empty word); the readable form shows `""`.                                                                                                                                                                                                                                            |
| C109 | fixed             | PE: the user's text around `%S` stays text and is not escaped; an escaped quote does not end the quotes.                                                                                                                                                                                                                          |
| C113 | fixed             | DL, STP: the longest line is measured in the job (`PagePrintView(longestLine:)`).                                                                                                                                                                                                                                                 |
| C125 | fixed             | VO: `model().selectionCount > 0`.                                                                                                                                                                                                                                                                                                 |
| C126 | fixed             | VO: a result is dropped when `model.sort` is no longer the order it started from.                                                                                                                                                                                                                                                 |
| C127 | fixed             | As C062 and C063.                                                                                                                                                                                                                                                                                                                 |
| C128 | not a defect      | Verdict that list files, `cd`, `cm_` steps and `%Q` were unaffected. `%Q` still pastes the name as it is; only the user's own text can switch it on (`%%Q` is not the code, and a name is never read for codes, also when one command hands it to the next).                                                                      |

Counts: fixed 51, duplicate 16, not a defect 2, refuted 1, needs other area 0, not fixed 0 (70 IDs). Parts of C013,
C015, C038, C062, C103 and C105 that lie in other areas are named in the notes and in `cross-requests/config-a.md`.

## 2. Decisions

Shell lines

1. Values reach the shell as arguments and are given names first (`__afm_1="${1}" …`, then the user's line with
   `"${__afm_N}"`). Named variables rather than `$1` in the line, so that `set --`, `shift` and functions in the user's
   line cannot move them; shell variables rather than environment variables, so that started programs do not inherit
   them.
2. Refused places: `$'…'`, backticks, a comment, in or after a here-document, after a backslash or a `$`, `$((…))`,
   `((…))`, `$[…]`, the subscript of `$name[…]`, a `${…}` with an operator (and everything after it), a `case` inside
   `$(…)` (and everything after it), and a test (`[[ ]]`, `[ ]`, `test`) that compares numbers and holds a placeholder.
   Some of these refuse more than strictly needed; refusing is the safe side.
3. A template that hands a name to another interpreter (`sh -c '… %N'`, `eval %N`, `osascript -e`) still gives that
   interpreter the name to read. That cannot be seen from the line and is not refused.
4. `%Q` keeps its meaning (the name is pasted as it is).
5. `?` prompt: names made only of letters, digits, blanks and `._-/+,:@` are shown written out (quoted where they are a
   word); every other name is shown as `${__afm_N}` with a legend below. The edited line is read back with the
   references as values.
6. An empty value that is a word of its own is an empty argument (was: no argument).
7. The fixed shell is `/bin/zsh -l -c`, `/bin/sh -c` without zsh. For a login shell other than zsh its PATH is asked for
   once (`$SHELL -l -c 'printenv PATH'`, then without `-l`, 3 s limit).
8. Exit status 126 and 127 of a user command are reported as "cannot be started" and end a waiting chain; other statuses
   are not reported (programs use them for ordinary answers).
9. A user command or Start-menu entry called from another one is always run directly, with its values kept as values. If
   it is refused or the user gives up its prompt, the calling chain ends there.
10. Limits: 16 levels of nesting, 1000 steps per run, `cm_wait` at most one hour. New command "Stop Waiting User
    Commands" (`afm_StopUserCommands`) in the Start menu; it sends SIGTERM to the programs a chain waits for.
11. List files: 0600 in a 0700 folder; a name with a line break refuses the command.

Settings 12. Known keys: registered preferences (checked by kind and range), keys the program has stored, the fixed
keys, and keys in a fixed list of plugin namespaces. Unknown entries are left out and listed. A known value of the wrong
kind refuses the whole file. 13. Numbers are limited to ±10^12, visit counters to 0…1,000,000; 2000 user commands, 500
Start-menu entries, 65,536 bytes per text, 16 MB per file. 14. Parts that need a tick, off by default: user commands and
Start menu; key bindings; text settings that name a program, command or file (by the key's name: editor, terminal,
program, command, tool, shell, exec, path, file); trusted certificates and other `network.` trust keys; connections;
hotlist; tabs when one is not a `file:` location. A part whose values equal the stored ones is not asked about. An
unticked part stays as it is. 15. An import removes ordinary settings the file lacks (as before) but never histories,
connections, or parts that need a tick. 16. Export: 0600 through a temporary file and rename. Histories (keys with
`history`, `undo`, `lastServer` in the name that are not preferences) and connections with trusted certificates are in
it only when ticked. With a file given as argument there is no dialog, the private parts are left out, and a message
says what the file holds.

Other 17. A typed line that begins with a blank is run but not remembered (this changes an existing test). 18. Reveal in
Finder shows the first 1000 items of a larger selection; Share refuses more than 1000. 19. Background sort and filter
have no fallback to the main thread. While a long list keeps changing faster than it can be sorted, the new order does
not appear until it holds still for one sort. 20. Thresholds: sort and filter in the background from 20,000 entries;
marked items gathered in the background in lists of 5000 items or more. 21. `DisplayText` and `LoginShell` are copied
into each plugin that needs them (cross-request to move them).

## 3. Tests

New files in `Tests/PluginTests`:

- `Review2ConfigAShellTests.swift` (12 tests): 34 hostile names × 17 templates × `/bin/zsh` and `/bin/sh`, 400 generated
  names × 4 templates × 2 shells, refused and allowed places, no value in the script text, `%Q`, trailing no-break
  spaces, numbers that overflowed, the `./` guard, list files, the prompt, `DisplayText`, arguments byte for byte
  through `ChildProcess`.
- `Review2ConfigARunnerTests.swift` (13): recursion across `cm_wait`, step and depth limits, stopping a waiting chain,
  values from one command to the next, refused lines, background gathering of marked names, application path with a
  space, list files at quit, and three tests with a real login shell (hostile names end to end, a program that is not
  found, a chain that stops).
- `Review2ConfigASettingsTests.swift` (7): confirmation and ticks, unchanged parts, wrong kinds, the fuzzer's
  reproducer, size cap, connection numbers, export mode and contents, bounded lists and backups.
- `Review2ConfigASystemToolsTests.swift` (8), `Review2ConfigAViewOptionsTests.swift` (5), `Review2ConfigAMacTests.swift`
  (4).

Existing tests changed on purpose: `ConfigurationCommandTests.swift` (empty value is `""`; prompt shows the name quoted;
Start menu has the stop command; import needs the form answered) and `SystemToolsTests.swift` (a line with a leading
blank is not remembered).

Final runs, from the project root with `--scratch-path .build-config-a`, after the last source change:

- `--filter 'Review2ConfigA'`: 49 tests in 7 suites passed.
- `--filter` on the existing suites of the area (ParameterExpansion, ConfigurationCommands, ConfigurationModels,
  ConfigPlacesFixExpansion/Store/Runner/Launching/SystemTools, ConfigurationAdoption, SystemToolsCommandTests,
  SystemToolsTypes, ViewOptions, MacIntegrationMore): 109 tests in 15 suites passed.
- Suites of other areas that load these plugins (PluginCommands, Integration, ToolsAdopt, KernelFixLocal, FileOpsFix,
  NetworkPlugin, ArchivesPlugin): 148 tests in 20 suites passed. No failures. The whole test suite was not run.

## 4. Not done

- Not built or run: the fuzz package (`Tests/Fuzz`). Its `quote`, `quote-demo` and `settings` targets compile against
  the kept names but no longer exercise the path the program runs (cross-request).
- Not tested: C055 against a real stale mount; C042 with a real program inside the loop; Quick Look following (it needs
  the system's panel, which tests do not open); the PATH lookup for a fish/tcsh/bash login shell beyond compiling it.
- Not added: a NUL-separated list code for `%L` (C050 offered it as an alternative to refusing).
- Programs and builtins that read an argument as code (`sh -c`, `eval`, `let`) are not detected (decision 3).
- Waiting in other areas, see `cross-requests/config-a.md`: the keychain item bound to the connection number alone
  (Network), `Hotlist.limit` on load and what a hotlist entry may run (Places), Select All / Invert / Restore on the
  main thread (kernel, Selection), a registry of settings keys (kernel), the window's own command-line history (shell).
- C011, C012 and the Selection part of C097 belong to the Selection plugin, which neither config agent owns.
