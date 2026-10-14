# Review Viewer second round

## Second-round review: Sources/Plugins/Viewer

I read every file in scope. Nothing in the project was modified or built; experiments are standalone copies under
`…/scratchpad/review2/viewer/` (`m1`–`m9`). "Confirmed" means reproduced there or unambiguous from the code; "plausible"
means reasoned but not run.

### Findings, most severe first

#### 1. CRITICAL · crash · `Model/TextRows.swift:221-228` (`Segment.thin`), called at `:659`

- **Wrong:** `while bytes / Int64(count) * Int64(step) < 4096 { step *= 2 }`. `bytes` is the nominal segment size (4
  MB), but a segment owns every row of a line that starts in it. Once it holds more checkpoints than bytes,
  `bytes / count == 0`, the loop never ends, and `step *= 2` traps on overflow.
- **Trigger:** one line longer than about 268 MB × columns, with wrap on (the default).
  - 10 GB line: crashes below about 37 columns (narrow quick-view pane, or zoomed font; `columnsThatFit` goes down to
    20).
  - 50 GB line: crashes below about 186 columns, which includes the default window.
  - Reproduced with the real 4 MB segment size: a 300 MB line at `textWidth = 1` gives `Trace/BPT trap` (`m6`).
- **Fix:** thin by the span the segment's rows actually cover (first checkpoint offset to end of last row), in floating
  point or as `count * 4096 / span`, and clamp `step`. Better: cap checkpoints while scanning by doubling the stride
  once a segment exceeds N checkpoints.
- **Confidence:** confirmed.

#### 2. HIGH · freeze · `UI/ViewerPane.swift:324` and `:289`; `Model/ByteSource.swift:182-190`

- **Wrong:** `stopWork()` runs on the main thread and calls `loaded?.source.close()`, which closes every idle pooled
  reader synchronously.
  - `SFTPFileReader.close()` does `channel.request(.close, timeout:)`, default 30 s.
  - `FTPReader.close()` does `abortTransfer()`, which waits up to 10 s for a reply.
  - Idle readers are exactly the ones that were not cancelled, so they take the synchronous path.
- **Trigger:** quick view or Lister on an SFTP/FTP file; the server stalls; press Down, F2, N/P, or close the window.
  The UI freezes for the timeout, once per idle reader. On a healthy server it is still a main-thread round trip per
  file change.
- **Fix:** hand `close()` to a background queue (`ProviderByteSource.close`/`deinit`, `CachedByteSource.close`); also
  mark the readers interrupted first so they take the `closeHandleLater` path.
- **Confidence:** confirmed by reading.

#### 3. HIGH · security · `UI/RichViews.swift:281-289` (`WebContentView.decidePolicyFor`)

- **Wrong:** every navigation of type `.other` is allowed. A `<meta http-equiv="refresh">` is delivered as `.other`, and
  the CSP meta tag does not restrict navigation.
- **Trigger:** an HTML file containing `<meta http-equiv="refresh" content="0;url=http://host/…">`, shown in page mode
  (mode 4). The web view requests the URL and renders the remote page with its own subresources and no CSP. That means
  tracking, IP leak, and GET requests against localhost or intranet devices.
- **Reproduced in `m5`:** the local server received `GET /refresh` and then `GET /img.png`. JavaScript stayed off,
  `file://` targets were blocked, and every other vector I tried (img, css, iframe, object, video, font, `@import`,
  ping, form) was blocked.
- **Fix:** allow only the first navigation (`about:blank` or the `WKNavigation` returned by `loadHTMLString`) and cancel
  all later ones. Optionally add a `WKContentRuleList` that blocks all network loads.
- **Confidence:** confirmed.

#### 4. HIGH · freeze/performance/threading · `Model/ByteSource.swift:109-127` (`ProviderByteSource.open`)

- **Wrong, three parts:**
  - `LocalFileSystem.item(at:)` reports `size = 0` for anything whose `lstat` type is not a regular file, including a
    symlink to a regular file. The viewer then "measures" by reading the whole file before showing a byte.
  - The measuring loop never checks the flag. It relies on `reader.interrupt()`, which is a no-op for the local reader,
    so moving on does not stop it.
  - `item.isSpecial` is ignored.
