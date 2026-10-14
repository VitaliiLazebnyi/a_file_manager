# Review 2 — archives

Every item the reviewers, verifiers, stress runs and fuzzers reported for this area. `verdict` items are independent rulings on a finding and sit next to it by file. Status is filled in by the fix round.


## Findings and verdicts

### A001 [finding, critical] B4a: ArchiveFileSystem.location(from:) calls stat() on main for typed paths with an archive-looking component (Pack, Unpack, Clipboard, FileTools).
**Outcome:** fixed — see `status/archives.md`


- **Where:** Plugins/Archives/ArchiveFileSystem.swift:534-535; AFMKernel/FileSystem/FileSystemProvider.swift:470; Plugins/Archives/ArchiveCommands.swift:265; Plugins/Archives/ArchiveCommands.swift:343; Plugins/Clipboard/ClipboardPlugin.swift:249; Plugins/FileTools/FileToolsPlugin.swift:109; Plugins/FileTools/FileToolsPlugin.swift:280
- **Basis:** read (blocking call, confirmed)
- **Detail:** Reached from FileSystemRegistry.location(from:relativeTo:). Confirmed for Pack (the proposed target always ends in .zip), Unpack, Clipboard and FileTools. Critical on a stalled mount.
- **Proposed fix:** Decide by text; verify in the job.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### A002 [finding, critical] ArchiveFileSystem.location(from:) calls stat() and is reached from the main thread by many callers (critical under a dead mount).
**Outcome:** duplicate of A001 — see `status/archives.md`


- **Where:** Plugins/Archives/ArchiveFileSystem.swift:534-535; AFMKernel/FileSystem/FileSystemProvider.swift:470; Plugins/Archives/ArchiveCommands.swift:265; Plugins/Archives/ArchiveCommands.swift:343; Plugins/Clipboard/ClipboardPlugin.swift:249; Plugins/FileTools/FileToolsPlugin.swift:109; Plugins/FileTools/FileToolsPlugin.swift:280; Plugins/Network/NetworkCommands.swift:316; Plugins/VirtualFolders/VirtualFoldersPlugin.swift:157
- **Basis:** read (reported as confirmed)
- **Detail:** Reached from FileSystemRegistry.location(from:relativeTo:), which asks every provider. Condition: any typed absolute path with a component that ends like an archive. Main-thread callers in scope: ArchiveCommands.pack (:265; the proposed target always ends in .zip, so Pack with the target panel on a stalled mount hangs main right after OK), unpack (:343), ClipboardPlugin.saveDetails (:249), FileTools.folder(from:) (:109 and :280), NetworkCommands.askForList (:316), VirtualFoldersPlugin.loadList (:157). Callers outside scope: Navigation (cd), Places, Selection, FolderTabs, CommandRunner, Sync and Compare call the same registry method; their thread was not checked. Duration: microseconds normally; the mount timeout on a stalled volume.
- **Proposed fix:** Make location(from:) text-only (decide by extension) and verify 'is a regular file' in the job or the listing. Alternatively resolve targets inside makeJob, as FileOperations.transfer already does.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### A003 [finding, critical] B2: OpenArchive.capabilities takes a lock that background threads hold across I/O, blocking main from the validation tick/menu.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Plugins/Archives/OpenArchive.swift:695-696; Plugins/FileOperations/FileOperationsPlugin.swift:43-45; Plugins/Archives/ArchiveFileSystem.swift:458-463; Plugins/Archives/ArchiveFileSystem.swift:476-483; Plugins/Archives/ArchiveFileSystem.swift:1313; Plugins/Archives/ArchiveFileSystem.swift:1105
- **Basis:** read (blocking lock, confirmed)
- **Detail:** Path: validation tick or menu -> any isWritable closure -> FileSystemRegistry.capabilities(for:) -> ArchiveFileSystem. The lock is held during a stat (:476-483), a rename, a central-directory reload (:1313) and a sort of all entries (:1105). Trigger: a panel inside a ZIP on a stalled mount (30-600 s on the next tick), or a 1M-entry ZIP being flushed or re-read (estimated 0.5 s to several seconds).
- **Proposed fix:** Publish capabilities as a lock-free snapshot; move the stat, rename and reload out of the lock.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### A004 [finding, critical] OpenArchive.capabilities takes a lock held across syscalls and O(n) work, so every isWritable validation can block main (lock).
**Outcome:** duplicate of A003 — see `status/archives.md`


- **Where:** Plugins/Archives/OpenArchive.swift:695-696; Plugins/FileOperations/FileOperationsPlugin.swift:43; Plugins/Archives/ArchiveFileSystem.swift:458-463; Plugins/Archives/OpenArchive.swift:476-483; Plugins/Archives/OpenArchive.swift:1268-1280; Plugins/Archives/OpenArchive.swift:1313; Plugins/Archives/OpenArchive.swift:1105; Plugins/Archives/OpenArchive.swift:843-851
- **Basis:** read (reported as confirmed)
- **Detail:** Path: validation tick or menu open -> any isWritable closure -> FileSystemRegistry.capabilities(for:) -> ArchiveFileSystem.capabilities(for:) -> OpenArchive.capabilities -> locked {}. Background holders: isCurrent() (:476-483) does FileSignature.of(localURL.path) (a stat) under the lock; install (:1268-1280) does a stat and a rename under it; rebase (:1313) re-reads the whole central directory (load()) under it; takeSnapshot (:1105) sorts all entries under it; finishWrite (:843-851) calls environment.hasRoom (a volume query) under it. Trigger and duration: a panel inside a ZIP on a stalled mount: 30-600 s on the next tick; a 1M-entry ZIP during a flush or a re-read after an external change: estimated 0.5-several s per occurrence. VirtualFileSystem inherits this for a branch of a zip.
- **Proposed fix:** Publish capabilities as a lock-free atomic snapshot, updated wherever format, hasDuplicates or fetchedCopy change. Move the stat, rename and load out of the lock.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### A005 [finding, critical] Write outside the target folder: names split on Character so '/' + combining mark hides the separator (archives, decode, combine)
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/ArchiveTree.swift:82; Sources/Plugins/FileTools/Transcoding.swift:520; Sources/Plugins/FileTools/SplitCombine.swift:242
- **Basis:** reproduced
- **Detail:** Names are split on Character. A '/' followed by a combining mark is one Character, so the separator is not seen and a leading '..' survives; result is one file written into the parent of the target. Found by a hand-made name after a related mismatch pointed at it, not by mutation runs. Unpacking is a user action so 'high' by the rule; ranked critical as the outside-write case. Reproducers: repro/arch/containment-slash-combining-mark.zip (fuzz-arch, target zip); .tar (target tar); repro/tools/decode-containment-slash-combining-mark.bin (fuzz-tools, decode); repro/tools/combine-containment-slash-combining-mark.crc (fuzz-tools, combine). Same class without a write: RemotePath.normalized in Sources/Plugins/Network/ServerAddress.swift:65 (repro/net/remotepath-slash-joins-combining-mark.bin, fuzz-net, target address).
- **Proposed fix:** Split and compare on UTF-8 bytes as RemoteEntry.isSafeName already does, and verify the final URL lies below the target.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### A006 [finding, high] Deadlock at quit: archive flush timer holding flushLock against ArchivesPlugin.stop() on main (lock plus main.sync cycle L5 -> MAIN -> L5).
**Outcome:** fixed — see `status/archives.md`


- **Where:** Archives/OpenArchive.swift:752; Archives/OpenArchive.swift:1045; Archives/OpenArchive.swift:1362; Archives/OpenArchive.swift:1373; Archives/OpenArchive.swift:1379; Network/FTPSession.swift:133; Network/FTPSession.swift:163; Network/FTPSession.swift:169; Network/SFTPSession.swift:119; AFMKernel/PluginAPI/Kernel.swift:102; AFMShell/App/Shell.swift:109; Archives/ArchivesPlugin.swift:96
- **Basis:** read
- **Detail:** Timer path (reviewer): OpenArchive.timerFired -> flush takes flushLock -> upload -> outer provider write/move/item. If the outer provider is FTP or SFTP and needs a new connection, it reaches askCredentials/askToTrust/askSecret -> Kernel.askUser -> DispatchQueue.main.sync. Main path: applicationWillTerminate -> Kernel.shutdown -> ArchivesPlugin.stop -> flushAll -> flush -> flushLock.lock(). The timer holds flushLock, main blocks on it, then the connection asks. applicationShouldTerminate drains only the job queue; the timer is not a job. Both halves read; the write path into the ask sites was not traced line by line.
- **Proposed fix:** Never take flushLock on main. Flush in applicationShouldTerminate (.terminateLater) on a background thread with a cancellable flag and a 'Saving archives...' sheet, and add a shutdown flag that timer flushes honour.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### A007 [finding, high] Pack completion builds Set<URL> and runs contains on main (183 ms) plus deselect.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Plugins/Archives/ArchiveCommands.swift:299-302
- **Basis:** measured
- **Detail:** 
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### A008 [finding, high] Archives stop() flushes every archive synchronously on main at quit (seconds to minutes; unbounded on a stalled mount).
**Outcome:** duplicate of A006 — see `status/archives.md`


- **Where:** Plugins/Archives/ArchivesPlugin.swift:95-96
- **Basis:** read (reported as confirmed)
- **Detail:** Reported medium to high; blocking call, quit only. Path: applicationWillTerminate -> kernel.shutdown() on main -> ArchivesPlugin.stop -> store.flushAll(). Rewrites or uploads every archive with pending changes. Rewrites are delayed up to 60 s by idleDelay, so a multi-GB ZIP edited shortly before Cmd-Q can freeze for seconds to minutes.
- **Proposed fix:** Do this in applicationShouldTerminate with .terminateLater, a background flush and a progress sheet.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### A009 [finding, high] ArchivesPlugin.stop() runs a synchronous, uncancellable whole-archive rewrite or upload on main at quit.
**Outcome:** duplicate of A006 — see `status/archives.md`


