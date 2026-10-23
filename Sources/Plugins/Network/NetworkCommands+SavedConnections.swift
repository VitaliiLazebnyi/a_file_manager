import AFMKernel
import Foundation

/// The list of saved connections and the dialog of one connection.
extension NetworkCommands {
    /// The fields of the connection dialog, filled from `connection`; `asksWhenEmpty` says that an
    /// empty password is asked for when connecting, else it leaves the stored one as it is.
    private static func detailFields(of connection: SavedConnection, asksWhenEmpty: Bool) -> [FormField] {
        [
            .text("name", "Session:", connection.name),
            .text("host", "Host name[:Port]:", connection.hostText),
            .choice(
                "kind",
                "Protocol:",
                SavedConnection.Kind.allCases.map(\.title),
                selected: connection.kind.rawValue
            ),
            .checkbox("anonymous", "Anonymous login (e-mail address as password)", connection.anonymous),
            .text("user", "User name:", connection.user),
            .password(
                "password",
                asksWhenEmpty ? "Password (empty: ask when connecting):" : "Password (empty: unchanged):"
            ),
            .checkbox("savePassword", "Keep the password in the macOS Keychain", true),
            .note("Passwords are stored in the Keychain, never in the settings; a master password is not needed."),
            .text("remote", "Remote dir:", connection.remoteDirectory),
            .text("local", "Local dir:", connection.localDirectory),
            .checkbox("passive", "Use passive mode for transfers (like a web browser)", connection.passive),
            .choice(
                "encoding",
                "Encoding of file names:",
                NameEncoding.allCases.map(\.title),
                selected: connection.encoding.rawValue
            ),
            .choice(
                "listing",
                "Directory listings:",
                SavedConnection.Listing.allCases.map(\.title),
                selected: connection.listing.rawValue
            ),
            .text("commands", "Send commands (separated by ;):", connection.initCommands)
        ]
    }

    /// Ctrl+F: the saved connections (spec 11 › "Connect to ftp server" dialog).
    internal func showConnections() {
        var selected = store.connections.firstIndex { $0.id == store.lastUsed } ?? 0
        dialog: while true {
            let connections = store.connections
            let rows = connections.isEmpty ? ["(no saved connections)"] : connections.map(\.listTitle)
            guard
                let answer = interaction.form(
                    "Connect to FTP server",
                    detail: "Connect to:",
                    fields: [.list("connection", "", rows, selected: selected)],
                    buttons: ["Connect", "New Connection…", "New URL…", "Duplicate Entry…", "Edit…", "Delete"]
                )
            else { break dialog }
            let row = answer.index("connection")
            let chosen = connections.indices.contains(row) ? connections[row] : nil
            selected = max(0, row)
            guard handle(button: answer.button, on: chosen, selected: &selected) else {
                break dialog
            }
        }
    }

    /// Does what the list's button `button` says with the connection `chosen`; false when the list closes.
    ///
    /// `selected` is the row the list shows next.
    private func handle(button: Int, on chosen: SavedConnection?, selected: inout Int) -> Bool {
        switch button {
        case 0:
            guard let chosen else {
                return true
            }
            connect(chosen.profile, path: nil, localDirectory: chosen.localDirectory, saved: chosen)
            return false

        case 1:
            addConnection(selecting: &selected)

        case 2:
            quickConnect()
            return false

        case 3:
            if let chosen { duplicate(chosen) }

        case 4:
            if let chosen { edit(chosen, isNew: false, offered: nil, passwordOf: nil) }

        default:
            if let chosen,
                interaction.choose(
                    "Delete the connection \(chosen.name)?",
                    detail: "",
                    buttons: ["Delete", "Cancel"],
                    style: .warning
                ) == 0
            {
                store.delete(chosen)
                selected = max(0, min(selected, store.connections.count - 1))
            }
        }
        return true
    }

    /// Opens the dialog of a new connection; the list then shows it in `selected`.
    private func addConnection(selecting selected: inout Int) {
        if let created = edit(SavedConnection(), isNew: true, offered: nil, passwordOf: nil),
            let row = store.connections.firstIndex(where: { $0.id == created.id })
        {
            selected = row
        }
    }

