import AFMContracts
import AFMKernel
import AppKit
@testable import FileToolsPlugin
import LocalFileSystemPlugin
import TestSupport
import Testing

/// Create and Verify checksums through the plugin's commands, compared with `md5`, `shasum`
/// and `cksum`.
@MainActor @Suite struct FileToolsChecksums {
    let memory = MemoryFileSystem()
    let box: Sandbox
    let settings = MemorySettings()
    let pasteboard = NSPasteboard.withUniqueName()
    let bench: TestBench

    var ui: ScriptedInteraction { bench.ui }
    var left: FakePanel { bench.left }

    init() throws {
        box = try Sandbox()
        try box.file("work/a.txt", "alpha")
        try box.file("work/b b.txt", "beta")
        try box.file("work/sub/c.txt", "gamma")
        try box.file("work/sub/deep/d.txt", "delta")
        try box.folder("other")
        bench = TestBench(plugins: [FileToolsPlugin(pasteboard: pasteboard)], fileSystems: [LocalFileSystem(), memory],
                          left: box.url("work"), right: box.url("other"), settings: settings)
    }

    func select(_ names: [String]) {
        left.reload()
        left.model.clearSelection()
        for name in names {
            if let row = left.model.row(ofName: name) { left.model.setSelected(true, rows: row...row) }
        }
        if let first = names.first { left.moveCursor(toName: first) }
    }

    func create(_ names: [String], _ values: [String: FormValues.Value] = [:]) {
        select(names)
        ui.formAnswers = [.values(values)]
        #expect(bench.commands.perform(.createChecksums))
    }

    /// Runs Verify and returns the window's title and text (shown in a form, there being no viewer).
    func verify(_ names: [String]) -> (title: String, text: String) {
        select(names)
        ui.formAnswers = [.accept]
        let shown = ui.forms.count
        #expect(bench.commands.perform(.verifyChecksums))
        guard ui.forms.count > shown, case .multilineText(let text)? = ui.forms.last?.first?.kind else { return (ui.log.last ?? "", "") }
        return (String((ui.log.last ?? "").dropFirst("form: ".count)), text)
    }

    func method(_ method: ChecksumMethod) -> FormValues.Value { .index(ChecksumMethod.dialogOrder.firstIndex(of: method) ?? 0) }
    func digest(_ tool: String, _ arguments: [String], _ path: String) throws -> String {
        String(try systemTool(tool, arguments + [box.url(path).path]).output.split(whereSeparator: { $0 == " " || $0 == "\n" }).first ?? "")
    }

    // MARK: Create

    @Test func proposalsAndDialog() {
        select(["a.txt"])
        ui.formAnswers = [.cancel]
        bench.commands.perform(.createChecksums)
        #expect(ui.forms.last?.first?.initialValue == .text(box.url("work/a.txt.sfv").path))
        #expect(ui.forms.last?.map(\.key).prefix(6) == ["target", "separateFiles", "separateFolders", "utf8", "unix", "method"])
        #expect(ui.log.last == "form: Create CRC-checksum file" && namesOnDisk(box.url("work")).count == 3)
        // Several items: the folder's name. The last method is proposed again.
        create(["a.txt", "b b.txt"], ["method": method(.md5)])
        #expect(box.exists("work/work.md5") && settings.index(FileTools.Keys.checksumMethod, default: 0) == ChecksumMethod.md5.rawValue)
        select(["a.txt", "sub"])
        ui.formAnswers = [.cancel]
        bench.commands.perform(.createChecksums)
        #expect(ui.forms.last?.first?.initialValue == .text(box.url("work/work.md5").path))
        #expect(ui.forms.last?[5].initialValue == method(.md5))
    }

    @Test func md5FileMatchesTheSystemTool() throws {
        create(["a.txt", "b b.txt"], ["method": method(.md5)])
        let expected = try ["a.txt", "b b.txt"].map { "\(try digest("/sbin/md5", ["-q"], "work/" + $0)) *\($0)\n" }.joined()
        #expect(box.read("work/work.md5") == expected)
        // After creation the selection is cleared, and the panel shows the new file.
        #expect(left.model.selection.isEmpty && left.names.contains("work.md5"))
        #expect(bench.jobService.titles == ["Creating checksums:"] && bench.jobService.reports.last?.itemsDone == 2)
    }

