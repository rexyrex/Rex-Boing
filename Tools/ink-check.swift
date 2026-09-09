import AppKit

// Checks the visualiser's colour ramp without needing a menu bar.
//
//   swiftc -O -o /tmp/ink-check Tools/ink-check.swift \
//     RexBoing/UI/Theme.swift RexBoing/Metrics/Snapshot.swift RexBoing/Metrics/Format.swift
//   /tmp/ink-check
//
// `LoadInk` promises two things the eye cannot easily confirm on a live menu
// bar: that the field keeps the label colour, untouched, right up to the
// threshold — so a busy-but-not-alarming machine looks exactly like an idle
// one apart from its pace — and that above the threshold the colour moves
// continuously from the neutral into orange and on to red, with no step at
// the line and no dead grey on the way. This pins both down in components.
@main
enum InkCheck {
    static func main() {
        var failures = 0
        func fail(_ message: String) {
            failures += 1
            print("FAIL: \(message)")
        }

        // Both appearances' label colours, resolved the way the status item
        // resolves them: into device RGB, then made opaque.
        let neutrals: [(name: String, color: NSColor)] = [
            ("light", NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)),
            ("dark", NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)),
        ]

        for neutral in neutrals {
            // Below and at the threshold the neutral comes back as-is.
            for load in stride(from: -0.5, through: LoadInk.threshold, by: 0.05) + [LoadInk.threshold] {
                let ink = LoadInk.color(forLoad: load, neutral: neutral.color)
                if ink !== neutral.color {
                    fail("\(neutral.name) load \(load): expected the neutral object, got \(ink)")
                }
            }

            // Just over the line the colour has barely moved: the ramp fades
            // in rather than popping.
            let epsilon = LoadInk.color(forLoad: LoadInk.threshold + 0.005, neutral: neutral.color)
            if distance(epsilon, neutral.color) > 0.08 {
                fail("\(neutral.name): ramp steps at the threshold — \(describe(epsilon)) vs neutral")
            }

            // Orange at eighty, red at full load, both exact.
            let orange = LoadInk.color(forLoad: 0.80, neutral: neutral.color)
            if distance(orange, NSColor(deviceRed: 0.98, green: 0.56, blue: 0.24, alpha: 1)) > 0.01 {
                fail("\(neutral.name) load 0.80: expected Palette.high orange, got \(describe(orange))")
            }
            let red = LoadInk.color(forLoad: 1.0, neutral: neutral.color)
            if distance(red, NSColor(deviceRed: 0.96, green: 0.36, blue: 0.36, alpha: 1)) > 0.01 {
                fail("\(neutral.name) load 1.00: expected Palette.critical red, got \(describe(red))")
            }
            if LoadInk.color(forLoad: 1.7, neutral: neutral.color) != red {
                fail("\(neutral.name): load above 1 does not clamp to red")
            }

            // Every colour above the line is opaque, never grey, and the walk
            // from orange to red is monotonic: green falls, blue rises, red
            // holds within a hair. Sampled finer than the status item's own
            // two-hundred-step quantisation.
            var previous = orange
            for step in 1...100 {
                let load = 0.80 + 0.20 * Double(step) / 100
                let ink = LoadInk.color(forLoad: load, neutral: neutral.color)
                if ink.alphaComponent != 1 { fail("\(neutral.name) load \(load): not opaque") }
                if saturation(ink) < 0.5 {
                    fail("\(neutral.name) load \(load): washed out — \(describe(ink))")
                }
                if ink.greenComponent > previous.greenComponent + 1e-6
                    || ink.blueComponent < previous.blueComponent - 1e-6
                    || abs(ink.redComponent - previous.redComponent) > 0.01 {
                    fail("\(neutral.name) load \(load): orange→red walk reversed — \(describe(previous)) then \(describe(ink))")
                }
                previous = ink
            }

            // And the fade-in itself is monotonic too: each component heads
            // straight from the neutral to orange.
            var last = neutral.color
            for step in 1...20 {
                let load = LoadInk.threshold + (0.80 - LoadInk.threshold) * Double(step) / 20
                let ink = LoadInk.color(forLoad: load, neutral: neutral.color)
                for (a, b, target) in zip3(components(last), components(ink), components(orange)) {
                    let towards = (target - a)
                    let moved = (b - a)
                    if moved * towards < -1e-6 || abs(moved) > abs(towards) + 1e-6 {
                        fail("\(neutral.name) load \(load): fade-in overshoots or reverses — \(describe(last)) then \(describe(ink))")
                        break
                    }
                }
                last = ink
            }
        }

        // The controller's memo compares quantised loads; the ramp must be
        // deterministic for that to be a cache and not a coin flip.
        let a = LoadInk.color(forLoad: 0.91, neutral: neutrals[1].color)
        let b = LoadInk.color(forLoad: 0.91, neutral: neutrals[1].color)
        if a != b { fail("ramp is not deterministic") }

        for load in [0.0, 0.5, 0.69, 0.70, 0.72, 0.75, 0.80, 0.90, 1.0] {
            print(String(format: "load %.2f  dark: %@", load, describe(LoadInk.color(forLoad: load, neutral: neutrals[1].color))))
        }

        if failures == 0 {
            print("PASS")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }

    private static func components(_ c: NSColor) -> [CGFloat] {
        let rgb = c.usingColorSpace(.deviceRGB)!
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
    }

    private static func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        zip(components(a), components(b)).map { abs($0 - $1) }.max() ?? 0
    }

    private static func saturation(_ c: NSColor) -> CGFloat {
        let parts = components(c)
        let hi = parts.max()!, lo = parts.min()!
        return hi > 0 ? (hi - lo) / hi : 0
    }

    private static func describe(_ c: NSColor) -> String {
        let parts = components(c)
        return String(format: "(%.3f, %.3f, %.3f)", parts[0], parts[1], parts[2])
    }

    private static func zip3<A, B, C>(_ a: [A], _ b: [B], _ c: [C]) -> [(A, B, C)] {
        (0..<min(a.count, b.count, c.count)).map { (a[$0], b[$0], c[$0]) }
    }
}
