/// One line of a text file: its text without the line break, and the break it ends with.
public struct TextLine: Equatable, Sendable {
    /// The text of the line, without its line break.
    public var text: String
    /// The line break the line ends with.
    public var ending: LineEnding
    /// The line's number in the file as it was loaded; 0 for lines added or changed since
    /// (spec 09 › Edit mode and saving).
    public var number: Int

    /// A line of `text` ending with `ending`; `number` 0 for a line that was not loaded.
    public init(_ text: String, ending: LineEnding = .lineFeed, number: Int = 0) {
        self.text = text
        self.ending = ending
        self.number = number
    }
}