    @Test(arguments: [(ChecksumMethod.sha1, "1"), (.sha224, "224"), (.sha256, "256"), (.sha384, "384"), (.sha512, "512")])
    func shaFilesAreAcceptedByShasum(method chosen: ChecksumMethod, algorithm: String) throws {
        // Folders are walked recursively, in the panel's order (folders first); names are relative to the checksum file.
        create(["a.txt", "b b.txt", "sub"], ["method": method(chosen)])
        let name = "work." + chosen.fileExtension
        let lines = (box.read("work/" + name) ?? "").split(separator: "\n").map(String.init)
        #expect(lines.map { String($0.split(separator: "*", maxSplits: 1).last ?? "") } == ["sub/c.txt", "sub/deep/d.txt", "a.txt", "b b.txt"])
        #expect(lines.last == "\(try digest("/usr/bin/shasum", ["-a", algorithm], "work/b b.txt")) *b b.txt")
        let check = try systemTool("/usr/bin/shasum", ["-a", algorithm, "-c", name], in: box.url("work"))
        #expect(check.status == 0 && check.output.components(separatedBy: ": OK").count == 5)
    }

    @Test func sfvFileMatchesCksum() throws {
        create(["a.txt", "b b.txt"])
        let crcs = try ["a.txt", "b b.txt"].map { String(format: "%08X", UInt32(try digest("/usr/bin/cksum", ["-o", "3"], "work/" + $0)) ?? 0) }
        #expect(box.read("work/work.sfv") == "a.txt \(crcs[0])\nb b.txt \(crcs[1])\n")
    }

    @Test func everyMethodRoundTripsThroughVerify() {
        for chosen in ChecksumMethod.allCases {
            create(["a.txt", "sub"], ["method": method(chosen), "target": .text(box.url("work/all." + chosen.fileExtension).path)])
            let result = verify(["all." + chosen.fileExtension])
            #expect(result.title == "\(chosen.reportName): Errors: 0", "\(chosen)")
            #expect(result.text.hasSuffix("Errors: 0\nOK: 3, not found: 0, read error: 0, wrong checksum: 0\n"), "\(chosen)")
        }
    }

    @Test func windowsFormatAndUnicodeNames() throws {
        try box.file("work/sub/ünï.txt", "x")
        create(["sub"], ["unix": .flag(false), "method": method(.md5), "target": .text(box.url("work/win.md5").path)])
        let data = try Data(contentsOf: box.url("work/win.md5"))
        // Back slashes, CRLF, and the mark that tells the original the names are UTF-8.
        #expect(data.starts(with: [0xEF, 0xBB, 0xBF]))
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        #expect(text.components(separatedBy: "\r\n").map { String($0.split(separator: "*").last ?? "") } == ["sub\\c.txt", "sub\\deep\\d.txt", "sub\\ünï.txt", ""])
        #expect(verify(["win.md5"]).title == "MD5: Errors: 0")
        #expect(settings.flag(FileTools.Keys.unixFormat, default: true) == false)

        create(["a.txt"], ["unix": .flag(true), "method": method(.md5), "target": .text(box.url("work/plain.md5").path)])
        #expect(!(try Data(contentsOf: box.url("work/plain.md5"))).starts(with: [0xEF, 0xBB, 0xBF]))
        create(["a.txt"], ["utf8": .flag(true), "method": method(.md5), "target": .text(box.url("work/marked.md5").path)])
        #expect((try Data(contentsOf: box.url("work/marked.md5"))).starts(with: [0xEF, 0xBB, 0xBF]))
        #expect(ChecksumFile.needsByteOrderMark(names: ["ä"], unixFormat: true, alwaysUTF8: false) == false)
        #expect(ChecksumFile.needsByteOrderMark(names: ["a"], unixFormat: false, alwaysUTF8: false) == false)
    }

