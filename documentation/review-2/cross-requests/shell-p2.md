# Cross-requests from the shell agent, second pass (shell-p2)

Nothing here blocks the shell: each item has a working fallback in place, named with it.

## 1. Kernel: a prepared change keeps the fresh listing and lets go of it on the main thread

File: `Sources/AFMKernel/Panels/PanelModel.swift`, `Prepared.Kind.update(Listing, focus:isSame:)` and `.show(Listing, focus:)`.
The `Listing` kept in `kind` holds the fresh items. `Prepared.deinit` hands `listed` and `shown` to `Discard`, but
not that listing: when the refresh found the folder as it was (`isSame`), `kind` is the last holder of a list as
long as the folder, and it goes where the `Prepared` goes, which is the main thread right after `apply`
(measured in the shell's benchmark before the workaround: the unchanged reload of a 1M folder cost the main
thread a release of 1M entries). Wanted: `deinit` also discards the items of the listing in `kind` (or `kind`
keeps the listing without its items).
Fallback in place: `PanelViewController.change(_:count:fresh:…)` keeps one more reference to the fresh items
until the block that applied the change has gone, and drops that one in the background.

## 2. Kernel: `show` / `showRemembered` of a long list, prepared in the background

File: `Sources/AFMKernel/Panels/PanelModel.swift`. `prepare(_:update:…)` covers a reading of the folder the panel
shows (and of its replacement, with `history: .keep`, complete). There is no prepared form for *entering*
another folder: `show(_:focus:history:complete:presorted:)` and `showRemembered(…)` do their work on the calling
thread (the filter over every entry when a display filter is on, the name index for the cursor, later the
totals). Wanted, additive: `PanelModel.prepare(_ basis:, show listing:, focus:, history:, complete:, remembered:,
presorted:)`.
Fallback in place, for `show` only: a first piece of 20,000 entries or more is shown as its first 5,000
(`complete: false`) and the whole list follows through `prepare(_:extendingTo:sortedBy:)`. `showRemembered` of a
long remembered listing is still one call on the main thread (no filter pass unless a display filter is on).

## 3. Every plugin with `prepareToQuit`: what the two buttons of the shell mean (for your information)

The shell now calls `Kernel.shouldTerminate()` and `Kernel.prepareToQuit(cancellation:completion:)` (see
`status/shell-p2.md`). While plugins are not done after half a second it shows "Finishing before quitting…"
with two buttons:
- **Quit Now** sets the cancellation flag. The program quits when every plugin has called its completion, and
  5 s later whether or not they have; `stop()` runs after that as before. (Archives already goes straight to
  keeping what was not written when its `prepareToQuit` was cancelled; any other plugin should do the same and
  not start the same work over in `stop()`.)
- **Don't Quit** calls the quit off and does *not* set the flag: what the plugins were writing they go on
  writing, the program stays in use, and `prepareToQuit` is called again at the next quit. A plugin must
  therefore leave itself usable after a `prepareToQuit` that was not cancelled: nothing that only `stop()` may do
  (switching its delayed writes off for good, dropping its services). `ViewerPlugin.prepareToQuit` closes its
  windows; after "Don't Quit" they stay closed, which is harmless.

## 4. Configuration (settings export/import): large values are files now

`UserDefaultsSettings.setLarge(_:forKey:)` / `largeData(forKey:)` keep each value in a file of its own
(`~/Library/Application Support/<bundle id>/Settings/<key>.data`, mode 0600, written in the background) and
remove the copy in the preferences. `ConfigurationPlugin.storedKeys(of:)` lists the persistent domain of the
preferences, so a key that is only ever stored with `setLarge` (the Multi-Rename undo history, once the plugin
calls it) no longer appears in an export. That is the right outcome for histories (they are left out of exports
anyway); a large value that *should* travel would have to be read with `largeData(forKey:)` by name.

## 5. SystemTools: the typed line now arrives with the blank it began with

`CommandLineView.execute` used to trim the line before it handed it to `afm_RunCommandLine`, so
`CommandHistory.isPrivate(line)` could never be true for a line typed in the window. The shell now passes a
private line with one leading blank (` curl -u me:secret …`), and keeps it out of its own history
(`window.commandLineHistory`) by the same rule and by the same switch (`systemTools.recordHistory`).
`TypedCommand.init` trims, so nothing else changes. No change needed; for your information.

## 6. Navigation: `cd` from the command line is reported by the shell

The shell calls `ServerConsentService.userChose(_:)` for the location of a `cd <path>` typed on the command line,
when its file system `connectsToServer`, before it performs `afm_ChangeDirectory`. Navigation need not (and
cannot) tell that case from other callers of the command. "Go to Folder…" is Navigation's own and already does it.

## 7. Plugins: `enabled:` / `checked:` closures (unchanged from `shell.md` item 5)

Nothing in the shell can make them cheap. The second-pass measurement at one million entries with 500,000 marks
(debug build): `MainWindowController.validateBars()` 0 ms, `PanelEvents.post(.cursorMoved / .selectionChanged /
.locationChanged)` 0 ms each. So the closures that were slow in the review are fixed or no longer reached on
those paths; the request stays only as a rule for new commands.
