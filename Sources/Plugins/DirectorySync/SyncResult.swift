/// What a comparison of two directory trees found.
public struct SyncResult: Sendable {
    /// The rows of the result list, folder by folder.
    public var rows: [SyncRow] = []
    /// The folders listed on the left.
    public var leftDirectories = 0
    /// The folders listed on the right.
    public var rightDirectories = 0
    /// Folders that could not be read and files that could not be compared.
    ///
    /// A folder that fails on one side is left out on both, so nothing in it looks unique.
    public var errors: [String] = []
    /// Whether the comparison was cancelled; the rows are then incomplete.
    public var wasCancelled = false
    /// How many entries the two start directories held before the masks and the selection were
    /// applied; nil where the directory could not be read.
    ///
    /// A source that lists as empty while the other side is not is how an unmounted share or a
    /// wrong path looks.
    public var topEntries: (left: Int?, right: Int?) = (nil, nil)
    /// The time tolerance the comparison used: as set where a file system needs it (FAT and
    /// exFAT, shares, servers, archives), none beyond rounding where both sides keep exact dates.
    public var toleranceSeconds = 0
}
