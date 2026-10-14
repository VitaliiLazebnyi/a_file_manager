internal import Foundation

/// The file and process helpers of the fuzzer.
internal enum FuzzFiles {
    /// The FNV-1a hash of `data`: names corpus files and remembers inputs already run.
    internal static func fnv(_ data: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return hash
    }

    /// `value` in hexadecimal digits.
    internal static func hex(_ value: UInt64) -> String {
        String(value, radix: 16)
    }

    /// The contents of the file at `path`, or nil when it cannot be read.
    internal static func read(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    /// The file at `path` as text: UTF-8, or Latin-1 when it is not, so that a log always reads.
    internal static func readText(_ path: String) -> String {
        let data = read(path) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
    }

    /// Writes `data` to `path`, replacing what is there.
    internal static func write(_ path: String, _ data: [UInt8]) {
        FileManager.default.createFile(atPath: path, contents: Data(data))
    }

    /// The paths of the items in the folder at `path`, sorted; empty when it cannot be read.
    internal static func list(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted().map { path + "/" + $0 }
    }

    /// Makes the folder at `path` and its parents.
    internal static func makeFolder(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    /// Where the targets may write: `$FZ_WORK`, or `afm-fuzz` in the system's temporary folder.
    internal static func workBase() -> String {
        var base = FileManager.default.temporaryDirectory.appendingPathComponent("afm-fuzz").path
        if let dir = ProcessInfo.processInfo.environment["FZ_WORK"], !dir.isEmpty {
            base = dir
        }
        makeFolder(base)
        // The real path (/private/var/… for /var/…): targets compare the paths they get back with it.
        if let real = realpath(base, nil) {
            base = String(cString: real)
            free(real)
        }
        return base
    }

    /// Removes a work folder, also when a target left folders without write permission in it.
    internal static func removeWork(_ path: String) {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            return
        }
        if (try? FileManager.default.removeItem(atPath: path)) == nil {
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["-R", "u+rwx", path]
            chmod.standardError = FileHandle.nullDevice
            if (try? chmod.run()) != nil {
                chmod.waitUntilExit()
            }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// A folder name for a finding's signature: its letters and digits, and a hash of the whole.
    internal static func safeName(_ text: String) -> String {
        let hash = hex(fnv(Array(text.utf8)))
        let head = String(text.map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(60))
        return head + "-" + String(hash.prefix(8))
    }

    /// Runs this program again with `arguments` (and `environment` added), output into `log`.
    ///
    /// Returns the exit status, or 128 plus the signal that ended it.
    internal static func launch(_ arguments: [String], log: String, environment: [String: String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = arguments
        FileManager.default.createFile(atPath: log, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: log) else {
            print("cannot write \(log)")
            exit(1)
        }
        process.standardError = handle
        process.standardOutput = handle
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        do {
            try process.run()
        } catch {
            print("cannot start worker: \(error)")
            exit(1)
        }
        process.waitUntilExit()
        try? handle.close()
        // A run that was killed could not remove its own work folder.
        if arguments.first == "run" {
            removeWork(workBase() + "/fzrun-\(process.processIdentifier)")
        }
        let status = process.terminationStatus
        return process.terminationReason == .uncaughtSignal ? 128 + status : status
    }
}
