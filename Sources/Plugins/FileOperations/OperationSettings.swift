import AFMKernel
import Foundation

/// The settings of the file operations and the two configuration pages that show them
/// (spec 13 › Operation › Copy/Delete, Operation › Log file). Main thread, like the settings store.
enum OperationSettings {
    static let overwrite = "fileOperations.overwriteMode"
    static let attributes = "fileOperations.keepAttributes"
    static let folderDates = "fileOperations.copyFolderDates"
    static let links = "fileOperations.links"
    static let verify = "fileOperations.verify"
    static let skipErrors = "fileOperations.keepGoingOnErrors"
    static let parallel = "fileOperations.parallelSmallFiles"
    static let keepPartial = "fileOperations.keepPartialFiles"
    static let alwaysOptions = "fileOperations.alwaysShowOptions"
    static let useTrash = "fileOperations.useTrash"
    static let askReadOnly = "fileOperations.askReadOnly"
    static let askHidden = "fileOperations.askHidden"
    static let askNonEmpty = "fileOperations.askNonEmptyFolders"
    static let askMerge = "fileOperations.askBeforeMerging"

    static let logEnabled = "fileOperations.log.enabled"
    static let logFile = "fileOperations.log.file"
    static let logTransfers = "fileOperations.log.transfers"
    static let logDeletes = "fileOperations.log.deletes"
    static let logFolders = "fileOperations.log.folders"
    static let logSuccess = "fileOperations.log.success"
    static let logErrors = "fileOperations.log.errors"
    static let logSkipped = "fileOperations.log.skipped"
    static let logRotation = "fileOperations.log.rotation"
    static let logSizeLimit = "fileOperations.log.sizeLimitKB"
    static let logKeepCount = "fileOperations.log.keepCount"

    static let defaultLogFile = "~/Library/Logs/A File Manager/operations.log"
    static let linkTitles = ["Copy the link itself", "Copy what the link points to"]

    static var copyDeletePage: PreferencePage {
        PreferencePage(title: "Copy/Delete", preferences: [
            Preference(overwrite, "When a file exists at the target", .choice(OverwriteMode.allCases.map(\.title), default: 0)),
            Preference(attributes, "Copies keep dates and permissions", .flag(default: true)),
            Preference(folderDates, "Copy date/time of folders", .flag(default: false)),
            Preference(links, "Symbolic links", .choice(linkTitles, default: 0)),
            Preference(verify, "Verify after copy (SHA-256 checksum)", .flag(default: false)),
            Preference(skipErrors, "Keep going on errors (skip what fails, report at the end)", .flag(default: false)),
            Preference(parallel, "Copy several small files at once on fast local disks", .flag(default: true)),
            Preference(keepPartial, "Keep a partly copied file when a copy between file systems is interrupted (to resume it)",
                       .flag(default: false)),
            Preference(alwaysOptions, "F5/F6 always show the copy options", .flag(default: false)),
            Preference(useTrash, "F8/Del moves to the Trash (Shift = delete permanently)", .flag(default: true)),
            Preference(askReadOnly, "Ask before overwriting/deleting read-only files", .flag(default: true)),
            Preference(askHidden, "Ask before overwriting/deleting hidden files", .flag(default: false)),
            Preference(askNonEmpty, "Ask before deleting non-empty folders", .flag(default: true)),
            Preference(askMerge, "Ask before copying into an existing folder of the same name", .flag(default: false)),
        ])
    }

    static var logPage: PreferencePage {
        PreferencePage(title: "Log file", preferences: [
            Preference(logEnabled, "Create a log file of file operations", .flag(default: false)),
            Preference(logFile, "Log file", .text(default: defaultLogFile)),
            Preference(logTransfers, "Log copy/move/rename/new file", .flag(default: true)),
            Preference(logDeletes, "Log delete", .flag(default: true)),
            Preference(logFolders, "Log create/delete folders", .flag(default: true)),
            Preference(logSuccess, "Log successful operations", .flag(default: true)),
            Preference(logErrors, "Log errors", .flag(default: true)),
            Preference(logSkipped, "Log skipped files (when choosing skip or skip all)", .flag(default: true)),
            Preference(logRotation, "Start a new log file",
                       .choice(["Never (always log to the same file)", "Every day after midnight", "When the file becomes larger than the limit"],
                               default: 0)),
            Preference(logSizeLimit, "Size limit (kBytes)", .text(default: "1000")),
            Preference(logKeepCount, "Keep a maximum of log file copies (0 = all)", .text(default: "30")),
        ])
    }

    /// The options of a job as the configuration has them.
    static func options(from settings: SettingsStore) -> TransferOptions {
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

    static func logConfiguration(from settings: SettingsStore) -> OperationLog.Configuration {
        var configuration = OperationLog.Configuration()
        configuration.isEnabled = settings.flag(logEnabled, default: false)
        let path = settings.text(logFile, default: defaultLogFile).trimmingCharacters(in: .whitespaces)
        configuration.file = URL(fileURLWithPath: NSString(string: path.isEmpty ? defaultLogFile : path).expandingTildeInPath)
        configuration.logsTransfers = settings.flag(logTransfers, default: true)
        configuration.logsDeletes = settings.flag(logDeletes, default: true)
        configuration.logsFolders = settings.flag(logFolders, default: true)
        configuration.logsSuccess = settings.flag(logSuccess, default: true)
        configuration.logsErrors = settings.flag(logErrors, default: true)
        configuration.logsSkipped = settings.flag(logSkipped, default: true)
        switch settings.index(logRotation, default: 0) {
        case 1: configuration.rotation = .daily
        case 2: configuration.rotation = .size(max(1, Int(settings.text(logSizeLimit, default: "1000")) ?? 1000) * 1024)
        default: configuration.rotation = .never
        }
        configuration.keepCount = max(0, Int(settings.text(logKeepCount, default: "30")) ?? 30)
        return configuration
    }
}

/// The options a command carries after its name, as in `cm_Copy /V1 O2 T="/tmp/" W="*.txt" G`
/// (spec 17 › Commands with parameters): a letter, then a number or `="text"`; a quote inside
/// the text is doubled. A letter without a number counts as 1.
public enum CommandSwitches {
    public static func parse(_ text: String) -> [Character: String] {
        var switches: [Character: String] = [:]
        var characters = Array(text)[...]
        while let letter = characters.popFirst() {
            guard letter.isLetter else { continue }
            if characters.first == "=" {
                characters.removeFirst()
                var value = ""
                if characters.first == "\"" {
                    characters.removeFirst()
                    while let next = characters.popFirst() {
                        if next == "\"" {
                            guard characters.first == "\"" else { break }
                            characters.removeFirst()
                        }
                        value.append(next)
                    }
                } else {
                    while let next = characters.first, next != " ", next != "/" { value.append(characters.removeFirst()) }
                }
                switches[letter] = value
            } else {
                var digits = ""
                while let next = characters.first, next.isNumber { digits.append(characters.removeFirst()) }
                switches[letter] = digits.isEmpty ? "1" : digits
            }
        }
        return switches
    }
}
