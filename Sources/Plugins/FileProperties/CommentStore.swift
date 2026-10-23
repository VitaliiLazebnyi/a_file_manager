import AFMKernel
import Foundation

/// Reads and writes the comment files through the file-system providers, so comments work
/// wherever files can be written, and remembers what it read.
///
/// **Threading.** Every method may be called from any thread, several at once; none belongs on
/// the main thread, because all of them may read a file. The Comment column asks for every row
/// of a folder on several threads: the folder's file is then read once, and the other threads
/// wait for that reading instead of starting their own. Nobody waits for ever: a reading
/// ends when its caller's flag is set, and a thread that waits for another's reading gives
/// up when its own flag is set or after `waitLimit` (the reader may be held by a server
/// that has stopped answering, with a flag nobody sets).
///
/// `remembered`, `beingRead`, `generations` and `waitLimit` are guarded by `condition`.
internal final class CommentStore: @unchecked Sendable {
    private struct Remembered {
        let comments: [String: String]
        let read: Date
    }

    /// Comment files larger than this are not read; no folder has that many comments.
    private static let sizeLimit = 16 * 1_024 * 1_024
    /// How long a reading is trusted.
    ///
    /// Changes made here are known at once (`forget`); this is for changes other programs make.
    private static let lifetime: TimeInterval = 3
    /// How often a waiting thread looks at its flag.
    private static let waitStep: TimeInterval = 0.1
    /// How long a thread waits for another thread's reading of the same folder.
    internal var waitLimit: TimeInterval {
        get { condition.withLock { patience } }
        set { condition.withLock { patience = newValue } }
    }
    private var patience: TimeInterval = 10

    private let fileSystems: FileSystemRegistry
    private let condition = NSCondition()
    private var remembered: [String: Remembered] = [:]
    private var beingRead: Set<String> = []
    /// Counts the changes made to each folder's comments here.
    ///
    /// A reading that began before a change is not remembered: it may be the file as it was.
    private var generations: [String: Int] = [:]

    /// A store that reads and writes the comment files through `fileSystems`.
    internal init(fileSystems: FileSystemRegistry) {
        self.fileSystems = fileSystems
    }

    /// The comment of an item, on one line; empty when it has none.
    internal func comment(for item: FileItem, cancellation: CancellationFlag) -> String {
        comments(in: item.url.deletingLastPathComponent(), cancellation: cancellation)[item.name.lowercased()] ?? ""
    }

    /// The comments of a folder by lower-cased file name.
    ///
    /// Nothing when `cancellation` was set before they were read, or when another thread's reading
    /// did not come back in time.
    internal func comments(in directory: URL, cancellation: CancellationFlag) -> [String: String] {
        let key = directory.locationKey
        condition.lock()
        let deadline = Date().addingTimeInterval(patience)
        while true {
            if let known = remembered[key], -known.read.timeIntervalSinceNow < Self.lifetime {
                condition.unlock()
                return known.comments
            }
            if !beingRead.contains(key) { break }
            // The reader may never come back; whoever waits for it looks up now and then.
            if cancellation.isCancelled || Date() >= deadline {
                condition.unlock()
                return [:]
            }
            condition.wait(until: min(deadline, Date().addingTimeInterval(Self.waitStep)))
        }
        beingRead.insert(key)
        let generation = generations[key] ?? 0
        condition.unlock()

        let comments = load(directory, cancellation: cancellation).commentsByName
        condition.lock()
        if remembered.count > 256 { remembered.removeAll() }
        // Changed here while it was being read: what was read is returned, but not kept.
        // Nor is a reading that was cut short: it is not what the file holds.
        if (generations[key] ?? 0) == generation, !cancellation.isCancelled {
            remembered[key] = Remembered(comments: comments, read: Date())
        }
        beingRead.remove(key)
        condition.broadcast()
        condition.unlock()
        return comments
    }

    /// Drops what was read of a folder's comments, after a change made here: the next question reads
    /// the file again, and a reading that is under way is not remembered.
    internal func forget(_ directory: URL) {
        let key = directory.locationKey
        condition.lock()
        remembered[key] = nil
        if generations.count > 4_096 { generations = generations.filter { beingRead.contains($0.key) } }
        generations[key, default: 0] += 1
        condition.unlock()
    }

