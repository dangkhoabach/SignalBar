import Darwin
import Foundation
import SystemConfiguration

/// One IPv6 address on an interface, as macOS uses it.
public struct IPv6InterfaceAddress: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case linkLocal
        /// The address that stays the same on this network.
        case stable
        /// A privacy address (RFC 8981): what outgoing connections use, replaced every day.
        case temporary
    }

    public let address: String
    public let prefixLength: Int
    public let kind: Kind
}

/// What the DHCP server told this Mac when it joined.
public struct DHCPLeaseInfo: Sendable, Equatable {
    public var server: String?
    public var leaseStart: Date?
    public var leaseEnd: Date?
    public var domainName: String?
    public var offeredDNS: [String] = []
}

public struct InterfaceDetails: Sendable, Equatable {
    public var name: String
    /// The name System Settings shows, such as "Wi-Fi".
    public var serviceName: String?
    public var ipv4: IPv4Address?
    public var ipv4Prefix: Int?
    public var router: String?
    public var ipv6: [IPv6InterfaceAddress] = []
    public var ipv6Router: String?
    public var mac: MACAddress?
    public var mtu: Int?
    /// What the driver reports as the link's speed; Wi-Fi's real rate comes from `WiFiStatus`.
    public var linkSpeedBitsPerSecond: UInt64?
    public var dhcp: DHCPLeaseInfo?

    public var subnetMask: IPv4Address? {
        ipv4Prefix.map { IPv4Address(IPv4CIDR(address: IPv4Address(0), prefixLength: $0).mask) }
    }
}

public struct DNSSettings: Sendable, Equatable {
    public enum Source: String, Sendable {
        /// Typed into System Settings.
        case manual
        /// Pushed by a VPN.
        case vpn
        /// From DHCP or router advertisements.
        case network
    }

    /// Names under these domains go to these servers only (split DNS, often from a VPN).
    public struct Scoped: Sendable, Equatable {
        public var domains: [String]
        public var servers: [String]
    }

    public var servers: [String] = []
    public var source: Source = .network
    /// What the network handed out, shown when the user typed other servers over it.
    public var offeredByNetwork: [String] = []
    public var searchDomains: [String] = []
    public var scoped: [Scoped] = []
}

public struct ProxySettings: Sendable, Equatable {
    public var http: String?
    public var https: String?
    public var socks: String?
    public var autoConfigURL: String?
    public var autoDiscovery = false
    public var exceptions: [String] = []

    public var isActive: Bool {
        http != nil || https != nil || socks != nil || autoConfigURL != nil || autoDiscovery
    }
}

public struct VPNTunnel: Sendable, Equatable {
    public var name: String
    public var serviceName: String?
    public var addresses: [String]

    /// Tailscale hands every device an address in 100.64.0.0/10.
    public var looksLikeTailscale: Bool {
        addresses.contains { IPv4CIDR("100.64.0.0/10")!.contains(IPv4Address($0) ?? IPv4Address(0)) }
    }
}

/// Everything about this Mac's own connection that it can read without
/// asking anything on the network.
public struct LocalConnection: Sendable, Equatable {
    public var primary: InterfaceDetails?
    public var others: [InterfaceDetails] = []
    public var dns = DNSSettings()
    public var proxies = ProxySettings()
    public var tunnels: [VPNTunnel] = []
    /// The default route goes through a tunnel: all traffic, not just some networks, uses the VPN.
    public var vpnCarriesAllTraffic = false
}

/// Reads `LocalConnection` from getifaddrs, the System Configuration
/// dynamic store and CFNetwork's proxy settings. Read fresh every time.
public enum SystemNetworkReader {
    public static func read() -> LocalConnection {
        let links = linkAddresses()
        var state: [String: [String: Any]] = [:]
        if let store = SCDynamicStoreCreate(nil, "SignalBar" as CFString, nil, nil) {
            let patterns = ["State:/Network/Global/.*", "State:/Network/Service/.*", "Setup:/Network/Service/[^/]+",
                            "Setup:/Network/Service/[^/]+/DNS", "State:/Network/Interface/[^/]+/IPv6"] as CFArray
            if let values = SCDynamicStoreCopyMultiple(store, nil, patterns) as? [String: Any] {
                state = values.compactMapValues { $0 as? [String: Any] }
            }
        }
        let proxies = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        return build(links: links, state: state, proxies: proxies)
    }

