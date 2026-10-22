import AFMKernel
import Foundation

/// Compresses the members of a new ZIP on all cores.
///
/// Files are cut into pieces of one megabyte; the pieces of a window (many small files, or parts of
/// a large one) are deflated at the same time and then written in order. Deflate allows that:
/// pieces compressed independently form one valid stream when each but the last ends on a byte
/// boundary. Used by one thread; only the compression itself runs on the others.
internal final class ZipPacker {
    private struct Piece {
        let member: Int
        let data: Data
        let isFirst: Bool
        let isLast: Bool
        let stored: Bool
    }

    private struct Member {
        var record: ZipRecord
        let expectedSize: UInt64
        var opened: ZipWriter.OpenMember?
        var crypto: ZipCrypto?
        var aes: ZipAES.Encryptor?
    }

    internal static let pieceSize = 1 << 20

    internal let writer: ZipWriter
    private let level: Int
    private let password: String?
    private let encryption: ZipEncryption
    private var pieces: [Piece] = []
    private var pendingBytes = 0
    /// The members whose pieces wait in `pieces`, in order; the first is number `firstMember`.
    private var members: [Member] = []
    private var firstMember = 0
    private let windowBytes = ZipPacker.pieceSize * max(2, ProcessInfo.processInfo.activeProcessorCount * 2)

    /// `level` 0 stores without compressing.
    ///
    /// With a password the members are encrypted: with AES-256, or the traditional way when that is
    /// asked for (spec 08 › Encryption; see `ZipEncryption` for what each is worth).
    internal init(
        _ output: OutputFile,
        level: Int,
        password: String? = nil,
        encryption: ZipEncryption = .aes256,
        limits: ZipLimits = .standard
    ) {
        writer = ZipWriter(output, limits: limits)
        self.level = level
        self.password = password?.isEmpty == false ? password : nil
        self.encryption = encryption
    }

    /// Adds a member.
    ///
    /// `next` delivers its contents in blocks of at most `pieceSize`, nil at the end; folders and
    /// empty files deliver nothing. The record carries name, time and attributes; sizes, checksum
    /// and method are filled in here.
    internal func add(_ record: ZipRecord, expectedSize: UInt64, stored: Bool = false, next: () throws -> Data?) throws
    {
        let id = firstMember + members.count
        members.append(Member(record: record, expectedSize: expectedSize))
        let stored = stored || level == 0
        var current = try next()
        var isFirst = true
        repeat {
            // One block is read ahead, to know which piece is the last.
            let following = current == nil ? nil : try next()
            pieces.append(
                Piece(member: id, data: current ?? Data(), isFirst: isFirst, isLast: following == nil, stored: stored)
            )
            pendingBytes += current?.count ?? 0
            if pendingBytes >= windowBytes { try drain() }
            isFirst = false
            current = following
        } while current != nil
    }

