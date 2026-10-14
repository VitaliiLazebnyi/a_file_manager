public import Foundation

/// What `FileSystemProvider.watch` returns: the watching goes on until it is released, which
/// may happen on any thread.
public typealias WatchToken = AnyObject & Sendable

/// Something a panel can show and operations can work on: the local disks, and later archives or servers (spec 01 ›
/// File systems shown in a panel).
///
/// A provider is chosen by the scheme of a URL; every URL it is handed has its own scheme.
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
public protocol FileSystemProvider: AnyObject, Sendable {
    /// The scheme of every URL of this file system (`file`, `zip`, `sftp`); one plugin's alone.
    var scheme: String { get }
    /// What can be done with this file system as a whole. Answers at once.
    var capabilities: FileSystemCapabilities { get }
    /// Whether a path from the root typed while a panel shows this file system (`/pub/files`)
    /// means a place on it. False, the default, for file systems that write their locations
    /// with their scheme (`ftp://host/pub`): there such a path is one of the local disks.
    var readsRootedPaths: Bool { get }
    /// Whether the locations of this file system are on a server, so that showing one may
    /// have to connect (and ask for a password). Answers at once; false by default.
    var connectsToServer: Bool { get }
    /// What can be done at one location, for a file system whose locations differ (a view
    /// that shows folders of several file systems). Answers at once, like `capabilities`,
    /// which is the default. Whoever asks about a particular place asks this.
    func capabilities(for url: URL) -> FileSystemCapabilities

    // Reading
    /// The entries of a directory, all at once; with `showHidden`, hidden ones too. Throws
    /// when the directory cannot be read.
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
    /// The entry at `url` itself (a link is not followed); nil when nothing is there.
    func item(at url: URL) -> FileItem?
    /// `item(at:)`, ended early (with nil) once `cancellation` is set.
    func item(at url: URL, cancellation: CancellationFlag) -> FileItem?
    /// The directory above; nil for a root. Works on the URL alone.
    func parent(of directory: URL) -> URL?
    /// Opens a file to read its contents from the start.
    func read(_ url: URL) throws -> any FileReader
    /// `read(_:)`, where opening itself can take long (a connection, the way to a member of
    /// a compressed archive): opening ends early, by throwing, once `cancellation` is set.
    /// The flag is the opening's only; a read of the reader that waits is ended with
    /// `FileReader.interrupt()` (`CancellationFlag.interrupting(_:)` ties the two together).
    func read(_ url: URL, cancellation: CancellationFlag) throws -> any FileReader

    // Changing
    /// Creates the directory with any missing parents.
    func createDirectory(at url: URL) throws
    /// Creates a new file. Throws `FileSystemError.alreadyExists` when the name is taken; an
    /// existing file is never overwritten this way.
    func write(_ url: URL) throws -> any FileWriter
    /// `write(_:)`, whose opening ends early, by throwing, once `cancellation` is set. As with
    /// `read(_:cancellation:)`, the writer itself is ended with `FileWriter.interrupt()`.
    func write(_ url: URL, cancellation: CancellationFlag) throws -> any FileWriter
    /// Opens an existing file to continue it. With an `offset`, the file is first cut to that
    /// many bytes and what is written follows them (Resume: the caller has checked that those
    /// bytes are the start of what it writes); throws when the file is shorter. With nil,
    /// what is written follows the end of the file as it is (Append). Nothing is written
    /// anew and no second file is made, so a failed or cancelled append leaves the file as
    /// long as it got. Throws `FileSystemError.notSupported`, the default, where files cannot
    /// be continued; `capabilities(for:)` then lacks `.append`, and the caller writes the
    /// whole file again. Opening ends early once `cancellation` is set.
    func append(to url: URL, at offset: Int64?, cancellation: CancellationFlag) throws -> any FileWriter
    /// Deletes one file, one link, or one **empty** directory. Whoever deletes a tree walks
    /// it, so that every item can be counted, skipped or cancelled.
    func remove(_ url: URL) throws
    /// Moves an item, folders with what they hold, to the Trash. Throws
    /// `FileSystemError.notSupported`, the default, where there is none (no `.trash`).
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
    /// Entries for the volume list.
    func places() -> [Place]
    /// The volume a location is on, for the status line; nil, the default, when the file
    /// system cannot say.
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
    func watch(_ directories: [URL], onChange: @escaping @MainActor @Sendable ([URL]) -> Void) -> (any WatchToken)?

    // The calls that change something, ended early once `cancellation` is set (see
    // Cancellation above). Each one's default is the call without a flag. A file system whose
    // changes travel (to a server) offers them, and whoever holds a flag passes it.
    /// `createDirectory(at:)`, ended early once `cancellation` is set.
    func createDirectory(at url: URL, cancellation: CancellationFlag) throws
    /// `remove(_:)`, ended early once `cancellation` is set.
    func remove(_ url: URL, cancellation: CancellationFlag) throws
    /// `move(_:to:replacing:)`, ended early once `cancellation` is set.
    func move(_ source: URL, to destination: URL, replacing: Bool, cancellation: CancellationFlag) throws
    /// `setAttributes(_:of:)`, ended early once `cancellation` is set.
    func setAttributes(_ attributes: FileAttributes, of url: URL, cancellation: CancellationFlag) throws
    /// `copyMetadata(from:to:)`, ended early once `cancellation` is set.
    func copyMetadata(from source: URL, to destination: URL, cancellation: CancellationFlag) throws
    /// `setQuarantine(_:of:)`, ended early once `cancellation` is set.
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
