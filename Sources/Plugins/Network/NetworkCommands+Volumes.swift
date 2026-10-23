import AFMKernel
import Foundation

/// Network volumes: Connect to Server and Eject Volume.
extension NetworkCommands {
    /// Connect to Server (spec 11 › Map a network drive, adapted): an address of a file server
    /// is mounted by the system and shown in the source panel; an FTP or SFTP address opens a
    /// connection of this program.
    internal func connectToServer(_ given: String?) {
        // An address stored by an older version may still carry a password; it is not shown again.
        let proposal = ServerAddress.removingPassword(
            from: kernel.settings.text(NetworkSettings.lastServer, default: "smb://")
        )
        guard
            let text =
                (given
                ?? interaction.prompt(
                    "Connect to Server",
                    value: proposal,
                    detail: "smb://, afp://, nfs://, https:// (WebDAV), or ftp://, ftps://, sftp://"
                ))?
                .trimmingCharacters(in: .whitespaces), !text.isEmpty
        else { return }
        if let address = ServerAddress(text), text.contains("://") {
            let user = address.user ?? (address.scheme == "sftp" ? NSUserName() : nil)
            connect(
                ConnectionProfile(
                    key: address.key,
                    tls: address.tls,
                    user: user,
                    password: address.password,
                    anonymous: user == nil
                ),
                path: address.hasPath ? address.path : nil,
                localDirectory: nil,
                saved: nil
            )
            return
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
            ServerSchemes.mountable.contains(scheme), let host = url.host
        else {
            // What was typed may hold a password; it is not shown again.
            interaction.inform(
                "\(ServerAddress.removingPassword(from: text)) is not the address of a server.",
                detail: "",
                style: .warning
            )
            return
        }
        // The address is offered again next time; a password in it is not kept.
        kernel.settings.set(ServerAddress.removingPassword(from: text), forKey: NetworkSettings.lastServer)
        mount(url, named: host)
    }

    /// Mounts the share at `url` in a job and shows it in the source panel; `host` names the job.
    private func mount(_ url: URL, named host: String) {
        guard let mounter else {
            return
        }
        let panel = source
        kernel.jobs.run(
            title: "Connect to \(host)",
            work: { monitor in
                Result { try mounter.mount(url, cancellation: monitor.cancellation) }
            },
            completion: { [kernel] result in
                switch result {
                case .success(let volumes):
                    if let volume = volumes.first { panel.show(volume) }

                case .failure(NetworkError.cancelled):
                    break

                case .failure(let error):
                    kernel.interaction.report(error, title: "Connect failed!")
                }
            }
        )
    }

    /// Ejects the volume the source panel shows; the panels leave it first.
    internal func ejectVolume() {
        guard let mounter, let volume = ServerSchemes.mountedVolume(of: source.model.directory) else {
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let inside = kernel.panels.all.filter { panel in
            panel.model.directory.isSameLocation(as: volume) || panel.model.directory.isInside(volume)
        }
        // The source panel is among them, so the volume is ejected once the last has left.
        var leaving = inside.count
        let eject = { [kernel] in
            _ = kernel.jobs.run(
                title: "Eject \(volume.lastPathComponent)",
                work: { _ in Result { try mounter.unmount(volume) } },
                completion: { result in
                    if case .failure(let error) = result {
                        kernel.interaction.report(error, title: "\(volume.lastPathComponent) cannot be ejected!")
                    }
                }
            )
        }
        for panel in inside {
            panel.show(home, focus: nil, history: .record) { _ in
                leaving -= 1
                if leaving == 0 { eject() }
            }
        }
    }
}
