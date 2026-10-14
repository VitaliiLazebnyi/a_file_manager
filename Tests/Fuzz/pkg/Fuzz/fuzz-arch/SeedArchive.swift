@testable import ArchivesPlugin

/// One archive that `mkseeds` packs: the seed folder it goes to, its format, password and name.
internal struct SeedArchive {
    /// The archives, in the order they are packed.
    internal static let all: [Self] = [
        Self(folder: "zip", format: .zip, password: nil, name: "own.zip"),
        Self(folder: "zip", format: .zip, password: "secret", name: "own-crypt.zip"),
        Self(folder: "zip", format: .zip, password: "secret", name: "own-crypt-aes.zip"),
        Self(folder: "tar", format: .tar, password: nil, name: "own.tar"),
        Self(folder: "tgz", format: .compressedTar(.gzip), password: nil, name: "own.tar.gz"),
        Self(folder: "txz", format: .compressedTar(.xz), password: nil, name: "own.tar.xz"),
        Self(folder: "bz", format: .compressedTar(.bzip2), password: nil, name: "own.tar.bz2"),
        Self(folder: "tgz", format: .compressedFile(.gzip), password: nil, name: "own.gz"),
        Self(folder: "txz", format: .compressedFile(.xz), password: nil, name: "own.xz")
    ]

    /// The seed folder below the seeds directory: the target's name.
    internal let folder: String
    /// The archive format.
    internal let format: ArchiveFormat
    /// The password; nil packs without encryption.
    internal let password: String?
    /// The file name.
    internal let name: String

    /// Whether the format compresses one file rather than a tree.
    internal var isSingleFile: Bool {
        if case .compressedFile = format {
            return true
        }
        return false
    }
}