    /// The part of `read` that only interprets what was read, so it can be
    /// tested with recorded values.
    static func build(links: [LinkAddresses], state: [String: [String: Any]], proxies: [String: Any]) -> LocalConnection {
        let global4 = state["State:/Network/Global/IPv4"] ?? [:]
        let global6 = state["State:/Network/Global/IPv6"] ?? [:]
        let primaryName = global4["PrimaryInterface"] as? String ?? global6["PrimaryInterface"] as? String

        // Service ID by interface name, from each service's IPv4 or IPv6 state.
        var serviceOfInterface: [String: String] = [:]
        for (key, value) in state where key.hasPrefix("State:/Network/Service/") && (key.hasSuffix("/IPv4") || key.hasSuffix("/IPv6")) {
            if let name = value["InterfaceName"] as? String {
                serviceOfInterface[name] = serviceID(of: key)
            }
        }
        func details(_ link: LinkAddresses) -> InterfaceDetails {
            let service = serviceOfInterface[link.name]
            var item = InterfaceDetails(name: link.name)
            item.serviceName = service.flatMap { state["Setup:/Network/Service/\($0)"]?["UserDefinedName"] as? String }
            item.ipv4 = link.ipv4.first?.address
            item.ipv4Prefix = link.ipv4.first?.prefixLength
            item.ipv6 = ipv6Addresses(link, flags: state["State:/Network/Interface/\(link.name)/IPv6"])
            item.mac = link.mac
            item.mtu = link.mtu
            item.linkSpeedBitsPerSecond = link.baudRate > 0 ? link.baudRate : nil
            if let service {
                item.dhcp = state["State:/Network/Service/\(service)/DHCP"].map(dhcpInfo)
                item.router = state["State:/Network/Service/\(service)/IPv4"]?["Router"] as? String
                item.ipv6Router = state["State:/Network/Service/\(service)/IPv6"]?["Router"] as? String
            }
            if link.name == primaryName {
                item.router = item.router ?? global4["Router"] as? String
                item.ipv6Router = item.ipv6Router ?? global6["Router"] as? String
            }
            return item
        }

        var connection = LocalConnection()
        for link in links {
            if link.isPointToPoint {
                let addresses = link.ipv4.map(\.address.description) + link.ipv6.map(\.address).filter { !$0.lowercased().hasPrefix("fe80") }
                // Apple keeps several tunnels up for its own services; they hold no address.
                guard !addresses.isEmpty, !link.name.hasPrefix("gif"), !link.name.hasPrefix("stf") else { continue }
                let serviceName = serviceOfInterface[link.name].flatMap { state["Setup:/Network/Service/\($0)"]?["UserDefinedName"] as? String }
                connection.tunnels.append(VPNTunnel(name: link.name, serviceName: serviceName, addresses: addresses))
            } else if link.name == primaryName {
                connection.primary = details(link)
            } else if !link.ipv4.isEmpty {
                connection.others.append(details(link))
            }
        }
        if let primaryName, connection.tunnels.contains(where: { $0.name == primaryName }) {
            connection.vpnCarriesAllTraffic = true
            // The tunnel runs over a real link; that link is what this Mac is connected with.
            if let index = connection.others.firstIndex(where: { $0.router != nil }) ?? connection.others.indices.first {
                connection.primary = connection.others.remove(at: index)
            }
        }
        connection.dns = dnsSettings(state: state, primaryName: primaryName, serviceOfInterface: serviceOfInterface,
                                     tunnelNames: Set(connection.tunnels.map(\.name)))
        connection.proxies = proxySettings(proxies)
        return connection
    }

    private static func serviceID(of key: String) -> String {
        let parts = key.split(separator: "/")
        return parts.count > 3 ? String(parts[3]) : ""
    }