- **Trigger:**
  - F3 on `current.log -> big-50GB.log`: minutes of "Reading…", and every F2 or cursor move leaves another thread
    reading 50 GB to the end.
  - A symlink to `/dev/zero` (trivial to ship in an archive) or `/dev/zero` itself: a thread spins forever, even after
    the window closes.
  - A FIFO: `open()` blocks forever, one GCD thread per visit; enough of them exhaust the pool.
- **Fix:** `try cancellation.throwIfCancelled()` inside the loop; refuse or specially handle `isSpecial`; use the
  resolved size for symlinks (`stat`); open local files with `O_NONBLOCK` and `fstat` for `S_ISREG`.
- **Confidence:** confirmed by reading.

#### 5. MEDIUM · performance · `Model/TextRows.swift:221-228`, `:654-657`, `:391-405`

Same root cause as finding 1, for giant lines that do not crash.

- **Sparse checkpoints:** thinning assumes a 4 MB span, so checkpoints end up `4096 × (line bytes / 4 MB)` apart, up to
  twice that from integer division.
  - Measured: a 256 MB line gives 820 checkpoints, 327 KB apart (`m2`). A 4 MB line in the scaled test kept one
    checkpoint.
  - Extrapolated: 10 GB line → 10–20 MB decoded per page fetch or `row(containing:)`; 50 GB → 50–100 MB. Over a server
    past the 1 GB spill cap, that is downloaded per scroll step.
  - It is fast while the index is partial (stride 64) and becomes slow the moment indexing completes.
- **Quadratic partial publishing:** each partial publish retains the checkpoint arrays, so the next append copies the
  whole list every 4 MB. About 30 GB of memcpy for a 10 GB line at 80 columns; hundreds of GB for 50 GB.
- **Fix:** as in finding 1, plus publish partials without sharing the growing array (append-only chunks).
- **Confidence:** sparse checkpoints confirmed (measured); the memcpy figure is computed.

#### 6. MEDIUM · crash · `Model/CharacterBoundaries.swift:104-106`, `:65-66`, `:74-85`

- **Wrong:** `data[data.startIndex + $0]` is indexed up to the requested length, but a source returns short data once
  the file has shrunk.
- **Trigger:** a cp932/936/949/950 file is truncated or rotated while open, then the user searches with a text or regex
  pattern. Reproduced with a shrinking source: trap (`m3 crash`).
- **Fix:** bound by `data.count`; treat a short read as end of file.
- **Confidence:** confirmed.

#### 7. MEDIUM · security · `UI/RichViews.swift:51-52` (`TemporaryCopies.localURL`), reachable from `UI/ViewerPane.swift:624-630` (`followLink`)

- **Wrong:** the temp file name is `url.lastPathComponent`, which percent-decodes. `sftp://h/dir/..%2F..%2Fx` yields
  `"../../x"`, and `folder.appendingPathComponent` then escapes the per-copy folder and the temp root (`m9`).
  `createFile(atPath:)` truncates whatever exists there.
- **Trigger:** any non-file URL with `%2F` in its last component that reaches a mode needing a local copy (media, Quick
  Look). For example a link in an HTML page, or a URL handed to `ViewerService.view`. An attacker-controlled server
  could overwrite a user-writable file with its own content.
- **Not affected:** names from directory listings, which `isSafeName` filters.
- **Fix:** sanitise to a single component (replace `/`, `:`, NUL; reject `.` and `..`), or always use a fixed name plus
  the extension; verify the standardised target stays under `folder`; create with `O_EXCL`.
- **Confidence:** traversal mechanics confirmed; end-to-end reachability plausible.

#### 8. MEDIUM · security · `UI/RichViews.swift:297-306` (RTF `NSTextView`), `:308-313` (`PDFView`)

- **Wrong:** neither view has a link delegate. Clicking a link in an untrusted RTF or PDF goes to `NSWorkspace.open`
  with any scheme: `file:///…/x.command`, `smb://attacker/…` (mount and credential leak), or app URL schemes.
- **Fix:** `textView(_:clickedOnLink:at:)` and `pdfViewWillClick(onLink:with:)` that pass only http/https/mailto, or
  strip `.link` attributes.