    private func drain() throws {
        let level = self.level
        let packed = Parallel.map(pieces, serialBelow: 2) {
            piece -> Result<(data: Data, crc: UInt32, stored: Bool), any Error> in
            Result {
                let crc = CRC32.of(piece.data)
                if piece.stored || piece.data.isEmpty && piece.isFirst {
                    return (piece.data, crc, true)
                }
                let deflated = try Deflater.piece(piece.data, level: level, final: piece.isLast)
                // A small file that does not shrink is stored as it is.
                if piece.isFirst, piece.isLast, deflated.count >= piece.data.count {
                    return (piece.data, crc, true)
                }
                return (deflated, crc, false)
            }
        }
        for (piece, outcome) in zip(pieces, packed) {
            let result = try outcome.get()
            var member = members[piece.member - firstMember]
            if piece.isFirst {
                member.record.method = result.stored ? ZipRecord.methodStored : ZipRecord.methodDeflate
                var header = Data()
                if let password, !member.record.isDirectory, encryption == .aes256 {
                    let aes = try ZipAES.Encryptor(password: password, method: member.record.method)
                    member.record.setAES(aes.field)
                    header = aes.header
                    member.aes = aes
                } else if let password, !member.record.isDirectory {
                    // The checksum is not known yet, so the password check byte comes from the
                    // time and the final values follow the data (general purpose bit 3).
                    member.record.flags |= ZipRecord.flagEncrypted | ZipRecord.flagDescriptor
                    var crypto = ZipCrypto(password: password)
                    header = crypto.header(check: UInt8(member.record.dosTime >> 8))
                    member.crypto = crypto
                }
                member.opened = try writer.begin(
                    member.record,
                    expectedSize: member.expectedSize + UInt64(header.count)
                )
                try writer.append(header)
                member.record.compressedSize = UInt64(header.count)
            }
            let payload = member.aes?.encrypt(result.data) ?? member.crypto?.encrypt(result.data) ?? result.data
            try writer.append(payload)
            member.record.crc = CRC32.combine(member.record.crc, result.crc, secondLength: piece.data.count)
            member.record.uncompressedSize += UInt64(piece.data.count)
            member.record.compressedSize += UInt64(payload.count)
            if piece.isLast, let aes = member.aes {
                // The code that proves the contents ends the member and stands for its checksum.
                let trailer = aes.trailer()
                try writer.append(trailer)
                member.record.compressedSize += UInt64(trailer.count)
                member.record.crc = 0
            }
            if piece.isLast, let opened = member.opened { try writer.end(opened, member.record) }
            members[piece.member - firstMember] = member
        }
        // Every member whose last piece was written is done; one whose pieces go on stays.
        let done = pieces.lazy.filter(\.isLast).count
        members.removeFirst(done)
        firstMember += done
        pieces.removeAll(keepingCapacity: true)
        pendingBytes = 0
    }

    internal func finish(comment: Data = Data()) throws {
        try drain()
        try writer.finish(comment: comment)
    }
}

/// How Pack is to work (spec 08 › Pack › Options).
internal struct PackOptions {
    internal var format = ArchiveFormat.zip
    /// 0 (store) … 9.
    internal var level = 6
    /// Folders keep their paths relative to the source folder; without, everything is stored flat.
    internal var storesPaths = true
    internal var recurses = true
    /// The sources are deleted after a successful pack.
    internal var movesSources = false
    /// One archive per operand.
    internal var separateArchives = false
    /// With separate archives: the archive of a folder holds its contents, not the folder.
    internal var skipsBaseFolder = false
    internal var password: String?
    /// How the members are encrypted when there is a password.
    internal var encryption = ZipEncryption.aes256
    internal var verifies = false
    internal var datesByNewest = false
    internal var limits = ZipLimits.standard
}

internal struct PackResult {
    /// The archives that were written.
    internal var archives: [URL] = []
    internal var failure: any Error?
    internal var cancelled = false
    /// The operands that were packed completely.
    internal var completed: [URL] = []
}

/// Pack (spec 08 › Pack): builds archives from files of any file system.
///
/// **Threading.** `run` blocks and is meant for a job's thread. Reading the sources and
/// writing the archive happen there; compression is spread over all cores (`ZipPacker`,
/// `ParallelCompressor`).
internal final class Packer {
    /// One thing to store: where it comes from and the path it gets in the archive.
    internal struct Member {
        internal let item: FileItem
        internal let path: String
    }

    private let fileSystems: FileSystemRegistry
    private let store: ArchiveStore
    private let monitor: any JobMonitor
    private let options: PackOptions
    private var done = (items: 0, bytes: Int64(0))
    private var total = (items: 0, bytes: Int64(0))
    private var lines: [String] = []
    private var lastReport = Date.distantPast
    /// The rights of an archive that is created (one that is replaced keeps its own).
    private var newMode: mode_t = 0o600
    /// Asked before an existing archive is replaced (ZIP archives are added to instead);
    /// false cancels.
    ///
    /// Called on the job's thread.
    internal var confirmReplace: ((URL) -> Bool)?

    internal init(fileSystems: FileSystemRegistry, store: ArchiveStore, monitor: any JobMonitor, options: PackOptions) {
        self.fileSystems = fileSystems
        self.store = store
        self.monitor = monitor
        self.options = options
    }

