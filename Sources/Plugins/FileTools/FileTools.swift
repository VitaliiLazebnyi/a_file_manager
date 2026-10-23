import AFMContracts
import AFMKernel
import AppKit

/// The behaviour behind the commands.
///
/// **Threading.** A command starts on the main thread, where it reads the panel and asks its
/// dialog. All reading, writing and hashing happens inside a job on the job's thread (hashing
/// on all cores); the job's completion returns to the main thread to report and refresh.
@MainActor
internal final class FileTools {
    /// The settings keys; the spec's names are given where it has them.
    internal enum Keys {
        /// The scope that holds every key below.
        internal static let scope = "filetools."
        /// `SplitBytesPerFile`, as typed.
        internal static let splitSize = scope + "splitBytesPerFile"
        /// `EncodeMethod`.
        internal static let encodeMethod = scope + "encodeMethod"
        /// `EncodeLinesPerFile`.
        internal static let encodeLines = scope + "encodeLinesPerFile"
        /// `Lastmd5`.
        internal static let checksumMethod = scope + "lastChecksumMethod"
        /// `CrcSeparateFiles`.
        internal static let separateFiles = scope + "crcSeparateFiles"
        /// `CrcSeparateFolders`.
        internal static let separateFolders = scope + "crcSeparateFolders"
        /// `CrcForceUtf8`.
        internal static let forceUTF8 = scope + "crcForceUtf8"
        /// `CrcForwardSlashes`: the Unix format of checksum files.
        internal static let unixFormat = scope + "crcUnixFormat"
        /// `CrcAppendExt`.
        internal static let appendExtension = scope + "crcAppendExt"
        /// `ChecksumExtraTypes`.
        internal static let extraTypes = scope + "checksumExtraTypes"
        /// Whether Verify shows only the errors.
        internal static let onlyErrors = scope + "verifyOnlyErrors"
    }

    /// Unowned: the kernel owns the plugin, and through it this.
    internal unowned let kernel: Kernel
    /// Where Verify looks for a checksum.
    internal let pasteboard: NSPasteboard

    /// The panel the commands work on.
    internal var source: PanelModel { kernel.panels.source.model }
    /// The kernel's dialogs and messages.
    internal var interaction: any UserInteraction { kernel.interaction }
    /// The program's settings.
    internal var settings: any SettingsStore { kernel.settings }
    /// The kernel's file systems.
    internal var fileSystems: FileSystemRegistry { kernel.fileSystems }

    // MARK: Common

    /// The other panel's folder, as the dialogs propose it.
    internal var targetProposal: String { fileSystems.displayPath(kernel.panels.target.model.directory) }

    /// The tools of `kernel`, Verify looking for a checksum on `pasteboard`.
    internal init(_ kernel: Kernel, pasteboard: NSPasteboard) {
        self.kernel = kernel
        self.pasteboard = pasteboard
    }

    /// Creates the target folder of a tool that, like Copy, makes it when it is missing.
    nonisolated internal static func prepare(_ folder: URL, _ run: ToolRun) throws {
        do {
            try run.provider(for: folder).createDirectory(at: folder)
        } catch {
            throw ToolError.failed("The given target path\n\(run.fileSystems.displayPath(folder))\nis invalid!")
        }
    }

    /// The proposal of "Save CRC file(s) to": next to the one file under its name, or, for
    /// several items, in the source folder under the folder's name (`checksums` at a root),
    /// from how many items there are and the name of the first, which is all it needs.
    nonisolated internal static func checksumProposal(
        count: Int,
        firstName: String?,
        in directory: URL,
        method: ChecksumMethod
    ) -> URL {
        let name = count == 1 ? firstName : (directory.lastPathComponent == "/" ? nil : directory.lastPathComponent)
        return directory.appending(name: (name ?? "checksums") + "." + method.fileExtension)
    }

    /// An empty target is the source folder.
    internal func folder(from text: String, relativeTo directory: URL) -> URL {
        // A target that was typed (not the proposal left as it was) is the user's own choice of a server, if it
        // names one.
        kernel.userTyped(location: text, relativeTo: directory, proposal: targetProposal)
        return text.trimmingCharacters(in: .whitespaces).isEmpty
            ? directory : fileSystems.location(from: text, relativeTo: directory)
    }

    /// Runs a tool as a job with progress and Cancel.
    ///
    /// Its error, if any, is shown under `title`; a cancelled run says nothing. The folders in
    /// `refreshing` are read again; it gets the result of the work (nil when it failed or was
    /// cancelled), which was made on the job's thread and reaches the main thread with the
    /// completion.
    internal func run<Value: Sendable>(
        _ title: String,
        job: String,
        refreshing folders: @escaping @MainActor (Value?) -> [URL],
        _ work: @escaping @Sendable (ToolRun) throws -> Value,
        then done: @escaping @MainActor (Value) -> Void
    ) {
        kernel.jobs.run(
            title: job,
            work: { [fileSystems, interaction] monitor -> Result<Value, any Error> in
                let run = ToolRun(fileSystems: fileSystems, monitor: monitor) { @MainActor @Sendable url in
                    interaction.pick(
                        "Overwrite:",
                        detail: fileSystems.displayPath(url),
                        [
                            ("Overwrite", .overwrite), ("Overwrite all", .overwriteAll), ("Skip", .skip),
                            ("Cancel", .cancel)
                        ],
                        fallback: ExistingFileChoice.cancel
                    )
                }
                let result = Result { try work(run) }
                // The last state always reaches the progress window, whatever was held back before.
                run.advance(0, items: 0, force: true)
                return result
            },
            completion: { [kernel] result in
                kernel.panels.refresh(folders(try? result.get()))
                switch result {
                case .success(let value):
                    done(value)

                case .failure(ToolError.cancelled):
                    break

                case .failure(let error):
                    kernel.interaction.inform(title, detail: error.localizedDescription, style: .warning)
                }
            }
        )
    }

    deinit {
        // Nothing to release.
    }
}
