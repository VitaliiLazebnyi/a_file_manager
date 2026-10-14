# Total Commander on macOS: setup notes

Last updated: 2026-10-11

## Current setup

- Mac: Apple Silicon (device "mac-lan").
- Wine layer: CrossOver 26.3.0, installed via `brew install --cask crossover`. 14-day trial started 2026-10-11.
- Bottle: **TotalCommander** (Windows 10 type).
- Total Commander 11.58 x64 (unregistered), installed at `C:\Program Files\totalcmd\TOTALCMD64.EXE` (NOT `C:\totalcmd`).
- Installer: ~/Downloads/tcmd1158x64.exe (from <https://totalcommander.ch/1158/tcmd1158x64.exe>).
- Settings files: `C:\users\crossover\AppData\Roaming\GHISLER\wincmd.ini` and `wcx_ftp.ini`.
- Wine drives: Y: = Mac home folder, Z: = `/`, C: = the bottle.

## How Claude can operate it (computer use)

- Total Commander must be started in the way that gives it a Mac app identity (a CrossOver helper app). It then appears
  as **"Total Commander 64 bit"**.
  - Bundle ID seen: `com.codeweavers.CrossOverHelper.A8B2E1842C56719A1B99F4DF262FE389.BF204AC1719937E2A96ADC863F9A2DBD`
- Steps: `computer_resolve_access` with "Total Commander 64 bit", then `computer_request_access`. Ask for clipboard
  read/write too: pasting text is the reliable way to enter paths and names.
- The app grant expires after 30 minutes without computer-use activity; resolve and request access again.
- Background (app_*) clicks do NOT work in it; app_screenshot shows only the window frame. Use full-screen control
  instead (request_full_control, then screenshot / left_click / key).
- When started via CrossOver "Run Command", it runs as a nameless process (tcmd1158x64.exe / TOTALCMD64.EXE) that can't
  be granted: it's invisible to screenshots and clicks are refused.
- On each start, an unregistered-version reminder asks you to press 1, 2 or 3.
- If the Mac screen is locked (login window in front), nothing can be operated until the user unlocks it.

## Operating quirks (learned 2026-10-11 while documenting)

- **The Mac Option key is NOT forwarded as Alt.** Alt+F7 arrives as F7, and Alt+Enter arrives as Enter (which opens the
  file). Use the menus for Alt shortcuts.
- macOS keeps some combinations for itself: Ctrl+F2 and Ctrl+arrow keys don't reach TC (Ctrl+F2 needs the
  systemKeyCombos grant). Ctrl+Shift+F5 also had no effect.
- Typing through the `type` action produces garbled characters in TC edit fields. Use `computer_write_clipboard` +
  Ctrl+V for text with special characters. Single `key` presses work for letters and digits (`period`, `pagedown`,
  `BackSpace`, `shift+-` for "_"); `KP_Multiply`, `Next`, `underscore` are rejected.
- **Esc can get "stuck" for Wine.** After pressing Esc (to close a dialog or Lister), the next file operation may fail
  with "ESC is pressed - operation aborted!". Fix: `hold_key` Escape for 0.5 s while the message box is shown, then
  retry. Better: close windows with their buttons or the red close button, not Esc, before starting an operation.
- Right after a menu was closed with Esc, keystrokes may not reach the panel until it is clicked.
- Windows opened by programs that TC launches (e.g. Wine notepad.exe) are separate processes that can't be granted.
  Avoid launching them (F4, Shift+F4).
- A macOS system alert (UserNotificationCenter) can sit over the screen and block clicks in its area. It can't be
  granted; the workaround is to move TC dialogs elsewhere, or have the user dismiss it.
- Clicks must not hit the Dock or desktop; that needs a Finder grant.
- The bottle folder (`~/Library/Application Support/CrossOver/Bottles/…`) is a protected location for device folder
  access.
- Options › Refresh auto-refresh is off (that is the program default, `WatchDirs=0`), so press Ctrl+R after file
  operations.

