import Foundation

/// An entry of the volume list: a disk, a mounted folder or a well-known place.
public struct Place {
    public enum Kind {
        case home, folder, internalDisk, externalDisk
    }

    public let name: String
    public let url: URL
    public let kind: Kind
    /// A drive that can be taken from the Mac: it gets an eject button. Never a disk inside
    /// the Mac (`isEjectable(...)`), never a place that is not a volume.
    public let canBeEjected: Bool

    public init(name: String, url: URL, kind: Kind, canBeEjected: Bool = false) {
        self.name = name
        self.url = url
        self.kind = kind
        self.canBeEjected = canBeEjected
    }

    /// The one rule for which volumes may be ejected, from what the system says of them (nil:
    /// it said nothing). Never the start-up disk or a system volume, and never a disk built
    /// into the Mac; a USB stick, a card, a disk image, an external disk and a server's share
    /// may. A disk the system does not call external is taken for an internal one.
    public static func isEjectable(
        path: String, isRootFileSystem: Bool?, isInternal: Bool?, isLocal: Bool?, isRemovable: Bool?,
        isEjectable: Bool?
    ) -> Bool {
        if isRootFileSystem == true || path == "/" || path.hasPrefix("/System/") { return false }
        // A card in the Mac's own reader is internal and removable: it may go.
        if isEjectable == true || isRemovable == true { return true }
        if isLocal == false { return true }
        return isInternal == false
    }
}

public struct VolumeInfo: Equatable {
    public let name: String
    public let freeBytes: Int64?
    public let totalBytes: Int64?
    /// False for network shares and other places where every question about a file travels:
    /// the panel then avoids anything that would ask about files one by one.
    public let isLocal: Bool

    public init(name: String, freeBytes: Int64? = nil, totalBytes: Int64? = nil, isLocal: Bool = true) {
        self.name = name
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        self.isLocal = isLocal
    }
}

/// What a file system can do, so commands can be offered or withheld before they fail.
public struct FileSystemCapabilities: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Files and folders can be created, changed and deleted.
    public static let write = Self(rawValue: 1)
    /// Deleted items can go to a Trash.
    public static let trash = Self(rawValue: 2)
    /// An existing file can be opened to continue it (`append(to:at:cancellation:)`).
    public static let append = Self(rawValue: 4)
    /// What is written is kept back for a while (in memory, in a spool file) before it reaches
    /// its place for good. Whoever is about to destroy the only other copy of what it wrote
    /// calls `commit(_:cancellation:)` first. Without this, `commit` has nothing to do and
    /// need not be called.
    public static let deferredWrites = Self(rawValue: 8)
    /// Said besides `write` by a location whose entries can be deleted or changed while
    /// nothing can be created in it (a list of files gathered from elsewhere): commands
    /// that make something new there (Paste, New Folder, New File, a copy into it) are
    /// withheld, the others are offered.
    public static let removeOnly = Self(rawValue: 16)
}

/// What is carried over when a file is copied from one file system to another.
public struct FileAttributes {
    public var modified: Date?
    public var permissions: UInt16?

    public init(modified: Date? = nil, permissions: UInt16? = nil) {
        self.modified = modified
        self.permissions = permissions
    }
}

public enum FileSystemError: LocalizedError {
    case noProvider(URL)
    case notSupported(String)
    case alreadyExists(String)
    /// A move or copy cannot be done inside the file system; the caller streams the contents.
    case crossesVolumes

    public var errorDescription: String? {
        switch self {
        case .noProvider(let url): return "No file system is available for \(url.absoluteString)."
        case .notSupported(let what): return "\(what) is not supported here."
        case .alreadyExists(let path): return "\(path) already exists."
        case .crossesVolumes: return "The file cannot be moved or copied inside its file system."
        }
    }
}

/// Access to the contents of a file. Used by one thread at a time; only `interrupt` may be
/// called from another thread meanwhile.
public protocol FileReader: AnyObject {
    /// The next block, or nil at the end of the file.
    func read(upToCount count: Int) throws -> Data?
    /// Continues reading at a position counted from the start of the file.
    func seek(to offset: UInt64) throws
    func close()
    /// Ends a `read` or `seek` that is waiting (for a server that does not answer, for a long
    /// way through a compressed stream): it throws soon, and so does every later one. **May be
    /// called from any thread**, at any time, more than once; it returns at once and never
    /// waits for the other thread. The reader's owner still calls `close` afterwards, on its
    /// own thread. The default does nothing: a reader that never waits long needs no more.
    func interrupt()
}

/// Used by one thread at a time; only `interrupt` may be called from another thread meanwhile.
public protocol FileWriter: AnyObject {
    func write(_ data: Data) throws
    /// Finishes the file and gives it the attributes the file system can keep.
    func close(attributes: FileAttributes) throws
    /// Ends a `write` or `close(attributes:)` that is waiting: it throws soon, and so does
    /// every later `write`. **May be called from any thread**, at any time, more than once; it
    /// returns at once. The owner still calls `close(attributes:)` afterwards (which may then
    /// throw as well) and removes what arrived, as after any failed write. The default does
    /// nothing.
    func interrupt()
}

