import Foundation

/// Runs a program of the system in the current folder and returns its exit status and output.
@discardableResult
internal func runTool(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
    runTool(path, arguments, in: nil)
}

/// Runs a program of the system in `directory` (nil: the current folder) and returns its exit status and output
/// (standard output and standard error together).
@discardableResult
internal func runTool(_ path: String, _ arguments: [String], in directory: URL?) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return (-1, "\(error)") }
    let output = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    process.waitUntilExit()
    // Tools print names in the archive's own encoding, which need not be UTF-8: Latin-1 takes any bytes, so no
    // output is lost.
    return (
        process.terminationStatus,
        String(bytes: output, encoding: .utf8) ?? String(bytes: output, encoding: .isoLatin1) ?? ""
    )
}

/// Every regular file below a folder with its contents, by relative path; empty folders as nil.
internal func snapshot(_ folder: URL) -> [String: Data?] {
    var found: [String: Data?] = [:]
    let base = folder.resolvingSymlinksInPath().path
    guard let walker = FileManager.default.enumerator(atPath: base) else {
        return found
    }
    for case let path as String in walker {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: base + "/" + path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            if ((try? FileManager.default.contentsOfDirectory(atPath: base + "/" + path)) ?? []).isEmpty {
                found[path.precomposedStringWithCanonicalMapping] = .some(nil)
            }
        } else {
            found[path.precomposedStringWithCanonicalMapping] = FileManager.default.contents(atPath: base + "/" + path)
        }
    }
    return found
}
