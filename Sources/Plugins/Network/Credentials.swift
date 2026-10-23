/// A user name and password the user typed while connecting.
public struct Credentials: Sendable {
    /// The name to log in with.
    public var user: String
    /// The password to log in with.
    public var password: String
    /// The user wants the password kept for the saved connection.
    ///
    /// It is stored once the server has accepted it (`SessionEnvironment.rememberPassword`), not
    /// before.
    public var remember: Bool

    /// Credentials as the user typed them; `remember` is false unless the user asked to keep the password.
    public init(user: String, password: String, remember: Bool = false) {
        self.user = user
        self.password = password
        self.remember = remember
    }
}
