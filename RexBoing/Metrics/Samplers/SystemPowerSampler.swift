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
final class SystemPowerSampler {
    struct Reading {
        var systemTotalWatts: Double?
        var dcInWatts: Double?
    }

    private let smc: SMCService

    /// Fails where the system rail is absent — Intel SMCs mostly do not carry
    /// `PSTR` — so the engine can skip the sampler entirely, the same contract
    /// `IOReportSampler` has.
    init?() {
        guard let smc = SMCService(), smc.watts(key: "PSTR") != nil else { return nil }
        self.smc = smc
    }

    func sample() -> Reading {
        Reading(
            systemTotalWatts: smc.watts(key: "PSTR"),
            // The port rail reads a flat 0 W on battery, which is "unplugged",
            // not a wattage worth a tile.
            dcInWatts: smc.watts(key: "PDTR").flatMap { $0 > 0.01 ? $0 : nil })
    }
}
