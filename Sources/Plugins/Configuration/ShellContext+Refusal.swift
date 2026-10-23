/// Why a value is refused.
extension ShellContext {
    /// Why no value can stand at a place.
    internal enum Refusal: Error, Equatable {
        /// Inside `$'…'`, whose escapes the lexer does not follow.
        case ansiQuote
        /// Where a shell works a value out as a number.
        case arithmetic
        /// Right after a backslash.
        case backslash
        /// Between backticks.
        case backtick
        /// After a `case` inside `$(…)`, whose patterns end in a `)` of their own.
        case caseInSubstitution
        /// In a comment.
        case comment
        /// Right after a `$`.
        case dollar
        /// In or after a here-document.
        case hereDocument
        /// In or after a `${…}` with an operator.
        case parameterExpansion

        /// What the user is told, with what to write instead where there is something.
        internal var explanation: String {
            switch self {
            case .ansiQuote:
                return "A placeholder cannot stand inside $'…'. Use \"…\" or '…' instead."

            case .backtick:
                return "A placeholder cannot stand between backticks. Use $(…) instead."

            case .hereDocument:
                return "A placeholder cannot stand in or after a here-document (<<)."

            case .comment:
                return "A placeholder stands in a comment (after #)."

            case .backslash:
                return "A placeholder cannot follow a backslash. Put it in quotes instead."

            case .dollar:
                return "A placeholder cannot follow a $ sign."

            case .arithmetic:
                return "A placeholder cannot stand where the shell works out a number: in $((…)), ((…)), $[…], "
                    + "in the subscript of $name[…], or in a test that compares numbers (-eq, -lt …)."

            case .parameterExpansion:
                return "A placeholder cannot stand in or after a ${…} expression with an operator."

            case .caseInSubstitution:
                return "A placeholder cannot stand after a case statement inside $(…)."
            }
        }
    }
}
