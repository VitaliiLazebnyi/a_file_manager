# Cross-requests from the sync / compare / file-tools agent (tools)

## 1. Kernel + shell: a plugin may veto quitting (T026)

Files: `Sources/AFMKernel/PluginAPI/Kernel.swift` (protocol `Plugin`), `Sources/AFMShell/App/Shell.swift` (`applicationShouldTerminate`, ~line 103).

Wanted, additive:

```swift
public protocol Plugin: AnyObject {
    ...
    /// Called before the program quits, on the main thread. A plugin with work the user would lose (unsaved
    /// edits) asks its question here and returns false when the user cancels; the quit is then called off.
    func shouldTerminate() -> Bool
}
extension Plugin { public func shouldTerminate() -> Bool { true } }
```

and in `applicationShouldTerminate`, before the job check: `guard kernel.plugins.allSatisfy({ $0.shouldTerminate() }) else { return .terminateCancel }`.

Why: Cmd+Q with edited files in Compare windows discards them silently; `stop()` runs only after the quit is decided, so it can ask (Save / Don't Save) but cannot call the quit off.
`CompareContentPlugin` already has `public func shouldTerminate() -> Bool` with exactly this meaning (Save / Don't Save / Cancel for every window with unsaved edits); once the requirement exists it satisfies it as it is. Until then `stop()` asks Save / Don't Save for what is left, so nothing is lost silently.
Depends on: T026.

## 2. Kernel: `FileItem.isSameLocation` (T025)

`Sources/AFMKernel/FileSystem/FileItem.swift:103` compares text only. The three tools guard their outputs by file identity (device and inode) themselves now (`ToolRun.isSameFile`, `CompareLoader.isSameFile`), so nothing is needed for the findings; a kernel-wide `URL.isSameFile(as:)` with that behaviour for local files would let other callers do the same.