- **Related:** `followLink` (`ViewerPane.swift:627-630`) loads any non-http URL from a page through the provider
  registry, which may be a network provider with an attacker-named host. Restrict it to the base file's own file system
  and folder tree.
- **Confidence:** plausible; framework default behaviour, not run.

#### 9. MEDIUM · freeze/memory · `UI/ViewerPane.swift:505`, `:535-539`, `:557-560`, `:584`

- **Wrong:** HTML page mode and RTF accept files up to `wholeFileLimit` (1 GB).
  - HTML: decoded to UTF-16 (2 GB) and a `String`, then `policy + html` is concatenated and `loadHTMLString` is called
    on the main thread.
  - RTF: parsed in the background, then `setAttributedString` and layout run on the main thread.
- **Trigger:** press 4 on a 900 MB `.html` log, or open a large RTF (RTF opens rich by default).
- **Fix:** cap both at tens of MB, as `htmlTextLimit` does, and fall back to text.
- **Confidence:** confirmed by reading.

#### 10. MEDIUM · freeze · `UI/TextPagerView.swift:81` (`fetchQueue`), `:151-153`

- **Wrong:** one serial queue per pager serves all documents. A read the kernel will not interrupt blocks every later
  fetch, including those of the next file. The local reader has no `interrupt()`, so this applies to stalled SMB/NFS/AFP
  mounts and dying disks.
- **Also:** each `show` starts an index build on a global queue, and each `load` starts a `workQueue` job. Stuck ones
  pile up towards GCD's thread limit and can stall other global-queue work.
- **Fix:** a queue (or operation) per document so a new document never waits behind an old one; cap in-flight builds and
  loads; for local files use non-blocking or `F_NOCACHE` reads with a watchdog, or at least stop issuing new reads on a
  source with a stuck one.
- **Confidence:** plausible.

#### 11. MEDIUM · performance/memory · `UI/ImageCanvasView.swift:117-137` (`ScaledFrameCache.image`)

- **Wrong:** every distinct draw size starts a job on the global queue. Jobs are never cancelled and do not check the
  generation before working. Each allocates up to 160 MB and resamples the full frame at high quality.
- **Trigger:** Ctrl+wheel or pinch on an 8192² image: dozens of stale jobs, about one per core at a time. That is on the
  order of 1–2 GB transient plus all cores busy, and the wanted bitmap arrives last.
- **Related:** while no bitmap is ready, `draw` resamples the full frame with `.high` on the main thread (`:173`,
  `:187`).
- **Fix:** one serial queue; check a `LatestNumber` before scaling; debounce about 100 ms; use `.low`/`.medium` for the
  interim draw.
- **Confidence:** confirmed by reading.

#### 12. MEDIUM · correctness (data loss) · `UI/ViewerPane+Actions.swift:551`

- **Wrong:** Save As calls `createFile(atPath:contents:nil)` on the target before reading. If the user picks the file
  being viewed (the panel offers its name and confirms "Replace"), the file is truncated to zero and then "copied" from
  itself.
- **Fix:** refuse a target that is the same file (`fstat` dev/inode), or write to a temporary file and rename.
- **Confidence:** confirmed by reading.

#### 13. MEDIUM · correctness · `Model/ViewerSearch.swift:224-233`

- **Wrong:** the search range is extended by `length - 1` units past `end`. A case-insensitive match shorter than the
  needle (`ß` for `ss`, `Straße` for `strasse`) can therefore begin exactly at `end`. A backward search then returns the
  match at `start` itself.
- **Trigger:** "Find previous" for `strasse` in a text with `Straße`: after the first hit, every Shift+F3 returns the
  same hit.
- **Evidence:** the search fuzz (7,706 runs) found only this mismatch (`m3`).
- **Fix:** reject `found.location >= end` and continue before it.
- **Confidence:** confirmed.

#### 14. MEDIUM-LOW · correctness · `UI/ImageCanvasView.swift:49-78`

- **Wrong:** any source with `count > 1` is treated as an animation with a 0.1 s default delay. `.icns` (10
  representations measured), `.ico`, multi-page TIFF and HEIC collections become a 10 fps slideshow of different-sized
  images stretched into the first frame's rectangle.
