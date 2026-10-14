import AFMContracts
public import AFMKernel
public import Foundation

/// The wildcard field of Synchronize directories (spec 09 › Filter, 18 › File masks): masks
/// separated by spaces or semicolons, masks to leave out after `|`. An excluded mask that ends
/// in `/` names folders: such folders are not entered at all.
public struct SyncMask {
    private let include: FileMask?
    private let exclude: FileMask?
    private let excludedFolders: FileMask?

    public init(_ text: String) {
        let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        func tokens(_ part: String) -> [String] {
            part.split(whereSeparator: { $0 == " " || $0 == ";" }).map(String.init)
        }
        func mask(_ tokens: [String]) -> FileMask? {
            tokens.isEmpty ? nil : FileMask(tokens.joined(separator: " "))
        }
        let isFolderToken = { (token: String) in token.hasSuffix("/") || token.hasSuffix("\\") }
        let excluded = parts.count > 1 ? tokens(parts[1]) : []
        include = mask(tokens(parts.first ?? ""))
        exclude = mask(excluded.filter { !isFolderToken($0) })
        excludedFolders = mask(excluded.filter(isFolderToken).map { String($0.dropLast()) })
    }

    /// An empty include part takes every file.
    public func matchesFile(_ name: String) -> Bool {
        (include?.matches(name) ?? true) && !(exclude?.matches(name) ?? false)
    }

    public func excludesFolder(_ name: String) -> Bool {
        excludedFolders?.matches(name) ?? false
    }
}

/// What is compared and how (spec 09 › Compare options).
public struct SyncOptions: Codable, Equatable {
    /// Recurse into subdirectories.
    public var subdirectories = true
    /// Pairs that look equal by size and date are also read and compared byte by byte.
    public var byContent = false
    /// Dates are not compared; such pairs are only "equal" or "not equal".
    public var ignoreDate = false
    /// The right side is to become a copy of the left: files only on the right are deleted.
    public var asymmetric = false
    /// Directories that exist on one side only are rows of their own, created or deleted.
    public var emptyDirectories = false
    /// File masks, with exclusions after `|`.
    public var mask = "*.*"
    /// Dates this close count as the same (spec 09 › Comparison algorithm: 3 s; FAT volumes
    /// round to 2 s).
    public var toleranceSeconds = 3
    /// Hours added to the dates of the right side before comparing, for a server in another
    /// time zone (spec 09 › Synchronizing with FTP, `dT`).
    public var timeOffsetHours = 0
    /// Differences of exactly one hour (daylight saving on FAT volumes) count as the same.
    public var ignoreOneHourDifference = false
    /// Hidden files take part.
    public var includeHidden = false
    /// "Only selected (in main window)": the only names of the two start directories that are
    /// compared; nil compares everything.
    public var onlyNames: [String]?

    public init() {}
}

/// What the comparison found out about a row (spec 09 › Comparison algorithm).
public enum SyncState: Equatable {
    case leftOnly, rightOnly
    case leftNewer, rightNewer
    case equal
    /// Both exist and differ, with no hint which one to keep.
    case different
    /// A pair that should have been compared by content and was not (cancelled, unreadable).
    case pending
    /// Never synchronized: the names differ only in case, or a file faces a folder.
    case excluded
}

/// What Synchronize will do with a row.
public enum SyncAction: Equatable {
    case none
    case copyToRight, copyToLeft
    case deleteLeft, deleteRight, deleteBoth

    /// The symbol of the middle column (spec 09 › Result list).
    public var symbol: String {
        switch self {
        case .none: return ""
        case .copyToRight: return "→"
        case .copyToLeft: return "←"
        case .deleteLeft: return "✕←"
        case .deleteRight: return "→✕"
        case .deleteBoth: return "✕✕"
        }
    }
}

/// One line of the result list: a file (or, with "Empty directories", a folder) on the left,
/// on the right, or on both sides.
public struct SyncRow: Equatable {
    /// The folder of the row relative to the start directories, with a trailing slash; empty
    /// for the start directories themselves. This is the caption of the row's group.
    public let directory: String
    public let name: String
    public let isDirectory: Bool
    public let left: FileItem?
    public let right: FileItem?
    /// Where the row's folder is on each side, whether or not it exists there yet.
    public let leftDirectory: URL
    public let rightDirectory: URL
    public internal(set) var state: SyncState
    /// What the comparison proposes; decides the row's colour and the Show buttons.
    public internal(set) var defaultAction: SyncAction
    public var action: SyncAction

