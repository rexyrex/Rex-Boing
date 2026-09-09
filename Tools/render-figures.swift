import AppKit

// Renders the README's menu bar figures from the very code that draws the
// menu bar, so the pictures cannot drift from the app.
//
//   swiftc -O -o /tmp/render-figures Tools/render-figures.swift \
//     RexBoing/StatusBar/Visualizer.swift RexBoing/StatusBar/StatusBarRenderer.swift \
//     RexBoing/App/Preferences.swift RexBoing/App/LoginItem.swift RexBoing/Metrics/Format.swift
//   /tmp/render-figures sheet docs/rexes.png [time]   every character × idle / working / flat out
//   /tmp/render-figures menubar docs/menubar.png      the status item: character plus two readouts
//
// `time` is the visualiser's own clock in cycles (default 1.3). Every
// character is a pure function of (time, load), so the same instant is
// reproducible frame for frame — see Visualizer.draw.
@main
enum RenderFigures {
    static let usage = "usage: render-figures sheet <out.png> [time] | menubar <out.png>"

    @MainActor static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print(usage); exit(2) }
        // Label colours resolve against the current drawing appearance; the
        // figures sit on dark ground, so draw them the way the menu bar's
        // dark appearance would.
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            switch args[1] {
            case "sheet":
                let time = args.count > 3 ? Double(args[3]) ?? 1.3 : 1.3
                sheet(to: args[2], time: time)
            case "menubar":
                menubar(to: args[2])
            default:
                print(usage); exit(2)
            }
        }
    }

    // MARK: - Contact sheet

    /// One row per character, one column per load. Each cell is the 36×22
    /// menu bar canvas scaled up whole, so proportions are exactly the bar's.
    @MainActor static func sheet(to path: String, time: Double) {
        let canvas = Visualizer.canvasSize
        let cellWidth = 240, cellHeight = 176
        let loads = [0.0, 0.5, 1.0]
        let rows = Visualizer.allCases
        let scale = CGFloat(cellWidth) / canvas.width
        let drawnHeight = canvas.height * scale

        let (rep, cg) = bitmap(
            pixelsWide: cellWidth * loads.count, pixelsHigh: cellHeight * rows.count)
        cg.setFillColor(red: 0.165, green: 0.169, blue: 0.20, alpha: 1)
        cg.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))

        for (row, visual) in rows.enumerated() {
            for (column, load) in loads.enumerated() {
                cg.saveGState()
                // Quartz origin is bottom-left: row 0 goes at the top.
                let x = CGFloat(column * cellWidth)
                let y = CGFloat((rows.count - 1 - row) * cellHeight)
                    + (CGFloat(cellHeight) - drawnHeight) / 2
                cg.translateBy(x: x, y: y)
                cg.scaleBy(x: scale, y: scale)
                visual.draw(
                    in: cg, rect: CGRect(origin: .zero, size: canvas),
                    time: time, load: load, color: .white)
                cg.restoreGState()
            }
        }
        write(rep, to: path)
        print("wrote \(path): \(rows.count) characters × \(loads.count) loads at time \(time)")
    }

    // MARK: - Menu bar item

    /// The status item as the bar shows it — the character in its slot beside
    /// two readouts — drawn through the readout renderer and the visualiser,
    /// magnified so the README can show it larger than 22 points.
    @MainActor static func menubar(to path: String) {
        let cells = [
            ReadoutCell(
                caption: MenuBarReadout.cpu.badge, value: "31%", tint: nil,
                width: StatusBarRenderer.width(for: .cpu)),
            ReadoutCell(
                caption: MenuBarReadout.memory.badge, value: "64%", tint: nil,
                width: StatusBarRenderer.width(for: .memory)),
        ]
        let layout = StatusBarRenderer.layout(cells: cells, hasVisual: true)
        let scale: CGFloat = 5.5
        let inset: CGFloat = 4  // points of bar either side, like the real item's neighbours

        guard let readouts = StatusBarRenderer.renderReadouts(
            cells: cells, layout: layout, monochrome: false, scale: scale)
        else { print("readout render failed"); exit(1) }

        let size = CGSize(width: layout.size.width + 2 * inset, height: layout.size.height)
        let (rep, cg) = bitmap(
            pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)))
        cg.setFillColor(gray: 0, alpha: 1)
        cg.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))

        cg.saveGState()
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: inset, y: 0)
        cg.draw(readouts, in: CGRect(origin: .zero, size: layout.size))
        cg.translateBy(x: layout.visual.minX, y: layout.visual.minY)
        Visualizer.rex.draw(
            in: cg, rect: CGRect(origin: .zero, size: layout.visual.size),
            time: 1.3, load: 0.3, color: .labelColor)
        cg.restoreGState()

        write(rep, to: path)
        print("wrote \(path): \(Int(size.width))×\(Int(size.height)) pt at \(scale)×")
    }

    // MARK: - Bitmaps

    static func bitmap(pixelsWide: Int, pixelsHigh: Int) -> (NSBitmapImageRep, CGContext) {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.setShouldAntialias(true)
        cg.interpolationQuality = .high
        return (rep, cg)
    }

    static func write(_ rep: NSBitmapImageRep, to path: String) {
        let png = rep.representation(using: .png, properties: [:])!
        try! png.write(to: URL(fileURLWithPath: path))
    }
}