- **Fix:** animate only when the GIF/APNG/WebP/HEICS dictionary carries delay or loop information; otherwise show the
  largest or first image.
- **Confidence:** frame count confirmed; behaviour by reading.

#### 15. MEDIUM-LOW · performance · `UI/RichViews.swift:41-85`, `:27`

- **Wrong:** a remote media or Quick Look file is copied whole to the temp directory, with no size limit and no
  free-space check. Two idle copies are kept until the plugin stops.
- **Trigger:** cursor rests on a 50 GB `.mov` on a server: 50 GB lands on the boot volume.
- **Fix:** size cap or free-space check; count idle copies by bytes.
- **Confidence:** confirmed by reading.

#### 16. MEDIUM-LOW · freeze-adjacent · `Model/FolderSummary.swift:25`

- **Wrong:** uses `provider.list(_:showHidden:)` although a variant taking `cancellation` exists. A listing on a stalled
  server cannot be interrupted and holds `Parallel` pool threads. Quick view also starts an unbounded recursive listing
  of a remote tree whenever the cursor rests on a folder.
- **Fix:** pass the flag; for non-local volumes limit depth or entries, or require a key press.
- **Confidence:** confirmed by reading.

#### 17. LOW · correctness/security · `Model/HTMLText.swift:345-346`, `:115-134`

Measured in `m9`:

- `if a < b then … </p> tail` yields `"if a tail"`: a lone `<` swallows everything up to the next `>`. With no later
  `>`, the rest of the document is dropped (`guard close < count else { return }`).
- `href` is found by substring. `<a data-href="decoy" href="real">` shows and collects the decoy;
  `<a title="x>y" href=…>` breaks the tag.
- **Fix:** treat `<` as a tag only before a letter, `/`, `!` or `?`; honour quotes when finding `>`; require a word
  boundary before `href`.

#### 18. LOW · correctness · `UI/ViewerPane.swift:422`, `:482-490`

- In HTML text mode the Encoding menu and A/S keys change `codePage`, but the stripped text is never re-decoded; the
  menu shows a new checkmark and the text does not change.
- `(try? read) ?? Data()` turns a read error into an empty view with no message.

#### 19. LOW · correctness · `Model/ByteSource.swift:476-497`, `:278-281`, `:293`

- `block()` keeps a short or empty block in the memory LRU (`readAndKeep` guards against this, `block` does not). After
  a transient short read, later reads end early until eviction or F2.
- When `pread` fails, the present bit is cleared but neither `held` nor the global budget is given back.
- The spill file is opened without `O_CLOEXEC`; a child spawned without close-on-exec defaults inherits a descriptor to
  cached remote content.
- With 256 KB blocks, a 1 MB scan chunk is not "long" (`> blockSize * 4` is false). Index scans of remote files
  therefore go block by block through the LRU, contrary to the class comment. It is harmless for correctness.

#### 20. LOW · correctness · `Model/ViewerEncoding.swift:50-57`, `:144-167`

- Multi-byte code pages outside 932/936/949/950 that CF knows (51932 EUC-JP and 54936 GB18030 are available here) are
  accepted by "Other…" but decoded as single-byte, so every high byte becomes U+FFFD. `encode()` for search still uses
  the real encoding.
- **Fix:** reject them, or decode them through CF.

#### 21. LOW · performance · `UI/ViewerPane.swift:645`, `:663-668`; `UI/TextPagerView.swift:460-470`, `:182`

- `pagerResized`, `applySettings` and `changeFontSize` compare `layout` with the shown document, not the pending one. A
  second trigger cancels and restarts an identical pending build.
- Zoom steps are not debounced: each starts a full index build (cancelled by the next).
- The shown document keeps indexing on all cores until the new one is adopted, so two full builds compete.
- A sequential (remote) scan reads a giant line twice: the owning segment reads to its end, then every following segment
  re-reads its own 4 MB while skipping.

#### 22. LOW · threading · `Model/TextRows.swift:288`, `:350`

- `segmentsReused` is written under the lock and read without it (`TextDocument.segmentsReused`). It is test-only, but
  it is a data race.

