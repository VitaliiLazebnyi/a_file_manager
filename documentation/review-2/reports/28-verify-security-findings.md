# Verify security findings

Twelve of the sixteen claims hold in full, three hold only in part (11, 13, 14), and one is refuted as stated (9). Claim 1 is the serious one, and claim 16 is worse than reported. Nothing in the project was modified and the app was never launched; all tests ran in `scratchpad/verify2/security/` on copies of the code.

Three things about my runs that you should know:
- The regex timing test for claim 16 used about six minutes of CPU on the busy machine, far more than intended.
- A `ksh -l` / `dash -l` probe sourced your `~/.profile` (read only, it printed a syntax error).
- Marker files are left in `c13/` and `c16/root/` under the scratch folder.

## Claim 1 — file names run as shell code: CONFIRMED (ran)

I compiled the real `ParameterExpansion.swift` with a stub `FileItem.split` and passed the expanded lines to `/bin/zsh -c` and `/bin/bash -c`. Marker files were created by `touch` text taken from the file name.

- **Cause (grapheme):** `ShellWords.escaped` (`ParameterExpansion.swift:63-70`) compares whole Swift `Character`s, so `"`, `` ` ``, `\` or `$` followed by a combining mark is not escaped. `needsQuoting` works on scalars, so the value is still wrapped in `"…"`, which the name then closes.
- **Single quotes:** line 284 has the same flaw; `replacingOccurrences(of: "'")` does not match `'` + U+0301.
- **Hand-off:** the line goes unchanged to `$SHELL -l -c` (`CommandRunner.swift:192, 247`).
- **Such names exist on disk:** I created `a"́;touch M1;"́` on APFS and listed it back byte for byte.

Affected through the grapheme bug, with any template, even the plainest `cmd %N`:
- `%N %n %v %V %M %m %O %o %E %e %P %p %T %t %S %s %R %r %B %C1-9`
- the same codes inside the user's own `"…"` or `'…'`
- the in-quote `%S` path (line 428)
- `%|VAR|` and `%VAR%` in the Command field (`CommandLanguage.swift:105-107`), which are not attacker-controlled in practice
- `%P`/`%T` when a folder name carries the payload

Not affected: `%L %F %D %UL %UF %WL %WF` (names go into a list file), and `cd` or internal `cm_` steps (no shell). `%Q` switches quoting off by design.

Affected only with particular templates, through quote-state tracking (`:232-244`), using plain ASCII names:

| Template | Name that executes | Why |
|---|---|---|
| `"$(cmd %N)"` | `g x;touch M7`, `e";touch M5;"` | value is escaped for double quotes but sits in a fresh `$(…)` context |
| `` `cmd %N` `` | `f$(touch M6)` | backticks strip the `\` from `\$` |
| `$'%N'` | `h\';touch M8;'` | backslash is live inside `$'…'` |
| `%N # don't` + newline + `%N` | `g x;touch M7` | apostrophe in a comment flips the quote state; needs a multi-line field |

Here-docs are the same class but I did not run them.

- **Precondition:** a crafted file or folder name in a folder the user visits (extracted archive, download, share, FTP listing), plus the user running any user command, button or Start-menu entry with one of these codes while the cursor or selection is on it.
- **Severity:** high. Arbitrary code as the user.

**`$SHELL -l -c` under csh/tcsh: CONFIRMED (ran).** `/bin/tcsh -l -c 'echo hi'` and `/bin/csh` both print `Unknown option: -l` and exit 1. In `CommandRunner.launch` the output goes to the null device and the exit status is never read, so the command silently does nothing. `SystemToolsPlugin.swift:143` has the same flags. This is a functional bug, not a security one.

## Claims 2–16

