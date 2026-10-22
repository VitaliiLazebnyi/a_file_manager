import AFMKernel
import AFMShell
import AppKit
import Foundation
import TestSupport

@testable import PlacesPlugin

/// A file system of folders only, for the directory tree: listings come from a table at once,
/// and the next listing of a folder can be held until the test lets it go.
///
/// Unchecked: every value is guarded by `condition`.
internal final class CoveragePlacesFolders: FileSystemProvider, @unchecked Sendable {
    private struct NotAFolder: Error {}

    private let condition = NSCondition()
    private var children: [String: [String]] = ["/": []]
    /// Folders whose next listing waits until it is let go.
    private var holding: Set<String> = []
    private var waiting: [String: Int] = [:]
    private var letGo: Set<String> = []

    internal let scheme = "tree"
    internal var capabilities: FileSystemCapabilities { [] }

    /// The places the file system offers; by default the disk, one inside it, and a home folder.
    internal var placeList: [Place] {
        get { condition.withLock { offered } }
        set { condition.withLock { offered = newValue } }
    }

    private lazy var offered = [
        Place(name: "Tree", url: url("/"), kind: .internalDisk),
        Place(name: "Inner", url: url("/Inner"), kind: .externalDisk),
        Place(name: "Home", url: url("/Home"), kind: .home)
    ]

    internal init(_ paths: [String] = []) {
        paths.forEach(add)
    }

    private static func path(of url: URL) -> String {
        let path = url.standardized.path
        return path.isEmpty ? "/" : path
    }

    internal func url(_ path: String) -> URL {
        URL(string: "tree://" + (path.hasPrefix("/") ? path : "/" + path)) ?? URL(fileURLWithPath: "/")
    }

    /// Makes a folder and the folders above it.
    internal func add(_ path: String) {
        condition.withLock {
            var parent = "/"
            for name in path.split(separator: "/").map(String.init) {
                let child = parent == "/" ? "/" + name : parent + "/" + name
                if children[child] == nil {
                    children[child] = []
                    children[parent, default: []].append(name)
                }
                parent = child
            }
        }
    }

    /// Removes a folder and what is in it.
    internal func remove(_ path: String) {
        condition.withLock {
            children = children.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
            let parent = (path as NSString).deletingLastPathComponent
            children[parent]?.removeAll { $0 == (path as NSString).lastPathComponent }
        }
    }

    /// Adds `count` subfolders `<prefix><n>` to the folder at `path` at once.
    internal func addMany(_ count: Int, below path: String, prefix: String = "f") {
        condition.withLock {
            for index in 0..<count {
                let name = "\(prefix)\(index)"
                children[path + "/" + name] = []
                children[path, default: []].append(name)
            }
        }
    }

    /// The next listing of `path` waits until `release(path)`.
    internal func hold(_ path: String) {
        condition.withLock { _ = holding.insert(path) }
    }

    /// Lets a held listing of `path` go on.
    internal func release(_ path: String) {
        condition.withLock {
            letGo.insert(path)
            condition.broadcast()
        }
    }

    /// Whether a listing of `path` waits right now.
    internal func isWaiting(_ path: String) -> Bool {
        condition.withLock { waiting[path, default: 0] > 0 }
    }

    private func pass(_ path: String) {
        condition.withLock {
            guard holding.remove(path) != nil else {
                return
            }
            waiting[path, default: 0] += 1
            while !letGo.contains(path) { condition.wait() }
            letGo.remove(path)
            waiting[path, default: 1] -= 1
        }
    }

