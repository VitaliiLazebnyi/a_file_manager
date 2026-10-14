import Foundation
import StressKit
import zlib

// Small helpers of the harness: work on a thread of its own, checksums, other programs.

/// Runs `body` on a thread with a 64 MB stack while the main run loop keeps going; returns its result.
@MainActor
internal func offMain<Value: Sendable>(_ body: @escaping @Sendable () -> Value) -> Value {
    let done = Locked<Value?>(nil)
    let thread = Thread {
        let value = body()
        done.value = value
    }
    thread.stackSize = 64 << 20
    thread.start()
    pump(upTo: 7_200) { done.value != nil }
    guard let value = done.value else {
        preconditionFailure("the work off the main thread did not end within two hours")
    }
    return value
}

/// The CRC-32 of `data`, as ZIP stores it.
internal func checksum(_ data: Data) -> UInt32 {
    data.withUnsafeBytes { raw in
        UInt32(truncatingIfNeeded: crc32(0, raw.bindMemory(to: UInt8.self).baseAddress, uInt(raw.count)))
    }
}

/// Runs the program at `path` and returns its exit status and everything it wrote.
internal func tool(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (-1, "\(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    // Text that is not UTF-8 (a name in another encoding) is shown byte for byte as Latin-1.
    let output = String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
    return (process.terminationStatus, output)
}

/// The output of a program without the blank space around it.
internal func trimmed(_ output: String) -> String {
    output.trimmingCharacters(in: .whitespacesAndNewlines)
}
