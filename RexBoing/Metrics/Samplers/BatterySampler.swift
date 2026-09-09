import Foundation
import IOKit
import IOKit.ps

/// Battery state, health and instantaneous draw.
///
/// `IOPowerSources` carries the user-facing values (charge, time remaining) and
/// the `AppleSmartBattery` IORegistry node carries the engineering ones (cycle
/// count, design capacity, cell temperature, amperage).
final class BatterySampler {
    func sample() -> BatteryMetrics {
        var metrics = BatteryMetrics()
        readPowerSources(into: &metrics)
        readSmartBattery(into: &metrics)
        metrics.adapterWatts = adapterWatts()
        return metrics
    }

    /// The charger's rated output, which is the ceiling the machine can draw
    /// from mains — useful next to package power when you want to know how much
    /// headroom is left.
    private func adapterWatts() -> Double? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?
            .takeRetainedValue() as? [String: Any] else { return nil }
        if let watts = details[kIOPSPowerAdapterWattsKey] as? Int, watts > 0 {
            return Double(watts)
        }
        // Some adapters publish volts and amps but no watts field.
        if let millivolts = details["Voltage"] as? Int,
           let milliamps = details["Current"] as? Int,
           millivolts > 0, milliamps > 0 {
            return Double(millivolts) / 1_000 * Double(milliamps) / 1_000
        }
        return nil
    }

    private func readPowerSources(into metrics: inout BatteryMetrics) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }

            metrics.present = true

            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                metrics.percentage = min(1, max(0, Double(current) / Double(maximum)))
            }

            metrics.isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            metrics.isPluggedIn =
                (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            metrics.condition = description[kIOPSBatteryHealthKey] as? String

            let remaining = metrics.isCharging
                ? description[kIOPSTimeToFullChargeKey] as? Int
                : description[kIOPSTimeToEmptyKey] as? Int
            if let remaining, remaining > 0 { metrics.timeRemainingMinutes = remaining }
        }
    }

    private func readSmartBattery(into metrics: inout BatteryMetrics) {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        func integer(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.intValue
        }

        metrics.present = true
        metrics.cycleCount = integer("CycleCount")
        metrics.designCapacity = integer("DesignCapacity")

        // Apple silicon reports `AppleRawMaxCapacity`; older units use `MaxCapacity`.
        metrics.maxCapacity = integer("AppleRawMaxCapacity") ?? integer("MaxCapacity")

        // Hundredths of a degree Celsius.
        if let raw = integer("Temperature") { metrics.celsius = Double(raw) / 100 }
        if let raw = integer("Voltage") { metrics.voltage = Double(raw) / 1_000 }

        // Amperage is signed: negative while discharging, positive when the
        // charger is pushing current back in.
        //
        // Only the discharging case is whole-machine draw. While charging the
        // same product is the power going *into* the cell, which says nothing
        // about what the machine is consuming — reporting it as "system power"
        // was simply wrong, so it is left nil and the row hides itself.
        if let raw = integer("Amperage"), let volts = metrics.voltage {
            let amps = Double(Int32(truncatingIfNeeded: raw)) / 1_000
            metrics.amperage = amps
            if amps < 0 {
                metrics.systemWatts = -amps * volts
            } else if amps > 0 {
                metrics.chargingWatts = amps * volts
            }
        }
    }
}
