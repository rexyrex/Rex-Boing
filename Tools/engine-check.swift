import AppKit
import Foundation

// Compile with all Rex Boing Swift sources except RexBoingApp.swift. Runs against
// live samplers without creating a status item or changing app preferences.
@main
struct EngineCheck {
    @MainActor static func main() async {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL")  \(message)")
            if !condition { failures += 1 }
        }
        let disk = DiskSampler()
        check(disk.sample(interval: 1, includeCapacity: false).capacity == 0,
              "background disk sampling does not resolve volume capacity")
        var metadata = DiskMetrics()
        disk.refreshCapacity(in: &metadata)
        check(metadata.capacity > 0, "dashboard can resolve capacity independently")
        check(disk.sample(interval: 1, includeCapacity: false).capacity == metadata.capacity,
              "background samples retain previously resolved capacity")

        let engine = MetricsEngine()
        engine.beginLiveProcessSampling()
        func waitForSample(after timestamp: Date) async -> Bool {
            for _ in 0..<200 {
                if engine.snapshot.timestamp > timestamp && engine.hasReceivedFirstSample {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return false
        }
        var timestamp = engine.snapshot.timestamp
        check(await waitForSample(after: timestamp), "engine produces its first sample")
        timestamp = engine.snapshot.timestamp
        check(await waitForSample(after: timestamp), "engine records an ordinary sample")
        check(engine.history.cpu.count > 0, "ordinary samples enter graph history")
        engine.setSamplingPaused(true)
        try? await Task.sleep(for: .milliseconds(300))
        timestamp = engine.snapshot.timestamp
        let count = engine.history.cpu.count
        engine.setSamplingPaused(false)
        engine.refreshNow()
        check(await waitForSample(after: timestamp), "engine resumes after a short display pause")
        check(engine.history.cpu.count == count, "resumed window does not enter graph history")
        check(engine.snapshot.processes.interval > 30,
              "process-only refresh cannot record the unobserved pause window")
        timestamp = engine.snapshot.timestamp
        check(await waitForSample(after: timestamp), "normal sampling continues after resync")
        check(engine.history.cpu.count == count + 1, "valid post-resync history resumes")
        engine.setSamplingPaused(true)
        engine.endLiveProcessSampling()
        exit(failures == 0 ? 0 : 1)
    }
}
