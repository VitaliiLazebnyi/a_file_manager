# Cross-requests from the local file system agent (localfs)

## 1. Kernel: `FileItem.linkTargetSize` and `FileItem.device` (L016, device boundaries)

File: `Sources/AFMKernel/FileSystem/FileItem.swift`. Additive stored properties, with defaults in the public init so
nothing existing changes:

```swift
/// For a link to a regular file: the size of that file; nil for everything else (and where unknown).
public var linkTargetSize: Int64?
/// The device (volume) the entry itself is on, as `st_dev`; nil where the file system has no such notion.
public var device: Int64?
```

(They should also take part in `isSameEntry(as:)` only if the shell wants them to; they are not needed there.)

Why: the local `item(at:)` keeps `lstat` semantics (size 0 for a link), so the viewer reads the whole target once just
to measure it. The local file system already knows the target's size where it looks at the target (`LinkResolver` in
`Sources/Plugins/LocalFileSystem/LocalSupport.swift`) and will fill `linkTargetSize` as soon as the field exists; a
viewer can then use `item.linkTargetSize ?? item.size`. `device` is filled from `st_dev` / `ATTR_CMN_DEVID` the same
way. Findings that depend on it: L016, and the "device boundaries" item of the brief.

Until the field exists the local file system offers, additively, on the concrete type:
`LocalFileSystem.deviceID(of:) -> Int64?` and `LocalFileSystem.isMountPoint(_:) -> Bool` (not reachable from plugins
that do not import `LocalFileSystemPlugin`, hence this request).

## 2. Kernel: `FileSystemRegistry.placesDidChange` (L007)

File: `Sources/AFMKernel/FileSystem/FileSystemProvider.swift`, next to `volumeInfoDidChange`:

```swift
public static let placesDidChange = Notification.Name("AFMPlacesDidChange")
```

The local file system now posts a notification with exactly this raw name (`LocalFileSystem.placesDidChange`, object:
the provider) on the main thread when a background re-read of the places produced a list that differs from the previous
one. `places()` itself never waits any more (it returns the last list, or the fixed places before the first read has
landed).

## 3. Shell: DriveBarView / volume menus should observe it (L007, L004, L012, L013, L021)

Files: `Sources/AFMShell/Window/ButtonBarView.swift` (DriveBarView.rebuild, observes `NSWorkspace` mount notifications
today, which only start the provider's refresh and therefore get the old list),
`Sources/AFMShell/Panel/PanelViewController.swift:916`, `Sources/Plugins/Navigation/NavigationPlugin.swift:161`. Wanted:
also (or instead) observe `FileSystemRegistry.placesDidChange` on the main queue and rebuild the drive bar / volume menu
from `places()` then. The rebuild on the mount notification can stay; it just may show the previous list until this one
arrives.

## 4. File operations: temporaries and locked copies (L010, L018)

`LocalFileSystem` now keeps the "may unlock this locked copy for a rename/removal" allowance only for copies made under
a temporary name (`LocalFileSystem.isTemporaryName`: leading dot and a `.tmp` suffix or `.afm-` in the name, which
covers `.afm-<UUID>.tmp` of `FileJob`, `.<name>.afm-sync` of SyncPlan and the others), drops it on rename/removal,
expires it after 6 h, and never wipes the table wholesale. A locked copy that is made directly under its final name is
now as locked as its source: `remove()`/`move()` of it fail with EPERM and the caller's existing "locked" question
applies. A caller that makes temporaries under another naming scheme and renames them should keep to the leading dot
plus `.tmp`/`.afm-`. Also for the file-operations agent: `copy(_:to:progress:)` now refuses directories (EISDIR) and
special files (EINVAL) instead of copying a tree with no progress; `read`/`append` refuse non-regular files with an
error instead of blocking; `append` does not follow a symbolic link at the final component (ELOOP error);
`setAttributes` changes a link itself and never its target (so FileJob.swift:745/1367 and SyncPlan are now safe as they
are).

## 5. Unpacker / `createDirectory` (L029, L043)

`LocalFileSystem.createDirectory(at:)` keeps its idempotent contract ("creates the directory with any missing parents";
an existing folder, or a link to one, is success) because many callers rely on it (a copy into a linked folder,
`ensureFolder`). The finding asks for "created vs. was there" and for not writing through a pre-existing link. That
needs a new protocol method the callers can opt into, e.g. in `FileSystemProvider`:

```swift
/// Creates only the last component, failing with FileSystemError.alreadyExists when anything (a link included) is there; missing parents are made.
func createDirectory(at url: URL, exclusive: Bool) throws   // default: calls createDirectory(at:)
```

The local implementation can be added the moment the requirement exists; Unpacker.swift:291-306 and FileJob's tree copy
would then call it for folders they are about to fill.
