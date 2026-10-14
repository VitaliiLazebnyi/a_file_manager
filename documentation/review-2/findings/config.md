# Review 2 — config

Every item the reviewers, verifiers, stress runs and fuzzers reported for this area. `verdict` items are independent
rulings on a finding and sit next to it by file. Status is filled in by the fix round.

## Findings and verdicts

### C001 [finding, critical] B4c: Open With calls urlsForApplications(toOpen:) and urlForApplication(toOpen:) on main

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Plugins/MacIntegration/MacIntegrationPlugin.swift:62-70;
  Plugins/MacIntegration/MacIntegrationPlugin.swift:150-152
- **Basis:** inferred (plausible)
- **Detail:** Plausible; SystemTools already does this lookup in a job.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### C002 [finding, critical] A file name can run commands through the default %N in every shell (grapheme-cluster escaping hole)

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/ParameterExpansion.swift:63-70;
  Sources/Plugins/Configuration/ParameterExpansion.swift:284;
  Sources/Plugins/Configuration/CommandLanguage.swift:105-107
- **Basis:** reproduced
- **Detail:** ShellWords.escaped walks Characters (grapheme clusters). A ", backtick or \ followed by a combining mark
  or variation selector is one Character not equal to the bare ASCII char so it is not escaped. needsQuoting works on
  scalars so the value is still wrapped in "...", and the shell sees a raw quote or backtick. The single-quote branch
  has the same hole: replacingOccurrences(of: "'") does not match ' + U+0301 (harness printed an unescaped result).
  Trigger: file named backtick+U+0301 ;touch PWNED; backtick+U+0301 (or the double-quote variant) under the cursor, with
  any user command, button or Start-menu entry using %N, %S, %P%N, x%Ny, --out=%N, "%N", "pre %N post" or %|VAR|. touch
  PWNED ran in zsh, bash, sh, dash, ksh (and tcsh/csh without -l). The '%N' form fell to the name. Lesser effect: $ +
  U+0301 not escaped either; bash and ksh passed a mangled name (wrong file, no execution).
- **Proposed fix:** Escape per Unicode scalar or UTF-8 byte, never per Character. Better, stop pasting values into shell
  text (see finding 2).
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C003 [finding, high] LaunchServices and sharing lookups (installedApplications, NSSharingServicePicker, activateFileViewerSelecting) run on main and may hang on a stalled mount

**Outcome:** fixed — see `status/config-a.md`

- **Where:** MacIntegration/MacIntegrationPlugin.swift:150-152; MacIntegration/MacIntegrationPlugin.swift:62-70;
  MacIntegration/MacIntegrationPlugin.swift:177-183; MacIntegration/MacIntegrationPlugin.swift:160-163;
  SystemTools/SystemToolsPlugin.swift:529
- **Basis:** read (call path confirmed; blocking plausible)
- **Detail:** Blocking call. installedApplications (:62-70) calls urlsForApplications(toOpen:) and
  urlForApplication(toOpen:) on main; both must type the file, so they touch it; on a stalled mount this hangs.
  SystemTools.openWith (SystemToolsPlugin.swift:529) already does the same lookup in a job. Same file :177-183:
  NSSharingServicePicker(items: 300k URLs).show on main, unbounded with item count and touching each file. :160-163:
  activateFileViewerSelecting(300k URLs).
- **Proposed fix:** Cap or summarise the item list for Share and Reveal, and resolve off main; reuse the openWith job
  pattern.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C004 [finding, high] Tree scan issues one outline.reloadItem per scanned folder, stalling the window (up to 2000 reloads = 1.6-1.8 s per turn)

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Places/DirectoryTreeWindowController.swift:343-357; Places/DirectoryTreeWindowController.swift:274
- **Basis:** measured (replica; plausible in app)
- **Detail:** Scaling/flooding. Path: scanner batch -> DispatchQueue.main.async (:274) -> linkWaiting() ->
  outline.reloadItem(node, reloadChildren: true) for every finished level whose node has a row. linkBudget (2000) counts
  linked nodes, with a minimum of 1 per level, so one turn can make up to 2000 reloadItem calls. Measured: 2000 x
  reloadItem(child, reloadChildren: true) = 1.6-1.8 s, independent of row count (headless NSOutlineView). Trigger: first
  scan or F2 rescan while an expanded folder shows thousands of subfolders, e.g. reveal expanded a node_modules. With 1M
  visible subfolders this is about 500 consecutive 1.6 s turns.
- **Proposed fix:** Budget the reloads (<=8 per turn or a time budget), skip the reload when a level adds no children to
  a collapsed row, or coalesce into one reloadItem(parent) per turn.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C005 [finding, high] P1: directory-tree scan issues up to 2000 outline.reloadItem(reloadChildren:) calls in one main-queue turn (1.6-1.8 s)

**Outcome:** duplicate of C004 — see `status/config-b.md`

- **Where:** Plugins/Places/DirectoryTreeWindowController.swift:343-357
- **Basis:** measured
- **Detail:** Scaling and flooding; measured on a headless replica.
- **Proposed fix:** Budget the reloads per turn, or coalesce to one per parent.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### C006 [finding, high] S10: virtual lists do O(n) URL work on main (registering 2M results 2-4 s; watch() on every navigation 3-5 s)

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Plugins/VirtualFolders/VirtualFileSystem.swift:122-138;
  Plugins/VirtualFolders/VirtualFileSystem.swift:456-459
- **Basis:** inferred (from measured per-key cost)
- **Detail:** Estimated from a measured 0.64 us per locationKey.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### C007 [finding, high] VirtualFileSystem.watch() does parent(of:) + locationKey for every list entry on main on every location change (est. 3-5 s per navigation with a 2M list)

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Plugins/VirtualFolders/VirtualFileSystem.swift:456-459
- **Basis:** read (confirmed; estimated)
- **Detail:** Done on main on every location change of either panel while a list is shown (the coordinator rebuilds all
  watchers). Estimate 3-5 s per navigation with a 2M list.
- **Proposed fix:** Store the unique parent folders (capped at watchLimit) with the list at registration, so watch() is
  O(512).
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### C008 [finding, high] VirtualFileSystem.Coalescer calls onChange on a global queue, violating the main-thread contract (panel reload off main)

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Plugins/VirtualFolders/VirtualFileSystem.swift:497-507;
  Plugins/VirtualFolders/VirtualFileSystem.swift:510-518; Plugins/VirtualFolders/VirtualFileSystem.swift:466;
  AFMShell/Window/PanelCoordinator.swift:178; AFMShell/Window/PanelCoordinator.swift:136;
  AFMShell/Panel/PanelViewController.swift:810; AFMKernel/FileSystem/FileSystemProvider.swift:308
- **Basis:** read (confirmed, both paths)
- **Detail:** Coalescer.signal fires the first report on the caller (main), then schedules settle() on
  DispatchQueue.global(qos: .userInitiated); settle calls fire() = onChange([virtual]) =
  PanelCoordinator.reloadChangedPanels -> PanelViewController.reload (MainThread.assert). Trigger: two changes within
  0.5 s in any watched branch view or file list. Debug builds assert; release builds race on panel and AppKit state. The
  provider contract says onChange is called on main. A pending settle also fires after the watcher was released.
- **Proposed fix:** Schedule settle on DispatchQueue.main, and give Coalescer a cancelled flag set from Watchers.deinit.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### C009 [finding, high] S10b: Coalescer.settle() calls onChange on a global queue, so PanelCoordinator.reloadChangedPanels runs off main (correctness bug)

**Outcome:** duplicate of C008 — see `status/config-b.md`

- **Where:** Plugins/VirtualFolders/VirtualFileSystem.swift:510-518
- **Basis:** read
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### C010 [finding, high] Leaving a picked branch maps lastPathComponent over the whole list on main (about 0.3 s at 300k)

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Plugins/VirtualFolders/VirtualFoldersPlugin.swift:143
- **Basis:** read (estimated)
- **Detail:** Scaling.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### C011 [finding, high] Mask selection and selection loading run on main (Select/Unselect Group 1.1 s, same-folder select 1.0 s, clipboard load ~1.7 s for 100 MB, file load est. 0.9 s)

**Outcome:** fixed — see `status/plugins-a-p2.md`

- **Where:** Selection/SelectionPlugin.swift:258; Selection/SelectionType.swift:123-141;
  Selection/SelectionMask.swift:101-109; Selection/SelectionPlugin.swift:370; Selection/SelectionPlugin.swift:469-478
- **Basis:** measured (file-load estimated)
- **Detail:** Reported severity high to medium; scaling. Select/Unselect Group by mask: 1.1 s for *.txt (a [Character]
  array per name), 0.34 s for a regex, plus 67 ms row index and 113 ms setSelected. 'Select all in same folder' (:370):
  1.0 s (URL work per row). Load Selection from Clipboard (:469-478): pasteboard.string on main, then
  Set(items.map(name)) 329 ms, then listed at 173 ms per 10 MB, about 1.7 s for 100 MB; lazily provided clipboard data
  can also block on the owning app. Load Selection from File: the job's completion parses up to 32 MB on main, est. 0.9
  s.
- **Proposed fix:** Do matching and parsing on a background queue from a listedItems snapshot and apply with one
  setSelection; use FileMask's byte matcher for plain masks.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C012 [finding, high] Compare Directories and Mark Newer run entirely on main (1.7-1.9 s compare at 1M x 1M, est. 2.5-3 s Mark Newer) and call resourceValues on main

**Outcome:** fixed — see `status/plugins-a-p2.md`

- **Where:** Selection/SelectionPlugin.swift:484-514; Selection/SelectionFile.swift:91-165;
  Selection/SelectionPlugin.swift:493-496
