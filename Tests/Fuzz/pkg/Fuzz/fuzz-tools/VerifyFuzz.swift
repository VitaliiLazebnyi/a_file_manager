import Foundation
import FuzzCore

@testable import FileToolsPlugin

/// The `verify` target: the whole of Verify, with the checksum file next to two real files.
internal enum VerifyFuzz {
    /// Tokens of checksum files that name the files there.
    private static let dict = [
        "a.txt", "sub/b.bin", "sub\\b.bin", "3610a686", "d41d8cd98f00b204e9800998ecf8427e", " *", "  ", "\n",
        "../out/canary/keep.txt", "/", "MD5 (", ") = ", "\\"
    ]

    /// The target.
    ///
    /// - Returns: The target for `fuzzMain`.
    @MainActor
    internal static func target() -> FuzzTarget {
        FuzzTarget("verify", maxLen: 2_048, dict: dict, seeds: seeds, setUp: ToolsFuzz.setUp, run: run)
    }

    /// Checksum files with right, wrong and missing entries (the first byte chooses the file name).
    ///
    /// - Returns: The seeds.
    private static func seeds() -> [[UInt8]] {
        [
            "a.txt 4a17b156\r\nsub\\b.bin 00000000\r\nmissing 12345678\r\n",
            "5eb63bbbe01eeed093cb22bb8f5acdc3 *a.txt\nd41d8cd98f00b204e9800998ecf8427e  sub/b.bin\n",
            "MD5 (a.txt) = 5eb63bbbe01eeed093cb22bb8f5acdc3\n",
            "2aae6c35c94fcfb415dbe95f408b9ce91ee846ed  ../out/canary/keep.txt\n"
        ]
        .map { [UInt8($0.utf8.count % 13)] + Array($0.utf8) }
    }

    /// Verifies the checksum file and checks nothing was written.
    ///
    /// - Parameter bytes: The input: the choice of the name, then the checksum file.
    @MainActor
    private static func run(_ bytes: [UInt8]) {
        guard let first = bytes.first else {
            return
        }

        let manager = FileManager.default
        let root = ToolsFuzz.prepare()
        let name = ToolsFuzz.checksumNames[Int(first) % ToolsFuzz.checksumNames.count]
        manager.createFile(atPath: root + "/in/a.txt", contents: Data("hello world".utf8))
        try? manager.createDirectory(atPath: root + "/in/sub", withIntermediateDirectories: true)
        manager.createFile(atPath: root + "/in/sub/b.bin", contents: Data())
        manager.createFile(atPath: root + "/in/" + name, contents: Data(bytes.dropFirst()))
        guard let file = ToolsFuzz.item(root + "/in/" + name) else {
            return
        }

        let toolRun = ToolRun(fileSystems: ToolsFuzz.registry)
        if let report = try? ChecksumRun.verify(checksumFiles: [file], run: toolRun) {
            _ = report.text(onlyErrors: false)
            _ = report.text(onlyErrors: true)
        }
        ToolsFuzz.checkContainment(root, inputs: ["a.txt", "sub", name], what: "verify")
    }
}
