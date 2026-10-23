import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `[T4]`: the date a camera recorded in a picture (EXIF "date taken", else the digitized or
/// the plain date; spec 18 › Date and time).
///
/// Read from files on the local disk only; called on the preview threads. Only plain files of a
/// picture type that are on this disk are opened: a FIFO in the list would hold a preview thread
/// for good, a stub of a file in the cloud would be downloaded, and the decoders of ImageIO are not
/// pointed at what is not a picture.
internal enum ContentDate {
    /// One formatter for all files; formatting and parsing with it is safe from several threads.
    private static let formatter: DateFormatter = {
        let made = DateFormatter()
        made.locale = Locale(identifier: "en_US_POSIX")
        made.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return made
    }()

    /// The date recorded in the picture at `url`; nil for what is no picture on this disk, or has no date.
    internal static func read(_ url: URL) -> Date? {
        guard url.isFileURL, isPicture(url), isPlainFileHere(url),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return nil
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let recorded =
            exif?[kCGImagePropertyExifDateTimeOriginal] ?? exif?[kCGImagePropertyExifDateTimeDigitized]
            ?? tiff?[kCGImagePropertyTIFFDateTime]
        guard let text = recorded as? String else {
            return nil
        }
        return formatter.date(from: text)
    }

    /// Whether the name is that of a picture (or a camera's raw file).
    internal static func isPicture(_ url: URL) -> Bool {
        let ext = url.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else {
            return false
        }
        return type.conforms(to: .image) || type.conforms(to: .rawImage)
    }

    /// A regular file whose contents are on this disk.
    internal static func isPlainFileHere(_ url: URL) -> Bool {
        var info = stat()
        // SF_DATALESS: the contents are in the cloud.
        return stat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_flags & 0x4000_0000 == 0
    }
}
