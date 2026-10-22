import AFMKernel
import Foundation

/// What happens to a file whose name is taken at the target, for the whole job (spec 07 ›
/// Default overwrite mode).
///
/// The first nine are the spec's `CopyOverwriteDefault` list in its order; the tenth exists only in
/// the Overwrite dialog.
public enum OverwriteMode: Int, CaseIterable, Sendable {
    case ask, overwriteAll, skipAll, overwriteOlder, autoRenameCopied, autoRenameExisting, copyLarger, copySmaller
    case renameOlderSkipNewer, overwriteOlderOrSame

    public var title: String {
        switch self {
        case .ask: return "Ask user"
        case .overwriteAll: return "Overwrite all"
        case .skipAll: return "Skip all"
        case .overwriteOlder: return "Overwrite all older"
        case .autoRenameCopied: return "Auto-rename copied"
        case .autoRenameExisting: return "Auto-rename target files"
        case .copyLarger: return "Copy all larger files (overwrite smaller)"
        case .copySmaller: return "Copy all smaller files (overwrite larger)"
        case .renameOlderSkipNewer: return "Rename older target files, skip newer"
        case .overwriteOlderOrSame: return "Overwrite all older and of the same age"
        }
    }
}

/// What a copy does with a symbolic link (spec 07 › Other copy settings, `CopyLinks`).
public enum LinkHandling: Int, Sendable {
    /// The link itself is copied and points where it pointed.
    case copyLinks
    /// The file or folder the link points to is copied in its place.
    case followLinks
}

/// The choices of the Copy and Move dialogs and of the Copy/Delete configuration page that
/// the engine acts on (spec 07 › Copy dialog, Advanced options; 13 › Operation › Copy/Delete).
///
/// The defaults are the behaviour without any dialog.
public struct TransferOptions: Sendable {
    public var overwrite = OverwriteMode.ask
    /// "Only files of this type".
    public var filter = CopyFilter()
    /// Copies keep the date of last change and the permissions (and, within one file system,
    /// whatever else that file system keeps).
    ///
    /// Off: the copy is dated now, with the usual permissions.
    public var preservesAttributes = true
    /// Copied folders get the date of the folder they were copied from (`CopyDirTimeStamp`).
    public var preservesFolderDates = false
    public var links = LinkHandling.copyLinks
    /// Reads every copy again and compares its checksum with the source's (spec 07 › Verify).
    public var verifies = false
    /// Items that fail are skipped without a question and counted in the result.
    public var skipsErrors = false
    /// "Overwrite/Delete read only/hidden": the extra questions are not asked.
    public var ignoresProtection = false
    public var asksAboutReadOnly = true
    /// Off by default, unlike on Windows: every folder a Mac has shown holds a hidden `.DS_Store`.
    public var asksAboutHidden = false
    public var asksAboutNonEmptyFolders = true
    /// Asks before a folder is copied into a folder of the same name that already exists.
    public var asksBeforeMerging = false
    /// Small files are copied several at a time where both sides are local and not spinning disks.
    public var copiesSmallFilesInParallel = true
    /// A copy between two file systems that is interrupted keeps what arrived under the real
    /// name, so that Resume in the Overwrite dialog can continue it.
    public var keepsPartialFiles = false

    public init() {}
}
