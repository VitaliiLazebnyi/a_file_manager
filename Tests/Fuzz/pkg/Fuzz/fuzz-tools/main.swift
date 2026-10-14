import Foundation
import FuzzCore
import AFMKernel
import LocalFileSystemPlugin
@testable import FileToolsPlugin

// FileTools: checksum files, the decoders (Base64/MIME, UUE, XXE, yEnc), split `.crc` files
// and the discovery of the parts to combine.

let fm = FileManager.default
var registry: FileSystemRegistry!
var local: LocalFileSystem!
let canaryText = Data("canary: must stay as it is\n".utf8)

func setUpTools() {
    local = LocalFileSystem()
    registry = FileSystemRegistry()
    registry.register(local)
}

func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
func names(_ path: String) -> [String] { ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted() }

/// <work>/x/in (the inputs), <work>/x/out/target (where results go), <work>/x/out/canary/keep.txt.
func prepare() -> String {
    let root = fzWorkDir + "/x"
    try? fm.removeItem(atPath: root)
    try? fm.createDirectory(atPath: root + "/in", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: root + "/out/target", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: root + "/out/canary", withIntermediateDirectories: true)
    fm.createFile(atPath: root + "/out/canary/keep.txt", contents: canaryText)
    return root
}

func checkContainment(_ root: String, inputs: Set<String>, what: String) {
    fzCheck(names(root) == ["in", "out"], "escape-work-root", "\(what): \(names(root))")
    fzCheck(names(root + "/out") == ["canary", "target"], "escape-next-to-target", "\(what): \(names(root + "/out"))")
    fzCheck(names(root + "/out/canary") == ["keep.txt"], "escape-into-canary", "\(what): \(names(root + "/out/canary"))")
    fzCheck(fm.contents(atPath: root + "/out/canary/keep.txt") == canaryText, "escape-canary-changed", what)
    fzCheck(Set(names(root + "/in")).isSubset(of: inputs), "stray-next-to-input", "\(what): \(names(root + "/in"))")
    // What was written is plain files directly in the target.
    for name in names(root + "/out/target") {
        var st = stat()
        if lstat(root + "/out/target/" + name, &st) == 0 { fzCheck(st.st_mode & S_IFMT == S_IFREG, "target-not-a-plain-file", "\(what): \(name)") }
    }
}

func item(_ path: String) -> FileItem? { registry.item(at: URL(fileURLWithPath: path)) }

// MARK: checksum files

let checksumNames = ["x.sfv", "x.md5", "x.sha1", "x.sha256", "x.sha512", "x.sha224", "x.sha384", "x.sha3", "x.b3", "x.bk3", "SHA256SUMS", "x.sha", "x.txt"]

let checksum = FuzzTarget("checksum", maxLen: 4096,
    dict: ["; comment\n", " *", "  ", "\\", "\\\\", "\\n", "\\r", "MD5 (", "SHA256 (", "SHA1(", "BLAKE3 (", ") = ", "d41d8cd98f00b204e9800998ecf8427e", "da39a3ee5e6b4b0d3255bfef95601890afd80709", "00000000", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "\r\n", "\u{FEFF}", "../", "/", "a.txt", "..\\", "\t", "*", "#"],
    seeds: { ["; made by x\r\na.txt 3610A686\r\nsub\\b.bin 00000000\r\n", "d41d8cd98f00b204e9800998ecf8427e *a.txt\n86f7e437faa5a7fce15d1ddcb9eaeaea377667b8  sub/b.bin\n", "MD5 (a.txt) = d41d8cd98f00b204e9800998ecf8427e\nSHA256 (b) = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n", "\\d41d8cd98f00b204e9800998ecf8427e  a\\nb\\\\c.txt\n", "da39a3ee5e6b4b0d3255bfef95601890afd80709  /etc/hosts\n3610a686  ../canary/keep.txt\n"].map { Array($0.utf8) }
        + [[0xFF, 0xFE] + Array("a.txt 3610A686\n".utf16).flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }, [0xEF, 0xBB, 0xBF] + Array("ä.txt 00000000\n".utf8)] },
    run: { bytes in
        let decoded = ChecksumFile.text(from: Data(bytes))
        for name in checksumNames {
            let entries = ChecksumFile.parse(decoded, fileName: name)
            for e in entries { fzCheck(!e.name.isEmpty, "checksum-empty-name", "\(name): \(e)") }
        }
        _ = ChecksumFile.method(forFileNamed: decoded); _ = ChecksumFile.isChecksumFile(String(decoded.prefix(300)), extraMasks: String(decoded.suffix(60)))
        _ = ChecksumRun.checksumInName(decoded); _ = ChecksumRun.checksum(fromClipboard: decoded)
        _ = Splitter.size(from: String(decoded.prefix(64)))
    })