extension FileReader {
    public func interrupt() {}
}

extension FileWriter {
    public func interrupt() {}
}

extension CancellationFlag {
    /// Interrupts `reader` when the flag is set, until the returned object is released: what
    /// a transfer does for the time it reads. The reader is not kept alive by it.
    public func interrupting(_ reader: FileReader) -> AnyObject {
        onCancel { [weak reader] in reader?.interrupt() }
    }

    public func interrupting(_ writer: FileWriter) -> AnyObject {
        onCancel { [weak writer] in writer?.interrupt() }
    }
}

/// What a lean listing tells about an entry: enough to walk a tree of folders, and no more.
public struct DirectoryEntry: Equatable {
    public let name: String
    /// A directory, or a symbolic link that points to one.
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let isPackage: Bool
    public let isHidden: Bool

    public init(
        name: String, isDirectory: Bool, isSymlink: Bool = false, isPackage: Bool = false, isHidden: Bool = false
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isPackage = isPackage
        self.isHidden = isHidden
    }

    public var isRealDirectory: Bool { isDirectory && !isSymlink }
}

/// Something a panel can show and operations can work on: the local disks, and later
/// archives or servers (spec 01 › File systems shown in a panel). A provider is chosen by the
/// scheme of a URL; every URL it is handed has its own scheme.
///
/// **Threading.** A provider is called from several threads at the same time: listings run in
/// the background, on several cores at once, while jobs and searches read and write on their
/// own threads. Every method must therefore be safe to call concurrently, and may block for as
/// long as the file system needs; none is called on the main thread except `parent(of:)`,
/// `displayPath(_:)`, `capabilities`, `capabilities(for:)` and `places()`, which must answer at once without
/// touching the file system's storage. A provider that has to ask the user (for a password, say) does it
/// with `Kernel.askUser`.
///
/// **Cancellation.** The calls that can wait long have a variant with a `CancellationFlag`.
/// Once the flag is set such a call ends soon, by returning what it has or by throwing, as
/// suits it: the caller looks at the flag, not at how the call ended, and takes nothing it
/// was given for complete. A provider whose calls wait for something it can abort (a
/// connection) registers with `CancellationFlag.onCancel`; one that works in a loop looks at
/// `isCancelled`. Each variant's default is the call without a flag, so a provider adds only
/// the ones it can really end early, and callers that hold a flag always pass it.
public protocol FileSystemProvider: AnyObject {
    var scheme: String { get }
    var capabilities: FileSystemCapabilities { get }
    /// What can be done at one location, for a file system whose locations differ (a view
    /// that shows folders of several file systems). Answers at once, like `capabilities`,
    /// which is the default. Whoever asks about a particular place asks this.
    func capabilities(for url: URL) -> FileSystemCapabilities

