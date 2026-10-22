import AFMKernel
public import AppKit
import Darwin

/// What is known of the volume a folder is on.
public struct VolumeFacts: Equatable, Sendable {
    public var url: URL?
    public var name = ""
    public var canBeEjected = false
    /// A share of a server: unmounted, there is no disk to eject.
    public var isNetwork = false

    public init(url: URL? = nil, name: String = "", canBeEjected: Bool = false, isNetwork: Bool = false) {
        (self.url, self.name, self.canBeEjected, self.isNetwork) = (url, name, canBeEjected, isNetwork)
    }
}

/// Why a volume was not ejected: who keeps it in use, if the system says.
public struct EjectRefusal: Error, Equatable {
    /// The program that has something open on the volume, by name; nil when not known.
    public var program: String?
    /// True when that program is this one.
    public var isThisProgram = false
    /// What the system said.
    public var reason: String

    public init(program: String? = nil, isThisProgram: Bool = false, reason: String) {
        (self.program, self.isThisProgram, self.reason) = (program, isThisProgram, reason)
    }
}

/// How volumes are looked at and ejected.
///
/// Both calls ask the volume and may wait on it: they run on a job's thread. Tests put a stand-in
/// in place of the system.
public protocol VolumeAccess: AnyObject, Sendable {
    func facts(of directory: URL) -> VolumeFacts
    /// Ejects gently: the system writes what is pending and refuses while any program has a
    /// file of the volume open. Nil when the volume is gone.
    func eject(_ volume: VolumeFacts) -> EjectRefusal?
}

/// The volumes of this Mac, ejected by `unmount`: the system's, or a stand-in that ejects nothing.
internal final class SystemVolumes: VolumeAccess {
    /// Unmounts a volume and then calls back, on a queue of its own, with what went wrong, if anything.
    internal typealias Unmount =
        @Sendable (URL, FileManager.UnmountOptions, @escaping @Sendable ((any Error)?) -> Void) -> Void

    /// The system's.
    internal static let unmount: Unmount = {
        FileManager.default.unmountVolume(at: $0, options: $1, completionHandler: $2)
    }

    private let unmountVolume: Unmount

    internal init(unmount: @escaping Unmount) {
        unmountVolume = unmount
    }

    deinit {
        // Nothing to release.
    }

    internal func facts(of directory: URL) -> VolumeFacts {
        let keys: Set<URLResourceKey> = [
            .volumeURLKey, .volumeNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey,
            .volumeIsLocalKey, .volumeIsRootFileSystemKey
        ]
        // Every mounted volume has a name.
        guard let values = try? directory.resourceValues(forKeys: keys), let url = values.volume,
            let name = values.volumeName
        else {
            return VolumeFacts()
        }
        let canBeEjected = Place.VolumeTraits(path: url.path, values: values).mayBeEjected
        return VolumeFacts(url: url, name: name, canBeEjected: canBeEjected, isNetwork: values.volumeIsLocal == false)
    }

    internal func eject(_ volume: VolumeFacts) -> EjectRefusal? {
        guard let url = volume.url else {
            return EjectRefusal(reason: "The volume is not known.")
        }
        // Never forced: a drive something still writes to is refused, not cut off. A disk
        // goes as a whole, with its other volumes, so that it can be taken out.
        let options: FileManager.UnmountOptions = volume.isNetwork ? [] : [.allPartitionsAndEjectDisk]
        let done = DispatchSemaphore(value: 0)
        /// Set by the callback before `done` is signalled, and read only after the wait.
        nonisolated(unsafe) var failure: (any Error)?
        unmountVolume(url, options) { error in
            failure = error
            done.signal()
        }
        done.wait()
        guard let failure else {
            return nil
        }
        let error = failure as NSError
        let dissenter = (error.userInfo[NSFileManagerUnmountDissentingProcessIdentifierErrorKey] as? NSNumber)?
            .int32Value
        return EjectRefusal(
            program: dissenter.flatMap(Self.programName),
            isThisProgram: dissenter == getpid(),
            reason: error.localizedDescription
        )
    }

