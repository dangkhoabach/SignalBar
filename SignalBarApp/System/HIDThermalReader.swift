import SignalBarCore
import Foundation

/// Reads every thermal sensor the Mac exposes through the HID event system —
/// the interface Apple Silicon actually publishes temperatures on, where the
/// `SMCReader` key probing only ever finds one usable die sensor (and often
/// none at all on M-series, whose SMC no longer carries the classic `TC0P`
/// family).
///
/// The `IOHIDEventSystemClient` symbols are SPI: they're exported by IOKit
/// but absent from its headers, so they're resolved at runtime with `dlsym`
/// rather than linked. That is deliberate — if a future macOS drops them,
/// `init?` fails and `SystemStatsService` silently falls back to SMC, instead
/// of the app failing to launch with a missing-symbol error.
///
/// Same shape as `SMCReader`: a small IOKit wrapper owned by the app target,
/// producing `SignalBarCore` value types (`TemperatureReading`).
final class HIDThermalReader {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject?, CFDictionary?) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject?) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject?, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (AnyObject?, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias EventFloatValue = @convention(c) (AnyObject?, Int32) -> Double

    /// `kHIDPage_AppleVendor` / `kHIDUsage_AppleVendor_TemperatureSensor`.
    private static let appleVendorPage = 0xff00
    private static let temperatureSensorUsage = 5
    /// `kIOHIDEventTypeTemperature`, and the field selector derived from it
    /// the way `IOHIDEventFieldBase` does (`type << 16`).
    private static let temperatureEventType: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    /// The per-sensor service clients borrow this client's mach port, so it
    /// has to outlive them — hence held as a stored property, not a local.
    private let client: AnyObject
    private let copyEvent: CopyEvent
    private let eventFloatValue: EventFloatValue
    private let services: [AnyObject]
    /// Sensor names and categories resolved once at init: the product string
    /// of a service never changes, and re-reading it on every poll would mean
    /// 50+ extra IOKit property copies per sample.
    private let sensors: [(name: String, category: TemperatureReading.Category)]

    /// `false` when this Mac publishes no sensors on this interface (Intel
    /// Macs generally don't) — the caller should fall back to SMC.
    var hasSensors: Bool { !services.isEmpty }

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", as: CreateClient.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
              let eventFloatValue = symbol("IOHIDEventGetFloatValue", as: EventFloatValue.self),
              let createdClient = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }

        self.client = createdClient
        self.copyEvent = copyEvent
        self.eventFloatValue = eventFloatValue

        let matching: [String: Int] = [
            "PrimaryUsagePage": Self.appleVendorPage,
            "PrimaryUsage": Self.temperatureSensorUsage,
        ]
        _ = setMatching(createdClient, matching as CFDictionary)

        let found = (copyServices(createdClient)?.takeRetainedValue() as? [AnyObject]) ?? []
        self.services = found
        self.sensors = found.map { service in
            let name = (copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String) ?? "Sensor"
            return (name, TemperatureReading.category(forSensorNamed: name))
        }
    }

    /// One reading per sensor that currently reports a plausible value,
    /// hottest first. Unpopulated or sleeping sensors report 0 (or garbage),
    /// so anything outside 1–150°C is dropped rather than shown.
    func sample() -> [TemperatureReading] {
        var readings: [TemperatureReading] = []
        readings.reserveCapacity(services.count)
        for (index, service) in services.enumerated() {
            guard let event = copyEvent(service, Self.temperatureEventType, 0, 0)?.takeRetainedValue() else { continue }
            let celsius = eventFloatValue(event, Self.temperatureField)
            guard celsius > 1, celsius < 150 else { continue }
            let sensor = sensors[index]
            readings.append(TemperatureReading(
                name: sensor.name, celsius: celsius, category: sensor.category,
                // Service index, because product names repeat across sensors.
                id: "\(index)"
            ))
        }
        return readings.sorted { $0.celsius > $1.celsius }
    }
}