## Sandbox for hands-on tests

- `~/tc-sandbox` (Y:\tc-sandbox in TC): A (test data), B (conflicting copies), C (archives, encoded file, corrupt zip),
  work (outputs), `_ref` (copies of help/inc/bar/ini files), `_scripts/make.py` (data generator).
- Rule used: source and target of every confirmed operation inside the sandbox; permanent delete (Shift+F8) only; no
  Directory Tree scan on Y:, no Save settings, no hotlist changes.
- The sandbox still exists; deleting it requires the user's permission.

## Windows 11 VM in Parallels (used 2026-10-11 for real-Windows tests)

- VM "Windows 11" (ARM64, Windows 11 26H2), user cm0k, no password. Total Commander 11.58 x64 installed to C:\Program
  Files\totalcmd (downloaded from totalcommander.ch inside the VM), settings in %APPDATA%\GHISLER.
- Isolation applied by Claude: VM network **Disconnected**; Mac<->Windows folder mirroring, cloud/volume sharing,
  "Access Windows folders from Mac" and printer sharing all **off**. (Re-enable in the VM's Configuration › Options ›
  Sharing and Hardware › Network if wanted.)
- Test material inside the VM only: C:\tc-sandbox (A, B, C, work, ftp, ftproot, downloads). Python 3.12 (per user) with
  pyftpdlib, a local FTP server script C:\tc-sandbox\ftp\ftpserver.py (127.0.0.1:2121 plain, :2122 TLS, anonymous) —
  runs as pythonw.exe while started.
- Official TC plugins installed per user under %APPDATA%\GHISLER\plugins (Imagine, ISO, Registry, Secure FTP, Exif); FTP
  sessions "Local test plain" and "Local test TLS" saved in wcx_ftp.ini.
- Backup of the VM's wincmd.ini before option tests: C:\tc-sandbox\work\wincmd_before_options.ini (options changed live:
  drive buttons on then off, folder brackets off + "Append \\", directories sorted like files, quick search "Letter
  only"). Restore pending if not done.
- Operating notes: Option is forwarded as Alt by Parallels; typing via the `type` action is garbled, paste via clipboard
  works; Windows "Open with" may offer "(Mac)" apps — never pick those.

## Documentation produced

- **Current: consolidated edition (2026-10-11)** in project docs `claude/tc-spec/`: README (index with "where to find
  what"), 20 chapters organised by feature (01 overview … 19 settings files and command line, 20 implementation guide)
  and appendices A (host differences: Wine artefacts, DPI-dependent values), B (investigation and test setup), C (change
  log against the first edition). About 225,000 words. Each topic is described once; every section ends with a _Basis_
  line naming its sources. Also delivered as `total-commander-11.58-spec-v2.zip` with the `translations/` folder (all 18
  bundled languages as CSV/JSON/UTF-8).
- Verified by independent checks: cross-references resolve to real headings; 04 matches WCMD_ENG.MNU item by item; 06
  covers every KEYBOARD.TXT line; 17 matches TOTALCMD.INC (594 commands); 19 holds every key of the used wincmd.ini;
  ~700 facts spot-checked against the Windows and Wine test notes and the help.
- First edition (23 layered chapters: UI 01–14, help logic 15–20, localisation 21, Wine tests 22, Windows tests 23) was
  replaced in the project; it survives only in the earlier zip `total-commander-11.58-docs.zip`.

## Known leftovers

- The CrossOver bottle may contain a broken TOTALCMD64 launcher pointing at `C:\totalcmd\...` (gives error 2). Delete it
  and keep the one pointing at Program Files.
- Parallels Desktop updated to 27.0.3 (usage analytics declined). The Windows 11 VM was later used for the real-Windows
  tests (see above).
- Homebrew's wine-stable cask is disabled. Wine itself was not installed.
- A Wine Notepad window with C:\windows\win.ini may still be open from 2026-10-11 (opened by accident, nothing edited);
  close it without saving.
- CrossOver TC panels were put back to c:\users\ and c:\.
