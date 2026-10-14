# Review 2 — viewer

Every item the reviewers, verifiers, stress runs and fuzzers reported for this area. `verdict` items are independent rulings on a finding and sit next to it by file. Status is filled in by the fix round.


## Findings and verdicts

### V001 [finding, critical] B3: the viewer closes pooled remote readers on main (SFTP/FTP close waits the full session timeout).
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Plugins/Viewer/UI/ViewerPane.swift:311-325; Plugins/Viewer/Model/ByteSource.swift:182-190; Plugins/Network/SFTPSession.swift:486-495; Plugins/Network/SFTPSession.swift:186
- **Basis:** read (blocking call, confirmed)
- **Detail:** stopWork -> loaded?.source.close() -> ByteSource -> SFTPSession -> closeHandle :186 waits the full session timeout; FTP about 10 s. Trigger: view a file on a server that stops answering, then press Esc, close the window, or move the cursor with quick view on. Duration: one timeout per idle reader, up to one reader per core. ProviderByteSource.deinit does the same on whichever thread drops the last reference.
- **Proposed fix:** Detach the reader list on main and close it on a background queue (closeHandleLater already exists).
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### V002 [finding, critical] A line longer than about 268 MB x columns makes Segment.thin loop forever and trap on step overflow.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/TextRows.swift:221-228; TextRows.swift:659
- **Basis:** reproduced
- **Detail:** `while bytes / Int64(count) * Int64(step) < 4096 { step *= 2 }`. `bytes` is the nominal segment size (4 MB), but a segment owns every row of a line that starts in it. Once it holds more checkpoints than bytes, bytes/count == 0, the loop never ends and `step *= 2` traps on overflow. Trigger: one line longer than about 268 MB x columns, wrap on (default). 10 GB line crashes below about 37 columns (narrow quick-view pane, zoomed font; columnsThatFit goes down to 20). 50 GB line crashes below about 186 columns, which includes the default window. Reproduced with the real 4 MB segment size: a 300 MB line at textWidth = 1 gives Trace/BPT trap (m6).
- **Proposed fix:** Thin by the span the segment's rows actually cover (first checkpoint offset to end of last row), in floating point or as count * 4096 / span, and clamp step. Better: cap checkpoints while scanning by doubling the stride once a segment exceeds N checkpoints.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V003 [finding, critical] TextRowIndex.Segment.thin(spanning:) overflows and traps when a segment holds more checkpoints than bytes.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/TextRows.swift:225
- **Basis:** reproduced
- **Detail:** `while bytes / Int64(count) * Int64(step) < Int64(TextRowIndex.minimumCheckpointDistance) { step *= 2 }`. A segment owns every row of the lines that begin in it. When it holds more checkpoints (one per 64 rows) than it is bytes long, bytes / count == 0, the loop never ends and step *= 2 overflows Int. Concrete: columns 1, segmentSize 1, one 66-byte line gives 2 checkpoints for a 1-byte segment. In the app with the 4 MiB segment it needs a single line of more than 268,435,456 rows: roughly a 27 GB file without line ends at 100 columns, or 2.7 GB in a 10-column window with wrap on. Reproducer repro/viewer/rows-thin-overflow.bin (75 bytes); confirmed on the unpatched release binary (SIGTRAP, arithmetic overflow at line 225). The copy was patched with a step < 1 << 40 guard (results/PATCHES.txt) so fuzzing could continue. Critical by the rule (viewing a file) but only for an extreme file.
- **Proposed fix:** Use max(1, bytes / Int64(count)), or derive the step directly from count * minimumCheckpointDistance / max(1, bytes).
- **Source:** reports/21-fuzz-target-group-6-viewer.md
- **Status:** open

### V004 [finding, critical] Closing the viewer's pooled readers on main blocks waiting for the server.
**Outcome:** duplicate of V001 — see `status/viewer.md`


- **Where:** Viewer/UI/ViewerPane.swift:311-325; Viewer/Model/ByteSource.swift:499; Viewer/Model/ByteSource.swift:182-188; Network/SFTPSession.swift:490-495; Network/SFTPSession.swift:186; Network/FTPConnection.swift:538-550; Viewer/Model/ByteSource.swift:190
- **Basis:** read (reported as confirmed)
- **Detail:** ViewerPane.stopWork -> loaded?.source.close() -> CachedByteSource.close (:499) -> ProviderByteSource.close (:182-188) closes every idle reader. SFTP: SFTPReader.close (SFTPSession.swift:490-495) -> closeHandle (:186) sends a close request and waits for the full session timeout. FTP: FTPReader.close -> stop() -> abortTransfer (FTPConnection.swift:538-550) waits up to min(timeout,10) s, then up to 2 s per further reply. stopWork runs on main from load (every quick-view cursor move, N/P, F2, a followed link), clear, QuickViewPanel.remove and windowWillClose. Trigger: view a file on a server, the server stops answering, then press Esc, close the window or move the cursor. Duration: the session timeout (SFTP) or about 10 s (FTP), multiplied by up to one idle reader per core.
- **Proposed fix:** Detach the reader list on main and close it on a background queue (the closeHandleLater pattern), or call interrupt() first; treat ProviderByteSource.deinit (:190) the same way.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### V005 [finding, high] ProviderByteSource.open measures symlinks/special files by reading the whole file with an uncancellable loop, hanging on /dev/zero or FIFOs.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/ByteSource.swift:109-127 (ProviderByteSource.open)
- **Basis:** read
- **Detail:** Three parts. (1) LocalFileSystem.item(at:) reports size = 0 for anything whose lstat type is not a regular file, including a symlink to a regular file; the viewer then measures by reading the whole file before showing a byte. (2) The measuring loop never checks the cancel flag; it relies on reader.interrupt(), a no-op for the local reader, so moving on does not stop it. (3) item.isSpecial is ignored. Triggers: F3 on current.log -> big-50GB.log gives minutes of "Reading..." and every F2 or cursor move leaves another thread reading 50 GB to the end. A symlink to /dev/zero (trivial to ship in an archive) or /dev/zero itself: a thread spins forever, even after the window closes. A FIFO: open() blocks forever, one GCD thread per visit; enough of them exhaust the pool.
- **Proposed fix:** try cancellation.throwIfCancelled() inside the loop; refuse or specially handle isSpecial; use the resolved size for symlinks (stat); open local files with O_NONBLOCK and fstat for S_ISREG.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V006 [finding, high] Viewer row-index overflow in step *= 2
**Outcome:** duplicate of V003 — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/TextRows.swift:225
- **Basis:** reproduced
- **Detail:** Overflows when a segment holds more checkpoints than bytes. Critical by the rule (viewing a file) but with the app's 4 MiB segment needs a single line over 268 million rows. Reproducer repro/viewer/rows-thin-overflow.bin (target rows). Patched in the fuzzing copy only (results/PATCHES.txt).
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### V007 [finding, high] Backward search returns the match at the start position (text Straße, pattern ss, case-insensitive, backwards from 4 returns 4..<6).
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/ViewerSearch.swift:225
- **Basis:** reproduced
- **Detail:** The .text case of search uses range first ..< end + length - 1, assuming a match is as long as the needle. Without case, "ss" matches the single unit ß, so a match beginning exactly at end (the excluded start) fits and is returned. User effect: TextPagerView.swift:508 starts a backwards search at selection.lowerBound, so Find Previous would return the same hit every time (UI not run to confirm). Variant: with the start inside a character the returned match begins after the start (repro/viewer/search-backwards-returns-match-after-start-midcharacter.bin). Reproducer: FZ_STRICT=1 fuzz-viewer run search repro/viewer/search-backwards-returns-match-at-start.bin (23 bytes); without FZ_STRICT the driver tolerates this known case. Wrong result, no crash.
- **Proposed fix:** After range(of:), reject any hit with found.location >= end and keep searching before it; do not size the range by the needle's length.
- **Source:** reports/21-fuzz-target-group-6-viewer.md
- **Status:** open