- **Where:** Plugins/Archives/ArchivesPlugin.swift:96; Plugins/Archives/ArchiveFileSystem.swift:182
- **Basis:** read
- **Detail:** flushAll -> L2, L4, then flush() -> L5. rescueAll -> L5/L4. reportFailure (:107) asks directly, since already on main. store.close() runs archive deinits and a recursive scratch delete on main. flushAll and close deliberately never touch L3.
- **Proposed fix:** See BUG 1 fix.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A010 [finding, high] Deadlock at quit: main blocks on flushLock (L5) while a timer thread holding L5 uploads to a network provider and asks the user via main.sync (BUG 1).
**Outcome:** duplicate of A006 — see `status/archives.md`


- **Where:** Plugins/Archives/OpenArchive.swift:752,1045,1361-1362,1373,1379; Plugins/Archives/ArchiveFileSystem.swift:185; AFMShell/Shell.swift:103-105; Plugins/Network/NetworkCommands.swift:44-78
- **Basis:** read (in-scope paths confirmed; network side partly traced)
- **Detail:** Archive on a network provider. Path T (GCD utility): timerFired :752 -> flush :1045 takes L5 -> upload :1362 provider.write(temporary...) (or :1373 move, :1379 item) -> the network connection asks -> Kernel.askUser -> DispatchQueue.main.sync. Path M (main): applicationWillTerminate -> Kernel.shutdown -> stop() :97 -> flushAll ArchiveFileSystem.swift:185 -> flush :1045 -> flushLock.lock(). Interleaving: M blocks on L5 first, then T's connection asks. applicationShouldTerminate cancels jobs only (Shell.swift:103-105); the timer is not a job. Both in-scope paths read; the network side is confirmed only as far as environment.askCredentials/askToTrust/askSecret -> kernel.askUser (NetworkCommands.swift:44-78); not traced into the provider's write path. Even without a question, M freezes for the whole rewrite or upload: upload makes a private CancellationFlag() (:1361) that nobody can set.
- **Proposed fix:** Never take L5 on main. Run stop()'s flush on a background thread with a cancellable flag while main pumps a modal 'Saving archives...' sheet, or flush in applicationShouldTerminate before replying. Give OpenArchive a shutdown flag that timer flushes honour.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A011 [finding, high] Quit can silently drop changes to nested or remote archives (flushAll makes one pass).
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/ArchiveFileSystem.swift:182-188; Sources/Plugins/Archives/ArchivesPlugin.swift:96-110
- **Basis:** read
- **Detail:** flushAll makes one pass over opened.values in dictionary order. Flushing an inner archive uploads into its outer archive, giving the outer new pending changes. If the outer was visited first nothing flushes it again, failures is empty, no rescue runs, and store.close() deletes the spools. Trigger: copy a file into outer.zip/inner.zip and quit within the idle delay (up to 60 s for the outer, since replacing the inner counts as a removal). Data loss.
- **Proposed fix:** Repeat until no archive has pending changes (bounded passes), or flush deepest first; run the rescue for anything still pending.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A012 [verdict, high] flushAll single pass loses edits in nested archives at quit
**Outcome:** duplicate of A011 — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/ArchiveFileSystem.swift:182-188; Sources/Plugins/Archives/OpenArchive.swift:1356-1384; Sources/Plugins/Archives/ArchivesPlugin.swift:96-111
- **Basis:** CONFIRMED (ran)
- **Detail:** Iterates a dictionary once. Flushing the inner archive uploads into the outer one making the outer pending again. ArchivesPlugin.stop() calls it once then store.close(). Run: with a 600 KB inner archive the change was lost in 5 of 10 runs; with a tiny inner archive 0 of 10 (immediate-write path covers it). Edit inside a nested ZIP dropped at quit with no message. Project's own test calls flushAll() twice. Server-side variant not run (same upload path).
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### A013 [finding, high] One deep path in an archive exhausts memory on Enter (quadratic ArchiveTree.insert).
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/ArchiveTree.swift:132-157; Sources/Plugins/Archives/ArchiveTree.swift:70-72, 81-84; Sources/Plugins/Archives/Tar.swift:229-231, 260
- **Basis:** reproduced
- **Detail:** insert walks up the parents and each step allocates a new full-length parent string kept as a dictionary key and entry path; cost and retained memory are quadratic in path length. One ZIP entry with a 65,533-byte name a/a/a/... creates 32,768 implicit folders; in a replica of the tree key handling this retained 1.07 GB of key bytes (1.2 GB RSS) and took 4.9 s. Twenty such entries fit in a ~2.6 MB ZIP. A pax path record may be 16 MB (about 8 million components) so a .tar.gz of a few tens of KB never finishes, and the loop has no cancellation check. Security (DoS).
- **Proposed fix:** Reject paths over about 4 KB or 256 components before inserting; store children as nodes rather than full-path keys; check the interrupt inside indexing.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A014 [finding, high] Quit blocks the main thread on archive writes (flushAll on main, uncancellable).
**Outcome:** duplicate of A006 — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/ArchivesPlugin.swift:96-98; Sources/Plugins/Archives/OpenArchive.swift:1044-1046; Sources/Plugins/Archives/OpenArchive.swift:1356-1362
- **Basis:** read
- **Detail:** applicationWillTerminate calls kernel.shutdown() which calls stop() which runs flushAll() on the main thread: whole-archive rewrites and uploads with no progress and no cancellation (upload creates a flag nobody can set). Also waits on flushLock behind any timer flush in progress, as does rescue(). Trigger: quit while a multi-GB rewrite is pending, or with an unresponsive server. Possible hard deadlock (plausible, depends on remote provider): a background flush holding flushLock whose provider calls kernel.askUser (a main.sync) deadlocks against the main thread waiting in flushAll.
- **Proposed fix:** Flush from applicationShouldTerminate via .terminateLater on a background thread with a progress window and cancellation flag; acquire flushLock with lock(before:).
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A015 [finding, high] capabilities(for:) on the main thread takes the archive lock, which is held across disk I/O and O(n log n) work.
**Outcome:** duplicate of A003 — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:695-700; Sources/AFMShell/Panel/PanelViewController+Interaction.swift:297
- **Basis:** read
- **Detail:** Same lock held during: isCurrent() stat (481-484); requireEditable() two access() calls or another provider capabilities (681-689); clones() clonefile + unlink (768-779); finishWrite statfs and possibly a volume resource query (842-850); takeSnapshot full sort and copy of all entries (1104-1138); install stat, open, rename and a walk over all entries (1267-1307); rebase re-reading and parsing the whole directory (1312-1352). Trigger: archive on a stalled SMB/NFS mount where a background stat holds the lock until the mount times out; or a 1M-entry ZIP during snapshot or rebase. Freeze.
- **Proposed fix:** Keep capability inputs (editable, hasDuplicates, fetched) in a separate tiny lock or atomic updated at load/rebase; move all syscalls out of the directory lock.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A016 [verdict, high] Deleting a member the running flush is writing for the first time is lost
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:789-799; Sources/Plugins/Archives/OpenArchive.swift:1115-1134; Sources/Plugins/Archives/OpenArchive.swift:1287-1304
- **Basis:** CONFIRMED (ran with hook) for this case
- **Detail:** take counts a removal only when record.isInArchive. Lost: a member the running flush is writing for the first time; after a further flushAll the file still listed t/new.txt, member gone from memory, nothing pending; reappears on reopening.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### A017 [finding, high] A deletion made while a flush is building never reaches the disk.
**Outcome:** duplicate of A016 — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:789-799; Sources/Plugins/Archives/OpenArchive.swift:1287-1304; Sources/Plugins/Archives/OpenArchive.swift:1130-1134
- **Basis:** read
- **Detail:** take counts a removal only if the record is already in the archive. A member that is still a spool when the snapshot is taken, then removed during the build, is written into the new file. install skips it because it is gone from the tree, and the next snapshot finds no work and marks everything written. Trigger: add files to a large ZIP, then delete one while the rewrite runs (minutes for big archives); the file stays in the archive on disk and reappears after a restart. A job .afm-<UUID>.tmp member discarded during a flush persists the same way. Correctness/privacy.
- **Proposed fix:** In install, for every snapshot entry that was written but is no longer in the tree, increment removals.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A018 [finding, high] Pack into a ZIP on a server or inside another archive deletes the old member on failure and ignores Encrypt.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/Packer.swift:488-514 (esp. 496, 503-507)
- **Basis:** read
- **Detail:** Data loss: the existing member is removed before the replacement is written; on a read error or Cancel the handler flushes, making the removal permanent with no replacement. Security: options.password and options.level are never used on this path; with Encrypt ticked members are stored in plain text and the verify pass succeeds because there is nothing to decrypt.
- **Proposed fix:** Write under a temporary name and move(replacing: true) on success; refuse or implement encryption on this path.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A019 [verdict, high] Pack into a server-side or nested ZIP ignores Encrypt
**Outcome:** duplicate of A018 — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/Packer.swift:488-514; Sources/Plugins/Archives/Packer.swift:304-305
- **Basis:** CONFIRMED (ran)
- **Detail:** Packing with password = 'pw' into mem:/store/s.zip gave members readable with unzip -p without a password; local control was encrypted.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### A020 [verdict, high] Pack into server-side ZIP removes the old member first; cancel leaves the ZIP empty
**Outcome:** duplicate of A018 — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/Packer.swift:488-514; Sources/Plugins/Archives/Packer.swift:498-499
- **Basis:** CONFIRMED (ran); source-open failure from reading
- **Detail:** Cancelling while a replacement source was being read left the server ZIP empty; the catch block removes the path and flushes. Further, from reading: open.write(path) and blocks(of:) at 498-499 sit outside the do; a source that fails to open leaves the old member removed and the writer never closed.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### A021 [finding, medium] Race, possible data loss on Move into an archive: evict can detach archive X between ArchiveFileSystem.write resolving it and openWriters += 1.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Archives/ArchiveFileSystem.swift:386; Archives/ArchiveFileSystem.swift:158-166; Archives/ArchiveFileSystem.swift:197; Plugins/FileOperations/FileJob.swift:1144-1177
- **Basis:** read (confirmed by reviewer)
- **Detail:** Medium-high. Path A: ArchiveFileSystem.write resolves X with Slot.lock released, then calls X.write. Path B: evict sees X.isBusy == false and removes X from the store. If B runs between A's resolve and A's openWriters += 1, X is detached holding pending changes. store.commit(url) finds nothing pending and returns success, and FileJob.flushDeferred then deletes the sources. At quit flushAll misses X and the scratch folder is deleted. Narrow window.
- **Proposed fix:** Retire an archive atomically under its own lock and have mutators re-resolve on a 'retired' error, or track busy archives in the store.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### A022 [finding, medium] Cancellation not wired through in Archives: Packer, Unpacker, ArchiveCommands, ArchiveFileSystem.read and timer/stop uploads use neither the flagged variant nor interrupting; Cancel hangs on a stalled server.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Archives/Packer.swift:272; Archives/Packer.swift:375; Archives/Unpacker.swift:370; Archives/ArchiveCommands.swift:147; Archives/ArchiveCommands.swift:177; Archives/ArchiveFileSystem.swift:351; Archives/OpenArchive.swift:1361
- **Basis:** read (reviewer)
- **Detail:** OpenArchive.swift:1361 uses a private flag nobody can set.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### A023 [finding, medium] 'Encrypt (ZIP only)' uses broken ZipCrypto with no warning; AES archives cannot be read either.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Plugins/Archives/ArchiveCommands.swift:234; Plugins/Archives/ArchiveCommands.swift:258-261; Plugins/Archives/ArchiveCommands.swift:309; Plugins/Archives/Packer.swift:36-41; Plugins/Archives/Packer.swift:84; Plugins/Archives/ZipFormat.swift:253-255; Plugins/Archives/OpenArchive.swift:623
- **Basis:** read (confirmed)
- **Detail:** Dialog detail is empty; ZipFormat comments 'It is weak'. The user believes the archive is protected; known-plaintext attacks recover the keys in minutes.
- **Proposed fix:** Implement WinZip AES-256 (CommonCrypto), or label the option 'legacy, weak encryption' in the dialog.
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### A024 [finding, medium] Store eviction races with a writer: an archive can be detached after resolve and get pending changes that commit/flushAll never see (BUG 2; silent no-op commit, possible data loss on move).
**Outcome:** duplicate of A021 — see `status/archives.md`


