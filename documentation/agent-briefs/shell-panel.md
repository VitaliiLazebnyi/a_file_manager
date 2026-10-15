# Assignment: shell-panel

Read and follow documentation/agent-briefs/quality-brief.md, then documentation/agent-briefs/module-brief.md (both whole
files). Assignment name: shell-panel. Base commit: 203576a (branch quality-gates; the kernel and contracts waves are
merged there, so the kernel API has changed since older notes: e.g. `Kernel.interaction`,
`FileItem(url:name:kind:stat:...)`, `Log` in AFMKernel/Support/Log.swift).

Your files: `Sources/AFMShell/Panel/**`. Existing test files you own (lint, docs, clean-up):
`Tests/ShellTests/KernelAdoptionTests.swift`, `PanelFeatureTests.swift`, `PanelPartsTests.swift`,
`RememberedListingTests.swift`, `Review2ShellP2Tests.swift`, `Review2ShellTests.swift`, `ScriptedFileSystem.swift`,
`PanelModel+SelectionNames.swift`. New test files you add go in `Tests/ShellTests/` with names starting `Panel` (UI
tests: `UITests/AFileManagerUITests/` files starting `Panel`). Another agent (shell-app) owns
`Sources/AFMShell/{App,Interaction,Window}/**`, `Sources/AFileManager/**`, the other ShellTests files and the other
UITests files; report anything you need changed there.

Do the whole module brief for your files EXCEPT step 7 (mutation): skip it; the coordinator runs mutation centrally
after the merge with per-test selection. Also:

1. Accessibility audit (see the hand-over section "UI tests, accessibility audit, snapshot tests"): fix the findings in
   the panel: the file lists have no accessibility label; the empty cells of the `[..]` row are static texts without a
   value; the Attr column fails the contrast check where it lies partly outside the visible panel. Add tests (unit tests
   of the accessibility values where possible, plus the UI audit). You are the only agent that runs `Scripts/check.sh
   uitest` (it takes over keyboard and mouse); run it near the end. One audit finding (an element of type 81 in the menu
   bar area without a description) belongs to shell-app; if the audit still fails only on that one, say so.
2. Lifetimes: shell objects in your files that hold the kernel (or other long-lived objects) strongly or `unowned`:
   review each per the module brief.
3. Duplicated wait/poll helpers in your test files: use the TestSupport ones (`Tests/TestSupport/Wait.swift` etc.)
   instead of local copies; if TestSupport lacks what you need, add it to a new TestSupport file whose name starts with
   `Panel` and say so.
4. The test `PanelStores.columnValuesAreComputedInTheBackgroundOnSeveralCores` (find it) failed once under load: make it
   deterministic without weakening what it checks (if it lies outside your files, report).
5. `MainThread.assert("…")` calls in your files: each creates a message closure that coverage counts and that runs only
   off the main thread; where the code is already main-actor isolated the assert is redundant and goes; elsewhere keep
   it and cover it.
6. Where your code swallows errors or would benefit from diagnostics, use the kernel's `Log` (`Log.logger(_:)`) rather
   than print; do not add logging for its own sake.
If you rename or remove anything public in AFMKernel/AFMContracts (you should not need to), run `Scripts/check.sh api`
and acknowledge the break in `Scripts/api-breaks.txt` with a reason.

Report as the briefs say, including the coverage numbers for your files before and after.
