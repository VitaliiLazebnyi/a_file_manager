import AFMKernel
import Foundation
import StressKit

@testable import ViewerPlugin

/// What every part of the scenario does the same way: open a file, act as the user at the pager.
@MainActor
internal enum Harness {
    /// Opens `url` as ViewerPane does for a local file: in the background, read through a block cache.
    internal static func openSource(_ url: URL, fileSystems: FileSystemRegistry) -> any ByteSource {
        let opened = Shared<(any ByteSource)?>(nil)
        DispatchQueue.global(qos: .userInitiated)
            .async {
                let source: any ByteSource
                do {
                    source = try ProviderByteSource.open(url, fileSystems: fileSystems)
                } catch {
                    preconditionFailure("cannot open \(url.path): \(error)")
                }
                let cached = CachedByteSource(source)
                DispatchQueue.main.async { opened.value = cached }
            }
        pump(upTo: 60) { opened.value != nil }
        guard let source = opened.value else {
            preconditionFailure("\(url.path) did not open within 60 s")
        }
        return source
    }

    /// What a user does at the pager, on the main thread, once per tick of the run loop; with
    /// `mayStop`, also Esc now and then.
    internal static func userAction(_ pager: TextPagerView, _ random: inout Random, mayStop: Bool) {
        guard !Options.noUser, let document = pager.document else {
            return
        }
        switch random.next() % (mayStop ? 400 : 5) {
        case 0, 1:
            pager.scroll(toPercent: Double(random.next() % 10_001) / 100)

        case 2:
            pager.scroll(toLine: 1 + Int(random.next() % UInt64(max(1, document.lineCount))))

        case 3:
            pager.reveal(offset: Int64(random.next() % UInt64(max(1, document.length))))

        case 4:
            _ = (pager.percent, pager.position, pager.indexingProgress, pager.isIndexing)

        case 5:
            pager.stopReading()  // Esc: about once a second

        default:
            userAction(pager, &random, mayStop: false)
        }
    }
}
