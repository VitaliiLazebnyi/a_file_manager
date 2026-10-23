import AFMKernel
import Foundation

/// The options of the Packer page as the working threads see them.
///
/// The settings store belongs to the main thread; this copy is refreshed there and read anywhere.
internal struct ArchiveOptions {
    /// How hard new ZIP members are compressed: 0 stores them, 9 is the strongest.
    internal var compressionLevel = 6
    /// Whether Enter on an archive with one of `extensions` opens it like a folder.
    internal var opensAsFolders = true
    /// Whether any file may be opened as an archive when the user asks for it explicitly.
    internal var entersAnyFile = true
    /// The file extensions (lowercase, without the dot) that are taken for archives.
    internal var extensions: Set<String> = []
    /// Whether a packed archive is read back and tested once it is written.
    internal var verifiesAfterPacking = true
    /// Whether a packed archive gets the date of its newest member instead of the time of packing.
    internal var datesArchiveByNewest = false
}
