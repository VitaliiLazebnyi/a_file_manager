# 11: FTP and network

This chapter describes the built-in FTP client: its connection dialogs, the live session in a panel, transfers, listing
parsers, SSL/TLS, download lists, HTTP downloads and what every FTP setting does. It also covers the Windows network
functions (UNC paths, Network Neighborhood, mapping and disconnecting drives, sharing, admin shares) and the PORT
connection over a USB or parallel cable. The live-session behaviour was recorded on Windows 11 against a local test
server: plain FTP on `127.0.0.1:2121` and FTPS with explicit TLS and a self-signed certificate on `127.0.0.1:2122`, both
with anonymous login (setup: Appendix B › Local FTP and FTPS servers). The network functions were tried only against the
test machine's own shares (`\\localhost`).

**Related:** 01 (virtual file systems), 02 (FTP toolbar placement, default button bar), 03 (drive combo, path bar,
folder tabs), 04 (Net menu), 06 (keys), 07 (Copy dialog, Background Transfer Manager, Change UNIX attributes), 09
(Synchronize with FTP, Find Files and Multi-Rename on FTP), 10 (Lister, F3/F4 launching), 13 (Configuration › FTP page),
15 (file-system plugins), 17 (internal commands), 18 (path and parameter syntax), 19 (`wcx_ftp.ini` and `wincmd.ini` key
reference), Appendix B (test setup).

## 1. Overview

### 1.1 The Net menu

| Item                           | Accel | Shortcut     | Command                      | Section |
| ------------------------------ | ----- | ------------ | ---------------------------- | ------- |
| Network Connections...         | N     | —            | `cm_NetConnect` 512          | §14.3   |
| Disconnect Network Drives...   | D     | —            | `cm_NetDisconnect` 513       | §14.4   |
| Share Current Directory...     | C     | —            | `cm_NetShareDir` 514         | §14.5   |
| Unshare Directory...           | U     | —            | `cm_NetUnshareDir` 515       | §14.5   |
| Show Admin Shares              | A     | —            | `cm_AdministerServer` 2204   | §14.6   |
| FTP Connect...                 | F     | Ctrl+F       | `cm_FtpConnect` 550          | §4      |
| FTP New Connection...          | P     | Ctrl+N       | `cm_FtpNew` 551              | §3      |
| FTP Disconnect                 | e     | Ctrl+Shift+F | `cm_FtpDisconnect` 552       | §11     |
| FTP Show Hidden Files          | w     | —            | `cm_FtpHiddenFiles` 553      | §7.4    |
| FTP Download From List...      | L     | —            | `cm_FtpDownloadList` 558     | §10.3   |
| PORT Connection To Other PC... | O     | —            | `cm_DirectCableConnect` 2300 | §15     |

- A separator follows _Show Admin Shares_.
- _Network Connections_ is shown only if a network supported by Windows is installed. _Disconnect Network Drives_ is
  shown only if such a network exists **and** it supports a disconnect dialog.
- _FTP Disconnect_ is greyed when there is no connection to close, and enabled while an FTP connection is open.
- _FTP Show Hidden Files_ is a toggle and shows a check mark (✓) while on.

**Related commands without a menu item:**

| Command                                                   | Purpose                                                         |
| --------------------------------------------------------- | --------------------------------------------------------------- |
| `cm_FtpAbort` 554                                         | Abort the current FTP command                                   |
| `cm_FtpResumeDownload` 555                                | Resume an aborted download                                      |
| `cm_FtpSelectTransferMode` 556                            | Select Binary, ASCII or Auto mode (Ctrl+Shift+M)                |
| `cm_FtpAddToList` 557                                     | Add the selected files to the download list                     |
| `cm_OpenTransferManager` 559                              | Background Transfer Manager (07 › Background Transfer Manager)  |
| `cm_FtpConfig` 489                                        | Configuration › FTP page (13 › Operation › FTP)                 |
| `cm_OpenNetwork` 2125                                     | Open Network Neighborhood                                       |
| `cm_NTinstallDriver` 2301 / `cm_NTremoveDriver` 2302      | Install / remove the parallel-port driver (§15.3)               |
| `cm_GoToPreviousLocalDir` 573 / `cm_GoToNextLocalDir` 574 | Back / forward in the directory history, skipping FTP locations |
| `FTPOPEN <session>`                                       | Open a stored connection (§2.3)                                 |

### 1.2 What the client does

- Up to **10 FTP servers** can be connected at the same time, over the Internet or an intranet.
- The client is operated with the normal file keys: F5 copy (upload/download), Shift+F5 copy within the same directory,
  Shift+F6 rename, F8 delete, F7 make directory. **F5 then F2** (the background key of the copy dialog) adds the
  transfer to the **most recently opened** Background Transfer Manager without changing the dialog's "background"
  option.
- Files can be copied directly from one server to another (§8.7).
- An `http://` or `https://` address downloads a file instead of opening a session (§10.4).
- The PORT cable connection (§15) is built on the FTP code and behaves like an FTP connection.
- **Listing formats recognised automatically:** Unix, Windows NT, VMS and PC/TCP, plus part of OS9 and AS-400. When no
  listing appears after connecting, the format is not supported; the help suggests an external client, a user-defined
  server type (§7.5) or MLSD (§7.4).
- **Restrictions:** `[Configuration] RestrictInterface` bit 64 disables FTP (Ctrl+N, Ctrl+F), bit 512 disables the PORT
  connection (19 › Language, restrictions, sounds, security, miscellaneous).

_Basis: observed on Windows 11 (menu states); help: ftp_menu, menu_net, options_connectnet, options_disconnectnet,
inisettings2; WCMD_ENG.MNU, inc.txt, KEYBOARD.TXT._

## 2. Connection model and addresses

### 2.1 A connection is a panel location

- A connection is a file system shown in a panel, identified by a connection number `0`…`9`. All open connections are
  listed under the virtual root **`\ftp`**, which is an entry of the path bar's special-folder menu (03 ›
  Current-directory bar (path bar)). How the connected panel looks: §7.1.
- **Which panel:** Configuration › FTP _Open new connections_ (`wcx_ftp.ini [General] FtpOpenIn`): `0` the active panel
  (default), `1` left, `2` right, `3` the inactive (target) panel.
- **Connecting in a panel that already shows a connection** (`AutoDisconnect`): `0` ask (default), `1` disconnect the
  previous connection, `2` keep it.
- Folder tabs on an FTP connection show the connection number, e.g. `0:tmp` (03 › Tab header appearance). The breadcrumb
  cascade waits `BreadcrumbDelayFtp=500` ms on FTP paths (19 › Current-directory bar and breadcrumbs). `DriveBarHide`
  with `0`–`9` hides FTP drive buttons (03 › Drive button bar).
- `%p` and `%t` in button parameters give the URL on an FTP connection (18 › Button and command parameters). Ignore-list
  entries can address FTP servers with the prefixes `FTP:`, `FTP:server:` and `FTP:>connection:` (13 › Operation ›
  Ignore list). Find Files accepts FTP start paths such as `0:/home/u/a;0:/home/u/b` (09 › "Search in": start paths,
  drives, list files).

### 2.2 Address and URL syntax

Accepted in the Ctrl+N box (§3). The Host field of a stored connection (§5) takes a host with optional `:port` and an
optional scheme prefix.

- `host`, `host:port`, `user@host:port`;
- the full form `scheme://user:password@host:port/path`, in which every part except the host is optional;
- examples from the help: `ftp://somewebhost.com/home/myusername`, `https://www.google.com`, `myself@myserver.com:1021`.

| Scheme                | Meaning                                                             |
| --------------------- | ------------------------------------------------------------------- |
| `ftp://`              | Plain FTP                                                           |
| `ftps://`             | FTP over SSL/TLS, the same as the _SSL/TLS_ checkbox                |
| `ftpes://`            | Force **explicit** TLS (`AUTH TLS` on the plain control connection) |
| `ftpis://`            | Force **implicit** TLS (encrypted from the first byte)              |
| `http://`, `https://` | No session: the file is downloaded (§10.4)                          |

- **IPv6:** a literal address in brackets with the port after it, e.g. `[1234:56:789A:BC::DE]:21`, or a name that
  resolves to IPv6. It must be enabled with `PreferIPv6` (§2.4).
- `DecodePercent=1` decodes `%hh` in the user name and password of a URL (`%73` → `s`).
- Since 11.50 the Host field of a **stored** connection may also hold a file-system plugin path `\\\Pluginname\Path`, or
  any local or UNC directory. The session list then also serves as a general bookmark list.

### 2.3 Opening connections by command

| Command                                           | Effect                                                                                                   |
| ------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `cd ftp://ftp.server.com`                         | Opens a connection to that address                                                                       |
| `FTPOPEN session`                                 | Opens a stored connection                                                                                |
| `FTPOPEN session\|/subdir`                        | Connects (in the panel chosen by `FtpOpenIn`) unless already connected, then changes to the subdirectory |
| `FTPOPEN session\|*/subdir`                       | The same, but always in the active panel                                                                 |
| `cd port://usb/c:/dir` or `cd port://lpt1/c:/dir` | Starts a PORT connection as client (§15.1)                                                               |

These work from buttons, the Start menu, the hotlist and hotkeys (14 › The command language).

### 2.4 IPv6 and the socket library

`PreferIPv6` (`wcx_ftp.ini`):

| Value        | Behaviour                                                   |
| ------------ | ----------------------------------------------------------- |
| -1 (default) | Prefer IPv4, using `wsock32.dll`; IPv6 is not used          |
| 0            | Prefer IPv4                                                 |
| 1            | Prefer IPv6 for servers that have both                      |
| 2            | Try IPv4 and IPv6 in the order the name server returns them |
| -2           | IPv6 off completely; try only the first IPv4 address        |

Every value except -1 uses `ws2_32.dll`. `[Configuration] Wsock32=` sets the path of the socket library.

_Basis: observed on Windows 11 (panel display); help: ftp_menu, dlg_newconnection, dlg_connectdetails,
wcx_ftp_ini_settings, inisettings2, usb_cable_connection; inc.txt._

## 3. Quick connect: the "ftp" dialog (Ctrl+N)

```text
ftp
Connect to (host or URL):
[                                                ▾]
[x] anonymous connection
[ ] Use firewall (proxy server)
     [Define new...                    ▾] [ Change... ]   (disabled until the box is ticked)
                       [ OK ] [ Cancel ] [ Help ]
```

- **Connect to:** an editable combo with a history. After a session it offered `127.0.0.1:2121`. The history is
  `wcx_ftp.ini [OldConnections] 0=…, 1=…`. A password typed into the URL is **never** stored in it.
