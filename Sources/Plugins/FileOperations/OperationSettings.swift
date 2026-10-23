import AFMKernel
import Foundation

/// The settings of the file operations and the two configuration pages that show them
/// (spec 13 › Operation › Copy/Delete, Operation › Log file).
///
/// Main thread, like the settings store.
internal enum OperationSettings {
    /// Settings key: what happens to files whose names are taken: an index into `OverwriteMode.allCases`.
    internal static let overwrite = "fileOperations.overwriteMode"
    /// Settings key: whether copies keep the date of last change and the permissions.
    internal static let attributes = "fileOperations.keepAttributes"
    /// Settings key: whether copied folders get the date of the folder they were copied from.
    internal static let folderDates = "fileOperations.copyFolderDates"
    /// Settings key: whether links are copied as links (0) or replaced by what they point to (1).
    internal static let links = "fileOperations.links"
    /// Settings key: whether every copy is read again and its checksum compared with the source's.
    internal static let verify = "fileOperations.verify"
    /// Settings key: whether items that fail are skipped without a question and reported at the end.
    internal static let skipErrors = "fileOperations.keepGoingOnErrors"
    /// Settings key: whether small files are copied several at a time between fast local disks.
    internal static let parallel = "fileOperations.parallelSmallFiles"
    /// Settings key: whether a copy between file systems that is interrupted keeps what arrived, to be resumed.
    internal static let keepPartial = "fileOperations.keepPartialFiles"
    /// Settings key: whether F5 and F6 always open the copy dialog with its options shown.
    internal static let alwaysOptions = "fileOperations.alwaysShowOptions"
    /// Settings key: whether F8 and Delete move to the Trash (Shift deletes for good).
    internal static let useTrash = "fileOperations.useTrash"
    /// Settings key: whether to ask before a read-only file is overwritten or deleted.
    internal static let askReadOnly = "fileOperations.askReadOnly"
    /// Settings key: whether to ask before a hidden file is overwritten or deleted.
    internal static let askHidden = "fileOperations.askHidden"
    /// Settings key: whether to ask before a folder that is not empty is deleted.
    internal static let askNonEmpty = "fileOperations.askNonEmptyFolders"
    /// Settings key: whether to ask before a folder is copied into a folder of the same name.
    internal static let askMerge = "fileOperations.askBeforeMerging"

    /// Settings key: whether file operations are written to a log file.
    internal static let logEnabled = "fileOperations.log.enabled"
    /// Settings key: the path of the log file; `~` stands for the home folder.
    internal static let logFile = "fileOperations.log.file"
    /// Settings key: whether copies, moves, renames and new files are logged.
    internal static let logTransfers = "fileOperations.log.transfers"
    /// Settings key: whether deletions are logged.
    internal static let logDeletes = "fileOperations.log.deletes"
    /// Settings key: whether folders that are created or deleted are logged.
    internal static let logFolders = "fileOperations.log.folders"
    /// Settings key: whether operations that succeed are logged.
    internal static let logSuccess = "fileOperations.log.success"
    /// Settings key: whether errors are logged.
    internal static let logErrors = "fileOperations.log.errors"
    /// Settings key: whether files that are skipped are logged.
    internal static let logSkipped = "fileOperations.log.skipped"
    /// Settings key: when a new log file is started: never (0), every day (1), or past the size limit (2).
    internal static let logRotation = "fileOperations.log.rotation"
    /// Settings key: the size limit of a log file in kilobytes, as text.
    internal static let logSizeLimit = "fileOperations.log.sizeLimitKB"
    /// Settings key: how many old log files are kept (0 keeps all), as text.
    internal static let logKeepCount = "fileOperations.log.keepCount"

    /// The log file when none is set.
    internal static let defaultLogFile = "~/Library/Logs/A File Manager/operations.log"
    /// The choices of the Symbolic links setting, in the order of the raw values of `LinkHandling`.
    internal static let linkTitles = ["Copy the link itself", "Copy what the link points to"]

    /// The configuration page Operation › Copy/Delete.
    internal static var copyDeletePage: PreferencePage {
        PreferencePage(
            title: "Copy/Delete",
            preferences: [
                Preference(
                    overwrite,
                    "When a file exists at the target",
                    .choice(OverwriteMode.allCases.map(\.title), default: 0)
                ),
                Preference(attributes, "Copies keep dates and permissions", .flag(default: true)),
                Preference(folderDates, "Copy date/time of folders", .flag(default: false)),
                Preference(links, "Symbolic links", .choice(linkTitles, default: 0)),
                Preference(verify, "Verify after copy (SHA-256 checksum)", .flag(default: false)),
                Preference(
                    skipErrors,
                    "Keep going on errors (skip what fails, report at the end)",
                    .flag(default: false)
                ),
                Preference(parallel, "Copy several small files at once on fast local disks", .flag(default: true)),
                Preference(
                    keepPartial,
                    "Keep a partly copied file when a copy between file systems is interrupted (to resume it)",
                    .flag(default: false)
                ),
                Preference(alwaysOptions, "F5/F6 always show the copy options", .flag(default: false)),
                Preference(useTrash, "F8/Del moves to the Trash (Shift = delete permanently)", .flag(default: true)),
                Preference(askReadOnly, "Ask before overwriting/deleting read-only files", .flag(default: true)),
                Preference(askHidden, "Ask before overwriting/deleting hidden files", .flag(default: false)),
                Preference(askNonEmpty, "Ask before deleting non-empty folders", .flag(default: true)),
                Preference(
                    askMerge,
                    "Ask before copying into an existing folder of the same name",
                    .flag(default: false)
                )
            ]
        )
    }