    /// Packs `sources` into the archive at `archive` (below `innerFolder` when it is an
    /// existing ZIP), or with `separateArchives` into one archive per source in the folder of
    /// `archive`.
    internal func run(_ sources: [FileItem], archive: URL, innerFolder: String = "") -> PackResult {
        var result = PackResult()
        do {
            var plans: [(archive: URL, sources: [FileItem], members: [Member])] = []
            if options.separateArchives {
                let folder = archive.deletingLastPathComponent()
                for source in sources {
                    let name = Self.archiveName(for: source, format: options.format)
                    plans.append(
                        (
                            folder.appending(name: name), [source],
                            try collect([source], skippingBase: options.skipsBaseFolder)
                        )
                    )
                }
            } else {
                plans.append((archive, sources, try collect(sources, skippingBase: false)))
            }
            // Sizes may come from another archive's directory, which may claim anything.
            total = plans.flatMap(\.members)
                .reduce(into: (0, Int64(0))) {
                    $0 = ($0.0 + 1, $0.1.addingSaturated($1.item.isDirectory ? 0 : max(0, $1.item.size)))
                }
            for plan in plans {
                try checkCancelled()
                let added = try pack(plan.members, into: plan.archive, innerFolder: innerFolder)
                result.archives.append(plan.archive)
                if options.verifies, options.format == .zip { try verify(plan.archive, only: added) }
                if options.movesSources {
                    // The sources are the only other copy: they go when the archive holds the data.
                    try commit(plan.archive)
                    try deleteSources(plan.members, operands: plan.sources)
                }
                result.completed += plan.sources.map(\.url)
            }
        } catch ArchiveError.cancelled {
            result.cancelled = true
        } catch {
            result.failure = error
        }
        return result
    }

    /// The name of the archive made for one operand: a folder or file gives `name.zip`; the
    /// single-file compressors keep the whole name (`a.txt` → `a.txt.gz`), spec 08 › Target string.
    internal static func archiveName(for source: FileItem, format: ArchiveFormat) -> String {
        if case .compressedFile = format {
            return source.name + "." + format.defaultExtension
        }
        return (source.isFolder || source.baseName.isEmpty ? source.name : source.baseName) + "."
            + format.defaultExtension
    }

    private func checkCancelled() throws {
        if monitor.cancellation.isCancelled { throw ArchiveError.cancelled }
    }

    private func report(force: Bool = false) {
        // A report for each of a hundred thousand small files would only slow the job down.
        guard force || Date().timeIntervalSince(lastReport) > 0.05 else {
            return
        }
        lastReport = Date()
        monitor.report(
            JobProgress(
                lines: lines,
                itemsDone: done.items,
                itemsTotal: total.items,
                bytesDone: done.bytes,
                bytesTotal: total.bytes
            )
        )
    }

    // MARK: What to pack

    /// The files and folders to store with their paths (spec 08 › Options, "Path names × recursion").
    private func collect(_ sources: [FileItem], skippingBase: Bool) throws -> [Member] {
        var members: [Member] = []
        func walk(_ item: FileItem, path: String, depth: Int) throws {
            try checkCancelled()
            guard item.isRealDirectory else {
                // A link to a folder on a file system that cannot say where it points is left out.
                if item.isDirectory, !item.url.isFileURL {
                    return
                }
                members.append(Member(item: item, path: options.storesPaths ? path : item.name))
                return
            }
            let isSkippedBase = skippingBase && depth == 0
            if options.storesPaths, !isSkippedBase { members.append(Member(item: item, path: path)) }
            // (Below the top only with recursion: without, the loop below passes over folders.)
            let children = Sorter.sorted(
                try fileSystems.provider(for: item.url).list(item.url, showHidden: true),
                byName: \.name
            )
            for child in children {
                // Without recursion only the files directly inside a selected folder are taken.
                if child.isRealDirectory, !options.recurses { continue }
                try walk(child, path: isSkippedBase ? child.name : path + "/" + child.name, depth: depth + 1)
            }
        }
        for source in sources { try walk(source, path: source.name, depth: 0) }
        // Without paths, files of different folders can meet under one name; an archive
        // would keep one of them, and Move to archive would then delete the other for good.
        var taken = Set<String>()
        for member in members where !taken.insert(member.path).inserted {
            throw ArchiveError.nameCollision(member.path)
        }
        return members
    }

