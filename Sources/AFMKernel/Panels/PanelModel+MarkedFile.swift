/// What is known about files among the marks.
extension PanelModel {
    /// Whether a file (something that is not a folder) is among the marked entries, once it
    /// has been looked for.
    internal enum MarkedFile {
        /// At least one marked entry is a file.
        case found
        /// Every marked entry is a folder.
        case notFound
        /// Not looked for since the marks last changed.
        case unknown
    }
}