    /// The configuration page Operation › Log file.
    internal static var logPage: PreferencePage {
        PreferencePage(
            title: "Log file",
            preferences: [
                Preference(logEnabled, "Create a log file of file operations", .flag(default: false)),
                Preference(logFile, "Log file", .text(default: defaultLogFile)),
                Preference(logTransfers, "Log copy/move/rename/new file", .flag(default: true)),
                Preference(logDeletes, "Log delete", .flag(default: true)),
                Preference(logFolders, "Log create/delete folders", .flag(default: true)),
                Preference(logSuccess, "Log successful operations", .flag(default: true)),
                Preference(logErrors, "Log errors", .flag(default: true)),
                Preference(logSkipped, "Log skipped files (when choosing skip or skip all)", .flag(default: true)),
                Preference(
                    logRotation,
                    "Start a new log file",
                    .choice(
                        [
                            "Never (always log to the same file)", "Every day after midnight",
                            "When the file becomes larger than the limit"
                        ],
                        default: 0
                    )
                ),
                Preference(logSizeLimit, "Size limit (kBytes)", .text(default: "1000")),
                Preference(logKeepCount, "Keep a maximum of log file copies (0 = all)", .text(default: "30"))
            ]
        )
    }

    /// The options of a job as the configuration has them.
    internal static func options(from settings: any SettingsStore) -> TransferOptions {
        var options = TransferOptions()
        options.overwrite = OverwriteMode(rawValue: settings.index(overwrite, default: 0)) ?? .ask
        options.preservesAttributes = settings.flag(attributes, default: true)
        options.preservesFolderDates = settings.flag(folderDates, default: false)
        options.links = LinkHandling(rawValue: settings.index(links, default: 0)) ?? .copyLinks
        options.verifies = settings.flag(verify, default: false)
        options.skipsErrors = settings.flag(skipErrors, default: false)
        options.copiesSmallFilesInParallel = settings.flag(parallel, default: true)
        options.keepsPartialFiles = settings.flag(keepPartial, default: false)
        options.asksAboutReadOnly = settings.flag(askReadOnly, default: true)
        options.asksAboutHidden = settings.flag(askHidden, default: false)
        options.asksAboutNonEmptyFolders = settings.flag(askNonEmpty, default: true)
        options.asksBeforeMerging = settings.flag(askMerge, default: false)
        return options
    }

    /// The log file's configuration as the settings have it; a blank path is the default file.
    internal static func logConfiguration(from settings: any SettingsStore) -> OperationLog.Configuration {
        var configuration = OperationLog.Configuration()
        configuration.isEnabled = settings.flag(logEnabled, default: false)
        let path = settings.text(logFile, default: defaultLogFile).trimmingCharacters(in: .whitespaces)
        configuration.file = URL(fileURLWithPath: expandingTilde(in: path.isEmpty ? defaultLogFile : path))
        configuration.logsTransfers = settings.flag(logTransfers, default: true)
        configuration.logsDeletes = settings.flag(logDeletes, default: true)
        configuration.logsFolders = settings.flag(logFolders, default: true)
        configuration.logsSuccess = settings.flag(logSuccess, default: true)
        configuration.logsErrors = settings.flag(logErrors, default: true)
        configuration.logsSkipped = settings.flag(logSkipped, default: true)
        switch settings.index(logRotation, default: 0) {
        case 1:
            configuration.rotation = .daily

        case 2:
            configuration.rotation = .size(max(1, Int(settings.text(logSizeLimit, default: "1000")) ?? 1_000) * 1_024)

        default:
            configuration.rotation = .never
        }
        configuration.keepCount = max(0, Int(settings.text(logKeepCount, default: "30")) ?? 30)
        return configuration
    }

    /// `path` with a leading `~` or `~user` replaced by that user's home folder, as a shell reads it.
    ///
    /// A user nobody knows leaves the path as it is.
    internal static func expandingTilde(in path: String) -> String {
        guard path.hasPrefix("~") else {
            return path
        }
        let end = path.firstIndex(of: "/") ?? path.endIndex
        let user = String(path[path.index(after: path.startIndex)..<end])
        let home =
            user.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser : FileManager.default.homeDirectory(forUser: user)
        guard let home else {
            return path
        }
        return home.path + path[end...]
    }
}
