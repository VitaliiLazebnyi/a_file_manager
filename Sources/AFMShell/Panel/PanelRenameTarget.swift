/// The item whose name is being edited in place: it keeps the editor for as long as it is in
/// the list of the tab and folder the editor was opened in.
internal struct PanelRenameTarget {
    /// The tab.
    internal let tab: ObjectIdentifier
    /// The folder (`URL.locationKey`).
    internal let location: String
    /// The item's name.
    internal let name: String
}
