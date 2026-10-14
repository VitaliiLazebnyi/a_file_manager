# Review Archives second round

## Second-round review: Sources/Plugins/Archives

All twelve files were read in full; nothing in the project was modified or built. Four findings were confirmed by
standalone experiments, the rest by reading. A mutation fuzzer over copies of the parsers (460,000 cases) produced no
trap.

Experiments are under
`/private/tmp/claude-501/-Users-cm0k-Claude-Projects-TotalCommander/91e36f29-0d53-4421-8985-1ec839e7f5c4/scratchpad/review2/archives/`
(`src/t1.swift`–`t3.swift`, `fz/`, `mt/`).

Two premises in the brief do not match the code:

- The archive lock is a plain `NSLock`, not recursive. No nested acquisition was found.
- FindFiles cannot descend into nested archives, because `location(from:)` only resolves local-disk archives. A quine
  archive is therefore only reachable by entering it by hand.

### Findings, most severe first

#### High

##### 1. One deep path exhausts memory on Enter — high, security (DoS), confirmed by experiment

- Where: `ArchiveTree.swift:132-157` (`insert`), `:70-72`, `:81-84`; `Tar.swift:229-231`, `:260`.
- What: `insert` walks up the parents, and each step allocates a new full-length parent string that is kept as a
  dictionary key and entry path. Cost and retained memory are quadratic in the path length.
- Trigger: one ZIP entry with a 65,533-byte name `a/a/a/…` creates 32,768 implicit folders. In a replica of the tree's
  key handling this retained 1.07 GB of key bytes (1.2 GB RSS) and took 4.9 s. Twenty such entries fit in a ~2.6 MB ZIP.
  A pax `path` record may be 16 MB (about 8 million components), so a `.tar.gz` of a few tens of KB never finishes, and
  the loop has no cancellation check.
- Fix: reject paths over about 4 KB or 256 components before inserting; store children as nodes rather than full-path
  keys; check the interrupt inside indexing.

##### 2. Quit can silently drop changes to nested or remote archives — high, data-loss, confirmed by reading

- Where: `ArchiveFileSystem.swift:182-188` (`flushAll`), `ArchivesPlugin.swift:96-110`.
- What: `flushAll` makes one pass over `opened.values` in dictionary order. Flushing an inner archive uploads into its
  outer archive, which gives the outer new pending changes. If the outer was visited first, nothing flushes it again,
  `failures` is empty, no rescue runs, and `store.close()` deletes the spools.
- Trigger: copy a file into `outer.zip/inner.zip` and quit within the idle delay (up to 60 s for the outer, since
  replacing the inner counts as a removal).
- Fix: repeat until no archive has pending changes (bounded passes), or flush deepest first; run the rescue for anything
  still pending.

##### 3. A deletion made while a flush is building never reaches the disk — high, correctness/privacy, confirmed by reading

- Where: `OpenArchive.swift:789-799` (`take`), `:1287-1304` (`install`), `:1130-1134`.
- What: `take` counts a removal only if the record is already in the archive. A member that is still a spool when the
  snapshot is taken, then removed during the build, is written into the new file. `install` skips it because it is gone
  from the tree, and the next snapshot finds no work and marks everything written.
- Trigger: add files to a large ZIP, then delete one of them while the rewrite runs (minutes for big archives). The file
  stays in the archive on disk and reappears after a restart. A job's `.afm-<UUID>.tmp` member that is discarded during
  a flush persists the same way.
- Fix: in `install`, for every snapshot entry that was written but is no longer in the tree, increment `removals`.

##### 4. Pack into a ZIP on a server or inside another archive deletes the old member on failure and ignores Encrypt — high, data-loss + security, confirmed by reading

- Where: `Packer.swift:488-514`, specifically `:496` and `:503-507`.
- What (data loss): the existing member is removed before the replacement is written. On a read error or Cancel, the
  handler flushes, which makes the removal permanent with no replacement.
