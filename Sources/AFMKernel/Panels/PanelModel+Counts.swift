/// One half of the status line's figures.
extension PanelModel {
    /// Bytes, files and folders of some items: one half of `Totals`.
    public struct Counts: Equatable, Sendable {
        /// The bytes of the items; a folder counts with its calculated size, once it has one.
        public var bytes: Int64
        /// How many of the items are files.
        public var files: Int
        /// How many of the items are folders.
        public var folders: Int

        /// The figures of some items.
        public init(bytes: Int64 = 0, files: Int = 0, folders: Int = 0) {
            (self.bytes, self.files, self.folders) = (bytes, files, folders)
        }

        /// The figures a count of a list came to.
        internal init(_ tally: Tally) {
            self.init(bytes: tally.bytes, files: tally.files, folders: tally.folders)
        }
    }
}
