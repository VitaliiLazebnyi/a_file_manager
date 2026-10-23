import AFMKernel

/// Shows no dialogs: keeps every question with the button Return would press, and answers
/// the way `answer` says (by default: Return).
internal final class P2RecordingUI: UserInteraction {
    /// A question that was asked, as the user would have seen it.
    internal struct Question {
        /// The question's text.
        internal let message: String
        /// The buttons offered, in order.
        internal let buttons: [String]
        /// The button Return presses; -1 when the question was asked without saying so.
        internal let defaultButton: Int?
    }

    /// Every question with buttons, in the order they were asked.
    internal private(set) var questions: [Question] = []
    /// Every message that only informed, in that order.
    internal private(set) var messages: [String] = []
    /// The title of every form that was shown, in that order.
    internal private(set) var forms: [String] = []
    /// The index of the chosen button; nil presses Return.
    internal var answer: (Question) -> Int? = { _ in nil }
    /// What a form is filled in with; nil cancels it.
    internal var formAnswer: ([FormField]) -> FormValues? = { _ in nil }
    /// What a prompt answers, given the proposed value; nil cancels it.
    internal var promptAnswer: (String) -> String? = { _ in nil }

    /// Answers with `promptAnswer`.
    internal func prompt(_: String, value: String, detail _: String) -> String? { promptAnswer(value) }
    /// Keeps the question, marked as asked without a default button, and answers with `answer` or the first button.
    internal func choose(_ message: String, detail _: String, buttons: [String], style _: QuestionStyle) -> Int {
        let question = Question(message: message, buttons: buttons, defaultButton: -1)
        questions.append(question)
        return answer(question) ?? 0
    }
    /// Keeps the question and answers with `answer`, or with the button Return presses.
    internal func choose(
        _ message: String,
        detail _: String,
        buttons: [String],
        style _: QuestionStyle,
        defaultButton: Int?
    )
        -> Int
    {
        let question = Question(message: message, buttons: buttons, defaultButton: defaultButton)
        questions.append(question)
        // Return presses the default button; without one, nothing happens until Esc: the last.
        return answer(question) ?? defaultButton ?? buttons.count - 1
    }
    /// Keeps the message.
    internal func inform(_ message: String, detail _: String, style _: QuestionStyle) { messages.append(message) }
    /// Keeps the form's title and answers with `formAnswer`.
    internal func form(_ title: String, detail _: String, fields: [FormField], buttons _: [String]) -> FormValues? {
        forms.append(title)
        return formAnswer(fields)
    }

    deinit {
        // Nothing to release.
    }
}
