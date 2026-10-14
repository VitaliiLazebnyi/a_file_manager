# Audit provider/operation plugins

Slice: main-thread responsiveness audit of FileOperations, Archives, Network, LocalFileSystem, VirtualFolders, Clipboard, FileProperties, FileTools (read-only; two micro-benchmarks under `scratchpad/review2/mainthread/forkB/`).

Paths below are relative to `P = /Users/cm0k/Claude/Projects/TotalCommander/Sources/Plugins`. "Measured" means `swiftc -O` on this Mac with a 1M-item list, 300k marked, ~60-char file URLs. `operands()` was timed with a slower `==` than the project's `memcmp`, so treat its 441 ms as an upper bound.

## (a) Inventory

**Provider methods the protocol allows on main**

| Provider | parent / displayPath | capabilities(for:) | places() | Other methods |
|---|---|---|---|---|
| LocalFileSystem | text only, ok | constant, ok | cached; can wait 1 s on NSCondition (F6) | `item(at:)` lstat/stat/getattrlist; `volume(of:)` fileExists loop, resourceValues, statfs; `watch()` realpath + FSEventStreamCreate (F1); `location(from:)` text only |
| ArchiveFileSystem | text only, ok | table lock (short), then `OpenArchive.lock`, which background threads hold across syscalls and O(n) work (F2) | none | `location(from:)` calls `stat()` (F3); `item`/`list`/`read` open the archive; `volume(of:)` inside an archive is text only |
| RemoteFileSystem | text only, ok | `center.lock` + session state lock, never held during I/O, ok | same short locks, ok | `location(from:)` may call `center.announce`, which disconnects only never-connected sessions, ok; `item`/`list` go to the network; `volume(of:)` no I/O |
| VirtualFileSystem | text only, ok | short lock; delegates to the real provider, so inherits F2 for a branch of a zip | none | `watch()` is O(list) plus realpath (F1, F4); `register`/`registerPicked` O(n) on main (F4); `volume(of:)` for a list is O(n) `allSatisfy` (called from background by the shell) |

**Every `enabled:` / `checked:` closure in scope**

| Plugin | Commands | Closure evaluates | Cost |
|---|---|---|---|
| FileOperations | copy, copyOtherPanel, copyWithOptions, copyNoAsk | `hasOperands` | O(1) |
| FileOperations | copySamePanel, renameMove, moveOnly, moveWithOptions, moveNoAsk, delete, deleteDirectly | `hasOperands && isWritable` | O(1) plus `capabilities(for: directory)` — F2 inside a zip |
| FileOperations | renameOnly, renameSingleFile | `cursorItem != nil && isWritable` | same |
| FileOperations | makeDirectory, makeDirectoryOther, newTextFile | `isWritable` (source or target) | same |
| Archives | packFiles, moveToArchive | `hasOperands` | O(1) |
| Archives | unpackFiles, testArchive | `hasOperands \|\| ArchiveURL.location(of:)` | URL parse, µs |
| Archives | openAsArchive | `cursorFile != nil` | O(1) |
| Network | ftpDisconnect | `!center.connected.isEmpty` | short locks, sort of a few sessions |
| Network | ftpHiddenFiles | `ServerKey(directory)`; checked: `showHidden` | µs |
| Network | ftpAddToList | remote and `hasOperands` | µs |
| Network | netDisconnect | `mountedVolume(of:)` | text only |
| VirtualFolders | branchView, left/right variants (checked); branchViewSelected (enabled) | `VirtualLocation(url)` parse, `hasOperands` | µs |
| Clipboard | cut, copy | `hasOperands && isFileURL` | O(1) |
| Clipboard | paste | `canReadObject(NSURL)`, then `isWritable`, a settings flag, `availableType` | measured 55 ms on the first call after 100k URLs land on the pasteboard, ~0.01 ms after; 0.09 ms with 100 MB of text; types only, never the data |
| Clipboard | copyNames and variants, detail commands | `hasOperands` | O(1) |
| Clipboard | saveDetails (two) | `hasOperands && isWritable` | F2 inside a zip |
| FileProperties | setAttributes, editComment | `isWritable` plus O(1) | F2 inside a zip |
| FileProperties | properties, finderInfo, occupiedSpace, createShortcut, showLinkTarget | flags, `isFileURL`, `hasOperands` | O(1) |
| FileProperties | countDirectoryContents | `isComplete && items.contains(where: \.isFolder)` | O(n) when the folder has no subfolders (F10) |
| FileTools | split, combine, encode, decode; createChecksums, verifyChecksums | `cursorItem` not a directory; `hasOperands` | O(1) |

