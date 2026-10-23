import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import FileToolsPlugin

/// Verify checksums: checksum files, a checksum from the clipboard, and CRCs in file names.
extension FileToolsChecksums {
    /// Verify tells the files that are right, missing and wrong, marks the failures, and can show only those.
    @Test
    internal func verifyReportsOkMissingAndWrong() throws {
        create(["a.txt", "b b.txt", "sub"], ["method": method(.md5)])
        try "changed".write(to: box.url("work/b b.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: box.url("work/sub/c.txt"))
        let result = verify(["work.md5"])
        #expect(result.title == "MD5: Errors: 2")
        #expect(
            result.text == """
                work.md5:
                Cannot open input file sub/c.txt!
                OK:  sub/deep/d.txt
                OK:  a.txt
                Wrong checksum: b b.txt!

                Errors: 2
                OK: 2, not found: 1, read error: 0, wrong checksum: 1

                """
        )
        // The failures that are in the panel are marked there.
        #expect(left.model.selection == ["b b.txt"])
        #expect(bench.jobService.titles.last == "Verifying checksums:")
        settings.set(true, forKey: FileTools.Keys.onlyErrors)
        #expect(
            verify(["work.md5"]).text
                .hasPrefix(
                    "work.md5:\nCannot open input file sub/c.txt!\nWrong checksum: b b.txt!\n\nErrors: 2\n"
                )
        )
    }

    /// Checksum files that the programs of macOS write are verified, also with another extension once its mask is
    /// set, and Windows paths in them are followed.
    @Test
    internal func verifiesFilesWrittenByTheSystemTools() throws {
        let work = box.url("work")
        try Data(
            try FileToolsFixture.systemTool("/usr/bin/shasum", ["-a", "256", "a.txt", "b b.txt", "sub/c.txt"], in: work)
                .output.utf8
        )
        .write(to: box.url("work/tool.sha256"))
        try Data(try FileToolsFixture.systemTool("/sbin/md5", ["a.txt", "b b.txt"], in: work).output.utf8)
            .write(
                to: box.url("work/bsd.md5")
            )
        try Data(
            try FileToolsFixture.systemTool("/usr/bin/shasum", ["-a", "512", "--tag", "a.txt"], in: work).output.utf8
        )
        .write(
            to: box.url("work/tagged.txt")
        )
        try Data(
            try FileToolsFixture.systemTool("/usr/bin/shasum", ["-a", "1", "-b", "sub/deep/d.txt"], in: work).output
                .utf8
        )
        .write(
            to: box.url("work/binary.sha")
        )
        let both = verify(["tool.sha256", "bsd.md5", "binary.sha"])
        #expect(both.title == "Checksums: Errors: 0")
        #expect(
            both.text == """
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

                """
        )
        // A file with another extension is a checksum file once its mask is configured.
        #expect(verify(["tagged.txt"]).title == "inform: Please select only SFV, MD5 or SHA files!")
        settings.set("*.sum tagged.*", forKey: FileTools.Keys.extraTypes)
        #expect(verify(["tagged.txt"]).title == "SHA2_512: Errors: 0")
        // Windows paths in a checksum file are followed too.
        try box.file("work/win.sfv", "sub\\c.txt 00000000\r\n")
        #expect(verify(["win.sfv"]).text.contains("Wrong checksum: sub\\c.txt!"))
    }

    /// Without a checksum file, the file under the cursor is checked against a checksum on the clipboard, and files
    /// against a CRC32 in their names.
    @Test
    internal func verifyAgainstTheClipboardAndTheFileName() throws {
        let sha256 = try digest("/usr/bin/shasum", ["-a", "256"], "work/a.txt")
        pasteboard.clearContents()
        pasteboard.setString("  \(sha256.uppercased())\n", forType: .string)
        var result = verify(["a.txt"])
        #expect(
            result.title == "SHA2_256: Errors: 0" && result.text.hasPrefix("Checksum from the clipboard:\nOK:  a.txt\n")
        )
        #expect(verify(["b b.txt"]).title == "SHA2_256: Errors: 1")
        // SHA-3 and BLAKE3 have the same length; whichever fits is found.
        let hasher = ChecksumMethod.sha3Bits256.makeHasher()
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
        #expect(
            result.text.hasPrefix(
                "Checksums in the file names:\nOK:  Movie [\(crc)].mkv\nWrong checksum: Other [00000000].mkv!\n"
            )
        )
        #expect(left.model.selection == ["Other [00000000].mkv"])
        #expect(
            ChecksumRun.checksumInName("x [1a2B3c4D] y.z") == "1a2b3c4d"
                && ChecksumRun.checksumInName("x [123].z") == nil
        )
        #expect(
            ChecksumRun.checksum(fromClipboard: "ABCDEF12") == "abcdef12"
                && ChecksumRun.checksum(fromClipboard: "ABCDEF123") == nil
        )
    }

    /// Many files on another file system are checked side by side and reported in the order of the checksum file.
    @Test
    internal func verifyManyFilesOnAnotherFileSystem() {
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
        #expect(
            rows.count == 203 && rows[1] == "OK:  f0.dat" && rows[78] == "Wrong checksum: f77.dat!"
                && rows[200] == "OK:  f199.dat"
        )
        #expect(left.model.selection == ["f77.dat"])
    }
}
