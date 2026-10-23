import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileToolsPlugin

/// Encode and decode of whole files beyond the other suites: very long lines, large outputs,
/// names that cannot be used, sources that grow, and numbered parts that cannot be read.
@Suite
internal struct CoverageFileToolsFiles {
    /// A file the user skips.
    private static let skip: @Sendable (URL) -> ExistingFileChoice = { _ in .skip }

    /// The files: `/A` with what a test puts there, `/B` empty.
    private let memory = MemoryFileSystem()
    /// The memory files behind a layer that fails what a test names.
    private let files: CoverageSmallFiles
    /// The layer, as the tools find it.
    private let fileSystems = FileSystemRegistry()

    /// A run that overwrites and asks nothing.
    private var run: ToolRun { ToolRun(fileSystems: fileSystems) }

    /// The files and the registry.
    internal init() {
        memory.addDirectory("/A")
        memory.addDirectory("/B")
        files = CoverageSmallFiles(memory)
        fileSystems.register(files)
    }

    /// The item of a memory path.
    private func item(_ path: String) throws -> FileItem {
        try #require(memory.item(at: memory.url(path)))
    }

    /// The decoded bytes of a memory file.
    private func bytes(_ path: String) throws -> Data {
        let reader = try memory.read(memory.url(path))
        var data = Data()
        while let block = try reader.read(upToCount: 1 << 20), !block.isEmpty { data.append(block) }
        return data
    }

    /// A Base64 text on one line longer than a line is read in pieces; its last line may end
    /// in a carriage return alone; a large output is written in blocks.
    @Test
    internal func longLinesAndLargeOutputs() throws {
        let data = Data((0..<(ToolRun.blockSize + 1_000)).map { UInt8($0 % 251) })
        memory.addFile("/A/big.b64", data.base64EncodedString() + "\r")
        let outcome = try Decoder.decodeChecked(
            try item("/A/big.b64"),
            into: memory.url("/B"),
            autoRename: false,
            run: run
        )
        #expect(outcome.files.count == 1 && outcome.problems.isEmpty)
        #expect(try bytes("/B/big") == data)
    }

    /// Without a name in the text and without a usable name of the encoded file, nothing is
    /// decoded.
    @Test
    internal func noUsableName() throws {
        memory.addFile("/A/..uue", "begin 644\n#86)C\n`\nend\n")
        #expect(throws: ToolError.failed("The decoded file has no usable name.")) {
            try Decoder.decode(try item("/A/..uue"), into: memory.url("/B"), autoRename: false, run: run)
        }
    }

    /// The next numbered part is looked at before it is read: one that cannot be opened or
    /// read is no fresh file; one that starts with blank lines, or has nothing but them, is
    /// read on.
    @Test
    internal func numberedPartsThatAreHardToRead() throws {
        let encoded = SixBitText.encode(Data(String(repeating: "x", count: 90).utf8), xxEncode: false)
        let lines = (String(bytes: encoded, encoding: .ascii) ?? "").split(separator: "\r\n")
        memory.addFile("/A/x001.uue", "begin 644 x\n\(lines[0])\n")
        memory.addFile("/A/x002.uue", "\r\n\r\n\(lines[1])\n")
        memory.addFile("/A/x003.uue", "\n\n")
        memory.addFile("/A/x004.uue", "end\n")
        let decoded = try Decoder.decodeChecked(
            try item("/A/x001.uue"),
            into: memory.url("/B"),
            autoRename: false,
            run: run
        )
        #expect(decoded.files == [memory.url("/B/x")] && memory.contents("/B/x")?.count == 90)
        files.failingPaths = ["/A/x002.uue"]
        #expect(throws: CoverageSmallFiles.Failure.self) {
            try Decoder.decode(try item("/A/x001.uue"), into: memory.url("/B"), autoRename: false, run: run)
        }
        files.failingPaths = []
        let opened = Shared(0)
        files.onCall = { [files] call in
            guard call == .open else {
                return
            }
            opened.modify { $0 += 1 }
            if opened.value == 2 { files.fail(.read, times: 1) }
        }
        let again = try Decoder.decodeChecked(
            try item("/A/x001.uue"),
            into: memory.url("/B"),
            autoRename: false,
            run: run
        )
        #expect(again.files == [memory.url("/B/x")] && memory.contents("/B/x")?.count == 90)
    }

    /// A source that grows while it is encoded needs more parts than were planned, which is
    /// refused; a part the user skips cancels the encoding.
    @Test
    internal func encodingsThatCannotBeMade() throws {
        memory.addFile("/A/grow.bin", String(repeating: "x", count: 57))
        let listed = try item("/A/grow.bin")
        memory.addFile("/A/grow.bin", String(repeating: "x", count: 57 * 3))
        #expect(throws: ToolError.failed("grow.bin changed while it was encoded (it needs more parts than planned).")) {
            try Encoder.encode(
                listed,
                into: memory.url("/B"),
                options: Encoder.Options(method: .mime, linesPerFile: 1),
                run: run
            )
        }
        memory.addFile("/B/grow.b64", "old")
        let skipping = ToolRun(
            fileSystems: fileSystems,
            cancellation: CancellationFlag(),
            report: { _ in
                // Not watched here.
            },
            askExisting: Self.skip
        )
        #expect(throws: ToolError.cancelled) {
            try Encoder.encode(
                try item("/A/grow.bin"),
                into: memory.url("/B"),
                options: Encoder.Options(method: .mime),
                run: skipping
            )
        }
        #expect(memory.contents("/B/grow.b64") == "old")
    }

    /// A file that cannot be created is reported as it is.
    @Test
    internal func aFileThatCannotBeCreated() {
        files.fails = [.create]
        #expect(throws: CoverageSmallFiles.Failure.self) {
            try run.create(memory.url("/A/new.txt"), autoRename: false, deferred: false)
        }
    }
}
