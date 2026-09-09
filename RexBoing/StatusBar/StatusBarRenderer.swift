import AppKit

/// One column of text in the menu bar: a small caption over a value.
struct ReadoutCell: Equatable {
    var caption: String
    var value: String
    /// Non-nil only when the value has crossed into a warning range.
    var tint: NSColor?
    var width: CGFloat
}

/// Draws the readout half of the menu bar item. The visualiser half is
/// `VisualCanvas`, below.
///
/// They are deliberately separate images. The readouts change once a second at
/// most and cost real text layout; the visualiser changes on every frame and
/// costs almost nothing. Compositing them into a single image, as this used to,
/// meant every animation frame carried its own copy of the text and had to
/// re-run its layout. Kept apart, they go into two layers, and the text is
/// rasterised only when the text actually changes.
@MainActor
enum StatusBarRenderer {
    static let barHeight: CGFloat = 22
    /// The visualiser's box: the full height of the bar, and wide enough for
    /// the rex to travel in. Everything drawn in it tapers to nothing at the
    /// left and right edges, so this is a shape in its own right rather than a
    /// window cropped out of something larger.
    static let visualSize = Visualizer.canvasSize

    private static let columnGap: CGFloat = 7
    private static let leadingInset: CGFloat = 2
    private static let trailingInset: CGFloat = 3

    /// Internal rather than private: `Tools/readout-check.swift` measures
    /// captions with the renderer's own font, so a size change there cannot
    /// silently leave the check measuring at the old one.
    static let captionFont = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    /// Where everything sits inside the status item.
    struct Layout: Equatable {
        var size: CGSize
        /// The visualiser's frame within the item, in points. Empty when hidden.
        var visual: CGRect
        /// Left edge of the first readout column.
        var textOrigin: CGFloat
    }

    static func layout(cells: [ReadoutCell], hasVisual: Bool) -> Layout {
        let visualSpace = hasVisual ? visualSize.width : 0
        let cellsWidth = cells.reduce(0) { $0 + $1.width }
            + CGFloat(max(0, cells.count - 1)) * columnGap
        let gapAfterVisual: CGFloat = (hasVisual && !cells.isEmpty) ? columnGap - 1 : 0
        let width = max(
            24, leadingInset + visualSpace + gapAfterVisual + cellsWidth + trailingInset)

        return Layout(
            size: CGSize(width: width, height: barHeight),
            visual: hasVisual
                ? CGRect(
                    x: leadingInset,
                    y: (barHeight - visualSize.height) / 2,
                    width: visualSize.width, height: visualSize.height)
                : .zero,
            textOrigin: leadingInset + visualSpace + gapAfterVisual)
    }

    /// The row of readouts, with the visualiser's slot left transparent.
    ///
    /// Drawn eagerly into an explicit bitmap rather than through
    /// `NSImage(size:flipped:drawingHandler:)`. The handler form is lazy — it
    /// re-runs the drawing every time AppKit paints the image — which defeats
    /// the caller's cache and makes the item pay for text layout repeatedly.
    ///
    /// The trade-off is that `labelColor` resolves against whatever appearance
    /// is current at *render* time, so callers must wrap this in the status
    /// button's `performAsCurrentDrawingAppearance`.
    static func renderReadouts(
        cells: [ReadoutCell],
        layout: Layout,
        monochrome: Bool,
        scale: CGFloat
    ) -> CGImage? {
        guard let (rep, context) = bitmap(size: layout.size, scale: scale) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Both modes draw in the resolved label colours. Monochrome used to
        // draw black and lean on `isTemplate` to have AppKit tint it, but the
        // frame now goes straight into a layer, where template rendering does
        // not apply — black on a dark menu bar would be invisible. Monochrome
        // is therefore expressed the honest way: the same colours, minus the
        // severity tints.
        let primary = NSColor.labelColor
        let secondary = NSColor.secondaryLabelColor

        var x = layout.textOrigin
        for cell in cells {
            let valueColor = monochrome ? primary : (cell.tint ?? primary)

            draw(
                cell.caption, font: captionFont, color: secondary,
                in: NSRect(x: x, y: barHeight - 10.5, width: cell.width, height: 9))
            draw(
                cell.value, font: valueFont, color: valueColor,
                in: NSRect(x: x, y: 1.5, width: cell.width, height: 11))

            x += cell.width + columnGap
        }

        return rep.cgImage
    }

