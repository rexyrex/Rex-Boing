import Foundation
import IOKit

/// Reads the SoC's on-die thermal sensors through `IOHIDEventSystemClient`.
///
/// Apple silicon does not expose per-core temperatures through the documented
/// SMC key space the way Intel Macs did; the sensors live behind HID services
/// on usage page `0xff00`. That API is not in any public header, so it is bound
/// at runtime via `dlsym` against IOKit. Every call site treats a `nil` here as
/// "this Mac has no readable sensors" and the UI degrades cleanly.
final class HIDSensorReader {
    private typealias ClientRef = CFTypeRef
    private typealias ServiceRef = CFTypeRef

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef?, CFDictionary?) -> Void
    private typealias CopyServicesFn = @convention(c) (CFTypeRef?) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef?, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef?, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatFn = @convention(c) (CFTypeRef?, Int32) -> Double

    /// `kIOHIDEventTypeTemperature`
    private static let temperatureEventType: Int64 = 15
    private static let usagePageAppleVendor = 0xff00
    private static let usageTemperatureSensor = 5

    private let setMatching: SetMatchingFn
    private let copyServices: CopyServicesFn
    private let copyProperty: CopyPropertyFn
    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn

    private let client: ClientRef
    private var services: [ServiceRef] = []
    /// Names repeat across services, so each gets a stable disambiguated key.
    private var keys: [String] = []

    init?() {
        guard let handle = dlopen(
            "/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        guard
            let create = symbol("IOHIDEventSystemClientCreate", as: CreateFn.self),
            let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self),
            let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self),
            let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self),
            let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEventFn.self),
            let getFloat = symbol("IOHIDEventGetFloatValue", as: GetFloatFn.self),
            let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }

        self.setMatching = setMatching
        self.copyServices = copyServices
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.getFloat = getFloat
        self.client = client

        guard discoverServices(), !services.isEmpty else { return nil }
    }

    private func discoverServices() -> Bool {
        let matching: [String: Any] = [
            "PrimaryUsagePage": Self.usagePageAppleVendor,
            "PrimaryUsage": Self.usageTemperatureSensor,
        ]
        // The SPI returns nothing; a failed match simply yields no services,
        // which the caller's empty check already treats as "no sensors".
        setMatching(client, matching as CFDictionary)
        guard let array = copyServices(client)?.takeRetainedValue() as? [ServiceRef] else {
            return false
        }

        services = array
        var occurrences: [String: Int] = [:]
        keys = array.map { service in
            let name = (copyProperty(service, "Product" as CFString)?
                .takeRetainedValue() as? String) ?? "Sensor"
            let index = occurrences[name, default: 0]
            occurrences[name] = index + 1
            return index == 0 ? name : "\(name) \(index + 1)"
        }
        return true
    }

    /// Returns every sensor currently reporting a plausible temperature.
    /// Sensors that are powered down report 0 or NaN and are dropped.
    func read() -> [(key: String, celsius: Double)] {
        var readings: [(String, Double)] = []
        readings.reserveCapacity(services.count)

        let field = Int32(truncatingIfNeeded: Self.temperatureEventType << 16)
        for (index, service) in services.enumerated() {
            guard let event = copyEvent(service, Self.temperatureEventType, 0, 0)?
                .takeRetainedValue() else { continue }
            let value = getFloat(event, field)
            guard value.isFinite, value > 0, value < 150 else { continue }
            readings.append((keys[index], value))
        }
        return readings
    }
}
