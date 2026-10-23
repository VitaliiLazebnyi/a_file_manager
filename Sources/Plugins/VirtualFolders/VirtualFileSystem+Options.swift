/// How branch views are walked.
extension VirtualFileSystem {
    /// How a branch view is walked: what the user chose on the Branch View preference page.
    public struct Options: Equatable, Sendable {
        /// Branch view also lists the folders themselves.
        public var listsFolders = false
        /// Branch view walks into packages (`.app`) instead of listing them as one item.
        public var entersPackages = false

        /// Options that list the files only and treat a package as one item, unless told otherwise.
        public init(listsFolders: Bool = false, entersPackages: Bool = false) {
            self.listsFolders = listsFolders
            self.entersPackages = entersPackages
        }
    }
}
