import AFMKernel
import Foundation

/// Ejects a drive the way the user expects it to.
///
/// What Commands › Eject Volume and the eject buttons of the drive bar and the path bar do:
///
/// 1. Every panel and folder tab that is on the drive goes back to the folder it showed before
///    it entered the drive (its history), or to the home folder; the panels are waited for.
/// 2. Everything in the program that shows or reads files of the drive lets go of them
///    (`FileSystemRegistry.releaseVolume`), and what is still to be written there is written
///    (`closeFiles`); a write that fails stops the eject, so nothing is lost.
/// 3. The system ejects the drive, gently: a drive another program still uses is refused. What
///    this program let go of a moment ago is given a moment to be gone.
/// 4. Done: a short notice says the drive can be removed. Refused: the panels go back to where
///    they were on the drive, and the user is told which program uses it.
///
/// Main thread, except what runs inside the jobs.
@MainActor
internal final class VolumeEjection {
    /// A tab that left the drive, and where it went.
    private struct Departure {
        weak var panel: any PanelHandle?
        weak var tab: PanelModel?
        let origin: URL
        var destination: URL
    }

    /// How often an eject that this program itself refused is tried again.
    nonisolated internal static let ownRefusalRetries = 4
    /// How long apart, in seconds, those tries are.
    nonisolated internal static let retryDelay: TimeInterval = 0.5

    /// Stands for the volumes in `BlockingCalls`: the questions to them are counted together.
    nonisolated private static let volumes = CallOwner()

    /// Unowned: the kernel owns the plugin, and through it this.
    private unowned let kernel: Kernel
    private let access: any VolumeAccess
    private let home: () -> URL
    private let note: (String) -> Void

    private var interaction: any UserInteraction { kernel.interaction }

    /// Ejects through `access`; a tab with nowhere else to go goes to `home`, and each eject is
    /// written to the log through `note`.
    internal init(
        kernel: Kernel,
        access: any VolumeAccess,
        home: @escaping () -> URL,
        note: @escaping (String) -> Void
    ) {
        self.kernel = kernel
        self.access = access
        self.home = home
        self.note = note
    }

    // MARK: Panels

    private static func isOn(_ url: URL, _ volume: URL) -> Bool {
        url.isFileURL && (url.isSameLocation(as: volume) || url.isInside(volume))
    }

    /// Asks something of a volume from a job.
    ///
    /// A volume that has stopped answering may never return: the question then goes on alone, and
    /// the job ends, with nil, once cancelled.
    nonisolated private static func ask<Answer: Sendable>(
        _ question: String,
        of url: URL,
        _ monitor: any JobMonitor,
        _ work: @escaping @Sendable () -> Answer
    ) -> Answer? {
        BlockingCalls.answer(from: volumes, to: question + " " + url.path, cancellation: monitor.cancellation) { _ in
            work()
        }
    }

    /// Writes what is pending on `volume` and ejects it; tries again a few times while it is this
    /// program itself that refuses.
    ///
    /// Blocks: on the job's thread.
    nonisolated private static func unmount(
        _ facts: VolumeFacts,
        volume: URL,
        access: any VolumeAccess,
        fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag
    ) -> Result<Void, any Error> {
        do {
            try fileSystems.closeFiles(on: volume, cancellation: cancellation)
        } catch {
            return .failure(error)
        }
        var refusal = access.eject(facts)
        // What this program let go of may take a moment to be gone (a folder watch
        // is closed on a thread of its own).
        for _ in 0..<ownRefusalRetries where refusal?.isThisProgram == true && !cancellation.isCancelled {
            Thread.sleep(forTimeInterval: retryDelay)
            refusal = access.eject(facts)
        }
        return refusal.map { .failure($0) } ?? .success(())
    }

    /// What the user is told of a refusal: who keeps the drive in use, as far as that is known.
    private static func detail(of refusal: EjectRefusal) -> String {
        if refusal.isThisProgram {
            return "Something in this program still uses it: a window that shows its files, "
                + "a search or a comparison. Close it, then eject the drive again."
        }
        if let program = refusal.program {
            return "It is in use by \(program). Close the files of the drive there, then eject it again."
        }
        return refusal.reason
    }

