import AFMKernel
import Foundation
import FuzzCore

@testable import FileToolsPlugin

/// The `combine` target: a split `.crc` file next to two parts, combined into the target and into
/// the folder of the parts.
internal enum CombineFuzz {
    /// Tokens of `.crc` files.
    private static let dict = [
        "filename=", "size=", "crc32=", "\r\n", "\n", "=", "../", "/", "\\", "..", "data.001", "data.crc", "FFFFFFFF",
        "-1", "9223372036854775807", "9223372036854775808", "0x", "+", " ", "\u{2028}", "\u{85}"
    ]

    /// The names in the input folder.
    private static let inputs: Set<String> = ["data.001", "data.002", "data.crc"]

    /// The target.
    ///
    /// - Returns: The target for `fuzzMain`.
    @MainActor
    internal static func target() -> FuzzTarget {
        FuzzTarget("combine", maxLen: 1_024, dict: dict, seeds: seeds, setUp: ToolsFuzz.setUp, run: run)
    }

    /// Right `.crc` files and ones whose name points elsewhere or whose numbers are out of range.
    ///
    /// - Returns: The seeds.
    private static func seeds() -> [[UInt8]] {
        [
            "filename=whole.bin\r\nsize=6\r\ncrc32=4B8E39EF\r\n", "filename=../canary/pwn.bin\nsize=6\ncrc32=0\n",
            "FILENAME=/abs/x\nSIZE=-1\nCRC32=FFFFFFFFF\n", "filename=data.001\nsize=6\ncrc32=4B8E39EF\n",
            "filename=..\nsize=1\ncrc32=1\n", "size=6\ncrc32=1\nfilename=a\\b/c:d\n"
        ]
        .map { Array($0.utf8) }
    }

    /// Reads the `.crc` text, then combines from the `.crc` file and from the first part.
    ///
    /// - Parameter bytes: The input: the `.crc` file.
    @MainActor
    private static func run(_ bytes: [UInt8]) {
        if let info = SplitInfo(text: ToolsFuzz.text(bytes)) {
            _ = info.text
            fzCheck(
                SplitInfo(text: info.text) == info || info.name.contains(where: \.isNewline) || info.name.contains("="),
                "splitinfo-roundtrip",
                "\(info)"
            )
        }
        let manager = FileManager.default
        let root = ToolsFuzz.prepare()
        manager.createFile(atPath: root + "/in/data.001", contents: Data("abc".utf8))
        manager.createFile(atPath: root + "/in/data.002", contents: Data("def".utf8))
        manager.createFile(atPath: root + "/in/data.crc", contents: Data(bytes))
        for start in ["data.crc", "data.001"] {
            combine(root: root, from: start)
        }
    }

    /// Plans from one file and combines into the target and into the folder of the parts.
    ///
    /// - Parameters:
    ///   - root: The folder `prepare` made.
    ///   - start: The file the command starts from.
    @MainActor
    private static func combine(root: String, from start: String) {
        let manager = FileManager.default
        guard let startItem = ToolsFuzz.item(root + "/in/" + start) else {
            return
        }

        let toolRun = ToolRun(fileSystems: ToolsFuzz.registry)
        guard let plan = try? Combiner.plan(for: startItem, run: toolRun) else {
            return
        }

        let partNames = plan.parts.map(\.name)
        fzCheck(partNames == ["data.001", "data.002"], "combine-parts", "\(partNames)")
        for target in [root + "/out/target", root + "/in"] {
            if let outcome = try? Combiner.combine(
                plan.parts,
                info: plan.info,
                into: URL(fileURLWithPath: target),
                run: toolRun
            ) {
                fzCheck(
                    outcome.output.deletingLastPathComponent().path == target,
                    "combine-wrote-elsewhere",
                    outcome.output.path
                )
                fzCheck(
                    manager.contents(atPath: outcome.output.path) == Data("abcdef".utf8),
                    "combine-content",
                    outcome.output.path
                )
                if target.hasSuffix("/in") {
                    try? manager.removeItem(at: outcome.output)
                }
            }
            fzCheck(
                manager.contents(atPath: root + "/in/data.001") == Data("abc".utf8)
                    && manager.contents(atPath: root + "/in/data.002") == Data("def".utf8),
                "combine-damaged-a-part",
                "into \(target)"
            )
        }
        ToolsFuzz.checkContainment(root, inputs: inputs, what: "combine from \(start)")
    }
}