    /// The comment file of a folder; empty when there is none, it cannot be read, or
    /// `cancellation` was set before all of it was read (a read that waits for a server is
    /// ended by the flag).
    internal func load(_ directory: URL, cancellation: CancellationFlag) -> DescriptIon {
        let url = directory.appending(name: DescriptIon.fileName)
        // Something that is called `descript.ion` and is a pipe would never finish being read.
        guard !cancellation.isCancelled, LocalInfo.canBeRead(url),
            let reader = try? fileSystems.provider(for: url).read(url, cancellation: cancellation)
        else { return DescriptIon() }
        defer { reader.close() }
        let token = cancellation.interrupting(reader)
        defer {
            withExtendedLifetime(token) {
                // The reading can be interrupted until it is over.
            }
        }
        var data = Data()
        while let block = autoreleasepool(invoking: { try? reader.read(upToCount: 1 << 20) }) {
            if cancellation.isCancelled {
                return DescriptIon()
            }
            data.append(block)
            if data.count > Self.sizeLimit {
                return DescriptIon()
            }
        }
        return cancellation.isCancelled ? DescriptIon() : DescriptIon(data: data)
    }

    /// The comment file of a folder for a change that rewrites it: absent is an empty one, but a
    /// file that is there and cannot be read whole (no permission, too large, not decodable)
    /// throws, because writing it afterwards would destroy every other comment in it.
    internal func loadForUpdate(_ directory: URL, cancellation: CancellationFlag) throws -> DescriptIon {
        let url = directory.appending(name: DescriptIon.fileName)
        let provider = try fileSystems.provider(for: url)
        guard LocalInfo.canBeRead(url) else { throw CommentFileError.unreadable }
        let reader: any FileReader
        do {
            reader = try provider.read(url, cancellation: cancellation)
        } catch {
            // "Not there" must be known, not guessed from a question that was cut short.
            if provider.item(at: url, cancellation: cancellation) == nil, !cancellation.isCancelled {
                return DescriptIon()
            }
            throw cancellation.isCancelled ? CocoaError(.userCancelled) : CommentFileError.unreadable
        }
        defer { reader.close() }
        let token = cancellation.interrupting(reader)
        defer {
            withExtendedLifetime(token) {
                // The reading can be interrupted until it is over.
            }
        }
        var data = Data()
        do {
            while let block = try reader.read(upToCount: 1 << 20) {
                data.append(block)
                if data.count > Self.sizeLimit { throw CommentFileError.unreadable }
            }
        } catch {
            throw cancellation.isCancelled ? CocoaError(.userCancelled) : CommentFileError.unreadable
        }
        // A reading that the flag ended is not the file: nothing is written from it.
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        guard let file = DescriptIon(strict: data) else { throw CommentFileError.unreadable }
        return file
    }

    /// Changes the comment of one file.
    ///
    /// The new comment file is written beside the old one and then takes its place in one step, so
    /// a failure leaves the old comments as they were. A file without comments is removed. With
    /// `hidden`, the file gets the hidden flag where the file system has one (a new `descript.ion`
    /// is hidden in Total Commander).
    internal func setComment(
        _ comment: String,
        for name: String,
        in directory: URL,
        hidden: Bool,
        cancellation: CancellationFlag
    ) throws {
        let provider = try fileSystems.provider(for: directory)
        let listed = directory.appending(name: DescriptIon.fileName)
        var file = try loadForUpdate(directory, cancellation: cancellation)
        let before = file
        if !DescriptIon.normalized(comment).isEmpty, !DescriptIon.canName(name) { throw CommentFileError.unnameable }
        file.setComment(comment, for: name)
        guard file != before else {
            return
        }
        defer { forget(directory) }
        // A comment file that is a link stays one: the file it points to is the one written.
        let url = LocalInfo.isSymlink(listed) ? listed.resolvingSymlinksInPath() : listed
        if file.isEmpty {
            if provider.item(at: listed, cancellation: cancellation) != nil {
                try provider.remove(listed, cancellation: cancellation)
            }
            return
        }
        let wasHidden = LocalInfo.details(url)?.isHidden ?? false
        let existed = provider.item(at: url, cancellation: cancellation) != nil
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        let draft = url.deletingLastPathComponent()
            .appending(
                name: ".\(DescriptIon.fileName).\(UUID().uuidString.prefix(8)).tmp"
            )
        do {
            let writer = try provider.write(draft, cancellation: cancellation)
            do {
                try writer.write(file.data())
                try writer.close(attributes: FileAttributes())
            } catch {
                try? writer.close(attributes: FileAttributes())
                throw error
            }
            // The new file takes the place of the old one and keeps what that one carried
            // besides its text: flags (hidden among them), tags, access rules.
            if existed { try? provider.copyMetadata(from: url, to: draft, cancellation: cancellation) }
            try provider.move(draft, to: url, replacing: true, cancellation: cancellation)
        } catch {
            // Tidying up, without the flag: it may be what ended the writing.
            try? provider.remove(draft)
            throw error
        }
        if hidden || wasHidden, url.isFileURL { try? LocalInfo.setFlag(UInt32(UF_HIDDEN), true, of: url) }
    }

    deinit {
        // Nothing to release.
    }
}
