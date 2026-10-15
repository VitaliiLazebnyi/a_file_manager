import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The pictures of the Thumbnails view (spec 03 › Thumbnails): made in the background, kept,
/// and given up when their tiles go out of sight.
@MainActor
@Suite(.serialized)
internal struct PanelThumbnailTests {
    /// An entry of `size` bytes at `/x`.
    private func item(_ name: String, size: Int64) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/x/" + name), name: name, stat: .init(size: size))
    }

    /// Pictures arrive later and are kept; a request for a tile out of sight is given up and its
    /// late answer dropped; a file without a picture is not asked for twice until the folder is
    /// shown anew.
    @Test
    internal func thumbnailsArriveLaterAreKeptAndAreCancelledWhenOutOfSight() async {
        let source = PanelScriptedThumbnails()
        let store = ThumbnailStore(source: source)
        var arrived: [String] = []
        store.onArrival = { arrived.append($0) }
        let (first, second, text) = (item("a.png", size: 1), item("b.png", size: 1), item("c.txt", size: 1))
        #expect(
            store.image(for: first, side: 96, scale: 2) == nil && store.image(for: second, side: 96, scale: 2) == nil
        )
        // Asking again while the picture is being made does not ask the source again.
        #expect(store.image(for: first, side: 96, scale: 2) == nil && source.requested == ["a.png", "b.png"])
        #expect(store.running.count == 2)
        let picture = NSImage(size: NSSize(width: 10, height: 10))
        source.answer("a.png", with: picture)
        #expect(await PanelWait.until { arrived == ["a.png"] })
        #expect(store.image(for: first, side: 96, scale: 2) === picture && store.running.count == 1)
        // Scrolled away: the request for b is given up, and an answer that still comes is dropped.
        let late = source.pending["b.png"]
        store.keepOnly([ThumbnailStore.key(for: first, side: 96)])
        #expect(source.cancelled == ["b.png"] && store.running.isEmpty)
        late?(picture)
        await PanelWait.drainMainQueue()
        #expect(
            arrived == ["a.png"] && store.image(for: second, side: 96, scale: 2) == nil && source.requested.count == 3
        )
        // A file without a picture is not asked for twice, until the folder is shown anew.
        #expect(store.image(for: text, side: 96, scale: 2) == nil)
        source.answer("c.txt", with: nil)
        #expect(await PanelWait.until { store.running.count == 1 })
        #expect(
            store.image(for: text, side: 96, scale: 2) == nil && source.requested.filter { $0 == "c.txt" }.count == 1
        )
        store.reset()
        #expect(store.running.isEmpty && store.image(for: text, side: 96, scale: 2) == nil)
        #expect(source.requested.filter { $0 == "c.txt" }.count == 2)
        // Another size, or a changed file, is another picture.
        #expect(ThumbnailStore.key(for: first, side: 96) != ThumbnailStore.key(for: first, side: 128))
        #expect(ThumbnailStore.key(for: first, side: 96) != ThumbnailStore.key(for: item("a.png", size: 2), side: 96))
    }

    /// The answer of a request that was given up does not end a newer request for the same picture.
    @Test
    internal func theAnswerOfAGivenUpThumbnailRequestDoesNotSpoilANewerOne() async {
        let source = PanelScriptedThumbnails()
        let store = ThumbnailStore(source: source)
        var arrived: [String] = []
        store.onArrival = { arrived.append($0) }
        let picture = item("a.png", size: 1)
        #expect(store.image(for: picture, side: 96, scale: 2) == nil)
        let late = source.pending["a.png"]
        // Scrolled away and back: a second request for the same picture is under way.
        store.keepOnly([])
        #expect(store.image(for: picture, side: 96, scale: 2) == nil && source.requested == ["a.png", "a.png"])
        #expect(store.running.count == 1)
        // The first request answers late, with nothing: that must not end the second request or
        // mark the file as one without a picture.
        late?(nil)
        await PanelWait.drainMainQueue()
        #expect(store.running.count == 1)
        let image = NSImage(size: NSSize(width: 10, height: 10))
        source.answer("a.png", with: image)
        #expect(await PanelWait.until { arrived == ["a.png"] })
        #expect(store.image(for: picture, side: 96, scale: 2) === image)
    }

    /// Pictures are counted by their pixels, not by how many there are.
    @Test
    internal func picturesAreCountedByTheirPixels() throws {
        #expect(ThumbnailStore.cost(of: NSImage(size: NSSize(width: 10, height: 10))) == 400)
        let representation = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 512,
                pixelsHigh: 512,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let retina = NSImage(size: NSSize(width: 256, height: 256))
        retina.addRepresentation(representation)
        #expect(ThumbnailStore.cost(of: retina) == 512 * 512 * 4)
        #expect(ThumbnailStore.cost(of: NSImage(size: .zero)) == 1)
        // Of several representations the largest counts.
        let small = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 64,
                pixelsHigh: 64,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        retina.addRepresentation(small)
        #expect(ThumbnailStore.cost(of: retina) == 512 * 512 * 4)
    }

    /// Quick Look makes the picture of a real file in the background, and a request can be given up.
    @Test
    internal func quickLookMakesThePictureOfARealFile() async throws {
        let box = try Sandbox()
        let file = try box.file("picture.txt", "some text for a picture")
        let pictures = Shared(0)
        let source = QuickLookThumbnails()
        let cancel = source.thumbnail(for: file, side: 64, scale: 1) { _ in pictures.modify { $0 += 1 } }
        #expect(await PanelWait.until { pictures.value == 1 })
        let other = source.thumbnail(for: file, side: 32, scale: 1) { _ in
            // An answer may still come after the request was given up.
        }
        other()
        cancel()
    }
}