### V008 [finding, high] Backwards viewer search returns the match at the start position
**Outcome:** duplicate of V007 — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/ViewerSearch.swift:225
- **Basis:** reproduced
- **Detail:** Range assumes a match is as long as the needle ('ss' matches 'ß'), so Find Previous would repeat the same hit. Reproducer: FZ_STRICT=1 ... fuzz-viewer run search repro/viewer/search-backwards-returns-match-at-start.bin.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### V009 [finding, high] HTML page mode allows meta-refresh navigation (type .other), so a hostile HTML file loads a remote page.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/RichViews.swift:281-289 (WebContentView.decidePolicyFor)
- **Basis:** reproduced
- **Detail:** Every navigation of type .other is allowed. A <meta http-equiv="refresh"> is delivered as .other and the CSP meta tag does not restrict navigation. Trigger: HTML file with meta refresh to http://host/..., shown in page mode (mode 4). The web view requests the URL and renders the remote page with its own subresources and no CSP: tracking, IP leak, GET requests against localhost or intranet devices. Reproduced in m5: local server received GET /refresh then GET /img.png. JavaScript stayed off, file:// targets were blocked, and every other vector tried (img, css, iframe, object, video, font, @import, ping, form) was blocked.
- **Proposed fix:** Allow only the first navigation (about:blank or the WKNavigation returned by loadHTMLString) and cancel all later ones. Optionally add a WKContentRuleList that blocks all network loads.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V010 [verdict, high] Save As onto the viewed file can empty it
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/ViewerPane+Actions.swift:551; Sources/Plugins/Viewer/UI/ViewerPane+Actions.swift:557; Sources/Plugins/Viewer/Model/ByteSource.swift:166-172
- **Basis:** PARTLY CONFIRMED (ran at source level)
- **Detail:** createFile(atPath:contents:nil) replaces the file with an empty one before any read but with a new inode. Normal case: ProviderByteSource usually holds an idle reader on the old inode; a 5,000,000-byte file saved onto itself intact. Failing case: after source.close() the same save left 0 bytes and no error because guard !block.isEmpty else { break } (557) returns success. Unproven: natural trigger where all idle readers are checked out by a running parallel index build so the save opens a fresh reader on the empty file (reading only).
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### V011 [finding, high] stopWork() on the main thread synchronously closes idle pooled readers, so a stalled SFTP/FTP server freezes the UI.
**Outcome:** duplicate of V001 — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/ViewerPane.swift:324; ViewerPane.swift:289; Sources/Plugins/Viewer/Model/ByteSource.swift:182-190
- **Basis:** read
- **Detail:** stopWork() runs on the main thread and calls loaded?.source.close(), which closes every idle pooled reader synchronously. SFTPFileReader.close() does channel.request(.close, timeout:), default 30 s. FTPReader.close() does abortTransfer(), which waits up to 10 s for a reply. Idle readers are exactly the ones not cancelled, so they take the synchronous path. Trigger: quick view or Lister on an SFTP/FTP file; server stalls; press Down, F2, N/P or close the window. UI freezes for the timeout, once per idle reader. On a healthy server it is still a main-thread round trip per file change.
- **Proposed fix:** Hand close() to a background queue (ProviderByteSource.close/deinit, CachedByteSource.close); also mark the readers interrupted first so they take the closeHandleLater path.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V012 [finding, high] ProviderByteSource.deinit closes the same readers on whichever thread drops the last reference, often main.
**Outcome:** duplicate of V001 — see `status/viewer.md`


- **Where:** Viewer/Model/ByteSource.swift:190
- **Basis:** read (reported as confirmed)
- **Detail:** Same blocking close as F1 (blocking call), run from deinit on whichever thread releases the last reference, which is often main.
- **Proposed fix:** Same fix as F1: close readers on a background queue / interrupt first.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### V013 [finding, medium] HTML page mode loads remote content via meta refresh (the 'nothing is loaded from elsewhere' claim is false).
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Plugins/Viewer/UI/ViewerPane.swift:558; Plugins/Viewer/UI/ViewerPane.swift:584; Plugins/Viewer/UI/RichViews.swift:278; Plugins/Viewer/UI/RichViews.swift:281-288; Plugins/Viewer/UI/ViewerPane.swift:624-630
- **Basis:** reproduced
- **Detail:** loadHTMLString with CSP meta prepended; delegate allows every .other navigation. <meta http-equiv="refresh" content="0;url=https://evil/..."> is a .other navigation and CSP does not govern navigations. Reproduced with the same configuration: the request was sent and the web view ended on the remote URL. Result: IP/open beacon and remote CSP-free content inside the viewer (JavaScript stays off). Related: followLink loads any non-http link into the viewer, so a click on ftp://evil/x or sftp://... opens a connection (see 6).
- **Proposed fix:** Allow only the first navigation (or only about:blank) and cancel the rest; in followLink accept only relative links and file: in the same folder.
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### V014 [verdict, medium] Viewer measuring loop cannot be cancelled
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/ByteSource.swift:119-124; Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:338-349; Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:327; Sources/AFMKernel/FileSystem/FileSystemProvider.swift:111-113
- **Basis:** CONFIRMED (read); reproduced in one run only
- **Detail:** No flag check inside the loop; relies on reader.interrupt() which the local reader does not implement (default does nothing). LocalFileSystem.item(at:) uses lstat and reports size 0 for anything not a regular file; a symlink to a 5,000-byte file has size 0. Run: opening a symlink to /dev/zero and cancelling at 0.3 s was still reading at 5.3 s; no control with a regular file or larger timeout, so it shows the loop outliving cancel, not how long. Consequence from the code: a symlink to a large file is read to the end before anything shows, endless device never finishes.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### V015 [finding, medium] CharacterBoundaries indexes past a short read, trapping when a cp932/936/949/950 file shrinks while searched.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/CharacterBoundaries.swift:104-106; CharacterBoundaries.swift:65-66; CharacterBoundaries.swift:74-85
- **Basis:** reproduced
- **Detail:** data[data.startIndex + $0] is indexed up to the requested length, but a source returns short data once the file has shrunk. Trigger: a cp932/936/949/950 file is truncated or rotated while open, then the user searches with a text or regex pattern. Reproduced with a shrinking source: trap (m3 crash).
- **Proposed fix:** Bound by data.count; treat a short read as end of file.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V016 [verdict, medium] CharacterBoundaries indexes past data on a shrunk file
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/CharacterBoundaries.swift:105-106; Sources/Plugins/Viewer/Model/CharacterBoundaries.swift:65-66; Sources/Plugins/Viewer/Model/CharacterBoundaries.swift:78; Sources/Plugins/Viewer/Model/ViewerSearch.swift:274
- **Basis:** CONFIRMED (ran)
- **Detail:** Both index data up to the requested length not the length returned. Trigger: text in code page 932/936/949/950, file truncated after loading, then a search reaching a chunk past the first. With a source reporting 200,000 bytes but returning 50,000, characterStart traps at 106 and ViewerSearch.find traps at 78; control with full file returns 150000. Crash; other encodings never reach this code.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### V017 [finding, medium] Giant lines get sparse checkpoints (and quadratic partial publishing), making page fetches and row(containing:) slow once indexing completes.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/TextRows.swift:221-228; TextRows.swift:654-657; TextRows.swift:391-405
- **Basis:** measured (sparse checkpoints); memcpy figure computed
- **Detail:** Same root cause as finding 1 for giant lines that do not crash. Sparse checkpoints: thinning assumes a 4 MB span, so checkpoints end up 4096 x (line bytes / 4 MB) apart, up to twice that from integer division. Measured: a 256 MB line gives 820 checkpoints, 327 KB apart (m2); a 4 MB line in the scaled test kept one checkpoint. Extrapolated: 10 GB line -> 10-20 MB decoded per page fetch or row(containing:); 50 GB -> 50-100 MB; over a server past the 1 GB spill cap, that is downloaded per scroll step. Fast while the index is partial (stride 64), slow the moment indexing completes. Quadratic partial publishing: each partial publish retains the checkpoint arrays, so the next append copies the whole list every 4 MB; about 30 GB of memcpy for a 10 GB line at 80 columns, hundreds of GB for 50 GB (computed).
- **Proposed fix:** As in finding 1, plus publish partials without sharing the growing array (append-only chunks).
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V018 [verdict, medium] Segment.thin traps on overflow
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/TextRows.swift:223-225; Sources/Plugins/Viewer/Model/TextRows.swift; Sources/Plugins/Viewer/UI/TextPagerView.swift:296; Sources/Plugins/Viewer/Model/ViewerSettings.swift:78
- **Basis:** CONFIRMED (ran) as a trap; 'never terminates' REFUTED
- **Detail:** When a segment has more checkpoints than bytes, bytes/count is 0 so 0*step < 4096 holds forever and step *= 2 overflows after 62 doublings (crash report 'arithmetic overflow' at line 225). Trigger: one line starting in a 4 MiB segment producing more than 4,194,304 checkpoints (>~268 million rows): a 300 MB line at width 1, or a 10 GB line under about 37 columns. Width 1 settable (allows 1..16384); with window width the floor is 20 columns. Direct call with 5 checkpoints over 4 bytes traps; TextRowIndex.build with 64-byte segments and a 12,288-byte line at width 1 traps; controls just under the limit return. Consequence: app crashes at end of indexing. 'Never terminates' part REFUTED.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### V019 [finding, medium] Backward case-insensitive search returns the match at the start position itself (Straße / strasse), so Find Previous repeats the same hit.
**Outcome:** duplicate of V007 — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/ViewerSearch.swift:224-233
- **Basis:** reproduced
- **Detail:** The search range is extended by length - 1 units past end. A case-insensitive match shorter than the needle (ß for ss, Straße for strasse) can begin exactly at end; a backward search then returns the match at start itself. Trigger: Find previous for "strasse" in a text with "Straße": after the first hit every Shift+F3 returns the same hit. The search fuzz (7,706 runs) found only this mismatch (m3).
- **Proposed fix:** Reject found.location >= end and continue before it.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V020 [finding, medium] ScaledFrameCache starts uncancelled, unchecked resample jobs for every draw size, burning cores and 1-2 GB on zoom.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/ImageCanvasView.swift:117-137 (ScaledFrameCache.image); ImageCanvasView.swift:173; ImageCanvasView.swift:187
- **Basis:** read
- **Detail:** Every distinct draw size starts a job on the global queue. Jobs are never cancelled and do not check the generation before working. Each allocates up to 160 MB and resamples the full frame at high quality. Trigger: Ctrl+wheel or pinch on an 8192^2 image: dozens of stale jobs, about one per core at a time; on the order of 1-2 GB transient plus all cores busy, and the wanted bitmap arrives last. Related: while no bitmap is ready, draw resamples the full frame with .high on the main thread (:173, :187).
- **Proposed fix:** One serial queue; check a LatestNumber before scaling; debounce about 100 ms; use .low/.medium for the interim draw.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V021 [finding, medium] RTF NSTextView and PDFView have no link delegate, so clicking a link in an untrusted file opens any URL scheme.
**Outcome:** fixed — see `status/plugins-b-p2.md`