| # | Verdict | Evidence | Precondition | Severity | Ran? |
|---|---|---|---|---|---|
| 2 | CONFIRMED | `PanelDragAndDrop.swift:24-28` reads `afm.panel-item` from any pasteboard; no `draggingSource` check in `validateDrop`/`acceptDrop` (`PanelViewController+Interaction.swift:307-325`) | User drags from a hostile app onto a panel | Low. Any URL scheme gets in (`ftp://`, `archive://`, `vfolder://`), so a drop can start a connection or transfer; a confirmation shows only if `confirmsDrops` is on | Read |
| 3 | CONFIRMED | No preview after the file-name prompt (`NetworkCommands.swift:351-363`); `move(arrived, to: to, replacing: true)` at `:468` reaches plain `rename(2)` (`LocalFileSystem.swift:439`). The list also accepts `put:`, `copy:`, `move:`, so it can upload or move local files | User runs a list file someone else wrote | Medium. `ftp://evil/x -> ~/.zshenv` silently replaces an existing file; the copy step only asks if the source's own name exists. | Read |
| 3, line injection | PLAUSIBLE-unproven | `isSafeName` rejects only `/` and NUL (`FTPListParser.swift:32-35`); `DownloadList.parse` splits on every Unicode newline. No `/` is allowed per name, so a payload needs nested remote folder names | Malicious server, then "Add to download list", then run | Low | Read |
| 4, meta refresh | CONFIRMED | `RichViews.swift:281-289` allows every `.other` navigation; the CSP does not cover navigation. A headless `WKWebView` with the same config fetched `http://127.0.0.1:18473/refresh` and showed it. JavaScript stayed off; `<img>`, `<iframe>`, CSS, `<video>`, `<object>` produced no request; `file://` refresh was blocked | User views a hostile HTML file in page mode. Not the default: `viewer.htmlAsText` defaults to true (`ViewerSettings.swift:87`) | Low-medium: IP disclosure, remote content in the viewer | Ran |
| 4, RTF/PDF links | RTF: parsing CONFIRMED, opening unproven. PDF: unproven | `NSAttributedString(rtf:)` kept `x-evil-scheme://…` and `file:///…Calculator.app` as `.link`; the viewer has no `clickedOnLink` or `PDFViewDelegate`. I did not click, so what AppKit opens is not shown | User clicks a link | Low | Parse only |
| 5 | Primitive CONFIRMED; full chain unproven | `RichViews.swift:51`: `lastPathComponent` of `ftp://h/a/..%2F..%2Fx` returns `../../x` on this OS, giving `<folder>/../../x`; `createFile` truncates an existing file. Listings cannot produce this (`appending(name:)` encodes `%`). Routes: `followLink` (`ViewerPane.swift:623-630`) loads any absolute href from a viewed page; tab files, typed URLs, `cm_List <url>`. Only `.media`/`.other` content takes this path (`ViewerPane.swift:561`) | Malicious server plus a viewed page and a click, or a crafted URL | Medium if the chain works: server-chosen path overwritten with server content | Primitive only |
| 6 | CONFIRMED | `restore` writes every key in the file, not only known ones (`ConfigurationModels.swift:292-295`); `validate` checks shape only; no summary or confirmation (`ConfigurationCenter.swift:269-285`). Password lookup is by UUID alone (`RemoteFileSystem.swift:59-65`) | User imports a hostile file. The password redirect also needs the victim's connection UUID, which is in their own export | High for the import: user commands plus key bindings mean code runs on the next keypress, and `network.trustedCertificates` can be pre-seeded. Low-medium for the redirect | Read |
| 7 | CONFIRMED | No quarantine code in `Sources/Plugins/Network`; the protocol default returns nil (`FileSystemProvider.swift:278`); `Resources/Info.plist` has no quarantine key | Malicious or compromised server, user opens the download | Low-medium: no Gatekeeper prompt | Read |
| 8 | CONFIRMED | `ZipFormat.swift:253-255` is the only cipher and its comment calls it weak; the dialog says only "Encrypt (ZIP only)" (`ArchiveCommands.swift:234, 306-314`) | Someone obtains the archive | Medium for anyone relying on it | Read |
| 9 | REFUTED as stated | `VirtualLocation.prefix(of:)` would copy user-info, but panel URLs are built without credentials (`ServerAddress.swift:44-50, 183`; `RemoteFileSystem.swift:591-598`). Only a hand-written `ftp://u:p@host/` in a tab file or `afm.panel-item` could carry one | — | Negligible | Read |
| 10, mount error | CONFIRMED | `VolumeMounting.swift:35` puts `url.absoluteString` in the alert; `NetworkCommands.swift:383` echoes the typed text | User typed `smb://user:pass@host` and the mount failed | Low: on-screen only; I found no log write but did not trace `ui.report` to the end | Read |
| 10, password saved despite untick | CONFIRMED | `edit()` deletes it when unticked (`:233-235`); the caller then sees none stored and saves `profile.password` (`:273-276`) | Quick connect with a password in the address, then "save session" on disconnect | Low | Read |
| 11 | FTPS: CONFIRMED. SFTP: REFUTED | `NetStream.swift:154-165` and `NetworkCommands.swift:56-75`: a new fingerprint for a host that already has an accepted one gets the same dialog; "Always trust" appends. SFTP uses `/usr/bin/ssh` with no `StrictHostKeyChecking` override (`SFTPSession.swift:52-59`), so the system `ssh` handles a changed key rather than this dialog | On-path attacker against a server with a self-signed certificate | Medium for FTPS | Read |
| 12 | CONFIRMED | `NWListener(using: .tcp, on: .any)`, first connection wins, no peer check (`NetStream.swift:564-592`). Passive mode correctly reuses the control peer (`FTPConnection.swift:454`) | Active mode (not default), plain FTP, attacker reaching the port in the window | Low | Read |
| 13a | CONFIRMED, limited | `ArchiveTree.swift:81-84` and `Unpacker.swift:256` split on `Character`. `../́escaped.txt` and `../‍e3.txt` (U+0301, U+200D) landed in the parent of the destination. Exactly one level up, and the name must begin with the combining character, so no known file can be targeted | User unpacks a hostile archive | Low | Ran the two copied lines, not the full Unpacker |
| 13b | CONFIRMED | `OpenArchive.swift:270`. An mtree text file named `evil.7z` with `contents=<marker>` produced a tar holding the marker's content. Any file that is not ZIP, TAR, gz, bz2 or xz takes this path (`ArchiveLocation.swift:245`) | User enters or unpacks the file | Low: local files are copied into the listing or extraction, with no exfiltration by itself | Ran the exact bsdtar call |
| 13c | Partly CONFIRMED | `ByteStreams.swift:339` creates archive files with 0644 regardless of source modes; member modes inside are preserved (`Packer.swift:393, 502, 520`) | Another local user | Low | Read |
| 14 | Count: REFUTED (bounded). Injection and connect: CONFIRMED | File capped at 1 MiB (`FolderTabsPlugin.swift:332, 408`), still roughly 100k tabs. `text()` writes paths and captions unescaped (`TabFile.swift:38-40`). A loaded active tab is shown at once; `ftp://user:pw@host` is announced without asking (`RemoteFileSystem.swift:595-596`) | Hostile `.tab` file, or a folder name with a newline that the user saves and reloads | Low | Read |
| 15 | CONFIRMED | Export takes every JSON-valued key in the defaults domain (`ConfigurationPlugin.swift:59-67`): command history, connection hosts, users and UUIDs, trusted fingerprints, tabs. `Data.write(.atomic)` gave mode 644 under umask 022. Tree cache is plain text in Application Support (`TreeCache.swift:180`, `PlacesPlugin.swift:72`) | Another local user, or wherever the export is shared | Low; the cache is informational | Ran the mode check |
| 16 | CONFIRMED, worse than claimed | Copied patterns from `FTPListParser.swift:129-133`. One line of `-rwxrwxrwx ` plus N digits took 3.4 s at 5,000, 20 s at 10,000, 78 s at 20,000, 268 s at 40,000. No line cap (`FTPConnection.swift:592-596`); `readLine` and the reply buffer are unbounded (`NetStream.swift:457-472`, `FTPConnection.swift:294-300`). | Malicious FTP server; user opens any folder | Medium: one roughly 40 KB line holds a thread for minutes, many lines hold every core, and a server that never sends a newline exhausts memory | Ran |

## Further defects noticed

- **`followLink` loads any absolute URL** (`ViewerPane.swift:623-630`). Any href that is not http, https or mailto is opened in the viewer, including `file:///…` and other servers. This is the route that makes claim 5 reachable.
- **Unbounded listing remainder** (`FTPConnection.swift:592-594`). `rest` is re-split in full on every 256 KB block, so a long line without a newline costs quadratic time and unbounded memory, separately from the regex.
- **Link-first extraction is unproven.** `Unpacker.swift:361-366` creates symlinks with any target. Within one run the folders are created first, so a "link, then file through the link" archive should fail; a second archive unpacked into the same folder would follow an existing link. I did not test it.
