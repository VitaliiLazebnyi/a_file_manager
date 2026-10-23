public import Foundation

public enum FileJobError: LocalizedError {
    case copyToItself
    case intoOwnSubfolder(String)
    case targetIsFolder(String)
    case targetIsFile(String)
    case sourceMissing(String)
    case folderNotEmpty(String)
    case verifyFailed(String)
    case cannotResume(String)
    /// A listed entry whose name could lead out of its folder (`..`, a name with `/`).
    case unsafeName(String)
    /// A pipe, a device or a socket: there is nothing in it to copy, and reading it may never end.
    case specialFile(String)
    /// Append and Resume only continue a plain file; a link at the target would lead elsewhere.
    case notPlainFile(String)
    /// A folder that is another volume, which the user did not want entered.
    case otherVolume(String)
    case nestedTooDeep(String)

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
