public import AFMKernel
import Foundation

/// The sections of the shared menus, each a group of entries between separators.
extension MenuSection {
    /// Opening files: open, open with.
    public static let filesOpen = MenuSection(.files, order: 10)
    /// Copy, move and rename.
    public static let filesTransfer = MenuSection(.files, order: 20)
    /// New folder, new file.
    public static let filesCreate = MenuSection(.files, order: 30)
    /// Delete, delete without the Trash.
    public static let filesDelete = MenuSection(.files, order: 40)
    /// Finding files.
    public static let filesTools = MenuSection(.files, order: 50)
    /// Properties, attributes, comments, occupied space.
    public static let filesProperties = MenuSection(.files, order: 45)
    /// Pack, unpack, test archives.
    public static let filesArchives = MenuSection(.files, order: 60)
    /// Multi-rename, compare by content, links.
    public static let filesAdvanced = MenuSection(.files, order: 70)
    /// Split, combine, encode, decode, checksums.
    public static let filesTransform = MenuSection(.files, order: 80)
    /// Printing.
    public static let filesPrint = MenuSection(.files, order: 90)

    /// Cut, copy and paste files.
    public static let editClipboard = MenuSection(.edit, order: 10)
    /// Copying and changing names.
    public static let editNames = MenuSection(.edit, order: 20)

    /// Marking by a mask or a list.
    public static let markGroups = MenuSection(.mark, order: 10)
    /// Marking everything, nothing, or the opposite.
    public static let markAll = MenuSection(.mark, order: 20)
    /// Save and load selections, copy names.
    public static let markStore = MenuSection(.mark, order: 30)
    /// Compare directories, mark newer.
    public static let markCompare = MenuSection(.mark, order: 40)

    /// Going back, forward, up, to a folder.
    public static let commandsGo = MenuSection(.commands, order: 10)
    /// Choosing a volume.
    public static let commandsVolumes = MenuSection(.commands, order: 20)
    /// Arranging the two panels.
    public static let commandsPanels = MenuSection(.commands, order: 30)
    /// Directory tree, hotlist, history, branch view.
    public static let commandsPlaces = MenuSection(.commands, order: 15)
    /// Find, synchronize, system information, terminal.
    public static let commandsTools = MenuSection(.commands, order: 40)
    /// Command line, run.
    public static let commandsRun = MenuSection(.commands, order: 50)

    /// Connecting to servers and leaving them.
    public static let netConnections = MenuSection(.net, order: 10)
    /// Transfer mode and download lists.
    public static let netTransfers = MenuSection(.net, order: 20)
    /// Network volumes.
    public static let netVolumes = MenuSection(.net, order: 30)

    /// What the files are sorted by.
    public static let showSortKey = MenuSection(.show, order: 10)
    /// Sorting the other way round.
    public static let showSortDirection = MenuSection(.show, order: 20)
    /// Which files are shown.
    public static let showFilters = MenuSection(.show, order: 30)
    /// Folder tabs.
    public static let showTabs = MenuSection(.show, order: 40)
    /// Brief, Full, Thumbnails, Quick View, custom columns.
    public static let showViewType = MenuSection(.show, order: 5)
    /// Button bar, command line, function keys, panel arrangement.
    public static let showWindow = MenuSection(.show, order: 60)

    /// The configuration dialog.
    public static let configurationOptions = MenuSection(.configuration, order: 10)
    /// Choosing helper programs.
    public static let configurationCustomize = MenuSection(.configuration, order: 20)
    /// Saving the window position and the settings.
    public static let configurationSave = MenuSection(.configuration, order: 30)

    /// The manual.
    public static let helpTopics = MenuSection(.help, order: 10)
}