    // Reading
    func list(_ directory: URL, showHidden: Bool) throws -> [FileItem]
    /// Lists a directory piece by piece: `receive` gets each batch of entries as soon as it is
    /// known, and returns false when no more are wanted. A slow or very large directory can be
    /// shown this way while it is still being read. The default delivers everything at once.
    func list(_ directory: URL, showHidden: Bool, receive: ([FileItem]) -> Bool) throws
    /// `list(_:showHidden:)`, ended early once `cancellation` is set (see Cancellation above).
    /// Its default is `list(_:showHidden:)` and not the variant below, so that a file system
    /// keeps answering each of its two ways of listing as it did: one that can end a listing
    /// early offers both variants.
    func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem]
    /// `list(_:showHidden:receive:)`, ended early once `cancellation` is set.
    func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag, receive: ([FileItem]) -> Bool) throws
    /// Names and kinds only, for whoever walks folders and needs neither sizes, dates nor
    /// locations; with `foldersOnly`, only the entries that are directories (links to
    /// directories among them). In no particular order. The default lists in full; a file
    /// system that can read less offers that.
    func entries(of directory: URL, showHidden: Bool, foldersOnly: Bool, cancellation: CancellationFlag) throws
        -> [DirectoryEntry]
    /// The entry at `url` itself (a link is not followed); nil when nothing is there.
    func item(at url: URL) -> FileItem?
    /// `item(at:)`, ended early (with nil) once `cancellation` is set.
    func item(at url: URL, cancellation: CancellationFlag) -> FileItem?
    /// The directory above; nil for a root. Works on the URL alone.
    func parent(of directory: URL) -> URL?
    func read(_ url: URL) throws -> FileReader
    /// `read(_:)`, where opening itself can take long (a connection, the way to a member of
    /// a compressed archive): opening ends early, by throwing, once `cancellation` is set.
    /// The flag is the opening's only; a read of the reader that waits is ended with
    /// `FileReader.interrupt()` (`CancellationFlag.interrupting(_:)` ties the two together).
    func read(_ url: URL, cancellation: CancellationFlag) throws -> FileReader

    // Changing
    /// Creates the directory with any missing parents.
    func createDirectory(at url: URL) throws
    /// Creates a new file. Throws `FileSystemError.alreadyExists` when the name is taken; an
    /// existing file is never overwritten this way.
    func write(_ url: URL) throws -> FileWriter
    /// `write(_:)`, whose opening ends early, by throwing, once `cancellation` is set. As with
    /// `read(_:cancellation:)`, the writer itself is ended with `FileWriter.interrupt()`.
    func write(_ url: URL, cancellation: CancellationFlag) throws -> FileWriter
    /// Opens an existing file to continue it. With an `offset`, the file is first cut to that
    /// many bytes and what is written follows them (Resume: the caller has checked that those
    /// bytes are the start of what it writes); throws when the file is shorter. With nil,
    /// what is written follows the end of the file as it is (Append). Nothing is written
    /// anew and no second file is made, so a failed or cancelled append leaves the file as
    /// long as it got. Throws `FileSystemError.notSupported`, the default, where files cannot
    /// be continued; `capabilities(for:)` then lacks `.append`, and the caller writes the
    /// whole file again. Opening ends early once `cancellation` is set.
    func append(to url: URL, at offset: Int64?, cancellation: CancellationFlag) throws -> FileWriter
    /// Deletes one file, one link, or one **empty** directory. Whoever deletes a tree walks
    /// it, so that every item can be counted, skipped or cancelled.
    func remove(_ url: URL) throws
    func trash(_ url: URL) throws
    /// Renames within this file system, in one step. With `replacing`, an existing file at the
    /// destination is replaced; without, an existing destination is an error and stays
    /// untouched. Throws `FileSystemError.crossesVolumes` when renaming cannot do it.
    func move(_ source: URL, to destination: URL, replacing: Bool) throws
    /// Copies one file or link to a free name within this file system, with its attributes.
    /// `progress` receives the bytes copied so far and returns false to stop; a stopped or
    /// failed copy leaves nothing behind, and an existing destination is never touched.
    /// Throws `FileSystemError.crossesVolumes` when the file system cannot copy between the two
    /// places itself (two servers, two archives); the caller then streams the contents.
    func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws
    /// Changes the date of last change and the permissions of an item; nil members stay as
    /// they are (spec 07 › Change attributes).
    func setAttributes(_ attributes: FileAttributes, of url: URL) throws
    /// Gives the existing item at `destination`, in this file system, what `setAttributes`
    /// cannot carry from the item at `source`: extended attributes (tags, comments, labels),
    /// access control lists, flags (hidden, and the Finder's lock) and the date of creation.
    /// The date of last change and the permissions stay as they are; those are
    /// `setAttributes`' business. Links are not followed. For folders that were created
    /// rather than copied, and for files that were streamed.
    ///
    /// **Call it last**: for a folder after everything is inside, and after `setAttributes`.
    /// A lock that comes along forbids every later change of the item and of what a folder
    /// holds; the file system that set it still lets the copy be renamed or removed.
    ///
    /// `source` may be of another file system. Throws `FileSystemError.notSupported`, the
    /// default, when this file system cannot read metadata from there or keeps none; throws
    /// the first error after carrying what it could when only a part arrived. Either way the
    /// destination is as usable as before, and a caller may go on without (`try?`).
    func copyMetadata(from source: URL, to destination: URL) throws
    /// Makes everything durable that was written at or below `url` through this file system:
    /// when it returns, the contents of every writer that was closed, every directory made,
    /// every removal, rename and change of attributes are where they belong (in the archive
    /// file, on the server), and no longer only in memory or in a temporary file. Writers
    /// that are still open are not included. Blocks for as long as that takes; ends early, by
    /// throwing, once `cancellation` is set.
    ///
    /// **Who must call it:** a caller that wrote here and is about to destroy the only other
    /// copy of what it wrote (a Move that deletes its sources, a Pack that deletes the packed
    /// files), after its last writer is closed and before the first deletion, when
    /// `capabilities(for:)` holds `.deferredWrites`. One call for the common folder of all it
    /// wrote is enough, and cheaper than one per file.
    ///
    /// **A throw means** that nothing written below `url` since the last successful commit
    /// can be relied on to exist: the caller keeps its sources, reports the error and ends
    /// the operation as failed. The default does nothing and never throws.
    func commit(_ url: URL, cancellation: CancellationFlag) throws
    /// `commit(_:cancellation:)` that says how far it is: `progress` receives the bytes
    /// written so far and all there are to write (0 when unknown), between the members of
    /// an archive or the blocks of an upload, and returns false to stop, which ends the
    /// commit as a set flag does. It may wait inside `progress` (a job that the user has
    /// paused holds its report), so a commit can be held back while it runs. The default is
    /// the call without `progress`, which is asked once before it; a file system whose
    /// commit takes long offers this, and whoever shows progress calls it.
    func commit(_ url: URL, cancellation: CancellationFlag, progress: (Int64, Int64) -> Bool) throws
    /// The mark files from this location carry for having come from elsewhere (the raw value
    /// of `com.apple.quarantine`): an archive that was downloaded says its own mark for all
    /// its members. Nil, the default, when there is none. May read from storage; not for the
    /// main thread.
    func quarantine(of url: URL) -> Data?
    /// Puts such a mark on an existing file or folder. A file system that cannot keep marks
    /// does nothing, which is the default; one that can throws when it fails. Whoever copies a
    /// file between two file systems asks the source's `quarantine(of:)` and, given a value,
    /// calls this on the destination after the file is written and closed (and before it is
    /// renamed into place, where a temporary name is used). A copy inside one file system is
    /// that file system's own affair.
    func setQuarantine(_ value: Data, of url: URL) throws

    // Surroundings
    /// How a location is written for the user.
    func displayPath(_ url: URL) -> String
    /// Reads a location the user typed in this file system's own notation; nil when the text
    /// is not one of its locations. Whatever `displayPath` writes must be readable here, because
    /// dialogs propose targets in that form and read them back.
    func location(from text: String) -> URL?
    /// Whether a path from the root typed while a panel shows this file system (`/pub/files`)
    /// means a place on it. False, the default, for file systems that write their locations
    /// with their scheme (`ftp://host/pub`): there such a path is one of the local disks.
    var readsRootedPaths: Bool { get }
    /// Entries for the volume list.
    func places() -> [Place]
    func volume(of url: URL) -> VolumeInfo?
    /// `volume(of:)`, ended early (with nil) once `cancellation` is set. The question can
    /// wait as long as a listing can (a share that has stopped answering holds it for good),
    /// so whoever asks on behalf of a panel asks this, and a file system whose answer may
    /// wait offers it. The default is `volume(of:)`.
    func volume(of url: URL, cancellation: CancellationFlag) -> VolumeInfo?
    /// Sum of the file sizes below a directory, links not followed; zero once `cancellation`
    /// is set. The default lists the tree; a file system with a cheaper way offers that.
    func totalSize(of directory: URL, cancellation: CancellationFlag) -> Int64
    /// Reports changes made by others to the given directories until the returned object is
    /// released. `onChange` is called on the main thread with the directories that changed.
    /// Nil when watching is not available.
    func watch(_ directories: [URL], onChange: @escaping ([URL]) -> Void) -> AnyObject?
    /// The same for whole trees: with `recursively`, `onChange` names a watched directory
    /// when anything at or below it changed, however deep. For a view that shows a tree as
    /// one list, which would otherwise have to watch every folder of it. The default
    /// watches the directories themselves only, as the call above does: a file system that
    /// can watch a tree at the cost of one folder offers this.
    func watch(_ directories: [URL], recursively: Bool, onChange: @escaping ([URL]) -> Void) -> AnyObject?

    // The calls that change something, ended early once `cancellation` is set (see
    // Cancellation above). Each one's default is the call without a flag. A file system whose
    // changes travel (to a server) offers them, and whoever holds a flag passes it.
    func createDirectory(at url: URL, cancellation: CancellationFlag) throws
    func remove(_ url: URL, cancellation: CancellationFlag) throws
    func move(_ source: URL, to destination: URL, replacing: Bool, cancellation: CancellationFlag) throws
    func setAttributes(_ attributes: FileAttributes, of url: URL, cancellation: CancellationFlag) throws
    func copyMetadata(from source: URL, to destination: URL, cancellation: CancellationFlag) throws
    func setQuarantine(_ value: Data, of url: URL, cancellation: CancellationFlag) throws
    /// Creates a directory that must not have been there. With `exclusive`, only the last
    /// component is made new (missing parents are made as usual), and anything already at
    /// `url`, a link included, is `FileSystemError.alreadyExists`: whoever is about to fill
    /// the folder then knows it is its own and not something a link led to. Without, this is
    /// `createDirectory(at:)`. The default is `createDirectory(at:)` whatever `exclusive`
    /// says, preceded by a look with `item(at:)` when it is set: a file system that can make
    /// the two one step offers this itself.
    func createDirectory(at url: URL, exclusive: Bool) throws
    /// `remove(_:cancellation:)` for an item of a tree that is being deleted: the item is
    /// removed only if it really lies below `root`, with every folder on the way from `root`
    /// to it a folder and none a link. Whoever deletes a tree lists a folder and then
    /// removes what it found by name; a folder that somebody swaps for a link in between
    /// would lead a removal by name to wherever the link points. `root` is the folder the
    /// deletion began with (a real folder when it began), `url` anything below it. Throws,
    /// having removed nothing, when the way has changed. The default is
    /// `remove(_:cancellation:)`: a file system that has no links, or cannot check the way
    /// and remove in one go, need not offer more.
    func remove(_ url: URL, below root: URL, cancellation: CancellationFlag) throws
    /// `createDirectory(at:exclusive:)`, ended early once `cancellation` is set. The default
    /// is the call without a flag.
    func createDirectory(at url: URL, exclusive: Bool, cancellation: CancellationFlag) throws

    /// The real location this one is another way of writing: a folder shown through a view
    /// (a branch, a list, the outside of an archive) names the place where its entries
    /// really are. Nil, the default, for a location that is itself. Works on the URL alone.
    func realLocation(of url: URL) -> URL?
    /// Whether the locations of this file system are on a server, so that showing one may
    /// have to connect (and ask for a password). Answers at once; false by default.
    var connectsToServer: Bool { get }
    /// The order in which several files of this file system are best read one after the
    /// other: an archive that is read as one stream gives them in the order they lie in it,
    /// so that no file makes the reading start over. The default leaves the order as it is.
    func readOrder(of urls: [URL]) -> [URL]
    /// `copy(_:to:progress:)`, ended early, by throwing, once `cancellation` is set: also
    /// while the copy waits where `progress` is not asked (for a volume that has stopped
    /// answering, between two blocks, while the attributes are carried over). As with the
    /// plain call, a stopped copy leaves nothing behind. The default is the plain call,
    /// which looks at the flag whenever `progress` is asked; a file system that can end the
    /// wait itself offers this, and whoever holds a flag calls it. Such a file system may
    /// call `progress` on another thread than the caller's while the caller waits here,
    /// one call at a time and never after this has returned.
    func copy(_ source: URL, to destination: URL, cancellation: CancellationFlag, progress: (Int64) -> Bool) throws
    /// The top of the tree `url` belongs to. Works on the URL alone, like `parent(of:)`. The
    /// default goes up with `parent(of:)` one level at a time, which for a location
    /// thousands of levels deep is thousands of steps over a long text each; a file system
    /// that knows its tops (the root of a disk, of an archive, of a server) says so at once.
    func root(of url: URL) -> URL
}

