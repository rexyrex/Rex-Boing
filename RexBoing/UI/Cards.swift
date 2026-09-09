import SwiftUI

// MARK: - CPU

struct CPUCard: View {
    var snapshot: Snapshot
    var history: MetricsHistory
    var unit: TemperatureUnit

    @State private var expanded = false

    private var cpu: CPUMetrics { snapshot.cpu }

    var body: some View {
        Card(
            accent: Palette.cpu, title: "Processor", symbol: "cpu",
            headline: Format.percent(cpu.total, decimals: 1)
        ) {
            Sparkline(
                values: history.cpu.values, accent: Palette.cpu,
                timestamps: history.cpu.timestamps,
                inspectorMetric: .cpu)
                .frame(height: 42)

            // Temperature and power are the two numbers the graph cannot show.
            // Everything else here describes the same load the trace already
            // draws, so it waits behind the disclosure.
            HStack(spacing: 0) {
                StatTile(
                    label: "Temp",
                    value: snapshot.thermal.cpuCelsius.map {
                        Format.temperature($0, unit: unit)
                    } ?? "—",
                    tint: snapshot.thermal.cpuCelsius.map {
                        Severity.temperature($0).swiftUIColor
                    })
                StatTile(
                    label: "Power",
                    value: snapshot.power.cpuWatts.map { Format.watts($0) } ?? "—")
            }

            Divider().opacity(0.4)

            ExpandButton(title: expanded ? "Less" : "More detail", expanded: $expanded)

            if expanded { detail }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                StatTile(label: "User", value: Format.percent(cpu.user, decimals: 1))
                StatTile(label: "System", value: Format.percent(cpu.system, decimals: 1))
                StatTile(label: "Idle", value: Format.percent(cpu.idle, decimals: 1))
                StatTile(
                    label: "Load avg",
                    value: String(format: "%.2f", cpu.loadAverage.one))
            }

            if !cpu.perCore.isEmpty {
                Divider().opacity(0.4)
                CoreGrid(loads: cpu.perCore, kinds: cpu.coreKinds)
            }

            Divider().opacity(0.4)

            // Load and clock are kept in separate tiles rather than one
            // combined string: at a quarter of the card's width, "64% ·
            // 1.69 GHz" wraps onto two lines and breaks the row's rhythm.
            if snapshot.host.isAppleSilicon {
                HStack(spacing: 0) {
                    StatTile(label: "E-cluster", value: Format.percent(cpu.efficiencyLoad))
                    StatTile(
                        label: "E clock",
                        value: cpu.efficiencyClockMHz.map { Format.frequency($0) } ?? "—")
                    StatTile(label: "P-cluster", value: Format.percent(cpu.performanceLoad))
                    StatTile(
                        label: "P clock",
                        value: cpu.performanceClockMHz.map { Format.frequency($0) } ?? "—")
                }

                // The tiles above say where the clocks are; these say where
                // they have been. A P-cluster trace that sags while the die
                // temperature peaks is thermal throttling made visible —
                // evidence of the thing the pressure state only asserts.
                // Cluster accents match the core grid's. Empty buffers mean
                // IOReport did not resolve, and the traces simply do not
                // appear — nothing is faked.
                if history.pClock.count > 0 || history.eClock.count > 0 {
                    HStack(spacing: 8) {
                        clockTrace(history.eClock, label: "E", accent: Palette.memory)
                        clockTrace(history.pClock, label: "P", accent: Palette.cpu)
                    }
                }
            }

            HStack(spacing: 0) {
                StatTile(label: "Processes", value: "\(cpu.processCount)")
                StatTile(label: "Threads", value: "\(cpu.threadCount)")
            }
        }
    }

    /// One cluster's clock history, autoscaled like the throughput graphs —
    /// the caption carries the scale. Clicking opens the CPU breakdown on the
    /// clicked instant: "what was running when the clock pinned".
    @ViewBuilder
    private func clockTrace(_ buffer: RingBuffer, label: String, accent: Color) -> some View {
        if buffer.count > 0 {
            Sparkline(
                values: buffer.values, accent: accent, ceiling: nil,
                scaleCaption: "\(label) peak \(Format.frequency(buffer.maximum))",
                timestamps: buffer.timestamps,
                format: { Format.frequency($0) },
                inspectorMetric: .cpu)
                .frame(height: 24)
        }
    }
}