    /// Hides deprecated privacy addresses: they stay on the interface for
    /// existing connections but nothing new uses them.
    static func ipv6Addresses(_ link: LinkAddresses, flags: [String: Any]?) -> [IPv6InterfaceAddress] {
        let listed = flags?["Addresses"] as? [String] ?? []
        let listedFlags = flags?["Flags"] as? [Int] ?? []
        var flagOf: [String: Int] = [:]
        for (address, flag) in zip(listed, listedFlags) { flagOf[normalizedIPv6(address)] = flag }

        return link.ipv6.compactMap { entry in
            let flag = flagOf[normalizedIPv6(entry.address)] ?? 0
            if flag & 0x10 != 0 { return nil } // IN6_IFF_DEPRECATED
            let kind: IPv6InterfaceAddress.Kind = entry.address.lowercased().hasPrefix("fe80") ? .linkLocal
                : flag & 0x80 != 0 ? .temporary : .stable // IN6_IFF_TEMPORARY
            return IPv6InterfaceAddress(address: entry.address, prefixLength: entry.prefixLength, kind: kind)
        }
    }

    static func normalizedIPv6(_ text: String) -> String {
        let bare = text.split(separator: "%").first.map(String.init) ?? text
        var address = in6_addr()
        guard inet_pton(AF_INET6, bare, &address) == 1 else { return bare.lowercased() }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count))
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func dhcpInfo(_ values: [String: Any]) -> DHCPLeaseInfo {
        func data(_ option: Int) -> [UInt8]? { (values["Option_\(option)"] as? Data).map(Array.init) }
        func addresses(_ bytes: [UInt8]?) -> [String] {
            guard let bytes, bytes.count % 4 == 0 else { return [] }
            return stride(from: 0, to: bytes.count, by: 4).map { start in
                IPv4Address(bytes[start..<start + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }).description
            }
        }
        var info = DHCPLeaseInfo()
        info.server = addresses(data(54)).first
        info.offeredDNS = addresses(data(6))
        info.domainName = data(15).map { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }.flatMap { $0.isEmpty ? nil : $0 }
        info.leaseStart = values["LeaseStartTime"] as? Date
        info.leaseEnd = values["LeaseExpirationTime"] as? Date
        return info
    }

    static func dnsSettings(
        state: [String: [String: Any]], primaryName: String?, serviceOfInterface: [String: String], tunnelNames: Set<String>
    ) -> DNSSettings {
        let global = state["State:/Network/Global/DNS"] ?? [:]
        var dns = DNSSettings()
        dns.servers = global["ServerAddresses"] as? [String] ?? []
        dns.searchDomains = global["SearchDomains"] as? [String] ?? []

        let primaryService = primaryName.flatMap { serviceOfInterface[$0] }
        if let primaryService {
            dns.offeredByNetwork = state["State:/Network/Service/\(primaryService)/DNS"]?["ServerAddresses"] as? [String] ?? []
        }
        let typed = primaryService.flatMap { state["Setup:/Network/Service/\($0)/DNS"]?["ServerAddresses"] as? [String] } ?? []
        let tunnelServices = Set(tunnelNames.compactMap { serviceOfInterface[$0] })

        for (key, value) in state where key.hasPrefix("State:/Network/Service/") && key.hasSuffix("/DNS") {
            let servers = value["ServerAddresses"] as? [String] ?? []
            let domains = value["SupplementalMatchDomains"] as? [String] ?? []
            if !domains.isEmpty, !servers.isEmpty, domains != [""] {
                dns.scoped.append(DNSSettings.Scoped(domains: domains.filter { !$0.isEmpty }, servers: servers))
            } else if tunnelServices.contains(serviceID(of: key)), !servers.isEmpty, servers == dns.servers {
                dns.source = .vpn
            }
        }
        if dns.source != .vpn, !typed.isEmpty, typed == dns.servers { dns.source = .manual }
        if dns.source != .manual { dns.offeredByNetwork = [] }
        dns.scoped.sort { $0.domains.joined() < $1.domains.joined() }
        return dns
    }

    static func proxySettings(_ values: [String: Any]) -> ProxySettings {
        func endpoint(_ prefix: String) -> String? {
            guard (values["\(prefix)Enable"] as? Int) == 1, let host = values["\(prefix)Proxy"] as? String, !host.isEmpty else { return nil }
            return (values["\(prefix)Port"] as? Int).map { "\(host):\($0)" } ?? host
        }
        var proxies = ProxySettings()
        proxies.http = endpoint("HTTP")
        proxies.https = endpoint("HTTPS")
        proxies.socks = endpoint("SOCKS")
        if (values["ProxyAutoConfigEnable"] as? Int) == 1 {
            proxies.autoConfigURL = values["ProxyAutoConfigURLString"] as? String
        }
        proxies.autoDiscovery = (values["ProxyAutoDiscoveryEnable"] as? Int) == 1
        proxies.exceptions = values["ExceptionsList"] as? [String] ?? []
        return proxies
    }
}

