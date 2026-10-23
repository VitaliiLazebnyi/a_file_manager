import CoreGraphics

/// An image ready to draw: one frame, or the frames of an animation with their delays.
internal struct DecodedImage {
    /// The frames in the order they play, each with the seconds it stays; one for a still image.
    internal var frames: [(image: CGImage, delay: Double)]
    /// The size of the file's image in pixels; the frames are smaller when it was downsampled.
    internal var pixelSize: CGSize
    /// Frames of an animation that were left out because together they would take too much
    /// memory (`ImageDecoder.animationMemoryLimit`): the animation is cut short.
    internal var framesDropped = 0

    /// The size the frames are drawn at for 100 %.
    internal var size: CGSize { frames.first.map { CGSize(width: $0.image.width, height: $0.image.height) } ?? .zero }
    /// Whether the frames have fewer pixels than the file's image (it was too large to decode whole).
    internal var isDownsampled: Bool { size.width < pixelSize.width || size.height < pixelSize.height }
}
