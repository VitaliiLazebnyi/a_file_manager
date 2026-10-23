import Foundation
import Testing

@testable import FileToolsPlugin

/// Reading checksum files: their lines, their names and their encodings.
extension FileToolsChecksums {
    /// The lines of GNU, SFV, OpenSSL and BSD checksum files, and of a stream, are read; comments and rubbish are
    /// not.
    @Test
    internal func lineFormats() {
        typealias Entry = ChecksumFile.Entry
        let md5 = String(repeating: "ab", count: 16)
        let sha256 = String(repeating: "CD", count: 32)
        #expect(
            ChecksumFile.parse(
                "\(md5) *a b.txt\r\n\(md5)  text.txt\n; comment\n# another\n\nrubbish line\n",
                fileName: "x.md5"
            )
                == [
                    Entry(name: "a b.txt", digest: md5, method: .md5),
                    Entry(name: "text.txt", digest: md5, method: .md5)
                ]
        )
        #expect(
            ChecksumFile.parse("file one.bin 1A2B3C4D\ndeadbeef 00112233\ncafe.txt\tFFFFFFFF", fileName: "x.sfv")
                == [
                    Entry(name: "file one.bin", digest: "1a2b3c4d", method: .crc32),
                    Entry(name: "deadbeef", digest: "00112233", method: .crc32),
                    Entry(name: "cafe.txt", digest: "ffffffff", method: .crc32)
                ]
        )
        #expect(
            ChecksumFile.parse(
                "SHA256(my (1).bin)= \(sha256)\nMD5 (b.txt) = \(md5)\nSHA3-256(c)= \(sha256)\nSHA256(short)= abcd",
                fileName: "sums.txt"
            )
                == [
                    Entry(name: "my (1).bin", digest: sha256.lowercased(), method: .sha256),
                    Entry(name: "b.txt", digest: md5, method: .md5),
                    Entry(name: "c", digest: sha256.lowercased(), method: .sha3Bits256)
                ]
        )
        // The checksum of a stream stands for the file the checksum file is named after.
        #expect(
            ChecksumFile.parse("\(sha256)  -", fileName: "disk.img.sha256") == [
                Entry(name: "disk.img", digest: sha256.lowercased(), method: .sha256)
            ]
        )
        // Without a telling extension the length decides, and several methods may fit.
        #expect(
            ChecksumFile.parse("\(sha256) *a", fileName: "sums.txt") == [
                Entry(name: "a", digest: sha256.lowercased(), method: nil)
            ]
        )
        #expect(ChecksumFile.parse("\(md5) *a", fileName: "x.sha256") == [Entry(name: "a", digest: md5, method: nil)])
    }

    /// The method of a checksum file follows from its extension, the files Verify takes from the masks, and
    /// lines are written as the formats have them.
    @Test
    internal func checksumFileNamesAndLines() {
        #expect(
            ChecksumFile.method(forFileNamed: "A.SHA") == .sha1
                && ChecksumFile.method(forFileNamed: "a.sha3-512") == .sha3Bits512
        )
        #expect(
            ChecksumFile.method(forFileNamed: "a.bk3") == .blake3 && ChecksumFile.method(forFileNamed: "a.txt") == nil
        )
        #expect(
            ChecksumFile.isChecksumFile("x.SFV", extraMasks: "")
                && ChecksumFile.isChecksumFile("x.sha512", extraMasks: "")
                && !ChecksumFile.isChecksumFile("x.sum", extraMasks: "")
        )
        #expect(ChecksumFile.isChecksumFile("x.sum", extraMasks: "*.sum *.crc32"))
        #expect(
            ChecksumFile.line(name: "n", digest: [0xAB, 0x01], method: .md5) == "ab01 *n"
                && ChecksumFile.line(name: "n", digest: [0xAB, 0x01], method: .crc32) == "n AB01"
        )
    }

    /// Checksum files are read in UTF-8 with or without a mark, in UTF-16 either way round, and in the Western code
    /// page.
    @Test
    internal func encodingsOfChecksumFiles() {
        let line = "ä.txt 00000000\n"
        #expect(ChecksumFile.text(from: Data([0xEF, 0xBB, 0xBF]) + Data(line.utf8)) == line)
        #expect(ChecksumFile.text(from: Data(line.utf8)) == line)
        #expect(ChecksumFile.text(from: line.data(using: .utf16) ?? Data()) == line)
        #expect(ChecksumFile.text(from: "ab\n ".data(using: .utf16LittleEndian) ?? Data()) == "ab\n ")
        #expect(ChecksumFile.text(from: "ab".data(using: .utf16BigEndian) ?? Data()) == "ab")
        #expect(ChecksumFile.text(from: line.data(using: .windowsCP1252) ?? Data()) == line)
    }
}