/// The whole of Verify: the checksum file lies next to two real files.
let verify = FuzzTarget("verify", maxLen: 2048,
    dict: ["a.txt", "sub/b.bin", "sub\\b.bin", "3610a686", "d41d8cd98f00b204e9800998ecf8427e", " *", "  ", "\n", "../out/canary/keep.txt", "/", "MD5 (", ") = ", "\\"],
    seeds: { ["a.txt 4a17b156\r\nsub\\b.bin 00000000\r\nmissing 12345678\r\n", "5eb63bbbe01eeed093cb22bb8f5acdc3 *a.txt\nd41d8cd98f00b204e9800998ecf8427e  sub/b.bin\n", "MD5 (a.txt) = 5eb63bbbe01eeed093cb22bb8f5acdc3\n", "2aae6c35c94fcfb415dbe95f408b9ce91ee846ed  ../out/canary/keep.txt\n"].map { [UInt8($0.utf8.count % 13)] + Array($0.utf8) } },
    setUp: setUpTools,
    run: { bytes in
        guard let first = bytes.first else { return }
        let root = prepare()
        let name = checksumNames[Int(first) % checksumNames.count]
        fm.createFile(atPath: root + "/in/a.txt", contents: Data("hello world".utf8))
        try? fm.createDirectory(atPath: root + "/in/sub", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/in/sub/b.bin", contents: Data())
        fm.createFile(atPath: root + "/in/" + name, contents: Data(bytes.dropFirst()))
        guard let file = item(root + "/in/" + name) else { return }
        let run = ToolRun(fileSystems: registry)
        if let report = try? ChecksumRun.verify(checksumFiles: [file], run: run) {
            _ = report.text(onlyErrors: false); _ = report.text(onlyErrors: true)
        }
        checkContainment(root, inputs: ["a.txt", "sub", name], what: "verify")
    })

// MARK: decoders

final class MemorySink: DecodeSink {
    var files: [(name: String?, bytes: Int)] = []
    var open = false
    func begin(name: String?) throws {
        fzCheck(!open, "decode-begin-while-open", "")
        open = true; files.append((name, 0))
        if let safe = Decoder.safeName(name) {
            // By bytes: a `/` that carries a combining mark is still a separator to the file system.
            let raw = Array(safe.utf8)
            fzCheck(!raw.contains(0x2F) && raw != [0x2E] && raw != [0x2E, 0x2E] && !raw.isEmpty && !raw.contains(0) && raw.count <= 255, "decode-unsafe-name", "\(String(describing: name).debugDescription) -> \(safe.debugDescription)")
        }
    }
    func write(_ bytes: [UInt8]) throws { fzCheck(open, "decode-write-without-file", ""); files[files.count - 1].bytes += bytes.count }
    func end() throws { fzCheck(open, "decode-end-without-file", ""); open = false }
}

let decodeDict = ["begin 644 ", "begin 0 ", "end\n", "`\n", "=ybegin part=1 total=2 line=128 size=5 name=", "=ypart begin=1 end=5\n", "=yend size=5 part=1 pcrc32=", "=yend size=5 crc32=00000000\n", "=ybegin line=128 size=99999999999999999999 name=",
                  "Content-Type: multipart/mixed; boundary=\"b\"\n", "Content-Transfer-Encoding: base64\n", "Content-Disposition: attachment; filename=\"", "name=\"", "filename*=UTF-8''", "MIME-Version: 1.0\n", "--b\n", "--b--\n", "\n\n", "\r\n", "=", "==", "M", "../", "/", "\\", "..", "\"", "begin-base64 644 ", "====\n", "xbtoa Begin\n", "+", "table\n", "section 1 of 2", "\u{0}"]

func decodeSeeds() -> [[UInt8]] {
    let payload = Data((0..<200).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    var seeds: [String] = []
    seeds.append("MIME-Version: 1.0\r\nContent-Type: application/octet-stream; name=\"a.bin\"\r\nContent-Transfer-Encoding: base64\r\nContent-Disposition: attachment; filename=\"a.bin\"\r\n\r\n" + payload.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) + "\r\n")
    seeds.append(String(decoding: SixBitText.encode(payload, xx: false), as: UTF8.self).isEmpty ? "" : "begin 644 a.bin\r\n" + String(decoding: SixBitText.encode(payload, xx: false), as: UTF8.self) + "`\r\nend\r\n")
    seeds.append("begin 644 a.bin\r\n" + String(decoding: SixBitText.encode(payload, xx: true), as: UTF8.self) + "+\r\nend\r\n")
    seeds.append("begin 644 ../canary/pwn.txt\n#0V%T\n`\nend\n")
    seeds.append("begin 644 /abs/../../canary/pwn.txt\n#0V%T\n`\nend\nbegin 600 ..\n#0V%T\n`\nend\nbegin 600 a:b\\c\n#0V%T\n`\nend\n")
    seeds.append("=ybegin line=128 size=3 name=../canary/y.bin\r\n\u{8D}\u{8F}\u{9E}\r\n=yend size=3 crc32=00000000\r\n")
    seeds.append("=ybegin part=1 total=2 line=128 size=6 name=two.bin\r\n=ypart begin=1 end=3\r\nabc\r\n=yend size=3 part=1 pcrc32=00000000\r\n=ybegin part=2 total=2 line=128 size=6 name=two.bin\r\n=ypart begin=4 end=6\r\ndef=J\r\n=yend size=3 part=2\r\n")
    seeds.append("From: x\nContent-Type: multipart/mixed; boundary=\"b\"\n\n--b\nContent-Type: text/plain\n\nhello\n--b\nContent-Transfer-Encoding: base64\nContent-Disposition: attachment; filename=\"../canary/m.txt\"\n\naGVsbG8=\n--b\nContent-Transfer-Encoding: base64\nContent-Type: image/png; name=\"second.png\"\n\naGVsbG8gd29ybGQ=\n--b--\n")
    seeds.append("begin-base64 644 b.txt\naGVsbG8=\n====\n")
    seeds.append("aGVsbG8gd29ybGQ=\n")
    seeds.append("begin 644 first.bin\nM" + String(repeating: "A", count: 60) + "\n\u{1C}M" + String(repeating: "B", count: 60) + "\n`\nend\n")
    return seeds.map { Array($0.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }) }
}

