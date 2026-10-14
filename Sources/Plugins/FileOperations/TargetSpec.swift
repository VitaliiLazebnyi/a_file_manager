import AFMContracts
import AFMKernel
import Foundation

/// Target masks of Copy and Move (spec 07 › Wildcard target names).
public enum TargetMask {
    public static func apply(_ mask: String, to sourceName: String) -> String {
        if mask.isEmpty || mask == "*.*" || mask == "*" { return sourceName }
        let source = splitAtLastDot(sourceName)
        let parts = splitAtLastDot(mask)
        let name = expand(source.name, mask: parts.name)
        guard let extMask = parts.ext else { return name }
        let ext = expand(source.ext ?? "", mask: extMask)
        return ext.isEmpty ? name : name + "." + ext
    }

    private static func splitAtLastDot(_ text: String) -> (name: String, ext: String?) {
        guard let dot = text.lastIndex(of: "."), dot != text.startIndex else { return (text, nil) }
        return (String(text[..<dot]), String(text[text.index(after: dot)...]))
    }

    static func expand(_ source: String, mask: String) -> String {
        let src = Array(source)
        let mask = Array(mask)
        var out = ""
        var p = 0
        var i = 0
        while i < mask.count {
            let c = mask[i]
            let next: Character? = i + 1 < mask.count ? mask[i + 1] : nil
            if c == "?" {
                if p < src.count { out.append(src[p]) }
                p += 1
                i += 1
            } else if c == "*" && next == "*" {
                out += source
                p = src.count
                i += 2
            } else if c == "*" && next == "?" {
                p = 0
                i += 2
            } else if c == "*" {
                if p < src.count { out += String(src[p...]) }
                p = src.count
                i += 1
            } else {
                out.append(c)
                p += 1
                i += 1
            }
        }
        return out
    }
}

/// Where a Copy or Move goes: a folder plus a name mask (spec 07 › Target field).
public struct TargetSpec: Equatable {
    public var directory: URL
    public var mask: String
    /// The mask is a name to be taken as it is, even if it holds `*` or `?`.
    public var isExactName = false

    public init(directory: URL, mask: String = "*.*") {
        self.directory = directory.standardized
        self.mask = mask
    }

    /// A target with one fixed name (for a rename typed by the user).
    public init(directory: URL, exactName: String) {
        self.init(directory: directory, mask: exactName)
        isExactName = true
    }

    public static func == (a: TargetSpec, b: TargetSpec) -> Bool {
        a.directory.isSameLocation(as: b.directory) && a.mask == b.mask && a.isExactName == b.isExactName
    }

    public func url(for sourceName: String) -> URL {
        directory.appending(name: isExactName ? mask : TargetMask.apply(mask, to: sourceName))
    }

    /// Reads the target field. Relative paths, `..` and an empty path refer to the source folder.
    /// Looks at the file system to tell a folder from a new name, so it is not for the main thread.
    /// With a `cancellation` flag that look ends when the flag is set (a target on a server
    /// that has stopped answering); the text is then read as if nothing were there.
    public static func parse(
        _ text: String, sourceDirectory: URL, operandCount: Int, fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag? = nil
    ) -> TargetSpec {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return TargetSpec(directory: sourceDirectory) }
        let last = (text as NSString).lastPathComponent
        if last.contains("*") || last.contains("?") {
            let folder = String(text.dropLast(last.count))
            return TargetSpec(directory: fileSystems.location(from: folder, relativeTo: sourceDirectory), mask: last)
        }
        let url = fileSystems.location(from: text, relativeTo: sourceDirectory)
        if text.hasSuffix("/") || last == ".." || last == "."
            || UniqueName.item(at: url, in: fileSystems, cancellation)?.isDirectory == true
        {
            return TargetSpec(directory: url)
        }
        // A plain new name renames a single item; for several items it names a folder to create.
        return operandCount == 1
            ? TargetSpec(directory: url.deletingLastPathComponent(), mask: last)
            : TargetSpec(directory: url)
    }
}

public enum UniqueName {
    /// A free name next to `url`: `report (2).txt`, `report (3).txt` (spec 07 › Auto-rename names).
    /// `isTaken` names locations that are spoken for although nothing is there yet.
    /// With a `cancellation` flag the looks at the file system end when it is set; the name
    /// that comes back then is not known to be free, and whoever asked is being stopped.
    public static func available(
        for url: URL, in fileSystems: FileSystemRegistry, cancellation: CancellationFlag? = nil,
        isTaken: (URL) -> Bool = { _ in false }
    ) -> URL {
        available(for: url) { item(at: $0, in: fileSystems, cancellation) != nil || isTaken($0) }
    }

