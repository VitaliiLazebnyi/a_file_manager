# Cross-requests from the second pass on the kernel and the local file system (`kernel-p2`)

Nothing here blocks anything: every old call still works as it did. These are the places where another area has to
call something new for a finding to be closed all the way to the user. Signatures and one line each are at the top
of `status/kernel-p2.md` (section 0).

## File operations (`FileJob`, Unpack callers)

1. **`copy(_:to:cancellation:progress:)`** (L032, F021). `LocalFileSystem` ends a copy that waits when the flag is
   set (a signal to the blocked read or write, the flag looked at between every step the system reports, and on a
   share the copy is left behind after 2 s). Wanted: pass the job's flag wherever `copy(_:to:progress:)` is called.
   One thing to know: on a volume that is not a disk of this Mac, `progress` is called on another thread while the
   caller waits in the call (one call at a time, never after the call has returned).
2. **`remove(_:below:cancellation:)`** (F043, your request 6 / fileops 11). The local file system walks from `root`
   to the item through descriptors opened without following links and removes with `unlinkat`. Wanted: when a tree
   is deleted (and for the source removal of a move), call it with the top folder of the tree as `root` for
   everything below that folder; the top folder itself goes with the plain `remove(_:cancellation:)`. It throws,
   having removed nothing, when a folder on the way has become a link (`ELOOP` / `ENOTDIR` in the POSIX domain,
   with a message that says so). The default of the protocol is the plain call, so other file systems are unchanged.
3. **`createDirectory(at:exclusive:cancellation:)`** (L029, L043). Local: one `mkdir`, `FileSystemError.alreadyExists`
   for anything of that name, a link included. Wanted where a folder is about to be filled and must be the
   caller's own: the tree copy of `FileJob`, and Unpack (see archives below).
4. The other variants with a flag (`remove`, `move`, `createDirectory`, `setAttributes`, `copyMetadata`,
   `setQuarantine`) are implemented by `LocalFileSystem` now: on a disk of this Mac the flag ends a call that waits
   (signal) and keeps the next step from being begun; on a share the call is left behind 2 s after the flag was
   set. **What a caller must know:** a call that was left behind is not known to have failed; the system call it
   was in may still take effect when the server answers. After `userCancelled`, take nothing for done and nothing
   for undone. A volume with 4 calls left behind refuses further flagged changes at once with `ETIMEDOUT` until
   one returns.
5. **`commit(_:cancellation:progress:)`** exists (your request 4) with a default that asks `progress(0, 0)` once
   and then commits. `FileJob` can call it now; it holds a paused job inside `progress` as soon as a file system
   implements it (archives, network: item 7 below).
6. `MemoryFileSystem` (TestSupport) for your tests: `stallsChanges` holds every changing call that came with a
   flag until the flag is set or `releaseStalls()`; `stalledChanges` says how many wait (wait for it instead of
   sleeping); `flaggedChanges` lists them (`"remove /a/b"`, `"remove below /root /root/a"`, `"copy /dest"`), to
   check that the flag is passed.

## Archives, network

7. **`root(of:)`** is a requirement of `FileSystemProvider` now (K039), with the old climbing as its default.
   `ArchiveFileSystem` (and `RemoteFileSystem`, `VirtualFileSystem`) should answer from the URL at once: the
   2,000-level archive path of K039 costs its 0.23 s in exactly this climb.
8. **`commit(_:cancellation:progress:)`**: implement it where a commit takes long (the archive writer between
   members, an upload between blocks), reporting bytes done and total and stopping when `progress` returns false.
9. Unpack: `createDirectory(at:exclusive:true)` for every folder it creates itself, so that a link planted by an
   earlier archive is "already exists" and not written through (L043).

## Shell

10. **Sort arriving lists by `model.wantedSort`**, not `model.sort`, in `PanelLoading` (the order the reader sorts
    pieces by, and the `presorted:` / `sortedBy:` it passes). With that, a sort the user asked for while a
    directory is still arriving or keeps changing (`PanelModel.requestSort`, called by ViewOptions) is carried by
    the very next piece without any sorting on the main thread. Until then the model sorts such a piece itself
    where it is applied (in the background with `prepare`, on the main thread with the plain calls).
11. X005 and X006 (`PanelPartsTests`, `RememberedListingTests`) are the shell's tests. `MemoryFileSystem` now has
    what makes them independent of time: `stalledPaths` (stall only the listings of some folders),
    `stalledListings(of:)` (wait until the listing really waits) and `releaseStalls()`. In X006 the 3 s
    `listStartDelay` and the 2.5 s poll for `isOpening` can become: stall `/nas`, wait for
    `stalledListings(of: "/nas") == 1`, re-read, release.
12. Quit, the default button, `BlockingCalls` for the reader thread: unchanged from `cross-requests/kernel.md`
    items 1, 4 and 6; section 0.1 of the status file repeats the signatures.

## ViewOptions, Selection, VirtualFolders (plugins-a)

13. **`PanelModel.requestSort(_:)`** (your request 1) is there, with `requestedSort` and `wantedSort`. Call it
    before `prepare(basis, sort:)`; a `.stale` answer then means either that a reading has brought the order
    already (`model.sort == order`: done, do not sort again) or that the user chose another order meanwhile. The
    fall-back to `setSort(_:)` on the main thread after three stale answers is no longer needed.
    `PanelModel.prepare(_:sort:)` for the order the list is already in now changes nothing in the list.
14. **`PanelModel.isInArrivalOrder`** (K047): reload for Unsorted only when it is false. (Today the plugin reloads
    whenever the key before was another one, which is the same thing in nearly every case.)
15. **`PanelModel.rows(of: basis, indices:)`** (your request 2): a `RowSet` from indexes of `basis.items`, on any
    thread, for `setSelection(_:_:)`.
16. **`watch(_:recursively:onChange:)`** (your request 3): one stream for a whole local tree; `onChange` names the
    watched folder below which something changed. The default of the protocol watches the folders themselves
    only, so a branch on another file system still needs the present fan-out.
17. **`FileSystemCapabilities.removeOnly`** (your request 4, fileops 12): `VirtualFileSystem` sets it besides
    `.write` for a list; Clipboard, FileOperations (Paste, New Folder, New File, a copy into the location) withhold
    creating commands where `capabilities(for:)` contains it. Nobody reads it yet.
18. `PanelModel.prepare(_:computedSizes:)` for FileProperties' Space on very long lists (K033): optional, see
    the status file.

## Viewer (plugins-b)

19. `FileItem.linkTargetSize` is filled by the local file system now (L016): `item.linkTargetSize ?? item.size`
    is the size of what a link to a file leads to, as it was when the entry was read (`item(at:)` gives it fresh).

## Whoever owns `Tests/Fuzz`

20. Unchanged from `cross-requests/kernel.md` item 15. Nothing in this pass changes the behaviour those three
    checks state.