- **anonymous connection:**
  - Ticked and no user in the URL: TC logs in as `anonymous` with the configured e-mail address as the password.
  - Unticked: TC asks for a user name and password during the connect.
  - It is **unticked automatically** as soon as the text contains `@`.
- **First anonymous login:** TC asks once for the address and remembers it (`[General] E-Mail=`):

```text
ftp
Your e-mail address as password:
[                                          ]
                    [ OK ] [ Cancel ]
```

- **Use firewall (proxy server):** use the firewall definition (§5.5). A firewall can be used for new connections only
  after it has been set up once in a connection's details. `[firewall] default=1` makes new connections use it; the
  value is updated automatically every time a connection is saved.
- **Passive mode** for a quick connection comes from `[default] pasvmode` (Configuration › FTP _Use passive mode by
  default_). When a connection is configured, its passive setting becomes the new default.
- **OK** connects (§6), or downloads the file for an http/https address, and adds the text to the history.
- On disconnecting, a quick connection offers to be saved (§11).

_Basis: observed on Windows 11 and under Wine (layout); help: dlg_newconnection, ftp_menu,
dialog_box__firewall_settings, wcx_ftp_ini_settings._

## 4. "Connect to ftp server" dialog (Ctrl+F)

```text
Connect to ftp server
Connect to:
┌──────────────────────────────────────┐  [ Connect           ]
│ (saved sessions; folders as nodes)   │
│                                      │  [ New connection... ]
│                                      │  [ New URL...        ]
│                                      │  [ Duplicate entry...]
│                                      │  [ New folder...     ]
│                                      │
│                                      │  [ Edit...           ]
│                                      │  [ Delete            ]
│                                      │  [ Encrypt...        ]
│                                      │  [ Cancel            ]
│                                      │
└──────────────────────────────────────┘  [ Help               ]
```

### 4.1 The list

- On opening, the cursor is on the **last used** connection (`[connections] default=<name>`, a name, not a number).
- **Order:** the help says new connections are saved in alphabetical order. On Windows the list showed the saved
  sessions in creation order; their names were not recorded, so whether the two orders differ for them is open.
- **Icons:**
  - a sheet with a globe: plain FTP;
  - a sheet with a lock in the middle: FTP over SSL/TLS;
  - an extra small lock: the password is protected by the master password (its corner is given inconsistently in the
    help, §16).
- **Folders:**
  - _New folder..._ asks "New folder (directory)" for a name and creates a group. Connections are moved into folders, or
    out to the root of the list, by drag & drop; several selected connections move in one operation, and a drag can
    start anywhere on a line (change log).
  - A connection inside a folder is named `Folder|Session` (the pipe separates the levels).
  - Empty folders are kept in `[|empty_folders|]`.
  - Space on a folder opens or closes it; `+` and `-` are shortcuts in the list (their exact function is not stated); ←
    closes a folder without moving the cursor up a line. _Edit_ on a folder renames or moves it. A folder can be deleted
    only after the connections in it have been deleted (change log).
- The list supports multi-character quick search, and several selected connections can be deleted at once. When a delete
  or a drag fails because `wcx_ftp.ini` is write-protected, an error is shown (change log).
- The dialog is resizable, with a minimum size that keeps the Help button visible (change log).

### 4.2 Buttons

| Button                     | Behaviour                                                                             |
| -------------------------- | ------------------------------------------------------------------------------------- |
| Connect, or a double click | Open the connection (§6)                                                              |
| New connection...          | "FTP: connection details" for a new entry (§5)                                        |
| New URL...                 | The Ctrl+N dialog (§3)                                                                |
| Duplicate entry...         | A new entry with all settings of the entry under the cursor                           |
| New folder...              | A new group (§4.1)                                                                    |
| Edit...                    | "FTP: connection details" for the entry under the cursor; on a folder: rename/move it |
| Delete                     | Remove the entry (or the selected entries). Saved **at once**.                        |
| Encrypt...                 | Master-password operations (§4.3)                                                     |
| Cancel                     | Close without connecting                                                              |

### 4.3 Encrypt and the master password

**Encrypt...** with no master password set asks:

```text
Please choose the operation you want to perform:
       [ Protect connections with master password... ]
       [ Cancel ]
```

Per the help, Encrypt protects the passwords of **all or only the selected** connections, changes an existing master
password, or removes the encryption (_Remove encryption_). The buttons shown when a master password already exists were
not recorded.

**Rules:**

- Protected passwords use **AES-256**. `[General] AESVerify` stores a verifier used to check an entered master password.
- An entered master password stays in memory until TC is **minimized** or the **screen saver** starts.
  `KeepMasterPassword` changes this: `1` keep it when minimized, `2` keep it when the screen saver starts, `3` both.
- The master-password dialog has a Windows Hello option; `[Configuration] UseWindowsHello=1` stores the master password
  with Windows Hello until TC closes. The option is unticked if storing fails and disabled when Windows Hello is not set
  up (change log).
- The dialog shows an estimated password strength, which does not check dictionary words.
- **Keyboard hook** (`Allowhook`): the master-password dialog reads keys through a system-wide keyboard hook and then
  clears them, which defeats simple keyloggers.

| `Allowhook` | Behaviour                        |
| ----------- | -------------------------------- |
| 0           | No hook; a warning icon is shown |
| 1           | Hook; an icon indicates it       |
| 2 (default) | Hook; no icon                    |

- File-system plugins can store their passwords under the same master password, in `[|FSPlugin|PluginName]`, so that the
  master password can be changed for them as well (15 › File-system plugins in use).
- The help recommends a master password because otherwise malware can read stored passwords.

_Basis: observed on Windows 11 (list order and icons) and under Wine (layout, Encrypt box); help: dialog_box__connect,
dlg_connectdetails, wcx_ftp_ini_settings, inisettings2; change log._

## 5. "FTP: connection details" dialog

Opened by _New connection..._ and _Edit..._ in §4, and by **Yes** in the save prompt of §11. Two tabs, **General** and
**Advanced**; buttons [OK] [Cancel] [Help].

### 5.1 General tab

```text
FTP: connection details
 General | Advanced
Session:            [                                    ]
Host name[:Port]:   [                                    ]
[ ] SSL/TLS         [ Anonymous login (e-mail address as password) ]
User name:          [                                    ]
Password:           [                                    ]
Warning: Storing the password is insecure!
[ ] Use master password to protect the password
Remote Dir:         [                                    ]
Local dir:          [                              ] [>>]
[ ] Use passive mode for transfers (like a WWW browser)
[ ] Use firewall (proxy server)
     [Define new...                ▾] [ Change... ]
                                          [ Advanced -> ]
              [ OK ] [ Cancel ] [ Help ]
```

- Ticking **SSL/TLS** puts `ftps://` in front of the Host field and also ticks _Use passive mode for transfers_; the
  change log gives the reason that TLS does not work with active mode.
- **[Advanced ->]** switches to the Advanced tab.
- A **Change password** button is shown when the password is protected with a master password that has not been entered
  yet (§5.4).

### 5.2 Advanced tab

```text
 General | Advanced
Send Commands:     [                                       ]
Server type:       [Auto detect                          ▾]
[ ] Send command to keep connection alive:
     Command: [NOOP ▾]           Send interval: every [90] s
Encoding of file names: [Auto-Detect (UTF-8 if possible) ▾]
[■] Use MLSD for directory listings (grayed=auto-detect)
[x] Remember contents of all visited directories (in cache)
Client Certificate: [                                    ▾]
```

- Defaults as shown: Send Commands empty; Server type _Auto detect_; keep-alive unticked, with Command `NOOP` and
  interval 90 s greyed while it is unticked; Encoding _Auto-Detect (UTF-8 if possible)_; MLSD in the grey (auto) state;
  cache ticked; Client Certificate empty.
- **Server type** list: Auto detect · Define new type (for exotic servers) · Import from file... · and any stored types.
- **Encoding of file names** list, with the stored `Encoding=` value:

| Caption                         | Value | Caption                          | Value              |
| ------------------------------- | ----- | -------------------------------- | ------------------ |
| Auto-Detect (UTF-8 if possible) | -1    | ANSI (local code page)           | 0                  |
| ASCII/DOS (local code page)     | 1     | UTF-8                            | 65001              |
| Eastern Europe (1250)           | 1250  | Cyrillic Windows (1251)          | 1251               |
| Western Latin1 (1252)           | 1252  | Greek (1253)                     | 1253               |
| Turkish (1254)                  | 1254  | Hebrew (1255)                    | 1255               |
| Arabic (1256)                   | 1256  | Baltic (1257)                    | 1257               |
| Vietnamese (1258)               | 1258  | Chinese Main Land (936)          | 936                |
| Chinese Taiwan (950)            | 950   | Japanese (932)                   | 932                |
| Korean (949)                    | 949   | Thai (874)                       | 874                |
| DOS-USA (437)                   | 437   | DOS-LATIN1 (850)                 | 850                |
| Cyrillic KOI8-R (20866)         | 20866 | Other (enter code page manually) | the number entered |

### 5.3 Field semantics

Each stored connection is a section `[<session name>]` in `wcx_ftp.ini`, listed in `[connections] 1=…, 2=…` in display
order (key reference: 19 › `wcx_ftp.ini`).

