/// What a copy does with a symbolic link (spec 07 › Other copy settings, `CopyLinks`).
public enum LinkHandling: Int, Sendable {
    /// The link itself is copied and points where it pointed.
    case copyLinks = 0
    /// The file or folder the link points to is copied in its place.
    case followLinks = 1
}