- **Where:** Sources/Plugins/Viewer/UI/RichViews.swift:297-306; RichViews.swift:308-313; Sources/Plugins/Viewer/UI/ViewerPane.swift:627-630 (followLink)
- **Basis:** inferred (plausible; framework default behaviour, not run)
- **Detail:** Clicking a link in an untrusted RTF or PDF goes to NSWorkspace.open with any scheme: file:///.../x.command, smb://attacker/... (mount and credential leak), or app URL schemes. Related: followLink (ViewerPane.swift:627-630) loads any non-http URL from a page through the provider registry, which may be a network provider with an attacker-named host.
- **Proposed fix:** textView(_:clickedOnLink:at:) and pdfViewWillClick(onLink:with:) that pass only http/https/mailto, or strip .link attributes. Restrict followLink to the base file's own file system and folder tree.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V022 [finding, medium] TemporaryCopies.localURL uses a percent-decoded lastPathComponent, allowing path traversal and truncation of an arbitrary user-writable file.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/RichViews.swift:51-52 (TemporaryCopies.localURL); Sources/Plugins/Viewer/UI/ViewerPane.swift:624-630 (followLink)
- **Basis:** traversal mechanics reproduced (m9); end-to-end reachability plausible
- **Detail:** Temp file name is url.lastPathComponent, which percent-decodes. sftp://h/dir/..%2F..%2Fx yields "../../x", and folder.appendingPathComponent then escapes the per-copy folder and the temp root (m9). createFile(atPath:) truncates whatever exists there. Trigger: any non-file URL with %2F in its last component reaching a mode needing a local copy (media, Quick Look), e.g. a link in an HTML page or a URL handed to ViewerService.view. An attacker-controlled server could overwrite a user-writable file with its own content. Not affected: names from directory listings, which isSafeName filters.
- **Proposed fix:** Sanitise to a single component (replace /, :, NUL; reject . and ..), or always use a fixed name plus the extension; verify the standardised target stays under folder; create with O_EXCL.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V023 [verdict, medium] Remote URL last path component traversal overwrites a local file (viewer download primitive)
**Outcome:** duplicate of V022 — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/RichViews.swift:51; Sources/Plugins/Viewer/UI/ViewerPane.swift:623-630; Sources/Plugins/Viewer/UI/ViewerPane.swift:561
- **Basis:** PARTLY CONFIRMED: primitive CONFIRMED (ran), full chain unproven
- **Detail:** lastPathComponent of ftp://h/a/..%2F..%2Fx returns ../../x on this OS, giving <folder>/../../x; createFile truncates an existing file. Listings cannot produce this (appending(name:) encodes %). Routes: followLink loads any absolute href from a viewed page, tab files, typed URLs, cm_List <url>. Only .media/.other content takes this path. Precondition: malicious server plus viewed page and a click, or crafted URL. Medium if chain works: server-chosen path overwritten with server content.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### V024 [finding, medium] One serial fetchQueue per pager blocks all later fetches (including the next file) behind an uninterruptible read; stuck builds/loads pile up on GCD.
**Outcome:** fixed — see `status/plugins-b-p2.md`


- **Where:** Sources/Plugins/Viewer/UI/TextPagerView.swift:81 (fetchQueue); TextPagerView.swift:151-153
- **Basis:** inferred (plausible)
- **Detail:** One serial queue per pager serves all documents. A read the kernel will not interrupt blocks every later fetch, including those of the next file. The local reader has no interrupt(), so this applies to stalled SMB/NFS/AFP mounts and dying disks. Also: each show starts an index build on a global queue and each load starts a workQueue job; stuck ones pile up towards GCD's thread limit and can stall other global-queue work.
- **Proposed fix:** A queue (or operation) per document so a new document never waits behind an old one; cap in-flight builds and loads; for local files use non-blocking or F_NOCACHE reads with a watchdog, or at least stop issuing new reads on a source with a stuck one.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V025 [finding, medium] Save As truncates the target before reading, so choosing the viewed file as the target destroys it.
**Outcome:** duplicate of V010 — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/ViewerPane+Actions.swift:551
- **Basis:** read
- **Detail:** Save As calls createFile(atPath:contents:nil) on the target before reading. If the user picks the file being viewed (the panel offers its name and confirms "Replace"), the file is truncated to zero and then "copied" from itself (data loss).
- **Proposed fix:** Refuse a target that is the same file (fstat dev/inode), or write to a temporary file and rename.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V026 [finding, medium] Save As reports success on a short read
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/ViewerPane+Actions.swift:557
- **Basis:** reproduced
- **Detail:** Breaks on an empty block and returns nil, so any read that ends early produces a truncated copy with no error. Seen in the claim 3 run.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### V027 [verdict, medium] ViewerPane.stopWork closes remote readers on main
**Outcome:** duplicate of V001 — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/ViewerPane.swift:324; Sources/Plugins/Viewer/Model/ByteSource.swift:182-188; Sources/Plugins/Network/SFTPSession.swift:486-490; Sources/Plugins/Network/SFTPSession.swift:186-188; Sources/Plugins/Network/FTPSession.swift:713; Sources/Plugins/Network/FTPConnection.swift:538-552
- **Basis:** CONFIRMED (read)
- **Detail:** SFTP closeHandle is a synchronous request with 30 s default timeout; FTP stop() -> abortTransfer() waits up to 10 s for a reply. Up to one idle reader per core closed one after another. Freeze when closing the viewer or switching quick-view file while server is slow.
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

### V028 [finding, medium] HTML page mode and RTF accept files up to the 1 GB wholeFileLimit and process them on the main thread.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/ViewerPane.swift:505; ViewerPane.swift:535-539; ViewerPane.swift:557-560; ViewerPane.swift:584
- **Basis:** read
- **Detail:** HTML: decoded to UTF-16 (2 GB) and a String, then policy + html is concatenated and loadHTMLString is called on the main thread. RTF: parsed in background, then setAttributedString and layout run on the main thread. Trigger: press 4 on a 900 MB .html log, or open a large RTF (RTF opens rich by default).
- **Proposed fix:** Cap both at tens of MB, as htmlTextLimit does, and fall back to text.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V029 [finding, medium] followLink loads any absolute URL in the viewer
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/ViewerPane.swift:623-630
- **Basis:** read
- **Detail:** Any href that is not http, https or mailto is opened in the viewer, including file:///... and other servers. This is the route that makes claim 5 reachable.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### V030 [finding, medium] Viewer completions do large work on main: print, copy selection, HTML, RTF, first image draw.
**Outcome:** fixed — see `status/plugins-b-p2.md`


- **Where:** Viewer/UI/ViewerPane+Actions.swift:650-654; Viewer/UI/ViewerPane+Actions.swift:466-467; Viewer/UI/ViewerPane.swift:584; Viewer/UI/RichViews.swift:299; Viewer/UI/ImageCanvasView.swift:173,187
- **Basis:** inferred (plausible)
- **Detail:** printContent (:650-654): sizeToFit lays out up to 2 MB of text; estimated 0.5-3 s. copySelection (:466-467): setString of up to 64 MB, or about 192 MB as hex; 0.1-0.5 s. show(html:) (ViewerPane.swift:584): loadHTMLString with up to 1 GB (wholeFileLimit). RTF view (RichViews.swift:299): setAttributedString with up to 1 GB. First image draw (ImageCanvasView.swift:173,187): a frame of up to 8192^2 drawn with high interpolation until the scaled bitmap is ready; estimated 0.1-0.4 s. Scaling, plausible.
- **Proposed fix:** Lower the limits for HTML and RTF, load HTML from a temporary file, and draw at low quality until the bitmap exists.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### V031 [finding, medium] Viewer closes pooled readers and deletes temp copies/folders on the main thread (stopWork, stale load, deinit, TemporaryCopies.release, ViewerPlugin.stop).
**Outcome:** fixed — see `status/plugins-b-p2.md`


- **Where:** Viewer/UI/ViewerPane.swift:324; Viewer/Model/ByteSource.swift:499-502; Viewer/Model/ByteSource.swift:182-188; Viewer/Model/ByteSource.swift:315; Viewer/UI/ViewerPane.swift:289; Viewer/Model/ByteSource.swift:190; Viewer/UI/ViewerPane.swift:253; Viewer/UI/ViewerPane.swift:331; Viewer/UI/ViewerPane.swift:317; Viewer/UI/ViewerPane.swift:146; Viewer/UI/RichViews.swift:117; Viewer/ViewerPlugin.swift:112; Viewer/UI/RichViews.swift:127
- **Basis:** read
- **Detail:** ViewerPane.stopWork calls loaded?.source.close() -> CachedByteSource.close -> ProviderByteSource.close, which calls FileReader.close() on up to activeProcessorCount idle readers, then spill.discard(). stopWork is main-only; callers are load (:251), clear (:329), ViewerWindowController.windowWillClose (:115) and QuickViewPanel.remove (:93). Same class: ViewerPane.swift:289 closes the source of a stale load on main; ProviderByteSource.deinit closes readers on whichever thread drops the last reference (main for loaded = nil at ViewerPane.swift:253 and :331); temporaryCopies.release (ViewerPane.swift:317, :146 in deinit) runs evict which calls FileManager.removeItem on main; ViewerPlugin.stop runs removeAll which deletes the whole root on main. Effect: every cursor move in quick view runs this; a network reader whose close() does a round trip stalls the UI.
- **Proposed fix:** Hand the source and the doomed folders to a background queue to close and delete.
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V032 [finding, low] Row index for 50 GB of ordinary text or newlines is about 120-150 MB, doubled during relayout.
**Outcome:** not a defect — see `status/viewer.md`