    /// What is at a location, asked so that the question ends with `cancellation` when there is one.
    static func item(at url: URL, in fileSystems: FileSystemRegistry, _ cancellation: CancellationFlag?) -> FileItem? {
        guard let cancellation else { return fileSystems.item(at: url) }
        return (try? fileSystems.provider(for: url))?.item(at: url, cancellation: cancellation)
    }

    /// The same with the question "is this name in use?" left to the caller.
    public static func available(for url: URL, exists: (URL) -> Bool) -> URL {
        guard exists(url) else { return url }
        let (base, ext) = FileItem.split(url.lastPathComponent)
        let folder = url.deletingLastPathComponent()
        var counter = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            let candidate = folder.appending(name: name)
            if !exists(candidate) { return candidate }
            counter += 1
        }
    }
}

/// The wording of the operation dialogs (spec 01 › The operand rule, 07 › Delete › Questions).
public enum OperationText {
    /// `Copy "name" to` for one file, otherwise `Copy N file(s) to`; a folder counts as a file.
    public static func heading(_ verb: String, _ items: [FileItem]) -> String {
        heading(verb, count: items.count, single: items.count == 1 ? items[0] : nil)
    }

    /// The same for whoever knows how many items there are without having the list of them;
    /// `single` is the item when there is exactly one.
    public static func heading(_ verb: String, count: Int, single: FileItem?) -> String {
        if let single, count == 1, !single.isFolder { return "\(verb) \"\(DisplayName.escaped(single.name))\" to" }
        return "\(verb) \(count) file(s) to"
    }

    /// The pre-filled target: one file gets its full target name, everything else the path with
    /// `*.*`. `targetPath` is the target panel's folder as shown to the user; nil for a copy
    /// within the source folder.
    public static func targetProposal(for items: [FileItem], targetPath: String?) -> String {
        targetProposal(count: items.count, single: items.count == 1 ? items[0] : nil, targetPath: targetPath)
    }

    public static func targetProposal(count: Int, single: FileItem?, targetPath: String?) -> String {
        let prefix = targetPath.map { $0.hasSuffix("/") ? $0 : $0 + "/" } ?? ""
        if let single, count == 1, !single.isFolder || targetPath == nil { return prefix + single.name }
        return prefix + "*.*"
    }

    public static func deleteQuestion(_ items: [FileItem], toTrash: Bool) -> String {
        deleteQuestion(count: items.count, single: items.count == 1 ? items[0] : nil, toTrash: toTrash)
    }

    public static func deleteQuestion(count: Int, single: FileItem?, toTrash: Bool) -> String {
        let what =
            single.flatMap { count == 1 ? $0 : nil }.map {
                "the selected \($0.isFolder ? "directory" : "file") \(DisplayName.escaped($0.name))"
            }
            ?? "the \(count) selected files/directories"
        return toTrash ? "Do you really want to move \(what) to the Trash?" : "Do you really want to delete \(what)?"
    }

    /// How the file being copied compares with the one at the target, for the Overwrite
    /// dialog: `The file being copied is newer and larger.`
    public static func comparison(source: FileItem, target: FileItem) -> String {
        let age =
            source.modified > target.modified
            ? "newer" : (source.modified < target.modified ? "older" : "of the same age")
        let size = source.size > target.size ? "larger" : (source.size < target.size ? "smaller" : "of the same size")
        return "The file being copied is \(age) and \(size)."
    }

    /// The second question about a protected item (spec 07 › Read-only, hidden and system
    /// targets; Delete › Questions), in the Mac's terms.
    public static func protection(_ question: ProtectionQuestion, path: String) -> (
        message: String, detail: String, action: String
    ) {
        if question.reason == .noTrash {
            return (
                "\(path) cannot be moved to the Trash.",
                "This volume has no Trash. Do you want to delete it permanently?", "Delete"
            )
        }
        let state: String
        switch question.reason {
        case .readOnly: state = "is READ ONLY!"
        case .hidden: state = "is HIDDEN!"
        case .locked: state = "is LOCKED!"
        case .noTrash: state = ""
        }
        switch question.purpose {
        case .overwrite: return ("The file \(path) \(state)", "Do you want to overwrite it anyway?", "Overwrite")
        case .delete: return ("Delete: \(path) \(state)", "Delete anyway?", "Delete")
        case .move: return ("Move: \(path) \(state)", "Move anyway?", "Move")
        }
    }
}
