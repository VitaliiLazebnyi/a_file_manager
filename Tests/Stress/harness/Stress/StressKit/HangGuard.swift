internal import Foundation

/// Ends the process with a `sample` of itself when a step takes longer than allowed.
///
/// Unchecked: the deadline, the label, the sample folder and the hang handler are guarded by `lock`.
public final class HangGuard: @unchecked Sendable {
    /// The one guard of the process.
    public static let shared = HangGuard()

    /// Guards every stored property.
    private let lock = NSLock()
    /// When the armed step runs out of time; infinity while disarmed.
    private var deadline = Double.infinity
    /// The armed step.
    private var label = ""
    /// Whether the guard thread runs.
    private var started = false
    /// Where samples are written; set with `sampleDirectory`.
    private var sampleFolder = FileManager.default.currentDirectoryPath
    /// Called instead of exiting; set with `onHang`.
    private var hangHandler: (@Sendable (String) -> Bool)?

    /// Where samples are written (the current folder at first).
    public var sampleDirectory: String {
        get { locked { sampleFolder } }
        set { locked { sampleFolder = newValue } }
    }

    /// Called with the step's label instead of exiting when set; returns true to go on living.
    public var onHang: (@Sendable (String) -> Bool)? {
        get { locked { hangHandler } }
        set { locked { hangHandler = newValue } }
    }

    /// Gives the step called `label` `seconds` from now.
    public func arm(_ label: String, seconds: Double) {
        let start = locked {
            self.label = label
            deadline = now() + seconds
            defer { started = true }
            return !started
        }
        guard start else {
            return
        }
        let thread = Thread { [self] in
            watch()
        }
        thread.name = "Stress.HangGuard"
        thread.start()
    }

    /// Takes the time limit away.
    public func disarm() {
        locked {
            deadline = .infinity
        }
    }

    /// The guard thread: looks at the deadline five times a second.
    private func watch() {
        while true {
            usleep(200_000)
            let (limit, name, folder, handler) = locked { (deadline, label, sampleFolder, hangHandler) }
            guard now() > limit else {
                continue
            }
            let safe = name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "_")
            let file = folder + "/hang-\(safe)-\(getpid()).sample.txt"
            say("!!!! HANG: '\(name)' exceeded its time limit; threads=\(threadCount()); sampling to \(file)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = ["\(getpid())", "3", "-file", file]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            if let handler, handler(name) {
                disarm()
                continue
            }
            MainWatchdog.shared.report(title: "at hang")
            exit(97)
        }
    }

    /// Runs `body` with `lock` held.
    private func locked<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    deinit {
        // Nothing to release: the one guard lives as long as the process.
    }
}
