/// Where a decoder puts what it finds.
internal protocol DecodeSink: AnyObject {
    /// A file starts; `name` is as the encoded text gives it, nil when it gives none.
    func begin(name: String?) throws
    /// The next decoded bytes of the file that was begun.
    func write(_ bytes: [UInt8]) throws
    /// The file that was begun is complete.
    func end() throws
}
