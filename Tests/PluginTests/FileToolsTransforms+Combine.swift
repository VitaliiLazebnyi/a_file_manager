import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileToolsPlugin

/// Combine: the row of parts, the `.crc` file, and the whole put together again.
extension FileToolsTransforms {
    /// The counters of part names are found and counted on, and `.crc` files are read.
    @Test
    internal func partSeries() {
        #expect(PartSeries.next(after: "file.001") == "file.002" && PartSeries.next(after: "file.099") == "file.100")
        #expect(
            PartSeries.next(after: "file.999") == nil && PartSeries.next(after: "notes.txt") == nil
                && PartSeries.next(after: "song.mp3") == nil
        )
        #expect(PartSeries.next(after: "name.00009.zip.part") == "name.00010.zip.part")
        #expect(
            PartSeries.next(after: "fileaa") == "fileab" && PartSeries.next(after: "fileaz") == "fileba"
                && PartSeries.next(after: "filezz") == nil
        )
        #expect(PartSeries.next(after: "file001.uue") == "file002.uue")
        #expect(
            PartSeries.combinedName(forPart: "movie.mkv.001") == "movie.mkv"
                && PartSeries.combinedName(forPart: "xaa") == "x"
        )
        #expect(
            PartSeries.combinedName(forPart: "name.00000.zip.part") == "name.zip.part"
                && PartSeries.combinedName(forPart: "001") == "001.combined"
        )
        #expect(
            SplitInfo(text: "filename=a b.bin\r\nsize=12\r\ncrc32=00FF00ff\r\n")
                == SplitInfo(name: "a b.bin", size: 12, crc: 0x00FF_00FF)
        )
        #expect(SplitInfo(text: "filename=a\nsize=x\ncrc32=1") == nil && SplitInfo(text: "") == nil)
    }

    /// Combine starts from the first part or from the `.crc` file, also into another file system.
    @Test
    internal func combineFromTheFirstPartOrTheCrcFile() throws {
        try write("A/random_1MB.bin", megabyte)
        perform(.splitFile, cursor: nil, ["target": .text(""), "size": .text("400k")])
        try FileManager.default.removeItem(at: box.url("A/random_1MB.bin"))
        perform(.combineFiles, cursor: "random_1MB.001", [:])
        #expect(data("B/random_1MB.bin") == megabyte)
        #expect(interaction.log.suffix(2) == ["form: Combine", "inform: Combine - 3"])
        if case .note = interaction.forms.last?.first?.kind {
            #expect(
                interaction.forms.last?.first?.label
                    == "Combine random_1MB.001 and all files with ascending names to the following directory:"
            )
        }
        perform(.combineFiles, cursor: "random_1MB.crc", ["target": .text("mem:/out")])
        #expect(memory.item(at: memory.url("/out/random_1MB.bin"))?.size == 1_048_576)
        #expect(bench.jobService.reports.last?.bytesDone == 1_048_576)
    }

    /// Combine checks the CRC32 of the `.crc` file, finds a damaged or missing part, and keeps a stored name in
    /// the target folder.
    @Test
    internal func combineChecksTheCrc() throws {
        try write("A/data.bin", FileToolsFixture.patternData(3_000))
        perform(.splitFile, cursor: nil, ["target": .text(""), "size": .text("1000")])
        let plan = try Combiner.plan(for: item("A/data.001"), run: run)
        #expect(plan.parts.map(\.name) == ["data.001", "data.002", "data.003"] && plan.info?.size == 3_000)
        #expect(try Combiner.combine(plan.parts, info: plan.info, into: box.url("B"), run: run).check == .matches)
        // A damaged part is found out.
        try Data(repeating: 7, count: 1_000).write(to: box.url("A/data.002"))
        let damaged = try Combiner.combine(plan.parts, info: plan.info, into: box.url("B"), run: run)
        #expect(damaged.check == .damaged && damaged.parts == 3)
        // So is a missing one: the row ends where a name is not there.
        try FileManager.default.removeItem(at: box.url("A/data.003"))
        let short = try Combiner.plan(for: item("A/data.001"), run: run)
        #expect(try Combiner.combine(short.parts, info: short.info, into: box.url("B"), run: run).check == .damaged)
        // A stored name with a path stays inside the target folder.
        let outside = try Combiner.combine(
            short.parts,
            info: SplitInfo(name: "../../evil.bin", size: 0, crc: 0),
            into: box.url("B"),
            run: run
        )
        #expect(outside.output == box.url("B/evil.bin"))
    }

    /// Without a `.crc` file the parts are combined under their name without the counter, never over a part.
    @Test
    internal func combineWithoutACrcFile() throws {
        for (index, text) in ["one ", "two ", "three"].enumerated() {
            try box.file("A/letter.txt.00\(index + 1)", text)
        }
        try box.file("A/xaa", "unix ")
        try box.file("A/xab", "split")
        perform(.combineFiles, cursor: "letter.txt.001", [:])
        #expect(box.read("B/letter.txt") == "one two three" && interaction.log.last == "inform: Combine - 3")
        perform(.combineFiles, cursor: "xaa", [:])
        #expect(box.read("B/x") == "unix split" && interaction.log.last == "inform: Combine - 2")
        // Into the folder of the parts themselves the whole must not replace a part.
        try box.file("A/001", "a")
        try FileManager.default.createDirectory(at: box.url("C"), withIntermediateDirectories: true)
        #expect(throws: ToolError.self) {
            try Combiner.combine(
                [item("A/letter.txt.001")],
                info: SplitInfo(name: "letter.txt.001", size: 4, crc: 0),
                into: box.url("A"),
                run: run
            )
        }
        #expect(box.read("A/letter.txt.001") == "one ")
        // A `.crc` file whose parts are gone.
        try box.file("A/lost.crc", "filename=lost.bin\r\nsize=1\r\ncrc32=00000000\r\n")
        perform(.combineFiles, cursor: "lost.crc", [:])
        #expect(interaction.log.last == "inform: Combine" && !box.exists("B/lost.bin"))
    }
}
