import Foundation

/// The BSD socket calls of the server and its sessions.
extension TestFTPServer {
    /// Opens a socket that listens on 127.0.0.1 on a port the system picks.
    ///
    /// Throws a `POSIXError` when no socket could be had or bound. Tests use it for a port that is
    /// surely closed, too.
    internal static func listen() throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 64) == 0 else {
            close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        return descriptor
    }

    /// The local port a socket is bound to.
    internal static func port(of descriptor: Int32) -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                getsockname(descriptor, generic, &length)
            }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// Connects to an IPv4 address, for active mode; nil when the connection is refused.
    internal static func connect(to host: String, port: Int) -> Int32? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr(host)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// Sends all of `data`; false when the peer went away before it was through.
    internal static func sendAll(_ descriptor: Int32, _ data: Data) -> Bool {
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        return data.withUnsafeBytes { buffer -> Bool in
            // Empty data has no address, and nothing to send.
            guard let start = buffer.baseAddress else {
                return true
            }
            var sent = 0
            while sent < buffer.count {
                let count = send(descriptor, start + sent, buffer.count - sent, 0)
                if count <= 0 {
                    return false
                }
                sent += count
            }
            return true
        }
    }

    /// Reads until the peer closes the connection (or it fails) and returns what came.
    internal static func receiveAll(_ descriptor: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count <= 0 {
                return data
            }
            data.append(buffer, count: count)
        }
    }
}