    /// The name the user knows a program by: the application's, else the process's.
    internal static func programName(_ pid: pid_t) -> String? {
        guard pid > 0 else {
            return nil
        }
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName {
            return name
        }
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else {
            return nil
        }
        return SystemText.string(buffer)
    }
}

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
    /// Unowned: the kernel owns the plugin, and through it this.
    private unowned let kernel: Kernel
    private let access: any VolumeAccess
    private let home: () -> URL
    private let note: (String) -> Void
    /// How often, and how long apart, an eject that this program itself refused is tried again.
    nonisolated internal static let ownRefusalRetries = 4
    nonisolated internal static let retryDelay: TimeInterval = 0.5

    internal init(kernel: Kernel, access: any VolumeAccess, home: @escaping () -> URL, note: @escaping (String) -> Void)
    {
        self.kernel = kernel
        self.access = access
        self.home = home
        self.note = note
    }

    private var ui: any UserInteraction { kernel.interaction }

    /// A tab that left the drive, and where it went.
    private struct Departure {
        weak var panel: any PanelHandle?
        weak var tab: PanelModel?
        let from: URL
        var to: URL
    }

    /// Ejects the drive `directory` is on.
    internal func eject(driveOf directory: URL) {
        let access = self.access
        kernel.jobs.run(
            title: "Volume:",
            work: { monitor in Self.ask("volume", of: directory, monitor) { access.facts(of: directory) } },
            completion: { [self] answer in
                // Nil: the question was cancelled.
                guard let facts = answer else {
                    return
                }
                guard let volume = facts.url, facts.canBeEjected else {
                    return ui.inform(
                        "\(DisplayText.oneLine(facts.name.isEmpty ? directory.path : facts.name)) cannot be ejected.",
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
        let access = self.access
        let fileSystems = kernel.fileSystems
        kernel.jobs.run(
            title: "Ejecting \(name):",
            work: { monitor -> Result<Void, any Error>? in
                Self.ask("eject", of: volume, monitor) { () -> Result<Void, any Error> in
                    do {
                        try fileSystems.closeFiles(on: volume, cancellation: monitor.cancellation)
                    } catch {
                        return .failure(error)
                    }
                    var refusal = access.eject(facts)
                    // What this program let go of may take a moment to be gone (a folder watch
                    // is closed on a thread of its own).
                    for _ in 0..<Self.ownRefusalRetries
                    where refusal?.isThisProgram == true && !monitor.cancellation.isCancelled {
                        Thread.sleep(forTimeInterval: Self.retryDelay)
                        refusal = access.eject(facts)
                    }
                    return refusal.map { .failure($0) } ?? .success(())
                }
            },
            completion: { [self] answer in
                // Cancelled: the panels stay where they went; the drive may still go.
                guard let answer else {
                    return
                }
                switch answer {
                case .success:
                    note("eject: \(volume.path)")
                    ui.notice("\(name) can now be removed safely.")

                case .failure(let refusal as EjectRefusal):
                    comeBack(departures, from: volume)
                    let detail: String
                    if refusal.isThisProgram {
                        detail =
                            "Something in this program still uses it: a window that shows its files, a search or a comparison. "
                            + "Close it, then eject the drive again."
                    } else if let program = refusal.program {
                        detail = "It is in use by \(program). Close the files of the drive there, then eject it again."
                    } else {
                        detail = refusal.reason
                    }
                    ui.inform(
                        "\(name) cannot be ejected",
                        detail: detail + "\nNothing on the drive was changed.",
                        style: .warning
                    )

                case .failure(let error):
                    comeBack(departures, from: volume)
                    ui.inform(
                        "\(name) was not ejected",
                        detail: "What is still to be written to it could not be written: "
                            + "\(error.localizedDescription)\nThe drive stays connected, so that nothing is lost.",
                        style: .warning
                    )
                }
            }
        )
    }

    // MARK: Panels

    private static func isOn(_ url: URL, _ volume: URL) -> Bool {
        url.isFileURL && (url.isSameLocation(as: volume) || url.isInside(volume))
    }

    /// Takes every tab off the drive; `then` runs once the panels show where they went.
    private func leave(_ volume: URL, then proceed: @escaping ([Departure]) -> Void) {
        var departures: [Departure] = []
        var pending = 1
        func finished() {
            pending -= 1
            if pending == 0 { proceed(departures) }
        }
        for panel in kernel.panels.all {
            for tab in panel.tabs.tabs where Self.isOn(tab.directory, volume) {
                let to = tab.lastVisited { $0.isFileURL && !Self.isOn($0, volume) } ?? home()
                let index = departures.count
                departures.append(Departure(panel: panel, tab: tab, from: tab.directory, to: to))
                guard panel.model === tab else {
                    retarget(tab, to: to)
                    continue
                }
                pending += 1
                panel.show(to, focus: nil, history: .record) { [self] succeeded in
                    guard !succeeded else {
                        return finished()
                    }
                    // The folder before is gone too: home.
                    departures[index].to = home()
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
                tab.directory.isSameLocation(as: departure.to)
            else { continue }
            if panel.model === tab {
                panel.show(departure.from, focus: nil, history: .record, completion: nil)
            } else {
                retarget(tab, to: departure.from)
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

    /// Stands for the volumes in `BlockingCalls`: the questions to them are counted together.
    nonisolated private static let volumes = CallOwner()

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
}