- **Where:** Plugins/Archives/ArchiveFileSystem.swift:155-157,58,65,386,158-166,70,197,214; Plugins/Archives/OpenArchive.swift:825; FileOperations/FileJob.swift:1155
- **Basis:** read (confirmed by reading both paths)
- **Detail:** Reported Medium-Low, narrow window. The comment at ArchiveFileSystem.swift:155-157 ('nobody can start a change between the look and the removal') is false: archive(at:) returns the archive after L3 is released (:58, :65). Path A: ArchiveFileSystem.write :386 resolve -> archive X returned, then X.write(path) (OpenArchive.swift:825). Path B: evict :158-166 sees X.isBusy == false and removes X from slots/opened; the same happens at :70 when isCurrent() is false. Interleaving: B runs between A's resolve and A's openWriters += 1. Result: X is detached and gets pending changes. store.commit(url) :197 finds nil, or a second OpenArchive with nothing pending, and returns success. A mover (FileJob.swift:1155) then deletes its sources. flushAll at quit misses X and the scratch delete removes its spools. Only X's own timer can still save the data.
- **Proposed fix:** Retire atomically: under X's L4, retireIfIdle() sets retired only if not busy; mutators throw a 'retired' error so ArchiveFileSystem re-resolves. Alternatively keep a store-level set of busy archives that the archive joins in changed()/write(), and have commit/flushAll iterate that.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A025 [finding, medium] Cancel is unresponsive on stalled I/O: several consumers pass neither a flag nor an interrupting tie and only poll between blocks (BUG 3).
**Outcome:** duplicate of A022 — see `status/archives.md`


- **Where:** Plugins/Archives/Packer.swift:272; Plugins/Archives/Packer.swift:375; Plugins/Archives/Unpacker.swift:370; Plugins/Archives/ArchiveCommands.swift:147; Plugins/Archives/ArchiveCommands.swift:177; Plugins/Archives/ArchiveFileSystem.swift:351; Plugins/Archives/OpenArchive.swift:1361
- **Basis:** read
- **Detail:** Affected: Packer.blocks (provider.read(item.url)), Packer.build, Unpacker.write, unpackAndOpen, openAsArchive, ArchiveFileSystem.read(_:) (opens a .member behind a long decompression with no way to interrupt), and timer and stop uploads.
- **Proposed fix:** Use the cancellation variants plus monitor.cancellation.interrupting(...).
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A026 [finding, medium] Cancellation gaps: archive opens, flushLock and isCurrent are not cancellable.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/ArchiveCommands.swift:114, 355, 363, 414; Sources/Plugins/Archives/Packer.swift:489, 566; Sources/Plugins/Archives/ArchiveFileSystem.swift:494; Sources/Plugins/Archives/OpenArchive.swift:1045, 937, 491
- **Basis:** read
- **Detail:** store.archive(at:) is called without the job flag at those sites; a long open (bsdtar, bzip2, counting a .bz2 to its end) cannot be cancelled and waiters on the same slot block. flush() takes flushLock unconditionally (1045), so commit and the immediate write in move (937, no flag at all) wait behind a multi-minute timer rewrite. isCurrent() does an uncancellable remote item(at:) under the slot lock (491).
- **Proposed fix:** Thread the flag through; use lock(before:) polling; use flushLock.try() for the opportunistic write in move.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A027 [finding, medium] Orphaned archives are skipped at quit and their spool files deleted
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/ArchiveFileSystem.swift:184; Sources/Plugins/Archives/ArchiveFileSystem.swift:214
- **Basis:** read
- **Detail:** flushAll iterates only the table, then store.close() deletes the spool files of orphaned archives, so pending edits there are lost.
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

### A028 [verdict, medium] Archive eviction race: slot dropped while a writer is starting
**Outcome:** duplicate of A021 — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/ArchiveFileSystem.swift:58; Sources/Plugins/Archives/ArchiveFileSystem.swift:386; Sources/Plugins/Archives/ArchiveFileSystem.swift:395; Sources/Plugins/Archives/OpenArchive.swift:826-834; Sources/Plugins/Archives/ArchiveFileSystem.swift:155-166; Sources/Plugins/FileOperations/FileJob.swift:720-724; Sources/Plugins/FileOperations/FileJob.swift:837-862; Sources/Plugins/Archives/OpenArchive.swift:876; Sources/Plugins/DirectorySync/SyncPlan.swift:272; Sources/Plugins/DirectorySync/SyncPlan.swift:358; Sources/Plugins/Archives/ArchiveFileSystem.swift:197; Sources/Plugins/Archives/ArchiveFileSystem.swift:184; Sources/Plugins/Archives/OpenArchive.swift:1272-1274
- **Basis:** PARTLY CONFIRMED: race CONFIRMED (read); stated consequence REFUTED for file jobs; weaker variant in DirectorySync holds
- **Detail:** Race CONFIRMED: store.archive(at:) releases the slot lock on return; caller then takes the archive's own lock and sets openWriters += 1; in between evict can see isBusy == false and drop the slot (comment at 155-157 is wrong). Window a few instructions, needs at least 12 other archives open plus another thread opening one right then. Stated consequence REFUTED for file jobs: FileJob.put writes under a temp name then renames; rename resolves the archive again, gets a fresh OpenArchive from disk and fails 'not found' (OpenArchive:876); source kept. What does happen: spurious error on one file (Retry works) and the orphan's own timer later writes a stray .afm-<uuid>.tmp member into the ZIP. Weaker variant holds: DirectorySync writes directly under final name (SyncPlan:272, write at 358); commit succeeds as a no-op; data exists only in the orphan until its timer fires; if app quits first flushAll (line 184) skips orphans and store.close() deletes the spool; sync does not delete the source. Further double race: orphan and fresh archive check the file signature under different locks (OpenArchive:1272-1274) so one flush could overwrite the other.
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

