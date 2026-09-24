import AppKit
import Foundation

// Exercises the live, unprivileged telemetry paths without launching the menu
// bar UI. It is intentionally a host smoke test rather than a golden-value
// test: exact readings change underneath it, but availability, finiteness,
// ranges and internally related counts must always hold.
//
//   swiftc -O -o /tmp/metrics-check \
//     -framework AppKit -framework IOKit -framework SystemConfiguration \
//     RexBoing/Metrics/Snapshot.swift RexBoing/Metrics/Format.swift \
//     RexBoing/Metrics/UsageLedger.swift \
//     RexBoing/Metrics/Samplers/Sysctl.swift \
//     RexBoing/Metrics/Samplers/CPUSampler.swift \
//     RexBoing/Metrics/Samplers/MemorySampler.swift \
//     RexBoing/Metrics/Samplers/GPUSampler.swift \
//     RexBoing/Metrics/Samplers/SMCService.swift \
//     RexBoing/Metrics/Samplers/HIDSensors.swift \
//     RexBoing/Metrics/Samplers/ThermalSampler.swift \
//     RexBoing/Metrics/Samplers/IOReportSampler.swift \
//     RexBoing/Metrics/Samplers/SystemPowerSampler.swift \
//     RexBoing/Metrics/Samplers/IOSampler.swift \
//     RexBoing/Metrics/Samplers/BatterySampler.swift \
//     RexBoing/Metrics/Samplers/ProcessSampler.swift \
//     RexBoing/Metrics/Samplers/SleepAssertionSampler.swift \
//     Tools/metrics-check.swift
//   /tmp/metrics-check
@main
enum MetricsCheck {
    static func main() {
        let cpu = CPUSampler()
        let memory = MemorySampler()
        let gpu = GPUSampler()
        let thermal = ThermalSampler()
        let power = IOReportSampler()
        let systemPower = SystemPowerSampler()
        let network = NetworkSampler()
        let disk = DiskSampler()
        let battery = BatterySampler()
        let processes = ProcessSampler()
        let sleepAssertions = SleepAssertionSampler()

        // Prime every counter-based source, then give it one real window.
        _ = cpu.sample()
        _ = memory.sample(interval: 0.5)
        _ = network.sample(interval: 0.5)
        _ = disk.sample(interval: 0.5)
        _ = processes.sample(interval: 0.5)
        Thread.sleep(forTimeInterval: 0.55)

        var timings: [(String, Double)] = []
        func measured<T>(_ name: String, _ work: () -> T) -> T {
            let start = ProcessInfo.processInfo.systemUptime
            let value = work()
            timings.append((name, (ProcessInfo.processInfo.systemUptime - start) * 1_000))
            return value
        }

        let cpuReading = measured("CPU") { cpu.sample() }
        let memoryReading = measured("memory") { memory.sample(interval: 0.55) }
        let gpuReading = measured("GPU") { gpu.sample() }
        let thermalReading = measured("thermal") { thermal.sample(detailed: true) }
        let powerReading = measured("power") {
            power?.sample(interval: 0.55) ?? IOReportSampler.Reading()
        }
        let systemPowerReading = measured("sys power") {
            systemPower?.sample() ?? SystemPowerSampler.Reading()
        }
        let networkReading = measured("network") { network.sample(interval: 0.55) }
        let diskReading = measured("disk") { disk.sample(interval: 0.55) }
        let batteryReading = measured("battery") { battery.sample() }
        let processReading = measured("processes") { processes.sample(interval: 0.55).metrics }
        let sleepReading = measured("assertions") { sleepAssertions.sample() }

        var failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if condition() {
                print("PASS  \(message)")
            } else {
                failures += 1
                print("FAIL  \(message)")
            }
        }

        check(cpuReading.total.isFinite && (0...1).contains(cpuReading.total),
              "CPU total is finite and in range")
        check(cpuReading.perCore.count == HostInfo.current.logicalCores,
              "CPU returned one reading per logical core")
        check(cpuReading.processCount > 0 && cpuReading.threadCount >= cpuReading.processCount,
              "kernel task/thread totals are populated")

        check(memoryReading.total == HostInfo.current.memoryBytes,
              "memory total matches the host")
        check(memoryReading.used <= memoryReading.total,
              "memory used does not exceed physical memory")
        check(memoryReading.fractionUsed.isFinite && (0...1).contains(memoryReading.fractionUsed),
              "memory fraction is finite and in range")
        check(memoryReading.swap.inRate.isFinite && memoryReading.swap.inRate >= 0
                && memoryReading.swap.outRate.isFinite && memoryReading.swap.outRate >= 0,
              "swap rates are finite and non-negative")

