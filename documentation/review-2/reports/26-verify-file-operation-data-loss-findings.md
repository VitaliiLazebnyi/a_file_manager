# Verify file operation data-loss findings

All 16 claims checked: 14 confirmed (four of them narrower than worded), 1 not reproducible as worded (16, though the
underlying defect is real), and 15 is a real crash but only with nesting no local disk can hold. I reproduced everything
except the 4,096-entry wipe in claim 10, which I only read. I also found one new defect (N1).

The throwaway tests are in
`/private/tmp/claude-501/-Users-cm0k-Claude-Projects-TotalCommander/91e36f29-0d53-4421-8985-1ec839e7f5c4/scratchpad/verify2/fileops/Tests/PluginTests/Verify2Tests.swift`,
with a small release probe in `Probe/main.swift` beside it. The project directory was not touched; the disk images are
unmounted and `.build` is removed.

Paths below are relative to `Sources/`; "FileJob" is `Plugins/FileOperations/FileJob.swift` and "LocalFileSystem" is
`Plugins/LocalFileSystem/LocalFileSystem.swift` (the claim's `AFMKernel/FileSystem/` path for it is wrong).

## Verdicts

**1. Move inside a branch view destroys the file — CONFIRMED, reproduced.**

- **Evidence:** `VirtualFileSystem.virtualItem` (`Plugins/VirtualFolders/VirtualFileSystem.swift:271-276`) returns the
  real file for `vfolder://…/d/a.txt`, so FileJob:593-594 plans `.write(replacing: true)`. In `put` (709-734) the two
  providers differ, so the file is stream-copied to a temp, renamed over itself, and then removed at 539-541.
- **Why nothing stops it:** `targetsSourceFolder` (362-368) is false for a move, and the paste filter
  (`Plugins/Clipboard/ClipboardPlugin.swift:149`) compares a `file:` folder with a `vfolder:` one.
- **Steps:** open a branch view, Cmd+X then Cmd+V on a file in the branch root. Or F6 / Shift+F6 and type the same name
  in another letter case.
- **Observed:** job reports completed=1, no error, no question; `a.txt` and `c.txt` are gone from disk.
- **Scope:** only files directly in the branch root. A file from a subfolder is moved up into the root, and a copy is
  refused with "cannot copy a file to itself".

**2. FIFO hangs a streamed transfer — CONFIRMED, reproduced.**

- **Evidence:** `LocalFileSystem.read` (334-336) opens with a blocking `FileHandle(forReadingFrom:)`. There is no
  cancellable variant, so the default (`AFMKernel/FileSystem/FileSystemProvider.swift:346-349`) only checks the flag
  before opening. `isSpecial` is not consulted anywhere in FileJob (only carried through at 1118).
- **Steps:** copy a folder containing a named pipe to an archive, a server or any other file system.
- **Observed:** not finished after 3 s, not finished 3 s after `cancel()`, ended only when I opened the pipe's write
  end.
- **Quit:** `applicationShouldTerminate` (`AFMShell/App/Shell.swift:103-107`) returns `.terminateLater` and waits for
  the job with no timeout. I read that; I did not launch the app.
- **Scope:** a plain local-to-local copy does not hang (it uses `copy`, not a stream; the pipe was simply not copied).
  Local-to-local with "follow links" on a link to a pipe does hang.

**3. Several sources onto one target name overwrite each other — CONFIRMED, reproduced, narrower than worded.**

- **Evidence:** FileJob:498-503 only waits for the first file to land; `plan` (586-622) then treats it as an ordinary
  existing target.
- **Observed (Move, Overwrite all):** `s/a/x.txt` and `s/b/x.txt` into `t/` gave completed=2, one `x.txt` containing
  "from-b", both sources gone, no question. `Report.txt` and `report.txt` from a case-sensitive source onto APFS left
  one file with "lower". Same with and without the parallel pool.
- **Scope:** in the default Ask mode the Overwrite question does appear for the second file. Real loss needs Move plus
  Overwrite all (preset or answered earlier in the job); with Copy the sources survive.

**4. Resume onto a symlink destination rewrites the link's target — CONFIRMED, reproduced.**

- **Evidence:** a link has size 0, so the guard at 617 passes and the dialog offers Resume
  (`Plugins/FileOperations/JobBridge.swift:56`). `resumeInPlace` (876-886) compares zero bytes, then
  `LocalFileSystem.append` (368-386) opens with `O_WRONLY`, follows the link and truncates.
- **Steps:** copy `f.txt` to a folder where `f.txt` is a link, choose More › Resume.
- **Observed:** `elsewhere/victim.txt` (53 bytes) now contains "source-bytes"; the link is still a link.

**5. 2-second tolerance on every volume — CONFIRMED, reproduced.**

- **Evidence:** FileJob:660-664, unconditional.
- **Observed:** on APFS with "Overwrite all older", a source 1.5 s newer was skipped and one 2.5 s newer was copied.
  Also affects "older or same" and "rename older, skip newer".

**6. Delete and Move descend through mount points — CONFIRMED, reproduced with real mounts.**

- **Evidence:** `deleteTree`/`deleteChildren` (1222-1288) and `transferFolder` (1021-1029) have no device check.
  `BranchWalker` and `DirectoryTree` do have one.
- **Delete:** a permanent delete (not Trash) of a folder containing a mounted disk image erased everything on that
  volume. The only error was "Resource busy" for the mount point itself.
- **Move:** merging into an existing folder (so it goes item by item) emptied the mounted volume into the destination.
  Content survives, but the disk is emptied.

**7. Link-cycle detection is textual — CONFIRMED, reproduced.**

- **Evidence:** `resolvingLink` (1108-1113) uses `URL.isInside`/`isSameLocation`, which are string prefix tests
  (`AFMKernel/FileSystem/FileItem.swift:103-111`).
- **Steps:** copy with "follow links" a folder containing `loop -> .`, reached through a symlinked parent path.
- **Observed:** direct path gave 1 copy; through the alias gave 31 nested copies, 32 levels deep, stopped only by the
  kernel's link limit.
- **Not tested:** with k such links per folder growth would be about k^31; the counting pass `measure` (1558-1565) has
  the same test.

**8. "Keep partial files" breaks Retry — CONFIRMED, reproduced.**

- **Evidence:** FileJob:727-729 renames the partial to the real name. Retry re-runs the same `.write(replacing: false)`
  plan, and 724 then fails with "already exists".
- **Observed:** with the option on, error 1 was the injected failure and error 2 was "…/big.bin already exists"; a
  4-byte partial stayed and the job did not complete. With the option off, Retry succeeded. No data loss.

**9. "755" over 4755 keeps setuid — CONFIRMED, reproduced, and deliberate.**

- **Evidence:** `Plugins/FileProperties/AttributeChange.swift:31` and `:87`; the comment at 19-20 documents it.
- **Observed:** "755" gives 4755, "rwxr-xr-x" gives 4755, "0755" gives 755. This differs from `chmod 755`, and the
  dialog hint (`FilePropertiesPlugin.swift:460`) does not mention it.

**10. `lockedCopies` allows silent unlock-and-delete — CONFIRMED in a narrower form, partly reproduced.**

- **Evidence:** LocalFileSystem:415-427 and 472-498.
- **Not affected:** the user's own locked original is refused, and a locked file copied by a job is refused afterwards,
  because the entry is dropped on the temp-to-final rename (461).
- **Affected:** a locked folder copied by a job stays in the table (via `copyMetadata`, 617). Deleting that copy later
  in the same session removed it with no "locked" question, while a control folder did get the question. A direct
  `copy()` to a final name behaves the same even after the user unlocks and re-locks it by hand; no in-app caller does
  that today.
- **Wipe at 4,096 (478):** read only, not reproduced. The consequence would be a spurious "Operation not permitted" on a
  pending locked temp, not a deletion.

**11. `setAttributes` on a symlink changes its target — CONFIRMED, reproduced.**

- **Evidence:** LocalFileSystem:572-584.
- **Observed:** target went 644 to 600 and took the new date; the link itself was unchanged.
- **Reach:** Change Attributes guards against this (`AttributeChange.swift:333`). Unguarded callers are FileJob:745 and
  1367 (see N1) and `Plugins/DirectorySync/SyncPlan.swift:192, 389, 392`, which I read but did not run.

**12. `write()` creates 0644 until close — CONFIRMED, reproduced.**

- **Evidence:** LocalFileSystem:359, permissions applied only at close (405-411).
- **Observed:** mode 644 while open, 600 after close.
- **Scope:** streamed transfers only (from archives or servers, followed links, Append, non-in-place Resume). Local
  copies use `copyfile` and are not affected. It only matters in folders other users can enter.

**13. `append`/`read` block on FIFOs — CONFIRMED, reproduced.**

- **Evidence:** LocalFileSystem:370 and 335; the non-regular-file check at 376 comes after the blocking open.
- **Observed:** both were still blocked after 2 s. At job level, Resume onto a destination pipe hung in
  `startsWithPartial` (FileJob:914) and ignored Cancel.

**14. `Format.kilobytes` traps near Int64.max — CONFIRMED, reproduced.**

- **Evidence:** `AFMContracts/Format.swift:29`.
- **Observed:** `Int64.max` crashes with signal 5 in debug and release; `Int64.max - 512` is fine.
- **Reach:** unproven. The callers (`AFMShell/Panel/PanelViewController.swift:512`,
  `Plugins/FileProperties/SpaceCalculator.swift:116/121`, `Plugins/SystemTools/DirectoryList.swift:117`) pass saturating
  sums, so the value is reachable in principle, for example from a server listing with absurd sizes. I did not check
  whether the remote parsers clamp sizes.

**15. `totalSizeByListing` recursion is unbounded — CONFIRMED mechanism; real trigger PLAUSIBLE-unproven.**

- **Evidence:** `AFMKernel/FileSystem/FileSystemProvider.swift:391-396`.
- **Observed:** with a fake provider on a 512 KB thread stack, a release build survives 2,000 levels and crashes at
  4,000; a debug build crashes between 300 and 400.
- **Reach:** local disks cannot nest that deep (path limit, and `LocalFileSystem` has its own `totalSize`). It needs a
  crafted archive or hostile server; I did not build one.
- **Related:** FileJob's `measure`, `deleteTree` and `transferFolder` recurse per level as well; I did not test them.

**16. Network `move(replacing: true)` loses both files — REFUTED as worded; the underlying defect is CONFIRMED,
reproduced over FTP.**

- **Evidence:** `Plugins/Network/RemoteFileSystem.swift:533-543` deletes the destination after any refused rename,
  whatever the reason. The plain-rename SFTP path feeds the same branch (`SFTPSession.swift:270-275`); I read that and
  did not run it.
- **Source survives:** moving `ftp:/ro/a.txt` (folder not writable) to `ftp:/w/` with Overwrite sent RNFR, RNTO 550,
  DELE `/w/a.txt`, RNFR, RNTO 550. The target was gone, the source was intact, the move failed.
- **Missing source:** `move(missing.txt -> keep.txt, replacing: true)` deleted `keep.txt` even though the source never
  existed.
- **By reading only:** for an upload with Overwrite, `discard` (FileJob:731) then removes the temp, leaving nothing on
  the server though the local source remains. For Append (FileJob:862-866) the existing remote file would be lost
  outright.

## New defect

**N1. Deleting a symlink the system refuses with EPERM chmods the link's target — reproduced.**

- **Evidence:** `removing` (FileJob:1360-1370) answers the "locked" question by calling
  `setAttributes(item.permissions | 0o200)` on the URL, which for a link lands on its target (claim 11).
- **Steps:** delete a link inside a locked folder (a sticky folder with a foreign-owned link should behave the same) and
  answer the "locked" question with yes.
- **Observed:** the delete still failed, and the link's target, `private/key.pem`, went from 600 to 755.
- **Impact:** a permissions exposure, not data loss. `discard` (745) has the same pattern for a locked temp.
