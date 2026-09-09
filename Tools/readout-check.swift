import AppKit

// Renders the menu bar readouts through the real drawing path and checks that
// every caption fits the column it was measured for.
//
//   swiftc -O -o /tmp/readout-check Tools/readout-check.swift \
//     RexBoing/StatusBar/StatusBarRenderer.swift RexBoing/App/Preferences.swift \
//     RexBoing/StatusBar/Visualizer.swift RexBoing/App/LoginItem.swift \
//     RexBoing/Metrics/Format.swift
//   /tmp/readout-check
//
// The captions used to be single letters, where nothing could ever be too wide
// for a column sized to "100%". Spelled out, they can be — so the width is
// taken from whichever of the two is wider, and this asserts that it worked.
@main
enum ReadoutCheck {
    @MainActor
    static func run() {
        // The renderer's own font, not a copy: measuring at a hard-coded size
        // would keep passing while a renderer font change clipped for real.
        let captionFont = StatusBarRenderer.captionFont
        var failures = 0

        var cells: [ReadoutCell] = []
        for readout in MenuBarReadout.allCases {
            let width = StatusBarRenderer.width(for: readout)
            let caption = NSAttributedString(
                string: readout.badge, attributes: [.font: captionFont]).size().width

            let verdict = caption <= width ? "ok" : "CLIPS"
            if caption > width { failures += 1 }
            print(String(
                format: "%-16@ badge %-5@ caption %5.1f  column %5.1f  %@",
                readout.rawValue as NSString, readout.badge as NSString,
                caption, width, verdict as NSString))

            cells.append(ReadoutCell(
                caption: readout.badge, value: "100%", tint: nil, width: width))
        }

        // Draw the lot, both as one strip and at a realistic three-readout
        // width, so the result can be looked at rather than only asserted on.
        write(cells: cells, to: "/tmp/readouts-all.png")
        write(
            cells: Array(cells.prefix(3)), to: "/tmp/readouts-typical.png")

        let total = StatusBarRenderer.layout(cells: cells, hasVisual: true).size.width
        let typical = StatusBarRenderer.layout(
            cells: Array(cells.prefix(3)), hasVisual: true).size.width
        print(String(format: "\nall ten readouts: %.1f pt", total))
        print(String(format: "cpu+gpu+mem:      %.1f pt", typical))

        print(failures == 0 ? "\nPASS" : "\n\(failures) caption(s) clip")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor
    private static func write(cells: [ReadoutCell], to path: String) {
        let layout = StatusBarRenderer.layout(cells: cells, hasVisual: true)
        guard let appearance = NSAppearance(named: .aqua) else { return }
        var rendered: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            rendered = StatusBarRenderer.renderReadouts(
                cells: cells, layout: layout, monochrome: false, scale: 2)
        }
        guard let image = rendered else {
            print("render failed for \(path)")
            return
        }

        // The readouts are drawn onto transparency, which is invisible against
        // the white a PNG viewer shows behind it. Flattened onto a menu-bar-ish
        // grey so the result can actually be looked at.
        let scale: CGFloat = 2
        guard let flattened = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: image.width, pixelsHigh: image.height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        flattened.size = NSSize(
            width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)

        guard let context = NSGraphicsContext(bitmapImageRep: flattened) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(white: 0.92, alpha: 1).setFill()
        NSRect(origin: .zero, size: flattened.size).fill()
        context.cgContext.draw(
            image, in: CGRect(origin: .zero, size: flattened.size))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = flattened.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    static func main() { MainActor.assumeIsolated { run() } }
}