#### 23. LOW · freeze (short stalls on the main thread)

- **Copy** (`ViewerPane+Actions.swift:450-471`): up to 64 MB of text or 192 MB of hex goes through
  `pasteboard.setString` on the main thread.
- **Print** (`:650-654`): 2 MB into an `NSTextView` plus `sizeToFit` on the main thread.
- **Code tables** (`TextDocument.swift:122`, `ViewerPane+Actions.swift:420`): `CodeTable.table(for:)` can run on the
  main thread. A first DBCS table is about 24,000 CF conversions under a global lock.
- **Row typesetting** (`TextPagerView.swift:759-764`): `CTLine` per row with up to 2 × `unwrapWidth` (32,768) units,
  rebuilt for all visible rows after every fetch.
- **Progress** (`TextPagerView.swift:157-171`): index progress reaches the main thread unthrottled; each tick runs
  `updateChrome`, `updateScrollers` and possibly `reveal`/`restoreCaret`.

#### 24. LOW · memory

- The index for 50 GB of ordinary text or of `\n` is about 120–150 MB (one 12-byte checkpoint per 4–5 KB), doubled while
  a relayout holds the old segments.
- `CharacterBoundaries.known` grows without bound (one entry per 16 KB).
- No pixel-count check before `CGImageSourceCreateThumbnailAtIndex`; a decompression-bomb PNG may be decoded in full by
  ImageIO (plausible).

#### 25. LOW · correctness/leak (smaller items)

- `QLPreviewView` is never stored or `close()`d (`ViewerPane.swift:597`, `dropRichViews`). In the embedded quick view
  its window never closes. Plausible leak.
- `afterLoad` closures of an overtaken fetch run after a later, unrelated load (`TextPagerView.swift:391-404`).
- `topOffset` falls back to the start of the file when the top row is not loaded yet, so a relayout during a fetch jumps
  to the top (`:487`).
- A late `localURL` can insert a copy after `release(owner:)` ran, so it is never idle. `removeAll()` during a copy
  leaves an entry whose file is gone.
- Columns ignore East Asian width and combining marks. Rows can split a base character from its mark, or a ZWJ sequence.
- For RTL runs the selection rectangle uses `to - from`, which is negative, so it draws a 2 px sliver
  (`TextPagerView.swift:839-840`).
- After a failed segment, rows walked from the previous segment overlap the numbering of the next.
- A lookahead or match longer than 64 KB at a chunk border is cut (documented).

### Shared mutable state and its protection

| State                                                                                                                                                  | Protection                                                                                                                                                          | Sufficient?                                                    |
| ------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| `TextRowIndex` (`finished`, `published`, `rows`, `lines`, `coveredEnd`, `complete`, `hasPartial`, `firstFailure`, `parameters`, `scanned`, `previous`) | `NSLock` via `synchronized`; nesting is new → old only                                                                                                              | Yes                                                            |
| `TextRowIndex.segmentsReused`                                                                                                                          | Written under the lock, read without                                                                                                                                | No (finding 22)                                                |
| Scan state (`SegmentScan`, splitter, buffers)                                                                                                          | Thread-local per segment                                                                                                                                            | Yes                                                            |
| `TextDocument.boundaries`, `fetchFailure`                                                                                                              | Own locks                                                                                                                                                           | Yes                                                            |
| `CharacterBoundaries.known`                                                                                                                            | `lock`; `computing` serialises the walk. The order is `computing` → `lock` only. Waiters on `computing` cannot be cancelled.                                        | Yes                                                            |
| `CodeTable.tables`                                                                                                                                     | Static lock, held during the build; tables are immutable afterwards                                                                                                 | Yes, apart from the stall in finding 23                        |
| `ProviderByteSource.idle`                                                                                                                              | `NSLock`; one reader per thread; a reader whose flag is set is closed, never pooled                                                                                 | Yes; I walked the cancel/check-in race and the invariant holds |
| `DiskBlockCache` instance state                                                                                                                        | `lock`, including `pread`/`pwrite` and close, so no use-after-close and no "present before written"                                                                 | Yes                                                            |
| `DiskBlockCache.held` (static)                                                                                                                         | `budget` lock                                                                                                                                                       | Yes, apart from the leak in finding 19                         |
| `CachedByteSource.blocks`/`order`                                                                                                                      | `lock`; double fetch of one block is possible but harmless                                                                                                          | Yes                                                            |
| `TemporaryCopies`                                                                                                                                      | `lock`; file I/O outside it                                                                                                                                         | Yes, apart from the late-insert race in finding 25             |
| `LatestNumber`, `progressScheduled`                                                                                                                    | Locks                                                                                                                                                               | Yes                                                            |
| `ViewerPane`, `TextPagerView`, `ScaledFrameCache`, `ImageCanvasView`, `ListerSettings`                                                                 | Main thread only; I found no background access. Results are gated by `loadGeneration`, `presentGeneration`, `generation`, `revealGeneration` and document identity. | Yes                                                            |
| `CancellationFlag` handlers                                                                                                                            | Run outside the lock on the cancelling thread (the main thread for `stopWork`); reader `interrupt()` implementations are short                                      | Yes                                                            |

