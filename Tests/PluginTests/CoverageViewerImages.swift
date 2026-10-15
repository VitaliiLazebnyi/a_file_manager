import CoreGraphics
import Foundation
import ImageIO

/// Pictures and image files made for the tests.
internal enum CoverageViewerImages {
    /// The errors of making a picture.
    internal enum Failure: Error {
        /// No drawing context could be made.
        case noContext
        /// The destination for the file could not be made.
        case noDestination
        /// The drawing gave no picture.
        case noImage
        /// The file could not be written.
        case notWritten
    }

    /// A picture of one colour, mostly green.
    internal static func picture(_ width: Int, _ height: Int) throws -> CGImage {
        try make(width, height, red: 0.1, gray: false)
    }

    /// A picture of one colour with `red` in it.
    internal static func picture(_ width: Int, _ height: Int, red: CGFloat) throws -> CGImage {
        try make(width, height, red: red, gray: false)
    }

    /// A picture of one shade of gray, in a gray colour space.
    internal static func grayPicture(_ width: Int, _ height: Int) throws -> CGImage {
        try make(width, height, red: 0.1, gray: true)
    }

    /// `images` written as a file of `type`.
    internal static func encoded(_ images: [CGImage], type: String) throws -> Data {
        try encoded(images, type: type, properties: [:], frameProperties: [:])
    }

    /// `images` written as a file of `type`, with the properties of the file and of every frame.
    internal static func encoded(
        _ images: [CGImage],
        type: String,
        properties: [CFString: Any],
        frameProperties: [CFString: Any]
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, images.count, nil) else {
            throw Failure.noDestination
        }
        CGImageDestinationSetProperties(destination, properties as CFDictionary)
        for image in images {
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw Failure.notWritten
        }
        return data as Data
    }

    /// An animated GIF of `count` frames of `size` pixels, each shown `delay` seconds.
    internal static func animation(count: Int, size: Int, delay: Double) throws -> Data {
        try encoded(
            (0..<count).map { try picture(size, size, red: 0.05 * CGFloat($0 % 6)) },
            type: "com.compuserve.gif",
            properties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]],
            frameProperties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
        )
    }

    private static func make(_ width: Int, _ height: Int, red: CGFloat, gray: Bool) throws -> CGImage {
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)
        guard let space,
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw Failure.noContext
        }
        context.setFillColor(CGColor(srgbRed: red, green: 0.7, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw Failure.noImage
        }
        return image
    }
}
