import CoreWLAN
import Foundation

/// The Wi-Fi link as the radio sees it. The network's name and the access
/// point's address are only there once the user has given the app Location
/// access: macOS treats them as a way to tell where the Mac is.
public struct WiFiStatus: Sendable, Equatable {
    public enum Band: String, Sendable { case ghz2, ghz5, ghz6 }

    public var interfaceName: String
    public var ssid: String?
    public var bssid: String?
    public var rssi: Int
    public var noise: Int
    public var channel: Int?
    public var band: Band?
    public var channelWidthMHz: Int?
    public var transmitRateMbps: Double
    /// "802.11ax" and so on.
    public var standard: String?
    /// "Wi-Fi 6" and so on.
    public var generation: String?
    public var security: String?

    public var snr: Int { rssi - noise }

    public enum Quality: String, Sendable { case excellent, good, fair, poor }

    /// The usual reading of signal-to-noise for a data link: 40 dB and more
    /// is as good as Wi-Fi gets, under 15 dB drops and retries.
    public var quality: Quality {
        switch snr {
        case 40...: .excellent
        case 25..<40: .good
        case 15..<25: .fair
        default: .poor
        }
    }

    /// `nil` when the Mac has no Wi-Fi or it is off.
    public static func read() -> WiFiStatus? {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn(), let name = interface.interfaceName else { return nil }
        let channel = interface.wlanChannel()
        let rssi = interface.rssiValue()
        // Associated to nothing: the radio reports zeros.
        guard rssi != 0 else { return nil }
        let phy = phyNames(interface.activePHYMode())
        let band = channel.flatMap { bandOf($0.channelBand) }
        return WiFiStatus(
            interfaceName: name,
            ssid: interface.ssid(),
            bssid: interface.bssid(),
            rssi: rssi,
            noise: interface.noiseMeasurement(),
            channel: channel.map(\.channelNumber),
            band: band,
            channelWidthMHz: channel.flatMap { width($0.channelWidth) },
            transmitRateMbps: interface.transmitRate(),
            standard: phy?.standard,
            // 802.11ax on 6 GHz is sold as its own generation.
            generation: phy?.generation == "Wi-Fi 6" && band == .ghz6 ? "Wi-Fi 6E" : phy?.generation,
            security: securityName(interface.security())
        )
    }

    private static func bandOf(_ band: CWChannelBand) -> Band? {
        switch band {
        case .band2GHz: .ghz2
        case .band5GHz: .ghz5
        case .band6GHz: .ghz6
        default: nil
        }
    }

    private static func width(_ width: CWChannelWidth) -> Int? {
        switch width {
        case .width20MHz: 20
        case .width40MHz: 40
        case .width80MHz: 80
        case .width160MHz: 160
        default: nil
        }
    }

    static func phyNames(_ mode: CWPHYMode) -> (standard: String, generation: String?)? {
        switch mode.rawValue {
        case 1: ("802.11a", nil)
        case 2: ("802.11b", nil)
        case 3: ("802.11g", nil)
        case 4: ("802.11n", "Wi-Fi 4")
        case 5: ("802.11ac", "Wi-Fi 5")
        case 6: ("802.11ax", "Wi-Fi 6")
        case 7: ("802.11be", "Wi-Fi 7")
        default: nil
        }
    }

    static func securityName(_ security: CWSecurity) -> String? {
        switch security {
        case .none: "Open"
        case .WEP, .dynamicWEP: "WEP"
        case .wpaPersonal, .wpaPersonalMixed: "WPA Personal"
        case .wpa2Personal, .personal: "WPA2 Personal"
        case .wpaEnterprise, .wpaEnterpriseMixed: "WPA Enterprise"
        case .wpa2Enterprise, .enterprise: "WPA2 Enterprise"
        case .wpa3Personal: "WPA3 Personal"
        case .wpa3Transition: "WPA2/WPA3 Personal"
        case .wpa3Enterprise: "WPA3 Enterprise"
        case .OWE, .oweTransition: "Enhanced Open"
        default: nil
        }
    }
}
