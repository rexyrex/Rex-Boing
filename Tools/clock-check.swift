import Foundation
import Combine

// swiftc -O -o /tmp/rexboing-clock-check RexBoing/Metrics/Snapshot.swift \
//   RexBoing/Metrics/Format.swift \
//   RexBoing/Metrics/History.swift RexBoing/Metrics/MinuteHistory.swift \
//   RexBoing/Metrics/ProcessHistory.swift \
//   RexBoing/Metrics/UsageLedger.swift Tools/clock-check.swift
@main
struct ClockCheck {
    @MainActor static func main() {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL")  \(message)")
            if !condition { failures += 1 }
        }
        let base = Date(timeIntervalSince1970: 1_700_000_040)
        let history = ProcessHistory()
        func record(_ offset: Double, interval: Double = 1) {
            var snapshot = Snapshot()
            snapshot.processes.sampledAt = base.addingTimeInterval(offset)
            snapshot.processes.interval = interval
            history.record(snapshot)
        }
        record(10)
        record(20)
        record(30)
        record(15)
        check(history.samples.map(\.timestamp) == [10.0, 15].map { base.addingTimeInterval($0) },
              "clock rollback replaces overlapping history and retains the first valid sample")
        record(16)
        check(history.nearest(to: base.addingTimeInterval(15))?.sample.timestamp == base.addingTimeInterval(15),
              "nearest lookup finds the correct post-rollback sample")
        record(16)
        check(history.samples.count == 3, "repeated snapshots are not recorded twice")
        record(12, interval: 0)
        record(13)
        check(history.samples.map(\.timestamp) == [10.0, 13].map { base.addingTimeInterval($0) },
              "rollback resync drops future samples without recording invalid rates")

        let ledger = UsageLedger()
        var work = AppWorkDelta(attribution: AppAttribution(
            key: "app:test", displayName: "Test", bundlePath: nil, executablePath: nil))
        work.cpuNanos = 100
        ledger.record([work], endingAt: base.addingTimeInterval(10), interval: 10)
        ledger.record([], endingAt: base.addingTimeInterval(70), interval: 10)
        ledger.record([work], endingAt: base.addingTimeInterval(20), interval: 10)
        for _ in 0..<2 {
            let report = ledger.report(window: 300, now: base.addingTimeInterval(25))
            check(report.rows.first?.totals.cpuNanos == 200 && report.coveredSeconds == 20,
                  "revisited minute includes both visits, including cached queries")
        }
        ledger.record([], endingAt: base.addingTimeInterval(80), interval: 10)
        let report = ledger.report(window: 300, now: base.addingTimeInterval(85))
        check(report.rows.first?.totals.cpuNanos == 200 && report.coveredSeconds == 40,
              "rolling forward preserves totals and coverage without double counting")

        // The per-minute tier, fed what the graph rings are fed.
        var minutes = MinuteHistory()
        var rings = MetricsHistory()
        let minuteStart = Date(timeIntervalSince1970: 1_700_000_040) // on a minute boundary
        for second in 0..<180 where !(60..<90).contains(second) {
            var sample = Snapshot()
            sample.timestamp = minuteStart.addingTimeInterval(Double(second))
            sample.cpu.total = Double(second % 60) / 60
            // The third minute has no temperature source at all.
            sample.thermal.cpuCelsius = second < 120 ? 50 + Double(second % 7) : nil
            minutes.record(sample)
            rings.record(sample)
        }
        let cpuMinutes = minutes.buckets(.cpu, from: minuteStart, through: minuteStart.addingTimeInterval(179))
        check(cpuMinutes.map(\.count) == [60, 30, 60], "one bucket per minute, counting only the seconds sampled")
        let firstMinute = rings.cpu.values.prefix(60).reduce(0, +) / 60
        check(abs((cpuMinutes.first?.mean ?? -1) - firstMinute) < 1e-12,
              "a minute's mean is the exact mean of the samples the rings hold for it")
        check(cpuMinutes.first?.minimum == 0 && abs((cpuMinutes.first?.maximum ?? 0) - 59.0 / 60) < 1e-6,
              "a minute keeps its extremes")
        check(minutes.buckets(.cpuTemp, from: minuteStart, through: minuteStart.addingTimeInterval(179)).count == 2,
              "a minute with no temperature reading has no temperature bucket, rather than a zero")
        check(minutes.buckets(.gpuTemp, from: minuteStart, through: minuteStart.addingTimeInterval(179)).isEmpty,
              "a series never read has no buckets")
        var later = Snapshot()
        later.timestamp = minuteStart.addingTimeInterval(300)
        later.cpu.total = 1
        minutes.record(later)
        check(minutes.buckets(.cpu, from: minuteStart, through: minuteStart.addingTimeInterval(359)).map(\.start)
              == [0.0, 60, 120, 300].map { minuteStart.addingTimeInterval($0) },
              "minutes nobody sampled (display or machine asleep) are absent, not zero")
        var stepBack = Snapshot()
        stepBack.timestamp = minuteStart.addingTimeInterval(30)
        stepBack.cpu.total = 1
        minutes.record(stepBack)
        check(minutes.buckets(.cpu, from: minuteStart, through: minuteStart.addingTimeInterval(59)).first?.count == 61,
              "a clock stepping back into a recorded minute adds to that minute")
        var tomorrow = Snapshot()
        tomorrow.timestamp = minuteStart.addingTimeInterval(86_400)
        tomorrow.cpu.total = 0.5
        minutes.record(tomorrow)
        check(minutes.buckets(.cpu, from: minuteStart, through: minuteStart.addingTimeInterval(59)).isEmpty
              && minutes.buckets(.cpu, from: tomorrow.timestamp, through: tomorrow.timestamp.addingTimeInterval(59)).first?.count == 1,
              "a day later the slot belongs to the new minute and the old one is gone")
        check(minutes.coverage?.minutes == 4 && minutes.coverage?.oldest == minuteStart.addingTimeInterval(60),
              "coverage counts the minutes still held")
        var broken = Snapshot()
        broken.timestamp = tomorrow.timestamp.addingTimeInterval(10)
        broken.cpu.total = .nan
        minutes.record(broken)
        check(minutes.buckets(.cpu, from: tomorrow.timestamp, through: tomorrow.timestamp.addingTimeInterval(59)).first?.count == 1,
              "a non-finite reading is never counted")
        exit(failures == 0 ? 0 : 1)
    }
}
