import AFMContracts

/// Names as they are shown in questions and written to the log.
///
/// A file name may hold anything but `/` and NUL: line breaks, characters that turn the reading
/// direction around, characters without width. Shown raw, such a name can make a question say
/// something else than it asks, or add lines to a log.
public enum DisplayName {
    /// The text with every such character written out as `<U+202E>`: the program's one
    /// rule for it (`Format.displayName`), so that every message shows a name the same way.
    public static func escaped(_ text: String) -> String {
        Format.displayName(text)
    }
}
