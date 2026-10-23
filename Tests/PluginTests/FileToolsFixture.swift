import Foundation

/// What the File Tools tests share: the programs of macOS to check against, and a test pattern.
internal enum FileToolsFixture {
    /// Runs a program that ships with macOS in `directory` (nil for the current one) and returns what it prints
    /// and its exit status.
    internal static func systemTool(_ path: String, _ arguments: [String], in directory: URL?) throws -> (
        output: String, status: Int32
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(bytes: data, encoding: .utf8) ?? "", process.terminationStatus)
    }

    /// The test pattern of the BLAKE3 reference vectors: the bytes 0…250, repeated, `count` of them.
    internal static func patternData(_ count: Int) -> Data {
        Data((0..<count).map { index in UInt8(index % 251) })
    }
}