### A029 [verdict, medium] Deep member path costs quadratic memory
**Outcome:** duplicate of A013 — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/ArchiveTree.swift:132-157; Sources/Plugins/Archives/Tar.swift:253-260
- **Basis:** CONFIRMED (ran at small scale)
- **Detail:** One implicit entry per ancestor, each with its own full-path string; no depth limit. Measured: depth 2000 +6 MB, 4000 +14 MB, 8000 +56 MB. A real 32 KB ZIP with one member 8000 folders deep cost +77 MB on open. Extrapolated not run: a 65,535-byte ZIP name allows ~32,767 levels, ~1 GB per member; TAR long names not bounded by the format.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### A030 [finding, medium] ".." filter bypass via combining characters (Character-based splitting).
**Outcome:** duplicate of A005 — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/ArchiveTree.swift:81-84; Sources/Plugins/Archives/Unpacker.swift:256
- **Basis:** reproduced
- **Detail:** Swift splits on Characters; / followed by a combining mark (U+0301, ZWJ, variation selectors) is a single Character not equal to /. The name ../\u{301}evil.txt normalises to itself and the unpack target becomes <folder>/../(combining)evil.txt. Limits: one level above the target and the file name must start with a combining mark. Reachable through Unpack; ordinary Copy fails to read such an item. Security.
- **Proposed fix:** Split on bytes (utf8, 0x2F) everywhere (normalized, name(of:), parent(of:), the Unpacker); reject NUL and control characters; assert the final target isInside the folder.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A031 [finding, medium] Child processes re-open the archive by path, so a replaced file returns member N of the new file under the old name.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/Codecs.swift:508; Sources/Plugins/Archives/OpenArchive.swift:270, 541-548
- **Basis:** inferred
- **Detail:** For bzip2 and bsdtar, members are found by index in a stream started from file.path. If the file is replaced while a job still holds entries of the old OpenArchive, member N of the new file is returned with no error. Nothing compares the header path or size with the entry. Plausible.
- **Proposed fix:** Give the child the already-open file (stdin; bsdtar ... @-) and verify header name and size on .member opens.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A032 [verdict, medium] Deadlock at quit between archive flush and credential prompt
**Outcome:** duplicate of A006 — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:1045; Sources/Plugins/Archives/OpenArchive.swift:1068; Sources/Plugins/Archives/OpenArchive.swift:1362; Sources/Plugins/Archives/OpenArchive.swift:470; Sources/Plugins/Network/FTPSession.swift:133; Sources/Plugins/Network/FTPSession.swift:137; Sources/Plugins/Network/FTPSession.swift:169; Sources/Plugins/Network/SFTPSession.swift:121; Sources/AFMKernel/PluginAPI/Kernel.swift:102; Sources/AFMShell/App/Shell.swift:112; Sources/Plugins/Archives/ArchivesPlugin.swift:97; Sources/Plugins/Archives/ArchiveFileSystem.swift:185
- **Basis:** CONFIRMED (read), narrow window
- **Detail:** flush() holds flushLock for its whole duration incl. upload(); upload() calls provider.write on the server file system; a (re)connect can ask a question via askCredentials/askToTrust/askSecret, which go through DispatchQueue.main.sync; main in applicationWillTerminate calls archive.flush() and waits on flushLock. Sequence: ZIP on FTP/SFTP with pending changes; flush timer thread in upload() needs a new connection; user quits, main blocks on flushLock; connection asks a question, timer thread blocks in main.sync. Narrow: question must be posted after main entered applicationWillTerminate (else a modal dialog is already up). NetworkPlugin.stop runs before ArchivesPlugin.stop and empties sessions, so a write after that builds a fresh session which asks if password not in Keychain. User sees beachball at quit, force quit needed, edit never reaches server.
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

### A033 [finding, medium] Members under temporary names can be persisted and remain in the archive.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:1116-1129; Sources/Plugins/Archives/ArchiveFileSystem.swift:182-198
- **Basis:** read
- **Detail:** Only the immediate write leaves out arriving members. The timer, another job commit, the store.flush calls of Unpack/Test/Pack, and flushAll at quit all write closed-but-unrenamed members under .afm-<UUID>.tmp. They remain if: the process exits or crashes before the rename; the job discards the temp member while a flush is building (finding 3); the writer landed in an orphaned OpenArchive (finding 24). Otherwise the later rename appends the data a second time and leaves dead space.
- **Proposed fix:** Never include arriving members in a flush unless the caller asks; at quit drop them; at load optionally hide or strip names matching the temp pattern.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A034 [finding, medium] Editing an archive reached through a symbolic link replaces the link.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:1170-1174, 1274
- **Basis:** inferred
- **Detail:** clonefile and stat follow the link but rename(temp, localURL.path) replaces the link itself with a new file; the real archive never changes. Plausible.
- **Proposed fix:** Resolve the last path component once at open and use the real path.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A035 [finding, medium] Nothing is synced before the rename though commit promises durability.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:1222; Sources/Plugins/Archives/OpenArchive.swift:1274; Sources/Plugins/Archives/Packer.swift:357-358, 422-423; Sources/Plugins/Archives/ByteStreams.swift:402-407
- **Basis:** inferred
- **Detail:** After a power loss the rename can be durable while the appended tail and new directory are not: a ZIP with no central directory, and Move or Move-to-archive has already deleted the sources. Plausible.
- **Proposed fix:** fsync (or F_BARRIERFSYNC) the temporary file before rename, at least on commit and Move-to-archive paths.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A036 [verdict, medium] No fsync anywhere in Archives
**Outcome:** duplicate of A035 — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:1273; Sources/Plugins/Archives/Packer.swift:358; Sources/Plugins/Archives/Packer.swift:423
- **Basis:** CONFIRMED (read); consequence not reproduced
- **Detail:** No fsync, F_FULLFSYNC or synchronize in Plugins/Archives. Power-loss consequence not reproduced.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### A037 [verdict, medium] Symlinked archive is replaced by a regular file on edit
**Outcome:** duplicate of A034 — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:1273; Sources/Plugins/Archives/Packer.swift:358; Sources/Plugins/Archives/Packer.swift:423
- **Basis:** CONFIRMED (ran)
- **Detail:** No path resolved through symlinks. After an in-archive edit through link.zip -> real/real.zip, link.zip was a regular file holding the change and real.zip unchanged. Packing into the link did the same.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### A038 [finding, medium] bsdtar accepts an mtree text file and reads local files it names.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:265-273; Sources/Plugins/Archives/ArchiveLocation.swift:245
- **Basis:** reproduced
- **Detail:** Anything not recognised becomes .foreign and is passed to bsdtar -cf - @file; libarchive mtree reader opens contents= paths. A text file named holiday.7z containing #mtree and "photo.jpg type=file contents=/path/to/secret" lists photo.jpg with the secret file bytes, read with the app privileges. A large local file is copied into scratch (up to 4 GB); a FIFO hangs the child until cancelled. Security.
- **Proposed fix:** Accept only known magic numbers for foreign formats (7z, Rar!, MSCF, xar!, cpio, ISO, LHA) before calling bsdtar; run with an empty working directory and minimal environment, ideally sandboxed to read only the archive.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A039 [finding, medium] Listing a foreign archive means full extraction through a pipe.
**Outcome:** not a defect — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:270, 355
- **Basis:** read
- **Detail:** Every open of a 7z/rar/iso decompresses all data just to see the headers. Above 256 MB nothing is kept, so each member read (or parked-reader miss) runs bsdtar from the start again.
- **Proposed fix:** Accept the trade-off knowingly, or list with libarchive directly.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A040 [finding, medium] Scratch disk exhaustion when entering stream archives or fetching remote/nested archives.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:34-36, 353-367, 391-412; Sources/Plugins/Archives/ArchiveFileSystem.swift:21, 122-134
- **Basis:** read
- **Detail:** Merely entering a stream archive of 256 MB or less writes up to 4 GB into scratch; twelve cached archives can hold 48 GB. No free-space check beforehand; a failed write is caught but the disk stays full until indexing ends. Fetching a remote or nested archive copies it whole with no size or space check; a nested member can declare any size.
- **Proposed fix:** A budget for total scratch use, a "keep N GB free" check before and during materialisation, and a hasRoom check against item.size before fetching.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A041 [finding, medium] Random-order reads of big stream archives are quadratic.
**Outcome:** fixed — see `status/fileops-p2.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:521-555
- **Basis:** inferred
- **Detail:** Only Unpacker uses readInOnePass. Ordinary Copy takes files in panel order. For a non-materialised archive (over 256 MB) that is uncorrelated with archive order, so each file decompresses a large fraction of the archive, with at most four parked readers. Plausible.
- **Proposed fix:** Materialise lazily when a second restart happens and space allows, or expose archive order or a batch API to the job.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A042 [finding, medium] Password prompt storm, and no serialisation of prompts.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:638-661; Sources/Plugins/Archives/Unpacker.swift:63-66, 316-329, 95-105
- **Basis:** read
- **Detail:** Every member whose check byte fails prompts up to three times. Parallel readers prompt concurrently. A refusal is not remembered. A ZIP with thousands of "encrypted" entries with differing check bytes makes Test or Unpack produce thousands of modal dialogs; only the job Cancel stops them. Related, low: Unpacker.run unlocks the whole archive even when the selection has no encrypted member.
- **Proposed fix:** One prompt gate per archive (re-check the cache after acquiring it); remember "declined" for the duration of the operation.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A043 [finding, medium] Utility-QoS work does not run for a minute or more when the cores are saturated (archive flush timer, column-value work).
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:714; Sources/Plugins/Archives/OpenArchive.swift:727
- **Basis:** inferred
- **Detail:** Evidence is the archive flush and column-value tests; QoS starvation as cause is inferred. Alternative for the archive tests is the min(60, 20 x lastRewriteDuration) idle delay at OpenArchive.swift:727.
- **Proposed fix:** Raise the flush timer's QoS after a deadline.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### A044 [finding, medium] Deferred writes are invisible to the rest of the app (archive stale if moved/copied during the idle window).
**Outcome:** fixed — see `status/fileops-p2.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:725-727
- **Basis:** inferred
- **Detail:** Deletions wait min(60, 20 x lastRewriteDuration) seconds. If the user moves, copies or uploads the archive file in another panel during that window the file is stale. A moved archive then fails with "changed by another program" forever, and the changes end up in a rescue ZIP at quit. Design data-loss risk, plausible.
- **Proposed fix:** Let the kernel ask providers to commit before a file that is an open archive is read, moved or deleted; show pending state in the panel.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A045 [finding, medium] Failed-flush retry rewrites the whole archive every 30 s forever.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:751-763
- **Basis:** read
- **Detail:** Deterministic failures (a damaged member copyMember rejects, an archive deleted or moved, a name too long) are retried at a fixed interval; each try may copy gigabytes to a temp file before failing.
- **Proposed fix:** Exponential back-off; do not retry failures that cannot heal until the next change.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A046 [finding, medium] Spools go to TMPDIR on the boot volume with no space check there.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:832-833, 842-850; Sources/Plugins/Archives/ByteStreams.swift:464-466
- **Basis:** read
- **Detail:** finishWrite checks room only at the archive folder. On a file system that cannot clone (exFAT, HFS+, SMB) immediate writes never happen, so a whole job compressed data accumulates in TMPDIR. Copying 200 GB into a ZIP on a USB drive needs 200 GB free on the boot disk and fails with "no space" although the destination has room.
- **Proposed fix:** Spool next to the archive when it is on another volume, or check scratch space and flush early.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A047 [finding, medium] Pack into an existing local ZIP bypasses OpenArchive: lost update and widened file mode.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/Packer.swift:298, 403-433, 349-358, 457
- **Basis:** read
- **Detail:** Lost update (plausible): appendToZip and writeZip read the directory at the start and rename at the end with no flushLock and no signature check; a flush or another program writing in between is overwritten. try? store.flush also ignores failure. Mode widened (confirmed by reading): the rewrite path creates the file 0644 and never applies the old mode, so a 0600 archive becomes world-readable.
- **Proposed fix:** Go through the open archive under its flushLock, or re-check FileSignature before the rename; chmod as OpenArchive.build does.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A048 [verdict, medium] Only ZIP encryption is the weak legacy cipher and the dialog does not warn
**Outcome:** duplicate of A023 — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/ZipFormat.swift:253-255; Sources/Plugins/Archives/ArchiveCommands.swift:234; Sources/Plugins/Archives/ArchiveCommands.swift:306-314
- **Basis:** CONFIRMED (read)
- **Detail:** Sole cipher; its comment calls it weak; dialog says only 'Encrypt (ZIP only)'. Precondition: someone obtains the archive. Medium for anyone relying on it.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### A049 [finding, medium] No cap on entry count; about 0.5-1 KB of memory per entry.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/ZipFormat.swift:462-499; Sources/Plugins/Archives/OpenArchive.swift:296-325; Sources/Plugins/Archives/ArchiveTree.swift
- **Basis:** inferred
- **Detail:** A .tgz of roughly 1 MB can hold a million empty members; larger ones tens of millions. Each entry carries an ArchiveEntry with an inline ZipRecord, three or four strings and a set element. Eviction is by count (12), not by memory. Per-entry figure is an estimate, not measured. Plausible.
- **Proposed fix:** Cap entries (a few million) with a clear error; consider a compact entry representation.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A050 [verdict, medium] Archive eviction race: stated consequence (data loss then deletion) for file jobs
**Outcome:** refuted — see `status/archives.md`


