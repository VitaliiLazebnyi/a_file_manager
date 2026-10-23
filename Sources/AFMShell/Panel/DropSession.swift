import AFMContracts
import Foundation

/// What a drag carries and where its sources are, worked out once for the whole drag: the mouse
/// reports its position many times a second, and the items may be many thousands.
///
/// Main thread only.
@MainActor
internal final class DropSession {
    /// From this many sources on, their places are worked out in the background.
    internal static let backgroundThreshold = 5_000

    /// Identifies the drag (`NSDraggingInfo.draggingSequenceNumber`).
    internal let sequence: Int
    /// What is dragged; empty while the program's own drag is still putting its items together.
    internal private(set) var sources: [URL]
    /// Where the sources are; nil while that is still being worked out, in the background,
    /// for a drag of very many items.
    internal private(set) var places: DragSources?
    /// The program's own drag, until its items are known.
    private var payload: PanelDragPayload?
    /// Whether dropping all sources on a destination is pointless, by kind and destination.
    private var verdicts: [String: Bool] = [:]

    /// Where the local volumes are mounted, asked of the system the first time it is needed.
    internal private(set) lazy var mountPoints: [String] = PanelDrop.mountPoints()

    /// The session of the drag `sequence` of `sources`.
    internal init(sequence: Int, sources: [URL]) {
        self.sequence = sequence
        self.sources = sources
        locate()
    }

    /// The session of a drag that started in this program: the sources are taken when the
    /// drag has put them together.
    internal init(sequence: Int, payload: PanelDragPayload) {
        self.sequence = sequence
        sources = []
        guard !payload.isReady else {
            sources = payload.locations
            locate()
            return
        }
        self.payload = payload
        payload.whenReady { [weak self] locations in self?.take(locations) }
    }

    /// Everything is worked out here and now: the files were dropped before the background
    /// had got there, and a drop is not turned away for that.
    internal func finishNow() {
        if let payload {
            self.payload = nil
            sources = payload.locations
        }
        if places == nil {
            places = DragSources(sources)
        }
    }

    /// As long as it is not known where the sources are, every drop counts as pointless and
    /// nothing is taken: the mouse asks again in a moment.
    internal func isPointless(_ kind: TransferKind, into destination: URL) -> Bool {
        guard let places else {
            return true
        }
        let key = "\(kind)|\(destination.absoluteString)"
        if let verdict = verdicts[key] {
            return verdict
        }
        let verdict = places.isPointless(kind, into: destination)
        verdicts[key] = verdict
        return verdict
    }

    /// The program's own drag has put its items together, unless `finishNow` was quicker.
    private func take(_ locations: [URL]) {
        guard payload != nil else {
            return
        }
        payload = nil
        sources = locations
        locate()
    }

    /// Works out where the sources are: here for a few, in the background for many.
    private func locate() {
        guard sources.count >= Self.backgroundThreshold else {
            places = DragSources(sources)
            return
        }
        let dragged = sources
        Background.compute(
            work: { DragSources(dragged) },
            then: { [weak self] places in self?.settle(places) }
        )
    }

    /// The places worked out in the background, unless `finishNow` was quicker.
    private func settle(_ places: DragSources) {
        if self.places == nil {
            self.places = places
        }
    }

    deinit {
        // Nothing to release.
    }
}