**Other main-thread entry points**
- **Command handlers:** every one that works on the marked items first calls `model.operands()` (measured up to 441 ms at 1M/300k), then shows a dialog, then starts a job. Per-handler extras are in the findings.
- **Job completions:** F5.
- **PanelEvents subscription:** `Network/NetworkCommands.swift:26`, a dictionary write, ok.
- **Main-queue hops:**
  - `Archives/ArchivesPlugin.swift:50` — one refresh per archive flush, at least 0.5 s apart, ok.
  - `LocalFileSystem/LocalFileSystem.swift:832` — at most once per 3 s per volume, ok.
  - `Network/NetworkCommands.swift:448` — a list-run pause, ok.
- **Openers:** `ArchiveCommands.open` and `showMember` are text plus a job, ok.
- **Plugin `stop()` at quit:** F7.

## (b) Findings, most severe first

**F1 — critical, blocking-call, confirmed: `realpath()` on main for every watched panel directory**
- **Where:** `P/LocalFileSystem/DirectoryWatcher.swift:76` and `:117`; `FSEventStreamCreate` with `WatchRoot` at `:100` also opens the path.
- **Path:** `PanelCoordinator.panelDidChangeLocation` → `updateWatchers()` (`AFMShell/Window/PanelCoordinator.swift:171-179`) → `LocalFileSystem.watch` (`P/LocalFileSystem/LocalFileSystem.swift:840`) → `DirectoryWatcher.watch` → `resolve` → `realpath`.
- **Trigger:** either panel shows a folder on a stalled SMB/NFS/AFP mount and either panel then changes location. Every panel directory is re-resolved, so navigating the healthy panel also hangs.
- **Duration:** the mount timeout, 30–600 s.
- **Second route:** `VirtualFileSystem.watch` (`P/VirtualFolders/VirtualFileSystem.swift:441-470`) forwards up to 512 real folders, so up to 512 `realpath` calls on main.
- **Fix:** create and replace the stream on the watcher's own queue, and return the handle at once. Skip watching when `model.volume?.isLocal == false`.

**F2 — critical, blocking-call (lock), confirmed: `OpenArchive.capabilities` takes a lock held across syscalls and O(n) work**
- **Where:** `P/Archives/OpenArchive.swift:695-696`.
- **Path:** validation tick or menu open → any `isWritable` closure (e.g. `P/FileOperations/FileOperationsPlugin.swift:43`) → `FileSystemRegistry.capabilities(for:)` → `ArchiveFileSystem.capabilities(for:)` (`P/Archives/ArchiveFileSystem.swift:458-463`) → `OpenArchive.capabilities` → `locked {}`.
- **What holds that lock in the background:**
  - `isCurrent()` at `:476-483` does `FileSignature.of(localURL.path)` (a stat) under the lock.
  - `install` at `:1268-1280` does a stat and a `rename` under it.
  - `rebase` at `:1313` re-reads the whole central directory (`load()`) under it.
  - `takeSnapshot` at `:1105` sorts all entries under it.
  - `finishWrite` at `:843-851` calls `environment.hasRoom` (a volume query) under it.
- **Trigger and duration:**
  - A panel inside a ZIP that lies on a stalled mount: 30–600 s on the next tick.
  - A 1M-entry ZIP during a flush or a re-read after an external change: estimated 0.5–several s per occurrence.
- **Fix:** publish `capabilities` as a lock-free atomic snapshot, updated wherever `format`, `hasDuplicates` or `fetchedCopy` change. Move the stat, rename and `load` out of the lock.

**F3 — critical under a dead mount, blocking-call, confirmed: `ArchiveFileSystem.location(from:)` calls `stat()`**
- **Where:** `P/Archives/ArchiveFileSystem.swift:534-535`, reached from `FileSystemRegistry.location(from:relativeTo:)` (`AFMKernel/FileSystem/FileSystemProvider.swift:470`), which asks every provider.
- **Condition:** any typed absolute path with a component that ends like an archive.
- **Main-thread callers in my scope:**
  - `ArchiveCommands.pack` at `P/Archives/ArchiveCommands.swift:265`. The proposed target always ends in `.zip`, so Pack with the target panel on a stalled mount hangs main right after OK.
  - `unpack` at `:343`.
  - `ClipboardPlugin.saveDetails` at `P/Clipboard/ClipboardPlugin.swift:249`.
  - `FileTools.folder(from:)` at `P/FileTools/FileToolsPlugin.swift:109` and `:280`.
  - `NetworkCommands.askForList` at `P/Network/NetworkCommands.swift:316`.
  - `VirtualFoldersPlugin.loadList` at `P/VirtualFolders/VirtualFoldersPlugin.swift:157`.
