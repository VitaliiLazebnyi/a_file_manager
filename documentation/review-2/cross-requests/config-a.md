# Cross requests from config-a (Configuration, SystemTools, ViewOptions, MacIntegration)

Nothing here blocks a config-a fix: each item has a working local fallback in place.

## For the kernel agent

### 1. A registry of settings keys (findings C013, C014, C015, C035)

Settings import now accepts only keys it knows. Without a registry "known" is: the registered preferences (checked by
kind), keys the program has stored, a few fixed keys, and any key whose first component is in a fixed list of plugin
namespaces (`SettingsSchema.namespaces` in `Sources/Plugins/Configuration/SettingsTransfer.swift`). Which keys can run
code or change trust is decided by name there too (`SettingsSchema.group(of:value:)`). Wanted, e.g. on `Kernel`:
`settingsKeys.declare(_ key: String, kind: SettingsKeyKind, check: ((Data) -> Bool)? = nil)` with `SettingsKeyKind` =
`.ordinary`, `.history` (left out of exports), `.runsCode`, `.trust`, `.connection`, and prefix declarations for key
families (`findFiles.history.`). The Configuration plugin would then drop its lists and a plugin that adds a key would
say what it is.

### 2. `PanelModel`: the marked items without a pass over the list on the main thread (C027, C030, C032, C062, C097)

`operands()` and `items.filter { isSelected($0) }` are O(list) on the main thread however few items are marked, and
`selection` builds a `Set<String>` of all marks when they changed. config-a now picks the marked items out on a
background thread from `(items, selection)` and falls back to the model when two names read the same
(`CommandRunner.snapshot`, `MacIntegrationPlugin.withLocalOperands`, `SystemTools.printList`). Wanted: a value that can
leave the main thread, e.g. `func operandsSnapshot() -> PanelModel.Operands` (O(1), holds `items` and the exact mark
set) with `func items() -> [FileItem]` callable from any thread. That removes the three copies and the `Set<String>`
build.

### 3. `PanelModel`: do not raise `listVersion` when an update changes nothing (C063, C127)

ViewOptions now sorts and filters a stale list again in the background instead of on the main thread, as often as
needed. In a watched folder whose reloads change nothing, the version still moves every time, so a sort of a very long
list can be repeated several times before it lands. An unchanged `update(with:)` should leave `listVersion` alone.

### 4. Select All / Invert / Restore Selection cost 170–290 ms at 1M (rest of C062)

Those are `PanelModel` (`shownKeys`) and the Selection plugin, outside config-a.

### 5. One home for two small helpers

`DisplayText.oneLine(_:limit:)` (untrusted names in messages and logs) is copied into the Configuration, SystemTools and
MacIntegration plugins, and `LoginShell` (the fixed POSIX shell and the PATH of the login shell) into Configuration and
SystemTools, because plugins share no code but the kernel's. `AFMContracts` (next to `Format`) would be the place; the
copies can then go.

## For the config-b agent (Places)

- **C024, C025:** imported numbers are now limited on import (every number to ±10^12, the visit counters of
  `places.history.frequent` to 0…1,000,000; covered by
  `Review2ConfigASettings.valuesOfTheWrongKindAreRefusedAndNumbersLimited` with the fuzzer's reproducer). The counter
  itself (`DirectoryHistory.swift`) still needs its own clamp on decode and a saturating add, because stored settings
  can be edited by hand; the code I read already has both.
- **C013 (hotlist part), C103:** an imported `places.hotlist` is stored only when the user ticks it, and the import
  dialog lists every entry that has a command. `Hotlist.limit` is still enforced on insert only; please enforce it on
  load as well.

## For the network agent (C015, C035)

- Imported connections no longer reuse the number of a stored connection unless every field is the same
  (`SettingsImportPlan.init`), so a file cannot point a stored password at another server. The root cause is still
  there: the keychain item is found by the connection's UUID alone (`RemoteFileSystem.swift` ~59-65). Please bind it to
  host, port and user as well.
- When an import replaces `network.connections`, the keychain items of the connections that went stay behind (the
  Configuration plugin cannot reach `PasswordStore`). A sweep of items without a connection at start would do.
- `network.trustedCertificates` (and any `network.` key with `certificate`, `trust` or `tls` in its name) is stored from
  a file only when the user ticks "certificates trusted for servers".

## For the shell agent (AFMShell)

- **C053:** the command line of the window keeps its own history (`window.commandLineHistory`). It is left out of
  exports by its name. SystemTools now skips a line that begins with a blank and has an option
  `systemTools.recordHistory`; the window's history should follow the same two rules.
- **C048:** `SystemTools` decides "program or application" with the PATH of the login shell now
  (`LoginShell.searchPath`); if the shell does a similar check before it hands a line over, it needs the same.

## For the owner of `Tests/Fuzz` (fuzz-misc)

`Tests/Fuzz/pkg/Fuzz/fuzz-misc/main.swift` still compiles against the changed types (I kept `ExpandedParameters.text`,
`ShellWords.*`, `CommandLanguage.expandingEnvironment` and `CommandRunner.applicationLine(for: String)`), but two
targets no longer test what runs:

- `quote` and `quote-demo` hand `result.text` to the shells. That is now the readable form only. What the program runs
  is `ShellLine.script(result.pieces)`: start the shell with `["-c"] + script.arguments` (see `Review2ConfigAShell.run`
  in `Tests/PluginTests/Review2ConfigAShellTests.swift`).
- `settings` calls `center.importSettings(from:)`. An import now shows a form and does nothing when it is cancelled,
  which is what `ScriptedInteraction` answers by default. Give it

  ```swift
  ui.formAnswers = [.values(["commands": .flag(true), "keys": .flag(true), "programs": .flag(true), "trust": .flag(true), "connections": .flag(true), "hotlist": .flag(true), "tabs": .flag(true)])]
  ```

  before each import to exercise the whole path. I did not build or run the fuzz package.

## Not in either config agent's scope

- **C011, C012** (Selection plugin: mask selection, Compare Directories, Mark Newer on the main thread) and the
  Selection part of **C097**. The brief gives Selection to neither config-a nor config-b.
- The MultiRename lines of **C038** (`RenameRun.swift:210, 265`).