/// The addresses and counters getifaddrs reports for one interface.
struct LinkAddresses: Sendable {
    var name: String
    var isPointToPoint = false
    var ipv4: [(address: IPv4Address, prefixLength: Int)] = []
    var ipv6: [(address: String, prefixLength: Int)] = []
    var mac: MACAddress?
    var mtu: Int?
    var baudRate: UInt64 = 0
    var bytesIn: UInt32 = 0
    var bytesOut: UInt32 = 0
}

/// Every interface that is up, except loopback.
func linkAddresses() -> [LinkAddresses] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let head else { return [] }
    defer { freeifaddrs(head) }

    var byName: [String: LinkAddresses] = [:]
    var order: [String] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = head
    while let entry = cursor?.pointee {
        defer { cursor = entry.ifa_next }
        let flags = Int32(entry.ifa_flags)
        guard let sockaddr = entry.ifa_addr, flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        let name = String(cString: entry.ifa_name)
        if byName[name] == nil {
            byName[name] = LinkAddresses(name: name, isPointToPoint: flags & IFF_POINTOPOINT != 0)
            order.append(name)
        }

        switch Int32(sockaddr.pointee.sa_family) {
        case AF_LINK:
            sockaddr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link in
                guard link.pointee.sdl_alen == 6 else { return }
                let start = UnsafeRawPointer(link).advanced(by: 8 + Int(link.pointee.sdl_nlen))
                if let mac = MACAddress(bytes: UnsafeRawBufferPointer(start: start, count: 6)), !mac.isZero {
                    byName[name]?.mac = mac
                }
            }
            if let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                byName[name]?.mtu = Int(data.ifi_mtu)
                byName[name]?.baudRate = UInt64(data.ifi_baudrate)
                byName[name]?.bytesIn = data.ifi_ibytes
                byName[name]?.bytesOut = data.ifi_obytes
            }
        case AF_INET:
            guard let mask = entry.ifa_netmask else { continue }
            let address = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let maskValue = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            byName[name]?.ipv4.append((IPv4Address(UInt32(bigEndian: address)), UInt32(bigEndian: maskValue).nonzeroBitCount))
        case AF_INET6:
            var address = sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count))
            let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let prefix = entry.ifa_netmask.map { mask in
                mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    withUnsafeBytes(of: pointer.pointee.sin6_addr) { $0.reduce(0) { $0 + $1.nonzeroBitCount } }
                }
            } ?? 64
            byName[name]?.ipv6.append((text, prefix))
        default:
            continue
        }
    }
    return order.compactMap { byName[$0] }
}

/// Bytes in and out of one interface since boot, for working out its current speed.
public struct InterfaceCounters: Sendable, Equatable {
    public let bytesIn: UInt32
    public let bytesOut: UInt32
    public let readAt: Date

    public static func read(interface name: String, at date: Date = Date()) -> InterfaceCounters? {
        linkAddresses().first { $0.name == name }.map { InterfaceCounters(bytesIn: $0.bytesIn, bytesOut: $0.bytesOut, readAt: date) }
    }

    /// Bits per second in and out between two reads. The counters are 32-bit
    /// and wrap after 4 GiB; unsigned subtraction makes one wrap come out right.
    public func rates(since earlier: InterfaceCounters) -> (inBitsPerSecond: Double, outBitsPerSecond: Double)? {
        let seconds = readAt.timeIntervalSince(earlier.readAt)
        guard seconds > 0 else { return nil }
        return (Double(bytesIn &- earlier.bytesIn) * 8 / seconds, Double(bytesOut &- earlier.bytesOut) * 8 / seconds)
    }
}
