import Foundation

public enum QuestionStyle: Sendable {
    case information, warning, critical
}

/// Every question the program asks goes through here, so plugins do not depend on windows
/// and can be driven by a script in tests.
@MainActor
public protocol UserInteraction: AnyObject, Sendable {
    /// A question with one text field. Returns nil on Cancel.
    func prompt(_ message: String, value: String, detail: String) -> String?
    /// Returns the index of the chosen button. Esc chooses the last one.
    func choose(_ message: String, detail: String, buttons: [String], style: QuestionStyle) -> Int
    /// The same with a say in which button Return presses: `defaultButton` is its index in
    /// `buttons`, nil for none at all (the user has to click, or press Esc for the last one).
    /// For questions whose first button destroys something or trusts somebody: a reflexive
    /// Return must not answer those. The default is `choose` without it, where Return presses
    /// the first button; whoever shows real dialogs offers this.
    func choose(_ message: String, detail: String, buttons: [String], style: QuestionStyle, defaultButton: Int?) -> Int
    func inform(_ message: String, detail: String, style: QuestionStyle)
    /// A short message that asks nothing and needs no answer ("… can be removed safely"):
    /// shown for a moment without holding anything up. The default is `inform`.
    func notice(_ message: String)
    /// A dialog with several fields. Every button in `buttons` accepts the dialog; a Cancel
    /// button is added to them, and nil is returned when the user takes it.
    func form(_ title: String, detail: String, fields: [FormField], buttons: [String]) -> FormValues?
}

extension UserInteraction {
    public func choose(
        _ message: String, detail: String, buttons: [String], style: QuestionStyle, defaultButton _: Int?
    )
        -> Int
    {
        choose(message, detail: detail, buttons: buttons, style: style)
    }

    public func prompt(_ message: String, value: String = "") -> String? {
        prompt(message, value: value, detail: "")
    }

    public func form(_ title: String, fields: [FormField]) -> FormValues? {
        form(title, detail: "", fields: fields, buttons: ["OK"])
    }

    /// Lets the user pick one row of a list; nil on Cancel.
    public func pickRow(_ title: String, detail: String = "", rows: [String], selected: Int = 0, button: String = "OK")
        -> Int?
    {
        guard
            let answer = form(
                title, detail: detail, fields: [.list("row", "", rows, selected: selected)], buttons: [button])
        else { return nil }
        let row = answer.index("row")
        return rows.indices.contains(row) ? row : nil
    }

    public func inform(_ message: String) {
        inform(message, detail: "", style: .information)
    }

    public func notice(_ message: String) {
        inform(message)
    }

    public func report(_ error: any Error, title: String) {
        inform(title, detail: error.localizedDescription, style: .warning)
    }

    /// A question whose buttons stand for values; `fallback` when the dialog is dismissed.
    public func pick<Choice>(
        _ message: String, detail: String, _ choices: [(String, Choice)], fallback: Choice,
        style: QuestionStyle = .warning
    ) -> Choice {
        let index = choose(message, detail: detail, buttons: choices.map(\.0), style: style)
        return choices.indices.contains(index) ? choices[index].1 : fallback
    }
}