- What (security): `options.password` and `options.level` are never used on this path. With "Encrypt" ticked, members
  are stored in plain text, and the verify pass succeeds because there is nothing to decrypt.
- Fix: write under a temporary name and `move(replacing: true)` on success; refuse or implement encryption on this path.

##### 5. Quit blocks the main thread on archive writes — high, freeze, confirmed by reading

- Where: `ArchivesPlugin.swift:96-98`, `OpenArchive.swift:1044-1046`, `:1356-1362`.
- What: `applicationWillTerminate` calls `kernel.shutdown()`, which calls `stop()`, which runs `flushAll()` on the main
  thread. That means whole-archive rewrites and uploads with no progress and no cancellation (`upload` creates a flag
  nobody can set). It also waits on `flushLock` behind any timer flush in progress, as does `rescue()`.
- Trigger: quit while a multi-GB rewrite is pending, or with an unresponsive server.
- Possible hard deadlock (plausible, depends on the remote provider): a background flush that holds `flushLock` and
  whose provider calls `kernel.askUser` (a `main.sync`) deadlocks against the main thread waiting in `flushAll`.
- Fix: flush from `applicationShouldTerminate` via `.terminateLater`, on a background thread, with a progress window and
  a cancellation flag; acquire `flushLock` with `lock(before:)`.

##### 6. `capabilities(for:)` on the main thread takes the archive lock, which is held across disk I/O and O(n log n) work — high, freeze, confirmed by reading

- Where: `OpenArchive.swift:695-700`, called from `PanelViewController+Interaction.swift:297`.
- The same lock is held during:
  - `isCurrent()` — `stat` (`:481-484`);
  - `requireEditable()` — two `access()` calls or another provider's `capabilities` (`:681-689`);
  - `clones()` — `clonefile` + `unlink` (`:768-779`);
  - `finishWrite` — `statfs` and possibly a volume resource query (`:842-850`);
  - `takeSnapshot` — a full sort and copy of all entries (`:1104-1138`);
  - `install` — `stat`, `open`, `rename`, and a walk over all entries (`:1267-1307`);
  - `rebase` — re-reading and parsing the whole directory (`:1312-1352`).
- Trigger: an archive on a stalled SMB/NFS mount, where a background `stat` holds the lock until the mount times out; or
  a 1M-entry ZIP during snapshot or rebase.
- Fix: keep the capability inputs (`editable`, `hasDuplicates`, `fetched`) in a separate tiny lock or atomic updated at
  load/rebase; move all syscalls out of the directory lock.

#### Medium

##### 7. bsdtar accepts an mtree text file and reads local files it names — medium, security, confirmed by experiment

- Where: `OpenArchive.swift:265-273`, `ArchiveLocation.swift:245`.
- What: anything not recognised becomes `.foreign` and is passed to `bsdtar -cf - @file`. libarchive's mtree reader
  opens the `contents=` paths.
- Trigger: a text file named `holiday.7z` containing `#mtree` and `photo.jpg type=file contents=/path/to/secret`. The
  archive lists `photo.jpg` with the secret file's bytes, read with the app's privileges. A large local file is copied
  into scratch (up to 4 GB); a FIFO hangs the child until cancelled.
- Fix: accept only known magic numbers for foreign formats (7z, Rar!, MSCF, xar!, cpio, ISO, LHA) before calling bsdtar;
  run it with an empty working directory and a minimal environment, ideally sandboxed to read only the archive.

##### 8. Nothing is synced before the rename, though `commit` promises durability — medium, data-loss, plausible

- Where: `OpenArchive.swift:1222` and `:1274`; `Packer.swift:357-358`, `:422-423`; `ByteStreams.swift:402-407`.
- What: after a power loss the rename can be durable while the appended tail and new directory are not. The result is a
  ZIP with no central directory, and Move or Move-to-archive has already deleted the sources.
