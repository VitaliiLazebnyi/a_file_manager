# Assignment: shell-app

Read and follow documentation/agent-briefs/quality-brief.md, then documentation/agent-briefs/module-brief.md (both whole
files). Assignment name: shell-app. Base commit: 203576a (branch quality-gates; the kernel and contracts waves are
merged there, so the kernel API has changed since older notes: e.g. `Kernel.interaction`,
`FileItem(url:name:kind:stat:...)`, `Log` in AFMKernel/Support/Log.swift).

Your files: `Sources/AFMShell/App/**`, `Sources/AFMShell/Interaction/**`, `Sources/AFMShell/Window/**`,
`Sources/AFileManager/**`. Existing test files you own (lint, docs, clean-up):
`Tests/ShellTests/ApplicationTests.swift`, `WindowTests.swift`, `SettingsMigrationApp.swift`,
`SettingsMigrationShell.swift`, `ShellUnitTests.swift`, `Snapshot.swift`, `Snapshots.swift`, `CorePlugins.swift`,
`Review2IntegrationShellTests.swift`, and `UITests/**` except files starting `Panel`. New test files you add go in
`Tests/ShellTests/` with names starting `App` (or `Window`, `Interaction`). Another agent (shell-panel) owns
`Sources/AFMShell/Panel/**` and the other ShellTests files; report anything you need changed there.

Do the whole module brief for your files EXCEPT step 7 (mutation): skip it; the coordinator runs mutation centrally
after the merge with per-test selection. Also:

1. Accessibility audit (hand-over section "UI tests, accessibility audit, snapshot tests"): the finding that belongs to
   you is an element in the menu bar area (type 81) without a description; find it (the window/toolbar/button bar or
   menus) and fix it, with a unit test of its accessibility value where possible. Do NOT run `Scripts/check.sh uitest`
   or the UI tests yourself: they take over keyboard and mouse and shell-panel runs them; say in your report what the UI
   audit should now show for your finding. You may still build the UI test bundle and lint the UITests files.
2. Lifetimes: shell objects in your files that hold the kernel (or other long-lived objects) strongly or `unowned`:
   review each per the module brief (windows close, tests end, background work may finish later).
3. Duplicated wait/poll helpers in your test files: use the TestSupport ones (`Tests/TestSupport/Wait.swift` etc.)
   instead of local copies; if TestSupport lacks what you need, add it to a new TestSupport file whose name starts with
   `App` and say so.
4. `MainThread.assert("…")` calls in your files: each creates a message closure that coverage counts and that runs only
   off the main thread; where the code is already main-actor isolated the assert is redundant and goes; elsewhere keep
   it and cover it.
5. Where your code swallows errors or would benefit from diagnostics, use the kernel's `Log` (`Log.logger(_:)`) rather
   than print; do not add logging for its own sake.
6. `Tests/ShellTests/ShellUnitTests.swift` has known lint and format findings from upstream: clear them.
If you rename or remove anything public in AFMKernel/AFMContracts (you should not need to), run `Scripts/check.sh api`
and acknowledge the break in `Scripts/api-breaks.txt` with a reason.

Report as the briefs say, including the coverage numbers for your files before and after.