- **Callers outside my scope:** Navigation (cd), Places, Selection, FolderTabs, CommandRunner, Sync and Compare call the same registry method; I did not check which thread they use.
- **Duration:** µs normally; the mount timeout on a stalled volume.
- **Fix:** make `location(from:)` text-only (decide by extension) and verify "is a regular file" in the job or the listing. Alternatively resolve targets inside `makeJob`, as `FileOperations.transfer` already does.

**F4 — high, scaling, confirmed (durations estimated from the measured 0.64 µs per `locationKey`): O(list) work on main in VirtualFileSystem**
- **Registering a list:** `register(files:)` → `unique()` at `P/VirtualFolders/VirtualFileSystem.swift:134-138` builds a `locationKey`, a `[UInt8]` and a Set insert per URL, then filters by scheme at `:122-123`.
  - Entry points: `VirtualFoldersPlugin.show` (`P/VirtualFolders/VirtualFoldersPlugin.swift:91-95`), called by Find Files "feed to listbox" and by the `loadList` completion; and `enter(selectedOnly:)` at `:117-121`.
  - Estimate: 2–4 s for 2M results; about 0.4 s plus `operands()` for 300k marked.
- **Watching a list:** `watch()` at `:456-459` does `parent(of:)` plus `locationKey` for every entry, on main, on every location change of either panel while a list is shown (the coordinator rebuilds all watchers). Estimate: 3–5 s per navigation with a 2M list.
- **Leaving a picked branch:** `leave()` at `P/VirtualFolders/VirtualFoldersPlugin.swift:143` maps `lastPathComponent` over the list, about 0.3 s at 300k.
- **Fix:** dedupe when the list is produced, off main. Store the unique parent folders (capped at `watchLimit`) with the list at registration, so `watch()` is O(512).

**F4b — thread-safety, confirmed: watcher callback delivered off main**
- **Where:** `Coalescer.settle()` at `P/VirtualFolders/VirtualFileSystem.swift:510-518`.
- **What happens:** it calls `fire()` from a global queue, so `onChange` reaches `PanelCoordinator.reloadChangedPanels` and then `panel.reload` on a background thread. The protocol promises main.
- **Fix:** hop to main in `settle`.

**F5 — high, scaling: bulk operations on 300k marked items**
- **Cut / Copy to clipboard:** `place()` at `P/Clipboard/ClipboardPlugin.swift:130-134` calls `writeObjects` with one NSURL per item. Measured 3.2 s for 100k and linear (about 32 µs per URL), so about 9.6 s for 300k, plus `operands()`. Fix: cap the count or ask first; build one pasteboard item with a file-list type; at minimum show progress.
- **Paste of 100k URLs:** `files()` → `readObjects` at `:142`, measured 1.1 s. The `isSameLocation` filter at `:158` measured 139 ms. The transfer completion at `P/FileOperations/FileOperationsPlugin.swift:362-364` adds about 0.1–0.2 s (estimate).
- **Verify Checksums (toolbar button) on ordinary files:** `P/FileTools/FileToolsPlugin.swift:291-303`.
  - `isChecksumFile` builds a `FileMask` per item: measured 286 ms.
  - `checksumInName` compiles an `NSRegularExpression` per item (`P/FileTools/ChecksumFiles.swift:429-433`): measured 773 ms.
  - Total with `operands()` about 1.3–1.5 s, before the "Please select only…" alert.
  - It also reads the general pasteboard string on main at `:297`; that blocks if the clipboard owner supplies the text lazily and is slow.
  - Fix: hoist the mask and the regex out of the loop; do the classification in the job.
