# Review config, places, tools again

## Second-round review: Configuration, Places, SystemTools, VirtualFolders

All files in the four plugin folders were read in full; no project file was modified. Experiments are under
`/private/tmp/claude-501/-Users-cm0k-Claude-Projects-TotalCommander/91e36f29-0d53-4421-8985-1ec839e7f5c4/scratchpad/review2/config/`:

- `harness` (built from `main.swift` and a verbatim copy of `ParameterExpansion.swift`) ran 19 templates against 43
  hostile names in zsh, bash, sh, dash, ksh, tcsh and csh; raw results are in `out.txt`.
- `vl/` round-trips virtual folder URLs.
- `pg/` checks process-group behaviour on cancel.

fish and nu are not installed, so nothing was tested in them.

### Findings

#### 1. Critical / security — a file name can run commands through the default `%N`, in every shell (confirmed)

- **Where:** `Sources/Plugins/Configuration/ParameterExpansion.swift:63-70` (`ShellWords.escaped`), `:284` (single-quote
  branch), and the same helpers in `CommandLanguage.swift:105-107`.
- **What:** `escaped` walks `Character`s (grapheme clusters). A `"`, `` ` `` or `\` followed by a combining mark or
  variation selector is one `Character` that is not equal to the bare ASCII character, so it is not escaped.
  `needsQuoting` works on scalars, so the value is still wrapped in `"…"`, and the shell sees a raw quote or backtick.
  The single-quote branch has the same hole: `replacingOccurrences(of: "'")` does not match `'` + U+0301 (the harness
  printed `'́x'\''y`).
- **Trigger:** a file named `` `◌́;touch PWNED;`◌́ `` (backtick + U+0301) or `"◌́;touch PWNED;"◌́` under the cursor, with
  any user command, button or Start-menu entry using `%N`, `%S`, `%P%N`, `x%Ny`, `--out=%N`, `"%N"`, `"pre %N post"` or
  `%|VAR|`. `touch PWNED` ran in zsh, bash, sh, dash and ksh (and tcsh/csh without `-l`). The `'%N'` form fell to the
  `'◌́…'◌́` name.
- **Lesser effect:** `$` + U+0301 is not escaped either; bash and ksh passed a mangled name (wrong file, no execution).
- **Fix:** escape per Unicode scalar or UTF-8 byte, never per `Character`. Better, stop pasting values into shell text
  (see finding 2).

#### 2. High / security — quote tracking does not understand command substitution, backticks, `$'…'`, comments, here-docs or `\%N` (confirmed)

- **Where:** `ParameterExpansion.swift:232-244` (`literal`), `:282-287` (`rendered`).
- **What:** the tracker only toggles on `"` and `'`. Confirmed injections with ordinary names:

| Template                                            | Name                                             | Shells where `touch PWNED` ran                                   |
| --------------------------------------------------- | ------------------------------------------------ | ---------------------------------------------------------------- |
| `"$(printf %s %N)"`                                 | `a;touch PWNED;`                                 | zsh, bash, sh, dash, ksh                                         |
| `"$(printf %s "%N")"` (the correct way to write it) | `a;touch PWNED;`                                 | same five; the line becomes `""a;touch PWNED;""`                 |
| `` `printf %s %N` ``                                | `$(touch PWNED)`                                 | bash, sh, dash, ksh (the backtick layer strips the `\`; not zsh) |
| `$'%N'`                                             | `\';touch PWNED;#`                               | zsh, bash, ksh (4 of 7 shells)                                   |
| `# %N`                                              | name containing a newline                        | bash, sh, dash, ksh (not zsh)                                    |
| here-doc body                                       | name with backtick + U+0301 (the finding-1 hole) | all seven                                                        |
| `\%N`                                               | `a;touch PWNED;"`                                | ksh                                                              |

- **Fix:** do not interpolate. Export each value as an environment variable or positional parameter and substitute a
  reference (`"$AFM_1"`), run as `sh -c "$line" afm "$@"`. A wrong context then yields a literal, never execution. If
  interpolation stays, refuse placeholders inside `$(`, backticks, `$'` and after `\`.

#### 3. High / security — settings import is silent, unrestricted, and can plant things that run later

- **Where:** `ConfigurationCenter.swift:269-285`, `ConfigurationModels.swift:289-292` and `:296-305`,
  `ConfigurationPlugin.swift:129-132`, `Places/Hotlist.swift:229-233`.
- **What:**
  - `restore` writes every key in the file, not only known ones. `validate` checks only the shape of four keys.
  - There is no confirmation and no summary of what will run.
  - An archive can set user commands, Start-menu entries and key bindings (e.g. Return or F5 bound to `em_x` whose
    command is a shell line). These take effect immediately through `applyStoredSettings`.
  - It can set `places.hotlist` entries. `HotlistAction` runs any `cm_`/`afm_`/`em_` command with a text argument, so an
    entry titled "Documents" with command `afm_RunCommandLine curl … | sh` executes on click.
  - It can set `systemTools.terminal` to any app path (launched on "Open Terminal Here"), plus whatever other plugins
    store (saved connections, editor/viewer commands — not verified, out of scope).
  - `afm_ImportSettings <path>` accepts a `.location` argument, so a hotlist entry or user command can import a file
    with no panel and no question.
- **Fix:** whitelist keys; show a diff listing every command line, key binding, hotlist command and program path, and
  require confirmation; never import from an argument without confirmation; restrict hotlist commands or show the
  command before running one that came from an import; cap file size (`Data(contentsOf:)` is unbounded).

#### 4. Medium / correctness + security — `$SHELL -l -c` with POSIX-only quoting

- **Where:** `CommandRunner.swift:245-247` and `:273-277`; `SystemToolsPlugin.swift:139-144`.
- **What:**
  - tcsh and csh reject the flags: ``Unknown option: `-l'``, exit 1 (confirmed). For a user whose shell is csh/tcsh,
    every user command and every typed command line fails.
  - If `-l` were dropped, the quoting is unsafe there: `"a!b"` gives "Event not found", and names with a newline or
    backtick executed in the harness.
  - fish and nu were not tested; `"…\`…"`is not POSIX-equivalent in fish, and nu rejects`\$`.
- **Fix:** run user commands with a fixed `/bin/zsh` or `/bin/sh` (take PATH from the login shell once, off-main), or
  apply the finding-2 fix, which is shell-independent.

#### 5. Medium / freeze — O(n) work on the main thread for file lists

- **Where:** `VirtualFileSystem.swift:108-138` and `:441-463`; `VirtualFoldersPlugin.swift:91-95` and `:120`; called on
  main from `AFMShell/Window/PanelCoordinator.swift:178`.
- **What:**
  - `register` and `unique` compute `locationKey` and a `[UInt8]` copy per URL, and scan every scheme under the registry
    lock.
  - `watch` for a list resolves provider, parent and `locationKey` for every entry before taking the first 512.
  - `volume(of:)` runs `allSatisfy(\.isFileURL)` over all entries.
- **Trigger:** feed a 1M-result search to the list box, or "branch view of selected" with a huge selection: seconds of
  beach ball.
- **Fix:** register the raw array and de-duplicate inside `listing` (already off-main); in `watch`, stop after 512
  distinct parents or precompute them off-main.

#### 6. Medium / performance — tree scan and branch walk run at full priority, with no I/O throttling, into protected and cloud folders

- **Where:** `DirectoryTree.swift:419-441` and `:485-520`; `DirectoryTreeWindowController.swift:66`, `:272`, `:513-523`;
  `AFMKernel/Support/Parallel.swift:245`; `BranchWalker.swift:119-136`.
- **What:**
  - The scan uses all cores at `.userInitiated` and keeps doing so for up to 15 minutes after the window closes. There
    is no `setiopolicy_np` anywhere in the sources.
  - A scan of `/` enters Desktop, Documents, Downloads, iCloud Drive, `~/Library/CloudStorage`, Photos, Mail. That means
    a series of TCC prompts and materialisation of dataless File Provider directories, which can stall on the network.
    There is no `SF_DATALESS` check.
  - No `(device, inode)` set exists in `TreeScanner`. Cycles are prevented only because symlinks are skipped, which is
    sufficient.
- **Fix:** scan on `.utility` with `IOPOL_THROTTLE` and fewer workers when hidden; skip dataless directories and known
  TCC roots unless the user expands them.

#### 7. Medium / freeze — tree quick search and expand-all on main

- **Where:** `DirectoryTree.swift:291-304`; `DirectoryTreeWindowController.swift:384-400` and `:430-441`.
- **What:**
  - `find` visits up to `count` nodes per keystroke. The first pass also runs `lowercased()` for every node.
  - Wildcard patterns call `fnmatch` with two String-to-C conversions per node and have no failure memo. During a scan
    `revision` changes every link turn, so the memo never holds.
  - Option-Right or Option-click on a disclosure triangle falls through to `NSOutlineView` and expands everything. That
    loads every row and starts one `reading.async` reader per unscanned folder.
- **Fix:** search off-main over a snapshot, or time-slice with a generation check; intercept recursive expand; cap
  concurrent on-demand readers.

#### 8. Medium / correctness — the self-call guard misses mutual recursion across asynchronous steps

- **Where:** `CommandRunner.swift:111-114`, `:158-159`, `:165-178`, `:196-199`.
- **What:** `active` is popped when `perform` returns, which happens before a `cm_wait` or a waited program continues.
- **Trigger:** `em_a = "cm_wait 1, em_b"` and `em_b = "cm_wait 1, em_a"` loop forever with no way to stop. With an
  external step it spawns processes endlessly. An imported settings file can contain this.
- **Fix:** carry the call chain through the continuation instead of using a stack; add a depth limit and a way to stop.

#### 9. Medium / leak — each launched program pins a GCD thread; waiting chains cannot be cancelled

- **Where:** `CommandRunner.swift:239-269`.
- **What:**
  - A worker thread blocks on a semaphore for the lifetime of every started process (`.utility`, or `.userInitiated`
    when a chain waits).
  - A program that stays open in a chain (`em_edit, cm_RereadSource`) parks the chain indefinitely. The main thread is
    not blocked, but the thread, the continuation and the list file are held, with no indication and no cancel.
  - Dozens of long-lived children could starve the global queues the rest of the app uses.
- **Fix:** keep the `Process` in a table and continue from `terminationHandler`; show waiting chains somewhere
  cancellable.

#### 10. Medium / correctness — application detection

- **Quoted app path with a space:** `CommandRunner.swift:290` uses `line.drop { $0 != " " }`, which cuts inside the
  quotes. `"/Applications/My App.app" %N` becomes `open -a "/Applications/My App.app" App.app" …`, a syntax error.
- **PATH lookup uses the GUI process's PATH, not the login shell's:** `CommandRunner.swift:293`,
  `SystemTools/CommandLine.swift:86`. Typing `docker` or `emacs` with a same-named `.app` installed and the CLI in
  `/opt/homebrew/bin` opens the app.
- **`.app` in the current folder wins:** `CommandLine.swift:71-74`. Typing `Safari.app` in a downloaded folder that
  contains a `Safari.app` opens that one. Bare names never search "."; a file named `ls` does not shadow `/bin/ls`.

#### 11. Medium / security — secrets persisted and exported

- **Command history:** `CommandLine.swift:217-229`, `SystemToolsPlugin.swift:166`. Every typed line
  (`curl -u user:pass`, `mysql -p…`) is stored in `systemTools.history`. Export includes every stored key
  (`ConfigurationPlugin.swift:59-67`) and writes the file with default 0644 (`ConfigurationCenter.swift:264`).
- **Passwords in virtual folder URLs (encoding confirmed):** `VirtualLocation.swift:98-103`. The comment says "scheme,
  user, host and port", but a password is included: `ftp://user:s3cret@host` becomes hex in the `vfolder://` host and
  then lands in tabs, history and hotlist.
- **Same if a real URL carries a password:** `DirectoryHistory.swift:34` and `TreeCache.swift:188` store
  `absoluteString`. Whether Network URLs ever carry one was not verified.
- **Fix:** strip the password in `prefix(of:)` and before persisting; offer "do not record" for history; exclude history
  from export or warn; write the export 0600.

#### 12. Medium / freeze — jobs that ignore cancellation can block the command system

- **Where:** `SystemToolsPlugin.swift:313-321`, `:327`, `:356`; `SystemInformation.swift:119-130`.
- **What:** `resourceValues` on a dead network mount can hang. The job ignores its monitor, and `Kernel.swift:79` blocks
  commands while `isBusy` is true.
- **Trigger:** Rename Volume, Eject or System Information with a stale NFS/SMB mount. Plausible, not reproduced.
- **Fix:** run these outside the job queue with a timeout, and abandon on cancel.

#### 13. Medium / performance — branch view memory and re-walk storms

- **Where:** `BranchWalker.swift:101`, `:144`, `:153`; `VirtualFileSystem.swift:259`, `:454`, `:466-470`, `:488-519`.
- **What:**
  - `visited` collects every directory URL (hundreds of MB for a large branch), yet only the first 512 are kept.
  - Only those 512 directories are watched, so deeper changes go unseen.
  - Every change report triggers a full re-walk on all cores, at most every 0.5 s, for as long as changes continue. A
    branch of `~` or of a build folder would re-walk constantly unless the panel debounces (not verified).
  - With no cancellation flag, `receive` is only consulted when a batch has files, so a directory-only region cannot be
    stopped.
  - `Coalescer` can call `onChange` up to 0.5 s after the watcher was released.
  - 64 remembered lists have no entry cap.
- **Fix:** cap `visited` at `watchLimit`; for local branches use one recursive watch on the root; back off re-walks;
  check a weak token in `settle`.

#### 14. Medium / correctness — list files are line-based with no escaping

- **Where:** `ParameterExpansion.swift:514-516`.
- **What:** a file named `x\n/Users/me/important` contributes two lines to `%L`/`%F`. `xargs rm < %L` then removes
  another path. `%F` names beginning with `-` are not protected.
- **Fix:** refuse names with newlines (as `missingName` refuses), or offer a NUL-separated list code.

#### 15. Low-medium — TreeCache

- **Stale file after a race:** `TreeCache.swift:159-169` against `:101-107`. `flush` snapshots an entry, `store` then
  writes a newer one, and `flush` writes the old snapshot last. The file on disk is stale after restart.
- **Subtrees silently lost:** `:206-211`. `line.hasPrefix("[")` is Character-based, so a folder whose name starts with a
  combining mark never parses back.
- **Slow parse:** `line.count` (`:206`) and `text.contains` (`:213`) are grapheme-based over files of 100 MB scale; use
  `utf8`.
- **Unbounded memory:** `memory` is never evicted (`:55`). A million-folder tree is held as full path strings, plus a
  `Set`, plus the formatted text during write.
- **Wrong leaf state:** `:134-152`. Folders added by `noteFolder` load as "scanned" and show as leaves even if they have
  subfolders.
- **Threading is sound:** the lock is never held during disk I/O and the main thread takes it only in `flush()` at quit.
  A hostile cache file can only produce odd names (`..`), which lead to navigation, not a crash.

#### 16. Low-medium / correctness — real folders named like virtual ones are unreachable by typed path

- **Where:** `VirtualFileSystem.swift:408-424`, with `AFMKernel/FileSystem/FileSystemProvider.swift:467-472`.
- **What:** any text ending in a space and `(branch)`, `(list N)` or `(selected branch N)` is claimed first. A real
  folder `/x/Photos (branch)` typed, or stored in the hotlist as `cd /x/Photos (branch)`, opens the branch view of
  `/x/Photos`. The `(list N)` form also ignores the title.

#### 17. Low — tree attach, release and hand-over

- **Unbudgeted merge:** `DirectoryTree.swift:214-231`. The merge path ignores `limit`. It is taken for every ancestor of
  the selected folder, because those are pre-created, so a huge folder on that chain links in one turn.
- **Partial attach can interleave:** `:232-240`. A partial attach across turns can interleave with a
  `node(at:creating:)` insert and give duplicate or out-of-order children.
- **Main-thread free:** `DirectoryTreeWindowController.swift:244` and `:298`. Dropping a million-node tree frees it on
  main; hand it to a background queue.
- **Cancelled scan still writes:** `:283-284`. A cancelled non-rescan scan still stores its partial result after a newer
  scan began. Harmless ordering in practice.
- **Ownership is clean:** nodes are built off-main and touched only on main afterwards, and generation checks cover
  every hop.

#### 18. Low — smaller items

- **`.unreadable` backups:** `ConfigurationModels.swift:130-131`, `StoredSettings.swift:43-44`. Written only if none
  exists, never removed, and exported. A second corruption is not backed up, and the next save drops the unreadable
  entries.
- **Start-menu slots:** `ConfigurationCenter.swift:148-164`. `ensureSlots` registers one command per entry with no cap;
  an imported million-entry menu stalls main. `Hotlist.limit` is likewise enforced on insert only.
- **Empty values vanish:** `ParameterExpansion.swift:286`. An empty value produces no word (`%E` without extension,
  empty variable), shifting later arguments; emit `""`.
- **Double escaping:** `:415-429`. `"…%S…"` re-escapes the user's own text (`"$HOME/%S"` becomes `\$HOME`), and the tail
  scan ignores `\"`.
- **Large selections:** a very large selection in `%S` exceeds ARG_MAX; the error reads "cannot be started".
- **List cleanup timing:** `CommandRunner.swift:47-55`. Quit deletes list files that programs started in the last 60 s
  may still need. The start-time async delete can race the first list write.
- **Pid reuse:** only leaks a folder. The parent is the per-user temp directory, so no symlink or predictable-name
  issue.
- **Hotlist "add current dir":** `Hotlist.swift:236-241`. A folder with a trailing space, or one named `:`, is stored as
  `cd <path>` and trimmed or reinterpreted on use.
- **Last-read capabilities:** `VirtualFileSystem.swift:75`. `capabilities` without a location answers for the folder
  read last, which is wrong with two different virtual panels.
- **List eviction:** `:127`, `:473`. Lists shown without any watcher (unwatchable provider, empty list, background tab)
  can be evicted while shown.
- **List file size:** `VirtualFoldersPlugin.swift:188-193`. Read without a size cap; lines may name any provider, so
  opening a list file causes connections.
- **Print view:** `DirectoryList.swift:172`. `PagePrintView.init` counts graphemes of every line on main.
- **History bookkeeping:** `DirectoryHistory.swift:32`, `:42`. 200 URL parses on main per navigation.
- **Virtual URL decoding:** `VirtualLocation.swift:105-110`. Decoded prefixes may carry a path or query, and the path is
  not standardised (`…/a/../../etc` is accepted). Navigation only.

### Shared mutable state and its protection

| State                                                                         | Protection                                              | Sufficient?                                                  |
| ----------------------------------------------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------------ |
| `CommandRunner.active`, `launched`, `environment`                             | main thread only                                        | Yes for races; `active` is logically wrong (finding 8)       |
| List folder on disk                                                           | global concurrent queue plus main at quit               | Benign races (finding 18)                                    |
| `ConfigurationStore` caches, `ConfigurationCenter`, key-binding editors       | main only                                               | Yes                                                          |
| `ProcessRunner.Buffer`                                                        | `NSLock`                                                | Yes                                                          |
| `SystemTools.log`                                                             | main only                                               | Yes                                                          |
| `DirectoryTree` / `TreeNode`                                                  | unsynchronised; built on one thread, handed to main     | Yes                                                          |
| `TreeScanner.paths` / `unscanned`                                             | scan thread only, read after `run`                      | Yes                                                          |
| Tree window `waiting`, `generation`, `scanner`                                | main only                                               | Yes                                                          |
| `TreeCache.memory`, `writeIsScheduled`                                        | `NSLock`, no I/O under lock                             | Yes, except the stale-write race (finding 15)                |
| `DirectoryHistoryTracker`                                                     | main only, 1 s debounce on main, saved in `stop()`      | Yes                                                          |
| `VirtualFileSystem` lists, ids, watch counts, options, capabilities, `walked` | one `NSLock`, never held across a walk or provider call | Yes for safety; `register` holds it O(n) on main (finding 5) |
| `Coalescer`                                                                   | own `NSLock`, `fire` called outside it                  | Yes, apart from the late callback (finding 13)               |

### Checked and found sound

- **Cancelling a typed command:** the child leads its own process group. After `terminate`, no orphan remained for
  `a; b` or a pipeline in zsh, bash, sh and dash (confirmed in `pg/`).
- **Output handling:** the 8 MB cap keeps draining, the parent's write end is closed, and `lpr` gets absolute paths.
- **Open Terminal Here:** uses `NSWorkspace.open`, with no AppleScript and no shell string, so there is no injection
  through directory names.
- **Ordinary hostile names:** in the plain contexts `%N`, `"%N"`, `'%N'`, `%P%N`, `x%Ny` and `--out=%N`, every name
  without a combining mark arrived as exactly one correct argument in zsh, bash, sh, dash and ksh. That covers spaces,
  both quotes, `\`, `$`, backtick, `;&|<>`, glob characters, `~`, `!`, `#`, `=`, newline, CR, tab, U+2028 and a 250-byte
  name. The `./` prefix for `-` names works.
- **No-name refusal:** `missingName` refuses `%N`, `%O`, `%E`, `%V` and `%M` on `[..]`; `%P%S` with nothing selected
  expands to nothing rather than the bare folder.
- **Directory names cannot trigger a hotlist command:** stored entries always start with `cd` and a space.
- **Virtual folder URLs:** they round-trip for spaces, `%`, `#`, `?`, `;`, newline, combining marks, trailing space and
  very long hosts. Lists are refused for every mutating call. `move`, `copy`, `remove`, `trash`, `append`, `commit`,
  `setQuarantine` and `copyMetadata` map source and destination consistently.
- **Options window, key-binding rebase, command browser modal, hotlist editor:** no threading issues found.

### Not reviewed

- fish, nu and other non-POSIX shells (not installed).
- `CommandLanguage.expandingEnvironment` was not run; it shares the helpers from finding 1.
- How the panel reacts to `onChange` bursts, and how the shell builds destination URLs for items shown under
  display-path names in picked views.
- Whether Network URLs ever carry passwords.
- The form/list UI's handling of newlines and very long titles.
- `JobService` internals beyond the protocol comment.
- Nothing was run inside the app itself: no build, and no TCC or File Provider behaviour observed live.