/// The decoders alone, into memory: fast.
let decodeMemory = FuzzTarget("decodemem", maxLen: 4096, dict: decodeDict, seeds: decodeSeeds,
    run: { bytes in
        let sink = MemorySink()
        let machine = DecodeMachine(sink: sink)
        var total = 0
        do {
            for var line in bytes.split(separator: 10, omittingEmptySubsequences: false) {
                if line.last == 13 { line = line.dropLast() }
                _ = DecodeMachine.startsNewFile(line)
                try machine.feed(line)
            }
            try machine.finish()
        } catch {}
        total = sink.files.reduce(0) { $0 + $1.bytes }
        // Nothing decodes into more than it was.
        fzCheck(total <= bytes.count + 16, "decode-grows", "\(total) bytes out of \(bytes.count)")
        for line in bytes.split(separator: 10).prefix(4) { _ = SixBitText.decode(line, xx: false); _ = SixBitText.decode(line, xx: true) }
        let name = text(Array(bytes.prefix(80)))
        _ = Decoder.safeName(name); _ = Decoder.fallbackName(for: name)
        for method in EncodeMethod.allCases { _ = Encoder.outputNames(for: name, method: method, parts: 1 + bytes.count % 3); _ = Encoder.header(for: name, method: method) }
    })

/// Decode as the command does it: from files in a folder (the input may hold several parts,
/// separated by the byte 0x1C) into a target folder.
let decodeFiles = FuzzTarget("decode", maxLen: 4096, dict: decodeDict + ["\u{1C}"], seeds: { decodeSeeds().map { [0] + $0 } },
    setUp: setUpTools,
    run: { bytes in
        guard let first = bytes.first else { return }
        let root = prepare()
        let ext = ["b64", "uue", "xxe", "ntx", "txt", "001"][Int(first) % 6]
        let parts = bytes.dropFirst().split(separator: 0x1C, maxSplits: 3, omittingEmptySubsequences: false)
        var inputs = Set<String>()
        for (index, part) in parts.enumerated() {
            let name = ext == "001" ? String(format: "part.%03d", index + 1) : String(format: "part%03d.%@", index + 1, ext)
            fm.createFile(atPath: root + "/in/" + name, contents: Data(part))
            inputs.insert(name)
        }
        guard let firstItem = item(root + "/in/" + inputs.sorted()[0]) else { return }
        for autoRename in [false, true] {
            let run = ToolRun(fileSystems: registry)
            let written = (try? Decoder.decode(firstItem, into: URL(fileURLWithPath: root + "/out/target"), autoRename: autoRename, run: run)) ?? []
            for url in written { fzCheck(url.deletingLastPathComponent().path == root + "/out/target", "decode-wrote-elsewhere", url.path) }
            checkContainment(root, inputs: inputs, what: "decode autoRename=\(autoRename)")
        }
    })

// MARK: split and combine

