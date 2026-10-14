import AFMKernel
import Foundation
import FuzzCore

/// Browsing: listing an opened archive and reading what it holds.
extension Opened {
    /// Lists everything and reads every file, while less than `readLimit` bytes have been read.
    internal func browse(readLimit: Int) -> BrowseResult {
        var result = BrowseResult()
        var queue = [root]
        var total = 0
        while let folder = queue.popLast(), result.count < 20_000 {
            guard let items = try? provider.list(folder, showHidden: true) else {
                continue
            }
            if folder == root {
                result.listed = true
            }
            for item in items {
                result.count += 1
                checkListedName(item.name, in: folder)
                _ = provider.item(at: item.url)
                if item.isDirectory {
                    queue.append(item.url)
                    continue
                }
                guard total < readLimit, let member = readMember(item.url, limit: readLimit) else {
                    continue
                }
                total += member.data.count
                if member.complete {
                    result.contents[item.url.path] = member.data
                }
            }
        }
        return result
    }

    /// A member whose name is a way out (`..`, a zero byte, a `/` that is part of a name or
    /// joined to a neighbouring character) is not listed at all.
    private func checkListedName(_ itemName: String, in folder: URL) {
        let name = Array(itemName.utf8)
        fzCheck(
            !name.isEmpty && name != [0x2E] && name != [0x2E, 0x2E] && !name.contains(0x2F) && !name.contains(0),
            "listed-unsafe-name",
            "\(itemName.debugDescription) in \(folder.path.debugDescription)"
        )
    }

    /// Reads a member to its end, or until it is longer than `limit`; nil when it cannot be opened.
    private func readMember(_ url: URL, limit: Int) -> (data: Data, complete: Bool)? {
        guard let reader = try? provider.read(url) else {
            return nil
        }
        var data = Data()
        var complete = true
        do {
            while let block = try reader.read(upToCount: 70_000) {
                data.append(block)
                if data.count > limit {
                    complete = false
                    break
                }
            }
        } catch {
            complete = false
        }
        reader.close()
        return (data, complete)
    }
}
