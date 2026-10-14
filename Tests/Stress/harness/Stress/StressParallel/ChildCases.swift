internal import AFMKernel
internal import Dispatch
internal import Foundation
internal import StressKit

/// The cases expected to deadlock or crash: each runs in a child process, for the parent to watch.
internal enum ChildCases {
    /// Runs the child case `name` (`StressParallel child <name>`) and ends the process.
    internal static func run(_ name: String) -> Never {
        let mainSyncs = NestedTree.mainSyncs
        switch name {
        case "main-in-map-bodies-sync-to-main":
            // The main thread is inside Parallel.map; bodies on helper threads call DispatchQueue.main.sync.
            say("child: main thread calls Parallel.map; helper-thread bodies call DispatchQueue.main.sync")
            let result = Parallel.map(Array(0..<64)) { (value: Int) -> Int in
                if !Thread.isMainThread {
                    DispatchQueue.main.sync { mainSyncs.add() }
                }
                return value * 2
            }
            say("child: returned, ordered=\(result == (0..<64).map { $0 * 2 }) mainSyncs=\(mainSyncs.count)")
            exit(0)

        case "main-in-map-all-bodies-sync-to-main":
            say("child: main thread calls Parallel.map; every body (also on main) calls DispatchQueue.main.sync")
            let result = Parallel.map(Array(0..<64)) { (value: Int) -> Int in
                DispatchQueue.main.sync { mainSyncs.add() }
                return value * 2
            }
            say("child: returned \(result.count)")
            exit(0)

        default:
            exit(2)
        }
    }

    /// Runs a child case; reports whether it ended, crashed or hung (then samples and kills it).
    internal static func watch(_ name: String, patience: Double, resultsDirectory: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["child", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            preconditionFailure("cannot start the child process: \(error)")
        }
        let deadline = now() + patience
        while process.isRunning, now() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            let file = resultsDirectory + "/parallel-child-\(name).sample.txt"
            sampleAndKill(process, into: file)
            say("CHILD \(name): DEADLOCK (no exit within \(patience)s); sample in \(file)")
        } else {
            let reason = process.terminationReason == .uncaughtSignal ? "signal" : "exit"
            say("CHILD \(name): exited status=\(process.terminationStatus) reason=\(reason)")
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.split(separator: "\n").prefix(12) {
            say("   | " + line)
        }
    }

    /// Writes a two-second `sample` of the hung `process` to `file`, then kills it.
    private static func sampleAndKill(_ process: Process, into file: String) {
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = ["\(process.processIdentifier)", "2", "-file", file]
        sample.standardOutput = FileHandle.nullDevice
        sample.standardError = FileHandle.nullDevice
        try? sample.run()
        sample.waitUntilExit()
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }
}
