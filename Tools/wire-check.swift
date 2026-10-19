import Foundation

// swiftc -O -o /tmp/rexboing-wire-check RexBoing/Metrics/Snapshot.swift \
//   RexBoing/Metrics/Wire.swift RexBoing/Metrics/Format.swift Tools/wire-check.swift
//
// Rex Boing Remote's wire format against Rex Boing's own model: a snapshot
// encoded the way the macOS agent encodes it must decode back into the same
// readings, and a sample as the Linux agent writes it must land in the right
// card fields — with nothing invented for what the sample left out.
@main
struct WireCheck {
    static func main() {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL")  \(message)")
            if !condition { failures += 1 }
        }
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // A Mac snapshot, round-tripped through a full sample.
        var mac = Snapshot()
        mac.timestamp = Date(timeIntervalSince1970: 1_792_141_977.889)
        mac.interval = 1.002
        mac.host.modelName = "MacBook Pro"
        mac.host.chipName = "Apple M1 Pro"
        mac.host.logicalCores = 4
        mac.host.isAppleSilicon = true
        mac.cpu.total = 0.25
        mac.cpu.user = 0.15
        mac.cpu.system = 0.1
        mac.cpu.idle = 0.75
        mac.cpu.perCore = [0.1, 0.2, 0.3, 0.4]
        mac.cpu.coreKinds = [.efficiency, .efficiency, .performance, .performance]
        mac.cpu.loadAverage = LoadAverage(one: 1.5, five: 1.25, fifteen: 1)
        mac.memory.total = 16 << 30
        mac.memory.used = 8 << 30
        mac.memory.compressed = 1 << 30
        mac.memory.pressureLevel = .warning
        mac.memory.swap.total = 2 << 30
        mac.memory.swap.used = 1 << 30
        mac.gpu.available = true
        mac.gpu.name = "Apple M1 Pro"
        mac.gpu.utilization = 0.4
        mac.thermal.cpuCelsius = 55
        mac.thermal.peakCelsius = 61
        mac.thermal.sensors = [TempSensor(key: "Tp09", label: "CPU P-core", celsius: 61, category: .cpu)]
        mac.thermal.fans = [Fan(index: 0, rpm: 1200, minRPM: 1000, maxRPM: 6000)]
        mac.power.packageWatts = 12.5
        mac.network.rxBytesPerSecond = 1000
        mac.disk.writeBytesPerSecond = 2000
        mac.disk.volumeName = "Macintosh HD"
        mac.disk.capacity = 500_000_000_000
        mac.disk.available = 200_000_000_000
        var row = ProcessRow(pid: 42, name: "Xcode")
        row.cpuPercent = 120
        row.memoryBytes = 3 << 30
        mac.processes.count = 512
        mac.processes.leaders = [.cpu: [row], .memory: [row]]

        do {
            let data = try encoder.encode(mac.wireSample(full: true))
            guard case .sample(let sample)? = WireMessage.decode(data) else {
                check(false, "a full sample decodes as a sample")
                return
            }
            let back = Snapshot(sample: sample, host: mac.host.wire(hostname: "mac", kernel: "25.0"))
            check(abs(back.timestamp.timeIntervalSince(mac.timestamp)) < 0.002, "timestamp survives")
            check(back.cpu.total == 0.25 && back.cpu.perCore == mac.cpu.perCore, "CPU load survives")
            check(back.cpu.coreKinds == mac.cpu.coreKinds, "core kinds survive")
            check(back.cpu.performanceLoad == 0.35 && back.cpu.efficiencyLoad == 0.15000000000000002,
                  "cluster loads are rebuilt from the cores")
            check(back.cpu.loadAverage == mac.cpu.loadAverage, "load average survives")
            check(back.memory.used == mac.memory.used && back.memory.compressed == mac.memory.compressed,
                  "memory survives")
            check(back.memory.pressureLevel == .warning, "pressure level survives")
            check(back.memory.swap.used == mac.memory.swap.used, "swap survives")
            check(back.gpu.available && back.gpu.utilization == 0.4, "GPU survives")
            check(back.thermal.sensors.count == 1 && back.thermal.groups.count == 1,
                  "sensors survive and are grouped")
            check(back.thermal.fans.first?.maxRPM == 6000, "fans survive")
            check(back.power.packageWatts == 12.5 && back.power.cpuWatts == nil,
                  "power survives and nothing is invented")
            check(back.disk.volumeName == "Macintosh HD" && back.disk.capacity == mac.disk.capacity,
                  "volume survives")
            check(sample.disk?.volumes?.first?.used == nil && back.disk.reserved == 0
                  && back.disk.fractionUsed == mac.disk.fractionUsed && mac.disk.fractionUsed == 0.6,
                  "a Mac volume has no reserve and is as full as before")
            check(back.processes.leaders[.cpu]?.first?.cpuPercent == 120
                  && back.processes.leaders[.memory]?.first?.memoryBytes == 3 << 30,
                  "process rankings survive")
            check(back.host.isAppleSilicon && back.host.chipName == "Apple M1 Pro", "host survives")

            let vitals = try encoder.encode(mac.wireSample(full: false))
            check(vitals.count < 700, "a vitals sample stays small (\(vitals.count) bytes)")
            guard case .sample(let small)? = WireMessage.decode(vitals) else {
                check(false, "a vitals sample decodes")
                return
            }
            let merged = Snapshot(sample: small, host: nil, previous: back)
            check(merged.thermal.sensors.count == 1 && merged.processes.count == 512,
                  "a vitals sample keeps the previous sensors and processes")
            check(merged.cpu.total == 0.25 && merged.cpu.perCore.isEmpty,
                  "a vitals sample carries load but not per-core detail")
        } catch {
            check(false, "encoding failed: \(error)")
        }

        // A sample as the Linux agent writes it.
        let linux = #"""
        {"type":"sample","seq":3,"t":1792141977889,"interval":1.0,"detail":"full","resync":false,
         "cpu":{"total":0.064,"user":0.04,"system":0.02,"idle":0.936,"nice":0,"iowait":0.004,
                "perCore":[0.15,0.14],"kinds":"PE","load":[2.75,2.78,2.42],"processes":742,"zombies":4},
         "memory":{"total":66701082624,"used":12000000000,"available":54701082624,"cached":30000000000,
                   "buffers":1000000000,"pressureLevel":"normal","swap":{"total":8589930496,"used":2097152,"free":8587833344}},
         "gpus":[{"name":"Intel Arc Graphics","vendor":"intel","utilization":0,"engines":{"render":0,"media":0},"maxClockMHz":2250}],
         "thermal":{"sensors":[{"key":"pkg","label":"CPU package","celsius":50,"category":"CPU","high":105,"critical":105},
                               {"key":"nvme0","label":"NVMe Composite","celsius":43.9,"category":"Storage","critical":94.8}],
                    "fans":[{"index":0,"label":"cpu_fan","rpm":1790}],"cpuCelsius":50,"storageCelsius":43.9,"peakCelsius":52,"state":"nominal"},
         "power":{"packageWatts":12.2},
         "network":{"rx":10236,"tx":156972,"primaryInterface":"enp1s0","localAddress":"192.168.1.20",
                    "interfaces":[{"name":"enp1s0","rx":10236,"tx":156972,"speedMbps":2500,"up":true}]},
         "disk":{"read":0,"write":0,"volumes":[{"name":"/","mount":"/","fs":"ext4","total":2013991550976,"available":1555545378816,"used":356000000000}]},
         "pressure":{"cpu":1.54,"memory":0,"io":0},
         "system":{"uptime":814624,"rebootRequired":true,"rebootReason":"kernel 6.8.0-147-generic installed","containers":31},
         "processes":{"count":742,"sampledAt":1792141977889,"interval":1,"gpuAttribution":false,
                      "rows":[{"pid":7,"name":"node","user":"alex","cmd":"node server.js","cpu":5.8,"memory":433000000}],
                      "rank":{"cpu":[7],"memory":[7]}},
         "future":{"ignored":true}}
        """#
        guard case .sample(let sample)? = WireMessage.decode(Data(linux.utf8)) else {
            check(false, "a Linux sample decodes, unknown keys and all")
            exit(1)
        }
        var host = WireHost()
        host.hostname = "homelab"
        host.modelName = "NUC15CRHU7"
        host.osName = "Ubuntu"
        host.osVersion = "24.04.5 LTS"
        host.logicalCores = 16
        let box = Snapshot(sample: sample, host: host)
        check(box.cpu.total == 0.064 && box.cpu.coreKinds == [.performance, .efficiency],
              "Linux CPU lands in the CPU card")
        check(box.memory.cached == 31_000_000_000 && box.memory.app == box.memory.used,
              "page cache and buffers read as cached; used is app memory")
        check(box.gpu.available && box.gpu.name == "Intel Arc Graphics", "the first GPU becomes the card's")
        check(box.thermal.cpuCelsius == 50 && box.thermal.groups.map(\.category) == [.cpu, .storage],
              "sensors are grouped by category")
        check(box.extras.sensorLimits["pkg"]?.critical == 105, "hardware limits are kept")
        check(box.thermal.fans.first?.rpm == 1790 && box.extras.fanLabels[0] == "cpu_fan",
              "fan readings and labels are kept")
        check(box.thermal.gpuCelsius == nil, "no GPU temperature is invented")
        check(box.power.packageWatts == 12.2 && box.power.totalWatts == 12.2, "package power drives the total")
        check(box.disk.volumeName == "/" && box.disk.capacity == 2_013_991_550_976, "root volume is primary")
        // 5 % of the ext4 root is kept for root: df calls this disk 19 % full,
        // and total − available would say 23 %.
        let dfFull = 356e9 / (356e9 + 1_555_545_378_816)
        check(box.disk.used == 356_000_000_000 && box.disk.reserved == 102_446_172_160
              && abs(box.disk.fractionUsed - dfFull) < 1e-12,
              "the root reserve is neither used nor available, as df counts it (\(box.disk.fractionUsed))")
        check(abs((sample.disk?.volumes?.first?.fractionUsed ?? 0) - dfFull) < 1e-12,
              "the Filesystems card reads the same fullness")
        var older = WireVolume()
        older.total = 100
        older.available = 40
        check(older.reserved == 0 && older.fractionUsed == 0.6, "an agent without used reads as before")
        var odd = WireVolume()
        odd.total = 100
        odd.available = 40
        odd.used = 90
        check(odd.reserved == 0 && odd.fractionUsed == 0.6, "used beyond total − available is not believed")
        odd.available = 150
        odd.used = 0
        check(odd.reserved == 0 && odd.fractionUsed == 0, "more available than the whole reads as empty")
        check(box.extras.pressure?.cpu == 1.54, "pressure stall is kept")
        check(box.extras.system?.rebootRequired == true && box.extras.system?.containers == 31,
              "system state is kept")
        check(box.extras.zombies == 4 && box.extras.iowait == 0.004, "zombies and iowait are kept")
        let top = box.processes.leaders[.cpu]?.first
        check(top?.name == "node" && top?.user == "alex" && top?.commandLine == "node server.js",
              "remote process rows keep user and command line")
        check(box.host.osVersion == "Ubuntu 24.04.5 LTS" && box.host.modelName == "NUC15CRHU7",
              "host description reads from hello")

        let hello = #"{"type":"hello","protocol":1,"agent":{"name":"rex-boing-agent","version":"0.1.0","os":"linux","arch":"amd64"},"host":{"hostname":"homelab"},"capabilities":["cpu"],"interval":1}"#
        if case .hello(let decoded)? = WireMessage.decode(Data(hello.utf8)) {
            check(decoded.protocol == 1 && decoded.agent?.os == "linux", "hello decodes")
        } else {
            check(false, "hello decodes")
        }
        check(WireMessage.decode(Data("not json".utf8)) == nil, "a non-JSON line is rejected")
        if case .notice(let code, _)? = WireMessage.decode(Data(#"{"type":"notice","code":"rapl-denied","message":"x"}"#.utf8)) {
            check(code == "rapl-denied", "notices decode")
        } else {
            check(false, "notices decode")
        }

        // What a buggy or hostile agent can put on the wire must not crash
        // the app or confuse its views.
        check(Format.duration(.infinity) == "—" && Format.shortInterval(.infinity) == "—"
              && Format.duration(.nan) == "—" && !Format.duration(1e19).isEmpty,
              "absurd uptimes format instead of trapping")
        check(!Format.bytes(UInt64(0)).contains("Zero") && !Format.diskBytes(0).contains("Zero"),
              "zero bytes read as a number")
        let oddMessage = #"{"type":"sample","message":{"x":1},"code":7,"cpu":{"total":0.5}}"#
        if case .sample(let odd)? = WireMessage.decode(Data(oddMessage.utf8)) {
            check(odd.cpu?.total == 0.5, "a sample with non-string code and message still decodes")
        } else {
            check(false, "a sample with non-string code and message still decodes")
        }
        let dupes = #"""
        {"type":"sample","detail":"full",
         "thermal":{"sensors":[{"key":"a","celsius":40},{"key":"a","celsius":41},{"celsius":42},{"celsius":43}],
                    "fans":[{"index":0,"rpm":1000},{"index":0,"rpm":2000},{"rpm":900}]},
         "sleep":{"sampled":true,"blockers":[{"pid":9,"name":"caffeinate"},{"pid":9,"name":"caffeinate"}]},
         "processes":{"count":1,"rows":[{"pid":7,"name":"x","cpu":0.5}],"rank":{"cpu":[7,7]}}}
        """#
        if case .sample(let dup)? = WireMessage.decode(Data(dupes.utf8)) {
            let snapshot = Snapshot(sample: dup, host: nil, previous: nil)
            let keys = snapshot.thermal.sensors.map(\.key)
            check(keys.count == 3 && Set(keys).count == 3, "sensor ids are unique (\(keys))")
            let fans = snapshot.thermal.fans.map(\.index)
            check(fans.count == 2 && Set(fans).count == 2, "fan ids are unique (\(fans))")
            check(snapshot.sleep.blockers.count == 1, "sleep blockers are unique by pid")
            check(snapshot.processes.leaders[.cpu]?.count == 1, "a ranked pid appears once")
        } else {
            check(false, "the duplicate-id sample decodes")
        }

        print(failures == 0 ? "All wire checks passed." : "\(failures) wire check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
