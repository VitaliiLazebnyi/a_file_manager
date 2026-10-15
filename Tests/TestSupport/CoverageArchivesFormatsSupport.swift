public import Foundation

/// Helpers of the tests of the archive formats.
public enum CoverageArchivesFormatsSupport {
    /// The text of the error `body` throws; nil when it throws none.
    public static func failure(_ body: () throws -> Void) -> String? {
        do {
            try body()
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    /// The text the system gives for an error number, as the archive formats put it in front
    /// of a path: `"<text>: <path>"`.
    public static func systemError(_ code: Int32, _ path: String) -> String {
        String(cString: strerror(code)) + ": " + path
    }

    /// The largest size a file on the volume of `folder` may have.
    ///
    /// Found by trying, so that the tests that write at the very end of what a file may hold do
    /// not depend on the file system.
    public static func largestFileSize(in folder: URL) -> Int64 {
        let path = folder.appendingPathComponent("largest-\(UUID().uuidString)").path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        defer {
            close(descriptor)
            unlink(path)
        }
        var (low, high) = (Int64(0), Int64.max)
        while high - low > 1 {
            let middle = low + (high - low) / 2
            if ftruncate(descriptor, middle) == 0 {
                low = middle
            } else {
                high = middle
            }
        }
        return low
    }

    /// Runs `/usr/bin/true` and returns its number once it has ended: a process that no longer runs.
    public static func deadProcess() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }
}
