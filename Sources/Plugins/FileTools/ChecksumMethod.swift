import CryptoKit
import Foundation

/// The checksum methods of "Create checksum files" (spec 08 › Methods).
///
/// The raw values are the numbers of the spec's `Lastmd5` setting.
internal enum ChecksumMethod: Int, CaseIterable, Codable {
    /// BLAKE3, 256 bits.
    case blake3 = 11
    /// CRC32, written as an SFV file.
    case crc32 = 0
    /// MD5.
    case md5 = 1
    /// SHA-1.
    case sha1 = 2
    /// SHA-224 (SHA-2).
    case sha224 = 5
    /// SHA-256 (SHA-2).
    case sha256 = 3
    /// SHA-384 (SHA-2).
    case sha384 = 6
    /// SHA3-224.
    case sha3Bits224 = 9
    /// SHA3-256.
    case sha3Bits256 = 7
    /// SHA3-384.
    case sha3Bits384 = 10
    /// SHA3-512.
    case sha3Bits512 = 8
    /// SHA-512 (SHA-2).
    case sha512 = 4

    /// The order of the dialog.
    internal static let dialogOrder = allCases.sorted { first, second in first.dialogPosition < second.dialogPosition }

    /// The place in the dialog.
    internal var dialogPosition: Int {
        switch self {
        case .crc32:
            return 0

        case .md5:
            return 1

        case .sha1:
            return 2

        case .blake3:
            return 3

        case .sha224:
            return 4

        case .sha256:
            return 5

        case .sha384:
            return 6

        case .sha512:
            return 7

        case .sha3Bits224:
            return 8

        case .sha3Bits256:
            return 9

        case .sha3Bits384:
            return 10

        case .sha3Bits512:
            return 11
        }
    }

    /// The name in the dialog and in the checksum files' names.
    internal var title: String {
        switch self {
        case .crc32:
            return "CRC32 (SFV)"

        case .md5:
            return "MD5"

        case .sha1:
            return "SHA1"

        case .sha256:
            return "SHA256"

        case .sha512:
            return "SHA512"

        case .sha224:
            return "SHA224"

        case .sha384:
            return "SHA384"

        case .sha3Bits256:
            return "SHA3_256"

        case .sha3Bits512:
            return "SHA3_512"

        case .sha3Bits224:
            return "SHA3_224"

        case .sha3Bits384:
            return "SHA3_384"

        case .blake3:
            return "BLAKE3"
        }
    }

    /// The name in the title of the Verify window: `MD5`, `SHA2_256` (spec 08 › Verify window).
    internal var reportName: String {
        switch self {
        case .crc32:
            return "CRC32"

        case .sha224, .sha256, .sha384, .sha512:
            return "SHA2_" + title.dropFirst(3)

        default:
            return title
        }
    }

    /// The extension of the checksum file.
    ///
    /// The spec records `.sfv`, `.md5`, `.sha`, `.sha256` and `.bk3`; the others follow the same
    /// pattern.
    internal var fileExtension: String {
        switch self {
        case .crc32:
            return "sfv"

        case .md5:
            return "md5"

        case .sha1:
            return "sha"

        case .blake3:
            return "bk3"

        default:
            return title.lowercased()
        }
    }

    /// The method as OpenSSL-style lines name it: `SHA256(name)= …`, `SHA3-256(name)= …`.
    internal var tagName: String {
        title.replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: "CRC32 (SFV)", with: "CRC32")
    }

    /// The bytes of a digest.
    internal var digestLength: Int {
        switch self {
        case .crc32:
            return 4

        case .md5:
            return 16

        case .sha1:
            return 20

        case .sha224, .sha3Bits224:
            return 28

        case .sha256, .sha3Bits256, .blake3:
            return 32

        case .sha384, .sha3Bits384:
            return 48

        case .sha512, .sha3Bits512:
            return 64
        }
    }

    /// The methods a digest of this many hex digits can come from (spec 08 › Hash-length
    /// disambiguation), the SHA-2 family first.
    internal static func candidates(hexDigits: Int) -> [Self] {
        [
            .crc32, .md5, .sha1, .sha224, .sha256, .sha384, .sha512, .sha3Bits224, .sha3Bits256, .sha3Bits384,
            .sha3Bits512, .blake3
        ]
        .filter { method in method.digestLength * 2 == hexDigits }
    }

    /// A new hasher of the method, at the start of its input.
    internal func makeHasher() -> any StreamHasher {
        switch self {
        case .crc32:
            return CRC32Hasher()

        case .md5:
            return CryptoHasher<Insecure.MD5>()

        case .sha1:
            return CryptoHasher<Insecure.SHA1>()

        case .sha256:
            return CryptoHasher<SHA256>()

        case .sha384:
            return CryptoHasher<SHA384>()

        case .sha512:
            return CryptoHasher<SHA512>()

        case .sha224:
            return SHA224Hasher()

        // The own implementation on every system: CryptoKit has SHA-3 only from macOS 26 on, and
        // is about a sixth faster there (845 against 705 MB/s for SHA3-256 on one core), less
        // than the disks the files come from deliver.
        case .sha3Bits224, .sha3Bits256, .sha3Bits384, .sha3Bits512:
            return SHA3Hasher(digestLength: digestLength)

        case .blake3:
            return BLAKE3Hasher()
        }
    }
}
