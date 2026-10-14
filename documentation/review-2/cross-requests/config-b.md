# Cross requests from config-b (Places, VirtualFolders, FolderTabs, Navigation)

## For the file-operations agent (FileJob, Clipboard): real identity of branch-view items
`VirtualFileSystem` (Sources/Plugins/VirtualFolders/VirtualFileSystem.swift) now has
`public func realLocation(of url: URL) -> URL?`: for a `vfolder:` branch or selected-branch location it returns the
real file or folder behind it (the same URL `real(_:)` uses for every change); nil for every other URL and for list
locations. Items listed in a branch view or list already carry their real `url`; only a `vfolder:` URL typed or
stored needs this. Use it where `FileJob` / paste compare a source with a destination folder (finding F018: move
inside a branch view), so a `vfolder:` location is compared by its real identity and never treated as another
provider's file. `virtualItem(at:)` still answers the real file for non-directories, as before.

## For the kernel agent: a batch change of tabs (optional)
FolderTabs now batches by saving `PanelTabs.onChange`, setting it to nil and calling it once afterwards (works with
the present API). A real `PanelTabs.performBatch { }` that fires `onChange` once would be tidier. Findings C029, C071.

## For the kernel agent: "does this location connect?" (optional)
FolderTabs decides whether a tab loaded from a tab file may be shown at once with a fixed list of network schemes
(ftp, ftps, sftp, http, https, ssh, smb, cifs, afp, nfs, webdav, dav, davs, vfolder). A provider property such as
`var connectsToServer: Bool { get }` (default false) on `FileSystemProvider`, readable without I/O, would replace the
list. Findings C072, C111.

## For the kernel/shell agents: start-up restoration of tabs (optional)
`PanelTabs.init(restoring:fallback:)` makes the stored active tab the shown one, which connects to a server at
start when that tab is on one. FolderTabs now guarantees this only for tab *files*; session restore is the shell's.
Finding C072/C111 (the "restoring tabs" half).

## For the kernel agent: pasteboard
NSPasteboard crashed in tests when a background read (availableType) met a main-thread clearContents/setString, so
Navigation reads the clipboard on the main thread only (cached by changeCount). A kernel-owned serial "pasteboard
access" queue used by every plugin that touches NSPasteboard (Clipboard, Navigation) would make background reads of
a huge/lazy clipboard possible. Findings C076, C077 stay open until then.
