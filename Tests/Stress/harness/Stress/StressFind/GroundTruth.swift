internal import Darwin
internal import Dispatch
internal import Foundation
internal import TestSupport

/// What the searches must find, found without the program's code.
internal enum GroundTruth {
    /// Every regular file below `root` (readdir), hidden ones left out.
    internal static func allFiles(_ root: URL) -> [String] {
        var result: [String] = []
        var stack = [root.path]
        while let directory = stack.popLast() {
            guard let handle = opendir(directory) else {
                continue
            }
            while let entry = readdir(handle) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." || name.hasPrefix(".") {
                    continue
                }
                let path = directory + "/" + name
                if entry.pointee.d_type == DT_DIR {
                    stack.append(path)
                } else {
                    result.append(path)
                }
            }
            closedir(handle)
        }
        return result
    }

    /// Whether the file at `path` holds `pattern`.
    internal static func contains(_ path: String, _ pattern: String, caseInsensitive: Bool) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return false
        }
        if info.st_size > 1 << 24 {
            // Large files are not mapped (that would count as this process's memory): `grep` reads them.
            return grep(path, pattern)
        }
        let bytes = Array(pattern.utf8)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count >= bytes.count else {
            return false
        }
        let lower = bytes.map { folded($0, true) }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            find(lower, in: raw.bindMemory(to: UInt8.self), caseInsensitive: caseInsensitive)
        }
    }

    /// The paths of `paths` that pass `test`, tested on every core.
    internal static func parallelFilter(_ paths: [String], _ test: @Sendable (String) -> Bool) -> Set<String> {
        let found = Shared(Set<String>())
        let chunk = max(1, paths.count / 64)
        DispatchQueue.concurrentPerform(iterations: (paths.count + chunk - 1) / chunk) { part in
            var own: [String] = []
            for path in paths[(part * chunk)..<min(paths.count, (part + 1) * chunk)] where test(path) {
                own.append(path)
            }
            found.modify { $0.formUnion(own) }
        }
        return found.value
    }

    /// Whether `/usr/bin/grep -qai` finds `pattern` in the file at `path`.
    private static func grep(_ path: String, _ pattern: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = ["-qai", pattern, path]
        do {
            try process.run()
        } catch {
            preconditionFailure("cannot run grep: \(error)")
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Whether `bytes` hold `lower` (a lowercase pattern); upper case letters of `bytes` count as
    /// lower case when `caseInsensitive`.
    private static func find(_ lower: [UInt8], in bytes: UnsafeBufferPointer<UInt8>, caseInsensitive: Bool) -> Bool {
        let last = bytes.count - lower.count
        var index = 0
        let first = lower[0]
        while index <= last {
            if folded(bytes[index], caseInsensitive) == first {
                var offset = 1
                while offset < lower.count, folded(bytes[index + offset], caseInsensitive) == lower[offset] {
                    offset += 1
                }
                if offset == lower.count {
                    return true
                }
            }
            index += 1
        }
        return false
    }

    /// `byte` in lower case if it is an ASCII capital and `fold`, else `byte`.
    private static func folded(_ byte: UInt8, _ fold: Bool) -> UInt8 {
        fold && byte >= 65 && byte <= 90 ? byte + 32 : byte
    }
}