| Field                                        | Semantics                                                                                                                                                                                                         | Key in `[<session>]`                        |
| -------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- |
| Session                                      | Free name; Unicode allowed. In a folder: `Folder\|Name`.                                                                                                                                                          | Section name and `[connections] n=`         |
| Host name[:Port]                             | Name or IP, optional `:port`; the scheme prefixes of §2.2 force TLS; since 11.50 also a plugin path or a directory                                                                                                | `host=`                                     |
| SSL/TLS                                      | Encrypted session (§9). Ticking it writes `ftps://` into the Host field, so it is presumably stored as that prefix of `host=` (the ini was not inspected; unverified).                                            | `host=`                                     |
| Anonymous login (button)                     | Asks for an e-mail address **every time** it is pressed; sets the user to `anonymous` and the password to that address                                                                                            | `anonymous=1`, `[General] E-Mail=`          |
| User name                                    | —                                                                                                                                                                                                                 | `username=`                                 |
| Password                                     | If empty, TC asks when connecting. Without a master password it is **scrambled, not encrypted** (the help calls encryption without one impossible in principle).                                                  | `password=`                                 |
| —                                            | Account password for `ACCT`; set only by hand, by copying a scrambled `password` value                                                                                                                            | `acct=`                                     |
| Use master password to protect the password  | AES-256 protection (§4.3); greyed while the master password set earlier has not been entered (§5.4)                                                                                                               | —                                           |
| Remote Dir                                   | `CWD` to this path right after login; separator `/`                                                                                                                                                               | `directory=`                                |
| Local dir                                    | After connecting, the **other** panel changes to this local path; separator `\`                                                                                                                                   | `localdir=`                                 |
| Use passive mode for transfers               | Passive (PASV): the **client** opens the data connection. Unticked: active (PORT), the **server** connects back (§8.6).                                                                                           | `pasvmode=1/0`                              |
| Use firewall (proxy server)                  | Use the firewall definition (§5.5)                                                                                                                                                                                | `firewall=1`                                |
| Send Commands                                | Commands sent after login, separated by `;` (§6.1)                                                                                                                                                                | `InitCommands=`                             |
| Server type                                  | Auto detect (empty), a stored type, _Define new type_, _Import from file_ (§7.5); no effect with MLSD                                                                                                             | `hosttype=<type name>`                      |
| Send command to keep connection alive        | Sends the command every N seconds to simulate traffic on servers with a short timeout; sent for **at most 1 hour**, so that the server slot is freed for others; not available in the Background Transfer Manager | `keepalive=90,NOOP`                         |
| Encoding of file names                       | §7.6                                                                                                                                                                                                              | `Encoding=` (default -1)                    |
| Use MLSD (tri-state)                         | §7.4                                                                                                                                                                                                              | `MLSD=-1/1/0`                               |
| Remember contents of all visited directories | §7.3                                                                                                                                                                                                              | `CacheDirs=1/0` (default 1)                 |
| Client Certificate                           | A certificate from the Windows store (§9.4)                                                                                                                                                                       | `ClientCert=<serial>:<first half of SHA-1>` |
| —                                            | Per-site flags; they take precedence over `[General] SpecialFlags` (§13.4)                                                                                                                                        | `SpecialFlags=`                             |

For stored connections, the user-name and password request dialogs shown while connecting carry the connection name in
their title, so that external password managers can fill them (change log).

### 5.4 The greyed master-password checkbox

The checkbox is greyed while the master password set earlier has not been entered. Three ways remove the protection:

1. Click **Change password** and enter the master password. The checkbox is enabled again.
2. Click **Change password**, then **Abort**. The checkbox is enabled, but unticking it means the connection password
   must be retyped; OK with an empty password **loses** the password.
3. Close the dialog, then use §4 › _Encrypt_ › _Remove encryption_.

### 5.5 Firewall (proxy) settings

The firewall settings dialog (help only; not opened in any session) holds a **Connect method** and a **Firewall logon**
group:

```text
Firewall settings                       (from the help; layout not recorded)
Connect method:      (one of the ten methods in the table below)
Firewall logon
  Host name:  [                         ]
  User name:  [                         ]
  Password:   [                         ]
```

- The help describes **one global** definition in `wcx_ftp.ini [firewall]`, shared by all connections. The 11.58 dialogs
  show a selector `[Define new... ▾] [Change...]` beside _Use firewall_, which suggests named definitions (§16). Which
  control opens the settings dialog was not recorded.
- **Keys:** `host=` (with `:port`, e.g. `firewall.mycompany.com:1021`; help default `localhost:80`), `username=`,
  `password=`, `Method=` (index in the dialog order below; whether it counts from 0 or 1 is not documented, the help's
  example is `Method=1`), `default=` (§3), and `httphost=`, `httpuser=`, `httppass=` for the separate proxy used by
  **HTTP** downloads.
- Many firewalls need no user name and password. If the firewall password is empty, TC asks for it when connecting.

| #   | Method (dialog caption)                                         | Logon sequence / notes                                                                                                                                                                                                                                     |
| --- | --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Send command USER user@hostname                                 | Connect to the proxy, send `USER <user>@<target host>`. Leave the firewall user and password **empty**. Wingate style.                                                                                                                                     |
| 2   | Send command SITE (with logon)                                  | Send the firewall user and password first (if given), then `SITE <target host>`. A firewall login is usually needed.                                                                                                                                       |
| 3   | Send command OPEN                                               | Firewall user and password first (if given), then `OPEN <target host>`. The login is sometimes not needed.                                                                                                                                                 |
| 4   | USER user@firewalluser@hostname / PASS pass@firewallpass        | Two commands carry both credential sets                                                                                                                                                                                                                    |
| 5   | Transparent                                                     | `USER`/`PASS` with the firewall credentials, then `USER`/`PASS` with the target credentials                                                                                                                                                                |
| 6   | HTTP Proxy with FTP support                                     | Browser-style `GET ftp://…` through an HTTP proxy. The returned HTML listing follows no standard; the major proxies are supported. The listing is stripped of HTML before parsing. The **transfer mode cannot be set**; the proxy chooses it by MIME type. |
| 7   | SOCKS4                                                          | Usually a user id but no password; an identd server may be needed; domain names need DNS on the local network                                                                                                                                              |
| 8   | SOCKS5 (basic authentication)                                   | User and password; GSSAPI is not supported                                                                                                                                                                                                                 |
| 9   | USER user@hostname firewalluser / PASS pass / ACCT firewallpass | Three commands                                                                                                                                                                                                                                             |
| 10  | HTTP CONNECT                                                    | Tunnels FTP through an HTTP/1.1 proxy that supports `CONNECT`. All FTP commands work, including delete and mkdir, so it is **preferred** over #6. **Only passive mode.**                                                                                   |

_Basis: observed on Windows 11 (SSL/TLS behaviour, Advanced defaults) and under Wine (layout, encoding list); help:
dlg_connectdetails, dialog_box__firewall_settings, wcx_ftp_ini_settings; change log._

## 6. Connecting

### 6.1 Login sequence

```text
connect(session):
  sock = tcp_connect(host, port or 21, via firewall method if firewall=1)   # §5.5
     on "server busy": retry up to ConnectRetries (default 10) times, WaitDelay (default 5) s apart
  if implicit TLS: tls_handshake()                     # ftpis:// or SpecialFlags & 1
  read greeting
  if explicit TLS: send AUTH TLS; tls_handshake()      # ftpes://, ftps://, SpecialFlags 2/4/8
  USER / PASS                                          # OTP challenge (MD4/MD5/SHA1): response computed
                                                       #   from the plain password automatically
  [ACCT acct]                                          # if required
  unless PreventFEAT: FEAT -> features (MLSD, MDTM, MFMT, XCRC, XMD5, MD5, XSHA1, ...)
  if Encoding == auto: OPTS UTF8 ON -> confirmed => UTF-8, else the client's ANSI code page
  SYST -> may carry "CP:<n>" (e.g. "UNIX Type: L8 , CP:1252")
  send InitCommands split at ';' (';;' -> literal ';')   # not in background threads if SpecialFlags & 256
  if directory: CWD directory
  if localdir: other panel -> localdir
  list = (useMLSD ? "MLSD" : "LIST") + (showHidden ? " -la" : "")
  parse listing (MLSD standard, else auto-detect or server-type template)
```

- The order of `FEAT`, `OPTS UTF8 ON` and `SYST` is not documented; only the existence of each step is.
- **Send Commands escape rule:** `CWD /test/a;;b;;c;PWD` sends `CWD /test/a;b;c` and then `PWD`.
- **Retries:** `ConnectRetries` (Configuration › _Number of times to retry if FTP server busy_; 0 = off) and `WaitDelay`
  (_Delay between retries_). The Configuration help applies them to anonymous and user/password logins, the INI help to
  anonymous logins only (§16).
- **OTP:** for servers with OTP authentication (MD4, MD5 or SHA1), the user enters the plain password and TC sends the
  correct response.
- With `ftpes://`/`ftpis://` or `SpecialFlags` 1/2 the TLS variant is forced (§9.3).

### 6.2 The "Connect" window

A **resizable** window titled **"Connect"** logs each connection, with an [Abort] button. Each connection starts with a
header block, followed by the server dialogue:

```text
┌ Connect ───────────────────────────────────────────────┐
│ ----------                                             │
│ Connect to: (10/11/2026 12:45:05)                      │
│ hostname=127.0.0.1:2121                                │
│ username=anonymous                                     │
│ startdir=                                              │
│ 127.0.0.1=127.0.0.1                                    │
│ (server dialogue …)                                    │
│                                              [ Abort ] │
└────────────────────────────────────────────────────────┘
```

With TLS the dialogue begins:

```text
Using sChannel (Secur32.dll) for SSL/TLS connection.
AUTH TLS
234 AUTH TLS successful.
Client handshake...
```

### 6.3 Connection errors

| Situation                 | Result                                                                                                                                                                             |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Server not running        | Box titled "ftp", warning icon: "Connect call failed!" [OK]                                                                                                                        |
| TLS handshake fails       | "Connect failed!" [OK] (title not recorded); the log shows "Client handshake failed: -2…"                                                                                          |
| First data connection     | The Windows Defender Firewall asks "Do you want to allow public and private networks to access this app?" for Total Commander. Cancelling it did not stop the loopback connection. |
| Hanging LIST/MLSD or PASV | Esc in the Connect window cancels; when both hang it must be pressed twice (change log)                                                                                            |
| Server busy               | Retries as in §6.1                                                                                                                                                                 |

_Basis: observed on Windows 11; help: dlg_connectdetails, ftp_menu, dlg_configftp, wcx_ftp_ini_settings; change log._

## 7. The connected panel

### 7.1 Panel display

| Element                     | Shows                                                                                                 |
| --------------------------- | ----------------------------------------------------------------------------------------------------- |
| Drive combo                 | A globe icon and the connection number, `0` for the first connection                                  |
| Drive line                  | `ftp://127.0.0.1:2121`, or `ftps://127.0.0.1:2122` for a TLS connection                               |
| Path bar                    | Connection number, colon, server path with `/`: `0:/*.*` at the server root, `0:/pub/*.*` in a folder |
| Command-line prompt         | `0:/pub/>`                                                                                            |
| File list                   | Name, Ext, Size and Date (MLSD times converted to local time); the Attr column shows `----`           |
| Drive button bar (if shown) | A number `0`…`9` beside a network icon (help)                                                         |
| Above the panels            | The FTP toolbar (§7.2)                                                                                |

### 7.2 FTP toolbar

While a connection is open, a full-width bar appears **above the panels**. Its parts, in order:

```text
[🔒] FTP   Transfer mode [Binary (archives, doc etc.)  ▾]   [ Disconnect ]   ┌ Waiting for server...   ┐
                                                                             └ 226 Transfer complete.  ┘
```

- The lock 🔒 appears only on a TLS connection. With an invalid certificate it is a **red open lock** (§9.2).
- **Transfer mode** offers Automatic · Binary (archives, doc etc.) · Text (plain text, html, etc.); it starts with the
  Configuration default (§8.5).