- Fix: `fsync` (or `F_BARRIERFSYNC`) the temporary file before `rename`, at least on the `commit` and Move-to-archive
  paths.

##### 9. Pack into an existing local ZIP bypasses `OpenArchive` — medium, data-loss/security

- Where: `Packer.swift:298`, `:403-433`, `:349-358`, `:457`.
- Lost update (plausible): `appendToZip` and `writeZip` read the directory at the start and rename at the end, with no
  `flushLock` and no signature check. A flush or another program that writes in between is overwritten.
  `try? store.flush` also ignores failure.
- Mode widened (confirmed by reading): the rewrite path creates the file 0644 and never applies the old mode, so a 0600
  archive becomes world-readable.
- Fix: go through the open archive under its `flushLock`, or re-check `FileSignature` before the rename; `chmod` as
  `OpenArchive.build` does.

##### 10. `..` filter bypass via combining characters — medium, security, confirmed by experiment

- Where: `ArchiveTree.swift:81-84`, `Unpacker.swift:256`.
- What: Swift splits on Characters. `/` followed by a combining mark (U+0301, ZWJ, variation selectors) is a single
  Character that is not equal to `/`. The name `../\u{301}evil.txt` normalises to itself, and the unpack target becomes
  `<folder>/../́evil.txt`.
- Limits: one level above the target, and the file name must start with a combining mark. Reachable through Unpack;
  ordinary Copy fails to read such an item.
- Fix: split on bytes (`utf8`, 0x2F) everywhere (`normalized`, `name(of:)`, `parent(of:)`, the Unpacker); reject NUL and
  control characters; assert the final target `isInside` the folder.

##### 11. No cap on entry count; about 0.5–1 KB of memory per entry — medium, security/performance, plausible (the per-entry figure is an estimate, not measured)

- Where: `ZipFormat.swift:462-499`, `OpenArchive.swift:296-325`, `ArchiveTree.swift`.
- What: a `.tgz` of roughly 1 MB can hold a million empty members; larger ones tens of millions. Each entry carries an
  `ArchiveEntry` with an inline `ZipRecord`, three or four strings and a set element. Eviction is by count (12), not by
  memory.
- Fix: cap entries (a few million) with a clear error; consider a compact entry representation.

##### 12. Password prompt storm, and no serialisation of prompts — medium, freeze (modal flood), confirmed by reading

- Where: `OpenArchive.swift:638-661`; `Unpacker.swift:63-66`, `:316-329`, `:95-105`.
- What: every member whose check byte fails prompts up to three times. Parallel readers prompt concurrently. A refusal
  is not remembered.
- Trigger: a ZIP with thousands of "encrypted" entries with differing check bytes; Test or Unpack produces thousands of
  modal dialogs, and only the job's Cancel stops them.
- Fix: one prompt gate per archive (re-check the cache after acquiring it); remember "declined" for the duration of the
  operation.
- Related, low: `Unpacker.run` unlocks the whole archive even when the selection has no encrypted member.

##### 13. Members under temporary names can be persisted and remain — medium, correctness, confirmed by reading

- Where: `OpenArchive.swift:1116-1129`; `ArchiveFileSystem.swift:182-198`.
- What: only the immediate write leaves out arriving members. The timer, another job's `commit`, the `store.flush` calls
  of Unpack/Test/Pack, and `flushAll` at quit all write closed-but-unrenamed members under `.afm-<UUID>.tmp`.
- They remain in three cases:
  - the process exits or crashes before the rename;
  - the job discards the temp member while a flush is building (finding 3);
  - the writer landed in an orphaned `OpenArchive` (finding 24).
- Otherwise the later rename appends the data a second time and leaves dead space.
- Fix: never include arriving members in a flush unless the caller asks; at quit, drop them; at load, optionally hide or
  strip names matching the temp pattern.

##### 14. Spools go to TMPDIR on the boot volume with no space check there — medium, performance/correctness, confirmed by reading

