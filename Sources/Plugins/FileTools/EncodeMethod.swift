/// The formats of Encode File (spec 08 › Encode).
///
/// The raw values are those of the spec's `EncodeMethod` setting; the cases stand in the order of the dialog.
internal enum EncodeMethod: Int, CaseIterable {
    /// MIME (Base64), with mail headers.
    case mime = 0
    /// UUEncode.
    case uue = 1
    /// XXEncode.
    case xxe = 2

    /// The name in the dialog.
    internal var title: String {
        switch self {
        case .mime:
            return "MIME (Base64)"

        case .uue:
            return "UUEncode"

        case .xxe:
            return "XXEncode"
        }
    }

    /// The extension of the encoded files.
    internal var fileExtension: String {
        switch self {
        case .mime:
            return "b64"

        case .uue:
            return "uue"

        case .xxe:
            return "xxe"
        }
    }

    /// The bytes of the original one full line carries.
    internal var bytesPerLine: Int { self == .mime ? 57 : 45 }
    /// The length of a full line with its CRLF.
    internal var lineLength: Int { self == .mime ? 78 : 63 }
}