- **Where:** Sources/Plugins/FileOperations/FileJob.swift:720-724; Sources/Plugins/Archives/OpenArchive.swift:876
- **Basis:** REFUTED for file jobs
- **Detail:** FileJob.put writes under a temporary name and renames; the rename resolves the archive again, gets a fresh OpenArchive and fails 'not found'; source kept. A commit that succeeds without the data followed by deletion does not follow.
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

### A051 [finding, low] About 1.4 KB of memory per ZIP member (272 MB for 200k).
**Outcome:** fixed — see `status/archnet-p2.md`


- **Basis:** measured
- **Detail:** Relayed from fork.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### A052 [finding, low] ArchiveStore.archive(at:) slot lock made a main-thread item(at:) wait 418 ms during another thread's open.
**Outcome:** fixed — see `status/archives.md`


- **Basis:** measured
- **Detail:** No shell code was found calling it on main. Relayed from fork.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### A053 [finding, low] scratch.removeAll() is serialised with in-table archives through L5 in flushAll, but not with detached archives (BUG 2) or post-stop timers.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Plugins/Archives/ArchiveFileSystem.swift:214
- **Basis:** read
- **Detail:** 
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A054 [finding, low] capabilities(for:) on main can wait behind rebase/takeSnapshot/install/finishWrite on L4.
**Outcome:** duplicate of A003 — see `status/archives.md`


- **Where:** Plugins/Archives/ArchiveFileSystem.swift:458; Plugins/Archives/OpenArchive.swift:696
- **Basis:** read
- **Detail:** Takes L2 then L4, then the outer capabilities with nothing held. It never takes L5 or L3, so main cannot block behind a flush or a materialise, but it can wait behind rebase/takeSnapshot/install/finishWrite on L4.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A055 [finding, low] L3 (Slot.lock) is held across network round trips and whole opens, unbounded.
**Outcome:** not a defect — see `status/archives.md`


- **Where:** Plugins/Archives/ArchiveFileSystem.swift:52,56,58,61,65,72,75,103,119,124,130-133; Plugins/Archives/OpenArchive.swift:491,353-366
- **Basis:** read
- **Detail:** While held: archive.isCurrent() :65 -> L4 then (L4 released, L3 still held) fileSystems.item(at: archiveURL) on the outer provider (OpenArchive.swift:491), a network round trip at most once per second with no cancellation; open() :72: remote/nested archive provider.item :119, provider.read :124, the whole download :130-133; OpenArchive.init -> load: ZIP directory parse, or a full decompress/bsdtar pass (archives <= 256 MB are materialised into a temp TAR up to 4 GB, OpenArchive.swift:353-366; larger ones stream-indexed end to end); evict :75: try() on other slots -> isBusy -> L4; deinit of the replaced archive (inside setArchive, :103); any user prompt the outer provider raises. Other threads wanting the same archive wait the whole prompt (unbounded at :56 without a flag).
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A056 [finding, low] ArchiveFileSystem.location(from:) does stat on main for typed paths.
**Outcome:** duplicate of A001 — see `status/archives.md`


- **Where:** Plugins/Archives/ArchiveFileSystem.swift:523-543
- **Basis:** read
- **Detail:** Listed under ArchiveCommands on main.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A057 [finding, low] L3 is held across askUser; safe only because main never takes L3, so any main-thread item/list/read/quarantine on that archive would deadlock.
**Outcome:** not a defect — see `status/archives.md`


- **Where:** Plugins/Archives/ArchiveFileSystem.swift; Plugins/Archives/OpenArchive.swift:647; Plugins/Archives/ArchivesPlugin.swift:38; Plugins/Archives/ArchiveTree.swift:188,205,214,225
- **Basis:** read
- **Detail:** askPassword via ArchiveMemberReader init/read/seek holds no in-scope locks, except when the caller is ArchiveStore.open :124 reading an inner archive out of an encrypted outer ZIP: L3(inner) is held. Out-of-scope providers asking inside calls made from ArchiveStore.open :119/:124 and isCurrent OpenArchive.swift:491 hold L3.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A058 [finding, low] afm-archives-<pid>-... scratch (remote archive copies, unpacked members) is not swept after a crash (viewer and list folders are swept).
**Outcome:** fixed — see `status/archives.md`


- **Where:** Plugins/Archives/ByteStreams.swift:465
- **Basis:** read
- **Detail:** 
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### A059 [finding, low] Tool.filter uses two workers per bzip2 piece, about 2 x cores at once, possibly approaching GCD's blocked-thread limit on 24+ core machines.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Plugins/Archives/Codecs.swift:326-336
- **Basis:** inferred (speculation)
- **Detail:** Speculation.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A060 [finding, low] Whole-file read without cap: bsdtar/bzip2 stderr (a warning per bad entry can grow it).
**Outcome:** fixed — see `status/archives.md`


- **Where:** Plugins/Archives/Codecs.swift:375
- **Basis:** read
- **Detail:** 
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### A061 [finding, low] Stale flush timers hold self strongly; after stop(), a retry timer can run flush against a deleted scratch folder and then block its worker in main.sync until exit.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Plugins/Archives/OpenArchive.swift
- **Basis:** read
- **Detail:** The closure holds self strongly, so an evicted archive's timer still fires. Harmless for notify-only timers. After stop(), a retry timer can run flush against a deleted scratch folder; it fails cleanly (atomic rename) and then blocks its worker in main.sync until exit.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A062 [finding, low] Priority inversion: a userInitiated job in commit/move, or main in stop(), waits on L5 held by a utility-QoS worker.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Plugins/Archives/OpenArchive.swift
- **Basis:** read
- **Detail:** NSLock gives no priority donation.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A063 [finding, low] Deinit on main is possible for ArchiveMemberReader/OpenArchive when the last reference drops there; OpenArchive.deinit and ProcessStream.deinit run on arbitrary threads.
**Outcome:** not a defect — see `status/archives.md`


- **Where:** Plugins/Archives/OpenArchive.swift:230,1457
- **Basis:** read
- **Detail:** The reader's closure holds the archive strongly. Deinits only unlink and terminate; ZipMemberWriter.deinit takes L4 briefly.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A064 [finding, low] park schedules one 10 s asyncAfter per member read, so a 100k-member per-file copy out of a stream archive queues 100k blocks.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Plugins/Archives/OpenArchive.swift:571
- **Basis:** read
- **Detail:** Low.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A065 [finding, low] If the CRC failure handler clears the password mid-run, every pool thread prompts separately, up to 3 attempts each.
**Outcome:** duplicate of A042 — see `status/archives.md`


- **Where:** Plugins/Archives/OpenArchive.swift:668-671
- **Basis:** read
- **Detail:** Low.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A066 [finding, low] Timer flush occupies a utility worker for a whole rewrite/upload and then indefinitely in reportFailure's main.sync; busy archives are uncapped (capacity 12 applies to idle ones only).
**Outcome:** fixed — see `status/archives.md`


- **Where:** Plugins/Archives/OpenArchive.swift:714,729
- **Basis:** read
- **Detail:** GCD blocking / fan-out. One worker per failing archive.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A067 [finding, low] timerFired polls every flushDelay (0.5 s) while any writer is open.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Plugins/Archives/OpenArchive.swift:745
- **Basis:** read
- **Detail:** 
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A068 [finding, low] reportFailure from the flush timer keeps its utility worker blocked in main.sync until the dialog is dismissed.
**Outcome:** duplicate of A066 — see `status/archives.md`


- **Where:** Plugins/Archives/OpenArchive.swift:762; Plugins/Archives/ArchivesPlugin.swift:45
- **Basis:** read
- **Detail:** On GCD utility (timer), no in-scope locks held (L4 released :761, L5 released by flush defer). The worker stays blocked until the dialog is dismissed.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A069 [finding, low] armTimer is a no-op while a retry or idleDelay timer (up to 60 s) is armed, so commit/move notifications and 'retry when something else changes' can lag up to 60 s.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Plugins/Archives/OpenArchive.swift:955,1099,754
- **Basis:** read
- **Detail:** Minor.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A070 [finding, low] Background.run blocks one userInitiated worker per unpack/test job; ProcessStream blocks one default-QoS worker per live child, including parked readers (up to 4 per archive, 10 s each).
**Outcome:** not a defect — see `status/archives.md`


