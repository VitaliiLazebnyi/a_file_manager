import Foundation

/// Every question the program asks goes through here, so plugins do not depend on windows and can be driven by a script
/// in tests.
///
/// Main thread.
@preconcurrency
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
    /// Tells the user something and waits until it was read.
    func inform(_ message: String, detail: String, style: QuestionStyle)
    /// A short message that asks nothing and needs no answer ("… can be removed safely"):
    /// shown for a moment without holding anything up. The default is `inform`.
    func notice(_ message: String)
    /// A dialog with several fields. Every button in `buttons` accepts the dialog; a Cancel
    /// button is added to them, and nil is returned when the user takes it.
    func form(_ title: String, detail: String, fields: [FormField], buttons: [String]) -> FormValues?
}

/// The shorter ways to ask, and what a simple implementation need not offer.
extension UserInteraction {
    /// `choose` without a say in the default button: Return presses the first one.
    public func choose(
        _ message: String,
        detail: String,
        buttons: [String],
        style: QuestionStyle,
        defaultButton _: Int?
    )
        -> Int
    {
        choose(message, detail: detail, buttons: buttons, style: style)
    }

    /// A question with one text field and no detail; nil on Cancel.
    public func prompt(_ message: String, value: String = "") -> String? {
        prompt(message, value: value, detail: "")
    }

    /// A dialog with several fields and one OK button; nil on Cancel.
    public func form(_ title: String, fields: [FormField]) -> FormValues? {
        form(title, detail: "", fields: fields, buttons: ["OK"])
    }

    /// Lets the user pick one row of a list; nil on Cancel.
    public func pickRow(_ title: String, rows: [String], detail: String = "", selected: Int = 0, button: String = "OK")
        -> Int?
    {
        guard
            let answer = form(
                title,
                detail: detail,
                fields: [.list("row", "", rows, selected: selected)],
                buttons: [button]
            )
        else { return nil }
        let row = answer.index("row")
        return rows.indices.contains(row) ? row : nil
    }

    /// Tells the user something plain, without detail.
    public func inform(_ message: String) {
        inform(message, detail: "", style: .information)
    }

    /// Shows a short message as a plain one.
    public func notice(_ message: String) {
        inform(message)
    }

    /// Tells the user that something failed: `title` says what, the error why.
    public func report(_ error: any Error, title: String) {
        inform(title, detail: error.localizedDescription, style: .warning)
    }

    /// A question whose buttons stand for values; `fallback` when the dialog is dismissed.
    public func pick<Choice>(
        _ message: String,
        detail: String,
        _ choices: [(String, Choice)],
        fallback: Choice,
        style: QuestionStyle = .warning
    ) -> Choice {
        let index = choose(message, detail: detail, buttons: choices.map(\.0), style: style)
        return choices.indices.contains(index) ? choices[index].1 : fallback
    }
}