    internal func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        let path = Self.path(of: directory)
        pass(path)
        guard let names = condition.withLock({ children[path] }) else { throw NotAFolder() }
        return names.filter { showHidden || !$0.hasPrefix(".") }
            .map { name in
                FileItem(
                    url: url(path == "/" ? "/" + name : path + "/" + name),
                    name: name,
                    kind: .init(isDirectory: true, isHidden: name.hasPrefix(".")),
                    stat: .init(permissions: 0o755)
                )
            }
    }

    internal func item(at _: URL) -> FileItem? { nil }

    internal func parent(of directory: URL) -> URL? {
        let path = Self.path(of: directory)
        return path == "/" ? nil : url((path as NSString).deletingLastPathComponent)
    }

    internal func root(of _: URL) -> URL { url("/") }

    internal func read(_: URL) throws -> any FileReader { throw FileSystemError.notSupported("Reading") }
    internal func createDirectory(at _: URL) throws { throw FileSystemError.notSupported("Writing") }
    internal func write(_: URL) throws -> any FileWriter { throw FileSystemError.notSupported("Writing") }
    internal func remove(_: URL) throws { throw FileSystemError.notSupported("Writing") }
    internal func move(_: URL, to _: URL, replacing _: Bool) throws { throw FileSystemError.notSupported("Writing") }
    internal func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) throws {
        throw FileSystemError.notSupported("Writing")
    }

    internal func displayPath(_ url: URL) -> String { "tree:" + Self.path(of: url) }

    internal func location(from text: String) -> URL? {
        text.hasPrefix("tree:") ? url(String(text.dropFirst(5))) : nil
    }

    internal func places() -> [Place] { placeList }
}

/// The parts of the Directory Tree window, found by their place in it.
@MainActor
internal struct CoveragePlacesTreeParts {
    internal let controller: DirectoryTreeWindowController

    internal var window: NSWindow? { controller.window }
    private var stack: NSStackView? { window?.contentView as? NSStackView }

    internal var popup: NSPopUpButton? { stack?.arrangedSubviews[0] as? NSPopUpButton }
    internal var outline: NSOutlineView? { CoveragePlacesLoop.views(NSOutlineView.self, in: stack).first }
    internal var path: String { (stack?.arrangedSubviews[2] as? NSTextField)?.stringValue ?? "" }
    internal var searchField: NSTextField? { row(3)?.arrangedSubviews[1] as? NSTextField }
    internal var status: String { (row(4)?.arrangedSubviews[0] as? NSTextField)?.stringValue ?? "" }

    /// The titles of the rows as they are drawn.
    internal var rows: [String] {
        guard let outline else {
            return []
        }
        return (0..<outline.numberOfRows).map(title(ofRow:))
    }

    internal var selected: String? {
        guard let outline, outline.selectedRow >= 0 else {
            return nil
        }
        return title(ofRow: outline.selectedRow)
    }

    /// The number of folders the status line names; 0 when it names none.
    internal var count: Int {
        let token = status.split(separator: " ").first { $0.contains(where: \.isNumber) } ?? ""
        return Int(token.filter(\.isNumber)) ?? 0
    }

    /// A scan or a read of the cache is over and the count shows.
    internal var isIdle: Bool { status.hasSuffix("directories") || status.hasSuffix("F2 reads the rest") }
    private func row(_ index: Int) -> NSStackView? { stack?.arrangedSubviews[index] as? NSStackView }

    internal func title(ofRow row: Int) -> String {
        guard let outline, let item = outline.item(atRow: row) else {
            return ""
        }
        return (controller.outlineView(outline, viewFor: nil, item: item) as? NSTextField)?.stringValue ?? ""
    }

    /// The row titled `title`, or -1.
    internal func row(titled title: String) -> Int {
        rows.firstIndex(of: title) ?? -1
    }

    internal func click(_ title: String) {
        guard let button = CoveragePlacesLoop.button(title, in: stack), let action = button.action else {
            return
        }
        NSApp.sendAction(action, to: button.target, from: button)
    }

    internal func press(_ characters: String, code: UInt16 = 0, _ modifiers: NSEvent.ModifierFlags = []) {
        outline?.keyDown(with: CoveragePlacesLoop.key(characters, code: code, modifiers: modifiers))
    }

    internal func type(_ text: String) {
        searchField?.stringValue = text
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
    }

    internal func chooseRoot(_ index: Int) {
        guard let popup, let action = popup.action else {
            return
        }
        if index < 0 { popup.select(nil) } else { popup.selectItem(at: index) }
        NSApp.sendAction(action, to: popup.target, from: popup)
    }

    internal func escape() -> Bool { (window as? ToolWindow)?.onEscape?() == true }
}