    /// Ejects the drive `directory` is on.
    internal func eject(driveOf directory: URL) {
        let volumeAccess = access
        kernel.jobs.run(
            title: "Volume:",
            work: { monitor in Self.ask("volume", of: directory, monitor) { volumeAccess.facts(of: directory) } },
            completion: { [self] answer in
                // Nil: the question was cancelled.
                guard let facts = answer else {
                    return
                }
                guard let volume = facts.url, facts.canBeEjected else {
                    let shown = DisplayText.oneLine(facts.name.isEmpty ? directory.path : facts.name, limit: 200)
                    return interaction.inform(
                        "\(shown) cannot be ejected.",
                        detail: "",
                        style: .warning
                    )
                }
                leave(volume) { [self] departures in
                    kernel.fileSystems.releaseVolume(volume)
                    eject(facts, volume: volume, departures: departures)
                }
            }
        )
    }

    private func eject(_ facts: VolumeFacts, volume: URL, departures: [Departure]) {
        let name = "“\(DisplayText.oneLine(facts.name, limit: 80))”"
        let volumeAccess = access
        let fileSystems = kernel.fileSystems
        kernel.jobs.run(
            title: "Ejecting \(name):",
            work: { monitor -> Result<Void, any Error>? in
                Self.ask("eject", of: volume, monitor) {
                    Self.unmount(
                        facts,
                        volume: volume,
                        access: volumeAccess,
                        fileSystems: fileSystems,
                        cancellation: monitor.cancellation
                    )
                }
            },
            completion: { [self] answer in
                // Cancelled: the panels stay where they went; the drive may still go.
                guard let answer else {
                    return
                }
                report(answer, name: name, volume: volume, departures: departures)
            }
        )
    }

    /// Tells the user how the eject of `volume` went; when it did not go, the tabs that left it
    /// come back.
    private func report(_ answer: Result<Void, any Error>, name: String, volume: URL, departures: [Departure]) {
        switch answer {
        case .success:
            note("eject: \(volume.path)")
            interaction.notice("\(name) can now be removed safely.")

        case .failure(let refusal as EjectRefusal):
            comeBack(departures, from: volume)
            interaction.inform(
                "\(name) cannot be ejected",
                detail: Self.detail(of: refusal) + "\nNothing on the drive was changed.",
                style: .warning
            )

        case .failure(let error):
            comeBack(departures, from: volume)
            interaction.inform(
                "\(name) was not ejected",
                detail: "What is still to be written to it could not be written: "
                    + "\(error.localizedDescription)\nThe drive stays connected, so that nothing is lost.",
                style: .warning
            )
        }
    }

    /// Takes every tab off the drive; `then` runs once the panels show where they went.
    private func leave(_ volume: URL, then proceed: @escaping ([Departure]) -> Void) {
        var departures: [Departure] = []
        var pending = 1
        let finished = {
            pending -= 1
            if pending == 0 { proceed(departures) }
        }
        for panel in kernel.panels.all {
            for tab in panel.tabs.tabs where Self.isOn(tab.directory, volume) {
                let destination = tab.lastVisited { $0.isFileURL && !Self.isOn($0, volume) } ?? home()
                let index = departures.count
                departures.append(Departure(panel: panel, tab: tab, origin: tab.directory, destination: destination))
                guard panel.model === tab else {
                    retarget(tab, to: destination)
                    continue
                }
                pending += 1
                panel.show(destination, focus: nil, history: .record) { [self] succeeded in
                    guard !succeeded else {
                        return finished()
                    }
                    // The folder before is gone too: home.
                    departures[index].destination = home()
                    panel.show(home(), focus: nil, history: .record) { _ in finished() }
                }
            }
        }
        finished()
    }

    /// The eject was refused: the tabs that are still where they went go back to the drive.
    private func comeBack(_ departures: [Departure], from _: URL) {
        for departure in departures {
            guard let panel = departure.panel, let tab = departure.tab, panel.tabs.tabs.contains(where: { $0 === tab }),
                tab.directory.isSameLocation(as: departure.destination)
            else { continue }
            if panel.model === tab {
                panel.show(departure.origin, focus: nil, history: .record, completion: nil)
            } else {
                retarget(tab, to: departure.origin)
            }
        }
    }

    /// Points a tab in the background at another folder; it is read when it is shown.
    private func retarget(_ tab: PanelModel, to location: URL) {
        let provider = try? kernel.fileSystems.provider(for: location)
        tab.open(
            location,
            parent: provider?.parent(of: location),
            root: provider?.root(of: location) ?? location,
            history: .record
        )
    }

    deinit {
        // Nothing to release.
    }
}