    /// Opens the dialog of a copy of `original`, saved as a new connection.
    private func duplicate(_ original: SavedConnection) {
        var copy = original
        copy.id = UUID()
        copy.name = original.name + " (2)"
        // The copy takes the password along, to whatever host and user it is saved with.
        edit(copy, isNew: true, offered: nil, passwordOf: original)
    }

    /// "FTP: connection details" (spec 11).
    ///
    /// Returns what was saved; nil on Cancel.
    ///
    /// The password is kept by the vault under the connection's server and login. It is never
    /// read here (the Keychain may make the main thread wait): an empty field leaves what is
    /// stored as it is, and the vault moves it along when the host or user was changed.
    /// `offered` is a password that is known already and is stored when the field is left
    /// empty (the one a quick connection was made with); `passwordOf` names the connection
    /// whose stored password this one takes over (the original of a copy).
    @discardableResult
    internal func edit(
        _ original: SavedConnection,
        isNew: Bool,
        offered: String?,
        passwordOf copied: SavedConnection?
    ) -> SavedConnection? {
        var connection = original
        var saved: SavedConnection?
        dialog: while true {
            let fields = Self.detailFields(of: connection, asksWhenEmpty: isNew && offered == nil && copied == nil)
            guard let answer = interaction.form("FTP: connection details", detail: "", fields: fields, buttons: ["OK"])
            else {
                break dialog
            }
            guard take(answer, into: &connection) else {
                continue
            }
            // What was stored for the connection as it was, under its old host and user.
            let before = copied ?? (isNew ? nil : original)
            store.save(connection)
            keepPassword(from: answer, for: connection, before: before, offered: offered, isCopy: copied != nil)
            saved = connection
            break dialog
        }
        return saved
    }

    /// Fills `connection` from the dialog's answer; false, after telling the user, when the host
    /// is none or the name is taken.
    private func take(_ answer: FormValues, into connection: inout SavedConnection) -> Bool {
        connection.name = answer.text("name").trimmingCharacters(in: .whitespaces)
        connection.anonymous = answer.flag("anonymous")
        connection.user = answer.text("user")
        connection.remoteDirectory = answer.text("remote").trimmingCharacters(in: .whitespaces)
        connection.localDirectory = answer.text("local").trimmingCharacters(in: .whitespaces)
        connection.passive = answer.flag("passive")
        connection.encoding = NameEncoding(rawValue: answer.index("encoding")) ?? .automatic
        connection.listing = SavedConnection.Listing(rawValue: answer.index("listing")) ?? .automatic
        connection.initCommands = answer.text("commands")
        let kind = SavedConnection.Kind(rawValue: answer.index("kind")) ?? .ftp
        guard connection.setHost(answer.text("host"), kind: kind) else {
            interaction.inform(
                "\(ServerAddress.removingPassword(from: answer.text("host"))) is not a host name.",
                detail: "",
                style: .warning
            )
            return false
        }
        if connection.name.isEmpty { connection.name = connection.host }
        let (id, name) = (connection.id, connection.name)
        if store.connections.contains(where: { other in
            other.id != id && other.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            interaction.inform("A connection named \(name) already exists.", detail: "", style: .warning)
            return false
        }
        return true
    }

    /// Stores, moves or removes the password of `connection` as the dialog's `answer` says.
    ///
    /// `before` is the connection whose stored password it had (as it was, or the original of a
    /// copy); `isCopy` says that the original keeps its own.
    private func keepPassword(
        from answer: FormValues,
        for connection: SavedConnection,
        before: SavedConnection?,
        offered: String?,
        isCopy: Bool
    ) {
        let vault = store.vault
        let typed = answer.text("password")
        let keeps = answer.flag("savePassword") && !connection.anonymous
        if !keeps {
            // Unticked: no password is kept, whatever was typed or known.
            if let before, !isCopy { vault.setPassword(nil, for: before) }
            vault.setPassword(nil, for: connection)
        } else if !typed.isEmpty {
            if let before, !isCopy { vault.carryPassword(from: before, to: connection, removing: true) }
            vault.setPassword(typed, for: connection)
        } else if let offered {
            vault.setPassword(offered, for: connection)
        } else if let before {
            // Unchanged: it follows the connection to its new host or user, or to the copy.
            vault.carryPassword(from: before, to: connection, removing: !isCopy)
        }
    }
}
