import AppKit
import ImageIO
import UniformTypeIdentifiers

// Animation frame renderer. Draws the app's own Visualizer (and, with
// --item, the status item's readouts) as transparent PNG sequences at any
// scale, with a scripted load curve. Time is integrated the way the status
// item does it: the clock advances at visual.rate(forLoad:) cycles a second.
// Tools/render-animations.sh turns its frames into the README's GIFs and the
// website's clips; the promo video's rex shots came from it too.
//
// render-frames --char rex --out DIR --scale 40 --fps 30 --dur 10
//               --loads "0:0.08,3:0.08,9:1,12:1" [--item] [--t0 0.4] [--mono]
//               [--color RRGGBB] [--list]

@main
enum RenderFrames {
    static var opts: [String: String] = [:]
    static var flags: Set<String> = []

    @MainActor static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let a = args.removeFirst()
            if a == "--item" || a == "--mono" || a == "--list" { flags.insert(a); continue }
            if a.hasPrefix("--"), !args.isEmpty { opts[a] = args.removeFirst() }
        }
        if flags.contains("--list") {
            for v in Visualizer.allCases { print(v.rawValue) }
            exit(0)
        }
        guard let charName = opts["--char"], let visual = Visualizer(rawValue: charName),
              let out = opts["--out"] else {
            print("usage: render-frames --char <name> --out <dir> [--scale s] [--fps f] [--dur d] [--loads t:l,...] [--item] [--t0 c]")
            exit(2)
        }
        let scale = CGFloat(Double(opts["--scale"] ?? "40") ?? 40)
        let fps = Double(opts["--fps"] ?? "30") ?? 30
        let dur = Double(opts["--dur"] ?? "4") ?? 4
        let t0 = Double(opts["--t0"] ?? "0.4") ?? 0.4
        let keys = parseLoads(opts["--loads"] ?? "0:0.5")
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            render(visual: visual, out: out, scale: scale, fps: fps, dur: dur, t0: t0, keys: keys)
        }
    }

    static func parseLoads(_ s: String) -> [(Double, Double)] {
        s.split(separator: ",").compactMap { pair in
            let p = pair.split(separator: ":")
            guard p.count == 2, let t = Double(p[0]), let l = Double(p[1]) else { return nil }
            return (t, l)
        }.sorted { $0.0 < $1.0 }
    }

    /// Smoothstep between keyframes so the ramp eases rather than kinks.
    static func load(at t: Double, _ keys: [(Double, Double)]) -> Double {
        guard let first = keys.first, let last = keys.last else { return 0.5 }
        if t <= first.0 { return first.1 }
        if t >= last.0 { return last.1 }
        for i in 0..<(keys.count - 1) where t >= keys[i].0 && t <= keys[i + 1].0 {
            let span = keys[i + 1].0 - keys[i].0
            var u = span > 0 ? (t - keys[i].0) / span : 1
            u = u * u * (3 - 2 * u)
            return keys[i].1 + (keys[i + 1].1 - keys[i].1) * u
        }
        return last.1
    }

    // LoadInk, reproduced: neutral below 0.70, orange by 0.80, red at 1.00.
    static let high = (0.98, 0.56, 0.24)
    static let critical = (0.96, 0.36, 0.36)
    static func ink(_ load: Double) -> NSColor {
        let l = min(1, max(0, load))
        func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> NSColor {
            NSColor(srgbRed: a.0 + (b.0 - a.0) * t, green: a.1 + (b.1 - a.1) * t,
                    blue: a.2 + (b.2 - a.2) * t, alpha: 1)
        }
        if let hex = opts["--color"], hex.count == 6, let v = Int(hex, radix: 16) {
            return NSColor(srgbRed: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255,
                           blue: Double(v & 255) / 255, alpha: 1)
        }
        if flags.contains("--mono") || l <= 0.70 { return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) }
        if l <= 0.80 { return mix((1, 1, 1), high, (l - 0.70) / 0.10) }
        return mix(high, critical, (l - 0.80) / 0.20)
    }

    // Severity.load tints for the readout value.
    static func tint(_ load: Double) -> NSColor? {
        switch load {
        case ..<0.6: return nil
        case ..<0.8: return NSColor(srgbRed: 0.95, green: 0.76, blue: 0.28, alpha: 1)
        case ..<0.93: return NSColor(srgbRed: 0.98, green: 0.56, blue: 0.24, alpha: 1)
        default: return NSColor(srgbRed: 0.96, green: 0.36, blue: 0.36, alpha: 1)
        }
    }

    @MainActor static func render(visual: Visualizer, out: String, scale: CGFloat, fps: Double,
                                  dur: Double, t0: Double, keys: [(Double, Double)]) {
        let canvas = Visualizer.canvasSize
        let item = flags.contains("--item")
        var layout: StatusBarRenderer.Layout?
        var size = canvas
        if item {
            let cells = cellsFor(load: 0.5)
            layout = StatusBarRenderer.layout(cells: cells, hasVisual: true)
            size = layout!.size
        }
        let w = Int(ceil(size.width * scale)), h = Int(ceil(size.height * scale))
        let frames = Int((dur * fps).rounded())
        var clock = t0
        let dt = 1 / fps
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for f in 0..<frames {
            let t = Double(f) * dt
            let l = load(at: t, keys)
            guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { exit(1) }
            cg.interpolationQuality = .high
            cg.setShouldAntialias(true)
            cg.saveGState()
            cg.scaleBy(x: scale, y: scale)
            if let layout {
                let cells = cellsFor(load: l)
                if let readouts = StatusBarRenderer.renderReadouts(
                    cells: cells, layout: layout, monochrome: false, scale: scale) {
                    cg.draw(readouts, in: CGRect(origin: .zero, size: layout.size))
                }
                cg.translateBy(x: layout.visual.minX, y: layout.visual.minY)
                visual.draw(in: cg, rect: CGRect(origin: .zero, size: layout.visual.size),
                            time: clock, load: l, color: ink(l))
            } else {
                visual.draw(in: cg, rect: CGRect(origin: .zero, size: canvas),
                            time: clock, load: l, color: ink(l))
            }
            cg.restoreGState()
            let image = cg.makeImage()!
            let url = URL(fileURLWithPath: String(format: "%@/f%05d.png", out, f))
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
            clock += visual.rate(forLoad: l) * dt
        }
        print("wrote \(frames) frames \(w)x\(h) to \(out)")
    }

    @MainActor static func cellsFor(load: Double) -> [ReadoutCell] {
        let cpu = Int((load * 100).rounded())
        return [
            ReadoutCell(caption: MenuBarReadout.cpu.badge, value: "\(cpu)%", tint: tint(load),
                        width: StatusBarRenderer.width(for: .cpu)),
            ReadoutCell(caption: MenuBarReadout.memory.badge, value: "64%", tint: nil,
                        width: StatusBarRenderer.width(for: .memory)),
        ]
    }
}
