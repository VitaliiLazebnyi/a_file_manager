public import AFMKernel
import AppKit
import Foundation

/// The places the user goes to: home and its usual folders, and the mounted volumes.
extension LocalFileSystem {
    /// The places that are known without asking a disk.
    internal static func fixedPlaces(home: URL) -> [Place] {
        [Place(name: "Home", url: home, kind: .home)]
            + ["Desktop", "Documents", "Downloads"]
            .map { folder in
                Place(name: folder, url: home.appending(name: folder), kind: .folder)
            }
            + [
                Place(
                    name: "Applications",
                    url: URL(fileURLWithPath: "/Applications", isDirectory: true),
                    kind: .folder
                )
            ]
    }

    /// Reads the places from the system.
    ///
    /// Each volume is asked about on its own thread and waited for for a moment only, so that one
    /// that does not answer (a share that went away) shows with what was known of it, or its folder
    /// name, and holds up none of the others.
    internal static func readPlaces(previous: [Place], _ probes: LocalProbes, asking volumesAsking: Locked<Set<String>>)
        -> [Place]
    {
        let files = FileManager.default
        let home = probes.home ?? files.homeDirectoryForCurrentUser
        var places = [Place(name: "Home", url: home, kind: .home)]
        places += ["Desktop", "Documents", "Downloads"]
            .map { folder in
                Place(name: folder, url: home.appending(name: folder), kind: .folder)
            }
        let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if files.fileExists(atPath: cloud.path) {
            places.append(Place(name: "iCloud Drive", url: cloud, kind: .folder))
        }
        places.append(
            Place(name: "Applications", url: URL(fileURLWithPath: "/Applications", isDirectory: true), kind: .folder)
        )
        // (The system always answers with a list; none would be no volumes.)
        let volumes = Array(
            [files.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes])]
                .compactMap(\.self).joined()
        )
        let answers = askVolumes(volumes, probes, asking: volumesAsking)
        for (volume, answered) in zip(volumes, answers) {
            guard let answered else {
                // Not answered in time: what was known of it, or its folder name.
                places.append(
                    previous.first { $0.url.path == volume.path }
                        ?? Place(
                            name: volume.lastPathComponent,
                            url: volume,
                            kind: volume.path == "/" ? .internalDisk : .externalDisk
                        )
                )
                continue
            }
            places.append(answered)
        }
        return places
    }

    /// Internal: the start-up disk, and a local disk the system calls internal that cannot be
    /// taken out.
    ///
    /// A volume the system knows nothing about counts as external: each trait it does not state
    /// is passed as false.
    internal static func volumeKind(
        path: String,
        isInternal: Bool,
        isLocal: Bool,
        isRemovable: Bool,
        isEjectable: Bool
    )
        -> Place.Kind
    {
        if path == "/" {
            return .internalDisk
        }
        let fixed = isLocal && isInternal && !isRemovable && !isEjectable
        return fixed ? .internalDisk : .externalDisk
    }

    /// Asks every volume about itself, each on a thread of its own, and waits for the answers for
    /// a moment; nil for each volume that has not answered by then, or that is still being asked
    /// by an earlier reading.
    private static func askVolumes(_ volumes: [URL], _ probes: LocalProbes, asking volumesAsking: Locked<Set<String>>)
        -> [Place?]
    {
        let answers = volumes.map { _ in Locked<Place?>(nil) }
        let group = DispatchGroup()
        for (volume, answer) in zip(volumes, answers) {
            let key = volume.path
            guard volumesAsking.withValue({ $0.insert(key).inserted }) else { continue }
            group.enter()
            BlockingCalls.run {
                let place = askVolume(volume, probes)
                answer.withValue { $0 = place }
                volumesAsking.withValue { $0.remove(key) }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + probes.volumePatience)
        return answers.map { answer in answer.withValue { $0 } }
    }

    /// The place of a volume, as the volume describes itself; may wait for as long as it likes.
    private static func askVolume(_ volume: URL, _ probes: LocalProbes) -> Place {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeIsRootFileSystemKey
        ]
        probes.willAsk?(volume.path)
        let values = try? volume.resourceValues(forKeys: keys)
        return Place(
            name: values?.volumeName ?? volume.lastPathComponent,
            url: volume,
            kind: Self.volumeKind(
                path: volume.path,
                isInternal: values?.volumeIsInternal == true,
                isLocal: values?.volumeIsLocal == true,
                isRemovable: values?.volumeIsRemovable == true,
                isEjectable: values?.volumeIsEjectable == true
            ),
            canBeEjected: Place.VolumeTraits(path: volume.path, values: values).mayBeEjected
        )
    }

    /// Home and its usual folders, iCloud Drive and Applications, then every mounted volume the
    /// Finder would show.
    ///
    /// The start-up disk and other built-in disks are internal; whatever is plugged in, a disk
    /// image or a network share is listed as external (the volume list knows no finer kinds).
    ///
    /// **Answers at once, and never waits**: with the last list that was read, or the places
    /// that need no reading until the first one has landed. The list is read in the
    /// background: when this file system is made, whenever a volume comes, goes or is renamed,
    /// and when the list in hand has grown old. Reading it asks the disks, which a caller on
    /// the main thread must not wait for. When the list that was read differs from the one
    /// before, `placesDidChange` is posted on the main thread: whoever shows the places asks
    /// again.
    public func places() -> [Place] {
        placesLock.lock()
        let places = knownPlaces
        let isOld = DispatchTime.now().uptimeNanoseconds &- placesRead > 10_000_000_000
        placesLock.unlock()
        if isOld { refreshPlaces() }
        return places
    }

    /// Reads the places again in the background, unless a reading is under way (it is then
    /// read once more after it) or two readings are stuck.
    internal func refreshPlaces() {
        placesLock.lock()
        guard !isReadingPlaces else {
            placesChangedMeanwhile = true
            placesLock.unlock()
            return
        }
        guard abandonedReads < 2 else {
            // Two readings are stuck already; the list in hand stays.
            placesRead = DispatchTime.now().uptimeNanoseconds
            placesLock.unlock()
            return
        }
        isReadingPlaces = true
        placesGeneration += 1
        let (generation, previous) = (placesGeneration, knownPlaces)
        placesLock.unlock()
        // Reading the places asks the disks, and one that does not answer keeps its thread:
        // a thread of the kernel's own, not one of a dispatch queue's few.
        let (stand, asking) = (probes, volumesAsking)
        BlockingCalls.run { [weak self] in
            let places = Self.readPlaces(previous: previous, stand, asking: asking)
            self?.finishReadingPlaces(places, generation: generation)
        }
        LocalClock.queue.asyncAfter(deadline: .now() + probes.placesPatience) { [weak self] in
            self?.abandonReadingPlaces(generation: generation)
        }
    }

    /// Takes the list a reading found, unless the reading was given up meanwhile, and announces it
    /// when it differs from the one before.
    private func finishReadingPlaces(_ places: [Place], generation: Int) {
        placesLock.lock()
        guard generation == placesGeneration else {
            // Given up on meanwhile and over now: the disks answer again, so the list is read anew.
            abandonedReads -= 1
            placesLock.unlock()
            refreshPlaces()
            return
        }
        let signature = { (list: [Place]) in list.map { "\($0.name)\u{0}\($0.url.path)\u{0}\($0.kind)" } }
        let isNew = signature(places) != signature(knownPlaces)
        (knownPlaces, placesRead) = (places, DispatchTime.now().uptimeNanoseconds)
        let again = placesChangedMeanwhile
        (placesChangedMeanwhile, isReadingPlaces) = (false, false)
        placesLock.unlock()
        if isNew {
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                NotificationCenter.default.post(name: Self.placesDidChange, object: self)
            }
        }
        if again { refreshPlaces() }
    }

    /// Gives up the reading `generation` when it is still under way: the list in hand stays.
    private func abandonReadingPlaces(generation: Int) {
        placesLock.lock()
        guard isReadingPlaces, generation == placesGeneration else {
            placesLock.unlock()
            return
        }
        placesGeneration += 1
        abandonedReads += 1
        isReadingPlaces = false
        // Not asked for again at the very next call: the list in hand is as young as this.
        placesRead = DispatchTime.now().uptimeNanoseconds
        let again = placesChangedMeanwhile
        placesChangedMeanwhile = false
        placesLock.unlock()
        if again { refreshPlaces() }
    }
}