- Where: `OpenArchive.swift:832-833`, `:842-850`; `ByteStreams.swift:464-466`.
- What: `finishWrite` checks room only at the archive's folder. On a file system that cannot clone (exFAT, HFS+, SMB),
  immediate writes never happen, so a whole job's compressed data accumulates in TMPDIR.
- Trigger: copying 200 GB into a ZIP on a USB drive needs 200 GB free on the boot disk and fails with "no space"
  although the destination has room.
- Fix: spool next to the archive when it is on another volume, or check scratch space and flush early.

##### 15. Scratch disk exhaustion — medium, security/performance, confirmed by reading

- Where: `OpenArchive.swift:34-36`, `:353-367`, `:391-412`; `ArchiveFileSystem.swift:21`, `:122-134`.
- What: merely entering a stream archive of 256 MB or less writes up to 4 GB into scratch. Twelve cached archives can
  hold 48 GB. No free-space check is made beforehand; a failed write is caught, but the disk stays full until indexing
  ends.
- What: fetching a remote or nested archive copies it whole with no size or space check. A nested member can declare any
  size.
- Fix: a budget for total scratch use, a "keep N GB free" check before and during materialisation, and a `hasRoom` check
  against `item.size` before fetching.

##### 16. Cancellation gaps — medium, freeze (of Cancel), confirmed by reading

- `store.archive(at:)` is called without the job's flag at `ArchiveCommands.swift:114`, `:355`, `:363`, `:414`;
  `Packer.swift:489`, `:566`; `ArchiveFileSystem.swift:494`. A long open (bsdtar, bzip2, counting a `.bz2` to its end)
  cannot be cancelled there, and waiters on the same slot block.
- `flush()` takes `flushLock` unconditionally (`OpenArchive.swift:1045`), so `commit` and the immediate write in `move`
  (`:937`, no flag at all) wait behind a multi-minute timer rewrite.
- `isCurrent()` does an uncancellable remote `item(at:)` under the slot lock (`:491`).
- Fix: thread the flag through; use `lock(before:)` polling; use `flushLock.try()` for the opportunistic write in
  `move`.

##### 17. Editing an archive reached through a symbolic link replaces the link — medium, correctness, plausible

- Where: `OpenArchive.swift:1170-1174`, `:1274`.
- What: `clonefile` and `stat` follow the link, but `rename(temp, localURL.path)` replaces the link itself with a new
  file. The real archive never changes.
- Fix: resolve the last path component once at open and use the real path.

##### 18. Child processes re-open the archive by path — medium, correctness, plausible

- Where: `Codecs.swift:508`, `OpenArchive.swift:270`, `:541-548`.
- What: for bzip2 and bsdtar, members are found by index in a stream started from `file.path`. If the file is replaced
  while a job still holds entries of the old `OpenArchive`, member N of the new file is returned under the old name with
  no error. Nothing compares the header's path or size with the entry.
- Fix: give the child the already-open file (stdin; `bsdtar … @-`), and verify header name and size on `.member` opens.

##### 19. Random-order reads of big stream archives are quadratic — medium, performance, plausible

- Where: `OpenArchive.swift:521-555`.
- What: only `Unpacker` uses `readInOnePass`. Ordinary Copy takes files in panel order. For a non-materialised archive
  (over 256 MB) that is uncorrelated with archive order, each file decompresses a large fraction of the archive, with at
  most four parked readers.
- Fix: materialise lazily when a second restart happens and space allows, or expose archive order or a batch API to the
  job.

##### 20. Listing a foreign archive means full extraction through a pipe — medium, performance, confirmed by reading

- Where: `OpenArchive.swift:270`, `:355`.
- What: every open of a 7z/rar/iso decompresses all data just to see the headers. Above 256 MB nothing is kept, so each
  member read (or parked-reader miss) runs bsdtar from the start again.
- Fix: accept the trade-off knowingly, or list with libarchive directly.

