/// The status line's figures.
extension PanelModel {
    /// The figures of the status line (03 › Status line): of the marked items and of all the
    /// shown ones.
    public struct Totals: Equatable, Sendable {
        /// The bytes of the marked items.
        public var selectedBytes: Int64 = 0
        /// The bytes of the shown items.
        public var totalBytes: Int64 = 0
        /// How many marked items are files.
        public var selectedFiles = 0
        /// How many shown items are files.
        public var totalFiles = 0
        /// How many marked items are folders.
        public var selectedFolders = 0
        /// How many shown items are folders.
        public var totalFolders = 0

        /// The figures of the marked items and of the shown ones.
        public init(selected: Counts = Counts(), total: Counts = Counts()) {
            (selectedBytes, selectedFiles, selectedFolders) = (selected.bytes, selected.files, selected.folders)
            (totalBytes, totalFiles, totalFolders) = (total.bytes, total.files, total.folders)
        }

        /// The totals with some bytes more or less; nil when the sum leaves the range of a
        /// number or may have left it before.
        internal func adding(bytes: Int64, selected: Bool) -> Self? {
            var totals = self
            let old = selected ? selectedBytes : totalBytes
            let (sum, overflow) = old.addingReportingOverflow(bytes)
            guard !overflow, old != .max, old != .min else {
                return nil
            }
            if selected { totals.selectedBytes = sum } else { totals.totalBytes = sum }
            return totals
        }
    }
}