    /// Where a symbolic link on the local disk points; nil for everything else.
    private func linkTarget(of item: FileItem) -> String? {
        guard item.isSymlink, item.url.isFileURL else {
            return nil
        }
        return try? FileManager.default.destinationOfSymbolicLink(atPath: item.url.path)
    }

    /// Reads a source file in blocks of exactly `size` (the last one shorter), counting progress.
    private func blocks(of item: FileItem, size: Int) throws -> (next: () throws -> Data?, close: () -> Void) {
        let reader = try fileSystems.provider(for: item.url).read(item.url, cancellation: monitor.cancellation)
        // A read that waits on a server ends when the job is cancelled.
        let tie = monitor.cancellation.interrupting(reader)
        var ended = false
        return (
            { [self] in
                guard !ended else {
                    return nil
                }
                try checkCancelled()
                var block = Data()
                while block.count < size {
                    guard let more = try reader.read(upToCount: size - block.count) else {
                        ended = true
                        break
                    }
                    block.append(more)
                }
                done.bytes += Int64(block.count)
                report()
                return block.isEmpty ? nil : block
            },
            {
                reader.close()
                withExtendedLifetime(tie) {}
            }
        )
    }

    // MARK: Writing

    /// Returns the paths of the members that were added when the archive existed before
    /// (they are what a test afterwards has to read); nil for a new archive.
    private func pack(_ members: [Member], into archive: URL, innerFolder: String) throws -> Set<String>? {
        let archive = ArchiveURL.resolved(archive)
        let cancellation = monitor.cancellation
        var added: Set<String>?
        let existing = (try? fileSystems.provider(for: archive))?.item(at: archive, cancellation: cancellation)
        try checkCancelled()
        if options.format != .zip, existing != nil {
            if confirmReplace?(archive) == false { throw ArchiveError.cancelled }
            // What still waits to be written into the archive that is replaced is written
            // first, so that it is not written into the new one afterwards.
            try store.flush(archive, cancellation: cancellation)
        }
        newMode = Self.mode(for: members)
        switch options.format {
        case .zip:
            let exists = existing != nil
            if exists { added = Set(members.map { ArchiveTree.join(innerFolder, $0.path) }) }
            if exists, !archive.isFileURL {
                try addThroughStore(members, to: archive, innerFolder: innerFolder)
            } else if exists {
                // The archive file is rewritten here, not by the open archive; so that the
                // two never write at once, this holds the archive's own gate, after what
                // waited there has been written, and looks once more before the new file
                // takes the old one's place.
                let open = try store.archive(at: archive, cancellation: cancellation)
                // Where the file really lies: a link to it stays a link.
                let real = Durable.realFile(archive)
                try open.whileHoldingFile(cancellation: cancellation) { stillUnchanged in
                    if try !appendToZip(members, at: real, innerFolder: innerFolder, check: stillUnchanged) {
                        try build(real, check: stillUnchanged) { output in
                            try writeZip(members, to: output, existing: real, innerFolder: innerFolder)
                        }
                    }
                }
            } else {
                try build(archive) { output in
                    try writeZip(members, to: output, existing: nil, innerFolder: innerFolder)
                }
            }

        case .tar:
            try build(archive) { output in try writeTar(members, to: output, method: .none) }

        case .compressedTar(let codec):
            try build(archive) { output in try writeTar(members, to: output, method: method(for: codec)) }

        case .compressedFile(let codec):
            let files = members.filter { !$0.item.isDirectory }
            guard files.count == 1, let file = files.first else {
                let advice = "choose \"Create a TAR archive first\""
                throw ArchiveError.unsupported(
                    "Packing several files or a folder into one \(options.format.title) file (\(advice))"
                )
            }
            try build(archive) { output in
                lines = [
                    "Packing: \(fileSystems.displayPath(file.item.url))", "To: \(fileSystems.displayPath(archive))"
                ]
                let compressor = try ParallelCompressor(method(for: codec), to: output, modified: file.item.modified)
                let source = try blocks(of: file.item, size: 1 << 20)
                defer { source.close() }
                while let block = try source.next() { try compressor.write(block) }
                try compressor.finish()
                done.items += 1
            }

        case .foreign:
            throw ArchiveError.unsupported("Creating archives of this type")
        }
        if options.datesByNewest, archive.isFileURL,
            let newest = members.filter({ !$0.item.isDirectory }).map(\.item.modified).max()
        {
            try? FileManager.default.setAttributes([.modificationDate: newest], ofItemAtPath: archive.path)
        }
        report(force: true)
        return added
    }