##### 21. Failed-flush retry rewrites the whole archive every 30 s forever — medium, performance, confirmed by reading

- Where: `OpenArchive.swift:751-763`.
- What: deterministic failures (a damaged member that `copyMember` rejects, an archive deleted or moved, a name that is
  too long) are retried at a fixed interval. Each try may copy gigabytes to a temp file before failing.
- Fix: exponential back-off; do not retry failures that cannot heal until the next change.

##### 22. Deferred writes are invisible to the rest of the app — medium, data-loss (design), plausible

- Where: `OpenArchive.swift:725-727`.
- What: deletions wait `min(60, 20 × lastRewriteDuration)` seconds. If the user moves, copies or uploads the archive
  file in another panel during that window, the file is stale. A moved archive then fails with "changed by another
  program" forever, and the changes end up in a rescue ZIP at quit.
- Fix: let the kernel ask providers to commit before a file that is an open archive is read, moved or deleted; show
  pending state in the panel.

#### Low

##### 23. `correctTime` patches before verifying; `canAppend` checks only the header offset

- Where: `OpenArchive.swift:1244-1251`, `:1148-1157`. Security/correctness, confirmed by reading.
- What: the four DOS-time bytes are written at `offset + 10` before the local signature is checked. With a crafted
  directory offset this overwrites another member's data. A member whose data runs past `directoryOffset` is cut by the
  truncation.
- Fix: verify signature and name first; require `offset + 30 + name + extra + compressedSize <= directoryOffset`.

##### 24. A writer can land in an archive the store has just dropped

- Where: `ArchiveFileSystem.swift:65-76`, `:147-171`, `:383-397`. Threading, plausible (narrow window).
- What: between `store.archive()` returning and `archive.write()`, eviction or the not-current replacement can remove
  the archive from the table. The later rename and commit go to a new instance: the job fails loudly, but the orphan
  flushes its temp-named member by itself. `store.commit` also returns success when no archive is in the table.
- Fix: a "detached" flag set under the archive lock that makes `write` throw or retry; register the writer under the
  slot lock.

##### 25. Leftovers after a crash; scratch permissions

- Where: `OpenArchive.swift:1170`; `Packer.swift:353`, `:413`; `ByteStreams.swift:464-474`. Leak/security, confirmed by
  reading.
- What: `.UUID.afm-zip.tmp` and `.afm-pack.tmp` files (full size on the rewrite path) and scratch folders are never
  swept. The scratch directory is created 0755 with files 0644, which matters only if TMPDIR is shared.
- Fix: sweep at start (the pid is in the scratch name); create the directory 0700 and files 0600.

##### 26. Cached open failures never expire for local files

- Where: `ArchiveFileSystem.swift:66-69`, `:86`. Correctness, confirmed by reading.
- What: a transient error (ENOSPC in scratch, a killed child) is replayed until the archive's signature changes or the
  slot is evicted.
- Fix: cache only format errors, with a time limit.

##### 27. Each immediate write re-sorts and copies all entries

- Where: `ArchiveTree.swift:116-121`, `:142`, `:164`; `OpenArchive.swift:1108`. Performance, confirmed by reading.
- What: any insert or remove clears `orderedPaths`, so each immediate write costs O(n log n) under the lock.
- Fix: keep the order incrementally (append when the order is the maximum).

##### 28. Unpack follows symbolic links that already exist at the destination