    @Test func separateFilesPerFileAndPerFolder() {
        #expect(ChecksumRun.separateName(for: "test.txt", pattern: "*.*.sfv", method: .crc32) == "test.txt.sfv")
        #expect(ChecksumRun.separateName(for: "test.txt", pattern: "*.sfv", method: .crc32) == "test.sfv")
        #expect(ChecksumRun.separateName(for: "test.txt", pattern: "*.*", method: .md5) == "test.txt.md5")
        // Without a `*` in the name the proposal of the preference is used: the extension is added…
        create(["a.txt", "b b.txt"], ["separateFiles": .flag(true), "method": method(.sha1)])
        #expect(namesOnDisk(box.url("work")).filter { $0.hasSuffix(".sha") } == ["a.txt.sha", "b b.txt.sha"])
        #expect(box.read("work/a.txt.sha")?.hasSuffix(" *a.txt\n") == true)
        // …or put in place of the file's own, and the files go where the target says.
        settings.set(false, forKey: FileTools.Keys.appendExtension)
        create(["a.txt", "sub"], ["separateFiles": .flag(true), "method": method(.sha1), "target": .text(box.url("other/x.sha").path)])
        #expect(namesOnDisk(box.url("other")) == ["a.sha", "c.sha", "d.sha"])
        // Elsewhere than above the files, the names carry no path.
        #expect(box.read("other/d.sha")?.hasSuffix(" *d.txt\n") == true)
        create(["b b.txt"], ["separateFiles": .flag(true), "method": method(.sha1), "target": .text(box.url("other/*.*.sum").path)])
        #expect(box.exists("other/b b.txt.sum"))

        // One file per folder, in that folder, whatever the target says.
        create(["a.txt", "sub"], ["separateFiles": .flag(false), "separateFolders": .flag(true), "method": method(.md5),
                                  "target": .text(box.url("other/ignored.md5").path)])
        #expect(box.exists("work/work.md5") && box.exists("work/sub/sub.md5") && box.exists("work/sub/deep/deep.md5") && !box.exists("other/ignored.md5"))
        #expect(box.read("work/sub/sub.md5")?.hasSuffix(" *c.txt\n") == true)
        #expect(verify(["work.md5"]).title == "MD5: Errors: 0")
    }

    @Test func createOnAnotherFileSystemAndFailures() {
        memory.addFile("/data/one.bin", "1")
        memory.addFile("/data/two.bin", "2")
        left.show(memory.url("/data"))
        create(["one.bin", "two.bin"], ["method": method(.blake3)])
        #expect(memory.contents("/data/data.bk3")?.split(separator: "\n").map { $0.suffix(9) } == ["*one.bin", "*two.bin"].map { Substring(" " + $0) })
        // An existing checksum file is asked about; Cancel keeps it.
        create(["one.bin"], ["method": method(.blake3), "target": .text("mem:/data/data.bk3")])
        #expect(memory.contents("/data/data.bk3")?.contains("two.bin") == true)
        ui.choiceAnswers = [0]
        create(["one.bin"], ["method": method(.blake3), "target": .text("mem:/data/data.bk3")])
        #expect(memory.contents("/data/data.bk3")?.contains("two.bin") == false)
        // An empty folder has nothing to hash.
        memory.addDirectory("/data/empty")
        create(["empty"])
        #expect(ui.log.last == "inform: Create CRC-checksum file" && !memory.exists("/data/data.sfv"))
    }

    // MARK: Reading checksum files