- **Where:** Plugins/Archives/Unpacker.swift:26-33; Plugins/Archives/Codecs.swift
- **Basis:** read
- **Detail:** GCD blocking / fan-out.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A071 [finding, low] item(at:) without a cancellation flag waits for another thread's open via the unconditional slot.lock.lock() in ArchiveStore.archive(at:).
**Outcome:** duplicate of A052 — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/ArchiveFileSystem.swift:40-57; Sources/Plugins/Archives/OpenArchive.swift:475
- **Basis:** measured
- **Detail:** Called on main 20 ms after another thread began opening the 200k archive, it returned after 418 ms. On an already open archive each call costs about 29 us and re-stats the archive file through isCurrent(). No shell code was found calling it on the main thread; this is what such a caller would wait.
- **Proposed fix:** Answer from the already-open archive without taking the slot lock, and rate-limit isCurrent() for local files as already done for remote ones.
- **Source:** reports/23-filejob-archives-stress.md
- **Status:** open

### A072 [finding, low] A writer can land in an archive the store has just dropped.
**Outcome:** duplicate of A021 — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/ArchiveFileSystem.swift:65-76, 147-171, 383-397
- **Basis:** inferred
- **Detail:** Between store.archive() returning and archive.write(), eviction or the not-current replacement can remove the archive from the table. Later rename and commit go to a new instance: the job fails loudly but the orphan flushes its temp-named member by itself. store.commit also returns success when no archive is in the table. Threading, plausible (narrow window).
- **Proposed fix:** A "detached" flag set under the archive lock that makes write throw or retry; register the writer under the slot lock.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A073 [finding, low] Cached open failures never expire for local files.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/ArchiveFileSystem.swift:66-69, 86
- **Basis:** read
- **Detail:** A transient error (ENOSPC in scratch, a killed child) is replayed until the archive signature changes or the slot is evicted.
- **Proposed fix:** Cache only format errors, with a time limit.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A074 [finding, low] ArchiveURL.make hex-encodes the outer authority so the host doubles per nesting level, and there is no nesting limit.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/ArchiveLocation.swift:48-61
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A075 [finding, low] Each immediate write re-sorts and copies all entries.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/ArchiveTree.swift:116-121, 142, 164; Sources/Plugins/Archives/OpenArchive.swift:1108
- **Basis:** read
- **Detail:** Any insert or remove clears orderedPaths so each immediate write costs O(n log n) under the lock.
- **Proposed fix:** Keep the order incrementally (append when the order is the maximum).
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A076 [finding, low] Opening a 200,064-member ZIP raises the footprint by 272 MB, about 1,425 bytes per member.
**Outcome:** fixed — see `status/archnet-p2.md`


- **Where:** Sources/Plugins/Archives/ArchiveTree.swift:5; Sources/Plugins/Archives/ZipFormat.swift:28
- **Basis:** measured
- **Detail:** Same in both runs. Likely holders: ArchiveEntry with its full ZipRecord. Reported as low/medium.
- **Proposed fix:** Keep names as slices of the central-directory buffer and build the full record only on write.
- **Source:** reports/23-filejob-archives-stress.md
- **Status:** open

### A077 [verdict, low] Archive path split on Character lets ../ + combining mark land one level up
**Outcome:** duplicate of A005 — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/ArchiveTree.swift:81-84; Sources/Plugins/Archives/Unpacker.swift:256
- **Basis:** CONFIRMED (ran copied lines), limited
- **Detail:** Splits on Character. '../́escaped.txt' and '../‍e3.txt' (U+0301, U+200D) landed in the parent of the destination. Exactly one level up, name must begin with the combining character so no known file can be targeted. Precondition: user unpacks hostile archive. Ran the two copied lines, not the full Unpacker.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### A078 [finding, low] stop() keys rescue outcomes by file name, so two archives with the same name report the wrong path.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/ArchivesPlugin.swift:99
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A079 [verdict, low] Archive files created with 0644 regardless of source modes
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/ByteStreams.swift:339; Sources/Plugins/Archives/Packer.swift:393; Sources/Plugins/Archives/Packer.swift:502; Sources/Plugins/Archives/Packer.swift:520
- **Basis:** PARTLY CONFIRMED (read)
- **Detail:** Member modes inside are preserved. Another local user can read.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### A080 [finding, low] bsdtar and bzip2 inherit the full environment (bzip2 reads BZIP2/BZIP; libarchive may exec filter helpers found via PATH) and are not sandboxed.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/Codecs.swift
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A081 [finding, low] A valid .xz with long stream padding is reported damaged.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/Codecs.swift:284-291
- **Basis:** reproduced
- **Detail:** Confirmed with a replica of the loop: padding of 64 KB and of 200 KB both fail.
- **Proposed fix:** Skip zero bytes in a loop until non-zero or EOF.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A082 [finding, low] Spools kept by rescue() are raw deflate streams with UUID names and no index.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A083 [finding, low] Leftovers after a crash and loose scratch permissions.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:1170; Sources/Plugins/Archives/Packer.swift:353, 413; Sources/Plugins/Archives/ByteStreams.swift:464-474
- **Basis:** read
- **Detail:** .UUID.afm-zip.tmp and .afm-pack.tmp files (full size on the rewrite path) and scratch folders are never swept. Scratch directory is created 0755 with files 0644, which matters only if TMPDIR is shared.
- **Proposed fix:** Sweep at start (the pid is in the scratch name); create the directory 0700 and files 0600.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A084 [finding, low] correctTime patches before verifying; canAppend checks only the header offset.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:1244-1251, 1148-1157
- **Basis:** read
- **Detail:** The four DOS-time bytes are written at offset + 10 before the local signature is checked. With a crafted directory offset this overwrites another member data. A member whose data runs past directoryOffset is cut by the truncation. Security/correctness.
- **Proposed fix:** Verify signature and name first; require offset + 30 + name + extra + compressedSize <= directoryOffset.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A085 [finding, low] install takes the new signature by stat on the path after the rename.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:1280
- **Basis:** read
- **Detail:** 
- **Proposed fix:** Use fstat on newFile.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A086 [verdict, low] Server-side variant of flushAll nested-loss not run
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:1356-1384
- **Basis:** UNPROVEN (not run)
- **Detail:** Same upload path as the nested case.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### A087 [verdict, low] Foreign-format archive named as mtree text pulls local files into the listing (bsdtar)
**Outcome:** duplicate of A038 — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:270; Sources/Plugins/Archives/ArchiveLocation.swift:245
- **Basis:** CONFIRMED (ran exact bsdtar call)
- **Detail:** An mtree text file named evil.7z with contents=<marker> produced a tar holding the marker's content. Any file not ZIP, TAR, gz, bz2 or xz takes this path. Local files copied into the listing or extraction; no exfiltration by itself.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### A088 [finding, low] A hard-link entry whose path is later reused by a file overwrites that file content mapping.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:320, 342
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A089 [finding, low] After a failed upload remoteStamp may become nil and remote changes are then never detected.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:485, 1379
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A090 [finding, low] readInOnePass ends silently when the stream has fewer members than wanted.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:598-607
- **Basis:** read
- **Detail:** 
- **Proposed fix:** Throw if left > 0.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A091 [verdict, low] OpenArchive.capabilities takes a lock on main
**Outcome:** duplicate of A003 — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:696; Sources/Plugins/FileOperations/FileOperationsPlugin.swift:43; Sources/Plugins/Clipboard/ClipboardPlugin.swift:52; Sources/Plugins/MultiRename/MultiRenamePlugin.swift:27; Sources/Plugins/FileProperties/FilePropertiesPlugin.swift:46; Sources/Plugins/Archives/OpenArchive.swift:1062
- **Basis:** CONFIRMED (read) narrowly; user-visible effect unproven
- **Detail:** Reached on main from command validation. Correction: lock not held across member data or archive rewrite (build, 1062, runs outside it); held across metadata system calls on the archive's volume: access() at 686, statfs/free-space at 850, clonefile probe at 772, stat/open/rename in install 1268-1274, stat at 482, full re-read of ZIP directory in rebase 1313-1327. Nothing visible on a local SSD; stall on a slow or stalled network share.
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

### A092 [finding, low] The flush timer runs at .utility QoS; a user-initiated commit waiting behind it gets a CPU override but not its I/O tier.
**Outcome:** duplicate of A062 — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:714
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A093 [verdict, low] Deleting an already-archived member during a flush
**Outcome:** refuted — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:789-799
- **Basis:** REFUTED (ran with hook) for this case
- **Detail:** Deleting a member that was already in the archive during a flush was persisted by the next flush.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### A094 [finding, low] Rollback in move can re-insert an entry with a stale order after a rebase.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/OpenArchive.swift:939-949
- **Basis:** inferred
- **Detail:** After a rebase inside the failed flush the restored replaced entry carries an order from the old tree, which can collide in built.offsets. Plausible (rare).
- **Proposed fix:** Insert without keepingOrder when the tree was reloaded.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A095 [finding, low] Packer leaks an open archive writer when the source cannot be opened
**Outcome:** duplicate of A018 — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/Packer.swift:498-499
- **Basis:** read
- **Detail:** From reading only.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### A096 [finding, low] Unpack follows symbolic links that already exist at the destination.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/Unpacker.swift:291-294, 369-379
- **Basis:** inferred
- **Detail:** A link created by an earlier extraction is followed by a later one. Within one run the order is safe. Security, plausible.
- **Proposed fix:** lstat each created component; refuse to pass through links the run did not create.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A097 [finding, low] Link-first extraction (symlink then file through the link) unproven
**Outcome:** duplicate of A096 — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/Unpacker.swift:361-366
- **Basis:** inferred
- **Detail:** Unpacker creates symlinks with any target. Within one run folders are created first so a 'link, then file through the link' archive should fail; a second archive unpacked into the same folder would follow an existing link. Not tested.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### A098 [finding, low] Unpacker.run unlocks the whole archive even when the selection has no encrypted member.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/Unpacker.swift:63-66, 316-329, 95-105
- **Basis:** read
- **Detail:** Related to the password prompt storm (finding 12).
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A099 [finding, low] ZIP64 end record is not found behind a self-extractor stub.
**Outcome:** fixed — see `status/archives.md`


