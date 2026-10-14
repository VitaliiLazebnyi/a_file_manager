import AFMKernel
import Foundation

/// How far a comparison is (spec 09 › Status line).
public struct SyncProgress: Equatable {
    public var leftDirectories = 0, rightDirectories = 0
    public var filesCompared = 0, filesToCompare = 0
    public var bytesCompared: Int64 = 0, bytesToCompare: Int64 = 0
}

public struct SyncResult {
    public var rows: [SyncRow] = []
    public var leftDirectories = 0, rightDirectories = 0
    /// Folders that could not be read and files that could not be compared. A folder that
    /// fails on one side is left out on both, so nothing in it looks unique.
    public var errors: [String] = []
    public var wasCancelled = false
    /// How many entries the two start directories held before the masks and the selection were
    /// applied; nil where the directory could not be read. A source that lists as empty while the
    /// other side is not is how an unmounted share or a wrong path looks.
    public var topEntries: (left: Int?, right: Int?) = (nil, nil)
    /// The time tolerance the comparison used: as set where a file system needs it (FAT and
    /// exFAT, shares, servers, archives), none beyond rounding where both sides keep exact dates.
    public var toleranceSeconds = 0
}

/// The comparison of two directory trees (spec 09 › Comparison algorithm). It knows nothing
/// of windows: it reads through the file-system providers, so the two sides can be on any
/// file systems, and returns rows.
///
/// **Threading.** `run` blocks and is meant for a background thread. The two sides of every
/// folder are listed at the same time, the subfolders of a folder are walked on all cores at
/// once, and with "by content" the file pairs are read and compared on all cores, each pair
/// with its own two readers. The counters shared by those threads are behind a lock.
/// `progress` is called from whichever thread has news, one call at a time. An instance runs
/// once; `cancellation` may be set from any thread.
public final class SyncComparison {
    public let options: SyncOptions
    public let cancellation: CancellationFlag
    private let fileSystems: FileSystemRegistry
    private let mask: SyncMask
    /// The names asked for (`SyncOptions.onlyNames`): as exact bytes, and as the Strings that
    /// compare equal to them (the other spelling of a name).
    private let onlyNames: Set<[UInt8]>?
    private let onlyAlike: Set<String>

    private let lock = NSLock()
    private var counters = SyncProgress()
    private var errors: [String] = []
    private var report: (SyncProgress) -> Void = { _ in }
    /// The unfiltered sizes of the two start directories' listings (under `lock`).
    private var topEntries: [Int?] = [nil, nil]
    /// The options the pairs are classified with: the tolerance only as large as the file systems need.
    private var classifying: SyncOptions

    /// The size of the blocks files are compared in.
    static let blockSize = 256 * 1_024

    public init(
        options: SyncOptions, fileSystems: FileSystemRegistry, cancellation: CancellationFlag = CancellationFlag()
    ) {
        self.options = options
        self.fileSystems = fileSystems
        self.cancellation = cancellation
        classifying = options
        mask = SyncMask(options.mask)
        onlyNames = options.onlyNames.map { Set($0.map { Array($0.utf8) }) }
        onlyAlike = Set(options.onlyNames ?? [])
    }

    public func run(left: URL, right: URL, progress: @escaping (SyncProgress) -> Void = { _ in }) -> SyncResult {
        report = progress
        // The dates of two file systems that keep them exactly are compared exactly; the tolerance
        // is for the ones that round (see `toleranceSeconds`). Otherwise a file changed two seconds
        // after its copy would count as unchanged.
        classifying.toleranceSeconds =
            Self.needsTolerance(left, right, fileSystems: fileSystems) ? options.toleranceSeconds : 0
        var rows = walk(Side(url: left, exists: true), Side(url: right, exists: true), relative: "", isTop: true)
        compareContents(of: &rows)
        lock.lock()
        defer { lock.unlock() }
        var result = SyncResult(
            rows: rows, leftDirectories: counters.leftDirectories, rightDirectories: counters.rightDirectories,
            errors: errors, wasCancelled: cancellation.isCancelled)
        result.topEntries = (topEntries[0], topEntries[1])
        result.toleranceSeconds = classifying.toleranceSeconds
        return result
    }

