/// The Python program the fake server runs.
extension FakeSFTPServer {
    /// The server: SFTP version 3 over its standard input and output, serving a folder, each answer after a
    /// delay picked at random between two bounds in milliseconds, and misbehaving as its mode says.
    ///
    /// Arguments: the mode's raw value, the folder, the lowest and the highest delay. It logs the kind of every
    /// request to `sftp-requests.log` next to itself, and the most answers owed at one moment to `sftp-peak.log`.
    internal static let script = """
        import heapq, os, random, select, struct, sys, time
        mode, root, low, high = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
        handles = {}
        folders = {}
        written = set()
        nextHandle = [1]
        log = open(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "sftp-requests.log"), "a")
        due = []
        counter = [0]
        peak = [0]
        peakPath = os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "sftp-peak.log")
        buffer = b""

        def u32(value): return struct.pack(">I", value)
        def string(value):
            if isinstance(value, str): value = value.encode()
            return u32(len(value)) + value
        def packet(kind, body): return u32(len(body) + 1) + bytes([kind]) + body
        def status(ident, code, message=""): return packet(101, u32(ident) + u32(code) + string(message) + string(""))
        def attributes(path, follow=False):
            info = os.stat(path) if follow else os.lstat(path)
            return sizes_and_times(info)
        def sizes_and_times(info):
            times = u32(int(info.st_atime)) + u32(int(info.st_mtime))
            return u32(1 | 4 | 8) + struct.pack(">Q", info.st_size) + u32(info.st_mode) + times

        def send_later(data):
            delay = random.uniform(low, high) / 1000.0
            counter[0] += 1
            heapq.heappush(due, (time.time() + delay, counter[0], data))
            # The most answers that were owed at one moment: what a test reads to see requests overlap.
            if len(due) > peak[0]:
                peak[0] = len(due)
                with open(peakPath, "w") as out: out.write(str(peak[0]))

        def take_string(data, at):
            (length,) = struct.unpack_from(">I", data, at)
            return data[at + 4:at + 4 + length], at + 4 + length

        def handle(kind, body):
            if kind == 1:
                os.write(1, packet(2, u32(3)))
                if mode == "stall":
                    time.sleep(600)
                return
            (ident,) = struct.unpack_from(">I", body, 0)
            at = 4
            log.write(str(kind) + "\\n")
            log.flush()
            if kind == 16:
                name, at = take_string(body, at)
                if mode == "shortpacket":
                    os.write(1, packet(101, b"\\0\\0"))
                    return
                send_later(packet(104, u32(ident) + u32(1) + string("/") + string("/") + u32(0)))
            elif kind in (7, 17):
                name, at = take_string(body, at)
                path = os.path.join(root, name.decode().lstrip("/"))
                if name.decode().endswith("hang") and mode in ("hang", "hangio"):
                    return
                if kind == 17 and mode == "links":
                    if name.decode().endswith("hang"):
                        return
                    if name.decode().endswith("die"):
                        os._exit(0)
                    if name.decode().endswith("deny"):
                        send_later(status(ident, 3, "Permission denied"))
                        return
                try:
                    send_later(packet(105, u32(ident) + attributes(path, follow=kind == 17)))
                except OSError:
                    send_later(status(ident, 2, "No such file"))
            elif kind == 11:
                name, at = take_string(body, at)
                if mode == "hangio":
                    return
                if not os.path.isdir(os.path.join(root, name.decode().lstrip("/"))):
                    send_later(status(ident, 2, "No such file"))
                    return
                number = nextHandle[0]
                nextHandle[0] += 1
                folders[number] = os.path.join(root, name.decode().lstrip("/"))
                send_later(packet(102, u32(ident) + string(str(number))))
            elif kind == 12:
                name, at = take_string(body, at)
                folder = folders.get(int(name))
                if folder is None:
                    send_later(status(ident, 1, "EOF"))
                    return
                folders[int(name)] = None
                names = sorted(os.listdir(folder))
                answer = u32(ident) + u32(len(names))
                for entry in names:
                    answer += string(entry) + string(entry) + attributes(os.path.join(folder, entry))
                if mode == "cutlisting":
                    os.close(0)
                    os.write(1, packet(104, answer))
                    time.sleep(600)
                send_later(packet(104, answer))
            elif kind == 3:
                name, at = take_string(body, at)
                (flags,) = struct.unpack_from(">I", body, at)
                path = os.path.join(root, name.decode().lstrip("/"))
                try:
                    if flags & 2:
                        creating = (os.O_CREAT if flags & 8 else 0) | (os.O_EXCL if flags & 32 else 0)
                        descriptor = os.open(path, os.O_WRONLY | creating, 0o644)
                    else:
                        descriptor = os.open(path, os.O_RDONLY)
                except OSError as error:
                    send_later(status(ident, 2 if error.errno == 2 else 4, str(error)))
                    return
                number = nextHandle[0]
                nextHandle[0] += 1
                handles[number] = descriptor
                send_later(packet(102, u32(ident) + string(str(number))))
            elif kind == 5:
                name, at = take_string(body, at)
                offset, length = struct.unpack_from(">QI", body, at)
                descriptor = handles[int(name)]
                if mode == "hangio" and offset >= 98304:
                    return
                if mode == "failread" and offset >= 98304:
                    send_later(status(ident, 4, "Read failed"))
                    return
                if mode == "shortreads":
                    readsPath = os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "sftp-reads.log")
                    with open(readsPath, "a") as out:
                        out.write(str(length) + "\\n")
                    length = min(length, 1000)
                elif mode == "emptydata":
                    send_later(packet(103, u32(ident) + string(b"")))
                    return
                elif mode == "overlong":
                    send_later(packet(103, u32(ident) + string(b"x" * (length + 10))))
                    return
                elif random.random() < 0.3:
                    # Some answers are shorter than asked for.
                    length = random.randint(1, length)
                data = os.pread(descriptor, length, offset)
                if not data:
                    send_later(status(ident, 1, "EOF"))
                else:
                    send_later(packet(103, u32(ident) + string(data)))
            elif kind == 6:
                name, at = take_string(body, at)
                (offset,) = struct.unpack_from(">Q", body, at)
                data, at = take_string(body, at + 8)
                if mode == "hangio":
                    return
                descriptor = handles[int(name)]
                written.add(int(name))
                if mode == "failwrite" and offset == 65536:
                    send_later(status(ident, 4, "No space left on device"))
                    return
                if not (mode == "forgetwrite" and offset >= 65536):
                    os.pwrite(descriptor, data, offset)
                send_later(status(ident, 0))
            elif kind == 4:
                name, at = take_string(body, at)
                descriptor = handles.pop(int(name), None)
                folders.pop(int(name), None)
                if descriptor is not None:
                    os.close(descriptor)
                if mode == "failclose" and int(name) in written:
                    send_later(status(ident, 4, "Disk quota exceeded"))
                else:
                    send_later(status(ident, 0))
            elif kind == 8:
                name, at = take_string(body, at)
                info = os.fstat(handles[int(name)])
                if mode == "nosize":
                    send_later(packet(105, u32(ident) + u32(4) + u32(info.st_mode)))
                    return
                send_later(packet(105, u32(ident) + sizes_and_times(info)))
            elif kind == 10:
                name, at = take_string(body, at)
                (flags,) = struct.unpack_from(">I", body, at)
                if flags & 1 and int(name) in handles:
                    (size,) = struct.unpack_from(">Q", body, at + 4)
                    os.ftruncate(handles[int(name)], size)
                send_later(status(ident, 0))
            elif kind == 18:
                old, at = take_string(body, at)
                new, at = take_string(body, at)
                source = os.path.join(root, old.decode().lstrip("/"))
                target = os.path.join(root, new.decode().lstrip("/"))
                if os.path.lexists(target) or (mode == "strictrename" and old.decode().endswith("locked")):
                    send_later(status(ident, 4, "Failure"))
                else:
                    os.rename(source, target)
                    send_later(status(ident, 0))
            elif kind == 13:
                name, at = take_string(body, at)
                try:
                    os.remove(os.path.join(root, name.decode().lstrip("/")))
                    send_later(status(ident, 0))
                except OSError as error:
                    send_later(status(ident, 2 if error.errno == 2 else 4, str(error)))
            elif kind in (9, 10):
                send_later(status(ident, 0))
            else:
                send_later(status(ident, 8, "Not supported"))

        while True:
            wait = None
            if due:
                wait = max(0, due[0][0] - time.time())
            ready, _, _ = select.select([0], [], [], wait)
            if ready:
                chunk = os.read(0, 1 << 20)
                if not chunk:
                    break
                buffer += chunk
                while len(buffer) >= 4:
                    (length,) = struct.unpack_from(">I", buffer, 0)
                    if len(buffer) < 4 + length:
                        break
                    body = buffer[5:4 + length]
                    kind = buffer[4]
                    buffer = buffer[4 + length:]
                    handle(kind, body)
            while due and due[0][0] <= time.time():
                _, _, data = heapq.heappop(due)
                os.write(1, data)
        """
}
