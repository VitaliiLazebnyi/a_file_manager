/// What is compared and how (spec 09 › Compare options).
public struct SyncOptions: Codable, Equatable, Sendable {
    /// The options that are stored: every one but `onlyNames`, which belongs to one comparison.
    private enum CodingKeys: String, CodingKey {
        case asymmetric = "asymmetric"
        case byContent = "byContent"
        case emptyDirectories = "emptyDirectories"
        case ignoreDate = "ignoreDate"
        case ignoreOneHourDifference = "ignoreOneHourDifference"
        case includeHidden = "includeHidden"
        case mask = "mask"
        case subdirectories = "subdirectories"
        case timeOffsetHours = "timeOffsetHours"
        case toleranceSeconds = "toleranceSeconds"
    }

    /// Recurse into subdirectories.
    public var subdirectories = true
    /// Pairs that look equal by size and date are also read and compared byte by byte.
    public var byContent = false
    /// Dates are not compared; such pairs are only "equal" or "not equal".
    public var ignoreDate = false
    /// The right side is to become a copy of the left: files only on the right are deleted.
    public var asymmetric = false
    /// Directories that exist on one side only are rows of their own, created or deleted.
    public var emptyDirectories = false
    /// File masks, with exclusions after `|`.
    public var mask = "*.*"
    /// Dates this close count as the same (spec 09 › Comparison algorithm: 3 s; FAT volumes
    /// round to 2 s).
    public var toleranceSeconds = 3
    /// Hours added to the dates of the right side before comparing, for a server in another
    /// time zone (spec 09 › Synchronizing with FTP, `dT`).
    public var timeOffsetHours = 0
    /// Differences of exactly one hour (daylight saving on FAT volumes) count as the same.
    public var ignoreOneHourDifference = false
    /// Hidden files take part.
    public var includeHidden = false
    /// "Only selected (in main window)": the only names of the two start directories that are
    /// compared; empty compares everything.
    ///
    /// Never stored: it belongs to one comparison.
    public var onlyNames: [String] = []

    /// The options of a new window: everything in subdirectories, by size and date.
    public init() {
        // Every option has its default.
    }
}
