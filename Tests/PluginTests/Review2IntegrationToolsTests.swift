import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileToolsPlugin

// Review round 2, integration: Split, Combine, Encode and Decode hand on the mark of coming
// from elsewhere that their source carries (network.md item 2, left open by plugins-b), and
// the sums they make of sizes cannot trap.

@Suite
internal struct Review2IntegrationTools {
    /// A "server": every file on it carries the mark of coming from elsewhere.
    internal let server = MemoryFileSystem(scheme: "srv")
    /// A place that keeps the marks it is given and gives none of its own.
    internal let target = MemoryFileSystem(scheme: "disk")
    internal let registry = FileSystemRegistry()
    internal let mark = Data("0081;from the server".utf8)

    internal init() {
        server.quarantineValue = mark
        registry.register(server)
        registry.register(target)
        target.addDirectory("/out")
    }

    private func run() -> ToolRun { ToolRun(fileSystems: registry) }

    private func item(_ url: URL) throws -> FileItem { try #require(registry.item(at: url)) }

    @Test
    internal func thePartsOfAFileFromAServerAndTheFilePutTogetherAgainCarryItsMark() throws {
        let source = server.addFile("/in/program.bin", String(repeating: "0123456789", count: 500))
        let parts = try Splitter.split(try item(source), into: target.url("/out"), partSize: 2_000, run: run())
        #expect(parts.count == 4)
        let marked = target.quarantineMarks
        #expect(
            marked["/out/program.001"] == mark && marked["/out/program.002"] == mark
                && marked["/out/program.003"] == mark
        )
        // Put together from parts that lie on the server, the whole carries it too.
        for name in ["program.001", "program.002", "program.003", "program.crc"] {
            _ = server.addFile("/parts/" + name, target.contents("/out/" + name) ?? "")
        }
        target.addDirectory("/whole")
        let plan = try Combiner.plan(for: try item(server.url("/parts/program.001")), run: run())
        _ = try Combiner.combine(plan.parts, info: plan.info, into: target.url("/whole"), run: run())
        #expect(target.contents("/whole/program.bin") == String(repeating: "0123456789", count: 500))
        #expect(target.quarantineMarks["/whole/program.bin"] == mark)
    }

    @Test
    internal func anEncodedFileAndWhatIsDecodedFromItCarryTheMarkOfTheirSource() throws {
        let source = server.addFile("/in/tool.sh", "#!/bin/sh\necho harmless\n")
        let encoded = try Encoder.encode(try item(source), into: target.url("/out"), method: .mime, run: run())
        #expect(encoded.count == 1 && target.quarantineMarks["/out/tool.b64"] == mark)
        // Decoded from a file on the server.
        _ = server.addFile("/in/tool.b64", target.contents("/out/tool.b64") ?? "")
        target.addDirectory("/decoded")
        let decoded = try Decoder.decode(
            try item(server.url("/in/tool.b64")),
            into: target.url("/decoded"),
            run: run()
        )
        #expect(decoded.count == 1 && target.contents("/decoded/tool.sh") == "#!/bin/sh\necho harmless\n")
        #expect(target.quarantineMarks["/decoded/tool.sh"] == mark)
    }

    @Test
    internal func aSourceWithoutAMarkLeavesItsOutputsWithoutOne() throws {
        let source = target.addFile("/plain/data.bin", String(repeating: "x", count: 3_000))
        _ = try Splitter.split(try item(source), into: target.url("/out"), partSize: 2_000, run: run())
        #expect(target.contents("/out/data.002") != nil && target.quarantineMarks.isEmpty)
    }

    @Test
    internal func sizesNobodyCanMeanAreRefusedAndTrapNothing() throws {
        let source = server.addFile("/in/small.bin", "small")
        // The largest size a field can hold, typed as the size of a part.
        let parts = try Splitter.split(try item(source), into: target.url("/out"), partSize: .max, run: run())
        #expect(parts.count == 2 && target.contents("/out/small.001") == "small")
        // A file a server says is nearly the largest number of bytes there is.
        let real = try item(source)
        let huge = FileItem(url: real.url, name: real.name, stat: .init(size: .max - 1, modified: real.modified))
        #expect(throws: ToolError.self) {
            try Splitter.split(huge, into: target.url("/out"), partSize: 1 << 20, run: run())
        }
        #expect(throws: ToolError.self) {
            try Encoder.encode(huge, into: target.url("/out"), method: .mime, linesPerFile: 1, run: run())
        }
    }
}
