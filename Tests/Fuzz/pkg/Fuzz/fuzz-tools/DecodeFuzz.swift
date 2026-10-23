import Foundation
import FuzzCore

@testable import FileToolsPlugin

/// The decoders (Base64/MIME, UUE, XXE, yEnc): `decodemem` into memory (fast), `decode` from files
/// in a folder into a target folder, as the command does it.
internal enum DecodeFuzz {
    /// Tokens of the encoded formats.
    private static let dict = [
        "begin 644 ", "begin 0 ", "end\n", "`\n", "=ybegin part=1 total=2 line=128 size=5 name=",
        "=ypart begin=1 end=5\n",
        "=yend size=5 part=1 pcrc32=", "=yend size=5 crc32=00000000\n",
        "=ybegin line=128 size=99999999999999999999 name=",
        "Content-Type: multipart/mixed; boundary=\"b\"\n", "Content-Transfer-Encoding: base64\n",
        "Content-Disposition: attachment; filename=\"", "name=\"", "filename*=UTF-8''", "MIME-Version: 1.0\n", "--b\n",
        "--b--\n", "\n\n", "\r\n", "=", "==", "M", "../", "/", "\\", "..", "\"", "begin-base64 644 ", "====\n",
        "xbtoa Begin\n", "+", "table\n", "section 1 of 2", "\u{0}"
    ]

    /// The `decodemem` target.
    ///
    /// - Returns: The target for `fuzzMain`.
    internal static func memoryTarget() -> FuzzTarget {
        FuzzTarget("decodemem", maxLen: 4_096, dict: dict, seeds: seeds, run: runInMemory)
    }

    /// The `decode` target: the input may hold several parts, separated by the byte 0x1C.
    ///
    /// - Returns: The target for `fuzzMain`.
    @MainActor
    internal static func filesTarget() -> FuzzTarget {
        FuzzTarget(
            "decode",
            maxLen: 4_096,
            dict: dict + ["\u{1C}"],
            seeds: { seeds().map { [0] + $0 } },
            setUp: ToolsFuzz.setUp,
            run: runOnFiles
        )
    }

    /// Feeds the lines to a decode machine that writes into memory, and asks the name helpers.
    ///
    /// - Parameter bytes: The input.
    private static func runInMemory(_ bytes: [UInt8]) {
        let sink = MemorySink()
        let machine = DecodeMachine(sink: sink)
        do {
            for var line in bytes.split(separator: 10, omittingEmptySubsequences: false) {
                if line.last == 13 {
                    line = line.dropLast()
                }
                _ = DecodeMachine.startsNewFile(line)
                try machine.feed(line)
            }
            try machine.finish()
        } catch {
            // Text the decoders refuse ends the run; what was decoded so far is counted.
        }
        let total = sink.files.reduce(0) { sum, file in sum + file.bytes }
        // Nothing decodes into more than it was.
        fzCheck(total <= bytes.count + 16, "decode-grows", "\(total) bytes out of \(bytes.count)")
        for line in bytes.split(separator: 10).prefix(4) {
            _ = (try? SixBitText.decode(line, xxEncode: false))
            _ = (try? SixBitText.decode(line, xxEncode: true))
        }
        let name = ToolsFuzz.text(Array(bytes.prefix(80)))
        _ = Decoder.safeName(name, replacingColon: true)
        _ = Decoder.fallbackName(for: name)
        for method in EncodeMethod.allCases {
            _ = Encoder.outputNames(for: name, method: method, parts: 1 + bytes.count % 3)
            _ = Encoder.header(for: name, method: method)
        }
    }

