import AppKit

// Renders the app icon from the very code that draws the menu bar rex.
//   render-icon <outdir> [time] [visual]
@main
enum RenderIcon {
    static func main() {
        let args = CommandLine.arguments
        let outDir = args[1]
        let time = args.count > 2 ? Double(args[2]) ?? Visualizer.restingTime : Visualizer.restingTime
        let visual = args.count > 3 ? Visualizer(rawValue: args[3]) ?? .rex : .rex
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        // macOS app icon grid: the rounded square spans 824/1024 of the canvas,
        // corner radius ≈ 22.5% of its side.
        let sizes: [(name: String, px: Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, px) in sizes {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let ctx = NSGraphicsContext(bitmapImageRep: rep)!
            NSGraphicsContext.current = ctx
            let cg = ctx.cgContext
            let s = CGFloat(px) / 1024
            cg.scaleBy(x: s, y: s)
            draw(in: cg, visual: visual, time: time)
            let png = rep.representation(using: .png, properties: [:])!
            try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
        }
        print("wrote icons to \(outDir)")
    }

    static func draw(in cg: CGContext, visual: Visualizer, time: Double) {
        let inset: CGFloat = 100
        let side: CGFloat = 1024 - 2 * inset
        let plate = CGRect(x: inset, y: inset, width: side, height: side)
        let radius: CGFloat = side * 0.2237
        let path = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Drop shadow under the plate, as the system icons have.
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
                     color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30))
        cg.addPath(path)
        cg.setFillColor(red: 0.20, green: 0.42, blue: 0.85, alpha: 1)
        cg.fillPath()
        cg.restoreGState()

        // Vertical gradient: the palette's CPU blue up top, deeper indigo below.
        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        let space = CGColorSpaceCreateDeviceRGB()
        let colors = [
            CGColor(red: 0.36, green: 0.68, blue: 1.00, alpha: 1),
            CGColor(red: 0.20, green: 0.46, blue: 0.94, alpha: 1),
            CGColor(red: 0.16, green: 0.30, blue: 0.78, alpha: 1),
        ] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1])!
        cg.drawLinearGradient(
            gradient, start: CGPoint(x: 512, y: plate.maxY), end: CGPoint(x: 512, y: plate.minY),
            options: [])
        // A soft highlight sweep across the top third.
        let glow = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
        ] as CFArray, locations: [0, 1])!
        cg.drawLinearGradient(
            glow, start: CGPoint(x: 512, y: plate.maxY), end: CGPoint(x: 512, y: plate.midY + 40),
            options: [])

        // The rex, drawn by the menu bar's own code at menu bar proportions.
        let canvas = Visualizer.canvasSize
        let width: CGFloat = side * 0.98
        let height = width * canvas.height / canvas.width
        let rect = CGRect(x: plate.midX - width / 2, y: plate.midY - height / 2 - 8,
                          width: width, height: height)
        // Figure shadow so the white reads against the lighter top of the plate.
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24,
                     color: CGColor(red: 0.05, green: 0.10, blue: 0.35, alpha: 0.45))
        cg.translateBy(x: rect.minX, y: rect.minY)
        cg.scaleBy(x: rect.width / canvas.width, y: rect.height / canvas.height)
        visual.draw(in: cg, rect: CGRect(origin: .zero, size: canvas),
                    time: time, load: 0.45, color: .white)
        cg.restoreGState()
        cg.restoreGState()
    }
}