    /// Whether the dates of these two places may be rounded or shifted by their file systems:
    /// anything but APFS and HFS+ on this Mac (FAT and exFAT keep two-second dates, shares and
    /// servers whatever theirs do, archives two seconds).
    static func needsTolerance(_ first: URL, _ second: URL, fileSystems _: FileSystemRegistry) -> Bool {
        func exact(_ url: URL) -> Bool {
            guard url.isFileURL else { return false }
            var info = statfs()
            guard statfs(url.path, &info) == 0 else { return false }
            let type = withUnsafeBytes(of: info.f_fstypename) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            return type == "apfs" || type == "hfs"
        }
        return !(exact(first) && exact(second))
    }

    // MARK: Classification

    /// What two files of the same name are to each other, by size and date alone. The second
    /// value says that only reading them can tell (spec 09 › Comparison algorithm).
    public static func classify(left: FileItem, right: FileItem, options: SyncOptions) -> (
        state: SyncState, needsContent: Bool
    ) {
        if !options.ignoreDate {
            let difference = left.modified.timeIntervalSince(
                right.modified.addingTimeInterval(Double(options.timeOffsetHours) * 3_600))
            let tolerance = Double(max(0, options.toleranceSeconds))
            // Whole seconds are compared: a file system that keeps less than a nanosecond or
            // millisecond (exFAT, HFS+, SMB) would otherwise show every copy from APFS as older.
            func within(_ seconds: Double) -> Bool { seconds < 1 || seconds <= tolerance }
            let sameTime =
                within(abs(difference)) || (options.ignoreOneHourDifference && within(abs(abs(difference) - 3_600)))
            if !sameTime { return (difference > 0 ? .leftNewer : .rightNewer, false) }
        }
        guard left.size == right.size else { return (.different, false) }
        return options.byContent ? (.pending, true) : (.equal, false)
    }

    // MARK: Walking the trees

    /// A folder on one side: where it is, and whether it is there at all.
    private struct Side {
        let url: URL
        let exists: Bool
    }

    private func update(_ change: (inout SyncProgress) -> Void) {
        lock.lock()
        change(&counters)
        let snapshot = counters
        // Reported under the lock, so the calls arrive one at a time and in order.
        report(snapshot)
        lock.unlock()
    }

