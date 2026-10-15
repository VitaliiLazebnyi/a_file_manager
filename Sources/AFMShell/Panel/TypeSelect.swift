import AFMKernel
import Foundation

/// Finds a file by typing the start of its name (spec 03 › Quick search, "Letter only").
///
/// What was typed is forgotten after a pause.
internal struct TypeSelect {
    /// How long a pause makes what was typed before forgotten, in seconds.
    internal static let pause: TimeInterval = 1

    /// What was typed since the last pause.
    private var prefix = ""
    /// When the last key came, in the events' time.
    private var lastKey: TimeInterval = 0

    /// Nothing typed yet.
    internal init() {
        // Nothing typed yet.
    }

    /// The row to go to: the next entry whose name starts with `prefix`, from the cursor on, around
    /// the end of the list.
    ///
    /// A longer prefix may stay on the row it is on; a single letter moves on to the next name with
    /// that letter. **For any thread**: a long list is looked through in the background; gives up,
    /// with nil, once `cancellation` is set.
    internal static func row(
        matching prefix: String,
        in items: [FileItem],
        from cursor: Int,
        cancellation: CancellationFlag?
    ) -> Int? {
        let count = items.count
        guard count > 0, !prefix.isEmpty else {
            return nil
        }
        let start = ((prefix.count > 1 ? cursor : cursor + 1) % count + count) % count
        let matches = matcher(for: prefix)
        return items.withUnsafeBufferPointer { items in
            var row = start
            for step in 0..<count {
                if step & 0xFFF == 0xFFF, cancellation?.isCancelled == true {
                    return nil
                }
                if matches(items[row].name) {
                    return row
                }
                row += 1
                if row == count {
                    row = 0
                }
            }
            return nil
        }
    }

    /// Whether a name starts with what was typed, upper and lower case being the same.
    ///
    /// Typed text is mostly plain ASCII, as most names are: those are compared byte by byte, which
    /// is several times faster than Foundation's comparison (a key looks at every name of the list
    /// when nothing matches). Anything else is left to Foundation.
    internal static func matcher(for prefix: String) -> (String) -> Bool {
        let needle = Array(prefix.lowercased().utf8)
        let slow: (String) -> Bool = { $0.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil }
        guard needle.allSatisfy({ $0 < 0x80 }) else {
            return slow
        }
        return { name in
            let quick =
                name.utf8.withContiguousStorageIfAvailable { ASCIIComparison.hasPrefix(needle, in: $0) } ?? .unknown
            guard quick == .unknown else {
                return quick == .match
            }
            return slow(name)
        }
    }

    /// Adds a typed character, at `time` (the event's), and returns what to look for.
    internal mutating func add(_ characters: String, at time: TimeInterval) -> String {
        if time - lastKey > Self.pause {
            prefix = ""
        }
        lastKey = time
        prefix += characters
        return prefix
    }
}
