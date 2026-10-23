public import Foundation

/// The places a Finder sidebar starts with, offered next to the user's own entries.
public enum MacFavorites {
    /// The standard folders in `home`, Applications and iCloud Drive, as hotlist items.
    ///
    /// Works on paths alone; nothing is asked of the disk.
    public static func entries(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [HotlistEntry] {
        let below = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]
            .map { name in
                HotlistEntry.item(name, command: "cd " + home.appendingPathComponent(name, isDirectory: true).path)
            }
        return [.item("Home", command: "cd " + home.path), .item("Applications", command: "cd /Applications")] + below
            + [
                .item(
                    "iCloud Drive",
                    command: "cd "
                        + home.appendingPathComponent(
                            "Library/Mobile Documents/com~apple~CloudDocs",
                            isDirectory: true
                        )
                        .path
                )
            ]
    }
}
