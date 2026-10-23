import AFMKernel
import Foundation

/// What a set of files and folders adds up to (spec 07 › Calculate occupied space).
internal struct SpaceTotals: Equatable {
    /// The sum of the file sizes.
    internal var bytes: Int64 = 0
    /// The space really taken on the source volume; equal to `bytes` where that is not known.
    internal var allocated: Int64 = 0
    /// The file sizes rounded up to the allocation unit of the target volume: the space a
    /// copy needs there.
    internal var rounded: Int64 = 0
    /// How many files were counted, links among them.
    internal var files = 0
    /// How many folders were counted below the measured items, and the measured folders themselves.
    internal var folders = 0
    /// Folders that could not be read; their contents are missing from the figures.
    internal var unreadable = 0

    /// The figures of both sides added up; the byte counts stop at `Int64.max` instead of overflowing.
    internal static func + (left: Self, right: Self) -> Self {
        Self(
            bytes: left.bytes.addingSaturated(right.bytes),
            allocated: left.allocated.addingSaturated(right.allocated),
            rounded: left.rounded.addingSaturated(right.rounded),
            files: left.files + right.files,
            folders: left.folders + right.folders,
            unreadable: left.unreadable + right.unreadable
        )
    }

    /// Adds the figures of `right` to `left`, as `+` does.
    internal static func += (left: inout Self, right: Self) {
        left = left + right
    }
}
