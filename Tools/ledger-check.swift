import AppKit
import Foundation

// Exercises the usage ledger: deterministic accounting tests against a
// synthetic timeline (the ledger takes dates rather than reading the clock,
// precisely so this file can exist), then one live pass through the real
// process sampler, then micro-benchmarks for the record and query paths.
//
//   swiftc -O -o /tmp/ledger-check \
//     -framework AppKit -framework IOKit \
//     RexBoing/Metrics/Snapshot.swift RexBoing/Metrics/Format.swift \
//     RexBoing/Metrics/UsageLedger.swift \
//     RexBoing/Metrics/Samplers/ProcessSampler.swift \
//     Tools/ledger-check.swift
//   /tmp/ledger-check
@main
enum LedgerCheck {
    static var failures = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            print("PASS  \(message)")
        } else {
            failures += 1
            print("FAIL  \(message)")
        }
    }

    static func delta(
        _ key: String, cpu: UInt64 = 0, energy: UInt64 = 0, gpu: UInt64 = 0,
        read: UInt64 = 0, written: UInt64 = 0, wakeups: UInt64 = 0,
        memory: UInt64 = 0
    ) -> AppWorkDelta {
        var value = AppWorkDelta(attribution: AppAttribution(
            key: key, displayName: key, bundlePath: nil, executablePath: nil))
        value.cpuNanos = cpu
        value.energyNanojoules = energy
        value.gpuNanos = gpu
        value.diskReadBytes = read
        value.diskWriteBytes = written
        value.wakeups = wakeups
        value.memoryBytes = memory
        return value
    }

    static func main() {
        synthetic()
        live()
        benchmark()

        print(failures == 0 ? "\nledger-check: all checks passed"
                            : "\nledger-check: \(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Synthetic timeline

    static func synthetic() {
        // A minute-aligned base keeps bucket arithmetic legible in failures.
        let base = Date(timeIntervalSince1970: 1_700_000_040 - 1_700_000_040
            .truncatingRemainder(dividingBy: 60))

        let ledger = UsageLedger()
        ledger.record(
            [delta("app:/A", cpu: 1_000_000_000, energy: 5_000_000_000,
                   memory: 100_000_000)],
            endingAt: base.addingTimeInterval(10), interval: 10)
        ledger.record(
            [delta("app:/A", cpu: 2_000_000_000, energy: 1_000_000_000,
                   memory: 200_000_000),
             delta("app:/B", gpu: 500_000_000, read: 1_000_000, written: 2_000_000)],
            endingAt: base.addingTimeInterval(20), interval: 10)
        // An idle observation: no measurable work, but ten seconds were watched.
        ledger.record([], endingAt: base.addingTimeInterval(30), interval: 10)

        let report = ledger.report(window: 300, now: base.addingTimeInterval(35))
        let a = report.rows.first { $0.attribution.key == "app:/A" }
        let b = report.rows.first { $0.attribution.key == "app:/B" }

        check(report.rows.count == 2, "two apps recorded, two rows reported")
        check(abs(report.coveredSeconds - 30) < 0.001,
              "coverage counts idle observations (30s)")
        check(a?.totals.cpuNanos == 3_000_000_000, "CPU work sums across samples")
        check(a?.totals.energyNanojoules == 6_000_000_000, "energy sums across samples")
        check(a?.totals.memoryByteSeconds == 3_000_000_000,
              "footprint integrates over time (byte·seconds)")
        check(a?.totals.peakMemoryBytes == 200_000_000, "peak footprint is the max")
        check(b?.totals.gpuNanos == 500_000_000, "GPU work lands on its own app")
        check(b?.totals.diskReadBytes == 1_000_000
                && b?.totals.diskWriteBytes == 2_000_000,
              "disk bytes land read/write split")
        check(report.earliestData == base, "earliest data is the first bucket's start")

        // A window that excludes the first minute: work recorded there is out.
        let narrow = ledger.report(window: 30, now: base.addingTimeInterval(95))
        check(narrow.rows.isEmpty && narrow.coveredSeconds == 0,
              "a window past the recorded minute reports nothing")

        // Bucket rollover: minute two lands in a second bucket; both visible.
        ledger.record(
            [delta("app:/A", cpu: 1_000_000_000)],
            endingAt: base.addingTimeInterval(70), interval: 10)
        let both = ledger.report(window: 300, now: base.addingTimeInterval(75))
        let rolledA = both.rows.first { $0.attribution.key == "app:/A" }
        check(rolledA?.totals.cpuNanos == 4_000_000_000,
              "rollover keeps both minutes queryable")
        check(abs(both.coveredSeconds - 40) < 0.001, "coverage spans buckets")

        // Ring wrap: a stamp 24h later claims the same slot, evicting the old
        // minute — which a 24h window must then no longer see.
        let day = UsageLedger.bucketWidth * Double(UsageLedger.bucketCount)
        ledger.record(
            [delta("app:/C", cpu: 7_000_000_000)],
            endingAt: base.addingTimeInterval(day + 10), interval: 10)
        ledger.record(
            [delta("app:/C", cpu: 1_000_000_000)],
            endingAt: base.addingTimeInterval(day + 70), interval: 10)
        let wrapped = ledger.report(
            window: day, now: base.addingTimeInterval(day + 75))
        let wrappedA = wrapped.rows.first { $0.attribution.key == "app:/A" }
        let wrappedC = wrapped.rows.first { $0.attribution.key == "app:/C" }
        check(wrappedA?.totals.cpuNanos == 4_000_000_000 - 3_000_000_000,
              "a lapped slot is evicted; untouched minutes survive")
        check(wrappedC?.totals.cpuNanos == 8_000_000_000,
              "the slot's new occupant reports in full")

        // Saturation: absurd counters pin at the ceiling instead of wrapping.
        let saturated = UsageLedger()
        saturated.record([delta("app:/S", cpu: .max)], endingAt: base, interval: 10)
        saturated.record([delta("app:/S", cpu: .max)],
                         endingAt: base.addingTimeInterval(10), interval: 10)
        let pinned = saturated.report(window: 300, now: base.addingTimeInterval(15))
        check(pinned.rows.first?.totals.cpuNanos == .max,
              "overflowing counters saturate rather than wrap")

        // Floors: what earns a ledger entry and what stays noise.
        check(!delta("x", cpu: 999_999).isMeasurable
                && delta("x", cpu: 1_000_000).isMeasurable,
              "CPU floor sits at one millisecond")
        check(!delta("x", wakeups: 1_000_000).isMeasurable,
              "wakeups alone earn no entry")
        check(!delta("x", memory: 33_554_431).isMeasurable
                && delta("x", memory: 33_554_432).isMeasurable,
              "memory floor sits at 32 MB")
    }

    // MARK: - Live integration

    static func live() {
        let sampler = ProcessSampler()
        let ledger = UsageLedger()

        _ = sampler.sample(interval: 0.5, discardCounterDeltas: true)
        // Guarantee this process itself does measurable work in the window.
        let spinUntil = Date().addingTimeInterval(0.05)
        var sink = 0.0
        while Date() < spinUntil { sink += .pi }
        _ = sink
        Thread.sleep(forTimeInterval: 0.6)

        let now = Date()
        let sampled = sampler.sample(interval: 0.6)
        ledger.record(sampled.workDeltas, endingAt: now, interval: 0.6)
        let report = ledger.report(window: 300, now: now)

        check(!sampled.workDeltas.isEmpty, "live pass produced app work deltas")
        check(sampled.workDeltas.allSatisfy { delta in
            ["app:", "exe:", "proc:"].contains { delta.attribution.key.hasPrefix($0) }
                && !delta.attribution.displayName.isEmpty
        }, "every attribution is tiered and named")
        check(Set(sampled.workDeltas.map(\.attribution.key)).count
                == sampled.workDeltas.count,
              "deltas arrive pre-aggregated, one per app")
        check(report.rows.contains {
            $0.attribution.displayName.contains("ledger-check")
        }, "this process's own work is attributed to it")

        let cores = ProcessInfo.processInfo.activeProcessorCount
        let ceiling = UInt64(0.6 * Double(cores) * 1.5e9)
        check(report.rows.allSatisfy { $0.totals.cpuNanos < ceiling },
              "no app's CPU work exceeds what the machine could do")
    }

    // MARK: - Benchmarks

    static func benchmark() {
        let ledger = UsageLedger()
        let base = Date(timeIntervalSince1970: 1_700_000_040)
        let appsPerSample = 60

        // A worst-case day: 60 measurable apps in every one of 1440 minutes.
        // Two samples per minute suffice — the figure of interest is the cost
        // of one record call, and each bucket's contents are the same however
        // many samples filled it.
        var recordNanos: UInt64 = 0
        var records = 0
        for minute in 0..<UsageLedger.bucketCount {
            for tick in 0..<2 {
                let deltas = (0..<appsPerSample).map { app in
                    delta("app:/bench/\(app)", cpu: 50_000_000,
                          energy: 20_000_000, read: 100_000, memory: 150_000_000)
                }
                let at = base.addingTimeInterval(Double(minute) * 60 + Double(tick) * 30)
                let start = DispatchTime.now().uptimeNanoseconds
                ledger.record(deltas, endingAt: at, interval: 6)
                recordNanos += DispatchTime.now().uptimeNanoseconds - start
                records += 1
            }
        }

        let queryStart = DispatchTime.now().uptimeNanoseconds
        let full = ledger.report(
            window: 86_400,
            now: base.addingTimeInterval(Double(UsageLedger.bucketCount) * 60))
        let queryNanos = DispatchTime.now().uptimeNanoseconds - queryStart

        let shortStart = DispatchTime.now().uptimeNanoseconds
        let short = ledger.report(
            window: 1_200,
            now: base.addingTimeInterval(Double(UsageLedger.bucketCount) * 60))
        let shortNanos = DispatchTime.now().uptimeNanoseconds - shortStart

        check(full.rows.count == appsPerSample, "benchmark day reports every app")
        check(!short.rows.isEmpty, "20-minute window answers from the same ring")

        print(String(
            format: "Record   %.1f µs avg over %d samples (%d apps each)",
            Double(recordNanos) / Double(records) / 1_000, records, appsPerSample))
        print(String(format: "Query    24h window %.2f ms, 20m window %.2f ms",
                     Double(queryNanos) / 1e6, Double(shortNanos) / 1e6))
        print(String(
            format: "Retained ~%.1f MB analytic for %d buckets × %d entries",
            Double(UsageLedger.bucketCount * appsPerSample * 80) / 1_048_576,
            UsageLedger.bucketCount, appsPerSample))
    }
}
