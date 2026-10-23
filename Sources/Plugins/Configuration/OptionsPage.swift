import AppKit

/// A page of the Options window.
///
/// What the user changes on it is pending until `commit`.
@MainActor
internal protocol OptionsPage: AnyObject {
    /// The page's name in the list of pages and above the page.
    var title: String { get }
    /// The page's content, made the first time the page is shown.
    var view: NSView { get }
    /// Whether something was changed on the page that `commit` would store.
    var isChanged: Bool { get }
    /// Called by the page when the user changed something, so Apply can be offered.
    var onEdit: (() -> Void)? { get set }
    /// Apply and OK.
    func commit()
    /// Cancel, and every time the window opens: show what is stored.
    func discard()
}
