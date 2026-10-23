import AFMKernel
import Foundation

/// Writes a file under a temporary name next to it and moves it into place when it is complete,
/// so a write that fails leaves no half of it behind and an old file as it was.
///
/// Runs on a job's thread.
internal enum DraftWrite {
    /// Writes `data` to `url` through `provider`; `replacing` lets the move replace a file
    /// that is there.
    ///
    /// Throws what the file system threw; the draft is removed first.
    internal static func write(
        _ data: Data,
        to url: URL,
        replacing: Bool,
        through provider: any FileSystemProvider,
        cancellation: CancellationFlag
    ) throws {
        let draft = url.deletingLastPathComponent()
            .appending(name: ".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        do {
            let writer = try provider.write(draft, cancellation: cancellation)
            do {
                try writer.write(data)
                try writer.close(attributes: FileAttributes())
            } catch {
                try? writer.close(attributes: FileAttributes())
                throw error
            }
            try provider.move(draft, to: url, replacing: replacing, cancellation: cancellation)
        } catch {
            // Tidying up: not with the job's flag, which may be what ended the writing.
            try? provider.remove(draft)
            throw error
        }
    }
}
