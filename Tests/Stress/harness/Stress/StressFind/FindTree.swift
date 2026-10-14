internal import Dispatch
internal import Foundation
internal import StressKit

/// The nested tree the searches run over: 2,000 folders of 50 small files and two large files of
/// 256 MB (fewer folders and smaller large files for a short smoke run).
internal enum FindTree {
    /// The text some of the files hold.
    internal static let needle = "NEEDLE_XYZ"

    /// The folders of the full tree.
    internal static let fullFolders = 2_000
    /// The size of each large file of the full tree, in MB.
    internal static let fullBigMegabytes = 256

    /// Builds the tree below `root`: `folders` folders (at most 10,000) of 50 files, and two large
    /// files of `bigMegabytes` MB each.
    internal static func generate(_ root: URL, folders: Int, bigMegabytes: Int) {
        let line = "The quick brown fox jumps over the lazy dog; pack my box with five dozen liquor jugs.\n"
        let body = String(repeating: line, count: 4)
        DispatchQueue.concurrentPerform(iterations: folders) { folder in
            writeFolder(folder, below: root, body: body)
        }
        // Two large files, so a text search is in the middle of a long read when it is cancelled.
        let big = root.appendingPathComponent("big")
        must("create \(big.path)") {
            try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        }
        var random = Random(seed: 7)
        var block = Data(count: 1 << 20)
        block.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            for index in words.indices {
                words[index] = random.next()
            }
        }
        for index in 0..<2 {
            let url = big.appendingPathComponent("big\(index).bin")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            must("write \(url.path)") {
                let handle = try FileHandle(forWritingTo: url)
                for _ in 0..<bigMegabytes {
                    handle.write(block)
                }
                if index == 1 {
                    handle.write(Data("tail \(needle) tail".utf8))
                }
                try handle.close()
            }
        }
    }

    /// Writes folder number `folder` (`dAA/eB/fC`) and its 50 files: 40 text, 10 binary.
    private static func writeFolder(_ folder: Int, below root: URL, body: String) {
        let top = folder / 100
        let middle = (folder / 10) % 10
        let leaf = folder % 10
        let directory = root.appendingPathComponent(String(format: "d%02d/e%d/f%d", top, middle, leaf))
        must("create \(directory.path)") {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for file in 0..<50 {
            let global = folder * 50 + file
            let isText = file < 40
            let name = String(format: isText ? "n%02d-%06d.txt" : "b%02d-%06d.dat", file, global)
            var text = "file \(global)\n" + body
            if global.isMultiple(of: 97) {
                text += "here is the \(needle) of file \(global)\n"
            }
            if global.isMultiple(of: 1_013) {
                text += "lowercase needle_xyz too\n"
            }
            must("write \(name)") { try Data(text.utf8).write(to: directory.appendingPathComponent(name)) }
        }
    }

    /// Runs `body`; a failure ends the process, naming `what` could not be done.
    private static func must(_ what: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            preconditionFailure("cannot \(what): \(error)")
        }
    }
}