- **Copy / Move / Delete:**
  - Start: `operands()` only, up to 441 ms. `delete` adds `items.allSatisfy { capabilities(for:) }` (`P/FileOperations/FileOperationsPlugin.swift:327`), about 35–50 ms on local files. Inside a zip or a list every call takes locks and parses a URL: estimated 1–1.5 s, and F2 applies.
  - Completion: `names(of:among:)` at `:202-208` measured 387 ms; `model.deselect` measured 97 ms. About 0.5 s in one main-queue block.
  - Fix: compute the names on the job thread before returning; the completion then only applies a ready set.
- **Pack completion:** `Set<URL>` plus `contains` at `P/Archives/ArchiveCommands.swift:299-302`, measured 183 ms, plus deselect.
- **Change Attributes and Create Link completions:** `P/FileProperties/FilePropertiesPlugin.swift:128-131` and `:373-375`. The closest measurement is 280 ms for `parentPaths` at 300k; the extra `locationKey` per item puts these at an estimated 0.3–0.5 s.
- **Create separate checksum files:** `P/FileTools/FileToolsPlugin.swift:283` passes up to 300k folders to `panels.refresh`, which compares each against both panels. Estimated 0.8 s or more.
- **Add to Download List:** `displayPath` per item on main at `P/Network/NetworkCommands.swift:327-330`. Estimated 0.5–1.5 s for 300k remote items.
- **Copy Path of Each File:** measured 280 ms. **Copy Names with Path:** measured 88 ms. Both plus `operands()`, then `setString` of 20 MB or more (estimated tens of ms; 100 MB measured 16 ms).

**F6 — medium, blocking-call, confirmed: `LocalFileSystem.places()` can wait 1 s on main per call**
- **Where:** `P/LocalFileSystem/LocalFileSystem.swift:670-675`.
- **Mechanism:** it waits up to 1 s on the condition while `knownPlaces == nil`. The comment assumes only the first call waits. If the first background `readPlaces()` (`mountedVolumeURLs` with resource values, `:733-735`) is stuck on a dead mount present at launch, `knownPlaces` stays nil.
- **Callers:** `DriveBarView.rebuild` (`AFMShell/Window/ButtonBarView.swift:192`) and `PanelViewController.swift:916`. Each call blocks a full second for as long as the read is stuck.
- **Fix:** wait only once (set a "waited" flag), or seed `knownPlaces` with `fixedPlaces()` in `init`.

**F7 — medium to high, blocking-call, quit only, confirmed: plugins write synchronously in `stop()`**
- **Path:** `applicationWillTerminate` → `kernel.shutdown()` on main.
- **What blocks:**
  - `ArchivesPlugin.stop` → `store.flushAll()` (`P/Archives/ArchivesPlugin.swift:95-96`). It rewrites or uploads every archive with pending changes. Rewrites are delayed up to 60 s by `idleDelay`, so a multi-GB ZIP edited shortly before Cmd-Q can freeze for seconds to minutes; unbounded on a stalled mount.
  - `FileOperationsPlugin.stop` → `OperationLog.flush()`, a `queue.sync` at `P/FileOperations/OperationLog.swift:101-106`; blocks if the log file is on a stalled volume.
  - `NetworkPlugin.stop` → `disconnectAll` → `QUIT` with a 2 s write timeout per idle FTP connection (`P/Network/FTPConnection.swift:264`) and up to 0.5 s per SFTP channel.
- **Fix:** do this in `applicationShouldTerminate` with `.terminateLater`, a background flush and a progress sheet.

**F8 — medium, blocking-call, plausible: Keychain on main**
- **Where:** `SecItemCopyMatching`, `SecItemDelete` and `SecItemAdd` in `P/Network/SavedConnections.swift:26-42`.
- **Callers on main:** `NetworkCommands.edit` and `showConnections` (password lookup when the editor opens, set on OK, copy on duplicate), the Disconnect "save?" path, and `askCredentials` inside `askUser`.
- **Duration:** normally 5–50 ms; unbounded while securityd shows an unlock or permission prompt.
- **Sound part:** the login path reads the password on the connecting thread.
- **Fix:** run Keychain calls in a job or on a utility queue.

**F9 — medium, modal/scaling, plausible: unbounded text in an alert**
- **Where:** `P/FileProperties/FilePropertiesPlugin.swift:371` joins every Create Link failure into one `ui.inform` detail.
- **Trigger:** links into a read-only target for 300k items give 300k lines (the join itself measured 11 ms). NSAlert must then lay out about 20 MB of text; estimated several seconds or more inside a modal.
- **Same pattern, usually small:** `ListRun` skipped lines at `P/Network/NetworkCommands.swift:441`. That method also recurses once per unsupported line (`:450`), so a very long list of unsupported lines risks a stack overflow.
- **Fix:** cap at about 20 lines plus "… and N more", as `FileJob` and `ArchiveCommands.summary` already do.