// MARK: - GPU

struct GPUCard: View {
    var snapshot: Snapshot
    var history: MetricsHistory
    var unit: TemperatureUnit

    @State private var expanded = false

    private var gpu: GPUMetrics { snapshot.gpu }

    var body: some View {
        Card(
            accent: Palette.gpu, title: "Graphics", symbol: "cube.transparent",
            trailing: gpu.available ? nil : "unavailable",
            headline: gpu.available ? Format.percent(gpu.utilization, decimals: 1) : nil
        ) {
            if gpu.available {
                Sparkline(
                    values: history.gpu.values, accent: Palette.gpu,
                    timestamps: history.gpu.timestamps,
                    inspectorMetric: .gpu)
                    .frame(height: 42)

                HStack(spacing: 0) {
                    StatTile(
                        label: "Temp",
                        value: snapshot.thermal.gpuCelsius.map {
                            Format.temperature($0, unit: unit)
                        } ?? "—",
                        tint: snapshot.thermal.gpuCelsius.map {
                            Severity.temperature($0).swiftUIColor
                        })
                    StatTile(
                        label: "Power",
                        value: snapshot.power.gpuWatts.map { Format.watts($0) } ?? "—")
                }

                Divider().opacity(0.4)

                ExpandButton(title: expanded ? "Less" : "More detail", expanded: $expanded)

                if expanded { detail }
            } else {
                Text("No accelerator reported utilisation statistics.")
                    .metricLabel()
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                StatTile(label: "Renderer", value: Format.percent(gpu.rendererUtilization))
                StatTile(label: "Tiler", value: Format.percent(gpu.tilerUtilization))
                StatTile(
                    label: "Clock",
                    value: gpu.clockMHz.map { Format.frequency($0) } ?? "—")
            }

            Divider().opacity(0.4)

            HStack(spacing: 0) {
                StatTile(label: gpu.coreCount != nil ? "Cores" : "Device",
                         value: gpu.coreCount.map { "\($0)" } ?? gpu.name)
                StatTile(label: "In use", value: Format.bytes(gpu.inUseMemory))
                // Only one of these is ever reported: Apple silicon publishes
                // the driver's allocation out of unified memory, a discrete
                // card publishes its VRAM capacity.
                if gpu.allocatedMemory > 0 {
                    StatTile(label: "Allocated", value: Format.bytes(gpu.allocatedMemory))
                } else if gpu.totalMemory > 0 {
                    StatTile(label: "VRAM", value: Format.bytes(gpu.totalMemory))
                }
            }
        }
    }
}

// MARK: - Memory

struct MemoryCard: View {
    var snapshot: Snapshot
    var history: MetricsHistory

    @State private var expanded = false

    private var memory: MemoryMetrics { snapshot.memory }