    private func note(_ error: String) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }

    /// The entries of one side that take part; nil when the folder cannot be read.
    private func list(_ side: Side, isTop: Bool, index: Int) -> [FileItem]? {
        guard side.exists else { return [] }
        do {
            let items = try fileSystems.provider(for: side.url).list(
                side.url, showHidden: options.includeHidden, cancellation: cancellation)
            // A listing that was ended by the cancel is not an error of the folder.
            if cancellation.isCancelled { return nil }
            if isTop {
                lock.lock()
                topEntries[index] = items.count
                lock.unlock()
            }
            return (isTop ? asked(among: items) : items).filter { item in
                // Links are never followed or copied, so the walk cannot run in circles; they
                // are listed so that a name that is a link on one side can be kept out of the pairs.
                item.isDirectory ? !mask.excludesFolder(item.name) : mask.matchesFile(item.name)
            }
        } catch {
            if !cancellation.isCancelled { note("\(fileSystems.displayPath(side.url)): \(error.localizedDescription)") }
            return nil
        }
    }

    /// The entries that were asked for. A name asked for in one spelling also stands for the
    /// other spelling of it (NFC, NFD) when the folder holds only that one.
    private func asked(among items: [FileItem]) -> [FileItem] {
        guard let onlyNames else { return items }
        let exact = Set(items.filter { onlyNames.contains(Array($0.name.utf8)) }.map(\.name))
        return items.filter {
            onlyNames.contains(Array($0.name.utf8)) || (onlyAlike.contains($0.name) && !exact.contains($0.name))
        }
    }

    private func walk(_ left: Side, _ right: Side, relative: String, isTop: Bool = false) -> [SyncRow] {
        guard !cancellation.isCancelled else { return [] }
        let listings = Parallel.map([(left, 0), (right, 1)]) { self.list($0.0, isTop: isTop, index: $0.1) }
        guard let leftItems = listings[0], let rightItems = listings[1] else { return [] }
        update {
            $0.leftDirectories += left.exists ? 1 : 0
            $0.rightDirectories += right.exists ? 1 : 0
        }

        let pairs = Self.sorted(Self.pair(leftItems, rightItems))

        var rows: [SyncRow] = []
        var folderRows: [SyncRow] = []
        var folders: [(left: Side, right: Side, name: String)] = []
        for pair in pairs {
            func row(_ state: SyncState, isDirectory: Bool = false) -> SyncRow {
                SyncRow(
                    directory: relative, isDirectory: isDirectory, left: pair.left, right: pair.right,
                    leftDirectory: left.url, rightDirectory: right.url, state: state, asymmetric: options.asymmetric)
            }
            if pair.left?.isSymlink == true || pair.right?.isSymlink == true {
                // A link is neither followed nor replaced: facing another entry it is shown, but nothing is done with it.
                if pair.left != nil, pair.right != nil { rows.append(row(.excluded)) }
                continue
            }
            let (leftIsFolder, rightIsFolder) = (pair.left?.isDirectory, pair.right?.isDirectory)
            if let leftIsFolder, let rightIsFolder, leftIsFolder != rightIsFolder {
                rows.append(row(.excluded))
            } else if leftIsFolder ?? rightIsFolder ?? false {
                guard options.subdirectories else { continue }
                let name = (pair.left ?? pair.right)!.name
                folders.append(
                    (
                        Side(url: pair.left?.url ?? left.url.appending(name: name), exists: pair.left != nil),
                        Side(url: pair.right?.url ?? right.url.appending(name: name), exists: pair.right != nil), name
                    ))
                if options.emptyDirectories, pair.left == nil || pair.right == nil {
                    folderRows.append(row(pair.left == nil ? .rightOnly : .leftOnly, isDirectory: true))
                }
            } else if let leftFile = pair.left, let rightFile = pair.right {
                rows.append(
                    row(
                        pair.isExactMatch
                            ? Self.classify(left: leftFile, right: rightFile, options: classifying).state
                            : .excluded))
            } else {
                // A name that differs only in case from one that is paired elsewhere is not "only here": on a
                // file system that ignores case, copying it would replace the other.
                rows.append(row(pair.collides ? .excluded : pair.left == nil ? .rightOnly : .leftOnly))
            }
        }
        let below = Parallel.map(folders) { self.walk($0.left, $0.right, relative: relative + $0.name + "/") }
        return rows + folderRows + below.flatMap { $0 }
    }

    /// The pairs in the order of their names, digits by their value (`file2` before `file10`),
    /// as Finder shows names. The order is the kernel's (`Sorter`), which is an order for any
    /// names: Foundation's localized comparison is none, and it ends the program for certain
    /// names (K001), which a folder on a server or in an archive may well hold. Each name's
    /// key is made once; the pairs themselves (large values) are moved once.
    static func sorted(_ pairs: [Pair]) -> [Pair] {
        Sorter.sorted(pairs, numeric: true) { ($0.left ?? $0.right)!.name }
    }

    struct Pair {
        var left: FileItem?
        var right: FileItem?
        /// False when the two names differ in case.
        var isExactMatch = true
        /// A name alone on its side whose lower-case form belongs to a name that has a partner: its twin in
        /// the other folder is already paired with another name.
        var collides = false
    }

    /// Puts the entries of two folders side by side: by exact name (the same bytes) first, then
    /// what is left over by name without regard to case or Unicode form. Two names that differ
    /// only in form (NFC and NFD) are two files and keep their own rows.
    static func pair(_ leftItems: [FileItem], _ rightItems: [FileItem]) -> [Pair] {
        var rightByName: [[UInt8]: Int] = [:]
        for (index, item) in rightItems.enumerated() where rightByName[Array(item.name.utf8)] == nil {
            rightByName[Array(item.name.utf8)] = index
        }
        var matched = [Bool](repeating: false, count: rightItems.count)
        var pairs: [Pair] = []
        var unmatched: [FileItem] = []
        for item in leftItems {
            if let index = rightByName[Array(item.name.utf8)], !matched[index] {
                matched[index] = true
                pairs.append(Pair(left: item, right: rightItems[index]))
            } else {
                unmatched.append(item)
            }
        }
        // What is left of the right side, in order, found by the name without its case.
        let leftovers = rightItems.indices.filter { !matched[$0] }.map { rightItems[$0] }
        var byFoldedName: [String: [Int]] = [:]
        for (index, item) in leftovers.enumerated() { byFoldedName[folded(item.name), default: []].append(index) }
        var next: [String: Int] = [:]
        var taken = [Bool](repeating: false, count: leftovers.count)
        // The names of both folders by their folded form: a name left over whose form is in use on the
        // other side collides with the name that is paired there.
        let foldedRight = Set(rightItems.map { folded($0.name) })
        let foldedLeft = Set(leftItems.map { folded($0.name) })
        for item in unmatched {
            let key = folded(item.name)
            if let indices = byFoldedName[key], case let position = next[key, default: 0], position < indices.count {
                next[key] = position + 1
                taken[indices[position]] = true
                let other = leftovers[indices[position]]
                // Names that differ only in form are the same name to this file system.
                pairs.append(Pair(left: item, right: other, isExactMatch: item.name == other.name))
            } else {
                pairs.append(Pair(left: item, right: nil, collides: foldedRight.contains(key)))
            }
        }
        return pairs
            + leftovers.indices.filter { !taken[$0] }.map {
                Pair(left: nil, right: leftovers[$0], collides: foldedLeft.contains(folded(leftovers[$0].name)))
            }
    }

    private static func folded(_ name: String) -> String { name.folding(options: .caseInsensitive, locale: nil) }

    // MARK: By content

    /// Reads the pairs that size and date could not tell apart, on all cores.
    private func compareContents(of rows: inout [SyncRow]) {
        let pending = rows.indices.filter { rows[$0].state == .pending }
        guard !pending.isEmpty else { return }
        update {
            $0.filesToCompare = pending.count
            $0.bytesToCompare = pending.reduce(Int64(0)) { $0.addingSaturated(rows[$1].left?.size ?? 0) }
        }
        let candidates = pending.map { rows[$0] }
        let states = Parallel.map(candidates) { self.contentState(of: $0) }
        for (index, state) in zip(pending, states) {
            rows[index].state = state
            rows[index].defaultAction = SyncRow.proposal(for: state, asymmetric: options.asymmetric)
            rows[index].action = rows[index].defaultAction
        }
    }

    private func contentState(of row: SyncRow) -> SyncState {
        guard !cancellation.isCancelled, let left = row.left, let right = row.right else { return .pending }
        defer { update { $0.filesCompared += 1 } }
        do {
            let same = try Self.sameContent(
                left.url, right.url, fileSystems: fileSystems, cancellation: cancellation
            ) { bytes in
                self.update { $0.bytesCompared += Int64(bytes) }
            }
            return same.map { $0 ? .equal : .different } ?? .pending
        } catch {
            if !cancellation.isCancelled { note("\(fileSystems.displayPath(left.url)): \(error.localizedDescription)") }
            return .pending
        }
    }

    /// Reads two files side by side and stops at the first difference. Nil when cancelled.
    /// The blocks a reader hands out may be of any length; they are cut to match.
    static func sameContent(
        _ first: URL, _ second: URL, fileSystems: FileSystemRegistry, cancellation: CancellationFlag,
        progress: (Int) -> Void = { _ in }
    ) throws -> Bool? {
        if cancellation.isCancelled { return nil }
        var readers: [any FileReader] = []
        // A read blocked on a server ends as soon as the flag is set.
        var tokens: [AnyObject] = []
        defer {
            readers.forEach { $0.close() }
            withExtendedLifetime(tokens) {}
        }
        for url in [first, second] {
            let reader = try fileSystems.provider(for: url).read(url, cancellation: cancellation)
            readers.append(reader)
            tokens.append(cancellation.interrupting(reader))
        }
        var buffers = [Data(), Data()]
        var ended = [false, false]
        while true {
            if cancellation.isCancelled { return nil }
            // One block of each side per round, in a pool of its own (a long pair of files would keep every block until it ends).
            let verdict: Bool?? = try autoreleasepool {
                for side in 0..<2 where !ended[side] && buffers[side].isEmpty {
                    if let block = try readers[side].read(upToCount: blockSize), !block.isEmpty {
                        buffers[side] = block
                    } else {
                        ended[side] = true
                    }
                }
                let count = min(buffers[0].count, buffers[1].count)
                if count == 0 {
                    // One side has ended: the files are the same only if the other has too.
                    return .some(buffers[0].isEmpty && buffers[1].isEmpty && ended[0] && ended[1])
                }
                guard buffers[0].prefix(count) == buffers[1].prefix(count) else { return .some(false) }
                buffers = buffers.map { Data($0.dropFirst(count)) }
                progress(count)
                return nil
            }
            if let verdict { return verdict }
        }
    }
}
