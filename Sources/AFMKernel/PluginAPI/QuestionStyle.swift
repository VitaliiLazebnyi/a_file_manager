/// How serious a question or message is, which decides the picture of its dialog.
public enum QuestionStyle: Sendable {
    /// Something may be lost or cannot be undone.
    case critical
    /// Plain news, nothing wrong.
    case information
    /// Something went wrong, or the user should think twice.
    case warning
}
