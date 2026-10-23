public import AFMKernel

/// The commands only this plugin uses (spec 11 › The Net menu, 17 › Command catalogue).
extension CommandID {
    /// FTP New Connection: a dialog for an address to connect to at once, without saving it.
    public static let ftpNew: CommandID = "cm_FtpNew"
    /// FTP Disconnect: closes a connection, the source panel's or one the user picks.
    public static let ftpDisconnect: CommandID = "cm_FtpDisconnect"
    /// FTP Show Hidden Files: shows or hides the dot files of the server in the source panel.
    public static let ftpHiddenFiles: CommandID = "cm_FtpHiddenFiles"
    /// FTP Transfer Mode: picks binary, text or automatic for the transfers that follow.
    public static let ftpSelectTransferMode: CommandID = "cm_FtpSelectTransferMode"
    /// FTP Add to Download List: puts the selected remote files on the download list.
    public static let ftpAddToList: CommandID = "cm_FtpAddToList"
    /// FTP Download From List: fetches what a download list names into the target panel's folder.
    public static let ftpDownloadList: CommandID = "cm_FtpDownloadList"
    /// `.text`: `session` or `session|/subdir`, the name of a saved connection (spec 11 ›
    /// Opening connections by command).
    public static let ftpOpen: CommandID = "FTPOPEN"
    /// Connect to Server: the Mac's form of *Network Connections…*. `.text`: the address.
    public static let netConnect: CommandID = "cm_NetConnect"
    /// Eject the volume the source panel shows: the Mac's form of *Disconnect Network Drives…*.
    public static let netDisconnect: CommandID = "cm_NetDisconnect"
}