    @Test func lineFormats() {
        typealias Entry = ChecksumFile.Entry
        let md5 = String(repeating: "ab", count: 16), sha256 = String(repeating: "CD", count: 32)
        #expect(ChecksumFile.parse("\(md5) *a b.txt\r\n\(md5)  text.txt\n; comment\n# another\n\nrubbish line\n", fileName: "x.md5")
                == [Entry(name: "a b.txt", digest: md5, method: .md5), Entry(name: "text.txt", digest: md5, method: .md5)])
        #expect(ChecksumFile.parse("file one.bin 1A2B3C4D\ndeadbeef 00112233\ncafe.txt\tFFFFFFFF", fileName: "x.sfv")
                == [Entry(name: "file one.bin", digest: "1a2b3c4d", method: .crc32), Entry(name: "deadbeef", digest: "00112233", method: .crc32),
                    Entry(name: "cafe.txt", digest: "ffffffff", method: .crc32)])
        #expect(ChecksumFile.parse("SHA256(my (1).bin)= \(sha256)\nMD5 (b.txt) = \(md5)\nSHA3-256(c)= \(sha256)\nSHA256(short)= abcd", fileName: "sums.txt")
                == [Entry(name: "my (1).bin", digest: sha256.lowercased(), method: .sha256), Entry(name: "b.txt", digest: md5, method: .md5),
                    Entry(name: "c", digest: sha256.lowercased(), method: .sha3_256)])
        // The checksum of a stream stands for the file the checksum file is named after.
        #expect(ChecksumFile.parse("\(sha256)  -", fileName: "disk.img.sha256") == [Entry(name: "disk.img", digest: sha256.lowercased(), method: .sha256)])
        // Without a telling extension the length decides, and several methods may fit.
        #expect(ChecksumFile.parse("\(sha256) *a", fileName: "sums.txt") == [Entry(name: "a", digest: sha256.lowercased(), method: nil)])
        #expect(ChecksumFile.parse("\(md5) *a", fileName: "x.sha256") == [Entry(name: "a", digest: md5, method: nil)])
        #expect(ChecksumFile.method(forFileNamed: "A.SHA") == .sha1 && ChecksumFile.method(forFileNamed: "a.sha3-512") == .sha3_512)
        #expect(ChecksumFile.method(forFileNamed: "a.bk3") == .blake3 && ChecksumFile.method(forFileNamed: "a.txt") == nil)
        #expect(ChecksumFile.isChecksumFile("x.SFV") && ChecksumFile.isChecksumFile("x.sha512") && !ChecksumFile.isChecksumFile("x.sum"))
        #expect(ChecksumFile.isChecksumFile("x.sum", extraMasks: "*.sum *.crc32"))
        #expect(ChecksumFile.line(name: "n", digest: [0xAB, 0x01], method: .md5) == "ab01 *n" && ChecksumFile.line(name: "n", digest: [0xAB, 0x01], method: .crc32) == "n AB01")
    }

    @Test func encodingsOfChecksumFiles() {
        let line = "ä.txt 00000000\n"
        #expect(ChecksumFile.text(from: Data([0xEF, 0xBB, 0xBF]) + Data(line.utf8)) == line)
        #expect(ChecksumFile.text(from: Data(line.utf8)) == line)
        #expect(ChecksumFile.text(from: line.data(using: .utf16) ?? Data()) == line)
        #expect(ChecksumFile.text(from: "ab\n ".data(using: .utf16LittleEndian) ?? Data()) == "ab\n ")
        #expect(ChecksumFile.text(from: "ab".data(using: .utf16BigEndian) ?? Data()) == "ab")
        #expect(ChecksumFile.text(from: line.data(using: .windowsCP1252) ?? Data()) == line)
    }

    // MARK: Verify

    @Test func verifyReportsOkMissingAndWrong() throws {
        create(["a.txt", "b b.txt", "sub"], ["method": method(.md5)])
        try "changed".write(to: box.url("work/b b.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: box.url("work/sub/c.txt"))
        let result = verify(["work.md5"])
        #expect(result.title == "MD5: Errors: 2")
        #expect(result.text == """
        work.md5:
        Cannot open input file sub/c.txt!
        OK:  sub/deep/d.txt
        OK:  a.txt
        Wrong checksum: b b.txt!

        Errors: 2
        OK: 2, not found: 1, read error: 0, wrong checksum: 1

        """)
        // The failures that are in the panel are marked there.
        #expect(left.model.selection == ["b b.txt"])
        #expect(bench.jobService.titles.last == "Verifying checksums:")
        settings.set(true, forKey: FileTools.Keys.onlyErrors)
        #expect(verify(["work.md5"]).text.hasPrefix("work.md5:\nCannot open input file sub/c.txt!\nWrong checksum: b b.txt!\n\nErrors: 2\n"))
    }

    @Test func verifiesFilesWrittenByTheSystemTools() throws {
        let work = box.url("work")
        try Data(try systemTool("/usr/bin/shasum", ["-a", "256", "a.txt", "b b.txt", "sub/c.txt"], in: work).output.utf8).write(to: box.url("work/tool.sha256"))
        try Data(try systemTool("/sbin/md5", ["a.txt", "b b.txt"], in: work).output.utf8).write(to: box.url("work/bsd.md5"))
        try Data(try systemTool("/usr/bin/shasum", ["-a", "512", "--tag", "a.txt"], in: work).output.utf8).write(to: box.url("work/tagged.txt"))
        try Data(try systemTool("/usr/bin/shasum", ["-a", "1", "-b", "sub/deep/d.txt"], in: work).output.utf8).write(to: box.url("work/binary.sha"))
        let both = verify(["tool.sha256", "bsd.md5", "binary.sha"])
        #expect(both.title == "Checksums: Errors: 0")
        #expect(both.text == """
        binary.sha:
        OK:  sub/deep/d.txt

        bsd.md5:
        OK:  a.txt
        OK:  b b.txt

        tool.sha256:
        OK:  a.txt
        OK:  b b.txt
        OK:  sub/c.txt

        Errors: 0
        OK: 6, not found: 0, read error: 0, wrong checksum: 0

        """)
        // A file with another extension is a checksum file once its mask is configured.
        #expect(verify(["tagged.txt"]).title == "inform: Please select only SFV, MD5 or SHA files!")
        settings.set("*.sum tagged.*", forKey: FileTools.Keys.extraTypes)
        #expect(verify(["tagged.txt"]).title == "SHA2_512: Errors: 0")
        // Windows paths in a checksum file are followed too.
        try box.file("work/win.sfv", "sub\\c.txt 00000000\r\n")
        #expect(verify(["win.sfv"]).text.contains("Wrong checksum: sub\\c.txt!"))
    }

    @Test func verifyAgainstTheClipboardAndTheFileName() throws {
        let sha256 = try digest("/usr/bin/shasum", ["-a", "256"], "work/a.txt")
        pasteboard.clearContents()
        pasteboard.setString("  \(sha256.uppercased())\n", forType: .string)
        var result = verify(["a.txt"])
        #expect(result.title == "SHA2_256: Errors: 0" && result.text.hasPrefix("Checksum from the clipboard:\nOK:  a.txt\n"))
        #expect(verify(["b b.txt"]).title == "SHA2_256: Errors: 1")
        // SHA-3 and BLAKE3 have the same length; whichever fits is found.
        let hasher = ChecksumMethod.sha3_256.makeHasher()
        hasher.update(Data("alpha".utf8))
        pasteboard.clearContents()
        pasteboard.setString(hasher.finish().hex, forType: .string)
        #expect(verify(["a.txt"]).title == "SHA3_256: Errors: 0")
        pasteboard.clearContents()
        pasteboard.setString("not a checksum", forType: .string)
        #expect(verify(["a.txt"]).title == "inform: Please select only SFV, MD5 or SHA files!")

        // A CRC32 in square brackets in the name.
        let crc = String(format: "%08X", UInt32(try digest("/usr/bin/cksum", ["-o", "3"], "work/a.txt")) ?? 0)
        try box.file("work/Movie [\(crc)].mkv", "alpha")
        try box.file("work/Other [00000000].mkv", "alpha")
        result = verify(["Movie [\(crc)].mkv", "Other [00000000].mkv"])
        #expect(result.title == "CRC32: Errors: 1")
        #expect(result.text.hasPrefix("Checksums in the file names:\nOK:  Movie [\(crc)].mkv\nWrong checksum: Other [00000000].mkv!\n"))
        #expect(left.model.selection == ["Other [00000000].mkv"])
        #expect(ChecksumRun.checksumInName("x [1a2B3c4D] y.z") == "1a2b3c4d" && ChecksumRun.checksumInName("x [123].z") == nil)
        #expect(ChecksumRun.checksum(fromClipboard: "ABCDEF12") == "abcdef12" && ChecksumRun.checksum(fromClipboard: "ABCDEF123") == nil)
    }

    @Test func verifyManyFilesOnAnotherFileSystem() {
        var lines = ""
        for index in 0..<200 {
            let content = "file number \(index)"
            memory.addFile("/big/f\(index).dat", content)
            let hasher = ChecksumMethod.sha1.makeHasher()
            hasher.update(Data((index == 77 ? "tampered" : content).utf8))
            lines += "\(hasher.finish().hex) *f\(index).dat\n"
        }
        memory.addFile("/big/all.sha", lines)
        left.show(memory.url("/big"))
        let result = verify(["all.sha"])
        #expect(result.title == "SHA1: Errors: 1")
        let rows = result.text.split(separator: "\n").map(String.init)
        // The rows come in the order of the checksum file, though the files were hashed side by side.
        #expect(rows.count == 203 && rows[1] == "OK:  f0.dat" && rows[78] == "Wrong checksum: f77.dat!" && rows[200] == "OK:  f199.dat")
        #expect(left.model.selection == ["f77.dat"])
    }
}
