public import Foundation

/// Why one step of a job failed, as the user is told.
public enum FileJobError: LocalizedError {
    /// Append or Resume met a target with nothing of the source in it.
    case cannotResume(String)
    /// The source and the target are one file.
    case copyToItself
    /// A folder still holds items that could not be processed.
    case folderNotEmpty(String)
    /// A folder would be copied or moved into one of its own subfolders.
    case intoOwnSubfolder(String)
    /// A folder lies deeper than the job goes (`FileJob.depthLimit`).
    case nestedTooDeep(String)
    /// Append and Resume only continue a plain file; a link at the target would lead elsewhere.
    case notPlainFile(String)
    /// A folder that is another volume, which the user did not want entered.
    case otherVolume(String)
    /// A source was gone by the time its turn came.
    case sourceMissing(String)
    /// A pipe, a device or a socket: there is nothing in it to copy, and reading it may never end.
    case specialFile(String)
    /// A file of that name is already there, where a folder was to go.
    case targetIsFile(String)
    /// A folder of that name is already there, where a file was to go.
    case targetIsFolder(String)
    /// A listed entry whose name could lead out of its folder (`..`, a name with `/`).
    case unsafeName(String)
    /// The copy, read again, is not the same as the source; it was removed.
    case verifyFailed(String)
    /// The message for the user, naming the place as it is shown.
    public var errorDescription: String? {
        switch self {
        case .copyToItself:
            return "You cannot copy a file to itself!"

        case .intoOwnSubfolder(let path):
            return "You cannot copy \(path) into one of its own subfolders!"

        case .targetIsFolder(let path):
            return "A folder with the name \(path) already exists!"

        case .targetIsFile(let path):
            return "A file with the name \(path) already exists!"

        case .sourceMissing(let path):
            return "\(path) does not exist any more!"

        case .folderNotEmpty(let path):
            return "\(path) still contains items that could not be processed."

        case .verifyFailed(let path):
            return "Verify failed: the copy of \(path) differs from the original. It was removed."

        case .cannotResume(let path):
            return "\(path) is not a shorter, partial copy of the file; it cannot be resumed."

        case .unsafeName(let name):
            return "\"\(DisplayName.escaped(name))\" is not a valid file name here. It was not processed."

        case .specialFile(let path):
            return "\(path) is a pipe, a device or a socket, not a file with contents. It was not copied."

        case .notPlainFile(let path):
            return "\(path) is a link or not a plain file; it cannot be appended to or resumed."

        case .otherVolume(let path):
            return "\(path) is another volume (a mounted disk or share). It was left as it is."

        case .nestedTooDeep(let path):
            return "\(path) is nested too deep to be processed."
        }
    }
}
