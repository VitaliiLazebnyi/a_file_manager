/// The three fonts of the Options menu (spec 10 › Font slots): each stands for a font and,
/// unless the Encoding menu says otherwise, a character set.
internal enum FontSlot: Int {
    /// The fixed-width font with the ANSI (Windows) character set.
    case ansi = 0
    /// The fixed-width font with the DOS character set.
    case ascii = 1
    /// The variable-width font with the ANSI character set.
    case variable = 2

    /// The character set the slot reads text in.
    internal var encoding: ViewerEncoding { self == .ascii ? .dos : .ansi }
}