let splitCombine = FuzzTarget("combine", maxLen: 1024,
    dict: ["filename=", "size=", "crc32=", "\r\n", "\n", "=", "../", "/", "\\", "..", "data.001", "data.crc", "FFFFFFFF", "-1", "9223372036854775807", "9223372036854775808", "0x", "+", " ", "\u{2028}", "\u{85}"],
    seeds: { ["filename=whole.bin\r\nsize=6\r\ncrc32=4B8E39EF\r\n", "filename=../canary/pwn.bin\nsize=6\ncrc32=0\n", "FILENAME=/abs/x\nSIZE=-1\nCRC32=FFFFFFFFF\n", "filename=data.001\nsize=6\ncrc32=4B8E39EF\n", "filename=..\nsize=1\ncrc32=1\n", "size=6\ncrc32=1\nfilename=a\\b/c:d\n"].map { Array($0.utf8) } },
    setUp: setUpTools,
    run: { bytes in
        let info = SplitInfo(text: text(bytes))
        if let info { _ = info.text; fzCheck(SplitInfo(text: info.text) == info || info.name.contains(where: \.isNewline) || info.name.contains("="), "splitinfo-roundtrip", "\(info)") }
        let root = prepare()
        fm.createFile(atPath: root + "/in/data.001", contents: Data("abc".utf8))
        fm.createFile(atPath: root + "/in/data.002", contents: Data("def".utf8))
        fm.createFile(atPath: root + "/in/data.crc", contents: Data(bytes))
        let inputs: Set<String> = ["data.001", "data.002", "data.crc"]
        for start in ["data.crc", "data.001"] {
            guard let it = item(root + "/in/" + start) else { continue }
            let run = ToolRun(fileSystems: registry)
            guard let plan = try? Combiner.plan(for: it, run: run) else { continue }
            fzCheck(plan.parts.map(\.name) == ["data.001", "data.002"], "combine-parts", "\(plan.parts.map(\.name))")
            for target in [root + "/out/target", root + "/in"] {
                if let outcome = try? Combiner.combine(plan.parts, info: plan.info, into: URL(fileURLWithPath: target), run: run) {
                    fzCheck(outcome.output.deletingLastPathComponent().path == target, "combine-wrote-elsewhere", outcome.output.path)
                    fzCheck(fm.contents(atPath: outcome.output.path) == Data("abcdef".utf8), "combine-content", outcome.output.path)
                    if target.hasSuffix("/in") { try? fm.removeItem(at: outcome.output) }
                }
                fzCheck(fm.contents(atPath: root + "/in/data.001") == Data("abc".utf8) && fm.contents(atPath: root + "/in/data.002") == Data("def".utf8), "combine-damaged-a-part", "into \(target)")
            }
            checkContainment(root, inputs: inputs, what: "combine from \(start)")
        }
    })

/// Part discovery by names alone: the row a name starts ends, and never names a path.
let partSeries = FuzzTarget("parts", maxLen: 512,
    dict: [".001", ".999", "aa", "zz", "az", ".", "9", "0", "99999999999999999", "999999999999999999", "9999999999999999999", ".crc", ".b64", "٣", "é", "/", "\u{0}"],
    seeds: { ["file.001", "file.999", "xaa", "xzz", "part01.rar", "IMG_0099.b64", "name.7z.009", "a9.99", "zz", "٣٣.٣", "000000000000000000.x", "999999999999999999"].map { Array($0.utf8) } },
    setUp: setUpTools,
    run: { bytes in
        for raw in bytes.split(separator: 10).prefix(4) {
            let name = text(Array(raw))
            var current = name, steps = 0
            var seen = Set<String>([name])
            while let next = PartSeries.next(after: current), steps < 3000 {
                fzCheck(seen.insert(next).inserted, "parts-cycle", "\(name.debugDescription) comes back to \(next.debugDescription)")
                fzCheck(next.utf8.count == current.utf8.count, "parts-length-changes", "\(current.debugDescription) -> \(next.debugDescription)")
                current = next; steps += 1
            }
            let whole = PartSeries.combinedName(forPart: name)
            fzCheck(!whole.isEmpty || name.isEmpty, "parts-empty-combined-name", name.debugDescription)
            _ = Splitter.partName(name, raw.count); _ = Splitter.size(from: name)
        }
        // In a folder: files named by the input's lines.
        let lines = bytes.split(separator: 10).prefix(6).map { text(Array($0)) }.filter { !$0.isEmpty && !$0.contains("/") && !$0.contains("\0") && $0 != "." && $0 != ".." && $0.utf8.count < 200 }
        guard !lines.isEmpty else { return }
        let dir = fzWorkDir + "/p"
        try? fm.removeItem(atPath: dir)
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for l in lines { fm.createFile(atPath: dir + "/" + l, contents: Data("x".utf8)) }
        for l in lines {
            guard let it = item(dir + "/" + l) else { continue }
            let parts = PartSeries.parts(startingAt: it, provider: local)
            fzCheck(parts.count <= lines.count + 1 && Set(parts.map(\.name)).count == parts.count, "parts-row", "\(parts.map(\.name))")
        }
    })

fuzzMain([checksum, verify, decodeMemory, decodeFiles, splitCombine, partSeries])
