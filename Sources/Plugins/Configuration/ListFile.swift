import Foundation

/// A list of file names a started program reads (spec 18 › List files).
///
/// The expansion only says what the file holds; whoever runs the command writes it, off the main
/// thread.
internal struct ListFile: Equatable {
    /// Where the file is to be written; its name is in the command line.
    internal let url: URL
    /// The names, one per line, in the encoding the code asked for.
    internal let contents: Data
}