/// What a provider does not have to offer.
extension FileSystemProvider {
    public func list(_ directory: URL, showHidden: Bool, receive: ([FileItem]) -> Bool) throws {
        _ = receive(try list(directory, showHidden: showHidden))
    }

    public func capabilities(for _: URL) -> FileSystemCapabilities { capabilities }

    public func list(_ directory: URL, showHidden: Bool, cancellation _: CancellationFlag) throws -> [FileItem] {
        try list(directory, showHidden: showHidden)
    }

    public func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag, receive: ([FileItem]) -> Bool)
        throws
    {
        try list(directory, showHidden: showHidden) { items in
            !cancellation.isCancelled && receive(items) && !cancellation.isCancelled
        }
    }

    public func entries(of directory: URL, showHidden: Bool, foldersOnly: Bool, cancellation: CancellationFlag) throws
        -> [DirectoryEntry]
    {
        try entriesByListing(
            of: directory, showHidden: showHidden, foldersOnly: foldersOnly, cancellation: cancellation)
    }

    /// The lean listing as any file system can give it: from the full one.
    public func entriesByListing(
        of directory: URL, showHidden: Bool, foldersOnly: Bool, cancellation: CancellationFlag
    ) throws -> [DirectoryEntry] {
        try list(directory, showHidden: showHidden, cancellation: cancellation).compactMap { item in
            foldersOnly && !item.isDirectory
                ? nil
                : DirectoryEntry(
                    name: item.name, isDirectory: item.isDirectory, isSymlink: item.isSymlink,
                    isPackage: item.isPackage,
                    isHidden: item.isHidden)
        }
    }

    public func item(at url: URL, cancellation: CancellationFlag) -> FileItem? {
        cancellation.isCancelled ? nil : item(at: url)
    }

    public func read(_ url: URL, cancellation: CancellationFlag) throws -> FileReader {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        return try read(url)
    }

    public func write(_ url: URL, cancellation: CancellationFlag) throws -> FileWriter {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        return try write(url)
    }

    public func append(to _: URL, at _: Int64?, cancellation _: CancellationFlag) throws -> FileWriter {
        throw FileSystemError.notSupported("Continuing a file")
    }

    public func copyMetadata(from _: URL, to _: URL) throws {
        throw FileSystemError.notSupported("Copying metadata")
    }
    public func commit(_: URL, cancellation _: CancellationFlag) {}
    public func commit(_ url: URL, cancellation: CancellationFlag, progress: (Int64, Int64) -> Bool) throws {
        if cancellation.isCancelled || !progress(0, 0) { throw CocoaError(.userCancelled) }
        try commit(url, cancellation: cancellation)
    }
    public func quarantine(of _: URL) -> Data? { nil }
    public func setQuarantine(_: Data, of _: URL) {}

    public func trash(_: URL) throws { throw FileSystemError.notSupported("Moving to the Trash") }
    public func setAttributes(_: FileAttributes, of _: URL) throws {
        throw FileSystemError.notSupported("Changing attributes")
    }
    public func displayPath(_ url: URL) -> String { url.absoluteString }
    public func location(from text: String) -> URL? {
        guard text.lowercased().hasPrefix(scheme + ":"), let url = URL(string: text), url.scheme == scheme else {
            return nil
        }
        return url
    }
    public var readsRootedPaths: Bool { scheme == "file" }
    public func places() -> [Place] { [] }
    public func volume(of _: URL) -> VolumeInfo? { nil }
    public func volume(of url: URL, cancellation: CancellationFlag) -> VolumeInfo? {
        cancellation.isCancelled ? nil : volume(of: url)
    }
    public func watch(_: [URL], onChange _: @escaping ([URL]) -> Void) -> AnyObject? { nil }
    public func watch(_ directories: [URL], recursively _: Bool, onChange: @escaping ([URL]) -> Void) -> AnyObject? {
        watch(directories, onChange: onChange)
    }

    public func createDirectory(at url: URL, cancellation: CancellationFlag) throws {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        try createDirectory(at: url)
    }

    public func remove(_ url: URL, cancellation: CancellationFlag) throws {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        try remove(url)
    }

    public func move(_ source: URL, to destination: URL, replacing: Bool, cancellation: CancellationFlag) throws {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        try move(source, to: destination, replacing: replacing)
    }

    public func setAttributes(_ attributes: FileAttributes, of url: URL, cancellation: CancellationFlag) throws {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        try setAttributes(attributes, of: url)
    }

    public func copyMetadata(from source: URL, to destination: URL, cancellation: CancellationFlag) throws {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        try copyMetadata(from: source, to: destination)
    }

    public func setQuarantine(_ value: Data, of url: URL, cancellation: CancellationFlag) throws {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        try setQuarantine(value, of: url)
    }

    public func createDirectory(at url: URL, exclusive: Bool) throws {
        if exclusive, item(at: url) != nil { throw FileSystemError.alreadyExists(displayPath(url)) }
        try createDirectory(at: url)
    }

    public func remove(_ url: URL, below _: URL, cancellation: CancellationFlag) throws {
        try remove(url, cancellation: cancellation)
    }

    public func createDirectory(at url: URL, exclusive: Bool, cancellation: CancellationFlag) throws {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        guard exclusive else {
            try createDirectory(at: url, cancellation: cancellation)
            return
        }
        try createDirectory(at: url, exclusive: true)
    }

    public func realLocation(of _: URL) -> URL? { nil }
    public var connectsToServer: Bool { false }
    public func readOrder(of urls: [URL]) -> [URL] { urls }

    public func copy(_ source: URL, to destination: URL, cancellation: CancellationFlag, progress: (Int64) -> Bool)
        throws
    {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        do {
            try copy(source, to: destination) { progress($0) && !cancellation.isCancelled }
        } catch {
            // However the copy ended, a caller that set the flag is told that it was stopped.
            throw cancellation.isCancelled ? CocoaError(.userCancelled) : error
        }
    }
}

