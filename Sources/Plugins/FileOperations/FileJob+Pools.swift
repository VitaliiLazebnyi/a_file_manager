import AFMContracts
import AFMKernel
import Foundation
import os

extension FileJob {
    /// Several files at once only where both ends answer at once: local volumes that are not
    /// spinning disks.
    ///
    /// Everything else gets a single stream.
    internal func makePool() -> Pool? {
        guard options.copiesSmallFilesInParallel, parallelWidth > 1, let target, !sources.isEmpty,
            areFastAndLocal([target.directory] + sourceFolders())
        else { return nil }
        return Pool(width: parallelWidth)
    }

    /// The folders the sources lie in, each once: a list of files from anywhere has many.
    ///
    /// Of a very long list a spread sample is looked at; a wrong guess costs speed, nothing else.
    private func sourceFolders() -> [URL] {
        var folders: [URL] = []
        var seen = Set<String>()
        var last = ""
        for index in stride(from: 0, to: sources.count, by: max(1, sources.count / 4_096)) {
            let parent = sources[index].deletingLastPathComponent()
            let folder = parent.absoluteString
            if folder == last { continue }
            last = folder
            if seen.insert(folder).inserted { folders.append(parent) }
        }
        return folders
    }

    /// A few files at once for deleting, where the disk answers at once.
    ///
    /// Measured on APFS: four workers delete three times as fast as one, more cores gain almost
    /// nothing.
    internal func makeDeletePool() -> Pool? {
        guard kind == .delete(toTrash: false), options.copiesSmallFilesInParallel, parallelWidth > 1,
            areFastAndLocal(sourceFolders())
        else { return nil }
        return Pool(width: min(4, parallelWidth))
    }

    private func areFastAndLocal(_ urls: some Sequence<URL>) -> Bool {
        // Many folders, few disks: each disk is asked about once.
        var devices = Set<dev_t>()
        for url in urls {
            if let device = FileIdentity.device(ofNearest: url), !devices.insert(device).inserted { continue }
            guard let provider = try? fileSystems.provider(for: url),
                let volume = provider.volume(of: url, cancellation: cancellation), volume.isLocal,
                !StorageMedium.isRotational(url)
            else { return false }
        }
        return true
    }
}
