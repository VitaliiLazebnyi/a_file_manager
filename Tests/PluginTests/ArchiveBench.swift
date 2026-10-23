import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The archive file systems on top of the local disk and a memory file system, without a kernel.
///
/// Unchecked: its parts are file systems and stores, which are safe from any thread; the
/// environment is set up before use.
internal final class ArchiveBench: @unchecked Sendable {
    /// The answers to password questions, and how often one was asked.
    ///
    /// Unchecked: the state is guarded by `lock`.
    internal final class Passwords: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String?] = []
        private var count = 0

        /// How many times a password was asked for so far.
        internal var asked: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        /// Sets the answers to give, in order; nil stands for Cancel.
        internal func set(_ answers: [String?]) {
            lock.lock()
            self.answers = answers
            lock.unlock()
        }

        /// Counts a question and returns the next answer, or nil (Cancel) when none is left.
        internal func next() -> String? {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return answers.isEmpty ? nil : answers.removeFirst()
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The test's own folder on the local disk.
    internal let box: Sandbox
    /// The settings and hooks the archive code runs with; changed by tests before use.
    internal let environment = ArchiveEnvironment()
    /// The open archives of both file systems.
    internal let store: ArchiveStore
    /// The local disk, the memory file system and both archive file systems.
    internal let fileSystems = FileSystemRegistry()
    /// A file system in memory, for archives that lie elsewhere than on the local disk.
    internal let memory = MemoryFileSystem()
    /// The file system of the archives that can be changed (ZIP).
    internal let zip: ArchiveFileSystem
    /// The file system of the archives that can only be read.
    internal let readOnly: ArchiveFileSystem
    /// The monitor of every pack and unpack the bench runs.
    internal let monitor = QuietMonitor()
    /// The answers to the password questions of the archive code.
    internal let passwords = Passwords()

    /// A fresh sandbox, store and set of file systems; writes are not delayed.
    internal init() throws {
        box = try Sandbox()
        environment.flushDelay = nil
        store = ArchiveStore(environment: environment)
        zip = ArchiveFileSystem(scheme: ArchiveURL.writableScheme, store: store)
        readOnly = ArchiveFileSystem(scheme: ArchiveURL.readOnlyScheme, store: store)
        [LocalFileSystem(), memory, zip, readOnly].forEach(fileSystems.register)
        environment.fileSystems = { [weak fileSystems] in fileSystems }
        environment.askPassword = { [passwords] _, _ in passwords.next() }
    }

    /// The small tree of `makeTree(_:)`, in the folder "tree".
    @discardableResult
    internal func makeTree() throws -> URL {
        try makeTree("tree")
    }

    /// A small tree with text, binary data, an empty file, an empty folder and odd names, in the folder `name`.
    @discardableResult
    internal func makeTree(_ name: String) throws -> URL {
        try box.file(
            "\(name)/readme.txt",
            String(repeating: "All work and no play makes Jack a dull boy.\n", count: 400)
        )
        try box.file("\(name)/empty.txt", "")
        try box.file("\(name)/sub/deep/übung – ñ 日本.txt", "unicode name")
        try box.file("\(name)/sub/.hidden", "hidden")
        try box.folder("\(name)/hollow")
        var random = Data(count: 300_000)
        random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try random.write(to: box.url("\(name)/sub/random.bin"))
        // Larger than one piece of the parallel compressor, and compressible.
        var big = Data()
        for index in 0..<120_000 { big.append(Data("line \(index) of a file that spans several pieces\n".utf8)) }
        try big.write(to: box.url("\(name)/big.log"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: box.url("\(name)/readme.txt").path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
            ofItemAtPath: box.url("\(name)/readme.txt").path
        )
        return box.url(name)
    }

    /// The item at `url`, from whichever file system serves it; fails the test when there is none.
    internal func item(_ url: URL) throws -> FileItem {
        try #require(fileSystems.item(at: url))
    }

    /// Packs `sources` into `archive` with the default options; throws what the packer reports.
    @discardableResult
    internal func pack(_ sources: [URL], to archive: URL) throws -> PackResult {
        try pack(sources, to: archive, innerFolder: "", options: packOptions())
    }

    /// Packs `sources` into the folder `innerFolder` of `archive` with the default options.
    @discardableResult
    internal func pack(_ sources: [URL], to archive: URL, innerFolder: String) throws -> PackResult {
        try pack(sources, to: archive, innerFolder: innerFolder, options: packOptions())
    }

    /// Packs `sources` into `archive` with the options as `configure` sets them.
    @discardableResult
    internal func pack(_ sources: [URL], to archive: URL, _ configure: (inout PackOptions) -> Void) throws
        -> PackResult
    {
        var options = packOptions()
        configure(&options)
        return try pack(sources, to: archive, innerFolder: "", options: options)
    }

    /// Packs `sources` into the folder `innerFolder` of `archive` with the options as `configure` sets them.
    @discardableResult
    internal func pack(
        _ sources: [URL],
        to archive: URL,
        innerFolder: String,
        _ configure: (inout PackOptions) -> Void
    ) throws -> PackResult {
        var options = packOptions()
        configure(&options)
        return try pack(sources, to: archive, innerFolder: innerFolder, options: options)
    }

    /// Unpacks all of `archive` into `target`, overwriting what is there.
    @discardableResult
    internal func unpack(_ archive: URL, to target: URL) throws -> UnpackResult {
        try unpack(archive, to: target, options: UnpackOptions())
    }

    /// Unpacks `archive` into `target` with `options`, overwriting what is there.
    private func unpack(_ archive: URL, to target: URL, options: UnpackOptions) throws -> UnpackResult {
        let unpacker = Unpacker(
            fileSystems: fileSystems,
            monitor: monitor,
            options: options,
            whileUnpacking: nil
        ) { _, _ in .overwrite }
        return unpacker.run([Unpacker.Source(archive: try store.archive(at: archive, cancellation: nil))], into: target)
    }

    /// The root of `archive` in the file system of the archives that can be changed.
    internal func inside(_ archive: URL) -> URL {
        inside(archive, "", scheme: ArchiveURL.writableScheme)
    }

    /// The location of `path` inside `archive`, in the file system of the archives that can be changed.
    internal func inside(_ archive: URL, _ path: String) -> URL {
        inside(archive, path, scheme: ArchiveURL.writableScheme)
    }

    /// The root of `archive` in the archive file system of `scheme`.
    internal func inside(_ archive: URL, scheme: String) -> URL {
        inside(archive, "", scheme: scheme)
    }

    /// The location of `path` inside `archive`, in the archive file system of `scheme`.
    internal func inside(_ archive: URL, _ path: String, scheme: String) -> URL {
        ArchiveURL.make(scheme: scheme, archive: archive, innerPath: path)
    }

    /// The whole contents of the file at `url`, read in blocks through its file system.
    internal func read(_ url: URL) throws -> Data {
        let reader = try fileSystems.provider(for: url).read(url)
        defer { reader.close() }
        var data = Data()
        while let block = try reader.read(upToCount: 70_000) { data.append(block) }
        return data
    }

    /// The sorted names in the folder at `url`, hidden ones included.
    internal func names(_ url: URL) throws -> [String] {
        try names(url, showHidden: true)
    }

    /// The sorted names in the folder at `url`; hidden ones only when `showHidden` is set.
    internal func names(_ url: URL, showHidden: Bool) throws -> [String] {
        try fileSystems.provider(for: url).list(url, showHidden: showHidden).map(\.name).sorted()
    }

    /// The default pack options, with the ZIP limits of the environment.
    private func packOptions() -> PackOptions {
        var options = PackOptions()
        options.limits = environment.limits
        return options
    }

    /// Packs `sources` into the folder `innerFolder` of `archive`; throws what the packer reports.
    private func pack(_ sources: [URL], to archive: URL, innerFolder: String, options: PackOptions) throws
        -> PackResult
    {
        let packer = Packer(fileSystems: fileSystems, store: store, monitor: monitor, options: options)
        let result = packer.run(try sources.map(item), archive: archive, innerFolder: innerFolder)
        if let failure = result.failure { throw failure }
        return result
    }

    deinit { store.close() }
}
