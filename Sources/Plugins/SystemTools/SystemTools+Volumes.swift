import AFMKernel
import AppKit

/// System Information and the volume name (spec 12 › System Information, Volume label).
extension SystemTools {
    /// A screen as the dialog shows it: its pixels, and its points and scale when they differ.
    nonisolated internal static func display(_ size: NSSize, scale: CGFloat) -> String {
        let pixels = "\(Int(size.width * scale))x\(Int(size.height * scale))"
        return scale == 1 ? pixels : "\(pixels) (\(Int(size.width))x\(Int(size.height)) @\(Int(scale))x)"
    }

    /// Gathers the System Information in a job and shows it, with a button that copies it.
    internal func showSystemInformation() {
        let displays = NSScreen.screens.map { screen in
            Self.display(screen.frame.size, scale: screen.backingScaleFactor)
        }
        kernel.jobs.run(
            title: "System Information:",
            work: { monitor in
                SystemInformation.gather(displays: displays, cancellation: monitor.cancellation, asking: .system)
            },
            completion: { [self] gathered in
                // Nil: cancelled while a volume did not answer.
                guard let information = gathered else {
                    return
                }
                let answer = interaction.form(
                    "System Information",
                    detail: "",
                    fields: [.lines("information", "", information.text)],
                    buttons: ["OK", "Copy"]
                )
                if answer?.button == 1 {
                    desktop.copy(information.text)
                }
            }
        )
    }

    /// "Set volume label" (spec 12 › Volume label): renames the volume of the source panel
    /// through the system's own interface, which asks for rights itself where it needs them.
    internal func renameVolume() {
        let directory = model.directory
        let volumeAccess = desktop.volumes
        kernel.jobs.run(
            title: "Volume:",
            work: { monitor in
                Self.ask("volume", of: directory, monitor) { volumeAccess.facts(of: directory) }
            },
            completion: { [self] answer in
                // Nil: the question was cancelled.
                guard let facts = answer else {
                    return
                }
                guard let volume = facts.url else {
                    let shown = DisplayText.oneLine(directory.path, limit: 200)
                    return interaction.inform("The volume of \(shown) cannot be determined.")
                }
                askName(of: volume, facts)
            }
        )
    }

    /// Asks for the new name of `volume` and, when it is one a volume may have, renames it in a job.
    private func askName(of volume: URL, _ facts: VolumeFacts) {
        guard
            let name = interaction.prompt(
                "Set volume label - \(DisplayText.oneLine(volume.path, limit: 200))",
                value: facts.name,
                detail: "Volume label"
            )?
            .trimmingCharacters(in: .whitespaces), name != facts.name
        else { return }
        if let problem = VolumeName.problem(with: name) {
            interaction.inform(
                "The volume cannot be named \(DisplayText.oneLine(name, limit: 80))!",
                detail: problem,
                style: .warning
            )
            return
        }
        let rename = desktop.renameVolume
        kernel.jobs.run(
            title: "Renaming volume:",
            work: { monitor -> any Error?? in
                Self.ask("rename to \(name)", of: volume, monitor) { () -> any Error? in
                    do {
                        try rename(volume, name)
                        return nil
                    } catch {
                        return error
                    }
                }
            },
            completion: { [self] answer in
                guard let error = answer else {
                    return
                }
                if let error {
                    return interaction.report(
                        error,
                        title: "The volume \(DisplayText.oneLine(facts.name, limit: 80)) cannot be renamed!"
                    )
                }
                note("rename-volume: \(volume.path) -> \(name)")
                // A renamed volume is mounted under its new name; the panels follow or climb.
                for panel in kernel.panels.all {
                    panel.reload()
                }
            }
        )
    }
}
