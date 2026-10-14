public import AFMKernel
import Foundation

/// The menus of the menu bar and the sections inside them, shared by every plugin that adds
/// entries (spec 04 › Main menu, in the Mac's menu order). A plugin with a menu of its own
/// declares its own `MenuID`.
extension MenuID {
    public static let files = MenuID("Files", order: 10)
    public static let edit = MenuID("Edit", order: 20)
    public static let mark = MenuID("Mark", order: 30)
    public static let commands = MenuID("Commands", order: 40)
    public static let net = MenuID("Net", order: 45)
    public static let show = MenuID("Show", order: 50)
    public static let configuration = MenuID("Configuration", order: 60)
    public static let start = MenuID("Start", order: 70)
    public static let help = MenuID("Help", order: 90)
}
