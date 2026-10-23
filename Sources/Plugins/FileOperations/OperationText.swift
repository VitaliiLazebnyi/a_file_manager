import AFMContracts
public import AFMKernel
import Foundation

/// The wording of the operation dialogs (spec 01 › The operand rule, 07 › Delete › Questions).
public enum OperationText {
    /// A question of a dialog: what it says, the line below, and the button that goes ahead.
    public struct Question: Sendable {
        /// The question itself.
        public let message: String
        /// The line below it.
        public let detail: String
        /// The title of the button that goes ahead.
        public let action: String
    }

    /// `Copy "name" to` for one file, otherwise `Copy N file(s) to`; a folder counts as a file.
    public static func heading(_ verb: String, _ items: [FileItem]) -> String {
        heading(verb, count: items.count, single: items.count == 1 ? items[0] : nil)
    }

    /// The same for whoever knows how many items there are without having the list of them;
    /// `single` is the item when there is exactly one.
    public static func heading(_ verb: String, count: Int, single: FileItem?) -> String {
        if let single, count == 1, !single.isFolder {
            return "\(verb) \"\(DisplayName.escaped(single.name))\" to"
        }
        return "\(verb) \(count) file(s) to"
    }

    /// The pre-filled target: one file gets its full target name, everything else the path with
    /// `*.*`. `targetPath` is the target panel's folder as shown to the user; nil for a copy
    /// within the source folder.
    public static func targetProposal(for items: [FileItem], targetPath: String?) -> String {
        targetProposal(count: items.count, single: items.count == 1 ? items[0] : nil, targetPath: targetPath)
    }

    /// The same for whoever knows how many items there are; `single` is the item when there is exactly one.
    public static func targetProposal(count: Int, single: FileItem?, targetPath: String?) -> String {
        let prefix = targetPath.map { $0.hasSuffix("/") ? $0 : $0 + "/" } ?? ""
        if let single, count == 1, !single.isFolder || targetPath == nil {
            return prefix + single.name
        }
        return prefix + "*.*"
    }

    /// The question of the Delete dialog for `items`: to the Trash or for good, one item by its name.
    public static func deleteQuestion(_ items: [FileItem], toTrash: Bool) -> String {
        deleteQuestion(count: items.count, single: items.count == 1 ? items[0] : nil, toTrash: toTrash)
    }

    /// The same for whoever knows how many items there are; `single` is the item when there is exactly one.
    public static func deleteQuestion(count: Int, single: FileItem?, toTrash: Bool) -> String {
        let what =
            single.flatMap { count == 1 ? $0 : nil }
            .map { item in
                "the selected \(item.isFolder ? "directory" : "file") \(DisplayName.escaped(item.name))"
            }
            ?? "the \(count) selected files/directories"
        return toTrash ? "Do you really want to move \(what) to the Trash?" : "Do you really want to delete \(what)?"
    }

    /// How the file being copied compares with the one at the target, for the Overwrite
    /// dialog: `The file being copied is newer and larger.`.
    public static func comparison(source: FileItem, target: FileItem) -> String {
        let age =
            source.modified > target.modified
            ? "newer" : (source.modified < target.modified ? "older" : "of the same age")
        let size = source.size > target.size ? "larger" : (source.size < target.size ? "smaller" : "of the same size")
        return "The file being copied is \(age) and \(size)."
    }

    /// The second question about a protected item (spec 07 › Read-only, hidden and system
    /// targets; Delete › Questions), in the Mac's terms.
    public static func protection(_ question: ProtectionQuestion, path: String) -> Question {
        let state: String
        switch question.reason {
        case .noTrash:
            return Question(
                message: "\(path) cannot be moved to the Trash.",
                detail: "This volume has no Trash. Do you want to delete it permanently?",
                action: "Delete"
            )

        case .readOnly:
            state = "is READ ONLY!"

        case .hidden:
            state = "is HIDDEN!"

        case .locked:
            state = "is LOCKED!"
        }
        switch question.purpose {
        case .overwrite:
            return Question(
                message: "The file \(path) \(state)",
                detail: "Do you want to overwrite it anyway?",
                action: "Overwrite"
            )

        case .delete:
            return Question(message: "Delete: \(path) \(state)", detail: "Delete anyway?", action: "Delete")

        case .move:
            return Question(message: "Move: \(path) \(state)", detail: "Move anyway?", action: "Move")
        }
    }
}
