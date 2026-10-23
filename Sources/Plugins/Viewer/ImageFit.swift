/// How an image is fitted to the window (the specification's `ShrinkBitmap`).
///
/// The raw values are stored under `viewer.fitImages` and are the index of the Configure Lister choice.
internal enum ImageFit: Int {
    /// The image at its own size.
    case actualSize = 0
    /// Only images larger than the window are shrunk to fit it.
    case largerOnly = 2
    /// Every image is scaled to fit the window.
    case window = 1
}
