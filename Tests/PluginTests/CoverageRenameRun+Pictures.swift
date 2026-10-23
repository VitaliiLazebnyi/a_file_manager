import AFMKernel
import Foundation
import ImageIO
import TestSupport
import Testing
import UniformTypeIdentifiers

@testable import MultiRenamePlugin

/// The dates inside pictures and the result log.
extension CoverageRenameRun {
    // MARK: Dates in pictures

    /// A picture with the given EXIF and TIFF properties (empty: none).
    internal func picture(_ name: String, exif: [CFString: Any], tiff: [CFString: Any]) throws -> URL {
        let url = box.url(name)
        let context = try #require(
            CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                url as CFURL,
                (url.pathExtension == "tif" ? UTType.tiff : UTType.jpeg).identifier as CFString,
                1,
                nil
            )
        )
        var properties: [CFString: Any] = [:]
        if !exif.isEmpty {
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if !tiff.isEmpty {
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// The date taken of the picture at `url`, as year-month-day hour in the time zone of the Mac.
    internal func taken(_ url: URL) -> String? {
        ContentDate.read(url)
            .map { date in
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = .current
                let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
                return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0) \(parts.hour ?? 0)"
            }
    }

    /// The date taken comes from the best field there is: the original, the digitized, the plain one.
    @Test
    internal func theDateTakenComesFromTheBestField() throws {
        let original = try picture(
            "o.jpg",
            exif: [kCGImagePropertyExifDateTimeOriginal: "2021:05:06 07:08:09"],
            tiff: [:]
        )
        #expect(taken(original) == "2021-5-6 7")
        let digitized = try picture(
            "d.jpg",
            exif: [kCGImagePropertyExifDateTimeDigitized: "2020:01:02 03:04:05"],
            tiff: [:]
        )
        #expect(taken(digitized) == "2020-1-2 3")
        let plain = try picture("t.tif", exif: [:], tiff: [kCGImagePropertyTIFFDateTime: "2019:12:31 23:00:00"])
        #expect(taken(plain) == "2019-12-31 23")
        #expect(taken(try picture("n.jpg", exif: [:], tiff: [:])) == nil)
    }

    /// Only plain pictures on the disk are opened.
    @Test
    internal func onlyPlainPicturesOnTheDiskAreOpened() throws {
        #expect(ContentDate.read(url("/x.jpg")) == nil)
        #expect(ContentDate.read(try box.file("notes.txt")) == nil)
        #expect(ContentDate.read(try box.file("noextension")) == nil)
        #expect(ContentDate.read(try box.folder("folder.jpg")) == nil)
        #expect(ContentDate.read(try box.file("broken.jpg", "no picture")) == nil)
        #expect(ContentDate.isPicture(URL(fileURLWithPath: "/a/raw.dng")))
        #expect(!ContentDate.isPicture(URL(fileURLWithPath: "/a/x.unknownextension")))
    }

    /// `[T4]` reads each picture once, however often the preview is made.
    @Test
    internal func theDateTakenIsReadOnce() throws {
        let file = try picture(
            "p.jpg",
            exif: [kCGImagePropertyExifDateTimeOriginal: "2021:05:06 07:08:09"],
            tiff: [:]
        )
        let cache = RenameCache()
        #expect(cache.contentDate(of: file) != nil)
        try FileManager.default.removeItem(at: file)
        #expect(cache.contentDate(of: file) != nil)
        #expect(cache.forChangedOrder().contentDate(of: file) != nil)
        #expect(RenameCache().contentDate(of: file) == nil)
    }

    // MARK: The result log

    /// A log that cannot be written is left out.
    @Test
    internal func aLogThatCannotBeWrittenIsLeftOut() throws {
        let folder = try box.folder("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let log = folder.appending(path: RenameLog.fileName)
        RenameLog.write([RenamedItem(from: url("/a"), destination: url("/b"))], to: log, fileSystems: registry)
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }

    /// A file moved elsewhere is logged with its whole path.
    @Test
    internal func aFileMovedElsewhereIsLoggedWithItsWholePath() {
        let text = RenameLog.text(
            [RenamedItem(from: url("/a/x.txt"), destination: url("/b/y.txt"))],
            fileSystems: registry
        )
        #expect(
            text == "\"\(registry.displayPath(url("/a/x.txt")))\" -> \"\(registry.displayPath(url("/b/y.txt")))\"\n"
        )
    }
}