- **Basis:** inferred
- **Detail:** One 12-byte checkpoint per 4-5 KB; about 120-150 MB for 50 GB, doubled while a relayout holds the old segments.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V033 [finding, low] CharacterBoundaries.known grows without bound (one entry per 16 KB).
**Outcome:** fixed — see `status/viewer.md`


- **Basis:** read
- **Detail:** CharacterBoundaries.known grows without bound, one entry per 16 KB.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V034 [finding, low] No pixel-count check before CGImageSourceCreateThumbnailAtIndex; a decompression-bomb PNG may be decoded in full.
**Outcome:** fixed — see `status/plugins-b-p2.md`


- **Basis:** inferred
- **Detail:** No pixel-count check before CGImageSourceCreateThumbnailAtIndex; a decompression-bomb PNG may be decoded in full by ImageIO (plausible).
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V035 [finding, low] Columns ignore East Asian width and combining marks; rows can split a base character from its mark or a ZWJ sequence.
**Outcome:** fixed — see `status/plugins-b-p2.md`


- **Basis:** read
- **Detail:** Columns ignore East Asian width and combining marks. Rows can split a base character from its mark, or a ZWJ sequence.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V036 [finding, low] After a failed segment, rows walked from the previous segment overlap the numbering of the next.
**Outcome:** fixed — see `status/viewer.md`


- **Basis:** read
- **Detail:** After a failed segment, rows walked from the previous segment overlap the numbering of the next.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V037 [finding, low] A lookahead or match longer than 64 KB at a chunk border is cut (documented).
**Outcome:** not a defect — see `status/viewer.md`


- **Basis:** read
- **Detail:** A lookahead or match longer than 64 KB at a chunk border is cut (documented).
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V038 [finding, low] Viewer leftovers: TemporaryCopies owner key outlives its pane and removeAll races an in-flight copy; Splitter closes its reader twice on error; createChecksums clears the selection with no directory check.
**Outcome:** duplicate — see `status/plugins-b-p2.md`


- **Where:** Plugins/FileTools/FileToolsPlugin.swift:291
- **Basis:** read (reviewer)
- **Detail:** Reviewer-reported.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### V039 [finding, low] RTF and PDF links open any scheme (no link delegate on NSTextView/PDFView), e.g. file:///Volumes/USB/x.app or smb://evil/share go to LaunchServices.
**Outcome:** duplicate of V021 — see `status/viewer.md`


- **Where:** Plugins/Viewer/UI/RichViews.swift:297-313
- **Basis:** inferred (plausible; framework default behaviour, not tested)
- **Detail:** 
- **Proposed fix:** Implement textView(_:clickedOnLink:at:) and pdfViewWillClick(onLink:with:); allow http/https/mailto after showing the real URL.
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### V040 [finding, low] AppKit objects can be deallocated off main: TextPagerView (self? in indexing thread).
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Plugins/Viewer/UI/TextPagerView.swift:152
- **Basis:** read (reviewer)
- **Detail:** Medium-low; reviewer-reported.
- **Proposed fix:** Capture weakly in the outer closure and take the strong reference only inside main.async.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### V041 [finding, low] A file truncated during indexing ends complete with fewer rows and no error.
**Outcome:** duplicate of V042 — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/ByteSource.swift:139-153
- **Basis:** measured
- **Detail:** Relayed from fork.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### V042 [finding, low] A file truncated during indexing is reported as complete with no error but fewer rows.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/ByteSource.swift:139-153; Sources/Plugins/Viewer/Model/TextRows.swift:561
- **Basis:** measured
- **Detail:** Document ended with isIndexComplete == true, indexedThrough == length and readError == nil but fewer rows (e.g. 3.09 M instead of 13.35 M); rows(from:) then returned empty for known rows 704,854 times without an error. Removal of the file is reported correctly through readError. No crash or hang in any of the 12 rounds. Short reads are treated as end of text.
- **Proposed fix:** Record an error when a read inside 0..<length comes back short.
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### V043 [finding, low] block() keeps short blocks in the LRU, pread failure leaks budget, spill file lacks O_CLOEXEC, and long-scan path is not used with 256 KB blocks.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/ByteSource.swift:476-497; ByteSource.swift:278-281; ByteSource.swift:293
- **Basis:** read
- **Detail:** block() keeps a short or empty block in the memory LRU (readAndKeep guards against this, block does not); after a transient short read later reads end early until eviction or F2. When pread fails the present bit is cleared but neither `held` nor the global budget is given back. The spill file is opened without O_CLOEXEC; a child spawned without close-on-exec defaults inherits a descriptor to cached remote content. With 256 KB blocks a 1 MB scan chunk is not "long" (> blockSize * 4 is false), so index scans of remote files go block by block through the LRU, contrary to the class comment; harmless for correctness.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V044 [finding, low] FolderSummary lists with the non-cancellable provider.list and starts an unbounded recursive remote listing whenever quick view rests on a folder.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/FolderSummary.swift:25
- **Basis:** read
- **Detail:** Uses provider.list(_:showHidden:) although a variant taking cancellation exists. A listing on a stalled server cannot be interrupted and holds Parallel pool threads. Quick view also starts an unbounded recursive listing of a remote tree whenever the cursor rests on a folder. Report severity label: MEDIUM-LOW (freeze-adjacent).
- **Proposed fix:** Pass the flag; for non-local volumes limit depth or entries, or require a key press.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V045 [finding, low] HTMLText.plainText: a lone '<' swallows text up to the next '>' and href is matched by substring.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/HTMLText.swift:345-346; HTMLText.swift:115-134
- **Basis:** measured
- **Detail:** Measured in m9: `if a < b then ... </p> tail` yields "if a tail": a lone < swallows everything up to the next >. With no later >, the rest of the document is dropped (guard close < count else { return }). href is found by substring: `<a data-href="decoy" href="real">` shows and collects the decoy; `<a title="x>y" href=...>` breaks the tag.
- **Proposed fix:** Treat < as a tag only before a letter, /, ! or ?; honour quotes when finding >; require a word boundary before href.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V046 [finding, low] CodeTable.table(for:) can run on the main thread; a first DBCS table is about 24,000 CF conversions under a global lock.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/TextDocument.swift:122; Sources/Plugins/Viewer/UI/ViewerPane+Actions.swift:420
- **Basis:** read
- **Detail:** Short main-thread stall: CodeTable.table(for:) can run on the main thread. A first DBCS table is about 24,000 CF conversions under a global lock.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V047 [verdict, low] Segment.thin 'never terminates' part
**Outcome:** refuted — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/TextRows.swift:223-225
- **Basis:** REFUTED
- **Detail:** step *= 2 overflows after 62 doublings, so it traps rather than looping forever.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### V048 [finding, low] Viewer index lock: one 202 ms main-thread wait on the viewer's index lock.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/TextRows.swift:272
- **Basis:** measured
- **Detail:** Relayed from fork.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### V049 [finding, low] TextRowIndex.segmentsReused is written under the lock and read without it (data race, test-only).
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/TextRows.swift:288; TextRows.swift:350
- **Basis:** read
- **Detail:** segmentsReused is written under the lock and read without it (TextDocument.segmentsReused). Test-only but a data race.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V050 [finding, low] Multi-byte code pages outside 932/936/949/950 (51932 EUC-JP, 54936 GB18030) are accepted by Other... but decoded single-byte.
**Outcome:** fixed — see `status/plugins-b-p2.md`


- **Where:** Sources/Plugins/Viewer/Model/ViewerEncoding.swift:50-57; ViewerEncoding.swift:144-167
- **Basis:** read
- **Detail:** Multi-byte code pages that CF knows (51932 EUC-JP and 54936 GB18030 available here) are accepted by "Other..." but decoded as single-byte, so every high byte becomes U+FFFD. encode() for search still uses the real encoding.
- **Proposed fix:** Reject them, or decode them through CF.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V051 [finding, low] Search target executions: 25,172 ASan and 574,186 release execs gave 3 mismatch signatures from 2 root causes (findings 2 and 3).
**Outcome:** duplicate of V007 — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/ViewerSearch.swift
- **Basis:** reproduced
- **Detail:** 0 crashes, 0 hangs or over-memory cases; 3 property-mismatch signatures.
- **Source:** reports/21-fuzz-target-group-6-viewer.md
- **Status:** open