- **Basis:** measured
- **Detail:** Scaling. Measured: DirectoryComparison.compare at 1M x 1M = 1.7-1.9 s. Mark Newer adds two synchronous
  setFilter passes whose closure allocates Array($0.name.utf8) per row (est. 2.5-3 s in total). foldsCase (:493-496)
  calls URL.resourceValues(.volumeSupportsCaseSensitiveNamesKey) on main for both panel folders: a blocking call; on a
  stalled mount it is an unbounded hang, and Shift+F2 reaches it in ordinary use, so it rates critical under that
  condition.
- **Proposed fix:** Run compare and foldsCase in a job (listVersion-guarded), apply with
  setFilter(_:prefiltered:listVersion:), and use ExactName instead of [UInt8] keys.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C013 [finding, high] Settings import is silent, unrestricted, and can plant commands, key bindings and hotlist entries that run later

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/ConfigurationCenter.swift:269-285;
  Sources/Plugins/Configuration/ConfigurationModels.swift:289-292;
  Sources/Plugins/Configuration/ConfigurationModels.swift:296-305;
  Sources/Plugins/Configuration/ConfigurationPlugin.swift:129-132; Sources/Plugins/Places/Hotlist.swift:229-233
- **Basis:** read
- **Detail:** restore writes every key in the file, not only known ones; validate checks only the shape of four keys. No
  confirmation and no summary of what will run. An archive can set user commands, Start-menu entries and key bindings
  (e.g. Return or F5 bound to em_x whose command is a shell line), effective immediately via applyStoredSettings. It can
  set places.hotlist entries; HotlistAction runs any cm_/afm_/em_ command with a text argument, so an entry titled
  "Documents" with command afm_RunCommandLine curl ... | sh executes on click. It can set systemTools.terminal to any
  app path (launched on Open Terminal Here), plus whatever other plugins store (saved connections, editor/viewer
  commands: not verified, out of scope). afm_ImportSettings `<path>` accepts a .location argument so a hotlist entry or
  user command can import a file with no panel and no question.
- **Proposed fix:** Whitelist keys; show a diff listing every command line, key binding, hotlist command and program
  path and require confirmation; never import from an argument without confirmation; restrict hotlist commands or show
  the command before running one from an import; cap file size (Data(contentsOf:) is unbounded).
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C014 [verdict, high] Config import: user commands plus key bindings execute code on next keypress; trustedCertificates pre-seeded (sub-ruling of claim 6)

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/ConfigurationModels.swift:292-295
- **Basis:** CONFIRMED (read)
- **Detail:** High for the import itself.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### C015 [verdict, high] Configuration import writes every key and has no confirmation

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/ConfigurationModels.swift:292-295;
  Sources/Plugins/Configuration/ConfigurationCenter.swift:269-285; Sources/Plugins/Network/RemoteFileSystem.swift:59-65
- **Basis:** CONFIRMED (read)
- **Detail:** restore writes every key in the file, not only known ones; validate checks shape only; no summary or
  confirmation. Password lookup by UUID alone. Precondition: user imports hostile file; password redirect also needs
  victim's connection UUID (in their own export). High for the import: user commands plus key bindings mean code runs on
  next keypress, and network.trustedCertificates can be pre-seeded. Low-medium for the redirect.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### C016 [finding, high] Unicode trailing spaces trimmed from an expanded name

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/ParameterExpansion.swift:139
- **Basis:** reproduced
- **Detail:** A name ending in U+00A0 or U+3000 arrives without it so it may name a different file. Reproducers
  repro/misc/quote-trailing-nbsp-trimmed.bin and quote-trailing-ideographic-space-trimmed.bin.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### C017 [verdict, high] File names run as shell code through quote-state tracking with particular templates (ASCII names)

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/ParameterExpansion.swift:232-244
- **Basis:** CONFIRMED (ran)
- **Detail:** Plain ASCII names execute with particular templates: "$(cmd %N)" with name 'g x;touch M7' or 'e";touch
  M5;"' (value escaped for double quotes but in a fresh $(...) context); `cmd %N` with 'f$(touch M6)' (backticks strip
  the \ from \$); $'%N' with 'h\';touch M8;'' (backslash live inside $'...'); '%N # don't' + newline + '%N' with 'g
  x;touch M7' (apostrophe in a comment flips quote state; needs multi-line field). Here-docs are the same class but not
  run.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### C018 [finding, high] Quote tracking does not understand command substitution, backticks, $'...', comments, here-docs or \%N, allowing injection with ordinary names

**Outcome:** duplicate of C017 — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/ParameterExpansion.swift:232-244;
  Sources/Plugins/Configuration/ParameterExpansion.swift:282-287
- **Basis:** reproduced
- **Detail:** The tracker only toggles on " and '. Confirmed injections (touch PWNED ran): template "$(printf %s %N)"
  name a;touch PWNED; in zsh, bash, sh, dash, ksh; "$(printf %s "%N")" (the correct way to write it) same five, line
  becomes ""a;touch PWNED;""; backtick printf %s %N with name $(touch PWNED) in bash, sh, dash, ksh (backtick layer
  strips the backslash; not zsh); $'%N' with name \';touch PWNED;# in zsh, bash, ksh (4 of 7 shells); "# %N" with a
  newline name in bash, sh, dash, ksh (not zsh); here-doc body with backtick+U+0301 name (finding-1 hole) in all seven;
  \%N with name a;touch PWNED;" in ksh.
