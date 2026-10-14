import FuzzCore

/// The `panel` and `paneldup` targets: up to 60 operations on a `PanelModel`, its invariants after each.
@MainActor
internal enum PanelTarget {
    /// A panel target; with `unique` no two listed items have the same bytes for a name.
    internal static func make(_ name: String, unique: Bool) -> FuzzTarget {
        FuzzTarget(
            name,
            maxLen: 3_000,
            seeds: {
                [
                    (0..<400).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 3) },
                    (0..<600).map { UInt8(truncatingIfNeeded: $0 &* 101 &+ 17) }, [UInt8](repeating: 7, count: 300),
                    (0..<500).map { UInt8(truncatingIfNeeded: ($0 * $0) >> 3) }
                ]
            },
            run: { bytes in
                run(bytes, unique: unique)
            }
        )
    }

    /// Runs the operations of one input.
    private static func run(_ bytes: [UInt8], unique: Bool) {
        FuzzState.shuffler = Shuffler(state: UInt64(bytes.count) &+ 42)
        FuzzState.uniqueNames = unique
        let session = PanelSession(bytes: bytes)
        var steps = 0
        while !session.choices.atEnd, steps < 60 {
            steps += 1
            session.step()
        }
    }
}