    /// Writes the parts as files, decodes the first into the target folder and checks nothing went elsewhere.
    ///
    /// - Parameter bytes: The input: the choice of the extension, then the parts.
    @MainActor
    private static func runOnFiles(_ bytes: [UInt8]) {
        guard let first = bytes.first else {
            return
        }

        let root = ToolsFuzz.prepare()
        let ext = ["b64", "uue", "xxe", "ntx", "txt", "001"][Int(first) % 6]
        let parts = bytes.dropFirst().split(separator: 0x1C, maxSplits: 3, omittingEmptySubsequences: false)
        var inputs = Set<String>()
        for (index, part) in parts.enumerated() {
            let name =
                ext == "001" ? String(format: "part.%03d", index + 1) : String(format: "part%03d.%@", index + 1, ext)
            FileManager.default.createFile(atPath: root + "/in/" + name, contents: Data(part))
            inputs.insert(name)
        }
        guard let firstItem = ToolsFuzz.item(root + "/in/" + inputs.sorted()[0]) else {
            return
        }

        let target = URL(fileURLWithPath: root + "/out/target")
        for autoRename in [false, true] {
            let toolRun = ToolRun(fileSystems: ToolsFuzz.registry)
            let written =
                (try? Decoder.decode(firstItem, into: target, autoRename: autoRename, run: toolRun)) ?? []
            for url in written {
                fzCheck(
                    url.deletingLastPathComponent().path == root + "/out/target",
                    "decode-wrote-elsewhere",
                    url.path
                )
            }
            ToolsFuzz.checkContainment(root, inputs: inputs, what: "decode autoRename=\(autoRename)")
        }
    }

    /// One file of each format, names that point elsewhere, and two-part and two-file inputs.
    ///
    /// - Returns: The seeds, each character as one byte.
    private static func seeds() -> [[UInt8]] {
        let payload = Data((0..<200).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let base64 = payload.base64EncodedString(options: [
            .lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed
        ])
        let uue = ToolsFuzz.text(Array(SixBitText.encode(payload, xxEncode: false)))
        let xxe = ToolsFuzz.text(Array(SixBitText.encode(payload, xxEncode: true)))
        var seeds: [String] = []
        seeds.append(
            "MIME-Version: 1.0\r\nContent-Type: application/octet-stream; name=\"a.bin\"\r\n"
                + "Content-Transfer-Encoding: base64\r\nContent-Disposition: attachment; filename=\"a.bin\"\r\n\r\n"
                + base64 + "\r\n"
        )
        seeds.append(uue.isEmpty ? "" : "begin 644 a.bin\r\n" + uue + "`\r\nend\r\n")
        seeds.append("begin 644 a.bin\r\n" + xxe + "+\r\nend\r\n")
        seeds.append("begin 644 ../canary/pwn.txt\n#0V%T\n`\nend\n")
        seeds.append(
            "begin 644 /abs/../../canary/pwn.txt\n#0V%T\n`\nend\nbegin 600 ..\n#0V%T\n`\nend\n"
                + "begin 600 a:b\\c\n#0V%T\n`\nend\n"
        )
        seeds.append(
            "=ybegin line=128 size=3 name=../canary/y.bin\r\n\u{8D}\u{8F}\u{9E}\r\n=yend size=3 crc32=00000000\r\n"
        )
        seeds.append(
            "=ybegin part=1 total=2 line=128 size=6 name=two.bin\r\n=ypart begin=1 end=3\r\nabc\r\n"
                + "=yend size=3 part=1 pcrc32=00000000\r\n=ybegin part=2 total=2 line=128 size=6 name=two.bin\r\n"
                + "=ypart begin=4 end=6\r\ndef=J\r\n=yend size=3 part=2\r\n"
        )
        seeds.append(
            "From: x\nContent-Type: multipart/mixed; boundary=\"b\"\n\n--b\nContent-Type: text/plain\n\nhello\n"
                + "--b\nContent-Transfer-Encoding: base64\n"
                + "Content-Disposition: attachment; filename=\"../canary/m.txt\"\n\naGVsbG8=\n"
                + "--b\nContent-Transfer-Encoding: base64\nContent-Type: image/png; name=\"second.png\"\n"
                + "\naGVsbG8gd29ybGQ=\n--b--\n"
        )
        seeds.append("begin-base64 644 b.txt\naGVsbG8=\n====\n")
        seeds.append("aGVsbG8gd29ybGQ=\n")
        seeds.append(
            "begin 644 first.bin\nM" + String(repeating: "A", count: 60) + "\n\u{1C}M"
                + String(repeating: "B", count: 60)
                + "\n`\nend\n"
        )
        return seeds.map { seed in seed.unicodeScalars.map { scalar in UInt8(truncatingIfNeeded: scalar.value) } }
    }
}
