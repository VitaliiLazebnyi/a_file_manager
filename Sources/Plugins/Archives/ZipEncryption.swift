/// How the members of a new ZIP are encrypted.
internal enum ZipEncryption: Equatable {
    /// AES with a 256-bit key as WinZip defined it (AE-2): what protects the contents. Opened
    /// by 7-Zip, WinZip, Keka, The Unarchiver and libarchive; not by the old `unzip`.
    case aes256
    /// The traditional ZIP encryption: every unzip program opens it, and anyone who knows a
    /// few bytes of a member can break it in minutes. Only for exchange with old programs.
    case legacy
}