    var body: some View {
        Card(
            accent: Palette.memory, title: "Memory", symbol: "memorychip",
            trailing: "\(Format.bytes(memory.used)) of \(Format.bytes(memory.total))",
            headline: Format.percent(memory.fractionUsed)
        ) {
            // Memory was the one subsystem with no trace, which made it the one
            // subsystem whose reading carried no history: 78% means something
            // different when it has been climbing for a minute.
            Sparkline(
                values: history.memory.values, accent: Palette.memory,
                timestamps: history.memory.timestamps,
                format: { fraction in
                    memory.total > 0
                        ? "\(Format.percent(fraction, decimals: 1)) · \(Format.bytes(Double(memory.total) * fraction))"
                        : Format.percent(fraction, decimals: 1)
                },
                inspectorMetric: .memory)
                .frame(height: 42)

            // Pressure and swap are what the trace cannot show. A Mac can sit
            // at ninety percent used and be perfectly happy; the same ninety
            // percent with the compressor working is where the stutter is.
            HStack(spacing: 0) {
                StatTile(
                    label: "Pressure",
                    value: memory.pressureLevel.label,
                    tint: Severity.memory(memory.pressureLevel).swiftUIColor)
                StatTile(
                    label: "Swap",
                    value: memory.swap.used > 0 ? Format.bytes(memory.swap.used) : "not in use",
                    tint: memory.swap.used > 0
                        ? Severity.load(memory.swap.fraction).swiftUIColor : nil)
            }

            Divider().opacity(0.4)

            ExpandButton(title: expanded ? "Less" : "More detail", expanded: $expanded)

            if expanded { detail }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            SegmentedBar(
                segments: [
                    BarSegment(label: "App", bytes: memory.app, color: Palette.memory),
                    BarSegment(
                        label: "Wired", bytes: memory.wired,
                        color: Palette.memory.opacity(0.62)),
                    BarSegment(label: "Compressed", bytes: memory.compressed, color: Palette.swap),
                    BarSegment(
                        label: "Cached", bytes: memory.cached,
                        color: Palette.cpu.opacity(0.45)),
                ],
                total: memory.total)

            Divider().opacity(0.4)

            HStack(spacing: 0) {
                StatTile(label: "Free", value: Format.bytes(memory.free))
                StatTile(label: "Inactive", value: Format.bytes(memory.inactive))
                StatTile(label: "Purgeable", value: Format.bytes(memory.purgeable))
            }

            // The share of physical memory the kernel cannot reclaim cheaply.
            // It was being sampled and then thrown away; the level alone only
            // moves in three steps and gives no warning of the next one.
            HStack(spacing: 6) {
                Text("Unreclaimable").sectionCaption()
                Spacer(minLength: 4)
                Text(Format.percent(memory.pressure))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Severity.memory(memory.pressureLevel).swiftUIColor)
            }
            MiniBar(
                fraction: memory.pressure,
                accent: Severity.memory(memory.pressureLevel).swiftUIColor,
                height: 4)
                .accessibilityLabel("Memory pressure")
                .accessibilityValue(Format.percent(memory.pressure))

            Divider().opacity(0.4)

            // Swap gets its own block: on a Mac that is genuinely short on
            // memory this is the number that explains the stutter, and it is
            // the one most menu bar monitors leave out.
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right.square")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.swap)
                Text("Swap").sectionCaption()
                Spacer(minLength: 4)
                Text(swapSummary)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(
                        memory.swap.used > 0
                            ? Severity.load(memory.swap.fraction).swiftUIColor
                            : .secondary)
            }

            MiniBar(fraction: memory.swap.fraction, accent: Palette.swap, height: 5)

            HStack(spacing: 0) {
                StatTile(label: "Used", value: Format.bytes(memory.swap.used))
                StatTile(label: "Free", value: Format.bytes(memory.swap.free))
                StatTile(label: "Page in", value: Format.rate(memory.swap.inRate))
                StatTile(label: "Page out", value: Format.rate(memory.swap.outRate))
            }
        }
    }

    private var swapSummary: String {
        guard memory.swap.total > 0 else { return "not in use" }
        let encrypted = memory.swap.encrypted ? " · encrypted" : ""
        return "\(Format.bytes(memory.swap.used)) of \(Format.bytes(memory.swap.total))\(encrypted)"
    }
}

// MARK: - Thermal

struct ThermalCard: View {
    var snapshot: Snapshot
    var history: MetricsHistory
    var unit: TemperatureUnit

    @State private var expanded = false

    private var thermal: ThermalMetrics { snapshot.thermal }

    var body: some View {
        Card(
            accent: Palette.thermal, title: "Thermals", symbol: "thermometer.medium",
            trailing: thermal.thermalState.label
        ) {
            if thermal.sensors.isEmpty {
                Text("This Mac exposes no readable temperature sensors.")
                    .metricLabel()
            } else {
                HStack(spacing: 0) {
                    temperatureTile("CPU", thermal.cpuCelsius)
                    temperatureTile("GPU", thermal.gpuCelsius)
                    temperatureTile("Peak", thermal.peakCelsius)
                    temperatureTile("Battery", thermal.batteryCelsius)
                }

                Sparkline(
                    values: history.cpuTemp.values,
                    accent: Palette.thermal,
                    ceiling: 100,
                    timestamps: history.cpuTemp.timestamps,
                    format: { Format.temperature($0, unit: unit) },
                    inspectorMetric: .cpu)
                    .frame(height: 26)

                if !thermal.fans.isEmpty {
                    Divider().opacity(0.4)
                    ForEach(thermal.fans) { fan in
                        HStack(spacing: 8) {
                            Text("Fan \(fan.index + 1)")
                                .metricLabel()
                                .frame(width: 42, alignment: .leading)
                            MiniBar(fraction: fan.fraction, accent: Palette.thermal)
                            Text("\(Int(fan.rpm)) rpm")
                                .metricValue(size: 10.5)
                                .frame(width: 62, alignment: .trailing)
                        }
                    }
                }

                Divider().opacity(0.4)

                ExpandButton(
                    title: "\(thermal.sensors.count) sensors", expanded: $expanded)

                if expanded { sensorList }
            }
        }
    }

