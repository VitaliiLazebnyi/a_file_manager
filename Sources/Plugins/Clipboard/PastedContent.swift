import AFMKernel
import AppKit

/// What Paste makes a new file of when the clipboard holds no files.
internal enum PastedContent: Equatable {
    /// PNG data, or any other picture format AppKit reads (converted on the job's thread).
    case image(Data)
    /// A text, written as UTF-8.
    case text(String)

    /// Paste found nothing to write, or the job was cancelled: no failure to report.
    private struct NothingToPaste: Error {}

    /// The data on the clipboard is no picture AppKit can read.
    private struct NotAPicture: LocalizedError {
        var errorDescription: String? { "The picture on the clipboard cannot be read." }
    }

    /// The pasteboard types read as a picture, in the order they are preferred.
    internal static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

    /// The extension of the file the content becomes: `txt` or `png`.
    internal var fileExtension: String {
        switch self {
        case .image:
            return "png"

        case .text:
            return "txt"
        }
    }

    /// The first name of the form `Clipboard.txt`, `Clipboard (2).txt`, … that `isTaken`
    /// does not report as used.
    internal static func freeName(extension ext: String, isTaken: (String) -> Bool) -> String {
        var name = "Clipboard.\(ext)"
        var number = 2
        while isTaken(name) {
            name = "Clipboard (\(number)).\(ext)"
            number += 1
        }
        return name
    }

    /// The picture or text on the clipboard.
    ///
    /// A picture wins over a text, because programs that copy a picture often add its name. Reads
    /// the data, which the program that owns it may make only now. Main thread.
    @MainActor
    internal static func read(from pasteboard: NSPasteboard) -> Self? {
        if let type = pasteboard.availableType(from: imageTypes), let data = pasteboard.data(forType: type),
            !data.isEmpty
        {
            return .image(data)
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return .text(text)
        }
        return nil
    }

    /// PNG data stays as it is; anything else is converted.
    ///
    /// Runs on a job's thread.
    private static func png(from data: Data) throws -> Data {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return data
        }
        guard let converted = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
            throw NotAPicture()
        }
        return converted
    }

    /// Writes the content as `Clipboard.txt` or `Clipboard.png` (with a number when the name
    /// is taken) through the folder's file system, in a job; the cursor goes to the new file.
    ///
    /// The file is written under a temporary name and gets its own when it is complete, so a write
    /// that fails leaves no half of it behind. Main thread; a failure is reported to the user.
    @MainActor
    internal func paste(into directory: URL, in kernel: Kernel) {
        let fileSystems = kernel.fileSystems
        kernel.jobs.run(
            title: "Paste:",
            work: { [self] monitor -> Result<URL, any Error> in
                Result { try write(into: directory, fileSystems: fileSystems, cancellation: monitor.cancellation) }
            },
            completion: { result in
                switch result {
                case .success(let url):
                    kernel.panels.refresh([directory], focus: url)

                case .failure(is NothingToPaste):
                    break

                case .failure(let error):
                    kernel.interaction.report(error, title: "The clipboard cannot be pasted as a file!")
                }
            }
        )
    }

    /// Writes the file under the first free name and returns where it is; on a job's thread.
    ///
    /// Throws `NothingToPaste` when cancelled, else what the conversion or the file system threw.
    private func write(
        into directory: URL,
        fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag
    ) throws -> URL {
        let provider = try fileSystems.provider(for: directory)
        let data: Data
        switch self {
        case .image(let picture):
            data = try Self.png(from: picture)

        case .text(let text):
            data = Data(text.utf8)
        }
        let name = Self.freeName(extension: fileExtension) { taken in
            provider.item(at: directory.appending(name: taken), cancellation: cancellation) != nil
        }
        if cancellation.isCancelled { throw NothingToPaste() }
        let url = directory.appending(name: name)
        do {
            try DraftWrite.write(data, to: url, replacing: false, through: provider, cancellation: cancellation)
        } catch {
            throw cancellation.isCancelled ? NothingToPaste() : error
        }
        return url
    }
}
