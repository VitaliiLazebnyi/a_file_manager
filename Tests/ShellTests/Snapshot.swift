import AppKit
import Foundation

/// Snapshot tests: a view drawn offscreen and compared with a reference image kept in git.
///
/// The references are `Tests/Snapshots/<name>.png`, drawn at twice the view's size (a Retina
/// screen) in the light appearance. Two images match when they have the same size and only a
/// few pixels differ by more than a little (`channelTolerance`, `pixelTolerance`): font
/// smoothing may differ in the last bits from one Mac to the next, a changed drawing does not.
/// A view that draws the user's accent colour (a selection, the source panel's path bar) is
/// drawn in it, so such a state is not a good reference.
///
/// `AFM_RECORD_SNAPSHOTS=1 swift test --filter Snapshots` writes the references anew; a missing
/// reference is written as well. Both count as a mismatch, so a recording never passes unseen.
/// When an image does not match, what was drawn is written to `.build/snapshots/<name>.png`.
@MainActor
internal enum Snapshot {
    /// How far a colour channel (0...255) may be off before the pixel counts as different.
    internal static let channelTolerance = 24
    /// The share of pixels that may be different.
    internal static let pixelTolerance = 0.002
    /// Pixels per point.
    private static let scale = 2

    /// The repository: this file is `Tests/ShellTests/Snapshot.swift`.
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Draws `view` and compares it with the reference `name`; nil when they match, else why not.
    internal static func mismatch(of view: NSView, named name: String) -> String? {
        let reference = repository.appendingPathComponent("Tests/Snapshots/\(name).png")
        guard let drawn = image(of: view), let png = png(of: drawn) else {
            return "\(name): the view could not be drawn"
        }
        let recording = ProcessInfo.processInfo.environment["AFM_RECORD_SNAPSHOTS"] == "1"
        guard !recording,
            let stored = NSImage(contentsOf: reference)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            do {
                let folder = reference.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: reference)
                return "\(name): recorded \(reference.path); run the test again to compare with it"
            } catch {
                return "\(name): the reference could not be written: \(error)"
            }
        }
        guard let difference = difference(between: drawn, and: stored) else {
            return nil
        }
        let failed = repository.appendingPathComponent(".build/snapshots/\(name).png")
        let folder = failed.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? png.write(to: failed)
        return "\(name): \(difference); drawn: \(failed.path), reference: \(reference.path)"
    }

    /// The view drawn the way the tests compare it: light appearance, `scale` pixels per point.
    private static func image(of view: NSView) -> CGImage? {
        let size = view.bounds.size
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width) * scale,
                pixelsHigh: Int(size.height) * scale,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let light = NSAppearance(named: .aqua)
        else { return nil }
        bitmap.size = size
        view.appearance = light
        light.performAsCurrentDrawingAppearance {
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        return bitmap.cgImage
    }

    private static func png(of image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Why two images do not match, or nil when they do.
    private static func difference(between drawn: CGImage, and stored: CGImage) -> String? {
        guard drawn.width == stored.width, drawn.height == stored.height else {
            return "the size is \(drawn.width)×\(drawn.height) pixels, the reference's \(stored.width)×\(stored.height)"
        }
        let one = pixels(of: drawn)
        let other = pixels(of: stored)
        guard !one.isEmpty, one.count == other.count else {
            return "the pixels could not be read"
        }
        var different = 0
        for start in stride(from: 0, to: one.count, by: 4) {
            let channels = start..<start + 4
            if channels.contains(where: { abs(Int(one[$0]) - Int(other[$0])) > channelTolerance }) {
                different += 1
            }
        }
        let share = Double(different) / Double(drawn.width * drawn.height)
        let percent = String(format: "%.2f%%", share * 100)
        return share > pixelTolerance ? "\(different) pixels differ (\(percent))" : nil
    }

    /// The pixels of an image as 8-bit RGBA in sRGB, whatever form the image came in; none if
    /// they cannot be read.
    private static func pixels(of image: CGImage) -> [UInt8] {
        let bytesPerRow = image.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            return []
        }
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? bytes : []
    }
}