- **[Disconnect]** disconnects (§11).
- The box on the right is a two-line, scrollable **log list** with the last server lines, the same messages as the
  Connect window, e.g. "Copied (10/11/2026 12:49:42): ftp://127.0.0.1:2121/pub/report_01.txt ->
  C:\Users\<user>\AppData\Local\Temp\_tc\report_01.txt 300 bytes, 17 kbytes/s". Lines from background transfers start
  with **"BG:"**.
- The bar is drawn with the XP theme background unless `XPthemeBg=0` and is scaled on high-DPI screens (02 › FTP
  toolbar).

### 7.3 Directory cache and refresh

- Every listing read in a session is cached.
- `CacheDirs=1` (_Remember contents of all visited directories (in cache)_, default): a directory is read only on the
  first visit, or when TC itself changed it.
- `CacheDirs=0`: the directory is re-read on every visit. Recommended when others upload to the server often.
- **F2** or **Ctrl+R** (`cm_RereadSource`) forces a re-read at any time, e.g. after another user or a background thread
  uploaded something.

### 7.4 Listing: MLSD or LIST, hidden files, raw listing

**MLSD** is preferred where possible:

- a standardised, machine-readable format;
- timestamps **in UTC** with 1-second resolution, shown in the user's time zone (the panel showed local times while the
  raw lines were UTC);
- server-type templates (§7.5) are **not used** with MLSD, and the Define server type dialog is never shown.

**Tri-state per site** (`[<site>] MLSD`; global default `[General] MLSD=-1`):

| Checkbox       | Value | Rule                                                        |
| -------------- | ----- | ----------------------------------------------------------- |
| Grey (default) | -1    | MLSD if `FEAT` reports it, otherwise LIST                   |
| Ticked         | 1     | MLSD even when it is not reported, or when FEAT is disabled |
| Unticked       | 0     | Always LIST (as in old TC versions)                         |

- `PreventFEAT=1` never sends `FEAT`, because some proxies hang on it. In auto mode MLSD then cannot be detected
  (inferred).
- Some old servers report symbolic links as plain files or directories under MLSD. Synchronize dirs then cannot skip
  them and may loop; turn MLSD off for such a connection (09 › Synchronizing with FTP).

**FTP Show Hidden Files** (`cm_FtpHiddenFiles`) is a toggle with a check mark. While on, TC requests the listing with
**`LIST -la`**, which shows Unix dot-files. `SpecialFlags` 512 also sends `MLSD -la`, which most servers do not support.
The state at start-up comes from `FtpShowHidden=0/1`. As a command it takes `0` or nothing (toggle), `1` (on) and `-1`
or `2` (off) (17 › Tri-state commands).

**Raw listing:** **Alt+Enter** on the FTP panel opens Lister on the raw directory listing, read from a temporary file
such as `%TEMP%\FTP2A7A.tmp`. From an MLSD server the lines are MLSD facts with UTC times:

```text
modify=20261011035043;perm=eldfmMTcp;size=4096;type=dir; docs
```

This is also the way to inspect an unsupported LIST format before defining a server type.

### 7.5 User-defined server types (LIST parser)

**Workflow:**

1. In the connection details set _Server type_ = **Define new type (for exotic servers)** and connect, ideally to a
   directory with many files and folders.
2. The **Define server type** dialog appears (help only; layout not recorded). It holds:
   - **Definition string:** the template used to parse the raw listing;
   - **Raw directory data from the server:** the listing of the current remote directory (through an HTTP proxy it is
     pre-stripped of HTML); if it holds nothing useful, disconnect and set a different Remote Dir;
   - **Additional definition strings (optional, for very complex servers);**
   - **Interpreted data for selected line of raw data:** the fields parsed from the raw line under the cursor, to check
     the template on every line;
   - **Load existing type...**, **OK**, **Cancel**.
3. **OK** binds the type to the connection (`hosttype=<TypeName>`) and asks to save the definition if the string
   changed. Types are stored as `[<TypeName>] Template1=…, Template2=…` (e.g. `[Unix1]`, `[ServerType1]`).
4. **Cancel** saves nothing; the connection uses automatic mode.
5. **Load existing type...** loads stored strings or imports a section from another INI file. To make a shareable
   template, copy the type section out of `wcx_ftp.ini` into a separate file; in the connection details this is _Server
   type › Import from file..._. Example section: `[Unix1]` /
   `Template1=pppppppppp                     !S* TTT DD UUUUU n*`.

**Definition language.** The string is **position-based**: each character matches one column of the listing line, unless
a variable-length operator is used. **Upper and lower case matter.**

| Char             | Field / action                                                                                                                                                         |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `n`              | File name; the number of `n`s is the width (`nnnnnnnn` = 8 characters); see `*`                                                                                        |
| `v`              | VMS name `name.ext;1` / `dirname.dir;1`                                                                                                                                |
| `.`              | Trim trailing spaces from the name so far, add a dot, continue the name (e.g. `nnnnnnnn.nnn`)                                                                          |
| `D`              | Day                                                                                                                                                                    |
| `M`              | Month (number)                                                                                                                                                         |
| `TTT`            | Three-letter month name (English, German and French recognised)                                                                                                        |
| `TTT=<36 chars>` | Custom month names, 12 × 3 letters in a row, e.g. Polish `stylutmarkwimajczelipsiewrzpa¥lisgru`                                                                        |
| `UUUUU`          | Unix year-or-time field (`2000` and a space, or `20:30`, in the same place)                                                                                            |
| `Y`              | Year                                                                                                                                                                   |
| `h`              | Hour                                                                                                                                                                   |
| `H`              | AM/PM letter (`a` / `p`)                                                                                                                                               |
| `m`              | Minute                                                                                                                                                                 |
| `s`              | Second                                                                                                                                                                 |
| `S`              | Size; thousands separators (commas) are skipped                                                                                                                        |
| `S=<n>`          | Size multiplied by n (e.g. `S=1024` for block counts)                                                                                                                  |
| `p`              | Unix permission string (`-rwxrwxrwx`)                                                                                                                                  |
| `d`              | Directory flag: a directory if this character is `D` or `d` (as in `<DIR>` or `[DIR]`)                                                                                 |
| `d=<c>`          | Directory flag: a directory if the character here is `<c>`                                                                                                             |
| `*`              | After a numeric field: all digits up to the first non-digit. After a name **not** at the end: up to the next space. After a name **at** the end: the rest of the line. |
| `!`              | Skip to the first space (or end of line)                                                                                                                               |
| `!=<x>`          | Skip to the first `<x>`, which is consumed too (or to end of line)                                                                                                     |
| `$`              | Skip spaces and tabs up to the next character (or end of line)                                                                                                         |
| `\`              | The record continues on the next line (max. 2 lines)                                                                                                                   |
| space            | Ignore one character. **Not allowed as the first character**, because Windows strips leading spaces from INI values.                                                   |
| `-`              | Ignore one character; use it at the start instead of a space                                                                                                           |
| `x`              | Exactly one space must be here, or the **whole line is ignored** (filters header/footer lines such as free-space lines)                                                |
| `x=<c>`          | Exactly `<c>` must be here, or the line is ignored (routes lines to another template)                                                                                  |
| `X`              | Any character except a space must be here, or the line is ignored                                                                                                      |
| `X=<c>`          | Any character except `<c>` must be here, or the line is ignored                                                                                                        |

**Several templates:** each line is parsed with every template and the one with the **fewest errors** wins. With a
**single** template up to **2 errors** per line are tolerated; a missing size on a directory line is 1 error. How errors
are counted is not specified further; a missing or unparsable field counts as one (inferred from the samples).

**Samples** (shapes paraphrased, definition strings verbatim):

| Server           | Listing shape                                                                 | Template(s)                                                                           | Point                                                                           |
| ---------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| AIX Unix         | `-rw-rw-r--   1 dso posgroup 2913 Mar 25 1999 .Xdefaults`                     | `pppppppppp                     !S* TTT DD UUUUU n*`                                  | `!` skips owner and group of varying width; better than fixed `SSSSSSS` columns |
| PC-NFSD          | `prog1    exe     2,563,136 06-10-99  10:00a` / `temp  <dir>  01-27-97 3:41p` | `nnnnnnnn.nnn  dSSSSSSSSSSS MM DD YY  hh mmH`                                         | `.` joins name and extension; directories give 1 error (no size), tolerated     |
| VOS (Stratus)    | file and directory lines with different layouts                               | `-   SSSSS            YY MM DD hh mm ss  n*` and `- d=  SSSSS  YY MM DD hh mm ss  n*` | Two templates, one per line kind; `d=m` marks directory lines                   |
| Unisys Clearpath | long names wrap onto a second line                                            | `nnnn…n  SSSSSSSSS MM DD YYYY hh mm` and `n*\x  …  SSSSSSSSS MM DD YYYY hh mm`        | `\` joins two physical lines                                                    |

### 7.6 File-name encoding

`Encoding=` per site (caption list in §5.2):

| Value | Meaning                                                                          |
| ----- | -------------------------------------------------------------------------------- |
| -1    | Auto-detect                                                                      |
| 0     | ANSI default code page                                                           |
| 1     | ASCII/OEM default code page                                                      |
| 65001 | UTF-8                                                                            |
| other | A `MultiByteToWideChar` code page number; _Other_ lets the user enter any number |

**Auto:** send `OPTS UTF8 ON`; if the server confirms, use UTF-8, otherwise the client's ANSI code page. A `CP:<n>` tag
in the `SYST` reply (e.g. `UNIX Type: L8 , CP:1252`) is also honoured. Choose a code page by hand when accents appear
wrong.

`SpecialFlags` 2048 doubles every byte 0xFF, for servers that expect Telnet-style escaping.

### 7.7 Commands typed on the command line

When the active panel shows an FTP connection, a line typed in the command line is **sent to the server**:

- `GET`, `PUT`, `RETR` and `STOR` are intercepted and run by TC itself as transfers;
- `HELP` lists the supported commands;
- `cd …` in **lower case** is translated into the FTP directory change;
- `CD …` in **upper case** is TC's own `cd`, e.g. to leave for a local path.

### 7.8 File operations on the server

| Action            | Behaviour                                                                                                                                   |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| F7                | The normal "New folder (directory)" dialog (07 › New folder (F7, Shift+F7)); the folder is created with `MKD`                               |
| Shift+F6          | In-place rename on the server (`RNFR` / `RNTO`)                                                                                             |
| Shift+F5          | Copy within the same directory                                                                                                              |
| F8                | The delete question below                                                                                                                   |
| Change attributes | The _Change UNIX attributes_ dialog, which sends `SITE chmod` (07 › Change UNIX attributes (FTP))                                           |
| F3                | Downloads the file to `%TEMP%\_tc\` and opens it in Lister                                                                                  |
| F4                | Edits a temporary local copy and re-uploads it (§7.9)                                                                                       |
| Shift+F4          | Creates an empty file in TEMP, edits it, then asks to upload it; multi-create is not available (10 › Archives, FTP and file-system plugins) |
| File comments     | Not available on FTP (07 › File comments (Ctrl+Z))                                                                                          |

```text
ftp
(?)  Do you really want to delete the selected directory
     renamed_on_ftp?
