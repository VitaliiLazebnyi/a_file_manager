import Foundation

/// AppleScript of the system, which reaches other applications. The UI tests cover this; unit
/// tests hand the plugin a recorder instead.
internal enum AppleScript {
    /// Runs `osascript` with these arguments and does not wait for it.
    internal static let run: @Sendable ([String]) -> Void = { arguments in
        let process = Process()
        (process.executableURL, process.arguments) = (URL(fileURLWithPath: "/usr/bin/osascript"), arguments)
        (process.standardOutput, process.standardError) = (FileHandle.nullDevice, FileHandle.nullDevice)
        try? process.run()
    }
}
