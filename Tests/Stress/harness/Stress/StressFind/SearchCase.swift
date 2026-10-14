internal import Foundation

/// One search and the files it must find.
internal struct SearchCase: Sendable {
    /// How the output names it.
    internal let label: String
    /// Where the search starts.
    internal let directory: URL
    /// The name patterns ("" for all).
    internal let names: String
    /// The text the files must hold ("" for none).
    internal let text: String
    /// The paths of the files it must find.
    internal var expected: Set<String>
}
