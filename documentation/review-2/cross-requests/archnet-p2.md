# Cross-requests from the second pass on archives and network (`archnet-p2`)

Nothing here blocks anything: each item has its local part in place.

## Network

### 1. Navigation, FolderTabs, shell: say when the user typed an address (N071)

- **Where:** whoever turns typed text into a location: `Sources/Plugins/Navigation` (the command line, `cd`,
  Go to Path), the path field of the shell. Not for text read from a file (a tab file, a list, a restored tab, a
  dropped item).
- **Wanted:** after `FileSystemRegistry.location(from:relativeTo:)` gave the URL of typed text and before the
  panel opens it: `kernel.services.find(ServerConsentService.self)?.userChose(url)` (main thread; it is cheap
  and does nothing for a location that names no ftp/ftps/sftp server).
- **State:** the network plugin offers the service now (`NetworkPlugin.swift`, `TypedAddresses`). Until a caller
  uses it, a typed address is still asked "Connect to X?" once. The test
  `NetworkPluginCommands.aTypedURLConnectsByItself` accepts both (asked once, or not at all), so adopting it
  breaks nothing.

### 2. FileOperations and other jobs: pass the job's flag to the changing calls (N010, N026, F021)

- **Where:** `FileJob` and every job that calls `createDirectory`, `remove`, `move`, `setAttributes` on a
  provider.
- **State:** `RemoteFileSystem` implements the four variants with `cancellation:` now. The wait for a free
  connection, for another thread's login and for the server's reply ends when the flag is set. A caller that
  still uses the variants without a flag gets the old behaviour (ends on Disconnect and at the limits).
- **One thing to know:** in a replacing `move` on a server whose rename does not replace, the flag ends only the
  first step. Once the file in the way has been renamed aside, the rest (rename in, or rename back) is seen
  through whatever the flag says, so a Cancel cannot leave the name without a file.

### 3. Configuration: kinds of the network keys (for information)

- The network plugin declares its settings keys with `Kernel.settingsKeys`: `network.` (family, ordinary),
  `network.connections` and `network.lastUsed` (`.connection`), `network.history` and
  `network.lastServerAddress` (`.history`), `network.unprotectedPasswordHosts` and
  `network.trustedCertificates` (`.trust`).
- `network.unprotectedPasswordHosts` is the list of plain FTP servers the user allowed a password to be sent to
  without being asked again. A settings file that plants a host there removes that question, so an import should
  treat it like the other trust keys (a tick). The network plugin cannot tell an imported value from one the user
  made.
- **Not done, on purpose (config-a's request for a sweep of Keychain items without a connection):** see
  `status/archnet-p2.md`, Decisions.