### V052 [finding, low] Search result depends on path and chunk size when ignorable characters are involved (case-insensitive NSString range(of:) ignores control characters).
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/ViewerSearch.swift:227
- **Basis:** reproduced
- **Detail:** text.range(of: needle, options: [.literal, .caseInsensitive]). Once the text is not plain ASCII, Foundation's case-insensitive search ignores control and other ignorable characters (U+0000-0008, U+001B, U+200B etc.; not tab) on both sides (checked with a standalone NSString test). The raw byte path compares exactly, so the answer depends on which path a chunk takes. Such matches differ in length from the needle, so the range.length >= length and end + length - 1 arithmetic makes the answer depend on chunk size. Counterexamples: pattern "\u{1B}9" in bytes 39 AE (UTF-8): raw path nil, decoded path 0..<1 (repro search-raw-vs-decoded-ignorable-characters.bin, 11 bytes). Pattern "0\u{03}" in 72 bytes: chunked nil, whole 59..<60 (repro search-chunked-vs-whole-ignorable-characters.bin, 81 bytes). Inconsistent result, no crash. Both mismatch signatures share this cause (3 signatures, 2 root causes).
- **Proposed fix:** Verify each NSString hit against the needle (folded units and length), or do the case-folded unit comparison yourself.
- **Source:** reports/21-fuzz-target-group-6-viewer.md
- **Status:** open

### V053 [finding, low] Viewer search result depends on path and chunk size with ignorable characters
**Outcome:** duplicate of V052 — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/Model/ViewerSearch.swift:227
- **Basis:** reproduced
- **Detail:** Two reproducers in repro/viewer/.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### V054 [finding, low] Any multi-frame image (.icns, .ico, multi-page TIFF, HEIC collections) is played as a 10 fps animation.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/ImageCanvasView.swift:49-78
- **Basis:** measured (frame count); behaviour read
- **Detail:** Any source with count > 1 is treated as an animation with a 0.1 s default delay. .icns (10 representations measured), .ico, multi-page TIFF and HEIC collections become a 10 fps slideshow of different-sized images stretched into the first frame's rectangle. Report severity label: MEDIUM-LOW (correctness).
- **Proposed fix:** Animate only when the GIF/APNG/WebP/HEICS dictionary carries delay or loop information; otherwise show the largest or first image.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V055 [finding, low] TemporaryCopies: a late localURL can insert a copy after release(owner:), and removeAll() during a copy leaves an entry whose file is gone.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/RichViews.swift
- **Basis:** read
- **Detail:** A late localURL can insert a copy after release(owner:) ran, so it is never idle. removeAll() during a copy leaves an entry whose file is gone.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V056 [verdict, low] RTF/PDF hostile links in the viewer
**Outcome:** duplicate of V021 — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/RichViews.swift
- **Basis:** PARTLY CONFIRMED (RTF parse only; opening unproven; PDF unproven)
- **Detail:** RTF: NSAttributedString(rtf:) kept x-evil-scheme://... and file:///...Calculator.app as .link and the viewer has no clickedOnLink or PDFViewDelegate; parsing CONFIRMED, what AppKit opens on click not shown. PDF: unproven. Precondition: user clicks a link.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### V057 [verdict, low] HTML meta refresh navigation loads remote content in page mode
**Outcome:** duplicate of V009 — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/RichViews.swift:281-289; Sources/Plugins/Viewer/Model/ViewerSettings.swift:87
- **Basis:** CONFIRMED (ran)
- **Detail:** RichViews allows every .other navigation; CSP does not cover navigation. Headless WKWebView with same config fetched http://127.0.0.1:18473/refresh and showed it. JavaScript stayed off; <img>, <iframe>, CSS, <video>, <object> produced no request; file:// refresh blocked. Precondition: user views hostile HTML in page mode (not default; viewer.htmlAsText defaults true). IP disclosure, remote content in the viewer.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### V058 [finding, low] Remote media/Quick Look files are copied whole to temp with no size limit or free-space check; two idle copies are kept.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/RichViews.swift:41-85; RichViews.swift:27
- **Basis:** read
- **Detail:** Cursor resting on a 50 GB .mov on a server puts 50 GB on the boot volume. Two idle copies are kept until the plugin stops. Report severity label: MEDIUM-LOW (performance).
- **Proposed fix:** Size cap or free-space check; count idle copies by bytes.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V059 [finding, low] Index progress reaches the main thread unthrottled; each tick runs updateChrome, updateScrollers and possibly reveal/restoreCaret.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/TextPagerView.swift:157-171
- **Basis:** read
- **Detail:** Short main-thread stalls: index progress reaches the main thread unthrottled; each tick runs updateChrome, updateScrollers and possibly reveal/restoreCaret.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V060 [finding, low] One 202 ms main-thread stall waiting on the text-row index lock (TextPagerView.isIndexing -> TextRowIndex.isComplete).
**Outcome:** duplicate of V048 — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/TextPagerView.swift:260; Sources/Plugins/Viewer/Model/TextRows.swift:284; TextRows.swift:272
- **Basis:** measured (cause inferred)
- **Detail:** Happened once, on the single-line file, with about 65 threads contending in the storm; not seen on other files or without the hammer. Inferred: lock-holder preemption. Reported as low/medium.
- **Proposed fix:** os_unfair_lock or atomics for the counters the main thread reads.
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### V061 [finding, low] afterLoad closures of an overtaken fetch run after a later, unrelated load.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/TextPagerView.swift:391-404
- **Basis:** read
- **Detail:** afterLoad closures of an overtaken fetch run after a later, unrelated load.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V062 [finding, low] topOffset falls back to the start of the file when the top row is not loaded, so a relayout during a fetch jumps to the top.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/TextPagerView.swift:487
- **Basis:** read
- **Detail:** topOffset falls back to the start of the file when the top row is not loaded yet, so a relayout during a fetch jumps to the top.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V063 [finding, low] Row typesetting builds a CTLine per row (up to 2 x unwrapWidth = 32,768 units), rebuilt for all visible rows after every fetch.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/TextPagerView.swift:759-764
- **Basis:** read
- **Detail:** Short main-thread stall: CTLine per row with up to 2 x unwrapWidth (32,768) units, rebuilt for all visible rows after every fetch.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V064 [finding, low] For RTL runs the selection rectangle uses to - from (negative), drawing a 2 px sliver.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/TextPagerView.swift:839-840
- **Basis:** read
- **Detail:** For RTL runs the selection rectangle uses `to - from`, which is negative, so it draws a 2 px sliver.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V065 [finding, low] Copy puts up to 64 MB text / 192 MB hex through pasteboard.setString on the main thread.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/ViewerPane+Actions.swift:450-471
- **Basis:** read
- **Detail:** Short main-thread stall: up to 64 MB of text or 192 MB of hex goes through pasteboard.setString on the main thread.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V066 [finding, low] Print puts 2 MB into an NSTextView plus sizeToFit on the main thread.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/ViewerPane+Actions.swift:650-654
- **Basis:** read
- **Detail:** Short main-thread stall: 2 MB into an NSTextView plus sizeToFit on the main thread.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V067 [finding, low] In HTML text mode the encoding menu changes codePage but the text is never re-decoded; read errors become an empty view silently.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/ViewerPane.swift:422; ViewerPane.swift:482-490
- **Basis:** read
- **Detail:** In HTML text mode the Encoding menu and A/S keys change codePage, but the stripped text is never re-decoded; the menu shows a new checkmark and the text does not change. `(try? read) ?? Data()` turns a read error into an empty view with no message.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V068 [finding, low] QLPreviewView is never stored or close()d, so its window never closes in the embedded quick view.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/ViewerPane.swift:597
- **Basis:** inferred
- **Detail:** QLPreviewView is never stored or close()d (ViewerPane.swift:597, dropRichViews). In the embedded quick view its window never closes. Plausible leak.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V069 [finding, low] Re-layout triggers restart identical pending builds, zoom is not debounced, two full builds compete, and sequential scans read a giant line twice.
**Outcome:** fixed — see `status/plugins-b-p2.md`


- **Where:** Sources/Plugins/Viewer/UI/ViewerPane.swift:645; ViewerPane.swift:663-668; Sources/Plugins/Viewer/UI/TextPagerView.swift:460-470; TextPagerView.swift:182
- **Basis:** read
- **Detail:** pagerResized, applySettings and changeFontSize compare layout with the shown document, not the pending one, so a second trigger cancels and restarts an identical pending build. Zoom steps are not debounced: each starts a full index build (cancelled by the next). The shown document keeps indexing on all cores until the new one is adopted, so two full builds compete. A sequential (remote) scan reads a giant line twice: the owning segment reads to its end, then every following segment re-reads its own 4 MB while skipping.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V070 [finding, low] Uncancellable directory listings in parallel walkers (FolderSummary, SpaceCalculator, AttributeJob) and CommentStore waiters with no timeout.
**Outcome:** fixed — see `status/fileops-p2.md`


- **Where:** Viewer/Model/FolderSummary.swift:25; FileProperties/SpaceCalculator.swift:95; FileProperties/AttributeChange.swift:298; FileTools/ChecksumFiles.swift:250; FileProperties/Descript.swift:217-223; FileProperties/Descript.swift:193
- **Basis:** read
- **Detail:** Low-medium. FolderSummary.measure, SpaceCalculator.measure and AttributeJob.process call list(_:showHidden:) without the cancellation: overload that ChecksumFiles.swift:250 uses. After cancel, or when the quick-view cursor moves on, in-flight lists run to completion while holding viewer.work threads and Parallel pool pieces. CommentStore.load reads without any flag; every column thread for that folder then sits in condition.wait() with no timeout.
- **Proposed fix:** Use the cancellable overloads.
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V071 [finding, low] One uncancelled global().async per distinct zoom size, up to 160 MB each during a pinch.
**Outcome:** duplicate of V020 — see `status/viewer.md`


