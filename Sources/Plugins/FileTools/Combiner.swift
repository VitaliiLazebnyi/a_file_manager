import AFMKernel
import Foundation

/// Combine Files (spec 08 › Combine files).
internal enum Combiner {
    /// What the `.crc` file says of the combined file.
    internal enum Check: Equatable {
        /// Size and CRC32 differ from the `.crc` file: the file is damaged or incomplete.
        case damaged
        /// Size and CRC32 are those of the `.crc` file.
        case matches
        /// There is no `.crc` file to check against.
        case unchecked
    }

    /// What Combine made.
    internal struct Outcome: Equatable {
        /// The combined file.
        internal var output: URL
        /// How many parts it was made of.
        internal var parts: Int
        /// Whether size and CRC32 match the `.crc` file.
        internal var check: Check
    }

    /// What is to be combined when the cursor is on `item`: the row of parts and what the
    /// `.crc` file says.
    ///
    /// The cursor may be on the first part or on the `.crc` file itself.
    internal static func plan(for item: FileItem, run: ToolRun) throws -> (parts: [FileItem], info: SplitInfo?) {
        let provider = try run.provider(for: item.url)
        let directory = item.url.deletingLastPathComponent()
        var first = item
        if item.ext.lowercased() == "crc" {
            guard
                let part = provider.item(
                    at: directory.appending(name: Splitter.partName(item.baseName, 1)),
                    cancellation: run.cancellation
                )
            else {
                throw ToolError.failed("\(Splitter.partName(item.baseName, 1)) not found!")
            }
            first = part
        }
        let crcFile = directory.appending(name: FileItem.split(first.name).base + ".crc")
        var info: SplitInfo?
        if provider.item(at: crcFile, cancellation: run.cancellation) != nil,
            let data = try? run.contents(of: crcFile, limit: 1 << 16)
        {
            info = SplitInfo(text: String(repairingUTF8: data))
        }
        return (PartSeries.parts(startingAt: first, provider: provider, cancellation: run.cancellation), info)
    }

    /// The name a `.crc` file gives to the whole, as a name inside the target folder: what stands
    /// after the last `/` or `\\` (found on the bytes, so that a slash with a combining mark
    /// after it is a slash all the same), never empty, `.` or `..`.
    internal static func storedName(_ name: String) -> String? {
        Decoder.safeName(name, replacingColon: false)
    }

    /// Writes the parts one after another into one file in `directory`, named as the `.crc` file says (else
    /// after the parts), and checks it against `info`.
    internal static func combine(_ parts: [FileItem], info: SplitInfo?, into directory: URL, run: ToolRun) throws
        -> Outcome
    {
        guard let first = parts.first else {
            throw ToolError.failed("No files selected!")
        }
        run.carriesOrigin = true
        // A stored name is only a name: it never leads out of the target folder.
        let name = info.flatMap { found in storedName(found.name) } ?? PartSeries.combinedName(forPart: first.name)
        guard let target = directory.appending(safeName: name) else {
            throw ToolError.failed("The name of the combined file is not a file name.")
        }
        guard !parts.contains(where: { part in ToolRun.isSameFile(part.url, target) }) else {
            throw ToolError.failed("The combined file would replace one of its parts.")
        }
        run.expect(bytes: parts.reduce(0) { total, part in total.addingSaturated(part.size) }, items: parts.count)
        return try run.transaction {
            guard let output = try run.create(target, autoRename: false, deferred: true) else {
                throw ToolError.cancelled
            }
            let crc = CRC32Hasher()
            for part in parts {
                run.show([
                    "From: " + run.fileSystems.displayPath(part.url), "To: " + run.fileSystems.displayPath(output.url)
                ])
                try run.read(part.url, counted: true, blockSize: ToolRun.blockSize) { block in
                    crc.update(block)
                    try output.write(block)
                }
                run.advance(0, items: 1, force: false)
            }
            try output.finish()
            let check: Check
            if let info {
                check = info.size == output.bytesWritten && info.crc == crc.checksum ? .matches : .damaged
            } else {
                check = .unchecked
            }
            return Outcome(output: output.url, parts: parts.count, check: check)
        }
    }
}