    private var sensorList: some View {
        // `groups` is built on the sampler queue; filtering and sorting 186
        // sensors into nine categories on every render was pure main-thread
        // work for a list whose contents change twice a second at most.
        VStack(alignment: .leading, spacing: 6) {
            ForEach(thermal.groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.category.rawValue)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)

                    // Sensor counts run into the dozens, so they are laid
                    // out in a compact grid rather than one row each.
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 6, alignment: .leading),
                            count: 3),
                        alignment: .leading, spacing: 2
                    ) {
                        ForEach(group.sensors) { sensor in
                            HStack(spacing: 3) {
                                Text(sensor.key)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 2)
                                Text(String(
                                    format: "%.0f°",
                                    Format.temperatureValue(sensor.celsius, unit: unit)))
                                    .font(.system(size: 9, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(
                                        Severity.temperature(sensor.celsius).swiftUIColor)
                            }
                            .help(sensor.label)
                        }
                    }
                }
            }
        }
    }

    private func temperatureTile(_ label: String, _ celsius: Double?) -> some View {
        StatTile(
            label: label,
            value: celsius.map { Format.temperature($0, unit: unit) } ?? "—",
            tint: celsius.map { Severity.temperature($0).swiftUIColor })
    }
}

// MARK: - Power

struct PowerCard: View {
    var snapshot: Snapshot
    var history: MetricsHistory
    var unit: TemperatureUnit

    private var power: PowerMetrics { snapshot.power }
    private var battery: BatteryMetrics { snapshot.battery }

    var body: some View {
        Card(
            accent: Palette.power, title: "Power", symbol: "bolt",
            // Whole-machine draw — fans, display and all — not the SoC
            // package; the headline and the graph below tell the same story.
            trailing: power.totalWatts.map { Format.watts($0) }
        ) {
            if power.hasAny || battery.chargingWatts != nil {
                HStack(spacing: 0) {
                    if let watts = power.cpuWatts {
                        StatTile(label: "CPU", value: Format.watts(watts))
                    }
                    if let watts = power.gpuWatts {
                        StatTile(label: "GPU", value: Format.watts(watts))
                    }
                    if let watts = power.aneWatts {
                        StatTile(label: "Neural", value: Format.watts(watts))
                    }
                    // The SoC roll-up the components above belong to. The gap
                    // between this and the headline is everything else on the
                    // board — display, SSD, fans.
                    if let watts = power.packageWatts {
                        StatTile(label: "SoC", value: Format.watts(watts))
                    }
                    if let watts = battery.chargingWatts {
                        StatTile(label: "Charging", value: Format.watts(watts))
                    } else if let watts = power.dcInWatts {
                        // Live draw at the port; the margin over the headline
                        // is conversion loss and battery upkeep.
                        StatTile(label: "DC In", value: Format.watts(watts))
                    } else if power.totalWatts == nil, let watts = power.adapterWatts {
                        // Rated ceiling, not a live figure — only worth a tile
                        // on a Mac with no measured wattage at all.
                        StatTile(label: "Adapter", value: Format.watts(watts))
                    }
                }

                // Adapter rating is a useful power figure, but it is a ceiling,
                // not a live draw. Do not manufacture a flat 0 W history graph
                // when it is the only source this Mac exposes.
                if history.power.count > 0 {
                    Sparkline(
                        values: history.power.values, accent: Palette.power, ceiling: nil,
                        scaleCaption: Format.watts(history.power.maximum) + " peak",
                        timestamps: history.power.timestamps,
                        format: { Format.watts($0) },
                        inspectorMetric: .energy)
                        .frame(height: 24)
                }
            }

            // A desktop Mac on mains can have neither wattage source nor a
            // battery, and a card that is only a header looks broken rather
            // than empty — same fallback the graphics and thermal cards use.
            if !power.hasAny && !battery.present {
                Text("No power telemetry available on this Mac.")
                    .metricLabel()
            }

            if battery.present {
                Divider().opacity(0.4)

                HStack(spacing: 6) {
                    Image(systemName: batterySymbol)
                        .font(.system(size: 11))
                        .foregroundStyle(
                            battery.isCharging ? Palette.battery : .secondary)
                    Text(batteryHeadline)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                    Spacer()
                    if let remaining = battery.timeRemainingMinutes {
                        Text(Format.minutes(remaining))
                            .metricValue(size: 10.5)
                            .foregroundStyle(.secondary)
                    }
                }

                MiniBar(
                    fraction: battery.percentage,
                    accent: battery.percentage < 0.2 ? Palette.critical : Palette.battery,
                    height: 5)

                HStack(spacing: 0) {
                    if let cycles = battery.cycleCount {
                        StatTile(label: "Cycles", value: "\(cycles)")
                    }
                    if let health = battery.healthFraction {
                        StatTile(
                            label: "Health",
                            value: Format.percent(health),
                            tint: health < 0.8 ? Palette.elevated : nil)
                    }
                    if let celsius = battery.celsius {
                        StatTile(label: "Temp", value: Format.temperature(celsius, unit: unit))
                    }
                    if let condition = battery.condition {
                        StatTile(label: "Condition", value: condition)
                    }
                }
            }

            // Only after the first successful read — "sampled and empty" is a
            // finding worth a row, "never sampled" would be a lie dressed as
            // one.
            if snapshot.sleep.sampled {
                Divider().opacity(0.4)
                sleepBlockers
            }
        }
    }

