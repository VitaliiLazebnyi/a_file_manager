import Foundation

/// IPv6: a server on ::1, and data connections the server makes to the client.
extension CoverageNetworkServer {
    /// A socket that listens on ::1, on a port the system picks.
    internal static func listenOnIPv6() throws -> Int32 {
        let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_loopback
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 16) == 0 else {
            close(descriptor)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        return descriptor
    }
}

/// Active mode: the server connects to the client.
extension CoverageNetworkServer.Line {
    /// Connects to the client for the next transfer, as EPRT asks (`|2|::1|port|`); false
    /// when the argument is no IPv6 address and port or nobody listens there.
    internal func connectBack(_ argument: String) -> Bool {
        let parts = argument.split(separator: "|")
        guard parts.count == 3, let clientPort = UInt16(parts[2]) else {
            return false
        }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = clientPort.bigEndian
        guard inet_pton(AF_INET6, String(parts[1]), &address.sin6_addr) == 1 else {
            return false
        }
        let descriptor = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard result == 0 else {
            close(descriptor)
            return false
        }
        active = descriptor
        return true
    }
}