- **Proposed fix:** Do not interpolate. Export each value as an environment variable or positional parameter and
  substitute a reference ("$AFM_1"), run as sh -c "$line" afm "$@". If interpolation stays, refuse placeholders inside
  $(, backticks, $' and after backslash.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C019 [finding, high] ParameterExpansion substring: %N:~6,9223372036854775807 overflows from + length

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/ParameterExpansion.swift:364
- **Basis:** reproduced
- **Detail:** C2. from = 6, length = Int.max. Reach: parameters of a user command or Start-menu entry (also via an
  imported settings file), when the command is run. Reproducer pexpand-substring-length-overflow.bin, target pexpand.
- **Proposed fix:** length >= all.count - from ? all.count : from + length
- **Source:** reports/22-fuzz-target-group-5-misc.md
- **Status:** open

### C020 [finding, high] Crash in parameter expansion: from + length overflows

**Outcome:** duplicate of C019 — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/ParameterExpansion.swift:364
- **Basis:** reproduced
- **Detail:** from + length overflows for %N:~6,9223372036854775807. Reproducer
  repro/misc/pexpand-substring-length-overflow.bin (target pexpand).
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### C021 [finding, high] Shell-quoting command injection through combining-mark characters

**Outcome:** duplicate of C002 — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/ParameterExpansion.swift:63-70
- **Basis:** reproduced
- **Detail:** ShellWords.escaped compares whole Characters so a ", \, $ or backtick carrying a combining mark is not
  escaped; a file name of that shape ran an injected command in zsh. Contexts: bare parameters, inside double quotes,
  %|VAR| and %VAR%; single quotes held. Reproducer repro/misc/quote-injection-combining-mark.bin (fuzz-misc, target
  quote-demo). 150,800 expansion checks ran through real /bin/zsh -c and /bin/sh -c.
- **Proposed fix:** Escape per scalar or byte, or always emit single-quoted words.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### C022 [finding, high] ShellWords.escaped compares whole Characters, so a quote, backslash, dollar or backtick carrying a combining mark is not escaped: command injection

**Outcome:** duplicate of C002 — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/ParameterExpansion.swift:63-70;
  Sources/Plugins/Configuration/CommandLanguage.swift:106-107
- **Basis:** reproduced
- **Detail:** Q1 (security). Contexts affected: bare %N / %P%N / %S / %T%N, inside the user's double quotes, %|VAR|, and
  the Command field's %VAR%. Single-quote context held in every case. Minimal counterexample: name a"<U+0301>;touch
  PWNED;"<U+0301> with parameters %N expands to "a"́;touch PWNED;"́" and zsh runs touch PWNED (file created). Results
  identical in zsh and sh. Reproducer quote-injection-combining-mark.bin, target quote-demo. Same cause, by reading
  only: name.hasPrefix("-") at line 263 misses - plus a combining mark, so such a name gets no ./ prefix.
- **Proposed fix:** Escape per unicode scalar or byte, or always emit single-quoted words with ' -> '\''.
- **Source:** reports/22-fuzz-target-group-5-misc.md
- **Status:** open

### C023 [verdict, high] File names run as shell code through ShellWords.escaped (grapheme bug)

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/ParameterExpansion.swift:63-70;
  Sources/Plugins/Configuration/ParameterExpansion.swift:284;
  Sources/Plugins/Configuration/ParameterExpansion.swift:428; Sources/Plugins/Configuration/CommandRunner.swift:192;
  Sources/Plugins/Configuration/CommandRunner.swift:247; Sources/Plugins/Configuration/CommandLanguage.swift:105-107
- **Basis:** CONFIRMED (ran)
- **Detail:** Real ParameterExpansion.swift compiled with a stub FileItem.split, expanded lines passed to /bin/zsh -c
  and /bin/bash -c; marker files created by touch text from the file name. ShellWords.escaped compares whole Swift
  Characters so ", `, \ or $ followed by a combining mark is not escaped; needsQuoting works on scalars so value is
  still wrapped in "..." which the name closes. Line 284 single-quote path has the same flaw (replacingOccurrences of '
  does not match ' + U+0301). Line goes unchanged to $SHELL -l -c. Name a"́;touch M1;"́ created on APFS and listed back
  byte for byte. Affected with any template even plain 'cmd %N': %N %n %v %V %M %m %O %o %E %e %P %p %T %t %S %s %R %r
  %B %C1-9; same codes inside user's own "..." or '...'; in-quote %S path (428); %|VAR| and %VAR% in Command field (not
  attacker-controlled in practice); %P/%T when a folder name carries the payload. Not affected: %L %F %D %UL %UF %WL %WF
  (list file), cd or internal cm_ steps; %Q switches quoting off by design. Precondition: crafted file/folder name in a
  visited folder (extracted archive, download, share, FTP listing) and user running any user command, button or
  Start-menu entry with one of those codes with cursor/selection on it. Arbitrary code as the user.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### C024 [finding, high] DirectoryHistory frequent-folder counts[..., default: 0] += 1 traps when a stored count is Int.max (imported settings)

**Outcome:** fixed — see `status/plugins-a-p2.md`

- **Where:** Sources/Plugins/Places/DirectoryHistory.swift:98
- **Basis:** reproduced
- **Detail:** C3. A stored count of Int.max, e.g. `"places.history.frequent":{"counts":{"<url>":9223372036854775807}}`.
  After importing such a settings file the app traps every time that folder is visited (at every start if it is the
  start folder). Reproducers settings-import-frequent-count-overflow.json (target settings, real import path) and
  frequentfolders-count-overflow.bin (target lenient).
- **Proposed fix:** Clamp counts on decode, or use a saturating add.
- **Source:** reports/22-fuzz-target-group-5-misc.md
- **Status:** open

### C025 [finding, high] Crash after settings import: frequent-count += 1 on Int.max

**Outcome:** duplicate of C024 — see `status/plugins-a-p2.md`

- **Where:** Sources/Plugins/Places/DirectoryHistory.swift:98
- **Basis:** reproduced
- **Detail:** += 1 on a stored count of Int.max traps every time that folder is visited. Reproducer
  repro/misc/settings-import-frequent-count-overflow.json (target settings).
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### C026 [finding, high] printFile enablement builds the full operand list (224 ms per evaluation), saturating main if the command is on the button bar

**Outcome:** fixed — see `status/config-a.md`

- **Where:** SystemTools/SystemToolsPlugin.swift:54,70
- **Basis:** measured
- **Detail:** Reported high if on the button bar, medium otherwise; scaling. Path: File menu open or Ctrl+F9 lookup ->
  isEnabled -> model().operands().filter{}. Measured 224 ms per evaluation. The button bar is user-configurable
  (ToolbarEditor); with this command on it, the 100 ms tick costs 224 ms each time, so the main thread stays saturated
  whenever validation is scheduled.
- **Proposed fix:** isLocal() && model().hasOperandFile
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C027 [finding, medium] CommandRunner.snapshot filters both panels on every button, user-command or Start-menu run even with no %S/%L code (195 ms per panel)

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Configuration/CommandRunner.swift:74-90
- **Basis:** measured
- **Detail:** Scaling, measured: 195 ms per panel.
- **Proposed fix:** Build the selection lazily.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C028 [finding, medium] Tree quick search and expand-all run on the main thread

**Outcome:** fixed — see `status/plugins-a-p2.md`

- **Where:** DirectoryTree.swift:291-304; DirectoryTreeWindowController.swift:384-400;
  DirectoryTreeWindowController.swift:430-441
- **Basis:** read
- **Detail:** find visits up to count nodes per keystroke; the first pass also runs lowercased() for every node.
  Wildcard patterns call fnmatch with two String-to-C conversions per node and no failure memo; during a scan revision
  changes every link turn so the memo never holds. Option-Right or Option-click on a disclosure triangle falls through
  to NSOutlineView and expands everything, loading every row and starting one reading.async reader per unscanned folder.
  Category: freeze.
- **Proposed fix:** Search off-main over a snapshot, or time-slice with a generation check; intercept recursive expand;
  cap concurrent on-demand readers.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C029 [finding, medium] A loaded tab file has no tab-count limit; 81,512 tabs from 1 MiB make restore O(n^2) on main and hang the app

**Outcome:** fixed — see `status/config-b.md`

- **Where:** FolderTabs/FolderTabsPlugin.swift:412-426,259-285
- **Basis:** measured (parse count confirmed; O(n^2) UI cost read, not timed)
- **Detail:** Category: freeze. A 1 MiB file parses to 81,512 tabs (measured, 0.09 s), and restore then calls insertTab
  once per tab on main, each firing onChange -> tabsChanged, which does work proportional to the tab count. Trigger: the
  user loads a crafted or corrupt .tab file. O(n^2) on main, and replace adds a firstIndex plus closeTab per old tab.
- **Proposed fix:** Cap tabs per side (a few hundred) and caption length. Add a batch insert to PanelTabs that fires
  onChange once.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### C030 [finding, medium] Copy as Pathname takes about 0.5 s on main (396 ms operands + join + pasteboard)

**Outcome:** fixed — see `status/config-a.md`

- **Where:** MacIntegration/MacIntegrationPlugin.swift
- **Basis:** measured (partly estimated)
- **Detail:** Scaling; partly estimated.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C031 [finding, medium] remember("quicklook|share|tags " + 300k paths) builds huge log lines (86 ms each; the log keeps up to 512 lines of roughly 30 MB, a low-memory hazard)

**Outcome:** fixed — see `status/config-a.md`

- **Where:** MacIntegration/MacIntegrationPlugin.swift:168,179,271
- **Basis:** measured (log size estimated)
- **Detail:** Scaling. 86 ms each measured; the up-to-512-line, ~30 MB-per-line figure is estimated.
- **Proposed fix:** Log a count.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C032 [finding, medium] Open Quick Look panel rebuilds the operand URL list on every panel event (396 ms per event)

**Outcome:** fixed — see `status/config-a.md`

- **Where:** MacIntegration/MacIntegrationPlugin.swift:172-175; MacIntegration/MacIntegrationPlugin.swift:108
- **Basis:** measured
- **Detail:** Scaling per event. localOperands() measured 396 ms per event, plus up to 25 ms for the array compare.
  Trigger: Quick Look open and many items marked; each arrow-key repeat costs about 0.4 s.
- **Proposed fix:** Follow only the cursor item when it changed, recompute marks only on .selectionChanged, debounce,
  and cap the list.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C033 [finding, medium] Tags completion Set(urls.map{deletingLastPathComponent}) costs 242 ms on main

**Outcome:** fixed — see `status/config-a.md`

- **Where:** MacIntegration/MacIntegrationPlugin.swift:272
- **Basis:** measured
- **Detail:** Scaling, measured.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C034 [finding, medium] Tree quick search walks the whole tree per keystroke (125-175 ms prefix, 570 ms wildcard at 2.4M nodes)

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Places/DirectoryTree.swift:291-304
- **Basis:** measured (replica)
- **Detail:** Scaling, measured in replica. Called from controlTextDidChange and handleKey. Scales linearly (10M nodes
  about 0.5-2.4 s). The failed-search memo is defeated during a scan because revision keeps changing.
- **Proposed fix:** Search off main with cancellation, or in time slices.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C035 [finding, medium] Settings import silently installs execution configuration (commands, editor/terminal path, trusted certificates, connection UUID reuse, remote tabs)

**Outcome:** duplicate of C013 — see `status/config-a.md`

- **Where:** Plugins/Configuration/ConfigurationCenter.swift:272;
  Plugins/Configuration/ConfigurationModels.swift:318-327; Plugins/Configuration/ConfigurationModels.swift:289-292;
  Plugins/Configuration/ConfigurationCenter.swift:301-311; Plugins/Configuration/CommandRunner.swift:247;
  Plugins/MacIntegration/MacIntegrationPlugin.swift:77-79; Plugins/SystemTools/SystemToolsPlugin.swift:253-255;
  Plugins/Network/SavedConnections.swift:240; Plugins/Network/RemoteFileSystem.swift:65
- **Basis:** read (confirmed)
- **Detail:** Data(contentsOf:) with no cap; any key accepted; written to UserDefaults; applied immediately; only 'The
  settings were imported' shown. An imported file can set: user commands, Start-menu entries and key bindings that run
  shell lines (`<login shell> -l -c`), e.g. Enter rebound to an em_ command; the F4 editor path and the terminal
  application path; network.trustedCertificates which pre-accepts an attacker certificate for a host;
  network.connections entries reusing an existing connection UUID with another host (Keychain password looked up by UUID
  only and would be sent there); left.tabs/right.tabs with remote URLs opened at next launch.
- **Proposed fix:** Before applying, summarise what the file contains that executes or connects and ask; whitelist keys;
  never import trusted certificates; bind the Keychain item to host, port and user as well as the id; cap the file size.
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### C036 [finding, medium] S6: with Quick Look open, every panel event rebuilds the operand URL list, about 0.3-0.4 s per cursor move with 300k marked

**Outcome:** duplicate of C032 — see `status/config-a.md`

- **Where:** Plugins/MacIntegration/MacIntegrationPlugin.swift:108;
  Plugins/MacIntegration/MacIntegrationPlugin.swift:172-175
- **Basis:** measured
- **Detail:** 396 ms measured by the fork, 256 ms for operands() alone in the auditor's run.
- **Proposed fix:** Follow the cursor item; recompute marks only on .selectionChanged.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### C037 [finding, medium] P6: tree quick search walks every node per key: 125-570 ms at 2.4M nodes

**Outcome:** duplicate of C034 — see `status/config-b.md`

- **Where:** Plugins/Places/DirectoryTree.swift:291-304
- **Basis:** measured
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### C038 [finding, medium] Cancellation not wired through in SystemTools/MultiRename/BranchWalker: unflagged list used

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Plugins/SystemTools/DirectoryList.swift:68; Plugins/MultiRename/RenameRun.swift:210;
  Plugins/MultiRename/RenameRun.swift:265
- **Basis:** read
- **Detail:** BranchWalker when called without a flag also uses the unflagged list.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### C039 [finding, medium] VirtualFileSystem watcher callback (Coalescer.settle) fires onChange from a global queue, so panel.reload runs on a background thread

**Outcome:** duplicate of C008 — see `status/config-b.md`

- **Where:** Plugins/VirtualFolders/VirtualFileSystem.swift:510-518
- **Basis:** read (reported as confirmed)
- **Detail:** F4b, thread-safety. settle calls fire() from a global queue, so onChange reaches
  PanelCoordinator.reloadChangedPanels and then panel.reload on a background thread. The protocol promises main.
- **Proposed fix:** Hop to main in settle.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### C040 [finding, medium] Tree scan and branch walk run at full priority with no I/O throttling into protected and cloud folders

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Sources/Plugins/Configuration/../Navigation/DirectoryTree.swift:419-441; DirectoryTree.swift:485-520;
  DirectoryTreeWindowController.swift:66, 272, 513-523; Sources/AFMKernel/Support/Parallel.swift:245;
  BranchWalker.swift:119-136
- **Basis:** read
- **Detail:** Scan uses all cores at .userInitiated and keeps doing so up to 15 minutes after the window closes. No
  setiopolicy_np anywhere in the sources. A scan of / enters Desktop, Documents, Downloads, iCloud Drive,
  ~/Library/CloudStorage, Photos, Mail: a series of TCC prompts and materialisation of dataless File Provider
  directories, which can stall on the network. No SF_DATALESS check. No (device, inode) set in TreeScanner; cycles are
  prevented only because symlinks are skipped, which is sufficient. Category: performance.
- **Proposed fix:** Scan on .utility with IOPOL_THROTTLE and fewer workers when hidden; skip dataless directories and
  known TCC roots unless the user expands them.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C041 [finding, medium] The self-call guard misses mutual recursion across asynchronous steps (cm_wait loops forever)

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/CommandRunner.swift:111-114, 158-159, 165-178, 196-199
- **Basis:** read
- **Detail:** active is popped when perform returns, which happens before a cm_wait or a waited program continues.
  Trigger: em_a = "cm_wait 1, em_b" and em_b = "cm_wait 1, em_a" loop forever with no way to stop; with an external step
  it spawns processes endlessly. An imported settings file can contain this.
- **Proposed fix:** Carry the call chain through the continuation instead of a stack; add a depth limit and a way to
  stop.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C042 [verdict, medium] Mutually calling user commands loop forever when a wait is in between

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/CommandRunner.swift:158-159;
  Sources/Plugins/Configuration/CommandRunner.swift:163-167; Sources/Plugins/Configuration/CommandRunner.swift:194-199
- **Basis:** CONFIRMED (ran)
- **Detail:** em_c = 'em_sayC,cm_wait 20,em_d' and mirror ran 42 lines after 1 s and 83 after 2 s. Guard's active list
  is popped whenever perform returns for a cm_wait or waited program. Endless loop, not stack recursion. Not run: same
  through a waited external program with real launches.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### C043 [verdict, medium] $SHELL -l -c fails silently under csh/tcsh

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/CommandRunner.swift:192;
  Sources/Plugins/SystemTools/SystemToolsPlugin.swift:143
- **Basis:** CONFIRMED (ran)
- **Detail:** /bin/tcsh -l -c 'echo hi' and /bin/csh both print 'Unknown option: -l' and exit 1. In CommandRunner.launch
  output goes to the null device and exit status is never read, so the command silently does nothing.
  SystemToolsPlugin.swift:143 has the same flags. Functional bug, not security.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### C044 [finding, medium] Each launched program pins a GCD thread; waiting chains cannot be cancelled

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/CommandRunner.swift:239-269
- **Basis:** read
- **Detail:** A worker thread blocks on a semaphore for the lifetime of every started process (.utility, or
  .userInitiated when a chain waits). A program that stays open in a chain (em_edit, cm_RereadSource) parks the chain
  indefinitely; main is not blocked but the thread, continuation and list file are held with no indication and no
  cancel. Dozens of long-lived children could starve the global queues the rest of the app uses. Category: leak.
- **Proposed fix:** Keep the Process in a table and continue from terminationHandler; show waiting chains somewhere
  cancellable.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C045 [finding, medium] $SHELL -l -c with POSIX-only quoting: csh/tcsh reject the flags and quoting is unsafe in other shells

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/CommandRunner.swift:245-247;
  Sources/Plugins/Configuration/CommandRunner.swift:273-277; Sources/Plugins/SystemTools/SystemToolsPlugin.swift:139-144
- **Basis:** reproduced
- **Detail:** tcsh and csh reject the flags ("Unknown option: -l", exit 1, confirmed): for a user whose shell is
  csh/tcsh every user command and every typed command line fails. If -l were dropped quoting is unsafe there: "a!b"
  gives "Event not found", and names with newline or backtick executed in the harness. fish and nu not tested;
  "...backtick..." is not POSIX-equivalent in fish and nu rejects \$. Category: correctness + security.
- **Proposed fix:** Run user commands with a fixed /bin/zsh or /bin/sh (take PATH from the login shell once, off-main),
  or apply the finding-2 fix, which is shell-independent.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C046 [verdict, medium] One GCD thread parked per launched program

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/CommandRunner.swift:261-267
- **Basis:** CONFIRMED (read)
- **Detail:** Both branches sit in ended.wait() until the login shell exits. Lines turned into open -a return at once; a
  program run directly holds a thread for its lifetime. These threads count toward the 80-thread limit measured under
  claim 10.
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

### C047 [finding, medium] Application detection: a quoted app path with a space is cut inside the quotes

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/CommandRunner.swift:290
- **Basis:** read
- **Detail:** line.drop { $0 != " " } cuts inside the quotes. "/Applications/My App.app" %N becomes open -a
  "/Applications/My App.app" App.app" ..., a syntax error.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C048 [finding, medium] Application detection uses the GUI process PATH, not the login shell PATH, so typing docker or emacs opens a same-named .app

**Outcome:** not a defect — see `status/shell-p2.md`

- **Where:** Sources/Plugins/Configuration/CommandRunner.swift:293; Sources/Plugins/SystemTools/CommandLine.swift:86
- **Basis:** read
- **Detail:** Typing docker or emacs with a same-named .app installed and the CLI in /opt/homebrew/bin opens the app.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C049 [finding, medium] ParameterExpansion trims .whitespaces from the finished text, dropping unquoted Unicode spaces (NBSP, U+3000) from file names

**Outcome:** duplicate of C016 — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/ParameterExpansion.swift:139
- **Basis:** reproduced
- **Detail:** Q2. Name a<U+00A0> (also report<U+3000>) with %N yields argument a, potentially a different file.
  Reproducers quote-trailing-nbsp-trimmed.bin, quote-trailing-ideographic-space-trimmed.bin, target quote-demo.
- **Proposed fix:** Trim only ASCII space and tab, or quote any Unicode whitespace.
- **Source:** reports/22-fuzz-target-group-5-misc.md
- **Status:** open

### C050 [finding, medium] List files are line-based with no escaping, so a name with a newline injects extra lines into %L/%F

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/ParameterExpansion.swift:514-516
- **Basis:** read
- **Detail:** A file named "x\n/Users/me/important" contributes two lines to %L/%F; xargs rm < %L then removes another
  path. %F names beginning with - are not protected.
- **Proposed fix:** Refuse names with newlines (as missingName refuses), or offer a NUL-separated list code.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C051 [finding, medium] Quick Look follow calls localOperands() on every panel event

**Outcome:** duplicate of C032 — see `status/config-a.md`

- **Where:** Sources/Plugins/MacIntegration/MacIntegrationPlugin.swift:172-175
- **Basis:** measured
- **Detail:** Including each cursor move while the panel is visible: 0.3 s at 1M marked.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### C052 [verdict, medium] Directory tree turns block main longer than budget

**Outcome:** duplicate of C004 — see `status/config-b.md`

- **Where:** Sources/Plugins/Places/DirectoryTreeWindowController.swift:342-357;
  Sources/Plugins/Places/DirectoryTreeWindowController.swift:369-372
- **Basis:** CONFIRMED (ran headless) in kind, smaller than claimed
- **Detail:** 2,000-node budget counts nodes not time. Headless one turn of 2,000 small levels: 10k outline rows 0.27 s;
  100k 0.30 s; 1M 0.74-0.81 s. outline.row(forItem:) is O(rows): 0.13 ms per call at 1M. Turns re-queue immediately.
  Claimed 1.6-1.8 s not reproduced without a window.
- **Proposed fix:** Budget by elapsed time (about 8 ms) and call reloadItem only for expanded nodes, once per turn per
  node.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### C053 [finding, medium] Command history with secrets is persisted and exported with default 0644 permissions

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** Sources/Plugins/SystemTools/CommandLine.swift:217-229;
  Sources/Plugins/SystemTools/SystemToolsPlugin.swift:166;
  Sources/Plugins/Configuration/ConfigurationPlugin.swift:59-67;
  Sources/Plugins/Configuration/ConfigurationCenter.swift:264
- **Basis:** read
- **Detail:** Every typed line (curl -u user:pass, mysql -p...) is stored in systemTools.history. Export includes every
  stored key and writes the file with default 0644.
- **Proposed fix:** Offer "do not record" for history; exclude history from export or warn; write the export 0600.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C054 [finding, medium] A .app in the current folder wins over the command typed (Safari.app in a downloaded folder opens that one)

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/SystemTools/CommandLine.swift:71-74
- **Basis:** read
- **Detail:** Bare names never search "."; a file named ls does not shadow /bin/ls.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C055 [finding, medium] Jobs that ignore cancellation can block the command system (Rename Volume, Eject, System Information on a stale mount)

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/SystemTools/SystemToolsPlugin.swift:313-321, 327, 356;
  Sources/Plugins/SystemTools/SystemInformation.swift:119-130; Kernel.swift:79
- **Basis:** inferred
- **Detail:** resourceValues on a dead network mount can hang; the job ignores its monitor and Kernel.swift:79 blocks
  commands while isBusy is true. Trigger with a stale NFS/SMB mount. Plausible, not reproduced. Category: freeze.
- **Proposed fix:** Run these outside the job queue with a timeout, and abandon on cancel.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C056 [finding, medium] An enabled-closure builds the whole operand list: Print enabled check costs 158 ms with 333k marked, paid whenever the Files menu validates

**Outcome:** duplicate of C026 — see `status/config-a.md`

- **Where:** Sources/Plugins/SystemTools/SystemToolsPlugin.swift:54
- **Basis:** measured
- **Detail:** SystemToolsPlugin calls model().operands().filter... Asking all 332 commands costs 136-178 ms, of which
  cm_PrintFile is 158 ms and cm_ShowOnlySelected 19 ms; validating the Files menu costs 129 ms.
- **Proposed fix:** Use hasOperandFile or a cached count.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### C057 [finding, medium] Branch view memory and re-walk storms

**Outcome:** not fixed — see `status/plugins-a-p2.md`

- **Where:** Sources/Plugins/VirtualFolders/BranchWalker.swift:101, 144, 153;
  Sources/Plugins/VirtualFolders/VirtualFileSystem.swift:259, 454, 466-470, 488-519
- **Basis:** read
- **Detail:** visited collects every directory URL (hundreds of MB for a large branch) yet only the first 512 are kept.
  Only those 512 directories are watched so deeper changes go unseen. Every change report triggers a full re-walk on all
  cores, at most every 0.5 s, for as long as changes continue; a branch of ~ or of a build folder would re-walk
  constantly unless the panel debounces (not verified). With no cancellation flag, receive is only consulted when a
  batch has files, so a directory-only region cannot be stopped. Coalescer can call onChange up to 0.5 s after the
  watcher was released. 64 remembered lists have no entry cap.
- **Proposed fix:** Cap visited at watchLimit; for local branches use one recursive watch on the root; back off
  re-walks; check a weak token in settle.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C058 [finding, medium] O(n) work on the main thread for virtual file lists (register, unique, watch, volume)

**Outcome:** duplicate of C006 — see `status/config-b.md`

- **Where:** Sources/Plugins/VirtualFolders/VirtualFileSystem.swift:108-138;
  Sources/Plugins/VirtualFolders/VirtualFileSystem.swift:441-463;
  Sources/Plugins/VirtualFolders/VirtualFoldersPlugin.swift:91-95;
  Sources/Plugins/VirtualFolders/VirtualFoldersPlugin.swift:120; Sources/AFMShell/Window/PanelCoordinator.swift:178
- **Basis:** read
- **Detail:** register and unique compute locationKey and a [UInt8] copy per URL and scan every scheme under the
  registry lock. watch for a list resolves provider, parent and locationKey for every entry before taking the first 512.
  volume(of:) runs allSatisfy(\.isFileURL) over all entries. Trigger: feed a 1M-result search to the list box, or branch
  view of a huge selection: seconds of beach ball.
- **Proposed fix:** Register the raw array and de-duplicate inside listing (already off-main); in watch stop after 512
  distinct parents or precompute them off-main.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C059 [verdict, medium] VirtualFileSystem register/watch are O(n) on main

**Outcome:** duplicate of C006 — see `status/config-b.md`

- **Where:** Sources/Plugins/VirtualFolders/VirtualFileSystem.swift:119-138;
  Sources/Plugins/VirtualFolders/VirtualFileSystem.swift:441-463;
  Sources/Plugins/VirtualFolders/VirtualFoldersPlugin.swift:95;
  Sources/Plugins/VirtualFolders/VirtualFoldersPlugin.swift:120; Sources/AFMShell/Window/PanelCoordinator.swift:186-196
- **Basis:** CONFIRMED (ran)
- **Detail:** Linear, at 100k / 1M: register(files:) 83 ms / 0.97 s; watch on a list 127 ms / 1.25 s;
  registerPicked(operands().map(\.url)) 144 ms / 1.77 s.
- **Proposed fix:** Register on the caller's background thread; in watch, stop collecting parents once watchLimit
  distinct ones are found.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### C060 [verdict, medium] Coalescer.settle calls onChange off the main thread

**Outcome:** duplicate of C008 — see `status/config-b.md`

- **Where:** Sources/Plugins/VirtualFolders/VirtualFileSystem.swift:510;
  Sources/Plugins/VirtualFolders/VirtualFileSystem.swift:516;
  Sources/Plugins/VirtualFolders/VirtualFileSystem.swift:517; Sources/AFMShell/Window/PanelCoordinator.swift:178;
  Sources/AFMShell/Panel/PanelViewController.swift:810; Sources/AFMKernel/FileSystem/FileSystemProvider.swift:308
- **Basis:** CONFIRMED (read)
- **Detail:** 510/517 schedule settle() on DispatchQueue.global; 516 calls fire() there with no hop to main. Callback is
  reloadChangedPanels, which mutates missedChanges and calls panel.reload (MainThread.assert at
  PanelViewController:810); contract says main thread. Sequence: panel shows a branch view or search-result list; second
  change report within 0.5 s of first; FSEvents latency is also 0.5 s so under sustained changes it often lands just
  before settle. User sees assertion crash in debug; in release undefined behaviour, possible crash.
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

### C061 [finding, medium] Passwords are encoded into virtual folder URLs and land in tabs, history and hotlist

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Sources/Plugins/VirtualFolders/VirtualLocation.swift:98-103;
  Sources/Plugins/Navigation/DirectoryHistory.swift:34; TreeCache.swift:188
- **Basis:** reproduced
- **Detail:** Comment says "scheme, user, host and port" but a password is included: ftp://user:s3cret@host becomes hex
  in the vfolder:// host (encoding confirmed). Same if a real URL carries a password: DirectoryHistory.swift:34 and
  TreeCache.swift:188 store absoluteString. Whether Network URLs ever carry one was not verified.
- **Proposed fix:** Strip the password in prefix(of:) and before persisting.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C062 [finding, medium] Display filters, Only Selected, Select All/Invert/Restore run synchronously on main (47-290 ms each at 1M)

**Outcome:** fixed — see `status/config-a.md`

- **Where:** ViewOptions/ViewOptionsPlugin.swift:181-189; ViewOptions/ViewOptionsPlugin.swift:128-133
- **Basis:** measured
- **Detail:** Scaling, measured. Display filters applied synchronously; 'Only Selected' costs 47 + 147 ms plus mark
  dropping. PanelModel.filtered and setFilter(prefiltered:) exist but are not used here. Select All 171 ms, Invert 290
  ms, Restore 260 ms (PanelModel.shownKeys; model-only).
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C063 [finding, medium] Background sort falls back to a main-thread sort of 1M because every update bumps listVersion even when nothing changed

**Outcome:** fixed — see `status/config-a.md`

- **Where:** ViewOptions/ViewOptionsPlugin.swift:196-200
- **Basis:** read (confirmed by reading; duration not measured)
- **Detail:** Reported medium to high; scaling. PanelModel.setListed increments listVersion on every update(with:), even
  when nothing changed. A quiet reload landing during the background sort sends the completion to model.setSort(order),
  which sorts 1M on main. In a busy watched folder this is the normal outcome. Duration not measured.
- **Proposed fix:** Re-dispatch the sort on a version mismatch, or stop bumping listVersion when the entries are
  unchanged.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C064 [finding, low] settings.flag runs a JSON decode per call inside checked: closures

**Outcome:** fixed — see `status/config-a.md`

- **Basis:** read
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### C065 [finding, low] Process arguments arrive in decomposed form and './' is prefixed inside the user's quotes

**Outcome:** fixed — see `status/config-a.md`

- **Basis:** reproduced
- **Detail:** Noted as a low-severity mismatch.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### C066 [finding, low] Configuration export/import/save position call UserDefaults.synchronize() on main

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Configuration/ConfigurationPlugin.swift
- **Basis:** read
- **Detail:** Low; file I/O is off main.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C067 [finding, low] Tree attach: the merge path ignores limit, so a huge folder on the selected-folder ancestor chain links in one turn

**Outcome:** fixed — see `status/plugins-a-p2.md`

- **Where:** DirectoryTree.swift:214-231
- **Basis:** read
- **Detail:** Taken for every ancestor of the selected folder because those are pre-created.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C068 [finding, low] Tree attach: a partial attach across turns can interleave with a node(at:creating:) insert and give duplicate or out-of-order children

**Outcome:** fixed — see `status/plugins-a-p2.md`

- **Where:** DirectoryTree.swift:232-240
- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C069 [finding, low] Dropping a million-node tree frees it on the main thread

**Outcome:** fixed — see `status/plugins-a-p2.md`

- **Where:** DirectoryTreeWindowController.swift:244, 298
- **Basis:** read
- **Detail:**
- **Proposed fix:** Hand it to a background queue.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C070 [finding, low] A cancelled non-rescan tree scan still stores its partial result after a newer scan began

**Outcome:** fixed — see `status/plugins-a-p2.md`

- **Where:** DirectoryTreeWindowController.swift:283-284
- **Basis:** read
- **Detail:** Harmless ordering in practice.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C071 [finding, low] Exchange Directories and Tabs / Load Tabs fire one tabs.onChange per inserted and closed tab (about 200 callbacks for 50+50 tabs; quadratic for a 1 MB tab file)

**Outcome:** fixed — see `status/config-b.md`

- **Where:** FolderTabs/FolderTabsPlugin.swift:238-262
- **Basis:** inferred (plausible)
- **Detail:** Reported low to medium; flooding, plausible; depends on the shell's tabs.onChange cost. A 1 MB tab file
  can hold thousands of tabs.
- **Proposed fix:** A batch-replace API on PanelTabs with a single notification, and a tab-count cap.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C072 [finding, low] Tab paths are read with fileSystems.location(from:), so an untrusted .tab file can make the app connect to any scheme/host or trigger automounts

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** FolderTabs/FolderTabsPlugin.swift:417
- **Basis:** inferred (plausible; depends on what the Network plugin does without a prompt)
- **Detail:** Category: security. A tab file can name any scheme or path (sftp://host/..., /net/host/...). The active
  tab of each side is opened immediately. Trigger: loading an untrusted .tab file makes the app connect to a host of the
  file's choosing or trigger automounts.
- **Proposed fix:** Ask for confirmation when a loaded file contains non-local locations.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### C073 [finding, low] TabFile writes values unescaped, so a newline in a folder name or caption injects lines (and edge spaces do not round-trip)

**Outcome:** fixed — see `status/config-b.md`

- **Where:** FolderTabs/TabFile.swift:34-47
- **Basis:** reproduced
- **Detail:** Category: security/correctness. Confirmed: a tab at /tmp/a\n0_path=sftp://evil.example/ with caption
  t\n1_path=/etc reads back as tabs sftp://evil.example and /etc. Trigger: a folder with such a name arrives in an
  extracted archive; the user saves tabs while in it and loads them later. Also: leading and trailing spaces in a path
  do not round-trip, because lines are trimmed.
- **Proposed fix:** Refuse or escape CR/LF in paths and captions on write; do not trim the value side.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### C074 [finding, low] A UTF-8 BOM makes TabFile reject the first section header; UTF-16 tab files fail through the lossy decode

**Outcome:** fixed — see `status/config-b.md`

- **Where:** FolderTabs/TabFile.swift:55-58; FolderTabs/FolderTabsPlugin.swift:410
- **Basis:** reproduced
- **Detail:** Category: correctness. TabFile(text: "\u{FEFF}[activetabs]...") returns nil (confirmed), so the user sees
  'The file holds no tabs'. UTF-16 files, which Windows tools write, fail the same way through the lossy decode at
  FolderTabsPlugin.swift:410.
- **Proposed fix:** Strip the BOM; detect UTF-16 by its BOM.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### C075 [finding, low] Next/previous volume calls places() on main; the local provider may wait up to 1 s on its first answer

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Navigation/NavigationPlugin.swift
- **Basis:** read
- **Detail:** Inventory note (LocalFileSystem scope).
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C076 [finding, low] Go to Path from Clipboard copies the whole pasteboard text on main

**Outcome:** fixed — see `status/plugins-a-p2.md`

- **Where:** Navigation/NavigationPlugin.swift
- **Basis:** read
- **Detail:** Listed in the inventory and cross-referenced to F6.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C077 [finding, low] pasteboard.string(forType:) runs on main in Go to Path from Clipboard; a lazy or huge clipboard blocks

**Outcome:** fixed — see `status/plugins-a-p2.md`

- **Where:** Navigation/NavigationPlugin.swift:133
- **Basis:** inferred (plausible)
- **Detail:** Category: freeze. A lazily provided or very large clipboard blocks for as long as the owning app takes.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### C078 [finding, low] First child(named:) in a 1M-subfolder folder builds its index on main (53 ms)

**Outcome:** not fixed — see `status/plugins-a-p2.md`

- **Where:** Places/DirectoryTree.swift
- **Basis:** measured (replica)
- **Detail:** Scaling, measured in replica.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C079 [finding, low] reloadData + expandItem with an expanded folder of 1M subfolders takes 0.74 + 0.84 s (84 + 71 ms at 100k)

**Outcome:** not fixed — see `status/plugins-a-p2.md`

- **Where:** Places/DirectoryTreeWindowController.swift
- **Basis:** measured (replica)
- **Detail:** Scaling, measured in replica.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C080 [finding, low] Tree teardown on main: tree = nil frees the whole tree (136 ms per 2.4M nodes)

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Places/DirectoryTreeWindowController.swift:298; Places/DirectoryTreeWindowController.swift:244
- **Basis:** measured (replica)
- **Detail:** Reported low to medium; scaling, measured in replica. Also replacement in adopt (:244).
- **Proposed fix:** Release on a background queue.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C081 [finding, low] Modal run loops (hotlist/history forms, NSApp.runModal editors, open/save/print panels) run on main

**Outcome:** not a defect — see `status/config-b.md`

- **Where:** Places/HotlistEditorWindowController.swift:40; Configuration/CommandBrowser.swift:92;
  Configuration/ConfigurationPlugin.swift:143; MacIntegration/MacIntegrationPlugin.swift:230;
  SystemTools/SystemToolsPlugin.swift:500
- **Basis:** read
- **Detail:** None is raised from a timer or event flood; each is user-triggered. ui.form loops: showHotlist,
  showHistory. NSApp.runModal: HotlistEditorWindowController.swift:40, CommandBrowser.swift:92.
  NSOpenPanel/NSSavePanel.runModal: ConfigurationPlugin.swift:143, MacIntegrationPlugin.swift:230.
  NSPrintOperation.runModal: SystemToolsPlugin.swift:500. storedDataProblem and ConfigurationStore.onProblem alerts are
  raised at most once per key.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C082 [finding, low] Places stop() performs a synchronous history save and treeCache.flush() (up to 2 MB per file) at quit

**Outcome:** not a defect — see `status/config-b.md`

- **Where:** Places/PlacesPlugin.swift (stop())
- **Basis:** read
- **Detail:** Low.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C083 [finding, low] CommandRunner.snapshot costs 195 ms per panel and bulk tab loads fire one tabs.onChange per tab

**Outcome:** duplicate of C027 — see `status/config-a.md`

- **Where:** Plugins/Configuration/CommandRunner.swift
- **Basis:** read
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### C084 [finding, low] One GCD worker blocked per launched program (ended.wait() for the life of every non-waited child); enough long-lived children could exhaust the pool and starve archive flush timers, ColumnValueStore and volume refresh

**Outcome:** duplicate of C044 — see `status/config-a.md`

- **Where:** Plugins/Configuration/CommandRunner.swift:261-264; Plugins/Configuration/CommandRunner.swift:267;
  Plugins/Archives/OpenArchive.swift:571; Plugins/Archives/OpenArchive.swift:714;
  AFMShell/Panel/ColumnValueStore.swift:89
- **Basis:** read
- **Detail:** Medium-low. :261-264 parks a global(.utility) worker in ended.wait(); :267 does the same on .userInitiated
  when waiting. The pool limit of 64 is the auditor's recollection, not checked against this OS version.
- **Proposed fix:** Use terminationHandler alone, with no waiting thread.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### C085 [finding, low] CommandRunner: line.drop { $0 != ' ' } cuts a quoted application path containing a space mid-word and yields an unbalanced line

**Outcome:** duplicate of C047 — see `status/config-a.md`

- **Where:** Plugins/Configuration/CommandRunner.swift:290
- **Basis:** read
- **Detail:**
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### C086 [finding, low] Privacy: settings export includes every stored key (command-line history, directory history, servers and users, trusted certificates)

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Plugins/Configuration/ConfigurationCenter.swift:254-263; Plugins/SystemTools/SystemToolsPlugin.swift:166
- **Basis:** read
- **Detail:**
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### C087 [finding, low] Whole-file reads without cap: settings import

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Plugins/Configuration/ConfigurationCenter.swift:272
- **Basis:** read
- **Detail:** No cap.
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### C088 [finding, low] ParameterExpansion: names inside user-quoted "%S" get no ./ guard against a leading -

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Plugins/Configuration/ParameterExpansion.swift:425-429
- **Basis:** read
- **Detail:**
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### C089 [finding, low] activateFileViewerSelecting with a large selection on main

**Outcome:** duplicate of C003 — see `status/config-a.md`

- **Where:** Plugins/MacIntegration/MacIntegrationPlugin.swift:161-162
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### C090 [finding, low] With Quick Look open, every cursor move builds the whole operand list

**Outcome:** duplicate of C032 — see `status/config-a.md`

- **Where:** Plugins/MacIntegration/MacIntegrationPlugin.swift:172-175
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### C091 [finding, low] urlsForApplications(toOpen:) on the main thread

**Outcome:** duplicate of C001 — see `status/config-a.md`

- **Where:** Plugins/MacIntegration/MacIntegrationPlugin.swift:62-70;
  Plugins/MacIntegration/MacIntegrationPlugin.swift:152
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### C092 [finding, low] TreeCache stale store: a cancelled, non-rescan scan that returns late stores its partial tree over the complete one a newer scan just stored

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Plugins/Places/DirectoryTreeWindowController.swift:283-284
- **Basis:** read
- **Detail:**
- **Proposed fix:** Carry a per-root store ticket.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### C093 [finding, low] Privacy: folder trees of every scanned volume stored in plaintext in `~/Library/Application Support/<product>/TreeCache/` and outlive encrypted or removable volumes

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Plugins/Places/TreeCache.swift:68-74; Plugins/Places/TreeCache.swift:180
- **Basis:** read
- **Detail:**
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### C094 [finding, low] TreeCache race: entry(for:) returns slot.entry after unlocking while note() appends to slot.entry.paths under the lock on the updates queue

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Plugins/Places/TreeCache.swift:89-92; Plugins/Places/TreeCache.swift:147-149
- **Basis:** read
- **Detail:** Low-medium.
- **Proposed fix:** Copy the entry while locked.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### C095 [finding, low] Name.app typed on the command line resolves in the current folder first (search-path hijack)

**Outcome:** duplicate of C054 — see `status/config-a.md`

- **Where:** Plugins/SystemTools/CommandLine.swift:71-72; Plugins/SystemTools/SystemToolsPlugin.swift:178-191
- **Basis:** read (confirmed)
- **Detail:** Rated LOW/MEDIUM. Typing 'Preview.app file.pdf' while the panel shows a USB stick or unpacked archive
  containing a planted Preview.app launches it (unquarantined there).
- **Proposed fix:** Search the application folders first; use the panel folder only for ./X.app.
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### C096 [finding, low] Whole-file reads without cap: VirtualFolders file list

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Plugins/VirtualFolders/VirtualFoldersPlugin.swift:192
- **Basis:** read
- **Detail:** No cap.
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### C097 [finding, low] Save selection to file runs operands() + encode on main (about 210 ms); print list does operands() or the whole list on main once

**Outcome:** fixed — see `status/plugins-a-p2.md`

- **Where:** Selection/SelectionPlugin.swift; SystemTools/SystemToolsPlugin.swift
- **Basis:** measured
- **Detail:** I/O and formatting are in a job.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C098 [verdict, low] %|VAR| and %VAR% in Command field are not attacker-controlled in practice (sub-ruling of claim 1)

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/CommandLanguage.swift:105-107
- **Basis:** CONFIRMED (ran)
- **Detail:** Affected by the grapheme bug but the value source is the user's own.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### C099 [finding, low] Pid reuse only leaks a folder; the parent is the per-user temp directory so no symlink or predictable-name issue

**Outcome:** not a defect — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/CommandRunner.swift
- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C100 [verdict, low] Mutually calling user commands (direct case)

**Outcome:** refuted — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/CommandRunner.swift:111-114
- **Basis:** REFUTED (ran) for the direct case
- **Detail:** em_a = 'em_sayA,em_b', em_b = 'em_sayB,em_a' stops with 'a calls itself'.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### C101 [finding, low] Foundation Process passes arguments in decomposed form (name o-grave C3 B2 arrives as 6F CC 80)

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/CommandRunner.swift:247
- **Basis:** reproduced
- **Detail:** Q3. Harmless on APFS; a different name on volumes that distinguish the two forms. See
  quote-mismatch-argument-decomposed.txt.
- **Source:** reports/22-fuzz-target-group-5-misc.md
- **Status:** open

### C102 [finding, low] List cleanup timing: quit deletes list files that programs started in the last 60 s may still need; the start-time async delete can race the first list write

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/CommandRunner.swift:47-55
- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C103 [finding, low] Start-menu slots: ensureSlots registers one command per entry with no cap; an imported million-entry menu stalls main. Hotlist.limit is likewise enforced on insert only

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/ConfigurationCenter.swift:148-164
- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C104 [finding, low] .unreadable settings backups are written only if none exists, never removed, and exported; a second corruption is not backed up and the next save drops the unreadable entries

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/ConfigurationModels.swift:130-131;
  Sources/Plugins/Configuration/StoredSettings.swift:43-44
- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C105 [verdict, low] Configuration export is world-readable and includes sensitive data

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/ConfigurationPlugin.swift:59-67; Sources/Plugins/Places/TreeCache.swift:180;
  Sources/Plugins/Places/PlacesPlugin.swift:72
- **Basis:** CONFIRMED (ran mode check)
- **Detail:** Export takes every JSON-valued key in the defaults domain: command history, connection hosts, users and
  UUIDs, trusted fingerprints, tabs. Data.write(.atomic) gave mode 644 under umask 022. Tree cache is plain text in
  Application Support. Another local user or wherever export is shared; cache informational.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### C106 [finding, low] A very large selection in %S exceeds ARG_MAX; the error reads "cannot be started"

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/ParameterExpansion.swift
- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C107 [finding, low] atWordStart is true after any space even inside the user's quotes, so a quoted string 'pre %N post' with name -x gives pre ./-x post

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/ParameterExpansion.swift:258
- **Basis:** reproduced
- **Detail:** Q4. The test accepts it, so it is not counted as a mismatch. Shortest mismatch per context and shell:
  repro/misc/quote-mismatches/.
- **Source:** reports/22-fuzz-target-group-5-misc.md
- **Status:** open

### C108 [finding, low] An empty value produces no word (%E without extension, empty variable), shifting later arguments

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/ParameterExpansion.swift:286
- **Basis:** read
- **Detail:**
- **Proposed fix:** Emit "".
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C109 [finding, low] Double escaping: "...%S..." re-escapes the user's own text ("$HOME/%S" becomes \$HOME) and the tail scan ignores \"

**Outcome:** fixed — see `status/config-a.md`

- **Where:** Sources/Plugins/Configuration/ParameterExpansion.swift:415-429
- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C110 [verdict, low] Tab file entry count

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Sources/Plugins/FolderTabs/FolderTabsPlugin.swift:332;
  Sources/Plugins/FolderTabs/FolderTabsPlugin.swift:408
- **Basis:** REFUTED (read) for the count
- **Detail:** File capped at 1 MiB, still roughly 100k tabs; count claim bounded.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### C111 [verdict, low] Tab file text() writes paths and captions unescaped; loaded active tab connects at once

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** Sources/Plugins/FolderTabs/TabFile.swift:38-40; Sources/Plugins/Network/RemoteFileSystem.swift:595-596
- **Basis:** CONFIRMED (read) for injection and connect
- **Detail:** A loaded active tab is shown at once; ftp://user:pw@host is announced without asking. Precondition:
  hostile .tab file, or a folder name with a newline that the user saves and reloads. Low.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### C112 [finding, low] History bookkeeping does 200 URL parses on main per navigation

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Sources/Plugins/Navigation/DirectoryHistory.swift:32, 42
- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C113 [finding, low] PagePrintView.init counts graphemes of every line on main

**Outcome:** fixed — see `status/plugins-a-p2.md`

- **Where:** Sources/Plugins/Navigation/DirectoryList.swift:172
- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C114 [finding, low] TreeCache: a stale file can be left after a flush/store race

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Sources/Plugins/Navigation/TreeCache.swift:159-169; TreeCache.swift:101-107
- **Basis:** read
- **Detail:** flush snapshots an entry, store then writes a newer one, and flush writes the old snapshot last; file on
  disk is stale after restart.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C115 [finding, low] Hotlist "add current dir": a folder with a trailing space, or one named ":", is stored as `cd <path>` and trimmed or reinterpreted on use

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Sources/Plugins/Places/Hotlist.swift:236-241
- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C116 [finding, low] Lists shown without any watcher (unwatchable provider, empty list, background tab) can be evicted while shown

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Sources/Plugins/VirtualFolders/VirtualFileSystem.swift:127, 473
- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C117 [finding, low] Real folders named like virtual ones (" (branch)", " (list N)", " (selected branch N)") are unreachable by typed path

**Outcome:** fixed — see `status/plugins-a-p2.md`

- **Where:** Sources/Plugins/VirtualFolders/VirtualFileSystem.swift:408-424;
  Sources/AFMKernel/FileSystem/FileSystemProvider.swift:467-472
- **Basis:** read
- **Detail:** Any text ending in these suffixes is claimed first: a real /x/Photos (branch), typed or stored in the
  hotlist as cd /x/Photos (branch), opens the branch view of /x/Photos. The (list N) form also ignores the title.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C118 [finding, low] capabilities without a location answers for the folder read last, wrong with two different virtual panels

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Sources/Plugins/VirtualFolders/VirtualFileSystem.swift:75
- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C119 [finding, low] List file is read without a size cap; lines may name any provider so opening a list file causes connections

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Sources/Plugins/VirtualFolders/VirtualFoldersPlugin.swift:188-193
- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C120 [finding, low] Virtual URL decoding: decoded prefixes may carry a path or query and the path is not standardised (.../a/../../etc accepted)

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Sources/Plugins/VirtualFolders/VirtualLocation.swift:105-110
- **Basis:** read
- **Detail:** Navigation only.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C121 [finding, low] TreeCache: folders added by noteFolder load as scanned and show as leaves even if they have subfolders

**Outcome:** fixed — see `status/plugins-a-p2.md`

- **Where:** TreeCache.swift:134-152
- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C122 [finding, low] TreeCache: slow parse, line.count and text.contains are grapheme-based over files of 100 MB scale

**Outcome:** fixed — see `status/plugins-a-p2.md`

- **Where:** TreeCache.swift:206, 213
- **Basis:** read
- **Detail:**
- **Proposed fix:** Use utf8.
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C123 [finding, low] TreeCache: subtrees silently lost because line.hasPrefix("[") is Character-based (folder name starting with a combining mark never parses back)

**Outcome:** fixed — see `status/plugins-a-p2.md`

- **Where:** TreeCache.swift:206-211
- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C124 [finding, low] TreeCache: memory is never evicted; a million-folder tree is held as full path strings plus a Set plus the formatted text during write

**Outcome:** fixed — see `status/plugins-a-p2.md`

- **Where:** TreeCache.swift:55
- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C125 [finding, low] onlySelected enablement rebuilds the `Set<String>` of all marks (47 ms after each mark change)

**Outcome:** fixed — see `status/config-a.md`

- **Where:** ViewOptions/ViewOptionsPlugin.swift:128
- **Basis:** measured
- **Detail:** Reported low to medium; scaling, measured. 47 ms after each mark change, on Show-menu open, or per tick if
  placed on the bar.
- **Proposed fix:** model().selectionCount > 0
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C126 [finding, low] A sort set by another route while a background sort is pending is overwritten when the background result lands

**Outcome:** fixed — see `status/config-a.md`

- **Where:** ViewOptions/ViewOptionsPlugin.swift:198-200; FolderTabs/FolderTabsPlugin.swift:266
- **Basis:** inferred (plausible)
- **Detail:** Category: correctness. pendingOrders[id] == order still holds, so setSort(order) runs. Trigger: a header
  click, or tab restore in FolderTabsPlugin.swift:266, during a pending background sort.
- **Proposed fix:** If model.sort != from, drop the result.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### C127 [finding, low] Sort fallback and display filters run synchronously on main (0.5 s sort, 0.2 s filter per million entries)

**Outcome:** fixed — see `status/config-a.md`

- **Where:** ViewOptions/ViewOptionsPlugin.swift:200; ViewOptions/ViewOptionsPlugin.swift:150-158;
  AFMKernel/Panels/PanelModel.swift:705
- **Basis:** measured
- **Detail:** Reported severity LOW-MEDIUM, freeze. Sort: when the list changed while a background sort ran, the
  fallback is model.setSort(order), a synchronous sort on main; measured 0.5 s for one million entries, on top of the
  model's filter and index work. With a busy folder (finding 4 bumps listVersion constantly, as do computed sizes at
  PanelModel.swift:705) the stale path is the normal path. Filters: apply always calls the synchronous model.setFilter,
  about 0.2 s of single-threaded matching per million entries on main. The kernel's off-thread PanelModel.filtered /
  setFilter(_:prefiltered:listVersion:) path is not used.
- **Proposed fix:** On a stale result, re-dispatch the sort with the new snapshot (a loop keyed by pendingOrders). Route
  filters through the prefiltered path above the same threshold.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### C128 [verdict, info] Names via list file (%L %F %D %UL %UF %WL %WF), cd and cm_ steps, and %Q are not affected (sub-ruling of claim 1)

**Outcome:** not a defect — see `status/config-a.md`

- **Basis:** CONFIRMED (ran)
- **Detail:** Names go into a list file or no shell is used; %Q switches quoting off by design.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### C129 [finding, info] Whole-file read without cap: Places TreeCache own cache file (own data)

**Outcome:** fixed — see `status/config-b.md`

- **Where:** Plugins/Places/TreeCache.swift:85
- **Basis:** read
- **Detail:**
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

## Checked and found sound

### C130 [sound, info] ViewOptions applied/pendingOrders and FolderTabs closedTabs are main-thread only

- **Basis:** read
- **Detail:** Fine; ObjectIdentifier reuse is guarded by the weak-model check, or by the closure retaining the model.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### C131 [sound, info] Tab save and load are sound

- **Basis:** read
- **Detail:** Save is done in a job, temp file plus rename, overwrite confirmed, temp removed on failure. Load is capped
  at 1 MiB, refuses directories and special files, and tolerates CRLF.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### C132 [sound, info] Background sort handles double clicks, reverse-twice and closed tabs

- **Basis:** read
- **Detail:** Double clicks and reverse-twice resolve correctly; a tab closed meanwhile is harmless.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### C133 [sound, info] Navigation, ViewOptions and FolderTabs do their storage work in jobs

- **Basis:** read
- **Detail:** Apart from watch and places, no main-thread path into blocking storage calls was found within scope.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### C134 [sound, info] Places history, cache, tree building and linking are bounded and off main

- **Basis:** read
- **Detail:** History bounded at 200, written after a 1 s debounce, touches no file system. Cache file reads, tree
  building, places() and root(of:) run on background queues with generation checks. Linking nodes is bounded per turn
  (only the reloads are not). On-demand expand reads in the background. The hotlist is capped at 2000 and MacFavorites
  is path-only.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C135 [sound, info] Navigation does no stat, fileExists or realpath on main

- **Basis:** read
- **Detail:**
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C136 [sound, info] FolderTabs tab-file I/O is in jobs with a 1 MB limit; duplicating a tab does not copy the list

- **Basis:** read
- **Detail:**
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C137 [sound, info] Configuration process launch/wait, list-file I/O and export/import are off main

- **Basis:** read
- **Detail:** cm_wait uses a timer; user-command recursion is guarded.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C138 [sound, info] SystemTools application lookup, volume facts, eject, rename, system information and urlsForApplications run in jobs or on a global queue

- **Basis:** read
- **Detail:**
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C139 [sound, info] MacIntegration editor lookup, tag reads/writes are off main; hasLocalOperands is O(1)

- **Basis:** read
- **Detail:**
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C140 [sound, info] Selection file I/O is in jobs; each command makes one model notification

- **Basis:** read
- **Detail:**
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C141 [sound, info] All enabled/checked closures in Selection, Navigation, FolderTabs, ViewOptions (other than onlySelected), Configuration, SystemTools (other than printFile) and MacIntegration are O(1) or microseconds

- **Basis:** read
- **Detail:** Navigation's pasteboard.availableType query does no data fetch (plausible, not measured).
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C142 [sound, info] TreeCache threading is sound: the lock is never held during disk I/O and the main thread takes it only in flush() at quit; a hostile cache file can only produce odd names (..), leading to navigation, not a crash

- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C143 [sound, info] Tree ownership is clean: nodes are built off-main and touched only on main afterwards, and generation checks cover every hop

- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C144 [sound, info] Shared state: CommandRunner.active/launched/environment main only (race-free; active logically wrong, finding 8); list folder benign races; ConfigurationStore caches, ConfigurationCenter, key-binding editors main only; ProcessRunner.Buffer NSLock; SystemTools.log main only; DirectoryTree/TreeNode built on one thread handed to main; TreeScanner.paths/unscanned scan thread only; tree window state main only; TreeCache.memory under NSLock with no I/O under lock (stale-write race finding 15); DirectoryHistoryTracker main only; VirtualFileSystem state under one NSLock never held across a walk or provider call (register holds it O(n) on main, finding 5); Coalescer own NSLock (late callback, finding 13)

- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C145 [sound, info] Cancelling a typed command: the child leads its own process group; after terminate no orphan remained for "a; b" or a pipeline in zsh, bash, sh, dash (confirmed in pg/)

- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C146 [sound, info] Output handling: the 8 MB cap keeps draining, the parent write end is closed, and lpr gets absolute paths

- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C147 [sound, info] Open Terminal Here uses NSWorkspace.open with no AppleScript and no shell string, so no injection through directory names

- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C148 [sound, info] Ordinary hostile names in plain contexts (%N, "%N", '%N', %P%N, x%Ny, --out=%N) arrive as exactly one correct argument in zsh, bash, sh, dash, ksh for every name without a combining mark (spaces, quotes, backslash, $, backtick, ;&|<>, globs, ~, !, #, =, newline, CR, tab, U+2028, 250-byte name); the ./ prefix for - names works

- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C149 [sound, info] No-name refusal: missingName refuses %N, %O, %E, %V and %M on [..]; %P%S with nothing selected expands to nothing rather than the bare folder

- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C150 [sound, info] Directory names cannot trigger a hotlist command: stored entries always start with cd

- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C151 [sound, info] Virtual folder URLs round-trip for spaces, %, #, ?, ;, newline, combining marks, trailing space and very long hosts; lists are refused for every mutating call; move, copy, remove, trash, append, commit, setQuarantine and copyMetadata map source and destination consistently

- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C152 [sound, info] Options window, key-binding rebase, command browser modal, hotlist editor: no threading issues found

- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C153 [sound, info] tabfile target: nothing found

- **Basis:** measured
- **Detail:** 67,570 ASan / 65,156 release execs.
- **Source:** reports/22-fuzz-target-group-5-misc.md
- **Status:** open

### C154 [sound, info] No hangs and no over-memory cases in the code under test

- **Basis:** measured
- **Detail:** The one rss stop in settings was the harness leaking a test bench per input.
- **Source:** reports/22-fuzz-target-group-5-misc.md
- **Status:** open

### C155 [sound, info] descript, descript-line, descript-store: no crash (only D1/D2 mismatches)

- **Basis:** measured
- **Detail:** 92,623/36,508; 34,836/25,553; 92,752/35,735 execs.
- **Source:** reports/22-fuzz-target-group-5-misc.md
- **Status:** open

### C156 [sound, info] selection, settings (real ConfigurationCenter.importSettings), lenient, pexpand ran; crashes C1-C4 only

- **Basis:** measured
- **Detail:** selection 112,826/69,181; settings 93,893/84,059; lenient 276,848/361,089; pexpand 111,425/49,579 execs.
- **Source:** reports/22-fuzz-target-group-5-misc.md
- **Status:** open

### C157 [sound, info] quote target: single-quote context held in every case; 150,800 expansion checks over 1,268 inputs across real /bin/zsh -c and /bin/sh -c

- **Basis:** measured
- **Detail:** Results identical in zsh and sh.
- **Source:** reports/22-fuzz-target-group-5-misc.md
- **Status:** open

## Not covered / left behind

### C158 [gap, info] Not reproduced: real blocking times of LaunchServices, sharing and pasteboard calls on a stalled mount

- **Basis:** read
- **Detail:** Inferred only.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C159 [gap, info] Not covered: PagePrintView drawing/pagination for a 1M-row list; ListCollector; KeyBindingEditor and LiveMenus internals; HotlistEditorWindowController beyond entry points (bounded by 2000 rows)

- **Basis:** read
- **Detail:**
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C160 [gap, info] F1 was measured on a headless NSOutlineView replica, not in the running app

- **Basis:** read
- **Detail:**
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### C161 [gap, info] fish, nu and other non-POSIX shells were not installed and not tested

- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C162 [gap, info] CommandLanguage.expandingEnvironment was not run; it shares the helpers from finding 1

- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C163 [gap, info] How the panel reacts to onChange bursts, and how the shell builds destination URLs for items shown under display-path names in picked views, were not reviewed

- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C164 [gap, info] Whether Network URLs ever carry passwords was not verified

- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C165 [gap, info] The form/list UI handling of newlines and very long titles was not reviewed

- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C166 [gap, info] JobService internals beyond the protocol comment were not reviewed

- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C167 [gap, info] Nothing was run inside the app: no build, and no TCC or File Provider behaviour observed live

- **Basis:** read
- **Detail:**
- **Source:** reports/15-review-config-places-tools-again.md
- **Status:** open

### C168 [gap, info] Imported cm_/em_/afm_/cd command steps were parsed (CommandLanguage.steps) but not performed because some open windows; cm_wait timers not run

- **Basis:** read
- **Detail:**
- **Source:** reports/22-fuzz-target-group-5-misc.md
- **Status:** open

### C169 [gap, info] Raw invalid-UTF-8 bytes cannot exist in a Swift String, so names were arbitrary Unicode scalars (U+0001-U+00FF included) rather than raw bytes

- **Basis:** read
- **Detail:**
- **Source:** reports/22-fuzz-target-group-5-misc.md
- **Status:** open

### C170 [gap, info] The tab-file target replicates FolderTabsPlugin.restore/replace (private there) on real PanelTabs rather than calling the plugin command

- **Basis:** read
- **Detail:**
- **Source:** reports/22-fuzz-target-group-5-misc.md
- **Status:** open
