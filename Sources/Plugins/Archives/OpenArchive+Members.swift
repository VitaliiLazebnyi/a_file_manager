import AFMKernel
import Foundation

/// Reading members.
extension OpenArchive {
    /// The contents of a member from its first byte.
    ///
    /// Members are checked while they are read: a stream that reaches its end without an error
    /// delivered what was packed. A ZIP entry carries the file its position belongs to, so an entry
    /// that was looked up before the archive was rewritten still reads the right bytes. Through a
    /// `slot` the reading ends early, with an error, when its owner interrupts: where the member
    /// lies behind a long stretch of decompression, opening itself is that long.
    internal func open(_ entry: ArchiveEntry, slot: InterruptSlot?) throws -> any ByteStream {
        let (current, copy, source, kind) = locked { (file, unpacked?.file, memberSource, format) }
        switch entry.content {
        case .empty:
            return DataStream(Data())

        case .text(let text):
            return DataStream(Data(text.utf8))

        case .unsupported(let what):
            throw ArchiveError.unsupported(what)

        case .zip(let record):
            return try openZip(record, path: entry.path)

        case .range(let offset, let length):
            return FileRangeStream(copy ?? current, offset: offset, length: length)

        case .whole:
            guard case .compressedFile(let codec) = kind else { throw ArchiveError.notFound(entry.path) }
            let control = StreamInterrupt()
            slot?.use(control)
            return try codec.decompressing(current, control: control)

        case .member(let wanted):
            guard let source else { throw ArchiveError.notFound(entry.path) }
            return try openStreamMember(entry, number: wanted, source: source, slot: slot)
        }
    }

    /// The member with this number of an archive that can only be read front to back.
    ///
    /// A reader that stands in front of the member goes on from there: files copied one after
    /// the other cost one pass through the archive, not one each.
    private func openStreamMember(
        _ entry: ArchiveEntry,
        number wanted: Int,
        source: (StreamInterrupt?) throws -> any ByteStream,
        slot: InterruptSlot?
    ) throws -> any ByteStream {
        let waiting = takeParked(before: wanted)
        let reader: TarReader
        if let waiting {
            reader = waiting.reader
        } else {
            let control = StreamInterrupt()
            reader = TarReader(try source(control), control: control)
        }
        slot?.use(reader.control)
        var index = waiting?.next ?? 0
        do {
            while let header = try reader.next() {
                if index == wanted {
                    try check(header, is: entry)
                    return TarMemberStream(reader, closesReader: false) { [weak self] sound in
                        if sound, let self { park(reader, next: wanted + 1) } else { reader.close() }
                    }
                }
                index += 1
            }
        } catch {
            reader.close()
            throw error
        }
        reader.close()
        throw ArchiveError.changedOutside(name)
    }

    /// Takes the parked reader that stands closest in front of the member with this number; nil
    /// (counting a new start of the stream) when none does.
    private func takeParked(before wanted: Int) -> ParkedReader? {
        locked {
            let candidates = parked.indices.filter { index in parked[index].next <= wanted }
            guard let index = candidates.max(by: { first, second in parked[first].next < parked[second].next })
            else {
                starts += 1
                return nil
            }
            return parked.remove(at: index)
        }
    }

    /// A member that is found by its number in a stream must be the one that was listed: a
    /// stream that is started again reads the file as it is now, which may be another.
    private func check(_ header: TarHeader, is entry: ArchiveEntry) throws {
        let sameSize = Int64(clamping: header.realSize ?? header.size) == entry.size
        guard sameSize || ArchiveTree.normalized(header.path) == entry.path else {
            throw ArchiveError.changedOutside(name)
        }
    }

    /// Keeps a reader that has delivered a member for the members behind it; it is closed
    /// when nobody came for it after a while.
    ///
    /// One sweep looks after all that wait, however many members are read.
    private func park(_ reader: TarReader, next: Int) {
        // One that was interrupted can read no more.
        guard reader.control?.isSet != true else {
            reader.close()
            return
        }
        lock.lock()
        parked.append(ParkedReader(reader: reader, next: next, since: .now()))
        // One for each of a few threads that read side by side.
        let dropped = parked.count > 4 ? parked.removeFirst() : nil
        let arm = !reaperArmed
        reaperArmed = true
        lock.unlock()
        dropped?.reader.close()
        if arm { armReaper() }
    }