- **Where:** Sources/Plugins/Archives/ZipFormat.swift:439-440
- **Basis:** inferred
- **Detail:** end64Offset is used unshifted so the reader falls back to the 32-bit fields. Plausible; not tested with a real ZIP64 SFX.
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A100 [finding, info] Commit cost on the large archive is 0.33-0.72 s per commit on the committing thread; other listings waited at most 125-160 ms.
**Outcome:** not a defect — see `status/archives.md`


- **Basis:** measured
- **Detail:** 
- **Source:** reports/23-filejob-archives-stress.md
- **Status:** open

### A101 [finding, info] flush() without leavingOutArrivals (timer, stop) writes members still under job temp names.
**Outcome:** duplicate of A033 — see `status/archives.md`


- **Where:** Plugins/Archives/OpenArchive.swift
- **Basis:** read
- **Detail:** Explicitly 'not a threading bug'.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A102 [finding, info] streamStarts is private(set) and readable unlocked (tests).
**Outcome:** fixed — see `status/archives.md`


- **Where:** Plugins/Archives/OpenArchive.swift
- **Basis:** read
- **Detail:** Minor.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A103 [finding, info] L5 (flushLock) is held across whole-archive rewrite or outer-provider upload; for a nested archive it reaches outer L3, outer L4 and outer L5.
**Outcome:** not a defect — see `status/archives.md`


- **Where:** Plugins/Archives/OpenArchive.swift:1045,1391,1053,1054,1183,1268,1313,1360,1380,1071,1169,1356
- **Basis:** read
- **Detail:** build :1169: clone-append writes only pending bytes plus the directory; a rewrite copies the whole archive (multi-GB) plus copyfile xattrs. upload :1356: outer provider.write/move/item/remove for the entire archive; for nested archive reaches outer L3, outer L4 and outer L5 (via outer move -> flush), and outer ZipMemberWriter.drain -> Parallel.map. Not held: reportFailure, contentsChanged, askPassword.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A104 [finding, info] L4 (OpenArchive.lock) is held across stat, clonefile/unlink probe, access() x2, outer capabilities, scratch.newFile/createDirectory/open(O_CREAT), hasRoom/statfs, O(n log n) tree.ordered, install walk, and a full ZIP directory re-parse in rebase (longest hold, ~1 s on huge ZIPs).
**Outcome:** fixed — see `status/archnet-p2.md`


- **Where:** Plugins/Archives/OpenArchive.swift:476-490,730-750,756-761,803,826,864,919,962,978,685,843,69,1105,1268,1313
- **Basis:** read
- **Detail:** Notable L4 holders: isCurrent stat; timerFired idleDelay -> clones() clonefile + unlink probe (once); makeDirectory/write/remove/move/duplicate/setAttributes -> requireEditable -> access() x2 or fileSystems.capabilities(for:) on the outer provider (:685); write also environment.options (L1), scratch.newFile (L8 + createDirectory), open(O_CREAT); finishWrite hasRoom -> statfs, possibly volumeAvailableCapacityForImportantUsage (:69, can be slow); takeSnapshot O(n log n) tree.ordered, clones(); install stat, open, rename, O(n) walk; rebase load(). Never held across askUser, a member read, or a flush.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open


## Checked and found sound

### A105 [sound, info] Entering and listing a 1M-entry archive runs in the background.

- **Basis:** read
- **Detail:** The Parallel.map calls, semaphores, Background.run and waitUntilExit in Codecs, Unpacker and FileJob are all on job threads. The store's table lock is short.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### A106 [sound, info] Lock nesting order is acyclic as read.

- **Basis:** read
- **Detail:** L3(inner) -> L3(outer); L3 -> L4 -> {L1, L8, L2 -> outer L4}; L5 -> L4; L5(inner) -> L3/L4/L5(outer); L7 -> L6 -> L10. L4 -> L5 does not exist (move :937 and timerFired :752 unlock first). L3(X) -> L5(X) and L5(X) -> L3(X) do not exist.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A107 [sound, info] Lock leaf status: L1, L2, L6, L8, L9, L11 are leaves held for ns-us.

- **Basis:** read
- **Detail:** ArchiveEnvironment.lock, ArchiveStore.lock, StreamInterrupt.lock (handlers run after unlock), ScratchFolder.lock, TemporaryFile.lock, SharedCounter.lock.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A108 [sound, info] No NSCondition, DispatchSemaphore, NSRecursiveLock, private DispatchQueue, Thread, NotificationCenter, lazy var or @unchecked Sendable in scope.

- **Basis:** read
- **Detail:** 
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A109 [sound, info] Cancel on main is short.

- **Basis:** read
- **Detail:** flag.cancel() -> StreamInterrupt.set (L6, L10 + terminate), InterruptSlot.interrupt (L7 -> L6 -> L10), outer reader/writer.interrupt().
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A110 [sound, info] capabilities(for:) never takes L5 or L3.

- **Basis:** read
- **Detail:** Main cannot block behind a flush or a materialise.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A111 [sound, info] ArchiveCommands on main avoid store.archive(at:).

- **Basis:** read
- **Detail:** showMember, openAsArchive and unpackAndOpen use jobs; refreshOptions and open take only L1.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A112 [sound, info] Only one flush at a time; no re-entry.

- **Basis:** read
- **Detail:** L5 is a non-recursive NSLock; upload only calls outer providers.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A113 [sound, info] Flush timer state machine is sound.

- **Basis:** read
- **Detail:** timerFired clears timerArmed under L4 before flushing (:731), so a change during the flush arms a new timer (:712). Failure re-arms (:760). uploadPending and leavingOutArrivals walked; no state with pending changes and neither an armed timer nor an in-flight timer thread.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A114 [sound, info] Writer close vs flush is sound.

- **Basis:** read
- **Detail:** finishWrite and takeSnapshot are both under L4. The snapshot's records retain the spool TemporaryFile, so a concurrent remove cannot unlink it. install re-resolves entries by order. openWriters is balanced on every path (:834, :844, deinit :1457, close :1506/:1516).
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A115 [sound, info] ProcessStream is sound.

- **Basis:** read
- **Detail:** stderr drained asynchronously and stdout by the reader; waitUntilExit runs only after EOF (:410). EOF depends on Foundation closing the parent's write end, which holds because the Pipe objects are passed directly.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A116 [sound, info] Internal interrupt consumers tie flags correctly.

- **Basis:** read
- **Detail:** ArchiveStore.open :124-128 and upload :1362-1365 pass both the flag and flag.interrupting; the defer order releases the tie before reader.close().
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A117 [sound, info] Every OpenArchive var is touched under L4.

- **Basis:** read
- **Detail:** load runs in init or under L4 in rebase; clones() and canClone always under L4; ArchiveTree.ordered (mutating getter) always under L4. format is read unlocked at ArchiveFileSystem.swift:442 but assigned only in init.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A118 [sound, info] Slot state and open-once logic are sound.

- **Basis:** read
- **Detail:** Slot.archive/failure under L3 and lastUsed under L2. archive(at:) re-checks slots[key] === slot after taking L3 (:61-64), so two threads open one archive once, and a cancelled open removes its slot (:81-83).
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A119 [sound, info] ArchiveEnvironment closures are set once in start() before registration; Unpacker result/itemsDone/lines are job-thread only.

- **Basis:** read
- **Detail:** Parallel.map bodies touch only SharedCounter, the monitor, and per-item streams.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A120 [sound, info] No lock is held by any caller across Parallel.map.

- **Basis:** read
- **Detail:** OpenArchive.swift:1488, Codecs.swift:584, Packer.swift:67, Unpacker.swift:96/:317. Bodies take L4 briefly, and L5 via provider.move into a ZIP; the caller holds neither.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A121 [sound, info] Archive big runs: 200,064-member ZIP (96 MB) concurrent stage had no stall over 100 ms attributable to the app.

- **Basis:** measured
- **Detail:** archives-big: 108 s, peak 985 MB, concurrent 23/0/0 max 16.7 ms, open 1/0/0 49 ms; archives-big-2: 932 MB, 9/0/0 max 17.0 ms. Only stalls over 100 ms were the harness's own loop (and leaks suspending the process). Threads 7 -> 8.
- **Source:** reports/23-filejob-archives-stress.md
- **Status:** open

### A122 [sound, info] Archive open and list performance: first root listing of the 200k archive took 0.46-0.47 s off the main thread.

- **Basis:** measured
- **Detail:** Second listing 1 ms, a 500-entry folder 1.3 ms, all 400 folders 0.36 s on one thread or 0.17 s on 16.
- **Source:** reports/23-filejob-archives-stress.md
- **Status:** open

### A123 [sound, info] Archive concurrent stage returned correct bytes: 16 readers over 64 probe members, one adder, one lister.

- **Basis:** measured
- **Detail:** 804,155 and 742,286 reads completed matching reference bytes and CRC; 13,419 and 11,088 reads ended by cancel, median 0.1 ms after cancel, p95 4 ms, max 120 ms; no wrong bytes, none failed without a cancel.
- **Source:** reports/23-filejob-archives-stress.md
- **Status:** open

### A124 [sound, info] Archive commits are valid: 30 + 26 commits, median 0.48 s and 0.36 s, max 0.72 s.

- **Basis:** measured
- **Detail:** After every commit unzip -tq reported no errors, zipinfo listed every new member, and a fresh reader found the right member count and read back new members identically.
- **Source:** reports/23-filejob-archives-stress.md
- **Status:** open

### A125 [sound, info] Deep archive (2,000-deep chain, 8,191-folder binary tree, one 60,000-byte path) listed and read at every level in 2.8 s, peak 96 MB, stalls 0/0/0 max 3.7 ms.

