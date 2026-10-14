public import AFMKernel
import Foundation

/// Answers the program's questions from a script and records what was asked.
///
/// Not tied to the main thread, unlike a real interaction: a test's job may ask from a thread of
/// its own while the main thread waits for the job (`ImmediateJobService`). Unchecked: the
/// script and the records are guarded by `lock`.
nonisolated public final class ScriptedInteraction: UserInteraction, @unchecked Sendable {
    /// How a prompt for a line of text is answered.
    public enum PromptAnswer: Sendable {
        /// OK with the proposed text.
        case accept
        /// OK with this text in place of the proposed one.
        case text(String)
        /// Cancel.
        case cancel
    }

    /// How a form is answered.
    public enum FormAnswer: Sendable {
        /// The first button, with the fields as proposed.
        case accept
        /// A button, with these values in place of the proposed ones.
        case values([String: FormValues.Value], button: Int = 0)
        /// Cancel.
        case cancel
    }

    /// The answers still to be given, each list used from the front.
    private struct Script {
        var prompts: [PromptAnswer] = []
        var choices: [Int] = []
        var forms: [FormAnswer] = []
    }

    /// What was asked so far.
    private struct Records {
        var forms: [[FormField]] = []
        var log: [String] = []
    }

    private let lock = NSLock()
    private var script = Script()
    private var records = Records()

    /// The answers to the next prompts, in order; without an answer a prompt is cancelled.
    public var promptAnswers: [PromptAnswer] {
        get { lock.withLock { script.prompts } }
        set { lock.withLock { script.prompts = newValue } }
    }

    /// The buttons chosen in the next questions, in order; without an answer the last button
    /// (usually Cancel) is chosen.
    public var choiceAnswers: [Int] {
        get { lock.withLock { script.choices } }
        set { lock.withLock { script.choices = newValue } }
    }

    /// The answers to the next forms, in order; without an answer a form is cancelled.
    public var formAnswers: [FormAnswer] {
        get { lock.withLock { script.forms } }
        set { lock.withLock { script.forms = newValue } }
    }

    /// The fields of every form that was shown.
    public var forms: [[FormField]] { lock.withLock { records.forms } }

    /// One line per question, message or form, in the order they came: `"choose: <message> /
    /// <detail>"`, `"prompt: <message> [<value>]"`, `"inform: …"`, `"notice: …"`, `"form: <title>"`.
    public var log: [String] { lock.withLock { records.log } }

    /// Starts with no answers and an empty record.
    public init() {
        // Everything starts empty.
    }

    /// Records the prompt and answers it with the next scripted answer, from any thread.
    public func prompt(_ message: String, value: String, detail _: String) -> String? {
        record("prompt: \(message) [\(value)]")
        let answer = lock.withLock { script.prompts.isEmpty ? .cancel : script.prompts.removeFirst() }
        switch answer {
        case .accept:
            return value

        case .text(let text):
            return text

        case .cancel:
            return nil
        }
    }

    /// Records the question and answers it with the next scripted button, from any thread.
    public func choose(_ message: String, detail: String, buttons: [String], style _: QuestionStyle) -> Int {
        record("choose: \(message) / \(detail)")
        return lock.withLock { script.choices.isEmpty ? buttons.count - 1 : script.choices.removeFirst() }
    }

    /// Records the message.
    public func inform(_ message: String, detail _: String, style _: QuestionStyle) {
        record("inform: \(message)")
    }

    /// Records the notice.
    public func notice(_ message: String) {
        record("notice: \(message)")
    }

    /// Records the form and its fields and answers it with the next scripted answer, from any thread.
    public func form(_ title: String, detail _: String, fields: [FormField], buttons _: [String]) -> FormValues? {
        record("form: \(title)")
        let answer = lock.withLock {
            records.forms.append(fields)
            return script.forms.isEmpty ? .cancel : script.forms.removeFirst()
        }
        switch answer {
        case .accept:
            return FormValues(defaultsOf: fields)

        case .values(let values, let button):
            var filled = FormValues(defaultsOf: fields, button: button)
            filled.values.merge(values) { _, new in new }
            return filled

        case .cancel:
            return nil
        }
    }

    private func record(_ line: String) {
        lock.withLock { records.log.append(line) }
    }

    deinit {
        // Nothing to release.
    }
}
