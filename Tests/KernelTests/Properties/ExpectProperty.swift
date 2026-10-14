public import TestSupport
import Testing

/// Records a test issue unless `holds` is true for `count` values of `generator`.
///
/// The issue names the smallest counterexample shrinking found. Public only so that it may take
/// the test's name and place by default.
public func expectProperty<Value>(
    _ generator: Generator<Value>,
    count: Int = 200,
    name: String = #function,
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column,
    _ holds: (Value) -> Bool
) {
    if let failure = Property.check(generator, count: count, name: name, holds) {
        Issue.record(
            Comment(rawValue: failure.description),
            sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
        )
    }
}
