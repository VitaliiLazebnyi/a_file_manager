import Foundation

/// Everything a mask needs besides the item itself.
///
/// A value, so that a preview computed on several threads works on one fixed state.
internal struct RenameContext {
    /// The number of items in the list, for `[c]` and automatic counter widths.
    internal var count = 1
    /// The counter `[C]` of "Define counter".
    internal var counter = CounterDefinition()
    /// `[T2]`: when the tool was opened.
    internal var opened = Date()
    /// `[T3]`: when the rename options were last changed.
    internal var changed = Date()
    /// `[X]`: the text on the clipboard, nil when there is none.
    internal var clipboard: String?
    /// `[X]` when `clipboard` is not set: asked only if a mask uses it, on the thread that
    /// works out the names, and answered from the clipboard as it was when the preview began.
    internal var clipboardLoader: (@Sendable () -> String?)?
    /// The environment variables, for `[%NAME%]`.
    internal var environment: [String: String] = [:]
    /// The words title case keeps in lower case.
    internal var titleRule = TitleCaseRule.standard
    /// The locale of `[d]` and `[t]`.
    internal var locale = Locale.current
    /// The time zone the dates and times are written in.
    internal var timeZone = TimeZone.current
    /// `[T4]`: the date recorded inside a picture.
    ///
    /// Called on the preview threads, several at once.
    internal var contentDate: (@Sendable (RenameSubject) -> Date?)?
}