[ ] Delete in background (separate thread)
                    [ Yes ] [ No ]
```

The FTP delete question has only [Yes] [No], where the local question has [Yes] [No] [Cancel] (07 › Delete (F8, Del,
Shift+F8)).

### 7.9 Editing and viewing remote files

- F3 and F4 work on a **temporary local copy**: F3 downloads the file to `%TEMP%\_tc\<name>` and opens it in Lister; the
  toolbar log shows the "Copied (…)" line (10 › Files that are not plain local files).
- How an edited copy goes back to the server is set by `[Configuration] AutoReUpload` (default 1: ask on the first
  re-upload; 2: re-upload each time the file is saved; 0: only after the editor closes, with confirmation), described in
  10 › FTP and file-system plugins: re-upload. `EditWaitTime` (multi-document editors) is in 10 › Multi-document
  editors.
- `ReturnToReUploadDir=1` (`wcx_ftp.ini [General]`, default 0) returns the panel to the file's remote directory after an
  automatic re-upload.
- Lister's _Save as_ keeps a temporary copy; F4 inside Lister is disabled for temporary files (10 › F4 inside Lister).

_Basis: observed on Windows 11 (panel, toolbar, Alt+Enter, F3, F7, Shift+F6, F8, Show Hidden Files toggle); help:
ftp_menu, dlg_connectdetails, define_server_type, wcx_ftp_ini_settings, dlg_configedit, inisettings1; change log._

## 8. Transfers

### 8.1 Download (F5 from the FTP panel)

F5 from an FTP panel to a local panel opens a **Download** dialog, not the Copy dialog:

```text
Download to:
[c:\tc-sandbox\B\*.*                                  ▾] [+ F7]
Only files of this type:
[                                                     ▾] [+ F8]
[ ] Download in background (separate thread)
[ ] Preserve file dates
[ ] Download later (add to download list)
                                   [ OK ] [ Cancel ]
```

- For one file the target is `<dir>\<name>`.
- The three checkboxes are **remembered** for the next download.
- **File dates:** without _Preserve file dates_ the file gets the **current time**; with it, the server's time is kept
  (`[default] PreserveDates`).
- _Download in background_: §8.8. _Download later_: §10.1.
- Downloading **into an archive** is refused, so that a long download is not lost if packing then fails. The other
  direction works: files unpacked from an archive go to TEMP first and are then uploaded (07 › Where each operation
  works; 08 › Unpack).
- Progress: §8.4.

### 8.2 Upload (F5 to the FTP panel)

```text
Upload->/pub
Upload as:
[*.*                                                  ▾]
Only files of this type:
[                                                     ▾] [+ F8]
[ ] Upload in background (separate thread)
[ ] Preserve file dates
[ ] Convert file names to lowercase
                                   [ OK ] [ Cancel ]
```

- The first line names the server folder (`/pub`).
- A selected **folder** is uploaded recursively: it is created on the server with its contents.
- _Preserve file dates_ and _Convert file names to lowercase_ correspond to `[default] PreserveDatesUpload` and
  `LowercaseUpload` (inferred mapping). The remote time can be kept only if the server supports a command to set it
  (§12).
- **Case of names:** when a remote file has the same name **apart from case**, the upload takes the **existing remote
  name**, so that two names never differ only in case. To change the case, delete the remote file first. For files that
  do not yet exist on the server, the name is kept or lower-cased by the option above.
- After an upload TC checks with `SIZE` that the file is complete (§8.9).

### 8.3 Target already exists and resume

Downloading onto an existing local file shows:

```text
ftp
Target already exists:
c:\tc-sandbox\B\report_01.txt
Do you want to overwrite it?
[ Overwrite ] [ Overwrite all ] [ Skip   ]
[ Cancel    ] [ Skip all      ] [ Rename ]
[ Resume    ] [ Resume all    ]
```

This is not the local Overwrite dialog (07 › Name collisions: the Overwrite dialog): it names only the target and adds
**Resume** and **Resume all**.

**Resuming a download:**

1. Select the remote file, with the partial local file in the other panel's directory, and press F5.
2. After the Download dialog, the box above offers Resume.
3. On Resume, TC first downloads the **last few bytes of the partial file** and compares them, to check that the remote
   file has not changed, then fetches the rest. Presumably this uses the FTP `REST` command, which the help does not
   name.

Not every server supports this.

**Resuming an upload:** only in **binary** mode, or in automatic mode for a binary file; the procedure mirrors the
download case. The result is **not guaranteed**: with some WarFTPd versions the resume appears to work but the file is
unusable, so check the file on the server afterwards.

### 8.4 Progress and abort

- **Progress window** of a foreground download: "Download" / "From: report_01.txt" / "To:
  c:\tc-sandbox\B\report_01.txt", a bar with %, [Pause] … (the rest of the button row was not recorded).
- In the Background Transfer Manager the overall-progress bar is not available for folder downloads from FTP (07 ›
  Background Transfer Manager).
- `cm_FtpAbort` (554) aborts the current FTP command; `cm_FtpResumeDownload` (555) resumes an aborted download (§8.3).

### 8.5 Transfer modes

Three modes: **Binary** (`I`), **Text** (`A`) and **Automatic** (`X`).

- **Default:** Configuration › FTP _Default transfer mode_ = `[General] TransferMode` (default `I`). This is the mode
  when TC starts.
- **During a session:** the toolbar's _Transfer mode_ combo (§7.2) or **Ctrl+Shift+M** (`cm_FtpSelectTransferMode`).
- **Automatic** decides per file by extension. Text extensions: `[General] Ascii=` (default `*.txt *.htm*`). The
  `ftp_menu` help says the file association decides (§16). By default the **remote** name's extension is used;
  `GetModeFromLocalFile=1` uses the **local** name's.
- **Text** mode converts line ends between Unix (LF) and Windows (CR LF).
- `WarnWrongMode=1` (default) warns when a binary file is transferred in text mode; `0` restores the old silent
  behaviour (TC 3.5x).
- Through an _HTTP proxy with FTP support_ the mode cannot be set (§5.5).

### 8.6 Active mode, passive mode and the data connection

- **Passive (PASV):** the client opens the data connection; needed behind firewalls that block incoming connections.
  Forced for HTTP CONNECT; ticked automatically with SSL/TLS (§5.1). `SpecialFlags` 1024: do **not** replace the private
  address returned by PASV with the server's address (by default TC replaces it).
- **Active (PORT):** the server connects back to the client.
  - **Port range** (`PortFrom`, `PortTo`; Configuration › _PORT mode: only use ports from limited range_, UI default
    10000–11000): the client listens only in that range, for firewalls opened for a range. Use ports **1024–65535**, at
    least 100 per computer and better 1000.
  - **External address** (`PortIP`, enabled by `PortIPEnabled=1`; _PORT mode: external address (IP/DNS/HTTP)_): the IPv4
    address announced in `PORT`. Needed only for routers without FTP support; it can be **counter-productive** with
    routers that rewrite PORT themselves. Three forms:
    1. a fixed IP;
    2. a DynDNS-style name;
    3. an `http://` URL of a page that returns the caller's IP as plain text, e.g. a PHP page
       `<?php print $_SERVER["REMOTE_ADDR"]; ?>`.

    The forwarded port range on the router must then also be entered as the port range above.
- `DataConnectTimeout=10`: seconds the server has to respond when a transfer is requested (maximum 300).

### 8.7 Server-to-server copy (FXP)

1. Connect both panels to servers, select the files, press F5.
2. The **left** server receives `PORT`, the **right** one `PASV`. Put a private or firewalled server in the **left**
   panel.

Not every server supports this, and firewalls may block it. `[default] ViaLocalPC=1` relays the data through the local
PC instead.

### 8.8 Background transfers

- A transfer runs in the background when _Download/Upload in background (separate thread)_ is ticked, when
  `FtpInBackground=1` (Configuration › _All uploads/downloads in background_), or when F2 is pressed in the copy dialog
  (F5 then F2). The FTP delete question has its own _Delete in background (separate thread)_.
- _Download in background_ opens a **separate** Background Transfer Manager that **closes itself** when done; the help
  also says a new window opens for every background transfer. F5–F2 adds to the **last opened** manager. The manager
  itself (queue, `+` menu with _Add URL to download_ and _Add selected items for downloading_, speed limit) is described
  in 07 › Background Transfer Manager and 07 › Adding jobs.
- Every background transfer needs **its own new connection** to the server. It can fail, e.g. when the server's user
  limit is reached; the workaround is a foreground transfer or a second TC instance.
- Log lines of background transfers start with "BG:" in the toolbar log.
- `SpecialFlags` 16 writes a detailed log for background connections; `SpecialFlags` 256 stops _Send Commands_ from
  being sent in background threads.
- The per-site keep-alive is **not** available in the Background Transfer Manager.
- The manager uses _Use passive mode by default_ when an ftps URL is added to it, e.g. with its `+` button during an
  active connection.

### 8.9 Auto-resume, size checks, keep-alive

- **Auto-resume** (`AutoResume=30`; Configuration › _Auto-resume transfer if no data received for [30] s_, ticked by
  default): when no data has arrived for N seconds, TC drops the connection, reconnects and resumes. `-1` disables it.
- **Size checks:** after an upload TC checks with `SIZE` that the file is complete (`SpecialFlags` 32 turns this off).
  After a download whose size differs from the listed size, TC checks with `SIZE` (`SpecialFlags` 64 turns this off).
- **Keep-alive:** the per-site command (§5.3); `KeepAliveTransfer=1` sends newline characters on the control connection
  **during** transfers, so that gateways do not drop it (some servers get confused; also settable per server, not in the
  BTM); `TcpKeepAlive=1` uses TCP keep-alive on all connections, for routers that drop connections often.
- **Upload buffer:** `UploadBlockSize=1` chooses the size automatically after the first 128 KB; fixed values such as
  1492 or 8192 can help on fast networks.

### 8.10 Compression (MODE Z)