    // MARK: - Bitmaps

    private static func bitmap(
        size: CGSize, scale: CGFloat
    ) -> (NSBitmapImageRep, NSGraphicsContext)? {
        // Rounded up, not truncated: a width like 61.5 points at 2× is 123
        // pixels, and taking the floor shaved the last column off the final
        // readout on any item whose width did not land on a whole pixel.
        bitmap(
            pixelsWide: Int(ceil(size.width * scale)),
            pixelsHigh: Int(ceil(size.height * scale)),
            scale: scale)
    }

    private static func bitmap(
        pixelsWide: Int, pixelsHigh: Int, scale: CGFloat
    ) -> (NSBitmapImageRep, NSGraphicsContext)? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }

        // Before the context is made, not after: the graphics context works out
        // its point-to-pixel transform from the representation's size at the
        // moment it is created, and a size assigned afterwards is ignored. Get
        // this the wrong way round and everything draws at 1 point per pixel,
        // which on a Retina display means half size in the corner of the frame.
        rep.size = NSSize(
            width: CGFloat(pixelsWide) / scale, height: CGFloat(pixelsHigh) / scale)

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        return (rep, context)
    }

    /// Draws text centred in `rect`, shrinking it if it would otherwise clip.
    private static func draw(
        _ string: String, font: NSFont, color: NSColor, in rect: NSRect
    ) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]

        var text = NSAttributedString(string: string, attributes: attributes)
        if text.size().width > rect.width, let smaller = NSFont(
            descriptor: font.fontDescriptor, size: font.pointSize - 1) {
            attributes[.font] = smaller
            text = NSAttributedString(string: string, attributes: attributes)
        }

        let size = text.size()
        text.draw(at: NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2))
    }

    /// Measures the widest string a readout can produce, so the item does not
    /// resize on every sample as digits come and go.
    ///
    /// Memoised: laying out an `NSAttributedString` just to measure it was
    /// showing up as real CPU time when this ran on every animation frame.
    private static var widthCache: [MenuBarReadout: CGFloat] = [:]

    static func width(for readout: MenuBarReadout) -> CGFloat {
        if let cached = widthCache[readout] { return cached }

        let template: String
        switch readout {
        case .cpu, .gpu, .memory, .swap, .battery: template = "100%"
        case .cpuTemperature, .gpuTemperature: template = "100°"
        // Three digits: Ultra-class machines exceed 100 W package draw, and
        // "100.0W" is wider than any two-digit reading.
        case .power: template = "100.0W"
        // The value rows are the *up* direction — "↑" for network, "W" for
        // disk — and "W" is the widest glyph either row can lead with.
        case .network: template = "↑999M"
        case .disk: template = "W999M"
        }
        let value = NSAttributedString(
            string: template, attributes: [.font: valueFont]).size()
        // The caption is measured too, not assumed narrower. It is set four
        // sizes down, so for most readouts the value still wins — but a word
        // like "SWAP" over "100%" does not, and `draw` would silently shrink
        // the caption a point to fit rather than let the column grow. Network
        // and disk swap the badge for a live rate at runtime, so it is that
        // rate's widest form being measured, not the badge.
        let captionTemplate: String
        switch readout {
        case .network: captionTemplate = "↓999M"
        case .disk: captionTemplate = "R999M"
        default: captionTemplate = readout.badge
        }
        let caption = NSAttributedString(
            string: captionTemplate, attributes: [.font: captionFont]).size()
        let width = ceil(max(value.width, caption.width)) + 2
        widthCache[readout] = width
        return width
    }
}
