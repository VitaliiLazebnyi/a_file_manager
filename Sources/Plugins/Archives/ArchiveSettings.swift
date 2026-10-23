import AFMKernel

/// The keys of the Packer page in the settings.
internal enum ArchiveSettings {
    /// Whether Enter opens archives like folders.
    internal static let opensAsFolders = "archives.openAsFolders"
    /// The endings, separated by spaces, of the files Enter opens as archives.
    internal static let extensions = "archives.extensions"
    /// Whether Ctrl+PgDn enters any file as an archive.
    internal static let entersAnyFile = "archives.enterAnyFile"
    /// The index, in `ArchiveFormat.writable`, of the format Pack proposes.
    internal static let format = "archives.format"
    /// The compression level Pack proposes, 0 to 9.
    internal static let level = "archives.level"
    /// Whether Pack stores the paths of the files below the folders it packs.
    internal static let storesPaths = "archives.storePaths"
    /// Whether Pack goes into subfolders.
    internal static let recurses = "archives.recurse"
    /// Whether a ZIP is tested after packing.
    internal static let verifies = "archives.verify"
    /// Whether a new archive gets the date of its newest member.
    internal static let datesByNewest = "archives.dateByNewest"
    /// Whether Unpack recreates the paths stored in the archive.
    internal static let unpackPaths = "archives.unpackPaths"
    /// Whether Unpack puts each archive into a folder of its own.
    internal static let unpackSeparate = "archives.unpackSeparate"
    /// Whether Unpack overwrites existing files without asking.
    internal static let unpackOverwrite = "archives.unpackOverwrite"

    /// The endings Enter opens as folders.
    ///
    /// Office documents and installer packages are ZIP or XAR files too, but Enter should hand
    /// those to their applications (spec 08 › Opening an archive, `PreferOpenTypes`); "Open as
    /// Archive" still enters them.
    internal static let defaultExtensions =
        "zip 7z rar tar gz tgz bz2 tbz tbz2 xz txz jar war cab cpio lha lzh arj z taz"
    /// The compression levels as the Pack dialog and the settings list them, 0 to 9.
    internal static let levels = ["0 (store)", "1 (fastest)", "2", "3", "4", "5", "6 (normal)", "7", "8", "9 (best)"]

    /// The options the working threads use, read from the settings; on the main thread.
    internal static func options(from settings: any SettingsStore) -> ArchiveOptions {
        var options = ArchiveOptions()
        options.compressionLevel = max(0, min(settings.index(level, default: 6), 9))
        options.opensAsFolders = settings.flag(opensAsFolders, default: true)
        options.entersAnyFile = settings.flag(entersAnyFile, default: true)
        let list = settings.text(extensions, default: defaultExtensions).lowercased()
        // "*.zip" and ".zip" are taken as "zip".
        options.extensions = Set(
            list.split { " ,;".contains($0) }.map { ending in String(ending.drop { "*.".contains($0) }) }
        )
        options.verifiesAfterPacking = settings.flag(verifies, default: true)
        options.datesArchiveByNewest = settings.flag(datesByNewest, default: false)
        return options
    }
}
