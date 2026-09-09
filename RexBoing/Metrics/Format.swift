import Foundation

/// Formatting helpers shared by the status bar renderer and the dashboard.
/// Menu bar text is redrawn several times a second, so everything here avoids
/// allocating a `Formatter` per call.
enum Format {
    /// `ByteCountFormatter` is mutable and not `Sendable`. Most formatting is
    /// done on the main thread, but diagnostics and future sampler-side callers
    /// should not turn this shared cache into a data race.
    private final class LockedByteFormatter: @unchecked Sendable {
        private let formatter: ByteCountFormatter
        private let lock = NSLock()

        init(countStyle: ByteCountFormatter.CountStyle) {
            let formatter = ByteCountFormatter()
            formatter.countStyle = countStyle
            formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
            formatter.zeroPadsFractionDigits = false
            self.formatter = formatter
        }

        func string(fromByteCount count: Int64) -> String {
            lock.lock()
            defer { lock.unlock() }
            return formatter.string(fromByteCount: count)
        }
    }

    /// 1024-based, matching Activity Monitor's memory figures.
    private static let byteFormatter = LockedByteFormatter(countStyle: .memory)
    /// Decimal, matching what Finder, Disk Utility and About This Mac say
    /// about storage. A "500 GB" SSD pushed through the memory style reads
    /// as ~465 GB and disagrees with every other surface by seven percent.
    private static let diskByteFormatter = LockedByteFormatter(countStyle: .file)

