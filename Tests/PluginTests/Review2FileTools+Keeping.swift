import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileToolsPlugin

/// Nothing that was there before is lost: cancelled tools leave the old files as they were.
extension Review2FileTools {
    /// A Split cancelled after an overwrite leaves the old parts as they were; one that ends replaces them all.
    @Test
    internal func cancelAfterOverwriteLeavesSplitPartsAsTheyWere() throws {
        try Data(repeating: 7, count: 3_000).write(to: box.url("data.bin"))
        try box.file("out/data.001", "old one")
        try box.file("out/data.002", "old two")
        try box.file("out/data.crc", "old crc")
        // The second question comes while the first new part is already being written.
        let cancel = CancellationFlag()
        #expect(throws: ToolError.cancelled) {
            try Splitter.split(
                item("data.bin"),
                into: box.url("out"),
                partSize: 1_000,
                run: run(cancel: cancel, cancelOnAsk: 2)
            )
        }
        #expect(
            box.read("out/data.001") == "old one" && box.read("out/data.002") == "old two"
                && box.read("out/data.crc") == "old crc"
        )
        #expect(names("out") == ["data.001", "data.002", "data.crc"])
        // Without the cancel they are replaced, all together.
        _ = try Splitter.split(item("data.bin"), into: box.url("out"), partSize: 1_000, run: run())
        let firstPart = try Data(contentsOf: box.url("out/data.001"))
        let thirdPart = try Data(contentsOf: box.url("out/data.003"))
        #expect(firstPart.count == 1_000 && thirdPart.count == 1_000)
        #expect(names("out") == ["data.001", "data.002", "data.003", "data.crc"])
    }

    /// An Encode cancelled after an overwrite leaves the old file as it was.
    @Test
    internal func cancelAfterOverwriteLeavesEncodedFileAsItWas() throws {
        try Data(repeating: 1, count: 5_000).write(to: box.url("data.bin"))
        try box.file("out/data.b64", "old")
        let cancel = CancellationFlag()
        #expect(throws: ToolError.cancelled) {
            try Encoder.encode(
                item("data.bin"),
                into: box.url("out"),
                options: Encoder.Options(method: .mime),
                run: run(cancel: cancel, cancelOnAsk: 1)
            )
        }
        #expect(box.read("out/data.b64") == "old" && names("out") == ["data.b64"])
    }

    /// A Combine cancelled after an overwrite leaves the old file and the parts as they were.
    @Test
    internal func cancelAfterOverwriteLeavesCombinedFileAndPartsAsTheyWere() throws {
        try box.file("in/f.001", "aaa")
        try box.file("in/f.002", "bbb")
        try box.file("out/f", "old combined")
        let cancel = CancellationFlag()
        let parts = [try item("in/f.001"), try item("in/f.002")]
        #expect(throws: ToolError.cancelled) {
            try Combiner.combine(parts, info: nil, into: box.url("out"), run: run(cancel: cancel, cancelOnAsk: 1))
        }
        #expect(box.read("out/f") == "old combined" && box.read("in/f.001") == "aaa" && names("out") == ["f"])
        let outcome = try Combiner.combine(parts, info: nil, into: box.url("out"), run: run())
        #expect(outcome.parts == 2 && box.read("out/f") == "aaabbb")
    }

    /// A Decode cancelled after an overwrite keeps the old file.
    @Test
    internal func decodeCancelledAfterOverwriteKeepsTheOldFile() throws {
        try box.file("out/f", "old")
        try Data("begin 644 f\n#86)C\n`\nend\n".utf8).write(to: box.url("f.uue"))
        let cancel = CancellationFlag()
        #expect(throws: ToolError.cancelled) {
            try Decoder.decode(
                item("f.uue"),
                into: box.url("out"),
                autoRename: false,
                run: run(cancel: cancel, cancelOnAsk: 1)
            )
        }
        #expect(box.read("out/f") == "old" && names("out") == ["f"])
    }

    /// The guard against writing over a source sees through letter case and links.
    @Test
    internal func sameFileGuardSeesCaseVariantsAndLinks() throws {
        try box.file("real/X.crc", "x")
        try FileManager.default.createSymbolicLink(at: box.url("alias"), withDestinationURL: box.url("real"))
        #expect(ToolRun.isSameFile(box.url("alias/X.crc"), box.url("real/X.crc")))
        #expect(
            ToolRun.isSameFile(box.url("real/x.CRC"), box.url("real/X.crc"))
                == (FileManager.default.fileExists(atPath: box.url("real/x.CRC").path))
        )
        #expect(!ToolRun.isSameFile(box.url("real/other"), box.url("real/X.crc")))
        // Splitting a part of its own series in place is refused through a link as well.
        try box.file("real/data.001", "abc")
        #expect(throws: ToolError.self) {
            try Splitter.split(item("real/data.001"), into: box.url("alias"), partSize: 10, run: run())
        }
        #expect(box.read("real/data.001") == "abc")
    }

    /// A huge number of lines per file is no limit, and no overflow.
    @Test
    internal func aHugeLinesPerFileDoesNotTrap() throws {
        try Data(repeating: 3, count: 500).write(to: box.url("data.bin"))
        try box.folder("out")
        let written = try Encoder.encode(
            item("data.bin"),
            into: box.url("out"),
            options: Encoder.Options(method: .uue, linesPerFile: 999_999_999_999_999_999),
            run: run()
        )
        #expect(written.count == 1)
    }
}
