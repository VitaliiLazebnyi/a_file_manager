import AFMKernel
import Foundation

/// A command the user defined (spec 14 › User commands (`em_`)).
///
/// It is registered like any other command, so keys, the button bar, menus and the command line
/// reach it by its name.
internal struct UserCommand: Codable, Equatable {
    /// What the name of every user command starts with.
    internal static let prefix = "em_"

    /// The full name, `em_backup`.
    internal var name: String
    /// The title the user gave it; empty when menus and lists show the name.
    internal var title: String
    /// What the command does.
    internal var action = CommandAction()
    /// A system symbol for the button bar; empty for none.
    internal var symbol = ""

    /// The name it is registered under.
    internal var id: CommandID { CommandID(rawValue: name) }
    /// What menus and lists show.
    internal var caption: String { title.isEmpty ? String(name.dropFirst(Self.prefix.count)) : title }

    /// The name as it is stored: letters, digits and `_` after `em_`.
    ///
    /// Nil when nothing usable is left of what the user typed.
    internal static func name(from text: String) -> String? {
        var typed = text.trimmingCharacters(in: .whitespaces)
        if typed.lowercased().hasPrefix(prefix) { typed.removeFirst(prefix.count) }
        let allowed = typed.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
        return allowed && !typed.isEmpty ? prefix + typed : nil
    }
}
