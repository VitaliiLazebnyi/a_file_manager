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

extension MenuSection {
    public static let filesOpen = MenuSection(.files, order: 10)
    public static let filesTransfer = MenuSection(.files, order: 20)
    public static let filesCreate = MenuSection(.files, order: 30)
    public static let filesDelete = MenuSection(.files, order: 40)
    public static let filesTools = MenuSection(.files, order: 50)
    /// Properties, attributes, comments, occupied space.
    public static let filesProperties = MenuSection(.files, order: 45)
    /// Pack, unpack, test archives.
    public static let filesArchives = MenuSection(.files, order: 60)
    /// Multi-rename, compare by content, links.
    public static let filesAdvanced = MenuSection(.files, order: 70)
    /// Split, combine, encode, decode, checksums.
    public static let filesTransform = MenuSection(.files, order: 80)
    public static let filesPrint = MenuSection(.files, order: 90)

    public static let editClipboard = MenuSection(.edit, order: 10)
    public static let editNames = MenuSection(.edit, order: 20)

    public static let markGroups = MenuSection(.mark, order: 10)
    public static let markAll = MenuSection(.mark, order: 20)
    /// Save and load selections, copy names.
    public static let markStore = MenuSection(.mark, order: 30)
    /// Compare directories, mark newer.
    public static let markCompare = MenuSection(.mark, order: 40)

    public static let commandsGo = MenuSection(.commands, order: 10)
    public static let commandsVolumes = MenuSection(.commands, order: 20)
    public static let commandsPanels = MenuSection(.commands, order: 30)
    /// Directory tree, hotlist, history, branch view.
    public static let commandsPlaces = MenuSection(.commands, order: 15)
    /// Find, synchronize, system information, terminal.
    public static let commandsTools = MenuSection(.commands, order: 40)
    /// Command line, run.
    public static let commandsRun = MenuSection(.commands, order: 50)

    public static let netConnections = MenuSection(.net, order: 10)
    public static let netTransfers = MenuSection(.net, order: 20)
    public static let netVolumes = MenuSection(.net, order: 30)

    public static let showSortKey = MenuSection(.show, order: 10)
    public static let showSortDirection = MenuSection(.show, order: 20)
    public static let showFilters = MenuSection(.show, order: 30)
    public static let showTabs = MenuSection(.show, order: 40)
    /// Brief, Full, Thumbnails, Quick View, custom columns.
    public static let showViewType = MenuSection(.show, order: 5)
    /// Button bar, command line, function keys, panel arrangement.
    public static let showWindow = MenuSection(.show, order: 60)

    public static let configurationOptions = MenuSection(.configuration, order: 10)
    public static let configurationCustomize = MenuSection(.configuration, order: 20)
    public static let configurationSave = MenuSection(.configuration, order: 30)

    public static let helpTopics = MenuSection(.help, order: 10)
}

extension ContextMenuSection {
    public static let open = ContextMenuSection(order: 10)
    public static let transfer = ContextMenuSection(order: 20)
    public static let clipboard = ContextMenuSection(order: 30)
    public static let create = ContextMenuSection(order: 40)
    public static let tools = ContextMenuSection(order: 50)
    public static let archives = ContextMenuSection(order: 45)
    public static let properties = ContextMenuSection(order: 60)
}
