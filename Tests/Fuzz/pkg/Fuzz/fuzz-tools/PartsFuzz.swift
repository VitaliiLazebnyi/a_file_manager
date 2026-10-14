import AFMKernel
import Foundation
import FuzzCore

@testable import FileToolsPlugin

/// The `parts` target: part discovery by names alone (the row a name starts ends, and never names
/// a path), then in a folder of files named by the input's lines.
internal enum PartsFuzz {
    /// Tokens of part names.
    private static let dict = [
        ".001", ".999", "aa", "zz", "az", ".", "9", "0", "99999999999999999", "999999999999999999",
        "9999999999999999999", ".crc", ".b64", "٣", "é", "/", "\u{0}"
    ]

    /// The target.
    ///
    /// - Returns: The target for `fuzzMain`.
    @MainActor
    internal static func target() -> FuzzTarget {
        FuzzTarget("parts", maxLen: 512, dict: dict, seeds: seeds, setUp: ToolsFuzz.setUp, run: run)
    }

    /// Names of parts in the numbered and lettered forms, and at the ends of their rows.
    ///
    /// - Returns: The seeds.
    private static func seeds() -> [[UInt8]] {
        [
            "file.001", "file.999", "xaa", "xzz", "part01.rar", "IMG_0099.b64", "name.7z.009", "a9.99", "zz", "٣٣.٣",
            "000000000000000000.x", "999999999999999999"
        ]
        .map { Array($0.utf8) }
    }

    /// Follows the row of each line's name, then finds the rows in a folder.
    ///
    /// - Parameter bytes: The input: names, one per line.
    @MainActor
    private static func run(_ bytes: [UInt8]) {
        for raw in bytes.split(separator: 10).prefix(4) {
            followRow(of: ToolsFuzz.text(Array(raw)), length: raw.count)
        }
        // In a folder: files named by the input's lines.
        let named = bytes.split(separator: 10).prefix(6).map { ToolsFuzz.text(Array($0)) }
        let lines = named.filter { line in
            !line.isEmpty && !line.contains("/") && !line.contains("\0") && line != "." && line != ".."
                && line.utf8.count < 200
        }
        guard !lines.isEmpty else {
            return
        }

        let manager = FileManager.default
        let dir = fzWorkDir + "/p"
        try? manager.removeItem(atPath: dir)
        try? manager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for line in lines {
            manager.createFile(atPath: dir + "/" + line, contents: Data("x".utf8))
        }
        for line in lines {
            guard let first = ToolsFuzz.item(dir + "/" + line) else {
                continue
            }

            let parts = PartSeries.parts(startingAt: first, provider: ToolsFuzz.local)
            fzCheck(
                parts.count <= lines.count + 1 && Set(parts.map(\.name)).count == parts.count,
                "parts-row",
                "\(parts.map(\.name))"
            )
        }
    }

    /// Follows the row a name starts: it ends, never comes back, and the names keep their length.
    ///
    /// - Parameters:
    ///   - name: The name.
    ///   - length: Its length in bytes (used as a part number).
    private static func followRow(of name: String, length: Int) {
        var current = name
        var steps = 0
        var seen = Set<String>([name])
        while let next = PartSeries.next(after: current), steps < 3_000 {
            fzCheck(
                seen.insert(next).inserted,
                "parts-cycle",
                "\(name.debugDescription) comes back to \(next.debugDescription)"
            )
            fzCheck(
                next.utf8.count == current.utf8.count,
                "parts-length-changes",
                "\(current.debugDescription) -> \(next.debugDescription)"
            )
            current = next
            steps += 1
        }
        let whole = PartSeries.combinedName(forPart: name)
        fzCheck(!whole.isEmpty || name.isEmpty, "parts-empty-combined-name", name.debugDescription)
        _ = Splitter.partName(name, length)
        _ = Splitter.size(from: name)
    }
}