- **Basis:** measured
- **Detail:** Slowest level 0.5 ms; member added at the bottom and committed; Python zipfile.testzip() passed. unzip -tq returns status 1 (filename too long) on the pristine file as well, a tool limit.
- **Source:** reports/23-filejob-archives-stress.md
- **Status:** open

### A126 [sound, info] No unbounded memory growth in archive stage.

- **Basis:** measured
- **Detail:** Footprint plateaued around 670-690 MB during the stage and fell to 287 MB after store.close(), about 230 MB of which is harness reference data. No-leak statement rests on the footprint series only.
- **Source:** reports/23-filejob-archives-stress.md
- **Status:** open

### A127 [sound, info] Archive parsers did not crash, hang or over-allocate in about 2.4 million executions

- **Basis:** reproduced
- **Detail:** Group 1 (ziplist, tarlist, tgzlist, txzlist, zip, tar, tgz, txz, zipmod, bz): 1,214,545 asan and 1,142,276 rel executions; no crash, hang or over-memory. HTML viewer rendering is linear. FileMask had no hang. Quoting: single quotes held.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### A128 [sound, info] Slot wait lock balance is correct.

- **Where:** Plugins/Archives/ArchiveFileSystem.swift
- **Basis:** read
- **Detail:** slot.lock.lock(before:) loop :52-54 registers the defer only after acquiring; try() at :158 and unlock at :168 are balanced.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A129 [sound, info] `.outside` forwarders return the outer provider's own reader/writer.

- **Where:** Plugins/Archives/ArchiveFileSystem.swift:364-366,385,392,402
- **Basis:** read
- **Detail:** interrupt() is native and the flag is forwarded wherever the protocol has one.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A130 [sound, info] ArchiveMemberReader.interrupt is safe at any time.

- **Where:** Plugins/Archives/ArchiveTree.swift:199
- **Basis:** read
- **Detail:** Repeatedly, after close (current == nil), and alongside read/close. closeStream releases the slot before closing, and park re-checks control.isSet (:562).
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A131 [sound, info] Tool.filter has no pipe-fill deadlock.

- **Where:** Plugins/Archives/Codecs.swift:312-340
- **Basis:** read
- **Detail:** stdin written and stderr drained on GCD while the caller drains stdout; errors read after group.wait. F_SETNOSIGPIPE is set. Not cancellable, but the input is at most 4 MB.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A132 [sound, info] ZipMemberWriter.interrupt is safe.

- **Where:** Plugins/Archives/OpenArchive.swift:1460
- **Basis:** read
- **Detail:** StreamInterrupt.set; checked at write/drain/close; worst latency is one Parallel.map deflate window.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A133 [sound, info] Interrupt tokens use weak captures and live exactly the blocking span.

- **Where:** Plugins/Archives/OpenArchive.swift:224,594; Plugins/Archives/ArchiveTree.swift:185
- **Basis:** read
- **Detail:** 
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A134 [sound, info] Background.run has a happens-before.

- **Where:** Plugins/Archives/Unpacker.swift:26-33
- **Basis:** read
- **Detail:** result is written in the group block and read only after group.wait returns success. tick runs on the caller.
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A135 [sound, info] Premise check: the archive lock is a plain NSLock, not recursive, and no nested acquisition was found.

- **Where:** Sources/Plugins/Archives/
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A136 [sound, info] Premise check: FindFiles cannot descend into nested archives because location(from:) only resolves local-disk archives; a quine archive is only reachable by entering it by hand.

- **Where:** Sources/Plugins/Archives/
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A137 [sound, info] Shared state is correctly guarded: OpenArchive state under lock (held too long, finding 6); archive file writes/upload/rescue under flushLock always taken before lock (not cancellable, Packer bypasses); format/archiveURL/quarantine/fetchedCopy immutable; ArchiveStore table lock is a leaf; Slot lock with try-based eviction (write-start race, finding 24); ArchiveEnvironment.options own lock, other fields set once by convention; StreamInterrupt/InterruptSlot own locks and handlers run outside; ProcessStream errors/isClosed own lock; ScratchFolder/TemporaryFile locks; ZipMemberWriter, ZipPacker, ParallelCompressor, OutputFile, TarReader and streams single owner thread; Unpacker/Packer counters on job thread with SharedCounter.

- **Where:** Sources/Plugins/Archives/
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A138 [sound, info] Lock order: slot -> table; slot -> archive; flushLock -> archive; inner archive -> table -> outer archive (via requireEditable); inner flushLock -> outer archive and outer flushLock (via upload). No inversion found. No holder of an archive lock calls the UI; askPassword is called with no archive lock held, possibly under the inner slot lock, which is safe because main never waits on a slot lock.

- **Where:** Sources/Plugins/Archives/
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A139 [sound, info] Parsers: no trap in 460,000 mutated ZIP, ZIP64, encrypted ZIP, pax/GNU tar, .tgz and .txz inputs; fuzzer covered directory, local header, extra fields, decrypt/inflate/size-guard/CRC, tar reader, pax records, xz index, gzip trailer and format detection; arithmetic clamped or range-checked.

- **Where:** Sources/Plugins/Archives/
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A140 [sound, info] bsdtar output is read as a TAR stream not text so names with newlines cannot spoof entries; tools invoked by absolute path with no shell; bzip2 gets --, bsdtar gets @ plus an absolute path.

- **Where:** Sources/Plugins/Archives/
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A141 [sound, info] Terminated children are reaped (20 terminated bsdtar, none left); the only pipe the app writes to has F_SETNOSIGPIPE.

- **Where:** Sources/Plugins/Archives/
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A142 [sound, info] Truncated xz, or xz with trailing garbage, ends with an error with no spin.

- **Where:** Sources/Plugins/Archives/
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A143 [sound, info] Flush atomicity: archive file is always the complete old or complete new one apart from durability (finding 8); disk full mid-append removes the clone; external change detected before build and again under the lock before rename; two flushes cannot overlap.

- **Where:** Sources/Plugins/Archives/
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A144 [sound, info] Readers during a flush stay consistent: readers hold records bound to their file object, listers see the tree only under the lock.

- **Where:** Sources/Plugins/Archives/
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A145 [sound, info] Timer: pending changes always imply an armed timer or running flush; no lost wake-up.

- **Where:** Sources/Plugins/Archives/
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A146 [sound, info] ZIP64 thresholds for count, offsets and sizes are handled on write and re-read; data descriptors rewritten correctly on copy; stub prefixes kept.

- **Where:** Sources/Plugins/Archives/
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A147 [sound, info] Read-only cases: duplicate-name archives are read-only on every mutating path; AES entries give a clear "not supported" error.

- **Where:** Sources/Plugins/Archives/
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A148 [sound, info] The cached password is dropped on a wrong check byte or CRC failure.

- **Where:** Sources/Plugins/Archives/
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A149 [sound, info] Parked readers are taken and returned under the lock; an interrupted reader is never parked.

- **Where:** Sources/Plugins/Archives/
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A150 [sound, info] Abandoned or cancelled opens cache nothing and their scratch files and children are removed.

- **Where:** Sources/Plugins/Archives/
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A151 [sound, info] Extraction order: within one Unpack run folders are created before any link and files arrive by temp + exclusive rename; a link entry followed by a file below it, or a case collision, cannot write through a link.

- **Where:** Sources/Plugins/Archives/
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A152 [sound, info] Ordinary Copy never creates links from archive members.

- **Where:** Sources/Plugins/Archives/
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A153 [sound, info] Setuid/setgid bits are masked for ZIP and TAR; device and FIFO entries are skipped (tar) or written as regular files (ZIP).

- **Where:** Sources/Plugins/Archives/
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A154 [sound, info] Quarantine is propagated to unpacked files and explicit folders.

- **Where:** Sources/Plugins/Archives/
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A155 [sound, info] NUL in names is not truncated by URL.path; it stays %00.

- **Where:** Sources/Plugins/Archives/
- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open


## Not covered / left behind

### A156 [gap, info] Not read in full: ZipFormat.swift 1-299 and 390-514, ArchiveLocation.swift 131-286.

- **Basis:** read
- **Detail:** Only grepped (no locks, queues, statics with state, or classes other than the streams there).
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A157 [gap, info] Nothing was built or run; every finding is from reading.

- **Basis:** read
- **Detail:** 
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open

### A158 [gap, info] Not covered: ZIP central-directory and ZIP64 arithmetic, inflate/xz stream internals, decompression-ratio limits beyond noting SizeGuardStream and unpackedLimit exist.

- **Basis:** 
- **Detail:** 
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### A159 [gap, info] Not reviewed: internals of Archives and Network providers (remove, move, commit semantics, listed-name sanitising) beyond FileJob's calls.

- **Basis:** 
- **Detail:** 
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### A160 [gap, info] The project was not built and its test suite was not run; findings marked confirmed by reading were not reproduced at runtime.

- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A161 [gap, info] Not exercised: crash and power-loss behaviour, non-APFS volumes, SMB stalls.

- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A162 [gap, info] Outside scope: Tests/, and FileJob beyond its transfer, temp-name and commit paths.

- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A163 [gap, info] Outside scope: the network providers, including whether one can call askUser during an upload (which decides the deadlock in finding 5).

- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A164 [gap, info] Main-thread callers in the shell were checked only by grep.

- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A165 [gap, info] Not measured: Apple LZMA decoder with a multi-GB declared dictionary.

- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A166 [gap, info] libarchive own parsers inside bsdtar are untrusted-input code that was not examined.

- **Basis:** read
- **Detail:** 
- **Source:** reports/16-review-archives-second-round.md
- **Status:** open

### A167 [gap, info] The network provider's write path was not traced beyond askUser for BUG 1.

- **Where:** Plugins/Network/NetworkCommands.swift:44-78
- **Basis:** read
- **Detail:** 
- **Source:** reports/06-archives-plugin-threading-audit.md
- **Status:** open
