import Foundation
import TestSupport

@testable import MacIntegrationPlugin

/// A desktop that notes what it is asked, from any thread, and starts nothing.
///
/// Unchecked `Sendable`: the records are `Shared` values; `preview` and `chosen` are used on the
/// main thread only.
internal final class CoverageMacDesktop: MacDesktop, @unchecked Sendable {
    /// What was asked, one line each: `open-with <app> <paths>`, `open <path>`, `reveal <paths>`,
    /// `choose <title>`, `share <paths>`.
    internal let requests = Shared<[String]>([])
    /// The Quick Look panel of this desktop.
    @MainActor internal let panel = CoverageMacPreview()
    /// What the user picks when asked for an application.
    @MainActor internal var chosen: URL?

    /// The Quick Look panel of this desktop.
    @MainActor internal var preview: any PreviewPanel { panel }

    /// A desktop that has been asked nothing.
    @MainActor
    internal init() {
        // Nothing asked yet.
    }

    /// Notes the request.
    internal func open(_ urls: [URL], with application: URL) {
        note("open-with \(application.lastPathComponent) " + urls.map(\.path).joined(separator: " "))
    }

    /// Notes the request.
    internal func open(_ url: URL) {
        note("open " + url.path)
    }

    /// Notes the request.
    internal func reveal(_ urls: [URL]) {
        note("reveal " + urls.map(\.path).joined(separator: " "))
    }

    /// Notes the request and answers with `chosen`.
    @MainActor
    internal func chooseApplication(title: String) -> URL? {
        note("choose " + title)
        return chosen
    }

    /// Notes the request.
    @MainActor
    internal func share(_ urls: [URL]) {
        note("share " + urls.map(\.path).joined(separator: " "))
    }

    private func note(_ line: String) {
        requests.modify { $0.append(line) }
    }

    deinit {
        // Nothing to release.
    }
}
