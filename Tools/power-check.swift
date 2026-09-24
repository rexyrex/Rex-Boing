import Foundation

// Drives `EnergyMeter` — the part of the IOReport sampler that turns a
// cumulative energy counter into watts — through synthetic timelines, so the
// behaviours that only show up on particular chips and OS releases are pinned
// down on any Mac, CI included.
//
//   swiftc -O -framework IOKit -o /tmp/power-check Tools/power-check.swift \
//     RexBoing/Metrics/Snapshot.swift RexBoing/Metrics/Format.swift \
//     RexBoing/Metrics/Samplers/IOReportSampler.swift
//   /tmp/power-check
@main
enum PowerCheck {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if condition {
            print("PASS  \(message)")
        } else {
            failures += 1
            print("FAIL  \(message)")
        }
    }

    static func close(_ value: Double?, _ expected: Double, within tolerance: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) <= tolerance
    }

    /// A counter accruing `watts` continuously, published every `period`
    /// seconds starting at `phase`, read every `readEvery` seconds for
    /// `duration`. Returns what the meter said after each read.
    static func run(
        watts: Double, period: Double, phase: Double = 0, readEvery: Double,
        duration: Double, stamped: Bool = true, startAt: Double = 1_000
    ) -> [Double?] {
        var meter = EnergyMeter()
        var outputs: [Double?] = []
        var t = 0.0
        while t <= duration {
            // The newest publication at or before this read.
            let published = max(0, ((t - phase) / period).rounded(.down)) * period + phase
            let at = t < phase ? 0 : published
            meter.observe(
                EnergyMeter.Reading(
                    joules: watts * at, stamp: stamped ? startAt + at : nil),
                at: startAt + t)
            outputs.append(meter.watts)
            t += readEvery
        }
        return outputs
    }

    static func main() {
        // Counters that advance on every read — macOS up to 26, every chip.
        let legacy = run(watts: 5, period: 1, readEvery: 1, duration: 20)
        check(legacy.dropFirst(2).allSatisfy { close($0, 5, within: 1e-9) },
              "every-read counters report the true draw on every sample")

        // M5 Max on macOS 27: mJ channels publish every ~2.1 s. Read once a
        // second, the old per-window arithmetic alternated 0 W and ~2x.
        let batched = run(watts: 17, period: 2.1, phase: 0.4, readEvery: 1, duration: 60)
        let settled = batched.dropFirst(4)
        check(settled.allSatisfy { close($0, 17, within: 1e-6) },
              "batched publications report the true draw on every read, never 0 or 2x")
        check(settled.allSatisfy { $0 != nil },
              "batched publications hold the reading between batches instead of blanking")

        // The same batching read slower than it publishes: several batches
        // per read must add up, not be dropped.
        let slowReads = run(watts: 9, period: 2.1, readEvery: 5, duration: 60)
        check(slowReads.dropFirst(2).allSatisfy { close($0, 9, within: 1e-6) },
              "several publications inside one read are metered together")

        // Where the driver's stamp is unreadable the meter times publications
        // by when it saw them: approximate against batches, but never blank
        // and never wildly off.
        let unstamped = run(
            watts: 17, period: 2.1, phase: 0.4, readEvery: 1, duration: 60, stamped: false)
        let unstampedSettled = unstamped.dropFirst(4).compactMap { $0 }
        check(unstampedSettled.count == unstamped.count - 4,
              "unstamped batches still hold a reading between publications")
        check(unstampedSettled.allSatisfy { $0 > 17 * 0.6 && $0 < 17 * 1.6 },
              "unstamped batches stay within one read's timing error of the truth")

        // M1 Pro on macOS 27: the CPU counter stops publishing altogether.
        var frozen = EnergyMeter()
        for t in stride(from: 0.0, through: 120, by: 1) {
            frozen.observe(EnergyMeter.Reading(joules: 132_649, stamp: 500), at: 1_000 + t)
        }
        check(frozen.watts == nil, "a counter that never publishes reports nothing")

        // ...and then publishes once, minutes of energy in one go. The mean
        // is real but it is not the present; withhold it.
        frozen.observe(EnergyMeter.Reading(joules: 132_649 + 900, stamp: 1_121), at: 1_121)
        check(frozen.watts == nil,
              "a publication spanning minutes is withheld rather than shown as current")

        // A block that stops publishing is let go after the hold limit.
        var stopping = EnergyMeter()
        stopping.observe(EnergyMeter.Reading(joules: 0, stamp: 0), at: 0)
        stopping.observe(EnergyMeter.Reading(joules: 4, stamp: 1), at: 1)
        check(close(stopping.watts, 4, within: 1e-9), "a fresh publication is reported")
        stopping.observe(EnergyMeter.Reading(joules: 4, stamp: 1), at: 1 + EnergyMeter.holdLimit - 0.5)
        check(close(stopping.watts, 4, within: 1e-9), "a reading is held inside the hold limit")
        stopping.observe(EnergyMeter.Reading(joules: 4, stamp: 1), at: 1 + EnergyMeter.holdLimit + 0.5)
        check(stopping.watts == nil, "a reading is dropped past the hold limit")

        // Something that looks like a stamp but does not move while the
        // counter does is not a publication time. The meter must notice and
        // fall back rather than wait forever for a "publication".
        var stuckStamp = EnergyMeter()
        for t in stride(from: 0.0, through: 10, by: 1) {
            stuckStamp.observe(EnergyMeter.Reading(joules: 3 * t, stamp: 42), at: 100 + t)
        }
        check(!stuckStamp.trustsStamps, "a stamp that does not follow the counter is distrusted")
        check(close(stuckStamp.watts, 3, within: 1e-9),
              "after distrusting the stamp the meter still reports the draw")

        // A driver reload resets the counter. No negative and no
        // lifetime-sized reading may come out of it.
        var reset = EnergyMeter()
        reset.observe(EnergyMeter.Reading(joules: 5_000, stamp: 10), at: 10)
        reset.observe(EnergyMeter.Reading(joules: 5_002, stamp: 11), at: 11)
        reset.observe(EnergyMeter.Reading(joules: 1, stamp: 12), at: 12)
        check(reset.watts == nil, "a counter reset publishes nothing across it")
        reset.observe(EnergyMeter.Reading(joules: 3, stamp: 13), at: 13)
        check(close(reset.watts, 2, within: 1e-9), "metering resumes cleanly after a reset")

        // Across a sleep the engine asks for a rebaseline; nothing measured
        // across the gap may surface afterwards.
        var slept = EnergyMeter()
        slept.observe(EnergyMeter.Reading(joules: 0, stamp: 0), at: 0)
        slept.observe(EnergyMeter.Reading(joules: 6, stamp: 2), at: 2)
        slept.rebaseline(to: EnergyMeter.Reading(joules: 50, stamp: 20), at: 20)
        check(slept.watts == nil, "a rebaseline forgets the held reading")
        slept.observe(EnergyMeter.Reading(joules: 50, stamp: 20), at: 21)
        check(slept.watts == nil, "no reading until the first publication after a rebaseline")
        slept.observe(EnergyMeter.Reading(joules: 58, stamp: 22), at: 22)
        check(close(slept.watts, 4, within: 1e-9), "the first post-rebaseline window is its own")

        // Two publications a sliver apart are folded into the next span
        // rather than divided by the sliver.
        var sliver = EnergyMeter()
        sliver.observe(EnergyMeter.Reading(joules: 0, stamp: 0), at: 0)
        sliver.observe(EnergyMeter.Reading(joules: 2, stamp: 1), at: 1)
        sliver.observe(EnergyMeter.Reading(joules: 2.02, stamp: 1.01), at: 1.5)
        check(close(sliver.watts, 2, within: 1e-9), "a sliver-length span is not divided")
        sliver.observe(EnergyMeter.Reading(joules: 4, stamp: 2), at: 2)
        check(close(sliver.watts, 2, within: 1e-9), "the folded sliver lands in the next span")

        // An idle block publishing zero energy is a real zero, not a gap.
        var idle = EnergyMeter()
        for t in stride(from: 0.0, through: 5, by: 1) {
            idle.observe(EnergyMeter.Reading(joules: 7, stamp: t), at: t)
        }
        check(idle.watts == 0, "a block that publishes no energy reads zero, not nothing")

        // Summing a block's channels: the later stamp stands for both, and an
        // unstamped channel unstamps the sum.
        let sum = EnergyMeter.Reading(joules: 1, stamp: 3) + EnergyMeter.Reading(joules: 2, stamp: 5)
        check(sum.joules == 3 && sum.stamp == 5, "summed channels add and keep the later stamp")
        let mixed = EnergyMeter.Reading(joules: 1, stamp: 3) + EnergyMeter.Reading(joules: 2, stamp: nil)
        check(mixed.stamp == nil, "an unstamped channel makes the sum unstamped")

        print(failures == 0 ? "\nPASS" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
