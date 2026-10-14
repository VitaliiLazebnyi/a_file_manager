import AFMKernel
import Foundation
import FuzzCore

@testable import ArchivesPlugin

/// The full round: the archive is opened the way a panel opens it, listed completely, every
/// member is read to its end, and the whole archive is unpacked with the Unpacker into a folder
/// next to a canary folder.
@MainActor
internal func runArchive(_ bytes: [UInt8], name: String) {
    if isForeign(bytes, name: name) {
        return
    }
    let (root, archive) = prepare(bytes, name: name)
    for pass in 0..<2 {
        // Second pass: as for an archive too large to keep an unpacked copy of (every read
        // goes through the stream, sizes come from the trailers).
        ArchiveRig.environment.materializeLimit = pass == 0 ? 256 << 20 : 0
        if pass == 1, name.hasSuffix(".zip") || name.hasSuffix(".tar") {
            break
        }
        let opened = Opened.open(archive)
        let seen = opened.browse(readLimit: 48 << 20)
        if pass == 0, seen.listed, let handle = try? opened.store.archive(at: archive) {
            unpackTwice(handle, with: opened.fileSystems, root: root, name: name)
            _ = ArchiveTester.test(handle, cancellation: CancellationFlag())
        }
        opened.store.close()
        checkContainment(root, archiveName: name, what: "browse")
    }
    probeSizes(archive, head: bytes)
}

/// Browsing only: the archive is listed and every member read, nothing is unpacked.
///
/// Much faster than the full round, so the parsers see many more inputs.
@MainActor
internal func runList(_ bytes: [UInt8], name: String) {
    if isForeign(bytes, name: name) {
        return
    }
    let dir = fzWorkDir + "/l"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let archive = URL(fileURLWithPath: dir + "/" + name)
    FileManager.default.createFile(atPath: archive.path, contents: Data(bytes))
    let plain = name.hasSuffix(".zip") || name.hasSuffix(".tar")
    for pass in 0..<(plain ? 1 : 2) {
        ArchiveRig.environment.materializeLimit = pass == 0 ? 256 << 20 : 0
        let opened = Opened.open(archive)
        _ = opened.browse(readLimit: 8 << 20)
        opened.store.close()
    }
    if !plain {
        probeSizes(archive, head: bytes)
    }
}

/// Unpacks the archive keeping its paths, then flat over links that stand in the target already.
private func unpackTwice(_ archive: OpenArchive, with fileSystems: FileSystemRegistry, root: String, name: String) {
    let target = root + "/out/target"
    for keepsPaths in [true, false] {
        if !keepsPaths {
            plantLinks(in: target)
        }
        var options = UnpackOptions()
        options.keepsPaths = keepsPaths
        options.overwrites = true
        let unpacker = Unpacker(fileSystems: fileSystems, monitor: QuietMonitor(), options: options) { _, _ in
            .overwrite
        }
        _ = unpacker.run([Unpacker.Source(archive: archive)], into: URL(fileURLWithPath: target))
        checkContainment(root, archiveName: name, what: "unpack keepsPaths=\(keepsPaths)")
        checkTree(target)
    }
}

/// Links that stand in the target already (the user's own, or what the first round unpacked):
/// nothing may be written through them.
private func plantLinks(in target: String) {
    try? FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
    let links = [
        ("ln", "../canary"), ("up", ".."), ("keep.txt", "../canary/keep.txt"), ("hl", "../canary/keep.txt")
    ]
    for (link, destination) in links {
        var info = stat()
        if lstat(target + "/" + link, &info) != 0 {
            try? FileManager.default.createSymbolicLink(atPath: target + "/" + link, withDestinationPath: destination)
        }
    }
}

/// The size probes that read the file directly: the XZ index, the gzip trailer and header.
private func probeSizes(_ archive: URL, head bytes: [UInt8]) {
    guard let file = try? RandomAccessFile(archive) else {
        return
    }
    _ = CompressedSize.ofXZ(file)
    _ = CompressedSize.claimedByGzip(file)
    _ = GzipHeader(Data(bytes.prefix(1_024)))
}