extension FileSystemProvider {
    /// Sum of the file sizes below a directory (spec 01 › Directory sizes during selection).
    public func totalSize(of directory: URL) -> Int64 {
        totalSize(of: directory, cancellation: CancellationFlag())
    }

    public func totalSize(of directory: URL, cancellation: CancellationFlag) -> Int64 {
        totalSizeByListing(of: directory, cancellation: cancellation)
    }

    /// The sum as any file system can work it out, by listing every folder; the subfolders
    /// are measured on all cores at once. What a file system falls back on when it has a
    /// faster way of its own that does not work everywhere: each subfolder is asked of the
    /// file system again (`totalSize(of:cancellation:)`), so its faster way gets its chance
    /// one level down.
    ///
    /// A tree can be as deep as whoever made it liked (an archive with thousands of nested
    /// folders, a server that shows a folder inside itself for ever), and a thread's stack
    /// cannot. So only the first levels are walked by calls that nest; from there on the
    /// walk goes level by level without nesting, stops at a depth no real tree has, and
    /// never lists a location twice. What was counted by then is the answer.
    public func totalSizeByListing(of directory: URL, cancellation: CancellationFlag) -> Int64 {
        let depth = TreeWalk.nesting
        guard depth < TreeWalk.deepestNesting else {
            return totalSizeLevelByLevel(of: directory, cancellation: cancellation)
        }
        TreeWalk.nesting = depth + 1
        defer { TreeWalk.nesting = depth }
        guard !cancellation.isCancelled,
            let items = try? list(directory, showHidden: true, cancellation: cancellation),
            !cancellation.isCancelled
        else { return 0 }
        let files = items.reduce(Int64(0)) { $1.isRealDirectory ? $0 : $0.addingSaturated($1.size) }
        let folders = Parallel.map(items.filter(\.isRealDirectory)) {
            cancellation.isCancelled ? 0 : self.totalSize(of: $0.url, cancellation: cancellation)
        }
        return cancellation.isCancelled ? 0 : folders.reduce(files) { $0.addingSaturated($1) }
    }

