import Foundation
import StressKit

/// The text files the viewer is tried on, written by the harness.
internal enum ViewerFiles {
    /// A line that exists only at the very end of the files that have one.
    internal static let marker = "ENDMARKER_QZX"

    /// `size` bytes of lines of 60 to 99 bytes of words, and how many lines they are.
    internal static func denseBlock(_ size: Int, seed: UInt64) -> (data: Data, lines: Int) {
        var random = Random(seed: seed)
        let words = [
            "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed", "do", "eiusmod",
            "tempor"
        ]
        var bytes: [UInt8] = []
        bytes.reserveCapacity(size)
        var lines = 0
        while bytes.count < size {
            let left = size - bytes.count
            var length = 60 + Int(random.next() % 40)
            if left < 200 {
                length = left - 1
            }
            var line: [UInt8] = []
            while line.count < length {
                line.append(contentsOf: Array(words[Int(random.next() % UInt64(words.count))].utf8))
                line.append(0x20)
            }
            bytes.append(contentsOf: line.prefix(length))
            bytes.append(0x0A)
            lines += 1
        }
        return (Data(bytes), lines)
    }

    /// Writes a dense text file of `megabytes` MiB that ends with the marker line; returns its lines.
    @discardableResult
    internal static func writeDense(_ url: URL, megabytes: Int) -> Int {
        let (block, lines) = denseBlock(1 << 20, seed: 11)
        let handle = writer(url)
        for _ in 0..<megabytes - 1 {
            handle.write(block)
        }
        // The last block ends with a line that exists nowhere else.
        var last = block
        let tail = Array((marker + "\n").utf8)
        last.replaceSubrange(last.count - tail.count..<last.count, with: tail)
        // The byte before the marker was part of the last line: still one line, a little shorter.
        handle.write(last)
        finish(handle, url)
        return lines * megabytes
    }

    /// Writes the four big files into `directory`: dense4g.txt, sparse4g.txt, line2g.txt, newlines1g.txt.
    internal static func generate(_ directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            preconditionFailure("cannot make \(directory.path): \(error)")
        }
        writeDense4g(directory)
        writeSparse(directory)
        writeOneLine(directory)
        writeNewlines(directory)
    }

    /// 4 GiB of dense text.
    private static func writeDense4g(_ directory: URL) {
        let started = now()
        let lines = writeDense(directory.appendingPathComponent("dense4g.txt"), megabytes: 4_096)
        say(
            String(
                format: "dense4g.txt: 4 GiB, %d lines (the marker line is cut out of the last one), %.1fs",
                lines,
                now() - started
            )
        )
    }

    /// 4 GiB, of which every 8 MiB begin with 2 MiB of text; the rest was never written (holes of NUL).
    private static func writeSparse(_ directory: URL) {
        let started = now()
        let sparse = directory.appendingPathComponent("sparse4g.txt")
        FileManager.default.createFile(atPath: sparse.path, contents: nil)
        let descriptor = open(sparse.path, O_RDWR)
        ftruncate(descriptor, 4 << 30)
        let (two, twoLines) = denseBlock(2 << 20, seed: 12)
        for stretch in 0..<512 {
            two.withUnsafeBytes { _ = pwrite(descriptor, $0.baseAddress, $0.count, off_t(stretch) * (8 << 20)) }
        }
        close(descriptor)
        say(
            String(
                format: "sparse4g.txt: 4 GiB apparent, 512 x 2 MiB of text (%d lines each) with 6 MiB holes, %.1fs",
                twoLines,
                now() - started
            )
        )
    }

    /// One line of 2 GiB that ends with the marker.
    private static func writeOneLine(_ directory: URL) {
        let started = now()
        let single = directory.appendingPathComponent("line2g.txt")
        let handle = writer(single)
        let phrase = Array("lorem ipsum dolor sit amet ".utf8)
        var block: [UInt8] = []
        while block.count < 1 << 20 {
            block.append(contentsOf: phrase)
        }
        block.removeLast(block.count - (1 << 20))
        let data = Data(block)
        for _ in 0..<2_047 {
            handle.write(data)
        }
        var last = data
        last.replaceSubrange(last.count - marker.utf8.count..<last.count, with: Array(marker.utf8))
        handle.write(last)
        finish(handle, single)
        say(String(format: "line2g.txt: one line of 2 GiB, %.1fs", now() - started))
    }

    /// 1 GiB of line feeds.
    private static func writeNewlines(_ directory: URL) {
        let started = now()
        let newlines = directory.appendingPathComponent("newlines1g.txt")
        let handle = writer(newlines)
        let feed = Data(repeating: 0x0A, count: 1 << 20)
        for _ in 0..<1_024 {
            handle.write(feed)
        }
        finish(handle, newlines)
        say(String(format: "newlines1g.txt: 1 GiB of line feeds, %.1fs", now() - started))
    }

    /// An empty file at `url`, open for writing.
    private static func writer(_ url: URL) -> FileHandle {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        do {
            return try FileHandle(forWritingTo: url)
        } catch {
            preconditionFailure("cannot write \(url.path): \(error)")
        }
    }

    /// Closes the file `handle` wrote to `url`.
    private static func finish(_ handle: FileHandle, _ url: URL) {
        do {
            try handle.close()
        } catch {
            preconditionFailure("cannot close \(url.path): \(error)")
        }
    }
}
