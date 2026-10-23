/// Where the passwords of saved connections are kept.
///
/// Safe from any thread.
public protocol PasswordStore: AnyObject, Sendable {
    /// The password kept under `account`, nil when there is none (or it cannot be read).
    func password(for account: String) -> String?
    /// Keeps `password` under `account`, in place of what was there; nil removes the password.
    func setPassword(_ password: String?, for account: String)
}