    /// Who is holding the machine or its display awake — the question `pmset
    /// -g assertions` answers, sitting where the person wondering about it is
    /// already looking. An empty list is shown as such: "nothing" is the
    /// answer most worth trusting.
    private var sleepBlockers: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Keeping awake").sectionCaption()
                Spacer(minLength: 4)
                if snapshot.sleep.blockers.isEmpty {
                    Text("nothing")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .help("""
                Processes holding a power assertion against sleep. "Display" \
                keeps the screen on; "system" lets the screen sleep but holds \
                the machine up — an audio stream, a download, a backup.
                """)

            ForEach(displayedBlockers) { blocker in
                HStack(spacing: 6) {
                    Text(blocker.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(blocker.preventsDisplaySleep ? "display" : "system")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.07)))
                }
                .help(blockerTooltip(blocker))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(blocker.name) preventing "
                        + "\(blocker.preventsDisplaySleep ? "display" : "system") sleep")
            }

            if overflowingBlockerCount > 0 {
                Text("+ \(overflowingBlockerCount) more")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Capped so a pathological day — every meeting app at once — cannot turn
    /// the card into a scroll. The cap is stated, not silent.
    private static let blockerRowLimit = 6

    private var displayedBlockers: ArraySlice<SleepBlocker> {
        snapshot.sleep.blockers.prefix(Self.blockerRowLimit)
    }

    private var overflowingBlockerCount: Int {
        max(0, snapshot.sleep.blockers.count - Self.blockerRowLimit)
    }

    /// The assertion names the process supplied — "Video Wake Lock" says more
    /// than "Google Chrome" does about what is actually being held open.
    private func blockerTooltip(_ blocker: SleepBlocker) -> String {
        var lines = ["\(blocker.name) — pid \(blocker.pid)"]
        lines.append(contentsOf: blocker.assertionNames)
        return lines.joined(separator: "\n")
    }

    private var batterySymbol: String {
        if battery.isCharging { return "battery.100.bolt" }
        switch battery.percentage {
        case ..<0.15: return "battery.0"
        case ..<0.4: return "battery.25"
        case ..<0.7: return "battery.50"
        case ..<0.9: return "battery.75"
        default: return "battery.100"
        }
    }

    private var batteryHeadline: String {
        var text = Format.percent(battery.percentage)
        if battery.isCharging {
            text += " · charging"
        } else if battery.isPluggedIn {
            text += " · on power"
        }
        return text
    }
}

// MARK: - Network

struct NetworkCard: View {
    var snapshot: Snapshot
    var history: MetricsHistory

