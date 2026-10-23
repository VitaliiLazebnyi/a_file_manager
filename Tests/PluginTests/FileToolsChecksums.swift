import AFMContracts
import AFMKernel
import AppKit
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileToolsPlugin

/// Create and Verify checksums through the plugin's commands, compared with `md5`, `shasum`
/// and `cksum`.
@MainActor
@Suite
internal struct FileToolsChecksums {
    /// A file system in memory, for files elsewhere than on disk.
    internal let memory = MemoryFileSystem()
    /// The folders on disk: `work` with four files below it, and `other`.
    internal let box: Sandbox
    /// The settings of the bench.
    internal let settings = MemorySettings()
    /// A pasteboard of the test's own, for the checksum Verify finds there.
    private let scratch = ScratchPasteboard()
    /// The pasteboard the plugin reads.
    internal var pasteboard: NSPasteboard { scratch.pasteboard }
    /// The kernel with the plugin, its left panel on `work`.
    internal let bench: TestBench

    /// The dialogs and messages of the bench, answered by script.
    internal var interaction: ScriptedInteraction { bench.interaction }
    /// The left panel.
    internal var left: FakePanel { bench.left }

    /// A bench on the folders `work` and `other`.
    internal init() throws {
        box = try Sandbox()
        try box.file("work/a.txt", "alpha")
        try box.file("work/b b.txt", "beta")
        try box.file("work/sub/c.txt", "gamma")
        try box.file("work/sub/deep/d.txt", "delta")
        try box.folder("other")
        bench = TestBench(
            plugins: [FileToolsPlugin(pasteboard: scratch.pasteboard)],
            fileSystems: [LocalFileSystem(), memory],
            left: box.url("work"),
            right: box.url("other"),
            settings: settings
        )
    }

    /// Selects the entries of `names` in the left panel and puts the cursor on the first.
    internal func select(_ names: [String]) {
        left.reload()
        left.model.clearSelection()
        for name in names {
            if let row = left.model.row(ofName: name) { left.model.setSelected(true, rows: row...row) }
        }
        if let first = names.first { left.moveCursor(toName: first) }
    }

    /// Runs Create checksums on `names`, the dialog answered with `values` (the others as proposed).
    internal func create(_ names: [String], _ values: [String: FormValues.Value]) {
        select(names)
        interaction.formAnswers = [.values(values)]
        #expect(bench.commands.perform(.createChecksums))
    }

    /// Runs Verify and returns the window's title and text (shown in a form, there being no viewer).
    internal func verify(_ names: [String]) -> (title: String, text: String) {
        select(names)
        interaction.formAnswers = [.accept]
        let shown = interaction.forms.count
        #expect(bench.commands.perform(.verifyChecksums))
        guard interaction.forms.count > shown, case .multilineText(let text)? = interaction.forms.last?.first?.kind
        else {
            return (interaction.log.last ?? "", "")
        }
        return (String((interaction.log.last ?? "").dropFirst("form: ".count)), text)
    }

    /// The answer of the dialog's method list that picks `method`.
    internal func method(_ method: ChecksumMethod) -> FormValues.Value {
        .index(ChecksumMethod.dialogOrder.firstIndex(of: method) ?? 0)
    }

    /// The digest a program of macOS prints for the file at `path` of the box.
    internal func digest(_ tool: String, _ arguments: [String], _ path: String) throws -> String {
        let output = try FileToolsFixture.systemTool(tool, arguments + [box.url(path).path], in: nil).output
        return String(output.split { character in character == " " || character == "\n" }.first ?? "")
    }

    // MARK: Create

