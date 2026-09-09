import SwiftUI

/// The popover shown when the status item is clicked.
struct DashboardView: View {
    /// Resolved once, at open, against the screen that was actually clicked.
    /// Reading `NSScreen.main` from the body sized the panel to whichever
    /// display held the key window, then re-sized it mid-open when the
    /// popover itself became key.
    let height: CGFloat

    @EnvironmentObject private var engine: MetricsEngine
    @EnvironmentObject private var preferences: Preferences

    private var snapshot: Snapshot { engine.snapshot }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.5)

            if engine.hasReceivedFirstSample {
                content
            } else {
                // Rendering the cards before the first sample lands shows a
                // panel full of confident zeros, which reads as a broken app
                // rather than one that has been running for 40 milliseconds.
                placeholder
            }
        }
        .frame(width: Metrics.dashboardWidth, height: height)
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: Metrics.sectionSpacing) {
                // The four headline subsystems sit two abreast, which puts the
                // whole machine's state in the first screenful. `fixedSize`
                // re-proposes each row at its taller card's height and `Card`
                // stretches to accept it, so a pair shares one bottom edge
                // however lopsided its contents — until a disclosure opens,
                // when the neighbour keeps its top-aligned content and simply
                // grows its background.
                HStack(alignment: .top, spacing: Metrics.sectionSpacing) {
                    CPUCard(
                        snapshot: snapshot, history: engine.history,
                        unit: preferences.temperatureUnit)
                    GPUCard(
                        snapshot: snapshot, history: engine.history,
                        unit: preferences.temperatureUnit)
                }
                .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: Metrics.sectionSpacing) {
                    MemoryCard(snapshot: snapshot, history: engine.history)
                    ThermalCard(
                        snapshot: snapshot, history: engine.history,
                        unit: preferences.temperatureUnit)
                }
                .fixedSize(horizontal: false, vertical: true)

                ProcessesCard(snapshot: snapshot, rowCount: preferences.processRowCount)
                AppUsageCard(
                    engine: engine,
                    sampledAt: snapshot.processes.sampledAt,
                    rowCount: preferences.processRowCount)
                PowerCard(
                    snapshot: snapshot, history: engine.history,
                    unit: preferences.temperatureUnit)

                // Network and storage pair up the same way the headline rows
                // do: neither needs a full row on its own, and side by side
                // they keep the panel a screenful.
                HStack(alignment: .top, spacing: Metrics.sectionSpacing) {
                    NetworkCard(snapshot: snapshot, history: engine.history)
                    StorageCard(snapshot: snapshot, history: engine.history)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 11)
        }
        // Every graph in here opens the same window, on whichever instant was
        // clicked. Installed once at the top rather than handed to each card:
        // the cards take their data by value so that they observe nothing, and
        // this keeps it that way.
        .environment(\.inspectGraph, InspectGraphAction { metric, date in
            ProcessInspectorWindowController.shared.show(
                engine: engine, metric: metric, at: date)
        })
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Taking the first sample…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    /// The name over the machine it is reading, with the character on duty
    /// in the menu bar standing beside it.
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            // The character on duty, at rest, drawn by the menu bar's own code
            // at the menu bar's own size. Tinted in the brand blue — the app
            // icon's plate and the foot of the load ramp — so it reads as a
            // mark beside the name rather than as a second status item.
            Image(nsImage: VisualizerIcon.image(for: preferences.visualizer))
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .frame(
                    width: Visualizer.canvasSize.width,
                    height: Visualizer.canvasSize.height)
                .foregroundStyle(Palette.cpu)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                wordmark
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help(hostDetail)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 4)

            Button {
                SettingsWindowController.shared.show(engine: engine)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
            .accessibilityLabel("Settings")

            Menu {
                // The breakdown is otherwise reachable only by clicking a
                // graph, which nothing on the panel announces. Opened on the
                // newest sample, following the stream, so it needs no instant.
                Button("Process Breakdown…") {
                    let latest = engine.processHistory.samples.last?.timestamp ?? Date()
                    ProcessInspectorWindowController.shared.show(
                        engine: engine, metric: .cpu, at: latest)
                }
                Divider()
                Button("About Rex Boing") { AboutPanel.show() }
                Divider()
                Button("Quit Rex Boing") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12.5))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("More")
            .accessibilityLabel("More options")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
    }

    /// The name set as a mark rather than a label: rounded and bold like the
    /// headline numbers below it, tightened a touch, with "Boing" picked out
    /// in the brand blue. System type on purpose — it is the one face that
    /// is guaranteed to be on every Mac and to match the rest of the panel.
    private var wordmark: some View {
        Text("Rex \(Text("Boing").foregroundStyle(Palette.cpu))")
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .tracking(-0.3)
            .lineLimit(1)
    }

    /// The machine in one line: model, chip, cores, memory, uptime. The model
    /// used to head the panel; now that the name does, it leads this line.
    private var subtitle: String {
        let host = snapshot.host
        var parts: [String] = [host.modelName, host.chipName]
        if host.isAppleSilicon, host.efficiencyCores > 0 {
            parts.append("\(host.performanceCores)P + \(host.efficiencyCores)E")
        } else {
            parts.append("\(host.logicalCores) cores")
        }
        parts.append(Format.bytes(host.memoryBytes))
        parts.append("up \(Format.duration(host.uptime))")
        return parts.joined(separator: " · ")
    }

    private var hostDetail: String {
        let host = snapshot.host
        return """
            \(host.modelName) (\(host.modelIdentifier))
            macOS \(host.osVersion)
            \(host.chipName) · \(host.physicalCores) physical / \(host.logicalCores) logical cores
            """
    }

}
