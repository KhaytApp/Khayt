import Darwin
import Foundation
import Network

/// Which IPv6 addresses are on this Mac's own network — for
/// `LanServer.throttleKey`, which keys those by the full address rather than
/// by /64. See the comment there for why.
enum LanOnLink {

    /// One IPv6 prefix: the network bits of an address on one of this Mac's
    /// interfaces, and how many of them count.
    struct Prefix: Sendable, Equatable {
        let bytes: [UInt8]   // 16
        let length: Int

        init(bytes: [UInt8], length: Int) {
            self.bytes = bytes; self.length = max(0, min(128, length))
        }

        /// `"2001:db8:1:2::"`, `64` — for tests.
        init?(_ text: String, length: Int) {
            guard let a = IPv6Address(text) else { return nil }
            self.init(bytes: [UInt8](a.rawValue), length: length)
        }

        func contains(_ address: [UInt8]) -> Bool {
            guard address.count == 16, bytes.count == 16 else { return false }
            var left = length
            for i in 0..<16 where left > 0 {
                let bits = min(8, left)
                let mask = UInt8(truncatingIfNeeded: 0xff << (8 - bits))
                if (address[i] & mask) != (bytes[i] & mask) { return false }
                left -= bits
            }
            return true
        }
    }

    /// Never a prefix shorter than this: an interface reporting a /0 or a /16
    /// would otherwise make most of the internet "on link".
    static let shortestPrefix = 48

    /// Keyed by the full address: link-local (`fe80::/10`), unique-local
    /// (`fc00::/7`), loopback, and anything inside one of `onLink`.
    static func keyedByFullAddress(_ b: [UInt8], onLink: [Prefix]) -> Bool {
        guard b.count == 16 else { return false }
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }     // fe80::/10
        if (b[0] & 0xfe) == 0xfc { return true }                     // fc00::/7
        if b.dropLast().allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }   // ::1
        return onLink.contains { $0.length >= shortestPrefix && $0.contains(b) }
    }

    // MARK: - This Mac's interfaces

    /// Read at most this often: an interface's prefix changes when the Mac
    /// joins another network, not between two requests.
    static let refresh: TimeInterval = 30

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (at: Date, prefixes: [Prefix])?

    /// The global and unique-local IPv6 prefixes on this Mac's interfaces
    /// that are up, cached for `refresh` seconds. `getifaddrs` reads kernel
    /// state and does not wait on anything, so this is safe on any thread.
    static func prefixes(now: Date = Date()) -> [Prefix] {
        lock.withLock {
            if let cached, now.timeIntervalSince(cached.at) < refresh, now >= cached.at {
                return cached.prefixes
            }
            let read = readInterfaces()
            cached = (now, read)
            return read
        }
    }

    private static func readInterfaces() -> [Prefix] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [Prefix] = []
        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let current = node {
            defer { node = current.pointee.ifa_next }
            let ifa = current.pointee
            guard (ifa.ifa_flags & UInt32(IFF_UP)) != 0,
                  let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET6),
                  let mask = ifa.ifa_netmask else { continue }
            let address = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { [UInt8]($0) }
            }
            let maskBytes = mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { [UInt8]($0) }
            }
            let length = maskBytes.reduce(0) { $0 + $1.nonzeroBitCount }
            let prefix = Prefix(bytes: address, length: length)
            if !out.contains(prefix) { out.append(prefix) }
        }
        return out
    }
}
