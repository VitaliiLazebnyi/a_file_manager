import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The defects of the passwords of the old encryption that the full test runs found.
extension ArchiveFixes {
    /// A wrong password of the old encryption that passes the check byte and whose data even
    /// starts like compressed data (a short stream that ends early) is a wrong password too: it
    /// is asked for again and not kept.
    ///
    /// It used to give a CRC error. (About one in 300 of the wrong passwords that pass the check
    /// byte is such a one; the archive is packed again, with another random header, until one is
    /// found.).
    @Test
    internal func aWrongPasswordWhoseDataStartsLikeCompressedDataIsAskedForAgain() throws {
        let tree = try bench.makeTree()
        let original = try Data(contentsOf: tree.appendingPathComponent("readme.txt"))
        var found: (archive: URL, password: String)?
        for round in 0..<200 where found == nil {
            let archive = box.url("secret\(round).zip")
            try bench.pack([tree.appendingPathComponent("readme.txt")], to: archive) { options in
                options.password = "right"
                options.encryption = .legacy
            }
            let record = try #require(ZipDirectory.read(RandomAccessFile(archive)).records.first)
            guard case .archive(let offset, let file) = record.source else {
                return
            }
            let start = try ZipDirectory.localHeader(of: record, at: offset, in: file).dataOffset
            // Passes the check byte, and its first 4 KB inflate without an error.
            func startsLikeCompressedData(_ password: String) -> Bool {
                guard
                    let decrypted = try? ZipDecryptStream(
                        FileRangeStream(file, offset: start, length: record.compressedSize),
                        password: password,
                        check: UInt8(record.dosTime >> 8),
                        name: ""
                    )
                else {
                    return false
                }
                let probe = InflateStream(decrypted, wrapping: .raw)
                defer { probe.close() }
                return (try? probe.read(upToCount: 1 << 12)) != nil
            }
            found = (0..<20_000).lazy.map { "wrong\($0)" }.first(where: startsLikeCompressedData).map { (archive, $0) }
        }
        let (archive, wrong) = try #require(found)
        bench.store.close()
        bench.passwords.set([wrong, "right"])
        let member = bench.inside(archive, "readme.txt")
        #expect(try bench.read(member) == original)
        #expect(bench.passwords.asked == 2)
        #expect(try bench.read(member) == original && bench.passwords.asked == 2)
    }
}
