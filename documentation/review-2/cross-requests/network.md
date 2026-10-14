# Cross-requests from the network area

Each request says which file or type, what is wanted, why, and which network findings depend on it.
Everything that could be done inside `Sources/Plugins/Network` is done; these are the parts that are not ours.

## 1. Kernel — a cancellation flag for the calls that change something

- **Where:** `Sources/AFMKernel/FileSystem/FileSystemProvider.swift`, protocol `FileSystemProvider`.
- **Wanted:** variants with a flag, defaulting to the existing calls, as `read(_:cancellation:)` and
  `write(_:cancellation:)` already have:
  `func createDirectory(at url: URL, cancellation: CancellationFlag) throws`,
  `func remove(_ url: URL, cancellation: CancellationFlag) throws`,
  `func move(_ source: URL, to destination: URL, replacing: Bool, cancellation: CancellationFlag) throws`,
  `func setAttributes(_ attributes: FileAttributes, of url: URL, cancellation: CancellationFlag) throws`.
  File operations (`FileJob`) would pass the job's flag.
- **Why:** these four reach a server and may wait (for a free connection, for another thread's login, for
  the reply). Without a flag the network plugin can only make the waits end by themselves: they end when
  the connection is disconnected, when nothing has moved on the server for a while (60 s, or twice the
  timeout), and at the reply timeout. Cancel in the progress window does not reach them.
- **Findings:** N010, N026, N065 (bounded now; cancellable only with this).

## 2. File operations, Viewer, Archives — put the download mark on what comes from a server

- **Where:** `Sources/Plugins/FileOperations/FileJob.swift` (the copy and move paths that stream between two
  file systems), `Sources/Plugins/Viewer` and `Sources/Plugins/Archives/OpenArchive.swift` (temporary local
  copies of remote files), `Sources/Plugins/MacIntegration` (the opener).
- **Wanted:** nothing new in the kernel. `RemoteFileSystem.quarantine(of:)` now returns a mark
  (`0083;<hex time>;<program name>;`) for every `ftp:`, `ftps:` and `sftp:` location. Whoever writes a local
  copy of a remote file must do what the kernel's documentation of `quarantine(of:)` says: ask the source's
  `quarantine(of:)` and call the destination's `setQuarantine(_:of:)` after the file is closed. Please check
  that this is done for (a) every FileJob path, including Resume/Append and the rename from a temporary
  name, (b) the viewer's and the archive plugin's temporary copies, (c) members unpacked from an archive that
  itself lies on a server.
- **Why:** a program, installer or `.command` file fetched from a server otherwise opens with no check by
  the system.
- **Findings:** N009, N019, N067 (the provider side is done and tested; the applying side is yours).

## 3. Shell — a dialog whose default answer is the safe one

- **Where:** `Sources/AFMKernel/PluginAPI/UserInteraction.swift` and its implementation in `AFMShell`.
- **Wanted:** a way to say which button Return triggers, or which button is destructive, e.g.
  `func choose(_ message: String, detail: String, buttons: [String], style: QuestionStyle, defaultButton: Int) -> Int`.
- **Why:** the dialog for a server certificate that changed must not be answerable with a reflexive Return.
  Today the network plugin uses a form whose only button does nothing unless a box "I have checked the new
  fingerprint" is ticked. That is safe, but a real alert with Cancel as the default would be clearer.
- **Findings:** N030, N031 (fixed with the workaround; this would only improve the look).

## 4. Kernel / Navigation — tell an address the user typed from one that was read from a file

- **Where:** `FileSystemRegistry.location(from:relativeTo:)` and its callers (`NavigationPlugin` for the
  command line and `cd`; `FolderTabs/TabFile`, `VirtualFolders` list files, restored tabs, drag and drop of
  `afm.panel-item`).
- **Wanted:** some way for the caller to say "the user typed this just now", for instance a contract
  service in `AFMContracts`
  `protocol ServerConsentService { func userChose(_ location: URL) }`
  that the network plugin would offer and that Navigation would call for typed locations only.
- **Why:** a server that nobody chose in a dialog of the network plugin (and that is not a saved connection)
  is now asked about before the first login: "Connect to ftp://host? … the address may come from a tab, a
  list or a link." `location(from:)` is used for typed text and for text from files alike, so the question
  is also asked once for an address the user typed into the command line. With the service above that one
  question could be spared.
- **Findings:** N071 (fixed; this would remove one question in the typed case).

## 5. Configuration (settings export/import)

- **Where:** the import of settings.
- **For your information, no change needed for safety:**
  - `network.trustedCertificates` in the settings is no longer read by anything: certificates accepted for
    good are kept in the Keychain (`PasswordVault`), and the network plugin empties that key at start. An
    import may drop the key.
  - The password of a saved connection is kept under a name made of the connection's identifier **and**
    its scheme, host, port and user (`PasswordVault.account(of:)`). An imported connection with a known
    identifier but another host or user finds no password. Renumbering imported connections is therefore
    not needed for safety, and does no harm.
  - `SavedConnection` now decodes tolerantly (missing or wrong members take their defaults, a port outside
    1…65535 is dropped); only `id` is required.
- **Findings:** N008, N086, and direction 6 of the round (trusted fingerprints from imported settings).

## 6. Callers of `VolumeMounter` outside the plugin (none known)

- `VolumeMounter` gained `mount(_:cancellation:)` with a default implementation; existing implementations
  keep working. Nothing to do unless another module implements the protocol and wants Cancel to work.
