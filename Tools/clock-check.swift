import Foundation
import Combine

// swiftc -O -o /tmp/rexboing-clock-check RexBoing/Metrics/Snapshot.swift \
//   RexBoing/Metrics/Format.swift \
//   RexBoing/Metrics/History.swift RexBoing/Metrics/ProcessHistory.swift \
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
        exit(failures == 0 ? 0 : 1)
    }
}
