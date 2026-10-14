public import AFMKernel
import Foundation

/// The menus of the menu bar and the sections inside them, shared by every plugin that adds
/// entries (spec 04 › Main menu, in the Mac's menu order). A plugin with a menu of its own
/// declares its own `MenuID`.
extension MenuID {
    /// The Files menu: what is done to the files under the cursor or marked.
    public static let files = MenuID("Files", order: 10)
    /// The Edit menu: the clipboard and the names of files.
    public static let edit = MenuID("Edit", order: 20)
    /// The Mark menu: choosing which files the next command works on.
    public static let mark = MenuID("Mark", order: 30)
    /// The Commands menu: going places, volumes, panels and tools.
    public static let commands = MenuID("Commands", order: 40)
    /// The Net menu: connections to servers and network volumes.
    public static let net = MenuID("Net", order: 45)
    /// The Show menu: how the panels show their files.
    public static let show = MenuID("Show", order: 50)
    /// The Configuration menu: the options and how they are kept.
    public static let configuration = MenuID("Configuration", order: 60)
    /// The Start menu: the user's own menu of programs and commands.
    public static let start = MenuID("Start", order: 70)
    /// The Help menu: the manual and what the program is.
    public static let help = MenuID("Help", order: 90)
}
