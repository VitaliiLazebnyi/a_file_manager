import Foundation
import FuzzCore

/// What a `zippack` input asks for: the password, the file's name and contents, and how to pack.
internal struct PackInput {
    /// The first byte: the high four bits give the level, low bits all set ask for the old encryption,
    /// and 0x40 repeats the contents 40 times.
    internal let flags: UInt8
    /// The password; never empty.
    internal let password: String
    /// The name of the file that is packed.
    internal let name: String
    /// The contents of the file.
    internal let contents: [UInt8]

    /// Whether the old ZIP encryption is asked for instead of AES.
    internal var legacy: Bool { flags & 0x0F == 0x0F }

    /// The compression level.
    internal var level: Int { Int(flags >> 4) % 10 }

    /// Takes the choices from the input's bytes.
    internal init(_ bytes: [UInt8]) {
        var choices = Choices(bytes)
        let first = choices.byte()
        var secret = fzText(choices.take(1 + Int(choices.byte() % 20)))
        secret.unicodeScalars.removeAll { $0.value == 0 }
        if secret.isEmpty {
            secret = "pw"
        }
        var fileName = fzText(choices.take(Int(choices.byte() % 24)))
        fileName.unicodeScalars.removeAll { $0 == "/" || $0.value == 0 || $0 == ":" }
        if fileName.isEmpty || fileName == "." || fileName == ".." || fileName.utf8.count > 200 {
            fileName = "f.bin"
        }
        var body = choices.rest()
        if first & 0x40 != 0 {
            body = Array(repeating: body, count: 40).flatMap(\.self)
        }
        flags = first
        password = secret
        name = fileName
        contents = body
    }
}