    /// The same without a call inside a call: every level of the tree is listed on all cores
    /// before the next one is begun.
    private func totalSizeLevelByLevel(of directory: URL, cancellation: CancellationFlag) -> Int64 {
        var total: Int64 = 0
        var level = [directory]
        var seen: Set<String> = [directory.locationKey]
        var depth = 0
        while !level.isEmpty, depth < TreeWalk.deepestTree, !cancellation.isCancelled {
            let listings = Parallel.map(level) { folder -> [FileItem] in
                cancellation.isCancelled
                    ? [] : (try? self.list(folder, showHidden: true, cancellation: cancellation)) ?? []
            }
            var next: [URL] = []
            for items in listings {
                for item in items {
                    if !item.isRealDirectory {
                        total = total.addingSaturated(item.size)
                    } else if seen.insert(item.url.locationKey).inserted {
                        next.append(item.url)
                    }
                }
            }
            level = next
            depth += 1
        }
        return cancellation.isCancelled ? 0 : total
    }

    /// Continues a file without a way to stop the opening.
    public func append(to url: URL, at offset: Int64?) throws -> FileWriter {
        try append(to: url, at: offset, cancellation: CancellationFlag())
    }

    public func commit(_ url: URL) throws {
        try commit(url, cancellation: CancellationFlag())
    }

