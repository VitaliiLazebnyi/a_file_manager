public import AFMKernel
public import Foundation

/// One line of the result list: a file (or, with "Empty directories", a folder) on the left,
/// on the right, or on both sides.
public struct SyncRow: Equatable, Sendable {
    /// The folder of the row relative to the start directories, with a trailing slash; empty
    /// for the start directories themselves.
    ///
    /// This is the caption of the row's group.
    public let directory: String
    /// The name of the file or folder, as the left side has it, else as the right.
    public let name: String
    /// Whether the row is a folder (with "Empty directories") rather than a file.
    public let isDirectory: Bool
    /// The left one; nil where only the right side has it.
    public let left: FileItem?
    /// The right one; nil where only the left side has it.
    public let right: FileItem?
    /// Where the row's folder is on the left, whether or not it exists there yet.
    public let leftDirectory: URL
    /// Where the row's folder is on the right, whether or not it exists there yet.
    public let rightDirectory: URL
    /// What the comparison found out.
    public internal(set) var state: SyncState
    /// What the comparison proposes; decides the row's colour and the Show buttons.
    public internal(set) var defaultAction: SyncAction
    /// What Synchronize will do; the user may change it.
    public var action: SyncAction

    /// Whether both sides have it.
    public var isPair: Bool { left != nil && right != nil }
    /// The row's path relative to the start directories.
    public var relativePath: String { directory + name }
    /// The row's place on the left; when nothing is there yet, where a copy would go.
    public var leftURL: URL { left?.url ?? leftDirectory.appending(name: name) }
    /// The row's place on the right; when nothing is there yet, where a copy would go.
    public var rightURL: URL { right?.url ?? rightDirectory.appending(name: name) }

    /// The action with the copy direction turned round; others stay.
    public var reversedAction: SyncAction {
        switch action {
        case .copyToRight where right != nil:
            return .copyToLeft

        case .copyToLeft where left != nil:
            return .copyToRight

        default:
            return action
        }
    }

    /// What a click on the middle column changes the row to: its default, then each copy
    /// direction, then nothing.
    public var nextAction: SyncAction {
        var cycle: [SyncAction] = []
        for candidate in [defaultAction, .copyToRight, .copyToLeft, .nothing]
        where accepts(candidate) && !cycle.contains(candidate) {
            cycle.append(candidate)
        }
        // (Every row takes no action, so the cycle is never empty.)
        guard let index = cycle.firstIndex(of: action) else {
            return cycle[0]
        }
        return cycle[(index + 1) % cycle.count]
    }

    /// A row found by the comparison, with the action its state proposes.
    internal init(
        directory: String,
        isDirectory: Bool,
        left: FileItem?,
        right: FileItem?,
        leftDirectory: URL,
        rightDirectory: URL,
        state: SyncState,
        asymmetric: Bool
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

    /// The default direction of a state (spec 09 › Comparison algorithm).
    ///
    /// In asymmetric mode nothing is ever proposed towards the left: what is only on the right is
    /// deleted there, and a file that is newer on the right is left for the user to decide.
    public static func proposal(for state: SyncState, asymmetric: Bool) -> SyncAction {
        switch state {
        case .leftOnly, .leftNewer:
            return .copyToRight

        case .rightOnly:
            return asymmetric ? .deleteRight : .copyToLeft

        case .rightNewer:
            return asymmetric ? .nothing : .copyToLeft

        case .equal, .different, .pending, .excluded:
            return .nothing
        }
    }

    /// Whether the action makes sense for the row: something must exist to be copied or deleted,
    /// and excluded rows take nothing.
    public func accepts(_ action: SyncAction) -> Bool {
        guard action == .nothing || state != .excluded else {
            return false
        }
        switch action {
        case .nothing:
            return true

        case .copyToRight, .deleteLeft:
            return left != nil

        case .copyToLeft, .deleteRight:
            return right != nil

        case .deleteBoth:
            return isPair
        }
    }
}