- **Where:** Viewer/UI/ImageCanvasView.swift:127
- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V072 [finding, low] TextPagerView can be deallocated on an indexing thread (self? temporary strong reference in buildIndex progress callback).
**Outcome:** duplicate of V040 — see `status/viewer.md`


- **Where:** Viewer/UI/TextPagerView.swift:152; Viewer/UI/TextPagerView.swift:157-171; Viewer/UI/TextPagerView.swift:127-132
- **Basis:** read
- **Detail:** Medium-low. document.buildIndex(parallel:) { self?.indexProgressed() } takes a temporary strong reference on a concurrentPerform or global worker for the duration of indexProgressed. If main drops its reference (window close, quick view hidden) while the worker holds the +1, the worker's release is the last and NSView dealloc and deinit (including NSScroller subviews) run off-main.
- **Proposed fix:** Capture a small non-view coalescer object (the lock and flag) and take the view strongly only inside the main.async.
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V073 [finding, low] After stopWork the pager still shows the old document with cancelled flags; scrolling during the next load fetches nothing and blanks the view.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Viewer/UI/TextPagerView.swift:353-366; Viewer/UI/TextPagerView.swift:234
- **Basis:** read
- **Detail:** Contradicts 'what is shown stays' (:234).
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V074 [finding, low] afterLoad actions survive a dropped fetch and later run against a different document.
**Outcome:** duplicate of V061 — see `status/viewer.md`


- **Where:** Viewer/UI/TextPagerView.swift:384-403
- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V075 [finding, low] viewer.rows is serial: a slow reveal or caret lookup blocks row fetches behind it, and restoreCaret is cancellable only by the document flag.
**Outcome:** duplicate of V024 — see `status/viewer.md`


- **Where:** Viewer/UI/TextPagerView.swift:81
- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V076 [finding, low] copySelection and withSelectedText have no stale-result guard (the latter has no cancellation either); by design.
**Outcome:** not a defect — see `status/viewer.md`


- **Where:** Viewer/UI/ViewerPane+Actions.swift:464; Viewer/UI/ViewerPane+Actions.swift:528
- **Basis:** read
- **Detail:** By design; low.
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V077 [finding, low] Modal run loops (open/save/page-layout panels and kernel.ui form/inform/pick from completions) run on main.
**Outcome:** not a defect — see `status/viewer.md`


- **Where:** Viewer/UI/ViewerPane+Actions.swift:537,547,602
- **Basis:** read
- **Detail:** NSOpenPanel / NSSavePanel / NSPageLayout runModal (ViewerPane+Actions.swift:537,547,602) and kernel.ui.form / inform / pick from completions (sync finish, compare finish, rename finish). Each is raised once per operation; none can be raised repeatedly from a flood.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### V078 [finding, low] TemporaryCopies owner key outlives its pane, and removeAll races an in-flight copy.
**Outcome:** duplicate of V055 — see `status/viewer.md`


- **Where:** Viewer/UI/ViewerPane.swift:562; Viewer/UI/RichViews.swift:81; Viewer/UI/RichViews.swift:92; Viewer/UI/ViewerPane.swift:146; Viewer/UI/RichViews.swift:121-127
- **Basis:** read
- **Detail:** localURL on viewer.work registers the copy under ObjectIdentifier(pane), possibly after the pane's deinit released that owner. The copy is then never idle and never evicted until removeAll. A new pane at the same address would release it, which is harmless. Separately, removeAll races an in-flight copy: the folder is deleted, then copies[key] is registered pointing at a missing file.
- **Proposed fix:** A per-pane token object with a liveness check, and an epoch check before registering.
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V079 [finding, low] Fan-out: one viewer.work block per quick-view cursor rest (load, showFolder), unbounded if a provider ignores cancellation.
**Outcome:** fixed — see `status/plugins-b-p2.md`


- **Where:** Viewer/UI/ViewerPane.swift:85
- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V080 [finding, info] A late interrupt() after close() is possible and relies on the contract's 'any time'.
**Outcome:** not a defect — see `status/viewer.md`


- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V081 [finding, info] close() during active reads closes only idle readers; readers in use are checked back in and stay open until deinit. Example: Save As job reads with monitor.cancellation, not the pane's flag.
**Outcome:** fixed — see `status/viewer.md`


- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V082 [finding, info] CodeTable build on main (tens of ms, estimated).
**Outcome:** duplicate of V046 — see `status/viewer.md`


- **Where:** Plugins/Viewer/UI/ViewerPane.swift:468
- **Basis:** inferred
- **Detail:** Reviewer.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### V083 [finding, info] A pager stopped with stopReading() reports isIndexing == true forever (document cancelled, never completed).
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Sources/Plugins/Viewer/UI/TextPagerView.swift
- **Basis:** reproduced
- **Detail:** Looks like the design, but anything waiting for indexing to end must handle it; the first smoke run waited on this indefinitely.
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### V084 [finding, info] DiskBlockCache.lock and TemporaryCopies.lock are the only locks main shares with a holder that does I/O (local disk); TemporaryCopies.newFolder holds the lock across two createDirectory calls.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Viewer/Model/ByteSource.swift:231; Viewer/UI/RichViews.swift:29; Viewer/UI/RichViews.swift:132-142
- **Basis:** read
- **Detail:** Worst-case hold: one 256 KB temp-disk I/O for DiskBlockCache.lock; ms for TemporaryCopies.lock. Both are in the bug 1 paths.
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V085 [finding, info] A short block could be cached if a provider returns empty instead of throwing on interrupt; provider contract violation, speculative.
**Outcome:** duplicate of V043 — see `status/viewer.md`


- **Where:** Viewer/Model/ByteSource.swift:487-493
- **Basis:** inferred
- **Detail:** Speculative.
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V086 [finding, info] CharacterBoundaries.computing is held across provider I/O (source.read) for a whole-file backward read in pure two-byte text; waiters are uncancellable until the holder's read is interrupted.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Viewer/Model/CharacterBoundaries.swift:91-124; Viewer/Model/CharacterBoundaries.swift:105; Viewer/Model/CharacterBoundaries.swift:132; Viewer/Model/ViewerSearch.swift:274
- **Basis:** read
- **Detail:** Held 91-124 across source.read (105, 132), then lock. Reached only from ViewerSearch.decoded:274 on viewer.work and Parallel threads; never main.
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V087 [finding, info] TextRowIndex.segmentsReused is written under the lock and read unlocked; benign, test-only accessor.
**Outcome:** duplicate of V049 — see `status/viewer.md`


- **Where:** Viewer/Model/TextRows.swift:350; Viewer/Model/TextRows.swift:288; Viewer/Model/TextDocument.swift:145
- **Basis:** read
- **Detail:** Benign.
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V088 [finding, info] CodeTable.lock is held across table construction (double-byte table about 24k CFString conversions) and main takes it for binary/hex TextDocument.init and Actions:420.
**Outcome:** duplicate of V046 — see `status/viewer.md`


- **Where:** Viewer/Model/ViewerEncoding.swift:132; Viewer/Model/ViewerEncoding.swift:136-141; Viewer/Model/ViewerEncoding.swift:184; Viewer/UI/ViewerPane.swift:468; Viewer/UI/ViewerPane+Actions.swift:420
- **Basis:** inferred
- **Detail:** CPU only; one table build, estimated tens of ms, unmeasured.
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V089 [finding, info] isFetching is write-only.
**Outcome:** fixed — see `status/viewer.md`


- **Where:** Viewer/UI/TextPagerView.swift
- **Basis:** read
- **Detail:** isFetching is written but never read.
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V090 [finding, info] One global().async plus concurrentPerform per relayout; normally at most two live (shown and pending document).
**Outcome:** not a defect — see `status/viewer.md`


- **Where:** Viewer/UI/TextPagerView.swift:151
- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V091 [finding, info] cancel() on main runs reader.interrupt() handlers (allowed by the contract); sites listed.
**Outcome:** not a defect — see `status/viewer.md`


- **Where:** Viewer/UI/ViewerPane.swift:143-144; Viewer/UI/ViewerPane.swift:312-314; Viewer/UI/ViewerPane.swift:319; Viewer/UI/ViewerPane.swift:451; Viewer/UI/ViewerPane.swift:697; Viewer/UI/TextPagerView.swift:128-131; Viewer/UI/TextPagerView.swift:145; Viewer/UI/TextPagerView.swift:182; Viewer/UI/TextPagerView.swift:237-240; Viewer/UI/TextPagerView.swift:378; Viewer/UI/ViewerPane+Actions.swift:200; Viewer/UI/ViewerWindowController.swift:42
- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open


## Checked and found sound

### V092 [sound, low] Scaled bitmap guard generation == token is sound but fragile: the key uses ObjectIdentifier(frame), but every frame swap calls invalidate.

- **Where:** Viewer/UI/ImageCanvasView.swift:129; Viewer/UI/ImageCanvasView.swift:221; Viewer/UI/ImageCanvasView.swift:244
- **Basis:** read
- **Detail:** Sound but fragile.
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V093 [sound, info] Viewer text path is off main and bounded.