- Where: `Unpacker.swift:291-294`, `:369-379`. Security, plausible.
- What: a link created by an earlier extraction is followed by a later one. Within one run the order is safe (see "found
  sound").
- Fix: `lstat` each created component; refuse to pass through links the run did not create.

##### 29. Rollback in `move` can re-insert an entry with a stale order after a rebase

- Where: `OpenArchive.swift:939-949`. Correctness, plausible (rare).
- What: after a rebase inside the failed flush, the restored `replaced` entry carries an order from the old tree, which
  can collide in `built.offsets`.
- Fix: insert without `keepingOrder` when the tree was reloaded.

##### 30. `readInOnePass` ends silently when the stream has fewer members than wanted

- Where: `OpenArchive.swift:598-607`. Correctness.
- Fix: throw if `left > 0`.

##### 31. ZIP64 end record is not found behind a self-extractor stub

- Where: `ZipFormat.swift:439-440`. Correctness, plausible (not tested with a real ZIP64 SFX).
- What: `end64Offset` is used unshifted, so the reader falls back to the 32-bit fields.

##### 32. A valid `.xz` with long stream padding is reported damaged

- Where: `Codecs.swift:284-291`. Correctness, confirmed with a replica of the loop: padding of 64 KB and of 200 KB both
  fail.
- Fix: skip zero bytes in a loop until non-zero or EOF.

##### 33. Smaller items

- `install` takes the new signature by `stat` on the path after the rename (`OpenArchive.swift:1280`); use `fstat` on
  `newFile`.
- `stop()` keys rescue outcomes by file name, so two archives with the same name report the wrong path
  (`ArchivesPlugin.swift:99`).
- A hard-link entry whose path is later reused by a file overwrites that file's content mapping
  (`OpenArchive.swift:320`, `:342`).
- After a failed `upload`, `remoteStamp` may become nil, and remote changes are then never detected
  (`OpenArchive.swift:485`, `:1379`).
- The flush timer runs at `.utility` QoS (`OpenArchive.swift:714`); a user-initiated commit waiting behind it gets a CPU
  override but not its I/O tier.
- `ArchiveURL.make` hex-encodes the outer authority, so the host doubles per nesting level, and there is no nesting
  limit (`ArchiveLocation.swift:48-61`).
- bsdtar and bzip2 inherit the full environment (bzip2 reads `BZIP2`/`BZIP`; libarchive may exec filter helpers found
  via PATH) and are not sandboxed.
- Spools kept by `rescue()` are raw deflate streams with UUID names and no index.

### Shared mutable state and its protection

| State                                                                                                                                                                                        | Guard                                                      | Sufficient?                                                                    |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `OpenArchive`: tree, file, unpacked, memberSource, parked, signature, remoteStamp, comment, password, offsets, unlisted, hasDuplicates, all counters, timer flags, canClone, reportedFailure | `lock`                                                     | Correct. Held too long and across syscalls (finding 6).                        |
| Archive file writes, upload, rescue                                                                                                                                                          | `flushLock`, always taken before `lock`                    | Correct. Not cancellable (findings 5, 16). The Packer bypasses it (finding 9). |
| `format`, `archiveURL`, `quarantine`, `fetchedCopy`                                                                                                                                          | Immutable after init                                       | Yes.                                                                           |
| `ArchiveStore.slots`, `opened`, `clock`, `Slot.lastUsed`                                                                                                                                     | Table lock; it is a leaf (nothing is acquired under it)    | Yes.                                                                           |
| `Slot.archive`, `Slot.failure`                                                                                                                                                               | Slot lock; eviction uses `try` and re-checks membership    | Yes, except the write-start race (finding 24).                                 |
| `ArchiveEnvironment.options`                                                                                                                                                                 | Own lock                                                   | Yes.                                                                           |
| Other `ArchiveEnvironment` fields                                                                                                                                                            | Set once before use                                        | Yes by convention; not enforced.                                               |
| `StreamInterrupt`, `InterruptSlot`                                                                                                                                                           | Own locks; handlers run outside the `StreamInterrupt` lock | Yes. A late interrupt after `release()` cannot reach a parked reader.          |
| `ProcessStream.errors`, `isClosed`                                                                                                                                                           | Own lock; `ended` is owner-thread only                     | Yes.                                                                           |
| `ScratchFolder.folders`, `isKept`; `TemporaryFile.kept`                                                                                                                                      | Static lock / own lock                                     | Yes.                                                                           |
| `ZipMemberWriter`, `ZipPacker`, `ParallelCompressor`, `OutputFile`, `TarReader`, all streams                                                                                                 | Single owner thread; only `interrupt()` crosses threads    | Yes.                                                                           |
| `Unpacker`/`Packer` counters                                                                                                                                                                 | Job thread; `SharedCounter` for bytes                      | Yes. Parallel closures touch only the counter.                                 |

Lock order:

- slot → table;
- slot → archive;
- `flushLock` → archive;
- inner archive → table → outer archive (via `requireEditable`);
- inner `flushLock` → outer archive and outer `flushLock` (via upload).

No inversion was found.

No holder of an archive lock calls the UI. `askPassword` is called with no archive lock held. It can be called while the
inner archive's slot lock is held (fetching a nested archive from an encrypted outer one), which is safe because the
main thread never waits on a slot lock.

### Checked and found sound

- **Parsers**: no trap in 460,000 mutated ZIP, ZIP64, encrypted ZIP, pax/GNU tar, `.tgz` and `.txz` inputs. The fuzzer
  covered directory, local header, extra fields, decrypt/inflate/size-guard/CRC, tar reader, pax records, the xz index,
  the gzip trailer and format detection. Arithmetic in these paths is clamped or range-checked.
- **bsdtar output**: read as a TAR stream, not text, so names with newlines cannot spoof entries. Tools are invoked by
  absolute path with no shell; bzip2 gets `--`, and bsdtar gets `@` plus an absolute path.
- **Children**: terminated children are reaped (20 terminated bsdtar processes, none left). The only pipe the app writes
  to has `F_SETNOSIGPIPE`.
- **Truncated xz, or xz with trailing garbage**: ends with an error; no spin.
- **Flush atomicity**: the archive file is always the complete old or the complete new one, apart from durability
  (finding 8). Disk full mid-append removes the clone and leaves the archive alone. An external change is detected
  before the build and again under the lock before the rename. Two flushes cannot overlap.
- **Readers during a flush**: readers hold records bound to their file object, and listers see the tree only under the
  lock, so both stay consistent.
- **Timer**: pending changes always imply an armed timer or a running flush; no lost wake-up.
- **ZIP64**: thresholds for count, offsets and sizes are handled on write and re-read. Data descriptors are rewritten
  correctly on copy. Stub prefixes are kept.
- **Read-only cases**: duplicate-name archives are read-only on every mutating path. AES entries give a clear "not
  supported" error.
- **Passwords**: the cached password is dropped on a wrong check byte or CRC failure.
- **Parked readers**: taken and returned under the lock. An interrupted reader is never parked.
- **Abandoned or cancelled opens**: nothing is cached, and their scratch files and children are removed.
- **Extraction order**: within one Unpack run, folders are created before any link, and files arrive by temp + exclusive
  rename. A link entry followed by a file below it, or a case collision, cannot write through a link.
- **Ordinary Copy**: never creates links from archive members.
- **Permissions and special files**: setuid/setgid bits are masked for ZIP and TAR. Device and FIFO entries are skipped
  (tar) or written as regular files (ZIP).
- **Quarantine**: propagated to unpacked files and explicit folders.
- **NUL in names**: not truncated by `URL.path`; it stays `%00`.

### Not reviewed

- The project was not built and its test suite was not run. Findings marked "confirmed by reading" were not reproduced
  at runtime.
- Not exercised: crash and power-loss behaviour, non-APFS volumes, and SMB stalls.
- Outside scope: `Tests/`, and FileJob beyond its transfer, temp-name and commit paths.
- Outside scope: the network providers, including whether one can call `askUser` during an upload (which decides the
  deadlock in finding 5).
- Main-thread callers in the shell were checked only by grep.
- Not measured: Apple's LZMA decoder with a multi-GB declared dictionary.
- libarchive's own parsers inside bsdtar are untrusted-input code I did not examine.