    init(
        directory: String, isDirectory: Bool, left: FileItem?, right: FileItem?, leftDirectory: URL,
        rightDirectory: URL,
        state: SyncState, asymmetric: Bool
    ) {
        self.directory = directory
        self.name = left?.name ?? right?.name ?? ""
        self.isDirectory = isDirectory
        self.left = left
        self.right = right
        self.leftDirectory = leftDirectory
        self.rightDirectory = rightDirectory
        self.state = state
        defaultAction = Self.proposal(for: state, asymmetric: asymmetric)
        action = defaultAction
    }

    /// The default direction of a state (spec 09 › Comparison algorithm). In asymmetric mode
    /// nothing is ever proposed towards the left: what is only on the right is deleted there,
    /// and a file that is newer on the right is left for the user to decide.
    public static func proposal(for state: SyncState, asymmetric: Bool) -> SyncAction {
        switch state {
        case .leftOnly, .leftNewer: return .copyToRight
        case .rightOnly: return asymmetric ? .deleteRight : .copyToLeft
        case .rightNewer: return asymmetric ? .none : .copyToLeft
        case .equal, .different, .pending, .excluded: return .none
        }
    }

    public var isPair: Bool { left != nil && right != nil }
    public var relativePath: String { directory + name }
    /// The row's place on the left; when nothing is there yet, where a copy would go.
    public var leftURL: URL { left?.url ?? leftDirectory.appending(name: name) }
    public var rightURL: URL { right?.url ?? rightDirectory.appending(name: name) }

    /// Whether the action makes sense for the row: something must exist to be copied or deleted,
    /// and excluded rows take nothing.
    public func accepts(_ action: SyncAction) -> Bool {
        if action == .none { return true }
        guard state != .excluded else { return false }
        switch action {
        case .none: return true
        case .copyToRight, .deleteLeft: return left != nil
        case .copyToLeft, .deleteRight: return right != nil
        case .deleteBoth: return isPair
        }
    }

    /// The action with the copy direction turned round; others stay.
    public var reversedAction: SyncAction {
        switch action {
        case .copyToRight where right != nil: return .copyToLeft
        case .copyToLeft where left != nil: return .copyToRight
        default: return action
        }
    }

    /// What a click on the middle column changes the row to: its default, then each copy
    /// direction, then nothing.
    public var nextAction: SyncAction {
        var cycle: [SyncAction] = []
        for candidate in [defaultAction, .copyToRight, .copyToLeft, SyncAction.none]
        where accepts(candidate) && !cycle.contains(candidate) {
            cycle.append(candidate)
        }
        guard let index = cycle.firstIndex(of: action) else { return cycle.first ?? .none }
        return cycle[(index + 1) % cycle.count]
    }
}

/// The Show buttons (spec 09 › Show filter); the raw values are the `SyncButtons` bits.
public struct SyncShow: OptionSet, Codable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let copyToRight = Self(rawValue: 1)
    public static let equal = Self(rawValue: 2)
    public static let notEqual = Self(rawValue: 4)
    public static let copyToLeft = Self(rawValue: 8)
    public static let duplicates = Self(rawValue: 16)
    public static let singles = Self(rawValue: 32)
    public static let all = Self(rawValue: 63)

    /// Rows are filtered by the direction the comparison computed, not by what the user made
    /// of it, and by whether the file is on both sides or on one.
    public func shows(_ row: SyncRow) -> Bool {
        let direction: Self
        switch row.defaultAction {
        case .copyToRight: direction = .copyToRight
        case .copyToLeft, .deleteRight: direction = .copyToLeft
        default: direction = row.state == .equal ? .equal : .notEqual
        }
        return contains(direction) && contains(row.isPair ? .duplicates : .singles)
    }
}

/// The footer after a comparison (spec 09 › Status line). Directories are not counted.
public struct SyncSummary: Equatable {
    public var files = 0, identical = 0, different = 0, uniqueLeft = 0, uniqueRight = 0

    public init(_ rows: [SyncRow]) {
        for row in rows where !row.isDirectory {
            files += 1
            switch row.state {
            case .leftOnly: uniqueLeft += 1
            case .rightOnly: uniqueRight += 1
            case .equal: identical += 1
            default: different += 1
            }
        }
    }

    public var text: String {
        files == 0
            ? "Files found: 0"
            : "Files found: \(files)  (Identical: \(identical), Different: \(different), Unique left: \(uniqueLeft), Unique right: \(uniqueRight))"
    }
}

/// Directories and options under a name (spec 09 › Saved sync sets).
public struct SyncSet: Codable, Equatable {
    public var name: String
    /// The two directories as the user sees and types them.
    public var left: String
    public var right: String
    public var options: SyncOptions
    public var show: SyncShow
}