- **Basis:** read
- **Detail:** Every read, index build, row fetch, reveal, search, copy read, HTML strip and decode runs on workQueue, fetchQueue or a global queue, with generation checks. Rows are always cut at the column limit, so a 10 GB single line becomes bounded rows. The TextRowIndex, CachedByteSource and DiskBlockCache locks are never held across provider I/O (only a local pread/pwrite of at most 256 KB). Scrolling is O(1) plus an asynchronous fetch.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### V094 [sound, info] CTLine drawing cost is small.

- **Basis:** read
- **Detail:** Measured 60 CTLines of 16,384 characters at about 5 ms, so drawing a page is cheap even at the widest setting.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### V095 [sound, info] No lock-order cycle and no deadlock in scope; none of the locks is held across Parallel.map or concurrentPerform.

- **Basis:** read
- **Detail:** Most locks suspected of freezing the UI are never held across provider I/O. Lock table covers ProviderByteSource.lock, DiskBlockCache.budget/lock, CachedByteSource.lock, CharacterBoundaries.lock/computing, TextDocument.boundariesLock/errorLock, TextRowIndex.lock, Locked.lock, CodeTable.lock, LatestNumber.lock/progressLock, TemporaryCopies.lock, ToolRun.lock/reportLock, AttributeJob.lock, ProgressMeter.lock, CommentStore.condition, LocalInfo.lock.
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V096 [sound, info] No Parallel.map and no provider read, list or item call on main in scope.

- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V097 [sound, info] Static mutable state (DiskBlockCache.held, CodeTable.tables, LocalInfo caches) is all locked; no raced lazy vars. Deinits: ViewerPane main only (no strong self capture in viewer.work closures), ToolOutput.deinit abandon is provider I/O but outputs are finished explicitly, hashers memory only, MediaView/ImageCanvasView main.

- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V098 [sound, info] windowWillClose and ViewerPlugin.stop wait for no background work; stop iterates a copy of windows; LinkedCancellation tokens kept alive by fetch closure and pager and unhooked on release.

- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V099 [sound, info] Viewer text path is O(visible); rows capped at 16,384 columns so a 10 GB line is bounded.

- **Basis:** read
- **Detail:** 
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### V100 [sound, info] TextRowIndex and related shared state are sufficiently protected by locks or main-thread confinement.

- **Basis:** read
- **Detail:** Table: TextRowIndex via NSLock (nesting new -> old only); scan state thread-local per segment; TextDocument.boundaries/fetchFailure own locks; CharacterBoundaries.known lock with `computing` serialising (order computing -> lock; waiters cannot be cancelled); CodeTable.tables static lock (apart from stall in finding 23); ProviderByteSource.idle NSLock, one reader per thread, cancelled reader closed never pooled, cancel/check-in race walked and invariant holds; DiskBlockCache instance state lock incl. pread/pwrite/close; DiskBlockCache.held budget lock (apart from leak in finding 19); CachedByteSource.blocks/order lock (double fetch harmless); TemporaryCopies lock with file I/O outside (apart from late-insert race, finding 25); LatestNumber/progressScheduled locks; ViewerPane, TextPagerView, ScaledFrameCache, ImageCanvasView, ListerSettings main-thread only, results gated by loadGeneration, presentGeneration, generation, revealGeneration and document identity; CancellationFlag handlers run outside the lock, reader interrupt() implementations short.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V101 [sound, info] Index equivalence fuzz: 6,000 cases found 0 mismatches against a single-pass decode reference.

- **Basis:** reproduced
- **Detail:** Raw scan (parallel and sequential, segments 16-1,024 bytes, chunks 16-4,096) compared with single-pass decode, including segment reuse into a second layout. Coverage: UTF-8, UTF-16 LE/BE, 1252, 932/936/949/950; CR, LF, CRLF; tabs; NULs; junk bytes; columns 1-80; random access; row(containing:). Covers CRLF and multi-byte characters across borders, exact-width lines, bulk empty-line path, partial segments and reuse conditions.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V102 [sound, info] Pathological 256 MB inputs are all linear and under 1 s.

- **Basis:** measured
- **Detail:** `\n` only: 0.03 s, checkpoints 4 KB apart. CR only, UTF-16 newlines, all tabs, all spaces, UTF-16 full of U+0A0A: all linear and under 1 s.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V103 [sound, info] Unsafe buffer accesses in TextRows, ViewerSearch and HTMLText are guarded.

- **Basis:** read
- **Detail:** Every unchecked buffer access traced is guarded. 16-bit handling is byte-wise or loadUnaligned. No pointer escapes its closure. Int32 offsets only relative to pieces of a few MB or less; file offsets Int64 throughout with the flag packed in bit 0.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V104 [sound, info] Decoders map lone surrogates, overlong forms and values above U+10FFFF to U+FFFD; no zero-width unbounded row; no code page maps a high byte to TAB/LF/CR.

- **Basis:** read
- **Detail:** 
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V105 [sound, info] CharacterBoundaries invariant holds for the decoder as implemented.

- **Basis:** read
- **Detail:** A non-lead byte is either a single-byte character or a trail byte, and both end a character. Half-width katakana are non-lead in the table.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V106 [sound, info] Search: raw and decoded paths agree apart from finding 13; catastrophic regexes stop within about 50 ms of cancel.

- **Basis:** reproduced
- **Detail:** Includes i-dot, Kelvin, long s, ligatures, whole-word neighbours, chunk borders and backward search. Cancel of catastrophic regexes within about 50 ms (m8).
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V107 [sound, info] Spill file is safe: per-user temp dir, O_EXCL, mode 0600, unlinked immediately, never reopened by path; stops caching at the cap with no refetch loop.

- **Basis:** read
- **Detail:** 
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V108 [sound, info] Launch sweep deletes only when kill(pid, 0) gives ESRCH, so it cannot remove a live instance's folder; PID reuse only delays cleanup.

- **Basis:** read
- **Detail:** 
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V109 [sound, info] WKWebView setup is tight: JavaScript off, non-persistent store, baseURL nil; all subresource vectors blocked; only the meta refresh gets through.

- **Basis:** reproduced
- **Detail:** 
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V110 [sound, info] Other checks sound: context-menu links limited to http/https/www; HTMLText linear on unterminated tags, comments, entities and skipped elements; no retain cycles; scroller and percent arithmetic safe, NaN harmless.

- **Basis:** read
- **Detail:** 
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V111 [sound, info] detect (detection, whole vs piecewise decode): 0 crashes, hangs, mismatches.

- **Basis:** measured
- **Detail:** 106,109 ASan / 640,318 release execs.
- **Source:** reports/21-fuzz-target-group-6-viewer.md
- **Status:** open

### V112 [sound, info] boundaries (CharacterBoundaries vs decode from start): 0 crashes, hangs, mismatches.

- **Basis:** measured
- **Detail:** 435,117 ASan / 1,032,918 release execs.
- **Source:** reports/21-fuzz-target-group-6-viewer.md
- **Status:** open

### V113 [sound, info] rows (TextDocument / TextRowIndex, text, binary, hex layouts): only the thin overflow crash.

- **Basis:** measured
- **Detail:** 37,747 ASan / 300,541 release execs.
- **Source:** reports/21-fuzz-target-group-6-viewer.md
- **Status:** open

### V114 [sound, info] html (HTMLText.plainText vs the tests' reference): 0 crashes, hangs, mismatches.

- **Basis:** measured
- **Detail:** 118,416 ASan / 1,044,758 release execs.
- **Source:** reports/21-fuzz-target-group-6-viewer.md
- **Status:** open

### V115 [sound, info] HTML time is linear.

- **Basis:** measured
- **Detail:** Slowest shapes per 1024 UTF-16 units in release: <a href="x"> repeated 20-27 us; & repeated 19 us; <li>x 6-12 us; &#x41 7 us; every other shape under 3 us. Flat from 2 KB to 64 KB (x1 to x32) across 17 shapes including unterminated <script>, <style, <!--, <a href=" and <svg><a>. The 200 ms/KB the ASan stats once recorded did not reproduce (0.002 ms in release).
- **Source:** reports/21-fuzz-target-group-6-viewer.md
- **Status:** open

### V116 [sound, info] No hangs and no over-memory cases in any viewer target.

- **Basis:** measured
- **Detail:** 
- **Source:** reports/21-fuzz-target-group-6-viewer.md
- **Status:** open

### V117 [sound, info] Viewer indexing and first rows fast on all test files: first rows 11-24 ms; index 0.61 s (4 GiB dense), 0.85 s (sparse), 3.37 s (2 GiB single line, 7.5 CPU-s, not parallel), 0.15 s (1 GiB newlines).

- **Basis:** measured
- **Detail:** Rows/lines 53.4M/53.4M, 37.9M/13.3M, 16.6M/1, 1.07G/1.07G. Relayout wider/wrap 40/no wrap: 1.92/1.72/0.64 s; 1.36/1.12/0.85 s; 3.83/4.15/2.99 s; <=1 ms (256/256 segments reused). Whole-file search 1.04, 0.84, 0.38, 0.13 s. Stalls >8/>100/>1s: 44/0/0, 23/0/0, 30/1/0, 3/0/0; max 58, 45, 202, 29 ms. Threads 7->70->9, 7->67->9, 7->65->8, 9->64->8. Peak RSS 96.9, 79.7, 43.9, 42.9 GB.
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### V118 [sound, info] Viewer row fetches after indexing: mean 0.15-0.26 ms, max 5.6-27 ms (single line mean 3.2 ms, max 8 ms); round-trip checks passed on all four files.

