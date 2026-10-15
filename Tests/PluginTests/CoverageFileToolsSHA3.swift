import CryptoKit
import Foundation
import Testing

@testable import FileToolsPlugin

/// The program's own SHA-3, which it uses on every system, against CryptoKit's where the system
/// has one.
@Suite
internal struct CoverageFileToolsSHA3 {
    /// Data of every length around the block sizes of the four variants, fed in pieces.
    private static let samples: [Data] = [0, 1, 71, 72, 73, 103, 104, 135, 136, 137, 143, 144, 145, 1_000, 100_000]
        .map { count in Data((0..<count).map { UInt8($0 % 251) }) }

    /// The digest of the program's own hasher, the data given in pieces of `piece` bytes.
    private func own(_ data: Data, length: Int, piece: Int) -> [UInt8] {
        let hasher = SHA3Hasher(digestLength: length)
        var start = data.startIndex
        while start < data.endIndex {
            let end = min(start + piece, data.endIndex)
            hasher.update(data[start..<end])
            start = end
        }
        return hasher.finish()
    }

    /// SHA3-256, -384 and -512 give what CryptoKit gives, however the data comes in.
    @Test
    @available(macOS 26.0, *)
    internal func theOwnSHA3IsCryptoKits() {
        for data in Self.samples {
            for piece in [1, 7, 1 << 20] {
                #expect(own(data, length: 32, piece: piece) == Array(SHA3_256.hash(data: data)), "\(data.count)")
                #expect(own(data, length: 48, piece: piece) == Array(SHA3_384.hash(data: data)), "\(data.count)")
                #expect(own(data, length: 64, piece: piece) == Array(SHA3_512.hash(data: data)), "\(data.count)")
            }
        }
        #expect(ChecksumMethod.sha3_256.makeHasher() is SHA3Hasher)
    }
}