| UI (Configuration › FTP)                | `ModeZ` | Effect                                                                                                                              |
| --------------------------------------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| _Compress during transfer (MODE Z)_ off | 0       | Disabled                                                                                                                            |
| on, _Not on LAN_ on (UI default)        | 1       | Compress only for Internet servers; servers on the **same subnet** or with a **private address** such as `192.168.*.*` are excluded |
| on, _Not on LAN_ off                    | 2       | Compress also on the LAN                                                                                                            |

- Used only when the server supports it; the method is ZIP-compatible (zlib).
- Strength: `ZlibRatioBin` (binary uploads) and `ZlibRatioTxt` (text), each 0–9 (0 none, 1 fastest, 9 strongest),
  default 3.
- **Cisco PIX** firewalls abort uploads compressed at strength **1**.
- A teleworker on a slow dial-up link into the company LAN should turn _Not on LAN_ off.

### 8.11 Zone identifiers on downloads

`[Configuration] WantZoneData=7` (bit sum) writes a `Zone.Identifier` stream to downloaded files:

| Bit | Source                                                                                                                                         |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Enabled: when copying or unpacking internally or via plugins, copy the `Zone.Identifier` stream from the source or archive (not for CHM files) |
| 2   | Internet http(s)                                                                                                                               |
| 4   | Anonymous ftp(s)                                                                                                                               |
| 8   | ftp(s) with login (also new connections with a user name)                                                                                      |
| 16  | Intranet http(s)                                                                                                                               |

_Basis: observed on Windows 11 (Download, Upload, target-exists box, progress, file dates, folder upload, "BG:" lines);
help: ftp_menu, dlg_configftp, dlg_connectdetails, wcx_ftp_ini_settings, sync_ftp, inisettings2, proc_copy._

## 9. SSL/TLS

### 9.1 Libraries

- On Windows versions after XP, TLS uses **sChannel** (the Windows Crypto API), so no DLLs are needed. The Connect log
  then reads "Using sChannel (Secur32.dll) for SSL/TLS connection." before `AUTH TLS`.
- OpenSSL can still be used:
  - classic `libssl.dll` (often named `ssleay.dll`) + `libeay.dll`;
  - since 10.50 **OpenSSL 3**: `libssl-3.dll` + `libcrypto-3.dll`, or for 64-bit `libssl-3-x64.dll` +
    `libcrypto-3-x64.dll`, in the **program directory**, not the `64` subdirectory.

| `PreferOpenSSL` | Behaviour                                |
| --------------- | ---------------------------------------- |
| 1 (default)     | OpenSSL if installed, otherwise sChannel |
| 0               | sChannel whenever possible               |
| -1              | OpenSSL only; never sChannel             |

When a TLS connection fails because the system does not support session reuse, the log suggests using the OpenSSL DLLs
(change log).

### 9.2 Certificates

- Trusted roots are read from the Windows stores **ROOT, CA, MY, AuthRoot**.
- Extra CA or server certificates can be put in **`wincmd.pem`** next to `wincmd.ini`. It is used only by the
  **OpenSSL** code path, never by sChannel.

| `VerifyCerts` | Behaviour                                                |
| ------------- | -------------------------------------------------------- |
| 1 (default)   | Always verify                                            |
| 0             | Never verify                                             |
| -1            | Verify only if `wincmd.pem` exists                       |
| -2            | Like -1, without the Windows store (TC ≤ 8.5x behaviour) |

**Invalid or untrusted certificate:** TC warns, unless `sslwarn=0`, and shows a **red open lock** in the toolbar in
either case. For a self-signed certificate the box was:

```text
SSL
(⚠)  The certificate was not signed by a trusted party!
     Continue anyway?
     Connected to: 127.0.0.1:2122
     SHA1 Fingerprint: A6:63:54:CB:…:53:03
     Validity: 10/11/2026 03:48:08 until 11/10/2026 03:48:08 (UTC)
     Cert subject: Common name: localhost, Organisation: tc-sandbox test
     Cert issuer: …
[ ] Always trust this server
                         [ Yes ] [ No ]
```

- Clicking the open lock trusts the server. If the certificate belongs to another name, the alias is stored as
  `[CertAlias] server.com=hostcompany.com`.
- What _Always trust this server_ writes was not recorded.

### 9.3 TLS flags

| `SpecialFlags` bit | Effect                                                                    |
| ------------------ | ------------------------------------------------------------------------- |
| 1                  | Force implicit TLS                                                        |
| 2                  | Force explicit TLS                                                        |
| 4                  | Force TLS authentication                                                  |
| 8                  | Force SSL23 authentication                                                |
| 128                | Do not reuse the TLS session for data connections (`SSL_copy_session_id`) |

**Unencrypted data channel:** put `PROT C` into _Send Commands_.

### 9.4 Client certificate

- Chosen from the Windows certificate store, imported through Control Panel › Internet Options › Content › Certificates.
  A PEM key and certificate can be converted with
  `openssl pkcs12 -export -inkey MyClient1.key -in MyClient1.pem -out MyClient1.p12`.
- Works only with sChannel (Vista and later), not with OpenSSL.

_Basis: observed on Windows 11 (sChannel log line, certificate box, toolbar lock); help: ftp_menu, dlg_connectdetails,
wcx_ftp_ini_settings; change log._

## 10. Download list and HTTP downloads

### 10.1 Download later

With _Download later (add to download list)_ ticked in the Download dialog (§8.1), OK asks for the list file and
downloads nothing:

```text
File name of download list:
[C:\Program Files\totalcmd\ftplist.txt                          ]
[ ] Save destination dir in list file
                         [ OK ] [ Tree ] [ Cancel ]
```

- The proposed file is `ftplist.txt` in the **program folder**. The last name used is `[Configuration] ListName=`,
  shared with _FTP Download From List_.
- Entries are also added with the right-click item _Add to download list_ during an FTP session (`cm_FtpAddToList`).
- An entry can be a URL to a file or to a **subdirectory**.

### 10.2 List file format

- Plain text, **ANSI** or **UTF-8 with a BOM**; other encodings do not work. When an added name contains characters
  outside the current code page, the list is converted to UTF-8 automatically (change log).
- Written lines observed: ANSI, CRLF, one entry per line, no user name for an anonymous session:

```text
ftps://127.0.0.1:2122/.hidden_on_server.txt -> c:\tc-sandbox\B\.hidden_on_server.txt
```

- A list name given without a path is looked up in the **current directory**.
- Each line is one command:

| Line                                             | Action                                                                                                        |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------- |
| `ftp://host/dir/file.zip`                        | Download into the base (target) directory                                                                     |
| `ftp://host/dir/file.zip -> c:\target\file.zip`  | Download to an absolute or relative destination; the separator is `->`                                        |
| `http(s)://…`                                    | HTTP download, the same rules                                                                                 |
| `put:c:\src\file.zip -> ftp://host/dir/file.zip` | Upload                                                                                                        |
| `copy:c:\a -> c:\b` or `c:\a -> c:\b`            | Local copy                                                                                                    |
| `move:c:\a -> c:\b`                              | Local move                                                                                                    |
| `sleep:<ms>`                                     | Pause, e.g. `sleep:1000`                                                                                      |
| `header: <Name>: <value>`                        | Extra HTTP header for the following requests, e.g. `header: Referer: http://www.source.com`                   |
| `copyflags: <x>`                                 | Overwrite flags, with the meanings of the F5 dialog's overwrite options; the codes are not listed in the help |

- Whether _Save destination dir in list file_ was ticked for that entry was not recorded; the line carries a
  destination.

### 10.3 Net › FTP Download From List

```text
File name of download list:
[<last list file used>                                  ] [>>]
                                     [ OK ] [ Cancel ]
```

- Pre-filled with the last path used (`ListName`); before any list has been used the field holds `ftplist.txt`.
- **OK** reconnected **silently** (no dialog) and downloaded the entry; the file got the **current time**. The list file
  was rewritten afterwards.
- The jobs run in the Background Transfer Manager, which picks up lines appended to the file while it runs; its _Edit
  list file_ item opens the list (07 › Adding jobs).

### 10.4 HTTP(S) downloads

- An `http://` or `https://` address in Ctrl+N, a download list or the Background Transfer Manager **downloads the
  file**; no session is opened. Where a Ctrl+N download is saved was not recorded.
- **Protocol** (`ForceHTTP11`): `0` (default) HTTP/1.0, except HTTP/1.1 for **resumed** downloads; `1` always HTTP/1.1.
  With 1.1 the server may send dynamic pages **chunked**, without a total size, so no progress bar is possible, but the
  data starts arriving sooner.
- `Httptimeout=30`: seconds to wait for the web server's response.
- `UserAgent=` overrides the default `Mozilla/4.0 (compatible; Totalcmd; Windows <ver>)`.
- Proxy: `[firewall] httphost`, `httpuser`, `httppass` (§5.5).
- Zone identifiers: §8.11.

_Basis: observed on Windows 11 (Download later, list line, Download From List); help: ftp_menu, inisettings1,
inisettings2, wcx_ftp_ini_settings, dlg_newconnection; change log._

## 11. Disconnecting and session summary

### 11.1 Disconnecting

- **Ctrl+Shift+F** (`cm_FtpDisconnect`), Net › _FTP Disconnect_ or the toolbar's [Disconnect]. The same command also
  closes PORT connections and file-system plugins that have a Disconnect function.
- After disconnecting, the panel returns to the **last local directory**.
- A **quick-connect** session (Ctrl+N) first asks, while `SaveNewConnection=1` (default):

```text
ftp
Current session not saved, save?
            [ Yes ] [ No ] [ Cancel ]
```

- **Yes** opens "FTP: connection details" (§5) pre-filled: Host = the server, User name `anonymous` (for an anonymous
  session), Remote Dir = the current server folder (`/pub`), Session empty.
- A **saved** session disconnects without asking.
- `[Configuration] DisconnectOnSuspend` (bit sum, default 0): `1` disconnects all FTP connections when the PC suspends,
  `2` all file-system plugins with a Disconnect function.

### 11.2 Session state changes at a glance