    private func method(for codec: ArchiveFormat.Codec) -> ParallelCompressor.Method {
        switch codec {
        // Deflate has no "store"; the fastest level is the least it can do.
        case .gzip:
            return .gzip(level: max(1, options.level))

        case .bzip2:
            return .bzip2(level: max(1, options.level))

        case .xz:
            return .xz
        }
    }

    /// The rights a new archive gets: the user's own, and those of group and others only as
    /// far as every file packed into it grants them.
    ///
    /// An archive of private files is not readable by everyone on the machine.
    internal static func mode(for members: [Member]) -> mode_t {
        let shared = members.filter { !$0.item.isDirectory }.reduce(UInt16(0o044)) { $0 & $1.item.permissions }
        return mode_t(0o600 | shared) & ~processMask
    }

    private static let processMask: mode_t = {
        let mask = umask(0)
        umask(mask)
        return mask
    }()

    /// Writes the archive under a temporary name and puts it in place when it is complete, so
    /// that a failed or cancelled pack leaves no half archive and never damages an existing one.
    ///
    /// The new file is on the disk before it takes the place (see `Durable`), and it is the user's
    /// alone while it is written. An archive that is replaced keeps its rights, and one that was
    /// reached through a symbolic link is replaced where it really lies. `check` is called right
    /// before the new file takes the place and may throw to prevent that.
    private func build(_ archive: URL, check: () throws -> Void = {}, _ write: (OutputFile) throws -> Void) throws {
        if archive.isFileURL {
            let archive = FileManager.default.fileExists(atPath: archive.path) ? Durable.realFile(archive) : archive
            let folder = archive.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let temporary = folder.appendingPathComponent(".\(UUID().uuidString).afm-pack.tmp", isDirectory: false)
            store.environment.scratch.noteExternal(temporary)
            var status = stat()
            let mode = stat(archive.path, &status) == 0 ? status.st_mode & 0o7777 : newMode
            let output = try OutputFile(creating: temporary)
            do {
                try write(output)
                output.setMode(mode)
                try output.close(durably: true)
                try check()
                guard rename(temporary.path, archive.path) == 0 else { throw posixError(errno, archive.path) }
                Durable.syncFolder(of: archive)
            } catch {
                try? output.close()
                unlink(temporary.path)
                throw error
            }
            return
        }
        // Another file system: built on the disk, then sent there.
        let local = try store.environment.scratch.newFile("pack")
        let keeper = TemporaryFile(local)
        let output = try OutputFile(creating: local)
        try write(output)
        try output.close()
        let provider = try fileSystems.provider(for: archive)
        try provider.createDirectory(at: archive.deletingLastPathComponent(), cancellation: monitor.cancellation)
        let temporary = archive.deletingLastPathComponent().appending(name: ".afm-\(UUID().uuidString).tmp")
        let writer = try provider.write(temporary, cancellation: monitor.cancellation)
        // A write that waits on the server ends when the job is cancelled.
        let tie = monitor.cancellation.interrupting(writer)
        defer { withExtendedLifetime(tie) {} }
        do {
            let source = FileRangeStream(try RandomAccessFile(keeper.url))
            while let block = try source.read(upToCount: 1 << 20) {
                try checkCancelled()
                try writer.write(block)
            }
            try writer.close(attributes: FileAttributes())
            try provider.move(temporary, to: archive, replacing: true, cancellation: monitor.cancellation)
        } catch {
            try? writer.close(attributes: FileAttributes())
            try? provider.remove(temporary)
            throw error
        }
    }

    private func record(for member: Member, path: String) -> ZipRecord {
        ZipRecord.new(
            name: path,
            isDirectory: member.item.isRealDirectory,
            modified: member.item.modified,
            permissions: member.item.permissions,
            isSymbolicLink: linkTarget(of: member.item) != nil
        )
    }