    var body: some View {
        Card(
            accent: Palette.network, title: "Network", symbol: "network",
            trailing: snapshot.network.primaryInterface,
            headline: Format.rate(
                snapshot.network.rxBytesPerSecond + snapshot.network.txBytesPerSecond)
        ) {
            // Both directions, summed. The trace sits above rows for download
            // *and* upload, and a graph of one direction drew a flat line
            // through a 50 MB/s upload. Rx and tx are appended in lockstep by
            // `MetricsHistory.record`, so the zip is element-aligned by
            // construction. The caption says "peak" because an autoscaled
            // maximum otherwise reads as a rate.
            let combined = zip(
                history.networkRx.values, history.networkTx.values).map(+)
            Sparkline(
                values: combined, accent: Palette.network, ceiling: nil,
                scaleCaption: Format.rate(combined.max() ?? 0) + " peak",
                timestamps: history.networkRx.timestamps,
                format: { Format.rate($0) },
                inspectorMetric: .cpu)
                .frame(height: 30)

            VStack(alignment: .leading, spacing: 4) {
                StatRow(
                    label: "Download",
                    value: Format.rate(snapshot.network.rxBytesPerSecond),
                    tint: Palette.network, symbol: "arrow.down")
                StatRow(
                    label: "Upload",
                    value: Format.rate(snapshot.network.txBytesPerSecond),
                    tint: Palette.network, symbol: "arrow.up")
            }

            Divider().opacity(0.4)

            // Address and totals stack rather than sharing a line: at half
            // the panel's width the pair collided over the middle.
            VStack(alignment: .leading, spacing: 2) {
                if let address = snapshot.network.localAddress {
                    Text(address)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(sessionTotals(
                    down: snapshot.network.rxTotal, up: snapshot.network.txTotal))
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Storage

struct StorageCard: View {
    var snapshot: Snapshot
    var history: MetricsHistory

    var body: some View {
        Card(
            accent: Palette.disk, title: "Storage", symbol: "internaldrive",
            headline: Format.rate(
                snapshot.disk.readBytesPerSecond + snapshot.disk.writeBytesPerSecond)
        ) {
            // Same shape as the network trace: reads plus writes, or a heavy
            // read leaves the graph flat under a row saying otherwise.
            let combined = zip(
                history.diskRead.values, history.diskWrite.values).map(+)
            Sparkline(
                values: combined, accent: Palette.disk, ceiling: nil,
                scaleCaption: Format.rate(combined.max() ?? 0) + " peak",
                timestamps: history.diskWrite.timestamps,
                format: { Format.rate($0) },
                inspectorMetric: .disk)
                .frame(height: 30)

            VStack(alignment: .leading, spacing: 4) {
                StatRow(
                    label: "Read",
                    value: Format.rate(snapshot.disk.readBytesPerSecond),
                    tint: Palette.disk, symbol: "arrow.down.doc")
                StatRow(
                    label: "Write",
                    value: Format.rate(snapshot.disk.writeBytesPerSecond),
                    tint: Palette.disk, symbol: "arrow.up.doc")
            }

            Text(sessionTotals(
                down: snapshot.disk.readTotal, up: snapshot.disk.writeTotal,
                downLabel: "read", upLabel: "written"))
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)

            Divider().opacity(0.4)

            HStack(spacing: 6) {
                Text(snapshot.disk.volumeName).metricLabel()
                Spacer(minLength: 4)
                Text("\(Format.diskBytes(snapshot.disk.available)) available of \(Format.diskBytes(snapshot.disk.capacity))")
                    .metricValue(size: 10.5)
                    .foregroundStyle(.secondary)
            }
            MiniBar(
                fraction: snapshot.disk.fractionUsed,
                accent: snapshot.disk.fractionUsed > 0.9 ? Palette.critical : Palette.disk,
                height: 5)
                .accessibilityLabel(
                    "\(snapshot.disk.volumeName) \(Format.percent(snapshot.disk.fractionUsed)) full")
        }
    }
}

/// Traffic since launch, shared by both I/O cards. The kernel's own counters
/// wrap, so a since-boot figure would be a fiction; this one is honest about
/// its window.
private func sessionTotals(
    down: UInt64, up: UInt64, downLabel: String = "down", upLabel: String = "up"
) -> String {
    "\(Format.bytes(down)) \(downLabel) · \(Format.bytes(up)) \(upLabel) this session"
}
