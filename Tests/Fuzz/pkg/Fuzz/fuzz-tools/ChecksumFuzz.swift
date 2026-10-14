import Foundation
import FuzzCore

@testable import FileToolsPlugin

/// The `checksum` target: checksum files of every format, read as each kind of checksum file.
internal enum ChecksumFuzz {
    /// Tokens of checksum files.
    private static let dict = [
        "; comment\n", " *", "  ", "\\", "\\\\", "\\n", "\\r", "MD5 (", "SHA256 (", "SHA1(", "BLAKE3 (", ") = ",
        "d41d8cd98f00b204e9800998ecf8427e", "da39a3ee5e6b4b0d3255bfef95601890afd80709", "00000000",
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "\r\n", "\u{FEFF}", "../", "/", "a.txt",
        "..\\", "\t", "*", "#"
    ]

    /// The target.
    ///
    /// - Returns: The target for `fuzzMain`.
    internal static func target() -> FuzzTarget {
        FuzzTarget("checksum", maxLen: 4_096, dict: dict, seeds: seeds, run: run)
    }

    /// SFV, md5sum, BSD style and escaped lines; UTF-16 and UTF-8 with a byte order mark.
    ///
    /// - Returns: The seeds.
    private static func seeds() -> [[UInt8]] {
        let texts = [
            "; made by x\r\na.txt 3610A686\r\nsub\\b.bin 00000000\r\n",
            "d41d8cd98f00b204e9800998ecf8427e *a.txt\n86f7e437faa5a7fce15d1ddcb9eaeaea377667b8  sub/b.bin\n",
            "MD5 (a.txt) = d41d8cd98f00b204e9800998ecf8427e\n"
                + "SHA256 (b) = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n",
            "\\d41d8cd98f00b204e9800998ecf8427e  a\\nb\\\\c.txt\n",
            "da39a3ee5e6b4b0d3255bfef95601890afd80709  /etc/hosts\n3610a686  ../canary/keep.txt\n"
        ]
        let utf16 = Array("a.txt 3610A686\n".utf16).flatMap { unit in [UInt8(unit & 255), UInt8(unit >> 8)] }
        return texts.map { Array($0.utf8) } + [
            [0xFF, 0xFE] + utf16,
            [0xEF, 0xBB, 0xBF] + Array("ä.txt 00000000\n".utf8)
        ]
    }

    /// Parses the text under every name, and asks the other helpers that read such text.
    ///
    /// - Parameter bytes: The input.
    private static func run(_ bytes: [UInt8]) {
        let decoded = ChecksumFile.text(from: Data(bytes))
        for name in ToolsFuzz.checksumNames {
            let entries = ChecksumFile.parse(decoded, fileName: name)
            for entry in entries {
                fzCheck(!entry.name.isEmpty, "checksum-empty-name", "\(name): \(entry)")
            }
        }
        _ = ChecksumFile.method(forFileNamed: decoded)
        _ = ChecksumFile.isChecksumFile(String(decoded.prefix(300)), extraMasks: String(decoded.suffix(60)))
        _ = ChecksumRun.checksumInName(decoded)
        _ = ChecksumRun.checksum(fromClipboard: decoded)
        _ = Splitter.size(from: String(decoded.prefix(64)))
    }
}