    /// Closes the parked readers nobody came back for, `readerParkTime` after they were parked,
    /// and comes back as long as any wait.
    private func armReaper() {
        // On the plugin's own clock and a thread of its own, like the delayed writes: the
        // shared queues may have no thread free for a long time, and closing a reader may
        // wait for the place the archive lies in.
        let parkTime = environment.readerParkTime
        environment.housekeeping(parkTime + 0.5, .utility) { [weak self] in
            guard let self else {
                return
            }
            let limit = UInt64(parkTime * 1_000_000_000)
            lock.lock()
            let now = DispatchTime.now().uptimeNanoseconds
            let stale = parked.filter { waiting in now &- waiting.since.uptimeNanoseconds >= limit }
            parked.removeAll { waiting in now &- waiting.since.uptimeNanoseconds >= limit }
            let again = !parked.isEmpty
            reaperArmed = again
            lock.unlock()
            for waiting in stale { waiting.reader.close() }
            if again { armReaper() }
        }
    }

    /// Hands the wanted members to `body` one by one, in archive order.
    ///
    /// For archives that can only be read front to back this takes one pass, however many members
    /// are wanted; `body` must then read (or leave) each stream before it returns. With
    /// `throughTheEnd`, the pass reads the archive's stream from the file to its end, also when its
    /// members are read from a copy or none is wanted: only there are the checks of the compressed
    /// stream itself (the checksum at the end of a GZIP file) made, on the file as it is now.
    internal func readInOnePass(
        _ wanted: [ArchiveEntry],
        cancellation: CancellationFlag?,
        throughTheEnd: Bool,
        _ body: (ArchiveEntry, any ByteStream) throws -> Void
    ) throws {
        // One name per member goes through the pass; further names of the same member (hard
        // links) are read by themselves afterwards.
        var streamed: [Int: ArchiveEntry] = [:]
        for entry in wanted {
            if case .member(let index) = entry.content, streamed[index] == nil { streamed[index] = entry }
        }
        if !streamed.isEmpty || throughTheEnd, let source = locked({ memberSource }) {
            // The pass runs through long stretches of decompression between two members.
            let control = StreamInterrupt()
            let following = control.following(cancellation)
            try withExtendedLifetime(following) {
                try pass(through: try source(control), control: control, streamed, throughTheEnd: throughTheEnd, body)
            }
        }
        for entry in wanted {
            if case .member(let index) = entry.content, streamed[index]?.path == entry.path { continue }
            let stream = try open(entry, slot: nil)
            defer { stream.close() }
            try body(entry, stream)
        }
    }

    /// The one pass of `readInOnePass` through the archive's stream: the members `streamed` (by
    /// their numbers) go to `body` as they come.
    private func pass(
        through stream: any ByteStream,
        control: StreamInterrupt,
        _ streamed: [Int: ArchiveEntry],
        throughTheEnd: Bool,
        _ body: (ArchiveEntry, any ByteStream) throws -> Void
    ) throws {
        let reader = TarReader(stream, control: control)
        defer { reader.close() }
        var index = 0
        var left = streamed.count
        while left > 0 || throughTheEnd, let header = try reader.next() {
            if let entry = streamed[index] {
                try check(header, is: entry)
                try body(entry, TarMemberStream(reader, closesReader: false, onClose: nil))
                left -= 1
            }
            index += 1
        }
        // The stream ended before every member came: it is not the archive that was listed.
        if left > 0 { throw ArchiveError.changedOutside(name) }
        // What follows the last member: the end of the TAR, the checksum of the compressed stream.
        while throughTheEnd, try stream.read(upToCount: 1 << 16) != nil { try control.check() }
    }
}