    /// Adds members to an existing ZIP on the local disk without copying what it holds: the
    /// archive is cloned (which costs neither time nor space), the clone's directory is cut
    /// off, the new members and a directory that lists old and new are written behind the old
    /// members, and the clone takes the archive's place in one step.
    ///
    /// False, with nothing done, when that is not possible: a member is to be replaced, the file
    /// system does not clone, or the archive is not laid out plainly. A failed or cancelled pack
    /// leaves the archive as it was, as `build` does.
    private func appendToZip(_ members: [Member], at archive: URL, innerFolder: String, check: () throws -> Void) throws
        -> Bool
    {
        let file = try RandomAccessFile(archive)
        let contents = try ZipDirectory.read(file)
        try Self.refuseOtherKinds(members, in: contents.records, innerFolder: innerFolder)
        let added = Set(members.map { ArchiveTree.join(innerFolder, $0.path) })
        var offsets: [UInt64] = []
        for record in contents.records {
            guard case .archive(let offset, _) = record.source, offset < contents.directoryOffset,
                !(ArchiveTree.normalized(record.name).map(added.contains) ?? false)
            else { return false }
            offsets.append(offset)
        }
        let temporary = archive.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(UUID().uuidString).afm-pack.tmp",
                isDirectory: false
            )
        store.environment.scratch.noteExternal(temporary)
        guard store.environment.clonesArchives, clonefile(archive.path, temporary.path, 0) == 0 else {
            return false
        }
        do {
            let output = try OutputFile(extending: temporary, from: contents.directoryOffset)
            do {
                let packer = ZipPacker(
                    output,
                    level: options.level,
                    password: options.password,
                    encryption: options.encryption,
                    limits: options.limits
                )
                for (record, offset) in zip(contents.records, offsets) { packer.writer.adopt(record, at: offset) }
                try add(members, to: packer, innerFolder: innerFolder, shownIn: archive.deletingLastPathComponent())
                try packer.finish(comment: contents.comment)
                try output.close(durably: true)
                try check()
                guard rename(temporary.path, archive.path) == 0 else { throw posixError(errno, archive.path) }
                Durable.syncFolder(of: archive)
            } catch {
                try? output.close()
                throw error
            }
        } catch {
            unlink(temporary.path)
            throw error
        }
        return true
    }

    /// As in an archive on a server (`OpenArchive`): a member packed again takes the place of
    /// one of its own kind only, a file that of a file and a folder that of a folder.
    ///
    /// A file under the name of a folder of the archive (one listed or one its members lie in), or
    /// a folder under the name of a file, leaves the archive as it is and fails.
    private static func refuseOtherKinds(_ members: [Member], in records: [ZipRecord], innerFolder: String) throws {
        // What each name is: what its record says, and a folder where other members lie in it.
        var folders: [String: Bool] = [:]
        for (name, isFolder) in records.compactMap({ record in
            ArchiveTree.normalized(record.name).map { ($0, record.isDirectory) }
        }) {
            folders[name] = isFolder
        }
        for name in Array(folders.keys) {
            var parent = ArchiveTree.parent(of: name)
            while !parent.isEmpty {
                folders[parent] = true
                parent = ArchiveTree.parent(of: parent)
            }
        }
        for member in members {
            let path = ArchiveTree.join(innerFolder, member.path)
            guard let isFolder = folders[path], isFolder != member.item.isRealDirectory else { continue }
            throw isFolder ? FileSystemError.alreadyExists(path) : ArchiveError.notADirectory(path)
        }
    }

    /// A new ZIP, or an existing one with the members added: what the old archive holds is
    /// copied over as it is, except the members that are packed again.
    private func writeZip(_ members: [Member], to output: OutputFile, existing: URL?, innerFolder: String) throws {
        let packer = ZipPacker(
            output,
            level: options.level,
            password: options.password,
            encryption: options.encryption,
            limits: options.limits
        )
        var comment = Data()
        if let existing {
            let file = try RandomAccessFile(existing)
            let contents = try ZipDirectory.read(file)
            comment = contents.comment
            let replaced = Set(members.map { ArchiveTree.join(innerFolder, $0.path) })
            // What stands in front of the first member (a self-extracting program) stays.
            let first = contents.records.compactMap(\.headerOffset).reduce(contents.directoryOffset, min)
            let prefix = FileRangeStream(file, offset: 0, length: first)
            while let block = try prefix.read(upToCount: 1 << 20) { try packer.writer.append(block) }
            for record in contents.records where !(ArchiveTree.normalized(record.name).map(replaced.contains) ?? false)
            {
                try checkCancelled()
                try packer.writer.copyMember(record)
            }
            // The archive stays the archive it was: its labels (the quarantine among them) go along.
            copyfile(existing.path, output.url.path, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL))
            Quarantine.apply(Quarantine.read(existing.path), to: output.url)
        }
        try add(members, to: packer, innerFolder: innerFolder, shownIn: output.url.deletingLastPathComponent())
        try packer.finish(comment: comment)
    }

    private func add(_ members: [Member], to packer: ZipPacker, innerFolder: String, shownIn place: URL) throws {
        let paths = members.map { ArchiveTree.join(innerFolder, $0.path) }
        for (member, path) in zip(members, paths) {
            lines = [
                "Packing: \(fileSystems.displayPath(member.item.url))", "To: \(fileSystems.displayPath(place))/\(path)"
            ]
            let record = record(for: member, path: path)
            if member.item.isRealDirectory {
                try packer.add(record, expectedSize: 0, stored: true) { nil }
            } else if let target = linkTarget(of: member.item) {
                var sent = false
                try packer.add(record, expectedSize: UInt64(target.utf8.count), stored: true) {
                    defer { sent = true }
                    return sent ? nil : Data(target.utf8)
                }
            } else {
                let source = try blocks(of: member.item, size: ZipPacker.pieceSize)
                defer { source.close() }
                try packer.add(record, expectedSize: UInt64(max(0, member.item.size)), next: source.next)
            }
            done.items += 1
            report()
        }
    }

    /// Makes a change in `open`, which the store may have let go before the first change
    /// (see `OpenArchive`): then the archive is asked for again, up to eight times, after
    /// which its refusal stands.
    private func changing<T>(
        _ open: inout OpenArchive,
        at archive: URL,
        attempt: Int = 0,
        _ change: (OpenArchive) throws -> T
    ) throws -> T {
        do {
            return try change(open)
        } catch ArchiveError.retired where attempt < 8 {
            open = try store.archive(at: archive, cancellation: monitor.cancellation)
            return try changing(&open, at: archive, attempt: attempt + 1, change)
        }
    }

    /// Adds to a ZIP that is not on the local disk, through the open archive's own means.
    ///
    /// Each file is written under a temporary name and takes its real name when it is
    /// complete: a member that is packed again stays as it was until then, so a read error or
    /// Cancel leaves the archive holding what it held. With a password the members are
    /// encrypted (AES-256) as on the local disk. The writer is closed on every path.
    private func addThroughStore(_ members: [Member], to archive: URL, innerFolder: String) throws {
        let cancellation = monitor.cancellation
        var open = try store.archive(at: archive, cancellation: cancellation)
        for member in members {
            try checkCancelled()
            let path = ArchiveTree.join(innerFolder, member.path)
            lines = [
                "Packing: \(fileSystems.displayPath(member.item.url))",
                "To: \(fileSystems.displayPath(archive))/\(path)"
            ]
            if member.item.isRealDirectory {
                try changing(&open, at: archive) { try $0.makeDirectory(path) }
            } else {
                let temporary = ArchiveTree.join(ArchiveTree.parent(of: path), ".afm-\(UUID().uuidString).tmp")
                let writer = try changing(&open, at: archive) {
                    try $0.write(temporary, level: options.level, password: options.password)
                }
                do {
                    let tie = cancellation.interrupting(writer)
                    defer { withExtendedLifetime(tie) {} }
                    let source = try blocks(of: member.item, size: 1 << 20)
                    defer { source.close() }
                    while let block = try source.next() { try writer.write(block) }
                    try writer.close(
                        attributes: FileAttributes(
                            modified: member.item.modified,
                            permissions: member.item.permissions
                        )
                    )
                } catch {
                    // Ended, not finished: nothing of it joins the archive.
                    writer.interrupt()
                    try? writer.close(attributes: FileAttributes())
                    try? open.remove(temporary)
                    throw error
                }
                do {
                    try open.move(temporary, to: path, replacing: true)
                } catch {
                    try? open.remove(temporary)
                    throw error
                }
            }
            done.items += 1
            report()
        }
        try open.flush(cancellation: cancellation)
    }

    private func writeTar(_ members: [Member], to output: OutputFile, method: ParallelCompressor.Method) throws {
        let compressor = try ParallelCompressor(method, to: output)
        for member in members {
            lines = ["Packing: \(fileSystems.displayPath(member.item.url))", "To: \(member.path)"]
            var header = TarHeader(
                path: member.path,
                modified: member.item.modified,
                permissions: member.item.permissions
            )
            if member.item.isRealDirectory {
                header.kind = .directory
                try compressor.write(header.encoded())
            } else if let target = linkTarget(of: member.item) {
                header.kind = .symbolicLink
                header.linkTarget = target
                try compressor.write(header.encoded())
            } else {
                // The header states the size before the data follows, so exactly that much is
                // written even when the file changes while it is read.
                let size = UInt64(max(0, member.item.size))
                header.size = size
                try compressor.write(header.encoded())
                let source = try blocks(of: member.item, size: 1 << 20)
                defer { source.close() }
                var written: UInt64 = 0
                while written < size, let block = try source.next() {
                    let part = block.prefix(Int(min(UInt64(block.count), size - written)))
                    try compressor.write(Data(part))
                    written += UInt64(part.count)
                }
                // A file that shrank while it was read is filled up with zeros, a piece at a time.
                while written < size {
                    let part = Int(min(size - written, 1 << 20))
                    try compressor.write(Data(count: part))
                    written += UInt64(part)
                }
                try compressor.write(TarHeader.padding(after: size))
            }
            done.items += 1
            report()
        }
        try compressor.write(TarHeader.endOfArchive)
        try compressor.finish()
    }

    // MARK: Afterwards

    /// Tests the new archive at once (spec 08 › After packing).
    ///
    /// A failure is reported and the archive stays; the sources are then not deleted. Of an archive
    /// that was added to, `only` names the new members: what it held before was not written again
    /// and is not read again.
    private func verify(_ archive: URL, only: Set<String>?) throws {
        lines = ["Testing: \(fileSystems.displayPath(archive))"]
        report(force: true)
        let open = try store.archive(at: ArchiveURL.resolved(archive), cancellation: monitor.cancellation)
        if let password = options.password { open.usePassword(password) }
        let problems = ArchiveTester.test(open, cancellation: monitor.cancellation, only: only)
        try checkCancelled()
        if let first = problems.first { throw ArchiveError.damaged("the new archive failed its test (\(first))") }
    }

    /// Makes the new archive durable where it lies, when its file system keeps writes back
    /// (an archive in a ZIP, on a server): a failure ends the pack with the sources in place.
    private func commit(_ archive: URL) throws {
        let archive = ArchiveURL.resolved(archive)
        let provider = try fileSystems.provider(for: archive)
        guard provider.capabilities(for: archive).contains(.deferredWrites) else {
            return
        }
        try provider.commit(archive, cancellation: monitor.cancellation)
        try checkCancelled()
    }

    /// Move to archive: exactly the files that were packed are deleted, then the folders that
    /// are empty afterwards.
    private func deleteSources(_ members: [Member], operands: [FileItem]) throws {
        var folders: [URL] = operands.filter(\.isRealDirectory).map(\.url)
        for member in members {
            try checkCancelled()
            if member.item.isRealDirectory {
                folders.append(member.item.url)
            } else {
                try fileSystems.provider(for: member.item.url)
                    .remove(
                        member.item.url,
                        cancellation: monitor.cancellation
                    )
            }
        }
        // Deepest first; a folder that still holds something (not packed) stays.
        for folder in folders.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            try? fileSystems.provider(for: folder).remove(folder)
        }
    }
}