        check(!gpuReading.available || (0...1).contains(gpuReading.utilization),
              "GPU is unavailable or has a valid utilisation")
        check(thermalReading.sensors.allSatisfy {
            $0.celsius.isFinite && $0.celsius > -50 && $0.celsius < 150
        }, "temperature sensors are finite and plausible")
        check(thermalReading.fans.allSatisfy {
            $0.rpm.isFinite && $0.rpm >= 0 && $0.maxRPM >= $0.minRPM
        }, "fan readings are finite and internally consistent")
        check([
            powerReading.power.cpuWatts,
            powerReading.power.gpuWatts,
            powerReading.power.aneWatts,
            powerReading.power.packageWatts,
        ].compactMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 },
        "power readings are finite and non-negative")
        // A machine that is on draws real watts, so where the rail exists at
        // all its reading has a meaningful floor, unlike the per-block rails.
        check(systemPower == nil || systemPowerReading.systemTotalWatts
                .map { $0.isFinite && $0 > 0.1 && $0 < 500 } == true,
              "system rail is absent or reads plausible whole-machine watts")
        check(systemPowerReading.dcInWatts.map { $0.isFinite && $0 > 0 } != false,
              "DC-in rail is absent or positive")
        check([
            powerReading.efficiencyClockMHz,
            powerReading.performanceClockMHz,
            powerReading.gpuClockMHz,
        ].compactMap { $0 }.allSatisfy { $0.isFinite && $0 > 0 },
        "clock readings are absent or finite and positive")
        check(networkReading.rxBytesPerSecond.isFinite
                && networkReading.rxBytesPerSecond >= 0
                && networkReading.txBytesPerSecond.isFinite
                && networkReading.txBytesPerSecond >= 0,
              "network rates are finite and non-negative")
        check(diskReading.readBytesPerSecond.isFinite
                && diskReading.readBytesPerSecond >= 0
                && diskReading.writeBytesPerSecond.isFinite
                && diskReading.writeBytesPerSecond >= 0,
              "disk rates are finite and non-negative")
        check(diskReading.capacity == 0 || diskReading.available <= diskReading.capacity,
              "volume capacity is internally consistent")

        check(processReading.count > 0, "process enumeration returned rows")
        check(processReading.count <= cpuReading.processCount + 64,
              "process enumeration agrees with the kernel task count")
        check(processReading.leaders.values.joined().allSatisfy {
            $0.cpuPercent.isFinite && $0.cpuPercent >= 0
                && $0.gpuPercent.isFinite && $0.gpuPercent >= 0
                && $0.diskBytesPerSecond.isFinite && $0.diskBytesPerSecond >= 0
        }, "ranked process rates are finite and non-negative")
        check(!batteryReading.present || (0...1).contains(batteryReading.percentage),
              "battery is absent or has a valid charge fraction")
        check(!sleepReading.sampled || sleepReading.blockers.allSatisfy {
            $0.pid > 0 && !$0.name.isEmpty
                && ($0.preventsDisplaySleep || $0.preventsSystemSleep)
        }, "sleep assertions are absent or internally consistent")

        print("\nReadings")
        print(String(
            format: "CPU %.1f%% · %d tasks · %d threads",
            cpuReading.total * 100, cpuReading.processCount, cpuReading.threadCount))
        print("Memory \(Format.bytes(memoryReading.used)) of \(Format.bytes(memoryReading.total))")
        print("GPU \(gpuReading.available ? Format.percent(gpuReading.utilization) : "unavailable")")
        print("Thermals \(thermalReading.sensors.count) sensors · "
            + "\(thermalReading.fans.count) fans")
        // Blocks whose counters have not published inside the window read
        // "not publishing" — on macOS 27 that can be every mJ channel.
        func watts(_ value: Double?) -> String { value.map(Format.watts) ?? "not publishing" }
        print("Package power \(watts(powerReading.power.packageWatts)) · "
            + "CPU \(watts(powerReading.power.cpuWatts)) · "
            + "GPU \(watts(powerReading.power.gpuWatts))")
        print("System power "
            + (systemPowerReading.systemTotalWatts.map(Format.watts) ?? "unavailable")
            + (systemPowerReading.dcInWatts.map { " · DC in " + Format.watts($0) } ?? ""))
        print("Network \(networkReading.primaryInterface ?? "—") · "
            + "↓\(Format.rate(networkReading.rxBytesPerSecond)) "
            + "↑\(Format.rate(networkReading.txBytesPerSecond))")
        print("Disk \(Format.rate(diskReading.readBytesPerSecond)) read · "
            + "\(Format.rate(diskReading.writeBytesPerSecond)) written")
        print("Processes \(processReading.count) enumerated")

        print("\nSampler time")
        for (name, milliseconds) in timings {
            print(String(format: "%-10@ %7.2f ms", name as NSString, milliseconds))
        }

        print(failures == 0 ? "\nPASS" : "\nFAIL: \(failures) check(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