    /// The top of the tree `url` belongs to, found by going up (the default of the requirement).
    public func root(of url: URL) -> URL {
        var current = url
        while let parent = parent(of: current) { current = parent }
        return current
    }
}

/// The file systems the plugins provide, found by URL scheme. Filled while the plugins start
/// and only read afterwards, so it may be read from any thread.
public final class FileSystemRegistry {
    private var providers: [FileSystemProvider] = []
    private var flushers: [(URL, CancellationFlag) throws -> Void] = []
    private var releasers: [(URL) -> Void] = []
    private var closers: [(URL, CancellationFlag) -> Void] = []

    public init() {}

    public func register(_ provider: FileSystemProvider) {
        precondition(
            !providers.contains { $0.scheme == provider.scheme },
            "A file system for \(provider.scheme): is registered twice")
        providers.append(provider)
    }

    /// Every provider, in registration order.
    public var all: [FileSystemProvider] { providers }

    public func provider(for url: URL) throws -> FileSystemProvider {
        guard let provider = providers.first(where: { $0.scheme == (url.scheme ?? "file") }) else {
            throw FileSystemError.noProvider(url)
        }
        return provider
    }

    /// What can be done at a location; nothing where no file system answers for it. Answers
    /// at once, on any thread.
    public func capabilities(for url: URL) -> FileSystemCapabilities {
        (try? provider(for: url))?.capabilities(for: url) ?? []
    }

    /// Posted on the main thread when a file system has learned that what `volume(of:)` says
    /// about a volume (its free space, say) is no longer what it last answered. The object is
    /// the file system (a `FileSystemProvider`), and `userInfo` holds the volume's root under
    /// `volumeRootKey`, when the file system knows it: whoever
    /// shows a `VolumeInfo` of a place at or below it asks `volume(of:)` again, in the
    /// background, and hands the answer to `PanelModel.setVolume`.
    public static let volumeInfoDidChange = Notification.Name("AFMVolumeInfoDidChange")
    public static let volumeRootKey = "volumeRoot"

    /// Posted on the main thread when a file system has learned that what `places()` answers
    /// is no longer what it last answered (a disk came or went). The object is the file
    /// system. Whoever shows the places (the drive bar, a volume menu) asks again.
    public static let placesDidChange = Notification.Name("AFMPlacesDidChange")

    /// The real location behind a location, followed to the end: what
    /// `FileSystemProvider.realLocation(of:)` answers, asked again of the file system of the
    /// answer, until one says the location is itself. Works on the URLs alone.
    public func realLocation(of url: URL) -> URL {
        var current = url
        // No honest chain is long; a circle among file systems ends here.
        for _ in 0..<16 {
            guard let next = (try? provider(for: current))?.realLocation(of: current), !next.isSameLocation(as: current)
            else { break }
            current = next
        }
        return current
    }

    /// What `addFlusher` was given. Guarded by `flushLock`: flushers are added while the
    /// plugins start and called from the threads of jobs.
    private static let flushLock = NSLock()