    // Clamped, not converted: `Int64(value)` traps above Int64.max, and while
    // every current caller wrap-guards its counters, one missed guard upstream
    // should read as a saturated figure, not take the app down inside a
    // formatter. (`Double(Int64.max)` rounds to exactly 2⁶³, which is itself
    // out of range — hence >= rather than >.)
    static func bytes(_ value: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: value))
    }

    static func bytes(_ value: Double) -> String {
        let clamped = max(0, value)
        return byteFormatter.string(
            fromByteCount: clamped >= Double(Int64.max) ? Int64.max : Int64(clamped))
    }

    /// Volume sizes only — see `diskByteFormatter` for why these are decimal
    /// while everything else here stays 1024-based.
    static func diskBytes(_ value: UInt64) -> String {
        diskByteFormatter.string(fromByteCount: Int64(clamping: value))
    }

    /// Where a value moves up to the next unit: the point at which the smaller
    /// unit would *round* to four digits. Deciding on the raw threshold instead
    /// let everything from 999.5 up to the boundary format as "1024K" or
    /// "1023 KB/s" — a four-digit reading that overflows layouts measured for
    /// three, when "1.0M" says the same thing in the width provided.
    private static let unitPromotion = 999.5 / 1024

    /// Compact form for tight layouts: `12.4 GB` becomes `12.4G`.
    static func compactBytes(_ value: UInt64) -> String {
        let units: [(UInt64, String)] = [
            (1 << 40, "T"), (1 << 30, "G"), (1 << 20, "M"), (1 << 10, "K"),
        ]
        for (threshold, suffix) in units
        where Double(value) >= Double(threshold) * unitPromotion {
            let scaled = Double(value) / Double(threshold)
            return scaled >= 9.95
                ? String(format: "%.0f%@", scaled, suffix)
                : String(format: "%.1f%@", scaled, suffix)
        }
        return "\(value)B"
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond >= 1 else { return "0 KB/s" }
        let units: [(Double, String)] = [
            (1_073_741_824, "GB/s"), (1_048_576, "MB/s"), (1_024, "KB/s"),
        ]
        for (threshold, suffix) in units where bytesPerSecond >= threshold * unitPromotion {
            let scaled = bytesPerSecond / threshold
            return scaled >= 99.95
                ? String(format: "%.0f %@", scaled, suffix)
                : String(format: "%.1f %@", scaled, suffix)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }

    /// Very short rate for the menu bar: `1.2M`, `340K`.
    static func compactRate(_ bytesPerSecond: Double) -> String {
        let units: [(Double, String)] = [
            (1_073_741_824, "G"), (1_048_576, "M"), (1_024, "K"),
        ]
        for (threshold, suffix) in units where bytesPerSecond >= threshold * unitPromotion {
            let scaled = bytesPerSecond / threshold
            return scaled >= 9.95
                ? String(format: "%.0f%@", scaled, suffix)
                : String(format: "%.1f%@", scaled, suffix)
        }
        // Sub-kilobyte traffic is still traffic. Reporting a flat "0K" for a
        // link that is quietly doing several hundred bytes a second reads as
        // "nothing is happening", which is the opposite of what it means.
        return bytesPerSecond >= 1 ? String(format: "%.0fB", bytesPerSecond) : "0"
    }

    static func percent(_ fraction: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f%%", fraction * 100)
    }

    static func temperature(_ celsius: Double, unit: TemperatureUnit) -> String {
        switch unit {
        case .celsius: return String(format: "%.0f°C", celsius)
        case .fahrenheit: return String(format: "%.0f°F", celsius * 9 / 5 + 32)
        }
    }

    static func temperatureValue(_ celsius: Double, unit: TemperatureUnit) -> Double {
        unit == .celsius ? celsius : celsius * 9 / 5 + 32
    }

    /// Precision switches where the *displayed* value crosses 10, not the raw
    /// one: 9.996 W under "%.2f" prints "10.00 W", the width the switch exists
    /// to avoid.
    static func watts(_ value: Double) -> String {
        value < 9.995 ? String(format: "%.2f W", value) : String(format: "%.1f W", value)
    }

    /// Accumulated energy in joules — the ledger's real, hardware-billed unit,
    /// unlike the live table's synthetic impact score. Same display-value
    /// promotion rules as everything else here.
    static func energy(_ joules: Double) -> String {
        let value = max(0, joules)
        if value < 0.9995 { return String(format: "%.0f mJ", value * 1000) }
        if value < 9.995 { return String(format: "%.2f J", value) }
        if value < 99.95 { return String(format: "%.1f J", value) }
        if value < 999.5 { return String(format: "%.0f J", value) }
        let kilojoules = value / 1000
        if kilojoules < 9.995 { return String(format: "%.2f kJ", kilojoules) }
        if kilojoules < 99.95 { return String(format: "%.1f kJ", kilojoules) }
        return String(format: "%.0f kJ", kilojoules)
    }

    /// Average draw over a window. Most apps average well under a watt, so
    /// this leads with milliwatts where `watts` would print "0.03 W".
    static func averagePower(_ value: Double) -> String {
        let clamped = max(0, value)
        if clamped < 0.009995 { return String(format: "%.1f mW", clamped * 1000) }
        if clamped < 0.9995 { return String(format: "%.0f mW", clamped * 1000) }
        return watts(clamped)
    }

    /// Promotes where MHz would *round* to four digits, so 999.6 reads
    /// "1.00 GHz" rather than "1000 MHz" — same rule as `unitPromotion`.
    static func frequency(_ megahertz: Double) -> String {
        megahertz >= 999.5
            ? String(format: "%.2f GHz", megahertz / 1000)
            : String(format: "%.0f MHz", megahertz)
    }

    static func duration(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// A short gap, in the units a person would use to say it.
    ///
    /// Separate from `duration`, which measures uptimes and rounds anything
    /// under a minute away to "0m". The intervals here are the seconds between
    /// two samples, where that rounding erases the entire quantity.
    static func shortInterval(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        // Branch where the displayed value changes form, not the raw one:
        // 9.96 under "%.1f" would print "10.0s", and 59.7 would print "60s"
        // where a minute reading is due. `duration` truncates, so hand it the
        // rounded value or 59.7 comes back as "0m".
        if seconds < 9.95 { return String(format: "%.1fs", seconds) }
        if seconds < 59.5 { return "\(Int(seconds.rounded()))s" }
        return duration(seconds.rounded())
    }

    /// Wall-clock time of a sample, to the second. Built once and reused: the
    /// hover readout re-formats on every pointer move.
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Template rather than a literal pattern, so a 12-hour locale gets
        // 12-hour times without the app deciding that on its behalf.
        formatter.setLocalizedDateFormatFromTemplate("jmmss")
        return formatter
    }()

    /// Minutes and seconds, for readouts too narrow to carry the hour.
    private static let shortClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("mmss")
        return formatter
    }()

    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    static func clockShort(_ date: Date) -> String {
        shortClockFormatter.string(from: date)
    }

    static func minutes(_ value: Int) -> String {
        let hours = value / 60
        let minutes = value % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius
    case fahrenheit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .celsius: return "Celsius"
        case .fahrenheit: return "Fahrenheit"
        }
    }

    var suffix: String {
        switch self {
        case .celsius: return "°C"
        case .fahrenheit: return "°F"
        }
    }
}
