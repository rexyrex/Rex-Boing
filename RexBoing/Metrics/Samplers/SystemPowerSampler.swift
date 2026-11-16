import Foundation

/// Whole-machine power draw from the SMC's system rails.
///
/// `IOReportSampler` covers the SoC blocks — CPU, GPU, Neural Engine, DRAM —
/// but nothing it publishes includes the display, SSD, fans, or the rest of
/// the board, and the battery-derived figure exists only while discharging.
/// Apple silicon publishes the roll-up that actually answers "what is this
/// machine drawing right now" as SMC key `PSTR` (system total power), next to
/// `PDTR` (draw at the DC-in port, charging and conversion loss included).
/// Both are instantaneous gauges rather than interval counters, so a read
/// stands on its own — no baseline, no delta, valid straight after a wake.
///
/// Some desktops carry `PSTR` and leave it at a flat 0 W (a Mac Studio,
/// Mac17,15, does). Everything such a Mac draws comes in through its one
/// input rail, which the SMC publishes as `PD0R`, so that stands in for the
/// total there.
final class SystemPowerSampler {
    struct Reading {
        var systemTotalWatts: Double?
        var dcInWatts: Double?
    }

    private let smc: SMCService

    /// A machine that is on draws real watts: a system rail at 0 W is a key
    /// the firmware never fills in, not a measurement.
    static let floorWatts = 0.1

    /// Fails where no system rail is present — Intel SMCs mostly do not carry
    /// `PSTR` — so the engine can skip the sampler entirely, the same contract
    /// `IOReportSampler` has.
    init?() {
        guard let smc = SMCService(),
              smc.watts(key: "PSTR") != nil || smc.watts(key: "PD0R") != nil else { return nil }
        self.smc = smc
    }

    func sample() -> Reading {
        Reading(
            systemTotalWatts: Self.total(system: smc.watts(key: "PSTR")) { smc.watts(key: "PD0R") },
            // The port rail reads a flat 0 W on battery, which is "unplugged",
            // not a wattage worth a tile.
            dcInWatts: smc.watts(key: "PDTR").flatMap { $0 > 0.01 ? $0 : nil })
    }

    /// The whole-machine figure: the system rail where it reads, else the
    /// input rail (read only then), else nothing — and `PowerMetrics` falls
    /// back to the battery's or the SoC package's figure rather than
    /// headlining 0 W.
    static func total(system: Double?, inputRail: () -> Double?) -> Double? {
        if let system, system > floorWatts { return system }
        if let input = inputRail(), input > floorWatts { return input }
        return nil
    }
}