    /// Registers work that makes a file up to date before somebody else uses it: a plugin
    /// that keeps changes to a file back for a while (an archive that is written after a
    /// delay) writes them when asked. `flush` is called on background threads with the
    /// location of a file that is about to be read, moved or deleted; it returns at once for
    /// a file it has nothing to do with, blocks for as long as the writing takes otherwise,
    /// and throws when the file could not be brought up to date.
    public func addFlusher(_ flush: @escaping (URL, CancellationFlag) throws -> Void) {
        Self.flushLock.lock()
        flushers.append(flush)
        Self.flushLock.unlock()
    }

    /// Has every registered flusher bring the file at `url` up to date. **Who calls it:**
    /// whoever is about to read, copy, move, upload or delete a file that some plugin may
    /// still have changes for, on its own background thread, before the first read. A throw
    /// means the file on disk is not what the user sees: the operation is not carried out.
    public func flushPendingWrites(to url: URL, cancellation: CancellationFlag) throws {
        Self.flushLock.lock()
        let flushers = self.flushers
        Self.flushLock.unlock()
        for flush in flushers { try flush(url, cancellation) }
    }

    // MARK: Letting go of a volume

    /// Registers who keeps something open on volumes and lets go of it before one is ejected:
    /// closes the windows that show its files, stops what reads there. Called on the main
    /// thread with the volume's location; whoever registers is the plugin that holds it.
    public func addVolumeReleaser(_ release: @escaping (URL) -> Void) {
        Self.flushLock.lock()
        releasers.append(release)
        Self.flushLock.unlock()
    }

    /// The same for what has to wait on the disk to let go (writing what is pending, closing
    /// files): called on the thread of the job that ejects, after the releasers.
    public func addVolumeCloser(_ close: @escaping (URL, CancellationFlag) -> Void) {
        Self.flushLock.lock()
        closers.append(close)
        Self.flushLock.unlock()
    }

    /// Main thread: every releaser lets go of what it shows or reads on `volume`.
    public func releaseVolume(_ volume: URL) {
        Self.flushLock.lock()
        let releasers = self.releasers
        Self.flushLock.unlock()
        for release in releasers { release(volume) }
    }

    /// Job thread: what is pending for `volume` is written (`flushPendingWrites`), then every
    /// closer closes what it keeps open there. A failed write is thrown, and nothing is closed:
    /// a volume that is ejected then would lose it.
    public func closeFiles(on volume: URL, cancellation: CancellationFlag) throws {
        try flushPendingWrites(to: volume, cancellation: cancellation)
        Self.flushLock.lock()
        let closers = self.closers
        Self.flushLock.unlock()
        for close in closers { close(volume, cancellation) }
    }

    /// Blocks like the provider's own `item(at:)`; not for the main thread.
    public func item(at url: URL) -> FileItem? {
        (try? provider(for: url))?.item(at: url)
    }

    /// How a location is written for the user: each file system decides for its own.
    public func displayPath(_ url: URL) -> String {
        (try? provider(for: url))?.displayPath(url) ?? url.absoluteString
    }

    /// Reads a location typed by the user. A relative path belongs to the file system of
    /// `base` and `~` is the home folder. A path from the root (`/Users/me`) is one of the
    /// local disks, which is how their locations are written for the user, unless the file
    /// system of `base` reads such paths itself (`readsRootedPaths`). Works on the text alone.
    public func location(from text: String, relativeTo base: URL) -> URL {
        let text = text.trimmingCharacters(in: .whitespaces)
        // A location written out in full, in the notation of one of the file systems.
        if let url = providers.lazy.compactMap({ $0.location(from: text) }).first {
            return url.standardized
        }
        if text == "~" || text.hasPrefix("~/") {
            return URL(fileURLWithPath: NSString(string: text).expandingTildeInPath, isDirectory: false).standardized
        }
        if text.hasPrefix("/") {
            let baseReadsIt = (try? provider(for: base))?.readsRootedPaths ?? true
            if !baseReadsIt, providers.contains(where: { $0.scheme == "file" }) {
                return URL(fileURLWithPath: text, isDirectory: false).standardized
            }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
            components.path = text
            return (components.url ?? URL(fileURLWithPath: text, isDirectory: false)).standardized
        }
        return text.isEmpty ? base : base.appending(name: text).standardized
    }
}

/// How deep the calls of a walk through a tree of folders are nested on the current thread.
/// For walks that call themselves once per level (`totalSizeByListing`), so that they can
/// stop nesting before a thread's stack is used up.
public enum TreeWalk {
    /// Calls nested deeper than this on one thread go on without nesting.
    public static let deepestNesting = 32
    /// Levels below which a walk that no longer nests gives up: no real tree is that deep.
    public static let deepestTree = 1_000

    private static let key: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key, nil)
        return key
    }()

    /// The number of walk calls under way on this thread, one inside the other.
    public static var nesting: Int {
        get { Int(bitPattern: pthread_getspecific(key)) }
        set { pthread_setspecific(key, UnsafeRawPointer(bitPattern: newValue)) }
    }
}