    /// The dialog proposes a file next to one item, or named after the folder for several, and the last method.
    @Test
    internal func proposalsAndDialog() {
        select(["a.txt"])
        interaction.formAnswers = [.cancel]
        bench.commands.perform(.createChecksums)
        #expect(interaction.forms.last?.first?.initialValue == .text(box.url("work/a.txt.sfv").path))
        #expect(
            interaction.forms.last?.map(\.key).prefix(6) == [
                "target", "separateFiles", "separateFolders", "utf8", "unix", "method"
            ]
        )
        #expect(interaction.log.last == "form: Create CRC-checksum file" && namesOnDisk(box.url("work")).count == 3)
        // Several items: the folder's name. The last method is proposed again.
        create(["a.txt", "b b.txt"], ["method": method(.md5)])
        #expect(
            box.exists("work/work.md5")
                && settings.index(FileTools.Keys.checksumMethod, default: 0) == ChecksumMethod.md5.rawValue
        )
        select(["a.txt", "sub"])
        interaction.formAnswers = [.cancel]
        bench.commands.perform(.createChecksums)
        #expect(interaction.forms.last?.first?.initialValue == .text(box.url("work/work.md5").path))
        #expect(interaction.forms.last?[5].initialValue == method(.md5))
    }

    /// An MD5 file holds what `md5` prints; the selection is cleared and the panel shows the new file.
    @Test
    internal func md5FileMatchesTheSystemTool() throws {
        create(["a.txt", "b b.txt"], ["method": method(.md5)])
        let expected = try ["a.txt", "b b.txt"]
            .map { name in "\(try digest("/sbin/md5", ["-q"], "work/" + name)) *\(name)\n" }
            .joined()
        #expect(box.read("work/work.md5") == expected)
        // After creation the selection is cleared, and the panel shows the new file.
        #expect(left.model.selection.isEmpty && left.names.contains("work.md5"))
        #expect(bench.jobService.titles == ["Creating checksums:"] && bench.jobService.reports.last?.itemsDone == 2)
    }

    /// SHA files list the files below the folders in the panel's order, and `shasum -c` accepts them.
    @Test(arguments: [
        (ChecksumMethod.sha1, "1"), (.sha224, "224"), (.sha256, "256"), (.sha384, "384"), (.sha512, "512")
    ])
    internal func shaFilesAreAcceptedByShasum(method chosen: ChecksumMethod, algorithm: String) throws {
        // Folders are walked recursively, in the panel's order (folders first); names are relative to the
        // checksum file.
        create(["a.txt", "b b.txt", "sub"], ["method": method(chosen)])
        let name = "work." + chosen.fileExtension
        let lines = (box.read("work/" + name) ?? "").split(separator: "\n").map(String.init)
        #expect(
            lines.map { line in String(line.split(separator: "*", maxSplits: 1).last ?? "") } == [
                "sub/c.txt", "sub/deep/d.txt", "a.txt", "b b.txt"
            ]
        )
        #expect(lines.last == "\(try digest("/usr/bin/shasum", ["-a", algorithm], "work/b b.txt")) *b b.txt")
        let check = try FileToolsFixture.systemTool(
            "/usr/bin/shasum",
            ["-a", algorithm, "-c", name],
            in: box.url("work")
        )
        #expect(check.status == 0 && check.output.components(separatedBy: ": OK").count == 5)
    }

    /// An SFV file holds the CRC32 that `cksum -o 3` gives.
    @Test
    internal func sfvFileMatchesCksum() throws {
        create(["a.txt", "b b.txt"], [:])
        let crcs = try ["a.txt", "b b.txt"]
            .map { name in
                String(format: "%08X", UInt32(try digest("/usr/bin/cksum", ["-o", "3"], "work/" + name)) ?? 0)
            }
        #expect(box.read("work/work.sfv") == "a.txt \(crcs[0])\nb b.txt \(crcs[1])\n")
    }

    /// What each method writes, Verify reads back without an error.
    @Test
    internal func everyMethodRoundTripsThroughVerify() {
        for chosen in ChecksumMethod.allCases {
            create(
                ["a.txt", "sub"],
                ["method": method(chosen), "target": .text(box.url("work/all." + chosen.fileExtension).path)]
            )
            let result = verify(["all." + chosen.fileExtension])
            #expect(result.title == "\(chosen.reportName): Errors: 0", "\(chosen)")
            #expect(
                result.text.hasSuffix("Errors: 0\nOK: 3, not found: 0, read error: 0, wrong checksum: 0\n"),
                "\(chosen)"
            )
        }
    }

    /// The Windows format writes back slashes, CRLF and the byte-order mark; the Unix format a mark only when asked.
    @Test
    internal func windowsFormatAndUnicodeNames() throws {
        try box.file("work/sub/ünï.txt", "x")
        create(["sub"], ["unix": .flag(false), "method": method(.md5), "target": .text(box.url("work/win.md5").path)])
        let data = try Data(contentsOf: box.url("work/win.md5"))
        // Back slashes, CRLF, and the mark that tells the original the names are UTF-8.
        #expect(data.starts(with: [0xEF, 0xBB, 0xBF]))
        let text = String(bytes: data.dropFirst(3), encoding: .utf8) ?? ""
        #expect(
            text.components(separatedBy: "\r\n").map { line in String(line.split(separator: "*").last ?? "") } == [
                "sub\\c.txt", "sub\\deep\\d.txt", "sub\\ünï.txt", ""
            ]
        )
        #expect(verify(["win.md5"]).title == "MD5: Errors: 0")
        #expect(settings.flag(FileTools.Keys.unixFormat, default: true) == false)

        create(
            ["a.txt"],
            ["unix": .flag(true), "method": method(.md5), "target": .text(box.url("work/plain.md5").path)]
        )
        #expect(!(try Data(contentsOf: box.url("work/plain.md5"))).starts(with: [0xEF, 0xBB, 0xBF]))
        create(
            ["a.txt"],
            ["utf8": .flag(true), "method": method(.md5), "target": .text(box.url("work/marked.md5").path)]
        )
        #expect((try Data(contentsOf: box.url("work/marked.md5"))).starts(with: [0xEF, 0xBB, 0xBF]))
        #expect(ChecksumFile.needsByteOrderMark(names: ["ä"], unixFormat: true, alwaysUTF8: false) == false)
        #expect(ChecksumFile.needsByteOrderMark(names: ["a"], unixFormat: false, alwaysUTF8: false) == false)
    }

    /// Separate checksum files per file take their names from a pattern; those per folder go into each folder.
    @Test
    internal func separateFilesPerFileAndPerFolder() {
        #expect(ChecksumRun.separateName(for: "test.txt", pattern: "*.*.sfv", method: .crc32) == "test.txt.sfv")
        #expect(ChecksumRun.separateName(for: "test.txt", pattern: "*.sfv", method: .crc32) == "test.sfv")
        #expect(ChecksumRun.separateName(for: "test.txt", pattern: "*.*", method: .md5) == "test.txt.md5")
        // Without a `*` in the name the proposal of the preference is used: the extension is added…
        create(["a.txt", "b b.txt"], ["separateFiles": .flag(true), "method": method(.sha1)])
        #expect(namesOnDisk(box.url("work")).filter { name in name.hasSuffix(".sha") } == ["a.txt.sha", "b b.txt.sha"])
        #expect(box.read("work/a.txt.sha")?.hasSuffix(" *a.txt\n") == true)
        // …or put in place of the file's own, and the files go where the target says.
        settings.set(false, forKey: FileTools.Keys.appendExtension)
        create(
            ["a.txt", "sub"],
            ["separateFiles": .flag(true), "method": method(.sha1), "target": .text(box.url("other/x.sha").path)]
        )
        #expect(namesOnDisk(box.url("other")) == ["a.sha", "c.sha", "d.sha"])
        // Elsewhere than above the files, the names carry no path.
        #expect(box.read("other/d.sha")?.hasSuffix(" *d.txt\n") == true)
        create(
            ["b b.txt"],
            ["separateFiles": .flag(true), "method": method(.sha1), "target": .text(box.url("other/*.*.sum").path)]
        )
        #expect(box.exists("other/b b.txt.sum"))

        // One file per folder, in that folder, whatever the target says.
        create(
            ["a.txt", "sub"],
            [
                "separateFiles": .flag(false), "separateFolders": .flag(true), "method": method(.md5),
                "target": .text(box.url("other/ignored.md5").path)
            ]
        )
        #expect(
            box.exists("work/work.md5") && box.exists("work/sub/sub.md5") && box.exists("work/sub/deep/deep.md5")
                && !box.exists("other/ignored.md5")
        )
        #expect(box.read("work/sub/sub.md5")?.hasSuffix(" *c.txt\n") == true)
        #expect(verify(["work.md5"]).title == "MD5: Errors: 0")
    }

    /// Checksums are made on another file system; a file in the way is asked about, and an empty folder has
    /// nothing to hash.
    @Test
    internal func createOnAnotherFileSystemAndFailures() {
        memory.addFile("/data/one.bin", "1")
        memory.addFile("/data/two.bin", "2")
        left.show(memory.url("/data"))
        create(["one.bin", "two.bin"], ["method": method(.blake3)])
        #expect(
            memory.contents("/data/data.bk3")?.split(separator: "\n").map { line in line.suffix(9) }
                == ["*one.bin", "*two.bin"].map { name in Substring(" " + name) }
        )
        // An existing checksum file is asked about; Cancel keeps it.
        create(["one.bin"], ["method": method(.blake3), "target": .text("mem:/data/data.bk3")])
        #expect(memory.contents("/data/data.bk3")?.contains("two.bin") == true)
        interaction.choiceAnswers = [0]
        create(["one.bin"], ["method": method(.blake3), "target": .text("mem:/data/data.bk3")])
        #expect(memory.contents("/data/data.bk3")?.contains("two.bin") == false)
        // An empty folder has nothing to hash.
        memory.addDirectory("/data/empty")
        create(["empty"], [:])
        #expect(interaction.log.last == "inform: Create CRC-checksum file" && !memory.exists("/data/data.sfv"))
    }
}