| Operation                         | Result                                                                                 |
| --------------------------------- | -------------------------------------------------------------------------------------- |
| Ctrl+N, OK (anonymous)            | E-mail prompt (once), Connect window, panel shows `0:/*.*`, FTP toolbar appears        |
| F3 on a server file               | Copy in `%TEMP%\_tc\`, opened in Lister                                                |
| Alt+Enter                         | Raw listing in Lister from `%TEMP%\FTP….tmp`                                           |
| F5 download                       | Download dialog; the file gets the current time unless _Preserve file dates_ is ticked |
| F5 download onto an existing file | "Target already exists" box with Resume / Resume all                                   |
| F5 upload of a folder             | The folder is created on the server, recursively                                       |
| F7 / Shift+F6 / F8                | `MKD` / `RNFR`+`RNTO` / delete after the "ftp" question                                |
| _Download later_                  | Entry written to the list file, nothing downloaded                                     |
| Download From List                | Silent reconnect, download, list file rewritten                                        |
| Disconnect, quick-connect session | "Current session not saved, save?"; panel back to the last local directory             |
| Disconnect, saved session         | No prompt; panel back to the last local directory                                      |

_Basis: observed on Windows 11; help: ftp_menu, wcx_ftp_ini_settings, inisettings1; KEYBOARD.TXT._

## 12. Synchronize with an FTP server

Synchronize dirs between a local directory and an FTP panel — the first-use warning "Synchronize with FTP:", the **FTP
time offset** group `dT= [0] h  [x] mdtm  [x] utc`, the greyed _by content_ option, the rule that changes local
timestamps after uploads, the case and CR LF rules and _Set local file date to remote date_ — is described in **09 ›
Synchronizing with FTP**. The client settings it relies on:

- **Setting the remote time:** `MDTM=3` (bit 1 enable, bit 2 send UTC); currently used **only** by Synchronize.
  `SpecialFlags` picks the command: 4096 = `MDTM`, 8192 = `MFMT`, 12288 = `SITE UTIME`.
- `SyncAllowChangeLocalTime=1` allows Synchronize to set the local time after an upload when the server cannot set
  times.
- `[TimeZone] <site>=<hours>` stores the time offset, keyed by server name.
- Compare by content over FTP is possible only if the server announces `XCRC`, `XMD5`, `MD5` or `XSHA1` in `FEAT`.
- `[default] PreserveDates` / `PreserveDatesUpload` keep times on ordinary (non-sync) transfers where possible (§8.1,
  §8.2).

_Basis: observed on Windows 11 (09 › Synchronizing with FTP); help: sync_ftp, synchronize_mlsd, wcx_ftp_ini_settings._

## 13. Logging, configuration effects and storage

### 13.1 Logging

- Configuration › FTP _Create a log file_ (`LogFile=`; the UI proposes `%TEMP%\tcftp.log`) **appends** the messages of
  the log list (the Connect window and the toolbar log, §6.2, §7.2) to that file.
- `LogFile2=` writes a reduced log with only the important data, such as the files transferred.
- `SpecialFlags` 16 adds a detailed log for background connections.
- FTP logging is separate from the file-operation log of Configuration › Log file (13 › Operation › Log file).

### 13.2 Effects of Configuration › FTP

The page itself is in 13 › Operation › FTP. Each option, with its key in `wcx_ftp.ini [General]` unless noted:

| Option                                         | UI default                  | Key                       | Effect                                                                                                              |
| ---------------------------------------------- | --------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Number of times to retry if FTP server busy    | 10                          | `ConnectRetries`          | Connection retries on a busy server; 0 = none (§6.1)                                                                |
| Delay between retries (seconds)                | 5                           | `WaitDelay`               | Wait before each retry                                                                                              |
| Default transfer mode                          | Binary (archives, doc etc.) | `TransferMode=I`          | Mode at start-up (§8.5)                                                                                             |
| Open new connections                           | in the active panel         | `FtpOpenIn=0`             | in the active / left / right / target panel (§2.1)                                                                  |
| Create a log file                              | off, `%TEMP%\tcftp.log`     | `LogFile`                 | §13.1                                                                                                               |
| All uploads/downloads in background            | off                         | `FtpInBackground=0`       | New transfers start in the background (§8.8)                                                                        |
| Use passive mode by default                    | off                         | `[default] pasvmode=0`    | Passive mode for new connections; updated when a connection is configured; used by the BTM for ftps URLs (§3, §8.8) |
| PORT mode: only use ports from limited range   | off, 10000–11000            | `PortFrom`, `PortTo`      | §8.6                                                                                                                |
| PORT mode: external address (IP/DNS/HTTP)      | off, empty                  | `PortIPEnabled`, `PortIP` | §8.6                                                                                                                |
| Compress during transfer (MODE Z) / Not on LAN | both ticked                 | `ModeZ=1`                 | §8.10                                                                                                               |
| Auto-resume transfer if no data received for   | ticked, 30 s                | `AutoResume=30`           | §8.9                                                                                                                |

### 13.3 Where FTP settings are stored

- `wcx_ftp.ini` holds **all** FTP client settings: options, connections, the Ctrl+N history, the firewall, server types,
  time offsets, certificate aliases, the master-password verifier and plugin passwords protected by the master password.
  `wincmd.ini` holds everything else, including the FTP-related `[Configuration]` keys named in this chapter
  (`AutoReUpload`, `EditWaitTime`, `ListName`, `DisconnectOnSuspend`, `UseWindowsHello`, `Wsock32`, `WantZoneData`,
  `RestrictInterface`).
- Sections: `[General]`, `[default]`, `[firewall]`, `[connections]`, `[OldConnections]`, one `[<site>]` per connection,
  `[<ServerType>]`, `[TimeZone]`, `[CertAlias]`, `[|empty_folders|]`, `[|FSPlugin|<Plugin>]`. The full key reference is
  in 19 › `wcx_ftp.ini`; the list-file grammar in 19 › Download list (`ftplist.txt`).
- Location: next to `wincmd.ini` by default (in a standard installation `%APPDATA%\GHISLER`), changeable with the `/F=`
  switch, the registry value `FtpIniName` or `[Configuration] UseIniInProgramDir` bit 2 (19 › How the location of
  `wincmd.ini` and `wcx_ftp.ini` is chosen). Redirection keys (`RedirectSection`) are **ignored** inside `wcx_ftp.ini`.
- Since 10.50, if `wincmd.ini` is missing at start-up, `ftptemplate.txt` from the program directory is copied to
  `wcx_ftp.ini` (and `maintemplate.txt` to `wincmd.ini`).
- _Change Settings Files Directly_ opens `wcx_ftp.ini` together with `wincmd.ini` (19 › Save Position, Save Settings,
  Change Settings Files Directly).

### 13.4 `SpecialFlags` bit index

`[General] SpecialFlags` (default 0) is a bit sum; a per-site `SpecialFlags` takes precedence.

| Bit   | Effect                                            | Section |
| ----- | ------------------------------------------------- | ------- |
| 1     | Force implicit TLS                                | §9.3    |
| 2     | Force explicit TLS                                | §9.3    |
| 4     | Force TLS authentication                          | §9.3    |
| 8     | Force SSL23 authentication                        | §9.3    |
| 16    | Detailed log for background connections           | §8.8    |
| 32    | No `SIZE` check after upload                      | §8.9    |
| 64    | No `SIZE` check after a size mismatch on download | §8.9    |
| 128   | No TLS session reuse on data connections          | §9.3    |
| 256   | No _Send Commands_ in background threads          | §8.8    |
| 512   | Send `MLSD -la` for hidden files                  | §7.4    |
| 1024  | Keep the private address returned by PASV         | §8.6    |
| 2048  | Double every byte 0xFF                            | §7.6    |
| 4096  | Set the remote time with `MDTM`                   | §12     |
| 8192  | Set the remote time with `MFMT`                   | §12     |
| 12288 | Set the remote time with `SITE UTIME`             | §12     |

_Basis: observed on Windows 11 (settings folder) and under Wine (Configuration › FTP defaults); help: dlg_configftp,
wcx_ftp_ini_settings, inisettings, inisettings1, inisettings2._

## 14. Windows network functions

### 14.1 UNC paths and servers

- `cd \\localhost\c$\tc-sandbox\B` on the command line opens a UNC path directly. The drive combo shows the network icon
  and `\`; the prompt reads `\\localhost\c$\tc-sandbox\B>`.
- **Backspace** at a share root goes up to the server, `\\localhost\*.*`, which lists the server's shares.
  Administrative and hidden shares are not listed there (with only `C$` on the test machine the list showed nothing but
  `[..]`) until _Show Admin Shares_ (§14.6).
- `cd \\server\share /user:username` (lower-case `/user:`) connects to a share as the given user; without a name TC asks
  for user name and password (14 › The command language).
- `[Configuration] PromptForUser`: `0` (default) connects network drives with `CONNECT_INTERACTIVE` only; `1` also with
  `CONNECT_PROMPT`, so the user is always asked.
- `UseShellConnect`: `1` uses the old shell method to connect shares (workaround for VINES); `-1` shows separate user
  and password dialogs (workaround for a crash with an NVIDIA driver).
- `NetwareBugfix=1` does not rename files on remote drives.
- Copying names with their UNC path is a clipboard command (07 › Names to the clipboard (Mark menu)).
  `ThreadFindFirst=1` reads directories in a separate thread, so that reading a hanging network path can be aborted (19
  › Drives, drive bar, devices).

### 14.2 Network Neighborhood

- Reached through the drive list entry `\  Network Neighborhood` (Alt+F1/Alt+F2 › `\`), the `\` drive button, or
  `cm_OpenNetwork`. Path: `\\Network\*.*`.
- Entries observed:
  - one folder per installed file-system plugin, e.g. `[Registry]` and `[Secure FTP]`, with their own icons and `<DIR>`
    (using them: 15 › File-system plugins in use);
  - `[Network (WORKGROUP)]`, the Windows network;
  - `<Refresh>`, shown with `<lnk>`.
- `NetHoodInThread=1` loads Network Neighborhood in a background thread. `NetHoodStyle`: `0` as Windows provides it, `1`
  (default) also an XP-style "Workgroup" subfolder, `2` only XP style. `NetHoodReadInfo` (sum: `1` GetAttributesOf, `2`
  SHGetDataFromIDList) chooses the shell functions called.
- In drive-letter sets of the configuration (`Allowed`, `NoReread`, `CopyCompatDrives`, `DriveBarHide`) the character
  `\` stands for Network Neighborhood (19 › Drives, drive bar, devices; 19 › Network Neighborhood and network
  connections).

### 14.3 Map a network drive (Net › Network Connections...)

Opens the network's own "connect drive" dialog, which is not part of TC. On Windows 11 it is the **"Map Network Drive"**
wizard:

```text
Drive:   [Z:                     ▾]
Folder:  [                       ▾] [ Browse... ]
         Example: \\server\share
[x] Reconnect at sign-in
[ ] Connect using different credentials
Connect to a Web site…                                    (link)
                                        [ Finish ] [ Cancel ]