### Checked and found sound

- **Index equivalence.** 6,000 fuzz cases compared the raw scan (parallel and sequential, segments 16–1,024 bytes,
  chunks 16–4,096) against a single-pass decode reference, including segment reuse into a second layout. Coverage:
  UTF-8, UTF-16 LE/BE, 1252, 932/936/949/950; CR, LF, CRLF; tabs; NULs; junk bytes; columns 1–80; random access;
  `row(containing:)`. Result: 0 mismatches. This covers CRLF and multi-byte characters across borders, exact-width
  lines, the bulk empty-line path, partial segments and reuse conditions.
- **Pathological inputs (256 MB each).** `\n` only: 0.03 s, checkpoints 4 KB apart. CR only, UTF-16 newlines, all tabs,
  all spaces, UTF-16 full of U+0A0A: all linear and under 1 s.
- **Unsafe code.** Every unchecked buffer access I traced in TextRows, ViewerSearch and HTMLText is guarded. 16-bit
  handling is byte-wise or `loadUnaligned`. No pointer escapes its closure. `Int32` offsets are only ever relative to
  pieces of a few MB or less; file offsets are `Int64` throughout, with the flag packed in bit 0.
- **Decoders.** Lone surrogates, overlong forms and values above U+10FFFF become U+FFFD, so no zero-width unbounded row
  exists. No tested code page maps a high byte to TAB, LF or CR.
- **`CharacterBoundaries` invariant.** It holds for the decoder as implemented: a non-lead byte is either a single-byte
  character or a trail byte, and both end a character. Half-width katakana are non-lead in the table.
- **Search.** Raw and decoded paths agree apart from finding 13, including İ, K, ſ, ligatures, whole-word neighbours,
  chunk borders and backward search. Catastrophic regexes stop within about 50 ms of cancel (`m8`).
- **Spill file.** Per-user temp directory, `O_EXCL`, mode 0600, unlinked immediately, never reopened by path. At the cap
  it simply stops caching; there is no refetch loop.
- **Launch sweep.** Deletes only when `kill(pid, 0)` gives `ESRCH`, so it cannot remove a live instance's folder. PID
  reuse only delays cleanup.
- **`WKWebView`.** JavaScript off, non-persistent store, `baseURL` nil; all subresource vectors blocked. Only the meta
  refresh gets through.
- **Other.** Context-menu links are limited to http/https/www. `HTMLText` is linear on unterminated tags, comments,
  entities and skipped elements. I found no retain cycles. Scroller and percent arithmetic is safe; NaN input is
  harmless.

### Not reviewed

- No run of the app, the test suite, or a build of the project; UI timing claims are from reading.
- Behaviour of `QLPreviewView`, PDFKit, AVKit and ImageIO on hostile files (remote loads in Quick Look SVG/Office/HTML
  previews, PDF page-count or rendering freezes, PNG bombs).
- Whether network and archive providers accept `%2F` or foreign-host URLs end to end (finding 7).
- The cost of `seek` in archive member readers. Archives report `isLocal == true`, so they get the parallel index and
  random access.
- `ParallelPool` and the kernel and providers beyond the reader `close`/`interrupt` paths cited.
