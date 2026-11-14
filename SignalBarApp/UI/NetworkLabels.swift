import SignalBarCore
import SwiftUI

// Display names and colours for the Network feature's values, kept in one
// place so the Devices table, the detail page and the menu bar agree.

extension NetworkDeviceState {
    var label: LocalizedStringKey {
        switch self {
        case .online: "Online"
        case .offline: "Offline"
        case .unknown: "Not seen"
        }
    }

    var color: Color {
        switch self {
        case .online: .green
        case .offline: .red
        case .unknown: .secondary
        }
    }
}

extension NetworkDeviceType {
    var label: LocalizedStringKey {
        switch self {
        case .unknown: "Unknown"
        case .router: "Router"
        case .networkSwitch: "Switch"
        case .accessPoint: "Access point"
        case .computer: "Computer"
        case .server: "Server"
        case .phone: "Phone"
        case .tablet: "Tablet"
        case .printer: "Printer"
        case .tv: "TV"
        case .camera: "Camera"
        case .iot: "Smart device"
        case .other: "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .unknown: "questionmark.circle"
        case .router: "wifi.router"
        case .networkSwitch: "switch.2"
        case .accessPoint: "antenna.radiowaves.left.and.right"
        case .computer: "desktopcomputer"
        case .server: "server.rack"
        case .phone: "iphone"
        case .tablet: "ipad"
        case .printer: "printer"
        case .tv: "tv"
        case .camera: "web.camera"
        case .iot: "lightbulb"
        case .other: "shippingbox"
        }
    }
}

extension NetworkObservationSource {
    var label: LocalizedStringKey {
        switch self {
        case .arpLocal: "ARP from this Mac"
        case .icmp: "Ping"
        case .tcp: "TCP"
        case .arpSNMP: "Router ARP table (SNMP)"
        case .fdbSNMP: "Switch MAC table (SNMP)"
        case .dhcp: "DHCP lease"
        case .mdns: "Bonjour (mDNS)"
        case .reverseDNS: "Reverse DNS"
        case .manual: "Entered by hand"
        case .thisMac: "This Mac"
        }
    }
}

extension NetworkEventKind {
    var label: LocalizedStringKey {
        switch self {
        case .discovered: "First seen"
        case .online: "Back online"
        case .offline: "Went offline"
        case .ipChanged: "Address changed"
        case .ipOwnerChanged: "Took over the address"
        case .conflict: "IP conflict"
        case .merged: "Merged with another device"
        case .sourceFailed: "Source can't be read"
        case .sourceRecovered: "Source can be read again"
        case .portOpened: "Port opened"
        case .portClosed: "Port closed"
        }
    }

    var systemImage: String {
        switch self {
        case .discovered: "sparkles"
        case .online: "arrow.up.circle"
        case .offline: "arrow.down.circle"
        case .ipChanged, .ipOwnerChanged: "arrow.left.arrow.right"
        case .conflict: "exclamationmark.triangle"
        case .merged: "arrow.triangle.merge"
        case .sourceFailed: "xmark.octagon"
        case .sourceRecovered: "checkmark.circle"
        case .portOpened: "lock.open"
        case .portClosed: "lock"
        }
    }
}

extension NetworkSourceKind {
    var label: LocalizedStringKey {
        switch self {
        case .snmp: "SNMP device"
        case .dhcpSSH: "DHCP server over SSH"
        case .dhcpMikroTik: "MikroTik router"
        case .dhcpImport: "Imported leases"
        }
    }

    var systemImage: String {
        switch self {
        case .snmp: "switch.2"
        case .dhcpSSH: "terminal"
        case .dhcpMikroTik: "wifi.router"
        case .dhcpImport: "doc.text"
        }
    }
}

extension NetworkScanStatus {
    var label: LocalizedStringKey {
        switch self {
        case .running: "Scanning…"
        case .completed: "Scanned"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        case .localNetworkDenied: "Local Network access is off"
        case .noRoute: "No route from this Mac"
        }
    }
}

extension DHCPLeaseFormat {
    var label: LocalizedStringKey {
        switch self {
        case .dnsmasq: "dnsmasq (OpenWrt, Pi-hole)"
        case .iscDhcpd: "ISC dhcpd (pfSense)"
        case .kea: "Kea"
        case .csv: "CSV"
        }
    }

    /// Where the format's server usually keeps its leases.
    var defaultPath: String {
        switch self {
        case .dnsmasq: "/var/lib/misc/dnsmasq.leases"
        case .iscDhcpd: "/var/lib/dhcp/dhcpd.leases"
        case .kea: "/var/lib/kea/kea-leases4.csv"
        case .csv: ""
        }
    }
}

extension NetworkViewModel.AddressState {
    var label: LocalizedStringKey {
        switch self {
        case .used: "In use"
        case .assigned: "Assigned"
        case .reserved: "Reserved"
        case .conflict: "Conflict"
        case .free: "Free"
        case .unknown: "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .used: .green
        case .assigned: .blue
        case .reserved: .purple
        case .conflict: .red
        case .free: .gray.opacity(0.35)
        case .unknown: .gray.opacity(0.12)
        }
    }
}

/// The coloured dot and label used for a device's state everywhere.
struct NetworkStatusLabel: View {
    let row: NetworkDeviceRow

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            if row.hasConflict {
                Text("Conflict")
            } else if row.isStale {
                Text("Stale")
            } else {
                Text(row.device.state.label)
            }
        }
    }

    private var color: Color {
        if row.hasConflict { return .orange }
        if row.isStale { return .yellow }
        return row.device.state.color
    }
}

/// A number with a caption, for the summary strips.
struct NetworkStatChip: View {
    let title: LocalizedStringKey
    let value: Int
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number).font(.title2.weight(.semibold)).foregroundStyle(tint).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 70, alignment: .leading)
    }
}

/// Bits per second, the way network gear shows them.
func formatBitRate(_ bps: Double?) -> String {
    guard let bps else { return "—" }
    let units = ["bps", "Kbps", "Mbps", "Gbps", "Tbps"]
    var value = bps
    var unit = 0
    while value >= 1000, unit < units.count - 1 {
        value /= 1000
        unit += 1
    }
    return unit == 0 ? "\(Int(value)) \(units[unit])" : String(format: "%.1f %@", value, units[unit])
}