```

- After mapping `\\localhost\c$\tc-sandbox` to `Z:`, the active panel switched to `z:\` at once.
- The drive list then shows `z  \\localhost\c$\tc-sandbox` with a network-drive icon. A drive that is not connected yet
  shows `(X)` before its path (03 › Drive combo box).
- A mapped drive behaves like a local drive; e.g. Space on a folder computed its size (`1,071,569`).

### 14.4 Disconnect network drives (Net › Disconnect Network Drives...)

Opens the network's own disconnect dialog. On Windows 11 it is the **"Disconnect Network Drives"** list: one line per
mapped drive, e.g. "tc-sandbox (\\localhost\c$) (Z:)", with a free-space bar, [OK] [Cancel]. OK removed `Z:`. Some
networks disconnect through the connect dialog instead.

### 14.5 Share and unshare

- **Share Current Directory...** on Windows 11 opens the Windows **Properties** sheet of the current folder, General tab
  first. Its Sharing tab shows "Not Shared", [Share...] and [Advanced Sharing...]. (The help describes sharing the
  directory **under the cursor**, as in Explorer; whether the cursor folder is used when one is under the cursor was not
  recorded.)
- **Unshare Directory...** (help only): stops sharing the directory under the cursor.
- The help describes both items as made for Windows for Workgroups and NT 3.51; on current Windows the same function is
  in the Properties sheet (Alt+Enter). To share a root such as `c:\`, use tree view. Shared folders get a hand overlay.

### 14.6 Show admin shares

- `cm_AdministerServer` lists administrative shares such as `C$` on a server. At `\\localhost\*.*` it showed `[ADMIN$]`,
  `[C$]` and `[IPC$]`.
- Normally the target machine's administrator password is required. A Win9x/ME target needs remote administration
  enabled in its Control Panel.
- `[Configuration] AdminShares=1` always shows administrative shares (NT-based systems). `AllHiddenNetNames=1` (default)
  shows all hidden shares, `0` only drive shares like `C$`.

### 14.7 System information

System Information › Network shows the primary and secondary network and, for Microsoft networks, user name, computer
name, workgroup and comment ("No network installed" for networks not directly supported by Windows); see 12 › System
Information.

_Basis: observed on Windows 11 (UNC, Network Neighborhood, map/disconnect, Share, admin shares; network kept to the VM's
own shares); help: options_connectnet, options_disconnectnet, options_share, options_unshare, show_admin_shares,
dlg_network, inisettings1, inisettings2._

## 15. PORT connection (USB or parallel cable)

### 15.1 Model

Net › **PORT Connection To Other PC...** (`cm_DirectCableConnect`) on both PCs shows:

```text
PORT
Should this machine be the client or the server?
Explanation: One machine is the client and one the server.
The client is the machine on which you work.
          [ Client ] [ Server ] [ Test ] [ Cancel ]
```

1. Start TC on both machines (one licence is enough for a single user).
2. Choose **Server** on one and **Client** on the other. The user works on the client; the server TC is **blocked** for
   the whole session.
3. If the machine has more than one usable port (parallel and/or USB), TC asks which port to use.
4. The link **works like an FTP connection**, being built on the FTP code: upload, download, delete, rename, view, edit
   and _Synchronize dirs_ work; running programs on the other side does not.
5. End the session with _Disconnect_ (Ctrl+Shift+F) on the client and _Abort_ on the server.

- **Starting by command** (client only), from a button, the Start menu or the hotlist:
  `cd port://lpt1/c:/subdir1/subdir2` or `cd port://usb/c:/subdir1/subdir2`. Paths after the port **must use `/`**.
- **Starting a server from the command line:** `/S=P:<port>` with `LPT1` or `USB` starts TC as a port server (19 ›
  Switches).
- `RestrictInterface` bit 512 disables the PORT connection.

### 15.2 USB link

- Only cables sold as **"Windows Easy Transfer Cable"** work. They have a bridge device in the middle and use
  Microsoft's documented **WinUSB** driver. Cables that promise transfer without a driver use proprietary drivers and do
  **not** work. A plain USB cable does not work and can damage the ports.
- Throughput up to about 20 MB/s, depending on the PCs and the virus scanner. It is not a network; it is for copying,
  moving and synchronising.
- Any pair from **Windows XP to Windows 11**, 32- or 64-bit. XP needs a driver installed; Vista and later have it built
  in. XP x64 lacks the 32-bit `winusb.dll` that 32-bit TC needs. Older Windows versions cannot be supported.
- **Auto-start:** `TcUsbRun.exe` (run as administrator on Vista–11) registers for cable-insert notifications and, when
  the cable is plugged in, starts TC as client or server.
- `[Configuration] UsbBufSize=-1`: transfer buffer in KB; `-1` = the maximum (currently 64 KB).

### 15.3 Parallel link

- An "Interlink/Laplink" (direct cable connection) **4-bit crossed** parallel cable with 25-pin male plugs at both ends
  (the PC port has 25 holes). About 50–80 KB/s; cables up to about 5–10 m work. A plain 1:1 extension cable can
  **damage** the ports. Between two XP-or-newer PCs the USB link is much faster.
- **Minimum wiring:**

| PC A pin | PC B pin    |
| -------- | ----------- |
| 2        | 15          |
| 3        | 13          |
| 4        | 12          |
| 5        | 10          |
| 6        | 11          |
| 15       | 2           |
| 13       | 3           |
| 12       | 4           |
| 10       | 5           |
| 11       | 6           |
| 25       | 25 (ground) |

- **Safety rules:** connect the cable only with **both PCs switched off** (parallel ports are not hot-pluggable);
  discharge static electricity first; connect parallel to parallel only, never to a serial port; do not share the port
  with dongles, ZIP drives or external disks, because TC **locks the port** for the whole session.

| OS                    | Driver        | Behaviour                                                               |
| --------------------- | ------------- | ----------------------------------------------------------------------- |
| Windows 95/98/ME      | `cglpt9x.vxd` | Loaded on connect, unloaded afterwards                                  |
| Windows NT–11, 32-bit | `cglptnt.sys` | Dynamic loading needs **administrator** rights                          |
| Windows NT–11, 64-bit | `cglpt64.sys` | Dynamic loading needs **administrator** rights                          |
| Windows 3.1           | none          | Direct port access, **no locking**: do not print to that port meanwhile |

- For use from a normal account, an administrator installs the driver to load at boot with
  `Totalcmd.exe /installdriver`; `Totalcmd.exe /removedriver` removes it (also `cm_NTinstallDriver` 2301 /
  `cm_NTremoveDriver` 2302). NT-based systems only.
- `[Configuration] PortInDriver=1` (Windows 9x/ME only): `1` transfers whole blocks inside the driver (fast, but the PC
  is unusable meanwhile); `0` works in user mode. NT-based systems always use the driver.
- The driver is a "parallel port class driver" written for TC: it blocks and unblocks port access and sends single
  characters or blocks. It gives user-mode programs exclusive access to **parallel ports only**.
- **DOS server:** a standalone add-on lets a plain-DOS machine act as server; no long file names, slower. Do not run it
  in a Win9x or Win 3.1 DOS box, because it accesses the port without protection.

### 15.4 Test mode and troubleshooting

Choose **Test** on **both** PCs. Each side sends a test pattern and can judge only **its own** receive lines, so
**both** must report the cable as good.

Without a cable, [Test] opened a window titled "USB" with [Abort], then the error "Connect failed!" [OK].

| Symptom                                                         | Cause                                                                                                                                                             | Fix                                                                     |
| --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| Both sides report "the cable is good", but the connection fails | Cable too long or poorly shielded                                                                                                                                 | A shorter or better cable                                               |
| "could not load driver"                                         | Driver missing (`cglpt9x.vxd` in the TC folder, or `cglptnt.sys` / `cglpt64.sys` not installed), or the desktop "shortcut" is really a **copy** of `Totalcmd.exe` | Install the driver or get rights; replace the copy with a real shortcut |
| No reply at all                                                 | A 1:1 cable, the wrong port, the wrong LPT number, or a non-standard port                                                                                         | Check the port and LPTx; try another cable                              |
| Data arrives, but with a receive error                          | A wrong wire or a broken pin                                                                                                                                      | TC lists the lines that do not work                                     |

_Basis: observed on Windows 11 (PORT box, Test without cable) and under Wine (PORT box); help: port_connection,
usb_cable_connection, direct_cable_connection, inisettings2; inc.txt._

## 16. Open points for an implementer

Points where the help topics disagree with each other or with the observed program, with the behaviour this
specification sets for a clone:

| Topic                          | What the sources say                                                                                               | Behaviour to implement                                                                                                                                    |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `wincmd.pem`                   | _ftp_menu_ presents it as a general store for extra certificates; _dlg_connectdetails_ says sChannel never uses it | Read `wincmd.pem` only in the OpenSSL code path; sChannel uses the Windows stores ROOT, CA, MY, AuthRoot (§9.2)                                           |
| Master-password lock overlay   | _dialog_box__connect_ puts the small lock in the upper-left corner in one paragraph and the lower-right in another | Draw a small lock overlay on entries whose password is protected; the corner is a free choice (not recorded)                                              |
| Busy-server retries            | Configuration › FTP applies the retry count to all logins; the INI help to anonymous logins only                   | Retry `ConnectRetries` times, `WaitDelay` s apart, for every busy-server login (§6.1)                                                                     |
| Firewall definitions           | The help describes one global `[firewall]` definition; 11.58 shows a `[Define new... ▾] [Change...]` selector      | Use the global `[firewall]` definition for every connection with `firewall=1` (§5.5); how the 11.58 selector stores several definitions is not documented |
| Session order in Ctrl+F        | Help: alphabetical; observed: creation order                                                                       | List entries in `[connections]` order (creation order as observed, §4.1)                                                                                  |
| Automatic transfer mode        | _dlg_configftp_: by extension; _ftp_menu_: by file association                                                     | Decide by the `Ascii=` extension list, remote name by default (§8.5)                                                                                      |
| `PreferIPv6` library name      | The help writes "wsock2_32.dll"                                                                                    | `wsock32.dll` for -1, the Windows library `ws2_32.dll` for every other value (§2.4)                                                                       |
| Share Current Directory        | Menu caption: current directory; help: directory under the cursor                                                  | Open the shell Properties sheet of the current folder, as observed (§14.5)                                                                                |
| `[firewall] Method=`           | Not stated whether the index counts from 0 or 1                                                                    | Store the position in the dialog's method list; the base is not documented                                                                                |
| `copyflags:` in download lists | Codes not listed                                                                                                   | Accept the line; map the value to the F5 overwrite modes (07 › Default overwrite mode) only once the codes are known                                      |

_Basis: help: ftp_menu, dlg_connectdetails, dialog_box__connect, dlg_configftp, dialog_box__firewall_settings,
wcx_ftp_ini_settings, options_share; observed on Windows 11._
