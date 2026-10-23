import AFMKernel
import Foundation

/// Closing connections.
extension NetworkCommands {
    /// Ctrl+Shift+F (spec 11 › Disconnecting): closes the connection of the source panel, or
    /// of the other panel, or the one the user picks, and returns the panels that showed it to
    /// the local folder they came from.
    internal func disconnect() {
        guard let profile = connectionToClose(), offerToSave(profile) else {
            return
        }
        let key = profile.key
        for panel in kernel.panels.all where ServerKey(panel.model.directory) == key {
            panel.show(lastLocal[ObjectIdentifier(panel)] ?? FileManager.default.homeDirectoryForCurrentUser)
        }
        // Returns at once: saying goodbye waits for the server and is done in the background.
        center.disconnect(key)
    }

    /// The connection a panel shows (the source panel's first), the only one, or the one the user
    /// picks; nil when there is none or the user cancels.
    private func connectionToClose() -> ConnectionProfile? {
        let connected = center.connected
        guard !connected.isEmpty else {
            return nil
        }
        let panels = [source, kernel.panels.target]
        let shown = panels.lazy
            .compactMap { panel in
                ServerKey(panel.model.directory).flatMap { key in connected.first { $0.key == key } }
            }
            .first
        if let shown {
            return shown
        }
        if connected.count == 1 {
            return connected[0]
        }
        guard
            let row = interaction.pickRow(
                "FTP Disconnect",
                rows: connected.map(\.title),
                detail: "Close the connection to:",
                button: "Disconnect"
            )
        else { return nil }
        return connected[row]
    }

    /// A quick connection offers to be saved first; false when the user cancels the disconnect.
    private func offerToSave(_ profile: ConnectionProfile) -> Bool {
        guard profile.savedID == nil, kernel.settings.flag(NetworkSettings.askToSave, default: true) else {
            return true
        }
        let key = profile.key
        let answer = interaction.choose(
            "Current session not saved, save?",
            detail: key.description,
            buttons: ["Yes", "No", "Cancel"],
            style: .information
        )
        switch answer {
        case 0:
            var connection = SavedConnection()
            connection.kind = SavedConnection.Kind(scheme: key.scheme, tls: profile.tls)
            connection.host = key.host
            connection.setPort(key.port)
            connection.anonymous = profile.anonymous || profile.user == "anonymous"
            if !connection.anonymous, let user = profile.user { connection.user = user }
            connection.remoteDirectory = center.lastPath(on: key) ?? ""
            // The password the connection was made with is kept only if the box in the dialog stays ticked.
            edit(connection, isNew: true, offered: connection.anonymous ? nil : profile.password, passwordOf: nil)
            return true

        case 1:
            return true

        default:
            return false
        }
    }
}
