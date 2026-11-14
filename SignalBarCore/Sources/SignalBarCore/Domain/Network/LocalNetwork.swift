import Darwin
import Foundation
import SystemConfiguration

/// One IPv4 address this Mac holds, on the interface that holds it.
public struct LocalInterface: Sendable, Equatable {
    public let name: String
    public let address: IPv4Address
    public let network: IPv4CIDR
    /// `nil` when macOS doesn't report one for the interface.
    public let mac: MACAddress?
}

/// What this Mac's own network looks like right now: its interfaces and
/// default gateway. Read fresh every time; nothing is cached, because a
/// laptop changes networks under the app without warning.
public enum LocalNetworkContext {
    /// Interfaces that are up and carry an IPv4 address, minus loopback and
    /// point-to-point links (VPN tunnels), whose "subnet" is a single peer.
    public static func interfaces() -> [LocalInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }

        var macs: [String: MACAddress] = [:]
        var found: [(name: String, address: IPv4Address, netmask: IPv4Address)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            let flags = Int32(entry.ifa_flags)
            guard let sockaddr = entry.ifa_addr,
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0
            else { continue }
            let name = String(cString: entry.ifa_name)

            switch Int32(sockaddr.pointee.sa_family) {
            case AF_LINK:
                sockaddr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link in
                    let length = Int(link.pointee.sdl_alen)
                    guard length == 6 else { return }
                    let start = UnsafeRawPointer(link).advanced(by: 8 + Int(link.pointee.sdl_nlen))
                    let bytes = UnsafeRawBufferPointer(start: start, count: 6)
                    if let mac = MACAddress(bytes: bytes), !mac.isZero { macs[name] = mac }
                }
            case AF_INET:
                guard let maskPointer = entry.ifa_netmask else { continue }
                let address = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                let mask = maskPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                found.append((name, IPv4Address(UInt32(bigEndian: address)), IPv4Address(UInt32(bigEndian: mask))))
            default:
                continue
            }
        }

        return found.compactMap { item in
            guard let network = IPv4CIDR(address: item.address, netmask: item.netmask), network.prefixLength < 32 else { return nil }
            return LocalInterface(name: item.name, address: item.address, network: network, mac: macs[item.name])
        }
    }

    /// The router of the primary network service, as System Settings shows it.
    public static func defaultGateway() -> IPv4Address? {
        guard let store = SCDynamicStoreCreate(nil, "SignalBar" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let router = global["Router"] as? String
        else { return nil }
        return IPv4Address(router)
    }
}
