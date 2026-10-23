/// How Pack is to work (spec 08 › Pack › Options).
internal struct PackOptions {
    /// The kind of archive that is made.
    internal var format = ArchiveFormat.zip
    /// 0 (store) … 9.
    internal var level = 6
    /// Folders keep their paths relative to the source folder; without, everything is stored flat.
    internal var storesPaths = true
    /// What lies in folders below a selected folder is packed too; without, only its own files.
    internal var recurses = true
    /// The sources are deleted after a successful pack.
    internal var movesSources = false
    /// One archive per operand.
    internal var separateArchives = false
    /// With separate archives: the archive of a folder holds its contents, not the folder.
    internal var skipsBaseFolder = false
    /// The password the members are encrypted with (ZIP); nil or empty packs them plainly.
    internal var password: String?
    /// How the members are encrypted when there is a password.
    internal var encryption = ZipEncryption.aes256
    /// The new archive is tested at once; one that fails keeps the sources from being deleted.
    internal var verifies = false
    /// The archive gets the time of its newest file instead of the time it was made.
    internal var datesByNewest = false
    /// The sizes above which a ZIP needs its 64-bit extension (ZIP64).
    internal var limits = ZipLimits.standard
}