- **Basis:** measured
- **Detail:** 
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### V119 [sound, info] Viewer storm: 40 relayouts during indexing with readers, searchers and Esc ended with the last layout indexed and same rows/lines as the first; search returned at most 3.7 ms after cancel.

- **Basis:** measured
- **Detail:** 6 threads called rows/row(containing:)/row(ofLine:) with random cancels, 2 ran ViewerSearch.find.
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### V120 [sound, info] Viewer truncate/remove during indexing: 12 rounds on 1 GiB all ended within 1.5 s with no crash or hang.

- **Basis:** measured
- **Detail:** Stalls 16/12/0 (all 12 harness), max 309 ms (harness), threads 9->42->11, peak RSS 26.5 GB. Removal reported correctly through readError.
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### V121 [sound, info] Viewer group: HTML rendering is linear

- **Basis:** reproduced
- **Detail:** 722,561 asan and 3,592,721 rel executions; 1 trap, 2 search bugs.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### V122 [sound, info] CommentStore condition wait uses a correct predicate loop, broadcast under lock; no in-scope caller is main. Image timer is non-repeating, weak, invalidated in deinit/show/replaceFrames; resizeWork and CursorFollower weak with generation.

- **Where:** FileProperties/Descript.swift:187-194; FileProperties/Descript.swift:203; Viewer/UI/ImageCanvasView.swift:323; Viewer/UI/ViewerPane.swift:640
- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V123 [sound, info] Temp files: TMPDIR not honoured (tested), per-user 0700 folder; viewer block cache O_EXCL 0600 and unlinked at once; pid sweeps only remove folders of dead pids.

- **Where:** Plugins/Viewer/Model/ByteSource.swift:292-300
- **Basis:** reproduced
- **Detail:** 
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### V124 [sound, info] Images downsampled to 8192 px with a 512 MiB animation budget.

- **Where:** Plugins/Viewer/UI/ImageCanvasView.swift:22-75
- **Basis:** read
- **Detail:** 
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### V125 [sound, info] TextRowIndex.segmentsReused is the one shared-state item with insufficient protection (written under lock, read without).

- **Where:** Sources/Plugins/Viewer/Model/TextRows.swift:288; TextRows.swift:350
- **Basis:** read
- **Detail:** Listed as 'No' in the shared-state table; see finding 22.
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V126 [sound, info] Cancellation: pooled reader cannot be handed to two threads (checkOut pops under lock); interrupt cannot hit a pooled reader (token released before isCancelled check; CancellationFlag.cancel sets flag and snapshots handlers in one critical section, also through LinkedCancellation).

- **Where:** Viewer/Model/ByteSource.swift:54; Viewer/Model/ByteSource.swift:158
- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V127 [sound, info] Shared state sound: TextRows state via synchronized; Hashes disjoint output slots with justified @unchecked Sendable; AttributeJob outcome under lock; ChecksumFiles per-file hashers; SpaceCalculator struct by value; FolderSummary; ViewerSearch.

- **Where:** Viewer/Model/TextRows.swift:344; FileTools/Hashes.swift:447; FileTools/Hashes.swift:459; FileProperties/AttributeChange.swift:289; FileTools/ChecksumFiles.swift:210-217; FileProperties/SpaceCalculator.swift:75-107; Viewer/Model/FolderSummary.swift:35; Viewer/Model/ViewerSearch.swift:163
- **Basis:** read
- **Detail:** viewer.work blocks share only thread-safe objects. ToolRun.create and overwritesAll never reached from the parallel body.
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V128 [sound, info] Media title uses weak self only; acceptable since one view per presentation.

- **Where:** Viewer/UI/RichViews.swift:217
- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V129 [sound, info] Stale-result guard: index progress is coalesced and reads live state.

- **Where:** Viewer/UI/TextPagerView.swift:163
- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V130 [sound, info] Stale-result guard: restoreCaret checks document identity and caretToRestore == offset.

- **Where:** Viewer/UI/TextPagerView.swift:218
- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V131 [sound, info] Stale-result guard: rows fetch hop in TextPagerView.

- **Where:** Viewer/UI/TextPagerView.swift:362; Viewer/UI/TextPagerView.swift:356
- **Basis:** read
- **Detail:** generation == wanted and document === document; pre-check via LatestNumber. The closure holds the document, so no ABA.
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V132 [sound, info] Stale-result guards: reveal and go-to-line use revealGeneration and document identity.

- **Where:** Viewer/UI/TextPagerView.swift:528; Viewer/UI/TextPagerView.swift:585
- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V133 [sound, info] Stale-result guards: search result/progress (loadGeneration, source identity, !cancel; activity.cancel === cancel), print (loadGeneration, cancel), encoding detection (part of Loaded value).

- **Where:** Viewer/UI/ViewerPane+Actions.swift:434; Viewer/UI/ViewerPane+Actions.swift:428; Viewer/UI/ViewerPane+Actions.swift:644
- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V134 [sound, info] Stale-result guards: load and folder summary use loadGeneration and !cancellation.isCancelled (load closes the stale source on main, bug 1).

- **Where:** Viewer/UI/ViewerPane.swift:287; Viewer/UI/ViewerPane.swift:345
- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V135 [sound, info] Stale-result guard: stripHTML checks loadGeneration, presentGeneration and mode == .html.

- **Where:** Viewer/UI/ViewerPane.swift:492
- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V136 [sound, info] Stale-result guards: image, PDF, rich and first frame use isCurrent (both generations, both flags, !isTextual).

- **Where:** Viewer/UI/ViewerPane.swift:545; Viewer/UI/ViewerPane.swift:564
- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open


## Not covered / left behind

### V137 [gap, info] Not covered: ViewerSearch, HTMLText, hex/binary row builders, MediaView, and per-key handleKey / menuEntries cost.

- **Basis:** read
- **Detail:** Not examined.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### V138 [gap, info] Hashes.swift, SplitCombine.swift, Transcoding.swift, first 330 lines of ViewerPane+Actions.swift, ViewerEncoding.swift, HTMLText.swift, ViewerDetection.swift, ViewerSettings.swift and PropertyDetails.swift were read only for concurrency-relevant parts and grepped; nothing was built or run.

- **Basis:** read
- **Detail:** 
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### V139 [gap, info] Not covered: HTMLText stripping and TextRows/ViewerSearch pointer loops (only sampled bounds checks).

- **Basis:** 
- **Detail:** 
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### V140 [gap, info] No run of the app, the test suite, or a build of the project; UI timing claims are from reading.

- **Basis:** read
- **Detail:** 
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V141 [gap, info] Behaviour of QLPreviewView, PDFKit, AVKit and ImageIO on hostile files not tested (remote loads in Quick Look SVG/Office/HTML previews, PDF page-count or rendering freezes, PNG bombs).

- **Basis:** read
- **Detail:** 
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V142 [gap, info] Whether network and archive providers accept %2F or foreign-host URLs end to end (finding 7) not checked.

- **Basis:** read
- **Detail:** 
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V143 [gap, info] Cost of seek in archive member readers not measured; archives report isLocal == true so they get the parallel index and random access.

- **Basis:** read
- **Detail:** 
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V144 [gap, info] ParallelPool and the kernel and providers beyond the reader close/interrupt paths cited were not reviewed.

- **Basis:** read
- **Detail:** 
- **Source:** reports/18-review-viewer-second-round.md
- **Status:** open

### V145 [gap, info] Tiny sizes in the driver: segment and chunk sizes down to 1 byte (which exposed finding 1); 150-250 ms executions for 3.7 KB inputs in rows and search came from those sizes, not the app's 4 MiB / 1 MiB.

- **Basis:** read
- **Detail:** 
- **Source:** reports/21-fuzz-target-group-6-viewer.md
- **Status:** open

### V146 [gap, info] Search coverage after the findings is limited: only the finding-2 case is tolerated in the driver; finding-3 mismatches still stop a worker each time, so exploration past them was limited.

- **Basis:** read
- **Detail:** 
- **Source:** reports/21-fuzz-target-group-6-viewer.md
- **Status:** open

### V147 [gap, info] Not fuzzed: ProviderByteSource, CachedByteSource and DiskBlockCache (only DataByteSource used).

- **Basis:** read
- **Detail:** 
- **Source:** reports/21-fuzz-target-group-6-viewer.md
- **Status:** open

### V148 [gap, info] Not fuzzed: cancellation mid-build.

- **Basis:** read
- **Detail:** 
- **Source:** reports/21-fuzz-target-group-6-viewer.md
- **Status:** open

### V149 [gap, info] Not fuzzed: user-typed regular expressions (only a fixed list of harmless ones).

- **Basis:** read
- **Detail:** 
- **Source:** reports/21-fuzz-target-group-6-viewer.md
- **Status:** open

### V150 [gap, info] Not fuzzed: the UI layer and the RTF/PDF/image paths.

- **Basis:** read
- **Detail:** 
- **Source:** reports/21-fuzz-target-group-6-viewer.md
- **Status:** open
