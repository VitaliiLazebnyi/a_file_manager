import AFMKernel
import Foundation
import StressKit

@testable import AFMShell

/// What loading a location the way a panel does took and brought.
internal struct LoadResult {
    /// Seconds to the first piece (0 when none came).
    internal let first: Double
    /// Seconds to the end.
    internal let total: Double
    /// The items of the last piece.
    internal let count: Int
    /// What the loading ended with.
    internal let error: (any Error)?
}

/// Loads a location the way a panel does (PanelLoading: background read, pieces on the main thread).
@MainActor
internal func panelLoad(_ bench: Bench, _ location: URL) -> LoadResult {
    let started = now()
    var first = 0.0
    var count = 0
    var ended = false
    var failure: (any Error)?
    let loading = PanelLoading(
        PanelLoading.Source(
            location: location,
            showHidden: true,
            fileSystems: bench.fileSystems,
            cache: ListingCache()
        ),
        order: PanelLoading.OrderBox(ListOrder()),
        cancellation: CancellationFlag()
    )
    loading.start(
        onPiece: { piece in
            if first == 0 {
                first = now() - started
            }
            count = piece.listing.items.count
        },
        onEnd: { error in
            failure = error
            ended = true
        }
    )
    pump(upTo: 600) { ended }
    return LoadResult(first: first, total: now() - started, count: count, error: failure)
}