**F10 — low, scaling**
- **countDirectoryContents enabled closure** (`P/FileProperties/FilePropertiesPlugin.swift:56`): `items.contains(where: \.isFolder)` scans all 1M items when the folder holds only files. Estimated 2–5 ms per evaluation, on every Files-menu or context-menu validation. Fix: keep a folder count in `PanelModel.totals`.
- **`model.selection.count > 1`** at `P/FileOperations/FileOperationsPlugin.swift:71` and `P/FileProperties/FilePropertiesPlugin.swift:206`, and `model.selection` in `unpack` (`P/Archives/ArchiveCommands.swift:320`): builds a `Set<String>` of all marks, measured 22 ms at 300k. Use `selectionCount`.
- **`nameContext`** (`P/FileOperations/FileOperationsPlugin.swift:480`): reads the pasteboard string on main when the typed name contains `[X`.
- **`verify` completion** (`P/FileTools/FileToolsPlugin.swift:314-318`): `report.text` and `setSelection(names:)` are O(rows) on main; low to medium for a checksum file with about 1M lines.

## (c) Verified sound
- **Progress reporting:** `FileJob` throttles at the source (`progressInterval = 0.04` at `FileOperationsPlugin.swift:185`, enforced at `FileJob.swift:1472-1474`), so at most 25 reports/s regardless of worker count. `ToolRun.advance` allows at most 20/s with a try-lock; forced reports are per part or phase, not per block. Archive testing ticks at 10 Hz. The failures list is capped at 20. How `monitor.report` reaches main is the shell's side.
- **Questions from jobs:** all go through `monitor.ask` or `kernel.askUser`, one modal at a time and user-driven. Compare-contents hashing runs on the job thread between dialogs. The archive failure alert is shown once per distinct message.
- **Transfer setup:** `TargetSpec.parse`, `FileJob` construction, target-folder creation and the per-item URL mapping all run inside `makeJob` on the job thread. The dialog texts are O(1) (`"Copy N file(s) to"`), with no joining of names.
- **Operation log:** writes go to its own queue in 0.25 s bursts; `flushSoon` is asynchronous.
- **DirectoryWatcher delivery:** FSEvents latency is 0.5 s, so 5,000 events/s arrive as about two callbacks per second. Sifting happens on the stream queue, and there is at most one `main.async` per callback, carrying at most the watched directories.
- **Network:** connect, list, mount, eject and disconnect all run in jobs or on a utility queue (`detach`). FTP and SFTP state locks are never held during I/O. `center.connected` and `capabilities(for:)` are short. There is no DNS on main.
- **FileProperties:** attribute reads, properties, space calculation, comment load/save and link creation run in jobs. Content columns (`LocalInfo`, `CommentStore`, whose `condition.wait` is at `Descript.swift:193`) are evaluated by the shell's `ColumnValueStore` on a utility queue, not main.
- **Archives:** entering and listing a 1M-entry archive runs in the background. The `Parallel.map` calls, semaphores, `Background.run` and `waitUntilExit` in `Codecs`, `Unpacker` and `FileJob` are all on job threads. The store's table lock is short.
- **Paste enabled closure:** looks at types only, never data.

## (d) Not covered
- Bodies of `FileJob`, `Packer`, `Unpacker`, `ZipFormat`, `Tar`, `Codecs`, `Transcoding`, `Hashes`, `SplitCombine`, `SFTPChannel` and `NetStream` beyond their threading entry points; they run on job threads.
- The shell side: `ProgressJobService.report` and `ask`, `PanelModel.setComputedSizes` / `setSelected(names:)` / `deselect` redraw cost, the `SettingsStore` implementation (each `settings.flag` is a JSON decode; about 25 reads per transfer start), and the `ui.form` / `pickRow` implementations.
- No live test against a stalled mount or a hung pasteboard owner; F1–F3, F6 and F7 durations are from reading the code. Cross-process pasteboard costs may exceed the in-process figures measured.
- Other plugins' main-thread calls to `fileSystems.location(from:)` (F3 root cause) need checking by their reviewers.
