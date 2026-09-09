import AppKit

/// The animated tyrannosaur in the menu bar item.
///
/// This went through two ideas before settling. It started as a rigged animal
/// in the RunCat mould and was abandoned because a figure has to *read as
/// something* — at nineteen points tall, every pixel of silhouette is spent on
/// the viewer deciding what it is. Abstract fields (waves, helices, comets)
/// fixed that and were retired in turn: legible, smooth, and nobody's
/// favourite. The cast that stuck is a single chibi tyrannosaur in sixteen
/// temperaments, and it dodges the original objection two ways: a solid
/// Chrome-dino-style silhouette is simple enough to cost nothing in
/// recognition, and every animation moves the *whole* silhouette — bounce,
/// travel, rotation, squash — because at nineteen points limb motion alone
/// is a rumour.
///
/// Every visualiser here is a pure function of `(time, load)`. No accumulated
/// state, no random numbers — which means a frame can be reproduced exactly,
/// off screen, in a test or a preview, and the same code that draws the menu
/// bar draws the figures in the README.
enum Visualizer: String, CaseIterable, Identifiable {
    /// A chibi tyrannosaur at a gallop, ground streaming past.
    case rex
    /// The same tyrannosaur pointing up on the beat, down on the off-beat.
    case disco
    /// The same tyrannosaur jumping around; backflips arrive with load.
    case boing
    /// The same tyrannosaur sprinting the width of the bar and back.
    case dash
    /// The same tyrannosaur gone kaiju: high-knee stomps and shockwaves.
    case stomp
    /// The same tyrannosaur leaping after a fly it will never catch.
    case chomp
    /// The same tyrannosaur revving up and rolling the bar as a ball.
    case roll
    /// The same tyrannosaur on a jetpack, swooping the width of the bar.
    case rocket
    /// The same tyrannosaur skipping rope; double-unders arrive with load.
    case skip
    /// The same tyrannosaur on a bungee cord, booping the floor every bounce.
    case bungee
    /// The same tyrannosaur winding up a sneeze and blowing itself backwards.
    case achoo
    /// The same tyrannosaur on a skateboard: push, ollie, kick-turn, repeat.
    case shred

    case dragon
    case ninja
    case surf
    case lift

    /// Shared by the menu bar, gallery and rendering checks.
    static let canvasSize = CGSize(width: 36, height: 22)

    /// The fewest drawn frames one cycle of the motion may be spread over.
    /// Below about this a cyclic motion aliases — a gallop appears to stall,
    /// or to run backwards — however cleanly each frame is drawn. Shared by
    /// the status item's pace clamp and the settings preview, so the preview
    /// cannot strobe at a pace the menu bar would never be allowed to run.
    static let minimumFramesPerCycle: Double = 11

    var id: String { rawValue }

    var name: String {
        switch self {
        case .rex: return "Rex"
        case .disco: return "Disco"
        case .boing: return "Boing"
        case .dash: return "Dash"
        case .stomp: return "Stomp"
        case .chomp: return "Chomp"
        case .roll: return "Roll"
        case .rocket: return "Rocket"
        case .skip: return "Skip"
        case .bungee: return "Bungee"
        case .achoo: return "Achoo"
        case .shred: return "Shred"
        case .dragon: return "Dragon"
        case .ninja: return "Ninja"
        case .surf: return "Surf"
        case .lift: return "Lift"
        }
    }

    var detail: String {
        switch self {
        case .rex: return "A tyrannosaur at a gallop. A lazy trot at rest; a flat-out, worried sprint under load."
        case .disco: return "The same tyrannosaur pointing up on the beat, down on the off-beat. The tempo is the machine's."
        case .boing: return "The same tyrannosaur jumping around — higher and faster with load, backflips past two-thirds."
        case .dash: return "The same tyrannosaur with the zoomies: full-width sprints, skidding into the turns."
        case .stomp: return "The same tyrannosaur gone kaiju. Every footfall lands a shockwave; past two-thirds load it roars."
        case .chomp: return "The same tyrannosaur chasing a fly, leaping and snapping. The fly gets bolder with load."
        case .roll: return "The same tyrannosaur revving up and rolling the bar as a ball. Longer rev, harder launch with load."
        case .rocket: return "The same tyrannosaur on a jetpack it should not have. Barrel rolls arrive past two-thirds load."
        case .skip: return "The same tyrannosaur skipping rope, the rope whipping right round it every hop. Double-unders past two-thirds load."
        case .bungee: return "The same tyrannosaur on a bungee cord, booping the floor with its nose on every bounce. A full twist on the recoil past two-thirds load."
        case .achoo: return "The same tyrannosaur winding up a sneeze and letting it go. A bigger sneeze with load: it skids the rex backwards, then flips it."
        case .shred: return "The same tyrannosaur on a skateboard — push, ollie, kick-turn and back. Past two-thirds load the ollie spins the deck a whole turn."
        case .dragon: return "A winged rex riding the air. Under load, it breathes a flickering plume of fire."
        case .ninja: return "A headband, a blade and a sweeping strike. Faster slashes and longer ribbons under load."
        case .surf: return "Carving a rolling wave, with spray flying from the board. Bigger waves as the Mac gets busier."
        case .lift: return "A tiny heavyweight pressing a barbell overhead, then sinking into a deep squat."
        }
    }

    // MARK: - Pace

    /// Characteristic cycles per second at rest and flat out.
    ///
    /// One cycle is the shortest repeating unit of the visible motion: a
    /// stride pair, a jump, a pounce, one crossing of the bar. Keeping them
    /// all in the same units lets the frame rate be derived the same way
    /// whichever is on screen. The floor matters more for a creature than it
    /// did for the abstract fields these replaced: a field can drift, but a
    /// rex moving at a stride every five seconds reads as broken rather than
    /// calm.
    private var idleRate: Double {
        switch self {
        case .rex: return 0.50
        case .disco: return 0.50
        case .boing: return 0.45
        case .dash: return 0.35
        case .stomp: return 0.40
        case .chomp: return 0.45
        case .roll: return 0.35
        case .rocket: return 0.40
        case .skip: return 0.55
        case .bungee: return 0.35
        case .achoo: return 0.40
        case .shred: return 0.35
        case .dragon: return 0.45
        case .ninja: return 0.40
        case .surf: return 0.40
        case .lift: return 0.35
        }
    }

    /// Top pace at the default quality, before the preset's own factor.
    ///
    /// The ceilings are set against what Smooth can actually show, not against
    /// what would look most dramatic in isolation.
    /// `StatusItemController` holds the pace to `fps / minimumFramesPerCycle`,
    /// and Smooth's thirty-frame ceiling puts that at a shade over 2.7 cycles a
    /// second. The other presets scale these through
    /// `AnimationQuality.paceFactor` rather than fighting that clamp: asking a
    /// preset for more than its frame rate can show does not buy a faster
    /// rex — the clamp simply takes it back, and the only thing left of the
    /// request is a visualiser that hits its real maximum at part load and
    /// then flattens.
    private var maxRate: Double {
        switch self {
        case .rex: return 2.7
        case .disco: return 2.4
        case .boing: return 2.5
        case .dash: return 2.2
        // The stompers and travellers cap lower than the gallop: a cycle here
        // is a whole event — two footfalls, a pounce, a crossing — and past
        // about two a second the events stop reading as events.
        case .stomp: return 2.0
        case .chomp: return 2.2
        case .roll: return 2.0
        case .rocket: return 2.2
        case .skip: return 2.5
        case .bungee: return 2.0
        case .achoo: return 2.0
        case .shred: return 2.2
        case .dragon: return 2.2
        case .ninja: return 2.0
        case .surf: return 1.8
        case .lift: return 1.7
        }
    }

    /// Cycles per second for a given 0...1 CPU load.
    ///
    /// Linear, on purpose. This ran through two exponents (0.65, then 0.78)
    /// that eased the low end in faster, and both spent the range the same
    /// way: most of the visible change had arrived by a third load, so the
    /// busy half — every load worth distinguishing while something is
    /// actually running — looked much the same. A straight line spends its
    /// resolution evenly: each extra ten points of load buys the same extra
    /// pace, so thirty, fifty and eighty percent read as three different
    /// machines.
    ///
    /// `speedFactor` is the quality preset's scale on the top end (see
    /// `AnimationQuality.paceFactor`). The idle pace is a floor of legibility
    /// — a creature moving once every few seconds reads as broken, whatever
    /// the preset — so only the ceiling moves with what the preset can show.
    func rate(forLoad load: Double, speedFactor: Double = 1) -> Double {
        let clamped = min(1, max(0, load))
        let top = max(idleRate, maxRate * speedFactor)
        return idleRate + (top - idleRate) * clamped
    }

    /// The moment drawn when animation is off, or Reduce Motion is on. Not
    /// zero: every one of these starts a cycle in a symmetric, flat-looking
    /// state, which as a still frame reads as a bug rather than a pause.
    /// Chosen clear of every character's blink window too — at 0.31 the
    /// products with the rex and stomp blink clocks landed inside it, so the
    /// permanent still pose held the default character mid-squint. At 0.40
    /// every `time × blink speed` product sits in 0.064...0.100, all past the
    /// 0.06 window, eyes open across the cast.
    static let restingTime = 0.40

    // MARK: - Drawing

    /// Renders one instant.
    ///
    /// Drawn straight onto the `CGContext` rather than through `NSBezierPath`.
    /// This runs on every frame, and the path objects were most of its cost:
    /// each one allocates, then converts itself to a `CGPath` in order to be
    /// stroked, and a rex is a dozen strokes and fills. Handing the context
    /// its points directly, and setting colours from components instead of
    /// building an `NSColor` per alpha, halved the cost of a frame when the
    /// first visualisers were written, and keeps the whole cast under about
    /// eighty microseconds a frame at menu bar size.
    ///
    /// - Parameters:
    ///   - time: the visualiser's own clock, in cycles. Advances at `rate`, so
    ///     the caller changes the pace without the drawing knowing about load.
    ///   - load: 0...1, already smoothed. Shapes amplitude and density.
    ///   - rect: destination rectangle, in points.
    ///   - color: ink, expected fully opaque. Depth is expressed as alpha
    ///     *within* the drawing, and the label colour's own transparency is
    ///     applied to the layer, so translucent parts stay translucent against
    ///     each other rather than compounding at every crossing.
    func draw(
        in context: CGContext, rect: NSRect, time: Double, load: Double, color: NSColor
    ) {
        let energy = min(1, max(0, load))
        let pen = Pen(context: context, color: color, rect: rect)

        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(true)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch self {
        case .rex: drawRex(time: time, energy: energy, pen: pen)
        case .disco: drawDisco(time: time, energy: energy, pen: pen)
        case .boing: drawBoing(time: time, energy: energy, pen: pen)
        case .dash: drawDash(time: time, energy: energy, pen: pen)
        case .stomp: drawStomp(time: time, energy: energy, pen: pen)
        case .chomp: drawChomp(time: time, energy: energy, pen: pen)
        case .roll: drawRoll(time: time, energy: energy, pen: pen)
        case .rocket: drawRocket(time: time, energy: energy, pen: pen)
        case .skip: drawSkip(time: time, energy: energy, pen: pen)
        case .bungee: drawBungee(time: time, energy: energy, pen: pen)
        case .achoo: drawAchoo(time: time, energy: energy, pen: pen)
        case .shred: drawShred(time: time, energy: energy, pen: pen)
        case .dragon, .ninja, .surf, .lift:
            drawAdventure(time: time, energy: energy, pen: pen)
        }
    }
}

// MARK: - Pen

/// The context, the box, and the ink pre-separated into components.
///
/// The components matter. `NSColor.withAlphaComponent(_:).cgColor` allocates
/// two objects each time it is called, and these visualisers change alpha on
/// almost every stroke — that is what all the depth is made of. Setting a
/// colour from four floats allocates nothing.
private struct Pen {
    let context: CGContext
    let rect: NSRect
    private let red: CGFloat
    private let green: CGFloat
    private let blue: CGFloat
    private let base: CGFloat

    init(context: CGContext, color: NSColor, rect: NSRect) {
        self.context = context
        self.rect = rect
        // The fallback must itself be an RGB-space colour: the component
        // accessors raise for anything else, and `.white` is in gray space.
        let rgb = color.usingColorSpace(.deviceRGB)
            ?? NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
        red = rgb.redComponent
        green = rgb.greenComponent
        blue = rgb.blueComponent
        base = rgb.alphaComponent
    }

    /// Widths and radii are given as fractions of the box height rather than
    /// in points, so the whole drawing is scale-free. The same code then has to
    /// be right at twenty-two points in the menu bar and at ten times that in a
    /// figure for the README — and an absolute line width, which was what this
    /// started with, makes the large version look like a wireframe of the small
    /// one rather than the same picture.
    private var unit: CGFloat { rect.height }

    func stroke(_ points: [CGPoint], width: Double, alpha: Double) {
        guard points.count > 1 else { return }
        context.setStrokeColor(
            red: red, green: green, blue: blue, alpha: base * CGFloat(alpha))
        context.setLineWidth(CGFloat(width) * unit)
        context.addLines(between: points)
        context.strokePath()
    }

    func dot(at point: CGPoint, radius: Double, alpha: Double) {
        context.setFillColor(
            red: red, green: green, blue: blue, alpha: base * CGFloat(alpha))
        let r = CGFloat(radius) * unit
        context.fillEllipse(in: CGRect(
            x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
    }

    // The characters are built from solid shapes rather than strokes — a
    // silhouette survives nineteen points where an outline dissolves — with
    // eyes and mouths punched out, so they read as menu bar showing through
    // whatever the ink is. Strokes and dots still carry the thin parts: legs,
    // arms, tails, dust.

    /// A filled polygon.
    func fill(_ points: [CGPoint], alpha: Double) {
        guard points.count > 2 else { return }
        context.setFillColor(
            red: red, green: green, blue: blue, alpha: base * CGFloat(alpha))
        context.addLines(between: points)
        context.closePath()
        context.fillPath()
    }

    /// A stroked ellipse — the stomp's shockwave rings.
    func strokeEllipse(at center: CGPoint, rx: Double, ry: Double, width: Double, alpha: Double) {
        guard rx > 0, ry > 0 else { return }
        context.setStrokeColor(
            red: red, green: green, blue: blue, alpha: base * CGFloat(alpha))
        context.setLineWidth(CGFloat(width) * unit)
        let rxp = CGFloat(rx) * unit
        let ryp = CGFloat(ry) * unit
        context.strokeEllipse(in: CGRect(
            x: center.x - rxp, y: center.y - ryp, width: rxp * 2, height: ryp * 2))
    }

    /// A filled ellipse, rotated about its own centre.
    func fillEllipse(at center: CGPoint, rx: Double, ry: Double, rotation: Double, alpha: Double) {
        guard rx > 0, ry > 0 else { return }
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        if rotation != 0 { context.rotate(by: CGFloat(rotation)) }
        context.setFillColor(
            red: red, green: green, blue: blue, alpha: base * CGFloat(alpha))
        let rxp = CGFloat(rx) * unit
        let ryp = CGFloat(ry) * unit
        context.fillEllipse(in: CGRect(
            x: -rxp, y: -ryp, width: rxp * 2, height: ryp * 2))
        context.restoreGState()
    }

    /// Punches an ellipse out of everything drawn so far. One
    /// `CGBlendMode.clear` fill; the layer is transparent there afterwards.
    func punch(at center: CGPoint, rx: Double, ry: Double, rotation: Double) {
        guard rx > 0, ry > 0 else { return }
        context.saveGState()
        context.setBlendMode(.clear)
        context.translateBy(x: center.x, y: center.y)
        if rotation != 0 { context.rotate(by: CGFloat(rotation)) }
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        let rxp = CGFloat(rx) * unit
        let ryp = CGFloat(ry) * unit
        context.fillEllipse(in: CGRect(
            x: -rxp, y: -ryp, width: rxp * 2, height: ryp * 2))
        context.restoreGState()
    }

    /// Punches a stroked polyline — the grin.
    func punchStroke(_ points: [CGPoint], width: Double) {
        guard points.count > 1 else { return }
        context.saveGState()
        context.setBlendMode(.clear)
        context.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.setLineWidth(CGFloat(width) * unit)
        context.addLines(between: points)
        context.strokePath()
        context.restoreGState()
    }
}

// MARK: - Shared shaping

/// Fades everything to nothing at the left and right edges.
///
/// Without it the ground line and its scenery are sliced off by the frame and
/// the item reads as a cropped window onto something bigger. With it, the
/// scene appears to arrive and depart, and the whole thing sits in the menu
/// bar as one object.
private func envelope(_ x: Double) -> Double {
    pow(sin(.pi * min(1, max(0, x))), 0.62)
}

private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

// MARK: - Rex shared parts

// The four rexes are one body in four temperaments, so the parts are shared:
// a pose is a set of numbers, not a new drawing. Everything below is still a
// pure function of its arguments — the blink and the sweat run on the same
// deterministic clock as the swells and the bobs.

private func fract(_ v: Double) -> Double { v - v.rounded(.down) }
private func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
private func smoothstep(_ t: Double) -> Double { t * t * (3 - 2 * t) }

/// The eye's height factor: open almost always, one quick squeeze on a
/// deterministic schedule, so any frame still reproduces exactly.
private func blinkFactor(time: Double, speed: Double) -> Double {
    let bp = fract(time * speed)
    return bp < 0.06 ? max(0.08, 1 - sin(.pi * bp / 0.06)) : 1
}

/// Rotates a units-of-height offset and lands it around a centre point.
private func spun(
    _ dx: Double, _ dy: Double, by rot: Double, around center: CGPoint, unit h: Double
) -> CGPoint {
    let c = cos(rot), s = sin(rot)
    return CGPoint(
        x: center.x + (dx * c - dy * s) * h,
        y: center.y + (dx * s + dy * c) * h)
}

/// A faint ground line with ticks — scrolling ones make the clock rate read
/// as ground speed when the character runs on the spot; still ones give the
/// dancers a floor.
private func rexGround(_ pen: Pen, time: Double, gy: Double, speed: Double) {
    let w = Double(pen.rect.width), h = Double(pen.rect.height)
    for i in 0..<8 {
        let p0 = Double(i) / 8, p1 = Double(i + 1) / 8
        pen.stroke(
            [CGPoint(x: p0 * w, y: gy), CGPoint(x: p1 * w, y: gy)],
            width: 0.018, alpha: 0.16 * envelope((p0 + p1) / 2))
    }
    for k in 0..<6 {
        let pos = fract(Double(k) / 6 + 0.07 - time * speed)
        pen.stroke(
            [CGPoint(x: pos * w - 0.028 * h, y: gy + 0.038 * h),
             CGPoint(x: pos * w + 0.028 * h, y: gy + 0.038 * h)],
            width: 0.022, alpha: 0.38 * envelope(pos))
    }
}

/// Enlarges the character about a point on its ground line.
///
/// The rexes were tuned to about six tenths of the bar's height, and at
/// nineteen points that reads as a small figure next to the RunCat-sized
/// characters other apps put in the menu bar. Scaling the tuned drawing
/// beats re-deriving every coordinate — but it must happen *after* the scene
/// furniture (ground line, sparkles) so only the body and its own effects
/// grow, and the anchor must ride the body's x so travel distances stay in
/// scene units instead of being magnified off the ends of the box. The
/// factor is per-character: how much headroom each has depends on how high
/// it bounces or jumps.
private func rexZoom(_ pen: Pen, aboutX x: Double, groundY gy: Double, factor z: Double) {
    // Keep travelling bodies inside the wider slot at their turnarounds.
    // Effects may trail out, but the tail and muzzle need breathing room.
    let horizontalScale = z * 1.16
    let margin = Double(pen.rect.height) * horizontalScale
    let anchor = min(Double(pen.rect.width) - 0.37 * margin, max(0.46 * margin, x))
    pen.context.translateBy(x: anchor, y: gy)
    // Broader shoulders and tail make the silhouette readable at menu bar size.
    pen.context.scaleBy(x: z * 1.16, y: z * 1.03)
    pen.context.translateBy(x: -x, y: -gy)
}

/// Turns the character to face the other way without a snap.
///
/// Every traveller mirrors at the ends of the bar, and a mirror is an
/// instant: one frame facing right, the next facing left. Scaling the
/// figure flat about its own x through the wrap — down to a sliver, seen
/// end-on — puts the flip where it cannot be seen, which is how a
/// turn-around is drawn in two dimensions. Applied after `rexZoom`, so the
/// scene furniture stays put and only the body turns.
private func rexTurn(_ pen: Pen, aboutX x: Double, width: Double) {
    pen.context.translateBy(x: x, y: 0)
    pen.context.scaleBy(x: max(0.12, min(1, width)), y: 1)
    pen.context.translateBy(x: -x, y: 0)
}

/// How far into the turn a crossing is: 1 at the wrap, 0 away from it.
private func turnWindow(_ f: Double, span: Double = 0.07) -> Double {
    if f < span { return smoothstep(1 - f / span) }
    if f > 1 - span { return smoothstep((f - (1 - span)) / span) }
    return 0
}

/// The ground shadow that keeps feet on the floor — and, shrinking and
/// fading, sells the air whenever the body leaves it.
private func rexShadow(_ pen: Pen, cx: Double, gy: Double, width: Double, alpha: Double) {
    let h = Double(pen.rect.height)
    pen.fillEllipse(
        at: CGPoint(x: cx, y: gy + 0.030 * h), rx: width, ry: 0.024,
        rotation: 0, alpha: alpha)
}

/// The head: skull, snout, punched eye, and either a punched open mouth
/// (panting, singing, wheee) or a punched grin. `mirror` is ±1 for a rex
/// facing left; everything rotates together.
private func rexHead(
    _ pen: Pen, at head: CGPoint, rotation: Double, mirror: Double = 1,
    blink: Double, mouth: Double = 0, grin: Double = 0
) {
    let h = Double(pen.rect.height)
    func pt(_ dx: Double, _ dy: Double) -> CGPoint {
        spun(dx * mirror, dy, by: rotation, around: head, unit: h)
    }
    // A squared muzzle, brow and jaw keep the rex distinct from a bird.
    pen.fillEllipse(at: head, rx: 0.112, ry: 0.090, rotation: rotation, alpha: 1)
    pen.fill([pt(0.025, -0.057), pt(0.142, -0.043), pt(0.151, 0.027),
              pt(0.128, 0.071), pt(0.022, 0.065)], alpha: 1)
    pen.punch(at: pt(0.022, -0.022), rx: 0.023, ry: 0.022 * blink, rotation: rotation)
    pen.punch(at: pt(0.124, -0.015), rx: 0.009, ry: 0.008, rotation: rotation)
    if mouth > 0.03 {
        pen.punch(at: pt(0.100, 0.056), rx: 0.032 * mouth, ry: 0.020 * mouth, rotation: rotation)
    } else if grin > 0.03 {
        pen.punchStroke(
            [pt(0.068, 0.052), pt(0.096, 0.061), pt(0.124, 0.049)], width: 0.013)
    }
}

/// The tail: two tapering segments with independent wag offsets, so it can
/// lag whatever the body is doing.
private func rexTail(
    _ pen: Pen, base: CGPoint, wag1: Double, wag2: Double, mirror: Double, alpha: Double
) {
    let h = Double(pen.rect.height)
    let t1 = CGPoint(x: base.x - mirror * 0.110 * h, y: base.y - 0.042 * h + wag1)
    let t2 = CGPoint(x: t1.x - mirror * 0.095 * h, y: t1.y - 0.042 * h + wag2)
    pen.stroke([base, t1], width: 0.078, alpha: alpha)
    pen.stroke([t1, t2], width: 0.042, alpha: alpha)
}

/// An arm: shoulder, elbow, hand, and a little fist. Three inches long.
private func rexArm(_ pen: Pen, shoulder: CGPoint, elbow: CGPoint, hand: CGPoint, alpha: Double) {
    pen.stroke([shoulder, elbow, hand], width: 0.032, alpha: alpha)
    pen.dot(at: hand, radius: 0.018, alpha: alpha)
}

/// A planted leg: hip to foot with a bent knee and a toe.
private func rexPlantLeg(
    _ pen: Pen, hip: CGPoint, footX: Double, footY: Double,
    kneeOut: Double, mirror: Double, alpha: Double
) {
    let h = Double(pen.rect.height)
    let knee = CGPoint(x: (hip.x + footX) / 2 + mirror * kneeOut * h, y: (hip.y + footY) / 2)
    pen.stroke([hip, knee, CGPoint(x: footX, y: footY)], width: 0.062, alpha: alpha)
    pen.stroke(
        [CGPoint(x: footX, y: footY),
         CGPoint(x: footX + mirror * 0.044 * h, y: footY - 0.005 * h)],
        width: 0.050, alpha: alpha)
}

// MARK: - Rex

private extension Visualizer {
    /// The runner as a gallop. At nineteen points the bounce IS the
    /// animation — the whole body rises and falls a tenth of the box every
    /// stride — with stretched strides and a streaming ground backing it up.
    func drawRex(time: Double, energy: Double, pen: Pen) {
        // The characters were tuned y-down — ground along the bottom edge —
        // in the canvas prototypes; flipping the context once beats negating
        // every coordinate. The caller's save/restore unwinds it.
        pen.context.translateBy(x: 0, y: pen.rect.height)
        pen.context.scaleBy(x: 1, y: -1)

        let w = Double(pen.rect.width), h = Double(pen.rect.height)
        let gy = 0.87 * h
        rexGround(pen, time: time, gy: gy + 0.02 * h, speed: 0.85)
        rexZoom(pen, aboutX: 0.42 * w, groundY: gy, factor: 1.28)

        let P = 2 * .pi * time                     // one cycle = one stride
        let air = pow(max(0, sin(P + 0.3)), 0.8)
        // The stance half of the stride, for the body to squash onto — a
        // gallop's bounce is a body being compressed and released, not a
        // rigid shape on a sine.
        let contact = pow(max(0, -sin(P + 0.3)), 1.3)
        // Slightly shallower than before the zoom, deeper after it: the
        // bounce is scaled with the body, and the head has to clear the top
        // of the box at the peak of a full-load stride.
        let bAmp = (0.070 + 0.060 * energy) * h
        let lean = 0.16 + 0.38 * energy + 0.06 * sin(P)
        let body = CGPoint(x: 0.42 * w, y: 0.585 * h - bAmp * air)
        func off(_ dx: Double, _ dy: Double) -> CGPoint {
            spun(dx, dy, by: lean * 0.6, around: body, unit: h)
        }

        rexShadow(
            pen, cx: body.x + 0.02 * h, gy: gy,
            width: 0.165 - 0.055 * air, alpha: 0.16 * (1 - 0.45 * air))

        let hip = off(-0.048, 0.078)
        let strideScale = 1.00 + 0.55 * energy
        func leg(_ phase: Double, _ alpha: Double) {
            let lift = max(0, sin(phase))
            // Negative cosine keeps the gait honest: grounded feet drive
            // backwards, airborne feet swing forwards. And feet reach for the
            // ground but travel with the body when it is airborne — a stance
            // leg has a length, and the flight phase is the point of a gallop.
            let fx = hip.x - 0.135 * h * cos(phase) * strideScale + 0.018 * h
            let fy = min(gy, hip.y + 0.185 * h) - lift * 0.145 * h
            let knee = CGPoint(
                x: (hip.x + fx) / 2 + (0.050 + 0.020 * lift) * h,
                y: (hip.y + fy) / 2)
            pen.stroke([hip, knee, CGPoint(x: fx, y: fy)], width: 0.062, alpha: alpha)
            pen.stroke(
                [CGPoint(x: fx, y: fy), CGPoint(x: fx + 0.044 * h, y: fy - 0.005 * h)],
                width: 0.050, alpha: alpha)
        }
        // The far leg is dimmed only slightly: enough to sit behind the body,
        // not so much that it goes missing against the menu bar.
        leg(P + .pi, 0.85)

        rexTail(
            pen, base: off(-0.140, -0.005),
            wag1: 0.030 * h * sin(P + 1.6), wag2: 0.072 * h * sin(P + 2.1),
            mirror: 1, alpha: 1)

        pen.fillEllipse(
            at: body, rx: 0.165 * (1 + 0.06 * contact - 0.03 * air),
            ry: 0.120 * (1 - 0.07 * contact + 0.04 * air),
            rotation: lean * 0.6, alpha: 1)
        leg(P, 1)

        let arm0 = off(0.098, 0.014)
        rexArm(
            pen, shoulder: arm0,
            elbow: CGPoint(x: arm0.x + 0.034 * h, y: arm0.y + 0.028 * h),
            hand: CGPoint(
                x: arm0.x + 0.064 * h,
                y: arm0.y - 0.012 * h + 0.030 * h * sin(P + 1.4)),
            alpha: 1)

        var head = off(0.118, -0.185)
        head.y += 0.042 * h * max(0, sin(P - 0.6))          // follow-through lag
        pen.fill([
            off(0.050, -0.060), off(0.135, -0.125),
            CGPoint(x: head.x - 0.02 * h, y: head.y + 0.06 * h),
            CGPoint(x: head.x - 0.085 * h, y: head.y + 0.025 * h),
        ], alpha: 1)
        let pant = clamp01((energy - 0.55) * 3) * (0.6 + 0.4 * sin(2 * P))
        rexHead(
            pen, at: head, rotation: lean * 0.6 + 0.08,
            blink: blinkFactor(time: time, speed: 0.17), mouth: pant)

        // Effort, made visible: sweat past seventy percent.
        let sweatGate = clamp01((energy - 0.70) / 0.30)
        if sweatGate > 0.01 {
            for k in 0..<2 {
                let dp = fract(time * 1.1 + Double(k) * 0.5)
                let sxp = head.x + (k == 0 ? -1 : 0.4) * (0.05 + 0.11 * dp) * h
                let syp = head.y - (0.09 + 0.06 * dp - 0.11 * dp * dp) * h
                pen.dot(
                    at: CGPoint(x: sxp, y: syp), radius: 0.016,
                    alpha: (1 - dp) * 0.8 * sweatGate)
            }
        }
    }
}

// MARK: - Disco

private extension Visualizer {
    /// The whole body swings — hips a tenth of the box, deep dips, a head
    /// tilting hard against them — under a longer point than any real
    /// tyrannosaur could manage. One cycle is an up point and a down point.
    func drawDisco(time: Double, energy: Double, pen: Pen) {
        // Flipped y-down like the other characters; see drawRex.
        pen.context.translateBy(x: 0, y: pen.rect.height)
        pen.context.scaleBy(x: 1, y: -1)

        let w = Double(pen.rect.width), h = Double(pen.rect.height)
        let gy = 0.87 * h
        rexGround(pen, time: time, gy: gy + 0.02 * h, speed: 0)

        let B = 2 * .pi * time
        let pt = sin(B)
        let dip2 = 0.5 - 0.5 * cos(2 * B)
        let body = CGPoint(
            x: 0.45 * w + 0.080 * h * pt,
            y: 0.600 * h + 0.046 * h * dip2 * (0.8 + 0.5 * energy))
        let rot = 0.22 * pt
        func off(_ dx: Double, _ dy: Double) -> CGPoint {
            spun(dx, dy, by: rot, around: body, unit: h)
        }

        // Sparkles, alternating corners on the beat. Drawn before the zoom:
        // they hang in the air around the dancer, and magnified with the body
        // the top pair would leave the box.
        let tw1 = pow(max(0, pt), 2), tw2 = pow(max(0, -pt), 2)
        let sparkles: [(x: Double, y: Double, tw: Double)] = [
            (body.x - 0.26 * h, 0.26 * h, tw2),
            (body.x + 0.30 * h, 0.18 * h, tw1),
            (body.x + 0.05 * h, 0.10 * h, dip2),
        ]
        for sparkle in sparkles {
            let arm = (0.032 + 0.030 * sparkle.tw) * h
            let alpha = 0.18 + 0.62 * sparkle.tw
            pen.stroke(
                [CGPoint(x: sparkle.x - arm, y: sparkle.y),
                 CGPoint(x: sparkle.x + arm, y: sparkle.y)],
                width: 0.017, alpha: alpha)
            pen.stroke(
                [CGPoint(x: sparkle.x, y: sparkle.y - arm),
                 CGPoint(x: sparkle.x, y: sparkle.y + arm)],
                width: 0.017, alpha: alpha)
        }

        // The dancer plants its feet, so it carries the biggest zoom of the
        // family: no jump arc to keep clear of the top of the box.
        rexZoom(pen, aboutX: body.x, groundY: gy, factor: 1.38)

        rexShadow(pen, cx: body.x + 0.01 * h, gy: gy, width: 0.165, alpha: 0.16)

        // Far arm mirrors the pose, dimmed, behind the body.
        let shF = off(0.075, -0.045)
        let angF = lerp(0.65, -1.30, (1 - pt) / 2)
        let eF = CGPoint(
            x: shF.x + 0.042 * h * cos(angF + 0.45),
            y: shF.y + 0.042 * h * sin(angF + 0.45))
        rexArm(
            pen, shoulder: shF, elbow: eF,
            hand: CGPoint(x: eF.x + 0.098 * h * cos(angF), y: eF.y + 0.098 * h * sin(angF)),
            alpha: 0.38)

        // Weight leg planted; free foot stepping wide with a real lift.
        rexPlantLeg(
            pen, hip: off(-0.055, 0.072), footX: body.x - 0.095 * h, footY: gy,
            kneeOut: 0.040, mirror: 1, alpha: 0.85)
        rexTail(
            pen, base: off(-0.138, -0.005),
            wag1: -0.038 * h * pt, wag2: -0.098 * h * sin(B - 0.5),
            mirror: 1, alpha: 1)
        pen.fillEllipse(at: body, rx: 0.165, ry: 0.120, rotation: rot, alpha: 1)
        let tapX = body.x + 0.070 * h + 0.098 * h * pt
        let tapLift = 0.065 * h * max(0, sin(2 * B + 0.4))
        rexPlantLeg(
            pen, hip: off(0.045, 0.072), footX: tapX, footY: gy - tapLift,
            kneeOut: 0.048, mirror: 1, alpha: 1)

        // The pointing arm. John Travolta, at last with some reach.
        let sh = off(0.095, -0.040)
        let ang = lerp(-1.30, 0.65, (1 - pt) / 2)
        let el = CGPoint(
            x: sh.x + 0.058 * h * cos(ang + 0.45),
            y: sh.y + 0.058 * h * sin(ang + 0.45))
        rexArm(
            pen, shoulder: sh, elbow: el,
            hand: CGPoint(x: el.x + 0.125 * h * cos(ang), y: el.y + 0.125 * h * sin(ang)),
            alpha: 1)

        // Head: big tilt against the hip, chin up when the point goes up.
        var head = off(0.112, -0.180)
        head.y -= 0.024 * h * pt
        pen.fill([
            off(0.048, -0.058), off(0.132, -0.120),
            CGPoint(x: head.x - 0.02 * h, y: head.y + 0.06 * h),
            CGPoint(x: head.x - 0.085 * h, y: head.y + 0.025 * h),
        ], alpha: 1)
        let woo = clamp01((energy - 0.75) * 4) * (0.5 + 0.5 * pt)
        rexHead(
            pen, at: head, rotation: rot - 0.30 * pt,
            blink: blinkFactor(time: time, speed: 0.23), mouth: woo, grin: 1 - woo)
    }
}

// MARK: - Boing

private extension Visualizer {
    /// Jumping around: squash to anticipate, a leap that clears a third of
    /// the box, a landing that raises dust, then over again the other way —
    /// each landing spot is the next jump's start, so the hops chain. Past
    /// two-thirds load the leap becomes a full backflip, eyes shut.
    func drawBoing(time: Double, energy: Double, pen: Pen) {
        // Flipped y-down like the other characters; see drawRex.
        pen.context.translateBy(x: 0, y: pen.rect.height)
        pen.context.scaleBy(x: 1, y: -1)

        let w = Double(pen.rect.width), h = Double(pen.rect.height)
        let gy = 0.87 * h
        rexGround(pen, time: time, gy: gy + 0.02 * h, speed: 0)

        let cycle = time.rounded(.down)
        let phi = time - cycle                    // one cycle = one jump
        let dir: Double = Int(cycle) % 2 == 0 ? 1 : -1
        let xFrom = 0.5 * w - dir * 0.150 * w
        let xTo = 0.5 * w + dir * 0.150 * w
        let crouchEnd = 0.20, landStart = 0.80
        // The arc trades height for the zoomed body: what the jump lost in
        // box-fractions the bigger character gives back in points, and the
        // ceiling is set where the head still clears the top of the box at
        // the apex of an unflipped hop.
        let jumpH = (0.14 + 0.08 * energy) * h
        // A narrow gate: in steady state the flip is cleanly off or on, and
        // the smoothed load glides through the partial-rotation band in under
        // a second on its way between them.
        let flipGate = clamp01((energy - 0.62) / 0.16)
        // The rotation itself is always a whole number of turns. A machine
        // *parked* mid-band — a steady 70% encode — holds a partial gate
        // indefinitely, and a partial turn lands the rex upside-down and
        // snaps it upright on every touchdown. The gate still blends the
        // stretch and the tilt; only the spin quantises.
        let flips = flipGate.rounded()

        var x = xFrom, by = 0.615 * h
        var sx = 1.0, sy = 1.0, rot = 0.0, airArc = 0.0
        if phi < crouchEnd {                       // anticipation
            let c = sin(.pi * (phi / crouchEnd))
            by = 0.615 * h + 0.055 * h * c
            sy = 1 - 0.30 * c; sx = 1 + 0.26 * c
        } else if phi < landStart {                // flight
            let t = (phi - crouchEnd) / (landStart - crouchEnd)
            airArc = sin(.pi * t)
            x = lerp(xFrom, xTo, smoothstep(t))
            by = 0.615 * h - jumpH * airArc
            let vel = abs(cos(.pi * t))
            sy = 1 + 0.20 * vel * (1 - 0.5 * flipGate); sx = 1 / sy
            rot = dir * (0.24 * airArc * (1 - flipGate)
                - 2 * .pi * smoothstep(t) * flips)
        } else {                                   // landing
            let c = sin(.pi * ((phi - landStart) / (1 - landStart)))
            x = xTo
            by = 0.615 * h + 0.065 * h * c
            sy = 1 - 0.34 * c; sx = 1 + 0.30 * c
        }
        let body = CGPoint(x: x, y: by)
        func off(_ dx: Double, _ dy: Double) -> CGPoint {
            spun(dx, dy, by: rot, around: body, unit: h)
        }

        // The smallest zoom of the family: the jump arc and the backflip's
        // head sweep both need the airspace above the body.
        rexZoom(pen, aboutX: x, groundY: gy, factor: 1.18)

        rexShadow(
            pen, cx: x, gy: gy,
            width: 0.165 - 0.075 * airArc, alpha: 0.16 * (1 - 0.55 * airArc))

        // Landing dust, kicked out to both sides.
        if phi > landStart {
            let dp = (phi - landStart) / (1 - landStart)
            for side in [-1.0, 1.0] {
                pen.dot(
                    at: CGPoint(
                        x: xTo + side * (0.09 + 0.13 * dp) * h,
                        y: gy - 0.02 * h - 0.03 * h * dp),
                    radius: 0.020 * (1 - 0.4 * dp), alpha: (1 - dp) * 0.45)
                pen.dot(
                    at: CGPoint(x: xTo + side * (0.05 + 0.09 * dp) * h, y: gy - 0.05 * h * dp),
                    radius: 0.014, alpha: (1 - dp) * 0.35)
            }
        }

        // Legs: planted and bending on the ground; in the air, knees up and
        // feet forward. Forward, not under: a foot tucked straight under the
        // hip is inside the belly at this size, and legs that hang straight
        // down read as standing in mid-air rather than jumping.
        if airArc > 0.02 {
            let footFar = off(0.045, 0.165), footNear = off(0.110, 0.150)
            rexPlantLeg(
                pen, hip: off(-0.050, 0.075), footX: footFar.x, footY: footFar.y,
                kneeOut: 0.070, mirror: 1, alpha: 0.85)
            rexPlantLeg(
                pen, hip: off(0.042, 0.075), footX: footNear.x, footY: footNear.y,
                kneeOut: 0.072, mirror: 1, alpha: 1)
        } else {
            let bend = 0.040 + 0.030 * (1 - sy)
            rexPlantLeg(
                pen, hip: off(-0.050, 0.075), footX: x - 0.085 * h, footY: gy,
                kneeOut: bend, mirror: 1, alpha: 0.85)
            rexPlantLeg(
                pen, hip: off(0.042, 0.075), footX: x + 0.080 * h, footY: gy,
                kneeOut: bend + 0.008, mirror: 1, alpha: 1)
        }

        let tailW1: Double, tailW2: Double
        if airArc > 0.02 {
            let t = (phi - crouchEnd) / (landStart - crouchEnd)
            tailW1 = 0.030 * h * cos(.pi * t)
            tailW2 = -0.060 * h * airArc * dir
        } else {
            tailW1 = 0.030 * h * sin(2 * .pi * phi)
            tailW2 = 0.060 * h * sin(2 * .pi * phi - 0.6)
        }
        rexTail(pen, base: off(-0.140, -0.005), wag1: tailW1, wag2: tailW2, mirror: 1, alpha: 1)

        pen.fillEllipse(at: body, rx: 0.165 * sx, ry: 0.120 * sy, rotation: rot, alpha: 1)

        // Arms: tucked on the ground, thrown up in the air. Wheee.
        if airArc > 0.02 {
            rexArm(pen, shoulder: off(0.095, -0.030), elbow: off(0.115, -0.075),
                   hand: off(0.130, -0.125), alpha: 1)
        } else {
            let a0 = off(0.098, 0.012)
            rexArm(
                pen, shoulder: a0,
                elbow: CGPoint(x: a0.x + 0.032 * h, y: a0.y + 0.026 * h),
                hand: CGPoint(x: a0.x + 0.060 * h, y: a0.y + 0.004 * h), alpha: 1)
        }

        // The head follows through: it arrives a beat after the body on
        // every squash, so the landing reads as weight rather than a pose.
        let lagPhi = fract(phi - 0.05)
        let lagSquash = lagPhi < crouchEnd
            ? sin(.pi * (lagPhi / crouchEnd))
            : (lagPhi > landStart ? sin(.pi * ((lagPhi - landStart) / (1 - landStart))) : 0)
        let squash = phi < crouchEnd
            ? sin(.pi * (phi / crouchEnd))
            : (phi > landStart ? sin(.pi * ((phi - landStart) / (1 - landStart))) : 0)
        let head = off(0.115, -0.182 + 0.032 * lagSquash)
        pen.fill([
            off(0.048, -0.058), off(0.132, -0.122),
            spun(-0.020, 0.060, by: rot, around: head, unit: h),
            spun(-0.085, 0.025, by: rot, around: head, unit: h),
        ], alpha: 1)
        let shutEyes = airArc > 0.02 ? flipGate : 0
        let whee = airArc * (0.35 + 0.55 * energy)
        rexHead(
            pen, at: head, rotation: rot + 0.06 + 0.10 * lagSquash,
            blink: blinkFactor(time: time, speed: 0.25) * (1 - 0.85 * shutEyes)
                * (1 - 0.55 * squash),
            mouth: whee, grin: 1 - whee)
    }
}

// MARK: - Dash

private extension Visualizer {
    /// The app's name, embodied: full-width sprints back and forth, leaning
    /// hard into the travel, speed lines behind, skidding into every turn.
    /// The largest possible motion in the box — unmissable at any size. One
    /// cycle is one crossing, and the rex mirrors when it turns.
    func drawDash(time: Double, energy: Double, pen: Pen) {
        // Flipped y-down like the other characters; see drawRex.
        pen.context.translateBy(x: 0, y: pen.rect.height)
        pen.context.scaleBy(x: 1, y: -1)

        let w = Double(pen.rect.width), h = Double(pen.rect.height)
        let gy = 0.87 * h
        rexGround(pen, time: time, gy: gy + 0.02 * h, speed: 0)

        let crossing = time.rounded(.down)
        let f = time - crossing                   // one cycle = one crossing
        let m: Double = Int(crossing) % 2 == 0 ? 1 : -1
        let xe = 0.5 - 0.5 * cos(.pi * f)         // easing in and out of the turns
        let x = lerp(0.15 * w, 0.85 * w, m > 0 ? xe : 1 - xe)
        let speed = sin(.pi * f)
        let lean = m * (0.08 + 0.52 * speed * (0.50 + 0.50 * energy))

        let scramble = 2 * .pi * time * 3.5       // legs cycle faster than crossings
        let body = CGPoint(x: x, y: 0.600 * h - 0.045 * h * abs(sin(scramble)) * speed)
        func off(_ dx: Double, _ dy: Double) -> CGPoint {
            spun(dx * m, dy, by: lean, around: body, unit: h)
        }

        // Zoomed about the sprint position, so the crossing still spans the
        // bar in scene units and only the runner grows. The snout kissing the
        // frame at the extremes of a turn is the price of the full-width run,
        // and it reads as intent rather than damage.
        rexZoom(pen, aboutX: x, groundY: gy, factor: 1.32)

        rexShadow(pen, cx: x, gy: gy, width: 0.165, alpha: 0.16)
        // The turn: flat through the wrap, so the mirror lands end-on. It
        // also keeps the tail inside the box at the extremes of the run.
        rexTurn(pen, aboutX: x, width: 1 - 0.88 * turnWindow(f))

        // Speed lines trailing the sprint.
        let lineAlpha = 0.50 * speed * clamp01(0.25 + energy)
        if lineAlpha > 0.03 {
            for k in 0..<3 {
                let y = body.y + (Double(k) - 1) * 0.075 * h
                pen.stroke(
                    [CGPoint(x: x - m * (0.22 + 0.03 * Double(k)) * h, y: y),
                     CGPoint(x: x - m * (0.44 + 0.06 * Double(k)) * h, y: y)],
                    width: 0.022, alpha: lineAlpha * (1 - 0.22 * Double(k)))
            }
        }
        // Skid dust into the turns.
        let skid = clamp01((energy - 0.40) * 2.5) * pow(max(0, f - 0.82) / 0.18, 1.5)
        if skid > 0.02 {
            for k in 0..<3 {
                pen.dot(
                    at: CGPoint(
                        x: x - m * (0.12 + 0.06 * Double(k)) * h,
                        y: gy - 0.02 * h - 0.02 * h * Double(k)),
                    radius: 0.018, alpha: skid * 0.5 * (1 - 0.25 * Double(k)))
            }
        }

        let hip = off(-0.048, 0.078)
        func leg(_ phase: Double, _ alpha: Double) {
            let lift = max(0, sin(phase))
            let fx = hip.x - m * 0.130 * h * cos(phase) * (0.55 + 0.75 * speed)
            let fy = gy - lift * 0.130 * h * (0.45 + 0.65 * speed)
            let knee = CGPoint(x: (hip.x + fx) / 2 + m * 0.048 * h, y: (hip.y + fy) / 2)
            pen.stroke([hip, knee, CGPoint(x: fx, y: fy)], width: 0.062, alpha: alpha)
            pen.stroke(
                [CGPoint(x: fx, y: fy), CGPoint(x: fx + m * 0.042 * h, y: fy - 0.005 * h)],
                width: 0.050, alpha: alpha)
        }
        leg(scramble + .pi, 0.85)
        rexTail(
            pen, base: off(-0.140, -0.005),
            wag1: 0.026 * h * sin(scramble + 1.5) * speed,
            wag2: 0.058 * h * sin(scramble + 2.0) * speed,
            mirror: m, alpha: 1)
        pen.fillEllipse(at: body, rx: 0.165, ry: 0.120, rotation: lean, alpha: 1)
        leg(scramble, 1)

        let arm0 = off(0.098, 0.014)
        rexArm(
            pen, shoulder: arm0,
            elbow: CGPoint(x: arm0.x + m * 0.034 * h, y: arm0.y + 0.026 * h),
            hand: CGPoint(
                x: arm0.x + m * 0.062 * h,
                y: arm0.y - 0.010 * h + 0.026 * h * sin(scramble + 1.2)),
            alpha: 1)

        // The head bobs a beat behind the body's scramble.
        let head = off(0.118, -0.185 + 0.022 * abs(sin(scramble - 0.7)) * speed)
        pen.fill([
            off(0.050, -0.060), off(0.135, -0.125),
            spun(-0.020 * m, 0.060, by: lean, around: head, unit: h),
            spun(-0.085 * m, 0.025, by: lean, around: head, unit: h),
        ], alpha: 1)
        let pant = clamp01((energy - 0.60) * 3) * speed
        rexHead(
            pen, at: head, rotation: lean + m * 0.08, mirror: m,
            blink: blinkFactor(time: time, speed: 0.19), mouth: pant, grin: 0.6)
    }
}

// MARK: - Stomp

private extension Visualizer {
    /// Kaiju mode: a high-knee march where every footfall is an event. The
    /// knee comes up a fifth of the box, the foot drives down fast, and the
    /// impact is shared out to everything it should touch — the body drops
    /// onto the planted leg, a shockwave ring rolls out along the floor, dust
    /// jumps, and the ground line itself jolts, because nothing drawn on a
    /// body sells weight like the floor giving way under it. One cycle is a
    /// stride pair. Past two-thirds load the head goes back and the mouth
    /// opens: a roar, with the lines to prove it.
    func drawStomp(time: Double, energy: Double, pen: Pen) {
        // Flipped y-down like the other characters; see drawRex.
        pen.context.translateBy(x: 0, y: pen.rect.height)
        pen.context.scaleBy(x: 1, y: -1)

        let w = Double(pen.rect.width), h = Double(pen.rect.height)
        let gy = 0.87 * h
        let P = 2 * .pi * time                     // one cycle = one stride pair

        // Each foot lands once per cycle, half a cycle apart, and its thud is
        // the shared clock for everything the impact touches. A narrow spike:
        // the attack is the wrap of `fract`, the decay is fast enough that
        // the impact reads as an instant rather than a state.
        let sNear = fract(time)
        let sFar = fract(time + 0.5)
        func thud(_ s: Double) -> Double { pow(max(0, 1 - s / 0.30), 2.2) }
        let quake = thud(sNear) + 0.75 * thud(sFar)

        rexGround(
            pen, time: time, gy: gy + 0.02 * h + 0.015 * h * quake, speed: 0.4)
        rexZoom(pen, aboutX: 0.46 * w, groundY: gy, factor: 1.28)

        // Rings and dust live at the landing spots, which are constants of
        // the cycle: the sway, evaluated at an impact instant, always comes
        // out at the same two phases, and the far leg plants a staggered
        // half-step behind the near one.
        for (s, ringX) in [
            (sNear, 0.46 * w + 0.064 * h), (sFar, 0.46 * w - 0.055 * h),
        ] where s < 0.30 {
            let grow = s / 0.30
            let radius = (0.055 + 0.185 * grow) * (1 + 0.35 * energy)
            pen.strokeEllipse(
                at: CGPoint(x: ringX, y: gy), rx: radius, ry: radius * 0.30,
                width: 0.020, alpha: 0.50 * (1 - grow) * (0.55 + 0.45 * energy))
            for side in [-1.0, 1.0] {
                pen.dot(
                    at: CGPoint(
                        x: ringX + side * (0.05 + 0.10 * grow) * h,
                        y: gy - 0.02 * h - 0.04 * h * grow),
                    radius: 0.015, alpha: (1 - grow) * 0.40)
            }
        }

        // The body vaults between impacts and drops onto them, swaying over
        // whichever leg is carrying it. The roar builds past two-thirds load:
        // head thrown back, arms up, everything trembling with it.
        // A kaiju leans into its rampage. The forward pitch is constant; the
        // rocking, the vault between impacts and the drop onto them all ride
        // on top of it.
        let roar = clamp01((energy - 0.62) / 0.22)
        let bounce = 0.5 - 0.5 * cos(2 * P)
        let body = CGPoint(
            x: 0.46 * w + 0.040 * h * cos(P + 0.4),
            y: 0.600 * h - (0.038 + 0.026 * energy) * h * bounce + 0.022 * h * quake)
        let rot = 0.11 + 0.07 * sin(P + 0.8) - 0.06 * roar
        func off(_ dx: Double, _ dy: Double) -> CGPoint {
            spun(dx, dy, by: rot, around: body, unit: h)
        }

        rexShadow(
            pen, cx: body.x, gy: gy,
            width: 0.175 + 0.030 * quake, alpha: 0.16 + 0.05 * quake)

        // The march itself: a slow, showy rise and a fast slam. The lift
        // curve peaks late — pow inside the sine — so most of the swing is
        // spent up in the air and the drop happens in a tenth of the cycle,
        // and the toe points down through the lift, telegraphing it.
        let hip = off(-0.048, 0.078)
        func leg(_ s: Double, _ stance: Double, _ alpha: Double) {
            let fx: Double, fy: Double, kneeUp: Double
            if s < 0.5 {                            // planted, body passing over
                fx = hip.x + (lerp(0.075, -0.060, s / 0.5) + stance) * h
                fy = gy
                kneeUp = 0
            } else {                                // leg cocked forward, then the slam
                // The cock has to punch *forward*, not just up: a foot lifted
                // straight under the hip disappears inside the belly, which
                // at this size is a third of the box wide. Ahead of and below
                // the belly's front edge is the only open sky it can read in.
                let u = (s - 0.5) / 0.5
                let liftCurve = sin(.pi * pow(u, 1.6))
                fx = hip.x + (lerp(-0.060, 0.075, smoothstep(u)) + stance
                    + 0.165 * liftCurve) * h
                fy = gy - liftCurve * (0.13 + 0.04 * energy) * h
                kneeUp = liftCurve
            }
            let knee = CGPoint(
                x: (hip.x + fx) / 2 + (0.055 + 0.050 * kneeUp) * h,
                y: (hip.y + fy) / 2 - kneeUp * 0.045 * h)
            pen.stroke([hip, knee, CGPoint(x: fx, y: fy)], width: 0.062, alpha: alpha)
            pen.stroke(
                [CGPoint(x: fx, y: fy),
                 CGPoint(
                    x: fx + lerp(0.046, 0.028, kneeUp) * h,
                    y: fy + lerp(-0.005, 0.034, kneeUp) * h)],
                width: 0.050, alpha: alpha)
        }
        leg(sFar, -0.045, 0.85)

        // The tail wags small and low. At a march's tempo the gallop's big
        // slow sweep stops reading as a tail at all and starts reading as a
        // wing being waved.
        rexTail(
            pen, base: off(-0.140, -0.005),
            wag1: 0.018 * h * sin(P + 1.4) + 0.012 * h * (quake + 1),
            wag2: 0.042 * h * sin(P + 1.9) + 0.018 * h,
            mirror: 1, alpha: 1)

        pen.fillEllipse(at: body, rx: 0.165, ry: 0.120, rotation: rot, alpha: 1)
        leg(sNear, 0, 1)

        // Arms: pumping with the march, punched up ahead of the roar — well
        // forward of it, because the thrown-back head arrives where a
        // straight-up fist would be.
        let sh = off(0.096, -0.020)
        let pump = 0.020 * h * sin(P + 0.6) * (1 - roar)
        let tremble = 0.010 * h * sin(6 * P) * roar
        rexArm(
            pen, shoulder: sh,
            elbow: CGPoint(
                x: sh.x + lerp(0.034, 0.080, roar) * h,
                y: sh.y + lerp(0.028, -0.042, roar) * h + pump + tremble),
            hand: CGPoint(
                x: sh.x + lerp(0.062, 0.128, roar) * h,
                y: sh.y + lerp(0.004, -0.098, roar) * h + pump * 1.4 + tremble),
            alpha: 1)

        // The head rides the quake a beat late — follow-through — and the
        // roar throws it up and back, not just its rotation: a head that only
        // rotates while staying put reads as sinking into the shoulders.
        var head = off(0.118 - 0.055 * roar, -0.185 - 0.042 * roar)
        head.y += 0.026 * h * thud(fract(time - 0.06))
        pen.fill([
            off(0.050, -0.060), off(0.135, -0.125),
            CGPoint(x: head.x - 0.02 * h, y: head.y + 0.06 * h),
            CGPoint(x: head.x - 0.085 * h, y: head.y + 0.025 * h),
        ], alpha: 1)
        let bellow = roar * (0.62 + 0.38 * sin(2 * P))
        // Eyes squeeze with each thud, a beat after it lands.
        let wince = 0.45 * thud(fract(time - 0.04)) * (1 - roar)
        rexHead(
            pen, at: head, rotation: rot + 0.06 - roar * (0.34 + 0.05 * sin(3 * P)),
            blink: blinkFactor(time: time, speed: 0.16) * (1 - wince), mouth: bellow,
            grin: 1 - bellow)

        // Roar lines fanning from the mouth, flickering on their own clock.
        if bellow > 0.25 {
            for k in 0..<3 {
                let ang = -0.55 - 0.38 * Double(k) + roar * 0.30
                let from = CGPoint(
                    x: head.x + 0.13 * h * cos(ang), y: head.y + 0.13 * h * sin(ang))
                let to = CGPoint(
                    x: head.x + 0.20 * h * cos(ang), y: head.y + 0.20 * h * sin(ang))
                pen.stroke(
                    [from, to], width: 0.018,
                    alpha: bellow * (0.35 + 0.30 * sin(5 * P + Double(k) * 2.1)))
            }
        }
    }
}

// MARK: - Chomp

private extension Visualizer {
    /// A chase. The fly loops the top of the box on its own pair of
    /// incommensurate sines, so it roams everywhere without a visible
    /// pattern; the rex runs the fly's position from a moment ago, so it is
    /// always cornering hard and always late. Once a cycle it leaps and
    /// snaps — jaws open on the way up, clack shut at the top — and the fly,
    /// keyed to the same phase, darts clear the beat before. Every time.
    func drawChomp(time: Double, energy: Double, pen: Pen) {
        // Flipped y-down like the other characters; see drawRex.
        pen.context.translateBy(x: 0, y: pen.rect.height)
        pen.context.scaleBy(x: 1, y: -1)

        let w = Double(pen.rect.width), h = Double(pen.rect.height)
        let gy = 0.87 * h
        rexGround(pen, time: time, gy: gy + 0.02 * h, speed: 0)

        // The dart is written into the fly's own path, keyed to the pounce
        // phase, so evaluating the path in the past — the trail, the rex's
        // stale target — replays past escapes correctly too.
        func flyAt(_ t: Double) -> CGPoint {
            let dart = pow(max(0, sin(.pi * clamp01((fract(t) - 0.64) / 0.18))), 2)
            let range = 0.29 + 0.05 * energy
            return CGPoint(
                x: w * 0.50 + w * range * sin(2 * .pi * 0.37 * t)
                    + 0.075 * w * sin(2 * .pi * 1.73 * t + 1.1),
                y: h * (0.30 + 0.085 * sin(2 * .pi * 1.19 * t + 0.7)
                    + 0.050 * sin(2 * .pi * 2.9 * t))
                    - dart * (0.11 + 0.05 * energy) * h)
        }

        // The rex chases the fly's past. The lag shortens with load — a
        // busier machine is a keener hunter — which the eye reads as the
        // whole chase tightening up.
        let lag = 0.30 - 0.13 * energy
        let target = flyAt(time)
        func chaseX(_ t: Double) -> Double {
            min(0.83 * w, max(0.17 * w, Double(flyAt(t - lag).x)))
        }
        let x = chaseX(time)

        let phi = fract(time)                      // one cycle = one pounce
        let leapStart = 0.52, leapEnd = 0.86
        var air = 0.0, tau = 0.0
        if phi > leapStart && phi < leapEnd {
            tau = (phi - leapStart) / (leapEnd - leapStart)
            air = sin(.pi * tau)
        }

        // Which way to face is a continuous quantity, not a sign: as the
        // fly passes overhead the rex turns through end-on rather than
        // flipping between frames. Two terms, because the leap is aimed
        // at a fly nearly overhead and position alone would turn the rex
        // end-on for the snap: where the fly is, and which way the chase
        // is running. And a leap commits — the facing is frozen at
        // take-off and eased back to live through the landing.
        let freeze = phi <= leapStart ? 0
            : (phi < leapEnd ? 1 : 1 - smoothstep(clamp01((phi - leapEnd) / (0.96 - leapEnd))))
        let faceTime = time - (phi - leapStart) * freeze
        let faceX = chaseX(faceTime)
        let run = (chaseX(faceTime + 0.02) - chaseX(faceTime - 0.02)) / 0.04
        let face = tanh((Double(flyAt(faceTime).x) - faceX) / (0.10 * h) + run / (0.6 * w))
        let m: Double = face >= 0 ? 1 : -1
        // A crouch to anticipate the leap and a squash to land it — the
        // pounce used to start from a run and end in one, and read as a
        // rex being lifted and set down.
        let crouch = (phi > 0.42 && phi <= leapStart)
            ? sin(.pi * (phi - 0.42) / (leapStart - 0.42)) : 0
        let land = (phi >= leapEnd && phi < 0.96)
            ? sin(.pi * (phi - leapEnd) / (0.96 - leapEnd)) : 0
        let squash = max(crouch, land)

        let scramble = 2 * .pi * time * 3.0
        let bob = 0.028 * h * abs(sin(scramble)) * (1 - air) * (1 - squash)
        let body = CGPoint(
            x: x, y: 0.605 * h - bob - air * (0.10 + 0.09 * energy) * h
                + 0.040 * h * squash)
        let lean = m * (0.14 + 0.24 * air)
        func off(_ dx: Double, _ dy: Double) -> CGPoint {
            spun(dx * m, dy, by: lean, around: body, unit: h)
        }

        rexZoom(pen, aboutX: x, groundY: gy, factor: 1.24)
        rexShadow(
            pen, cx: x, gy: gy,
            width: 0.165 - 0.070 * air + 0.030 * squash, alpha: 0.16 * (1 - 0.55 * air))
        rexTurn(pen, aboutX: x, width: abs(face))

        // Landing dust, kicked out to both sides.
        if land > 0.02 {
            let dp = (phi - leapEnd) / (0.96 - leapEnd)
            for side in [-1.0, 1.0] {
                pen.dot(
                    at: CGPoint(
                        x: x + side * (0.09 + 0.12 * dp) * h,
                        y: gy - 0.02 * h - 0.03 * h * dp),
                    radius: 0.018 * (1 - 0.4 * dp), alpha: (1 - dp) * 0.40)
            }
        }

        // Legs scramble on the ground; knees up and feet forward in the air.
        let hip = off(-0.048, 0.078)
        if air > 0.02 {
            let footFar = off(0.045, 0.165), footNear = off(0.110, 0.150)
            rexPlantLeg(
                pen, hip: hip, footX: footFar.x, footY: footFar.y,
                kneeOut: 0.070, mirror: m, alpha: 0.85)
            rexPlantLeg(
                pen, hip: off(0.042, 0.075), footX: footNear.x, footY: footNear.y,
                kneeOut: 0.072, mirror: m, alpha: 1)
        } else if squash > 0.02 {
            let bend = 0.040 + 0.035 * squash
            rexPlantLeg(
                pen, hip: hip, footX: x - m * 0.085 * h, footY: gy,
                kneeOut: bend, mirror: m, alpha: 0.85)
            rexPlantLeg(
                pen, hip: off(0.042, 0.075), footX: x + m * 0.085 * h, footY: gy,
                kneeOut: bend + 0.008, mirror: m, alpha: 1)
        } else {
            func leg(_ phase: Double, _ alpha: Double) {
                let lift = max(0, sin(phase))
                let fx = hip.x - m * 0.115 * h * cos(phase)
                let fy = gy - lift * 0.110 * h
                let knee = CGPoint(
                    x: (hip.x + fx) / 2 + m * 0.048 * h, y: (hip.y + fy) / 2)
                pen.stroke([hip, knee, CGPoint(x: fx, y: fy)], width: 0.062, alpha: alpha)
                pen.stroke(
                    [CGPoint(x: fx, y: fy),
                     CGPoint(x: fx + m * 0.042 * h, y: fy - 0.005 * h)],
                    width: 0.050, alpha: alpha)
            }
            leg(scramble + .pi, 0.85)
            leg(scramble, 1)
        }

        rexTail(
            pen, base: off(-0.140, -0.005),
            wag1: 0.022 * h * sin(scramble + 1.5),
            wag2: 0.050 * h * sin(scramble + 2.0),
            mirror: m, alpha: 1)

        pen.fillEllipse(
            at: body, rx: 0.165 * (1 + 0.22 * squash), ry: 0.120 * (1 - 0.24 * squash),
            rotation: lean, alpha: 1)

        // Arms: pumping on the ground, both reaching up in the leap.
        if air > 0.02 {
            rexArm(
                pen, shoulder: off(0.095, -0.030), elbow: off(0.118, -0.078),
                hand: off(0.132, -0.130), alpha: 1)
        } else {
            let arm0 = off(0.098, 0.014)
            rexArm(
                pen, shoulder: arm0,
                elbow: CGPoint(x: arm0.x + m * 0.034 * h, y: arm0.y + 0.026 * h),
                hand: CGPoint(
                    x: arm0.x + m * 0.062 * h,
                    y: arm0.y - 0.010 * h + 0.026 * h * sin(scramble + 1.2)),
                alpha: 1)
        }

        // The snap: jaws open through the rise, clack shut just before the
        // apex — timed to land exactly where the fly was a dart ago.
        let jaw = smoothstep(clamp01(tau / 0.50))
            * (1 - smoothstep(clamp01((tau - 0.50) / 0.14)))
        let lagPhi = fract(phi - 0.04)
        let lagSquash = (lagPhi >= leapEnd && lagPhi < 0.96)
            ? sin(.pi * (lagPhi - leapEnd) / (0.96 - leapEnd)) : 0
        let head = off(0.118, -0.185 + 0.030 * lagSquash)
        pen.fill([
            off(0.050, -0.060), off(0.135, -0.125),
            spun(-0.020 * m, 0.060, by: lean, around: head, unit: h),
            spun(-0.085 * m, 0.025, by: lean, around: head, unit: h),
        ], alpha: 1)
        rexHead(
            pen, at: head, rotation: lean - m * (0.10 + 0.26 * air) + m * 0.10 * lagSquash,
            mirror: m,
            blink: blinkFactor(time: time, speed: 0.21) * (1 - 0.5 * land), mouth: jaw,
            grin: air > 0.02 ? 0 : 0.8)

        // The clack, made visible: a little star at the snout as the jaws
        // meet on nothing.
        if tau > 0.58 && tau < 0.74 {
            let flash = sin(.pi * (tau - 0.58) / 0.16)
            let tip = spun(
                0.150 * m, 0.046, by: lean - m * (0.10 + 0.26 * air),
                around: head, unit: h)
            for (dx, dy) in [(0.028, 0.0), (0.0, 0.028)] {
                pen.stroke(
                    [CGPoint(x: tip.x - dx * h * flash, y: tip.y - dy * h * flash),
                     CGPoint(x: tip.x + dx * h * flash, y: tip.y + dy * h * flash)],
                    width: 0.016, alpha: 0.75 * flash)
            }
        }

        // The fly itself, drawn over everything: a dot, two blurred wings,
        // and a short fading trail so the darts leave a streak.
        for k in 1...3 {
            let past = flyAt(time - Double(k) * 0.035)
            pen.dot(
                at: past, radius: 0.011 - 0.002 * Double(k),
                alpha: 0.28 * (1 - Double(k) / 4) * (0.4 + 0.6 * energy))
        }
        let flap = sin(2 * .pi * time * 9)
        for side in [-1.0, 1.0] {
            pen.stroke(
                [target,
                 CGPoint(
                    x: target.x + CGFloat(side * 0.030 * h),
                    y: target.y - CGFloat((0.026 + side * 0.010 * flap) * h))],
                width: 0.014, alpha: 0.55)
        }
        pen.dot(at: target, radius: 0.021, alpha: 0.95)
    }
}

// MARK: - Roll

private extension Visualizer {
    /// A spin-dash. A third of the cycle goes on the wind-up — crouched,
    /// vibrating, dust flying off the scrabbling feet — because the
    /// anticipation is the joke: all that rev buys a launch that crosses the
    /// bar in half the time it took to charge. Mid-flight the rex is a ball,
    /// over-spinning like a slipping wheel, and at the far side it pops back
    /// out and skids into the wall of its own momentum. Past a bit over half
    /// load the ball stops bothering to touch the ground on the way.
    func drawRoll(time: Double, energy: Double, pen: Pen) {
        // Flipped y-down like the other characters; see drawRex.
        pen.context.translateBy(x: 0, y: pen.rect.height)
        pen.context.scaleBy(x: 1, y: -1)

        let w = Double(pen.rect.width), h = Double(pen.rect.height)
        let gy = 0.87 * h
        rexGround(pen, time: time, gy: gy + 0.02 * h, speed: 0)

        // The endpoints leave a whole tail's reach clear of the frame: the
        // rev and the skid both happen at the ends, tail out behind, and a
        // sliced-off tail reads as damage rather than speed.
        let crossing = time.rounded(.down)
        let f = time - crossing                   // one cycle = one crossing
        let m: Double = Int(crossing) % 2 == 0 ? 1 : -1
        let xFrom = 0.5 * w - m * 0.255 * w
        let xTo = 0.5 * w + m * 0.255 * w
        let revEnd = 0.34, rollEnd = 0.82

        // The anchor rides the body's own x through all three phases — the
        // rule `rexZoom` documents, and the one every other traveller obeys.
        // Anchoring the roll at the box's left edge drew the ball at 1.14×
        // its scene position: a ~1pt lurch at launch and a ~3pt backwards
        // teleport into the skid, landing exactly as the ball slows enough
        // for the jump to read. The formulas mirror the phase branches below.
        let anchorX: Double
        if f < revEnd {
            anchorX = xFrom
        } else if f < rollEnd {
            let t = (f - revEnd) / (rollEnd - revEnd)
            anchorX = lerp(xFrom, xTo - m * 0.05 * w, 1 - pow(1 - t, 1.75))
        } else {
            anchorX = lerp(
                xTo - m * 0.05 * w, xTo, smoothstep((f - rollEnd) / (1 - rollEnd)))
        }
        rexZoom(pen, aboutX: anchorX, groundY: gy, factor: 1.14)
        // The skid ends facing the way it came and the next rev starts
        // facing the other way; the turn between them is drawn end-on.
        rexTurn(pen, aboutX: anchorX, width: 1 - 0.88 * turnWindow(f, span: 0.06))

        if f < revEnd {
            // Wind-up: crouch low, lean back, vibrate. The shake frequency is
            // fixed per cycle, so at idle it is a visible shudder and under
            // load it blurs — which is exactly what a rev should do.
            let u = f / revEnd
            let crouch = smoothstep(min(1, u * 1.6))
            let rev = u * u
            let shake = 0.008 * h * sin(2 * .pi * f * 15) * rev
            let body = CGPoint(
                x: xFrom + shake, y: 0.615 * h + 0.055 * h * crouch)
            let rot = -m * 0.22 * crouch
            func off(_ dx: Double, _ dy: Double) -> CGPoint {
                spun(dx * m, dy, by: rot, around: body, unit: h)
            }

            rexShadow(pen, cx: body.x, gy: gy, width: 0.175, alpha: 0.16)

            // Dust scrabbling out behind the launch line.
            for k in 0..<3 {
                let d = fract(f * 9 + Double(k) * 0.33)
                pen.dot(
                    at: CGPoint(
                        x: body.x - m * (0.10 + 0.17 * d) * h,
                        y: gy - 0.012 * h - 0.030 * h * d),
                    radius: 0.017 * (1 - 0.3 * d), alpha: (1 - d) * 0.50 * rev)
            }

            rexPlantLeg(
                pen, hip: off(-0.050, 0.075), footX: body.x - m * 0.105 * h,
                footY: gy, kneeOut: 0.058, mirror: m, alpha: 0.85)
            rexTail(
                pen, base: off(-0.138, -0.005),
                wag1: 0.030 * h * sin(2 * .pi * f * 8) * rev + 0.012 * h * crouch,
                wag2: 0.055 * h * sin(2 * .pi * f * 8 - 0.7) * rev + 0.020 * h * crouch,
                mirror: m, alpha: 1)
            pen.fillEllipse(
                at: body, rx: 0.165 * (1 + 0.20 * crouch),
                ry: 0.120 * (1 - 0.22 * crouch), rotation: rot, alpha: 1)
            rexPlantLeg(
                pen, hip: off(0.045, 0.075), footX: body.x + m * 0.090 * h,
                footY: gy, kneeOut: 0.062, mirror: m, alpha: 1)
            let arm0 = off(0.098, 0.018)
            rexArm(
                pen, shoulder: arm0,
                elbow: CGPoint(x: arm0.x + m * 0.030 * h, y: arm0.y + 0.024 * h),
                hand: CGPoint(x: arm0.x + m * 0.056 * h, y: arm0.y + 0.006 * h),
                alpha: 1)

            let head = off(0.115, -0.175)
            pen.fill([
                off(0.048, -0.055), off(0.130, -0.118),
                spun(-0.020 * m, 0.060, by: rot, around: head, unit: h),
                spun(-0.085 * m, 0.025, by: rot, around: head, unit: h),
            ], alpha: 1)
            // Squinting down the runway, grinning.
            rexHead(
                pen, at: head, rotation: rot + m * 0.10, mirror: m,
                blink: blinkFactor(time: time, speed: 0.20) * (1 - 0.45 * crouch),
                grin: 1)
        } else if f < rollEnd {
            // The launch eases out, not in: all the acceleration happened in
            // the rev, so the ball leaves at full speed and bleeds it off
            // across the bar. The spin over-runs the travel — a slipping
            // wheel — because a correctly rolling ball, at this size, looks
            // stately.
            let t = (f - revEnd) / (rollEnd - revEnd)
            let xe = 1 - pow(1 - t, 1.75)
            let x = lerp(xFrom, xTo - m * 0.05 * w, xe)
            let radius = 0.135 + 0.008 * energy
            let hop = clamp01((energy - 0.55) / 0.25)
            let cy = gy - (radius + 0.012) * h
                - hop * 0.105 * h * sin(.pi * t)
                - (1 - hop) * 0.015 * h * abs(sin(2 * .pi * t * 2.5))
            let ball = CGPoint(x: x, y: cy)
            let spin = m * 2 * .pi * 3.2 * xe
            let vel = pow(1 - t, 0.75)

            rexShadow(
                pen, cx: x, gy: gy, width: 0.150 - 0.045 * hop * sin(.pi * t),
                alpha: 0.16 * (1 - 0.4 * hop * sin(.pi * t)))

            // Speed lines and a dust trail, both dying off with the speed.
            for k in 0..<2 {
                let y = cy + (Double(k) - 0.5) * 0.11 * h
                pen.stroke(
                    [CGPoint(x: x - m * 0.20 * h, y: y),
                     CGPoint(x: x - m * (0.38 + 0.04 * Double(k)) * h, y: y)],
                    width: 0.020, alpha: 0.45 * vel * (0.4 + 0.6 * energy))
            }
            for k in 0..<3 {
                let d = Double(k + 1) / 3
                pen.dot(
                    at: CGPoint(x: x - m * (0.16 + 0.14 * d) * h, y: gy - 0.02 * h),
                    radius: 0.015, alpha: 0.40 * vel * (1 - d) * (0.3 + 0.7 * energy))
            }

            // The ball: body circle, snout bump leading the spin, feet lumps,
            // the tail wrapped round the rim and trailing, and the eye —
            // squeezed shut — going round and round with the rest.
            func rim(_ angle: Double, _ r: Double) -> CGPoint {
                CGPoint(x: ball.x + r * h * cos(angle), y: ball.y + r * h * sin(angle))
            }
            let nose = spin - m * 0.4
            var tailPts = [CGPoint](repeating: .zero, count: 5)
            for i in 0..<5 {
                let a = nose + m * (2.3 + 0.45 * Double(i))
                tailPts[i] = rim(a, radius * (1.02 + 0.06 * Double(i)))
            }
            pen.stroke(Array(tailPts[0...2]), width: 0.052, alpha: 1)
            pen.stroke(Array(tailPts[2...4]), width: 0.030, alpha: 1)
            pen.fillEllipse(at: ball, rx: radius, ry: radius, rotation: 0, alpha: 1)
            pen.fillEllipse(
                at: rim(nose, radius * 0.94), rx: 0.052, ry: 0.040,
                rotation: nose, alpha: 1)
            pen.dot(at: rim(nose + m * 1.7, radius * 0.98), radius: 0.032, alpha: 1)
            pen.dot(at: rim(nose + m * 2.5, radius * 0.98), radius: 0.030, alpha: 1)
            pen.punch(
                at: rim(nose - m * 0.55, radius * 0.55), rx: 0.020, ry: 0.006,
                rotation: nose)
        } else {
            // Pop out and skid: lean way back, wobble upright, dust pushed
            // out in front. The rex faces the way it was going; the next
            // cycle turns it round.
            let u = (f - rollEnd) / (1 - rollEnd)
            let x = lerp(xTo - m * 0.05 * w, xTo, smoothstep(u))
            let settle = 1 - u
            let rot = -m * 0.30 * settle + m * 0.10 * sin(3 * .pi * u) * settle
            let squash = sin(.pi * min(1, u * 1.4))
            let body = CGPoint(x: x, y: 0.600 * h + 0.030 * h * squash)
            func off(_ dx: Double, _ dy: Double) -> CGPoint {
                spun(dx * m, dy, by: rot, around: body, unit: h)
            }

            rexShadow(pen, cx: x, gy: gy, width: 0.170, alpha: 0.16)

            // Skid streaks under the braced feet, dust thrown ahead.
            for k in 0..<2 {
                pen.stroke(
                    [CGPoint(x: x - m * (0.06 + 0.05 * Double(k)) * h, y: gy),
                     CGPoint(x: x - m * (0.16 + 0.07 * Double(k)) * h, y: gy)],
                    width: 0.020, alpha: 0.45 * settle)
                pen.dot(
                    at: CGPoint(
                        x: x + m * (0.10 + 0.08 * Double(k)) * h,
                        y: gy - 0.03 * h - 0.02 * h * Double(k)),
                    radius: 0.016, alpha: 0.40 * settle)
            }

            rexPlantLeg(
                pen, hip: off(-0.050, 0.075), footX: x - m * 0.075 * h, footY: gy,
                kneeOut: 0.050 + 0.020 * settle, mirror: m, alpha: 0.85)
            rexTail(
                pen, base: off(-0.138, -0.005),
                wag1: -0.030 * h * settle * sin(4 * .pi * u),
                wag2: -0.070 * h * settle * sin(4 * .pi * u + 0.8),
                mirror: m, alpha: 1)
            pen.fillEllipse(
                at: body, rx: 0.165 * (1 + 0.14 * squash),
                ry: 0.120 * (1 - 0.16 * squash), rotation: rot, alpha: 1)
            rexPlantLeg(
                pen, hip: off(0.045, 0.075), footX: x + m * 0.100 * h, footY: gy,
                kneeOut: 0.055 + 0.025 * settle, mirror: m, alpha: 1)
            // Arms out for balance, windmilling down as it settles.
            let sh = off(0.095, -0.025)
            rexArm(
                pen, shoulder: sh,
                elbow: CGPoint(
                    x: sh.x + m * 0.045 * h,
                    y: sh.y - (0.030 + 0.030 * settle) * h),
                hand: CGPoint(
                    x: sh.x + m * (0.075 + 0.030 * settle) * h,
                    y: sh.y - (0.010 + 0.075 * settle) * h),
                alpha: 1)

            let head = off(0.115, -0.180)
            pen.fill([
                off(0.048, -0.058), off(0.130, -0.120),
                spun(-0.020 * m, 0.060, by: rot, around: head, unit: h),
                spun(-0.085 * m, 0.025, by: rot, around: head, unit: h),
            ], alpha: 1)
            // Eyes wide after all that spinning; the grin never left.
            rexHead(
                pen, at: head, rotation: rot - m * 0.08, mirror: m,
                blink: 1, grin: 1)
        }
    }
}

// MARK: - Rocket

private extension Visualizer {
    /// A jetpack the rex should not have. It reclines on the thrust —
    /// nose-up, hero arm out, legs streaming behind — and swoops the bar,
    /// pitching flatter as it picks up speed through the middle and rearing
    /// up to shed it at the ends. The flame flickers on its own fast clock,
    /// the exhaust puffs ride the actual flown path — turns included — and
    /// past two-thirds load the middle of every swoop picks up a full
    /// mid-air loop, eyes shut, arm still out.
    func drawRocket(time: Double, energy: Double, pen: Pen) {
        // Flipped y-down like the other characters; see drawRex.
        pen.context.translateBy(x: 0, y: pen.rect.height)
        pen.context.scaleBy(x: 1, y: -1)

        let w = Double(pen.rect.width), h = Double(pen.rect.height)
        let gy = 0.87 * h
        rexGround(pen, time: time, gy: gy + 0.02 * h, speed: 0)

        // The path is a function of absolute time, so the exhaust puffs can
        // be placed by evaluating it in the recent past — and a puff dropped
        // just before a turn correctly hangs on the far side of it.
        func flightAt(_ t: Double) -> (pos: CGPoint, m: Double, f: Double) {
            let c = t.rounded(.down)
            let f = t - c
            let m: Double = Int(c) % 2 == 0 ? 1 : -1
            let xe = smoothstep(f)
            let wobble = 0.016 * sin(2 * .pi * t * 2.6) + 0.009 * sin(2 * .pi * t * 5.3)
            return (
                CGPoint(
                    x: lerp(0.19 * w, 0.81 * w, m > 0 ? xe : 1 - xe),
                    y: (0.46 - 0.09 * sin(.pi * f) + wobble) * h),
                m, f)
        }

        let flight = flightAt(time)
        let body = flight.pos
        let m = flight.m
        let speed = sin(.pi * flight.f)

        // Exhaust puffs, oldest largest and faintest — drawn first, under
        // everything, in scene space so the zoom does not fling them around.
        for k in 1...4 {
            let past = flightAt(time - Double(k) * 0.055)
            pen.dot(
                at: past.pos, radius: 0.014 + 0.007 * Double(k),
                alpha: (1 - Double(k) / 5) * 0.32 * (0.45 + 0.55 * energy))
        }

        rexZoom(pen, aboutX: body.x, groundY: gy, factor: 1.18)
        // Reared up at the end of a swoop, the rex turns end-on and comes
        // round facing the way back rather than flipping in place.
        rexTurn(pen, aboutX: body.x, width: 1 - 0.88 * turnWindow(flight.f))

        let altitude = (gy - body.y) / gy
        rexShadow(
            pen, cx: body.x, gy: gy, width: 0.130 * (1 - 0.3 * altitude),
            alpha: 0.12 * (1 - 0.8 * altitude))

        // Level on the thrust through the middle, rearing nose-up to shed
        // speed at the ends. The loop is one extra full turn spliced into the
        // middle of the swoop — always a *whole* turn: a load parked in the
        // gate's band would otherwise hold a partial loop and fly the back
        // half of every swoop inverted, unwinding with a snap at the turn.
        let loop = clamp01((energy - 0.62) / 0.18).rounded()
        let spin = loop * 2 * .pi * smoothstep(clamp01((flight.f - 0.32) / 0.34))
        let rot = -m * 0.30 * pow(1 - speed, 1.2) + m * spin
        func off(_ dx: Double, _ dy: Double) -> CGPoint {
            spun(dx * m, dy, by: rot, around: body, unit: h)
        }

        // Flame first: it lives behind the pack, and the pack behind the
        // body. It points back and down along the thrust — rotated with the
        // loop, so mid-somersault it flails around the turn — and bursts at
        // each end of the bar where the thrust has a corner to argue with.
        let burst = pow(1 - speed, 2)
        let nozzle = off(-0.118, -0.108)
        let flameLen = (0.13 + 0.15 * energy + 0.035 * sin(2 * .pi * time * 10.7)
            + 0.08 * burst) * h
        let flick = 0.014 * sin(2 * .pi * time * 13.3)
        let ca = cos(m * spin), sa = sin(m * spin)
        func spunDir(_ dx: Double, _ dy: Double) -> (x: Double, y: Double) {
            (dx * ca - dy * sa, dx * sa + dy * ca)
        }
        let axis = spunDir(-m * 0.87, 0.49 + flick)
        let side = spunDir(-0.49, -0.87 * m)
        let baseA = CGPoint(
            x: nozzle.x + side.x * 0.036 * h, y: nozzle.y + side.y * 0.036 * h)
        let baseB = CGPoint(
            x: nozzle.x - side.x * 0.036 * h, y: nozzle.y - side.y * 0.036 * h)
        pen.fill([
            baseA, baseB,
            CGPoint(x: nozzle.x + axis.x * flameLen, y: nozzle.y + axis.y * flameLen),
        ], alpha: 0.75)
        pen.fill([
            baseA, baseB,
            CGPoint(
                x: nozzle.x + axis.x * flameLen * 0.55,
                y: nozzle.y + axis.y * flameLen * 0.55),
        ], alpha: 0.50)
        pen.fillEllipse(at: off(-0.080, -0.118), rx: 0.056, ry: 0.070, rotation: rot, alpha: 1)

        // Legs streaming straight back, fluttering out of phase in the
        // slipstream, toes pointed like they matter.
        let flutter = 0.013 * sin(2 * .pi * time * 5.9)
        let footFar = off(-0.196, 0.058 + flutter * 1.3)
        pen.stroke(
            [off(-0.038, 0.062), off(-0.120, 0.078), footFar],
            width: 0.062, alpha: 0.85)
        pen.stroke(
            [footFar, off(-0.240, 0.052 + flutter * 1.3)], width: 0.050, alpha: 0.85)
        let footNear = off(-0.204, 0.090 - flutter)
        pen.stroke(
            [off(-0.052, 0.078), off(-0.128, 0.100), footNear],
            width: 0.062, alpha: 1)
        pen.stroke(
            [footNear, off(-0.248, 0.086 - flutter)], width: 0.050, alpha: 1)

        rexTail(
            pen, base: off(-0.145, -0.018),
            wag1: 0.022 * h * sin(2 * .pi * time * 4.3),
            wag2: 0.048 * h * sin(2 * .pi * time * 4.3 - 0.8),
            mirror: m, alpha: 1)

        pen.fillEllipse(at: body, rx: 0.165, ry: 0.120, rotation: rot, alpha: 1)

        // Arms: the far one tucked, the hero one straight out ahead.
        rexArm(
            pen, shoulder: off(0.072, -0.005), elbow: off(0.105, 0.024),
            hand: off(0.132, 0.040), alpha: 0.5)
        rexArm(
            pen, shoulder: off(0.090, -0.045), elbow: off(0.160, -0.056),
            hand: off(0.228, -0.064), alpha: 1)

        let head = off(0.118, -0.170)
        pen.fill([
            off(0.050, -0.055), off(0.135, -0.115),
            spun(-0.020 * m, 0.060, by: rot, around: head, unit: h),
            spun(-0.085 * m, 0.025, by: rot, around: head, unit: h),
        ], alpha: 1)
        // Eyes shut through the loop; otherwise a grin that opens into a
        // delighted yell as the speed comes on.
        let shut = loop * pow(max(0, sin(spin / 2)), 0.6)
        let whee = clamp01((energy - 0.35) * 2) * speed * 0.8
        rexHead(
            pen, at: head, rotation: rot - m * 0.08, mirror: m,
            blink: blinkFactor(time: time, speed: 0.22) * (1 - 0.85 * shut),
            mouth: whee, grin: 1 - whee)
    }
}

// MARK: - Skip

private extension Visualizer {
    /// A skipping rope. The rope is the biggest thing in the box — a loop the
    /// full height of the figure, whipping round it once a cycle and slapping
    /// flat along the floor when it gets there — and the hop is timed to it:
    /// crouch as the rope comes over the head, clear the floor as it passes
    /// underneath, land as it climbs the far side. Past two-thirds load it
    /// goes round twice a hop — the double-under — knees tucked to make room.
    func drawSkip(time: Double, energy: Double, pen: Pen) {
        // Flipped y-down like the other characters; see drawRex.
        pen.context.translateBy(x: 0, y: pen.rect.height)
        pen.context.scaleBy(x: 1, y: -1)

        let w = Double(pen.rect.width), h = Double(pen.rect.height)
        let gy = 0.87 * h
        rexGround(pen, time: time, gy: gy + 0.02 * h, speed: 0)

        let cx = 0.47 * w
        let phi = fract(time)                      // one cycle = one hop
        // Whole turns only, for the reason boing's flips are: a load parked
        // in the gate band would otherwise hold a rope turning one and a half
        // times a hop, and land the loop in the rex's shins every cycle.
        let double = clamp01((energy - 0.62) / 0.16).rounded()
        let turns = 1 + double

        // Airborne from a fifth of the cycle to four fifths, apex at the
        // half — exactly when a single rope is under the feet. A double
        // passes at a quarter and three quarters instead, so its flight is
        // longer, to have the feet well clear of the floor at both. On the
        // ground either side, one squash spans the landing and the next
        // crouch, deepest at the wrap.
        let airStart = 0.20 - 0.05 * double, airEnd = 0.80 + 0.05 * double
        var air = 0.0, vel = 0.0
        if phi > airStart && phi < airEnd {
            let t = (phi - airStart) / (airEnd - airStart)
            air = sin(.pi * t)
            vel = abs(cos(.pi * t))
        }
        let g = phi >= airEnd ? phi - airEnd : phi + 1 - airEnd
        let squash = air > 0 ? 0 : sin(.pi * g / (1 - airEnd + airStart))
        let hopH = (0.075 + 0.055 * energy) * h * (1 + 0.15 * double)
        let stretch = 1 + 0.10 * vel * air
        let sy = (1 - 0.24 * squash) * stretch
        let sx = (1 + 0.22 * squash) / stretch
        let body = CGPoint(x: cx, y: 0.600 * h - hopH * air + 0.040 * h * squash)
        let rot = 0.06 + 0.05 * air
        func off(_ dx: Double, _ dy: Double) -> CGPoint {
            spun(dx, dy, by: rot, around: body, unit: h)
        }

        rexZoom(pen, aboutX: cx, groundY: gy, factor: 1.20)
        rexShadow(
            pen, cx: cx + 0.01 * h, gy: gy,
            width: 0.165 - 0.060 * air, alpha: 0.16 * (1 - 0.5 * air))

        // Landing dust, both sides.
        if phi >= airEnd {
            let dp = (phi - airEnd) / (1 - airEnd)
            for side in [-1.0, 1.0] {
                pen.dot(
                    at: CGPoint(
                        x: cx + side * (0.09 + 0.12 * dp) * h,
                        y: gy - 0.02 * h - 0.03 * h * dp),
                    radius: 0.018 * (1 - 0.4 * dp),
                    alpha: (1 - dp) * 0.40 * (0.5 + 0.5 * energy))
            }
        }

        // The rope's handles are the hands, low by the hips; the loop is
        // centred on them and clamped to the floor, so on the ground it lies
        // along the boards rather than through them.
        let a = 2 * .pi * phi * turns - .pi / 2
        let ropeC = CGPoint(x: cx, y: body.y + 0.06 * h)
        let floorY = gy + 0.012 * h
        func rim(_ angle: Double) -> CGPoint {
            CGPoint(
                x: ropeC.x + 0.33 * h * cos(angle),
                y: min(floorY, ropeC.y + 0.36 * h * sin(angle)))
        }

        // Far arm, behind the body, turning its own handle.
        let farHand = CGPoint(
            x: off(0.062, 0.062).x + 0.014 * h * cos(a),
            y: off(0.062, 0.062).y + 0.014 * h * sin(a))
        rexArm(pen, shoulder: off(0.060, -0.015), elbow: off(0.078, 0.030), hand: farHand, alpha: 0.40)

        // Legs: planted and bending on the ground, tucked in the air — and
        // tucked hard for the double, where the rope has to fit under twice.
        let tuck = air * (0.55 + 0.45 * double)
        if air > 0.02 {
            let footFar = off(-0.050, 0.200 - 0.085 * tuck)
            let footNear = off(0.062, 0.195 - 0.085 * tuck)
            rexPlantLeg(
                pen, hip: off(-0.050, 0.075), footX: footFar.x, footY: footFar.y,
                kneeOut: 0.050 + 0.035 * tuck, mirror: 1, alpha: 0.85)
            rexPlantLeg(
                pen, hip: off(0.042, 0.075), footX: footNear.x, footY: footNear.y,
                kneeOut: 0.055 + 0.035 * tuck, mirror: 1, alpha: 1)
        } else {
            let bend = 0.040 + 0.030 * squash
            rexPlantLeg(
                pen, hip: off(-0.050, 0.075), footX: cx - 0.082 * h, footY: gy,
                kneeOut: bend, mirror: 1, alpha: 0.85)
            rexPlantLeg(
                pen, hip: off(0.042, 0.075), footX: cx + 0.078 * h, footY: gy,
                kneeOut: bend + 0.008, mirror: 1, alpha: 1)
        }

        rexTail(
            pen, base: off(-0.140, -0.005),
            wag1: -0.030 * h * air + 0.015 * h * squash,
            wag2: -0.065 * h * air + 0.030 * h * squash,
            mirror: 1, alpha: 1)

        pen.fillEllipse(at: body, rx: 0.165 * sx, ry: 0.120 * sy, rotation: rot, alpha: 1)

        // Near arm: elbow in, wrist turning the handle in a small circle.
        let nearHand = CGPoint(
            x: off(0.102, 0.062).x + 0.016 * h * cos(a),
            y: off(0.102, 0.062).y + 0.016 * h * sin(a))
        rexArm(pen, shoulder: off(0.095, -0.010), elbow: off(0.122, 0.028), hand: nearHand, alpha: 1)

        // The head lands a beat after the body.
        let lagPhi = fract(phi - 0.05)
        let lagG = lagPhi >= airEnd ? lagPhi - airEnd : lagPhi + 1 - airEnd
        let lagSquash = (lagPhi > airStart && lagPhi < airEnd)
            ? 0 : sin(.pi * lagG / (1 - airEnd + airStart))
        let head = off(0.115, -0.182 + 0.030 * lagSquash)
        pen.fill([
            off(0.048, -0.058), off(0.132, -0.122),
            spun(-0.020, 0.060, by: rot, around: head, unit: h),
            spun(-0.085, 0.025, by: rot, around: head, unit: h),
        ], alpha: 1)
        let effort = clamp01((energy - 0.70) / 0.30) * (0.4 + 0.6 * air)
        rexHead(
            pen, at: head, rotation: rot + 0.06 + 0.08 * lagSquash,
            blink: blinkFactor(time: time, speed: 0.18) * (1 - 0.5 * squash),
            mouth: effort, grin: 1 - effort)

        // Sweat past seventy percent, as the gallop has it.
        let sweatGate = clamp01((energy - 0.70) / 0.30)
        if sweatGate > 0.01 {
            for k in 0..<2 {
                let dp = fract(time * 1.1 + Double(k) * 0.5)
                let sxp = head.x + (k == 0 ? -1 : 0.4) * (0.05 + 0.11 * dp) * h
                let syp = head.y - (0.09 + 0.06 * dp - 0.11 * dp * dp) * h
                pen.dot(
                    at: CGPoint(x: sxp, y: syp), radius: 0.016,
                    alpha: (1 - dp) * 0.8 * sweatGate)
            }
        }

        // The rope itself, over everything: a blur trailing the tip — longer
        // as the load climbs — and the rope proper, bowed back from the
        // hands to the tip the way a loop seen edge-on is.
        // Six segments, not more: each is its own stroke, and the blur was
        // the difference between this character costing what the others do
        // and costing a fifth more.
        let trail = 0.9 + 0.8 * energy
        let steps = 6
        var prev = rim(a)
        for k in 1...steps {
            let p = rim(a - trail * Double(k) / Double(steps))
            pen.stroke(
                [prev, p], width: 0.024,
                alpha: 0.50 * (1 - Double(k) / Double(steps + 1)))
            prev = p
        }
        let tip = rim(a)
        let bow = CGPoint(
            x: (nearHand.x + tip.x) / 2 + 0.045 * h * sin(a),
            y: (nearHand.y + tip.y) / 2 - 0.045 * h * cos(a))
        pen.stroke([nearHand, bow, tip], width: 0.028, alpha: 0.90)
    }
}

// MARK: - Bungee

private extension Visualizer {
    /// A bungee cord from somewhere above the menu bar. The rex hangs by its
    /// ankles, head down, and the cycle is one bounce: a slow hang at the
    /// top, the plunge, the cord biting at the bottom — where the snout
    /// boops the floor and rings it — and the recoil back up. The cord goes
    /// slack and wavy at the top and thin and straight under load; legs flail
    /// while it is slack and straighten when it bites. The cord drifts a
    /// little to one side and then the other, so the hang is never quite
    /// vertical, and past two-thirds load the recoil adds a full twist.
    func drawBungee(time: Double, energy: Double, pen: Pen) {
        // Flipped y-down like the other characters; see drawRex.
        pen.context.translateBy(x: 0, y: pen.rect.height)
        pen.context.scaleBy(x: 1, y: -1)

        let w = Double(pen.rect.width), h = Double(pen.rect.height)
        let gy = 0.87 * h
        rexGround(pen, time: time, gy: gy + 0.02 * h, speed: 0)

        let phi = fract(time)                      // one cycle = one bounce
        // Depth 0...1: a parabolic start from rest at the top, sharpened
        // where the cord bites at the bottom.
        let wave = 0.5 - 0.5 * cos(2 * .pi * phi)
        let depth = pow(wave, 1.5)
        let vel = abs(sin(2 * .pi * phi)) * sqrt(wave) / 0.77
        let taut = smoothstep(clamp01((depth - 0.25) / 0.50))
        let boop = (phi > 0.43 && phi < 0.57) ? sin(.pi * (phi - 0.43) / 0.14) : 0

        let ax = 0.50 * w
        let anchorY = -0.03 * h
        // The sway runs on a clock twice the bounce, so it alternates sides;
        // the tension pulls it towards centre at the bottom.
        let x = ax + 0.055 * h * sin(.pi * time + 0.4) * (1 - 0.6 * depth)
        let y = 0.270 * h + 0.330 * h * depth
        let body = CGPoint(x: x, y: y)

        let twist = clamp01((energy - 0.62) / 0.18).rounded()
        let spin = 2 * .pi * twist * smoothstep(clamp01((phi - 0.58) / 0.34))
        // Inverted, feet towards the anchor. The extra tilt hangs the head
        // under the ankles: the head sits well forward of the hips, and a
        // body turned exactly half a turn dangles at a visible angle.
        let rot = .pi - 0.22 + atan2(ax - x, y - anchorY) + spin
        func off(_ dx: Double, _ dy: Double) -> CGPoint {
            spun(dx, dy, by: rot, around: body, unit: h)
        }

        rexZoom(pen, aboutX: x, groundY: gy, factor: 1.06)
        rexShadow(
            pen, cx: x, gy: gy, width: 0.080 + 0.090 * depth,
            alpha: 0.06 + 0.12 * depth)

        // The boop: a ring rolling out from where the snout met the floor,
        // dust either side.
        let ring = clamp01((phi - 0.48) / 0.22)
        if ring > 0 && ring < 1 {
            let radius = (0.05 + 0.20 * ring) * (1 + 0.35 * energy)
            let hit = off(0.118, -0.185).x
            pen.strokeEllipse(
                at: CGPoint(x: hit, y: gy), rx: radius, ry: radius * 0.30,
                width: 0.020, alpha: 0.50 * (1 - ring) * (0.55 + 0.45 * energy))
            for side in [-1.0, 1.0] {
                pen.dot(
                    at: CGPoint(
                        x: hit + side * (0.05 + 0.10 * ring) * h,
                        y: gy - 0.02 * h - 0.04 * h * ring),
                    radius: 0.015, alpha: (1 - ring) * 0.40)
            }
        }

        // Legs: straight up the cord when it bites, bent and kicking when
        // it goes slack.
        let kick = 0.045 * sin(2 * .pi * time * 4.5) * (1 - taut)
        let reach = lerp(0.150, 0.235, taut)
        let footFar = off(-0.045 + kick, reach - 0.010)
        let footNear = off(0.035 - kick, reach)
        rexPlantLeg(
            pen, hip: off(-0.050, 0.075), footX: footFar.x, footY: footFar.y,
            kneeOut: 0.045 * (1 - taut) + 0.012, mirror: -1, alpha: 0.85)
        rexPlantLeg(
            pen, hip: off(0.042, 0.075), footX: footNear.x, footY: footNear.y,
            kneeOut: 0.050 * (1 - taut) + 0.012, mirror: -1, alpha: 1)

        // The cord: anchor to ankles, thick and wavy while slack, thin and
        // straight under tension.
        let ankle = CGPoint(x: (footFar.x + footNear.x) / 2, y: (footFar.y + footNear.y) / 2)
        let slack = 1 - taut
        var cord = [CGPoint](repeating: .zero, count: 9)
        for i in 0..<9 {
            let s = Double(i) / 8
            let base = CGPoint(
                x: lerp(ax, ankle.x, s), y: lerp(anchorY, ankle.y, s))
            let wiggle = slack * 0.030 * h * sin(2 * .pi * (1.5 * s - time * 1.7)) * sin(.pi * s)
            cord[i] = CGPoint(x: base.x + wiggle, y: base.y)
        }
        pen.stroke(cord, width: lerp(0.030, 0.018, taut), alpha: 0.75)

        rexTail(
            pen, base: off(-0.140, -0.005),
            wag1: 0.028 * h * sin(2 * .pi * time * 3.7) * (1 - 0.5 * taut) + 0.020 * h * boop,
            wag2: 0.060 * h * sin(2 * .pi * time * 3.7 - 0.8) * (1 - 0.5 * taut) + 0.040 * h * boop,
            mirror: -1, alpha: 1)

        // Stretched along the cord on the way down, squashed at the boop.
        let sy = (1 + 0.16 * vel) * (1 - 0.24 * boop)
        let sx = (1 - 0.08 * vel) * (1 + 0.24 * boop)
        pen.fillEllipse(at: body, rx: 0.165 * sx, ry: 0.120 * sy, rotation: rot, alpha: 1)

        // Arms flailing on their own fast clock, thrown wide at the boop.
        let flail = 2 * .pi * time * 5.1
        rexArm(
            pen, shoulder: off(0.068, -0.020), elbow: off(0.095, -0.070),
            hand: off(0.085 + 0.045 * boop, -0.120 + 0.025 * sin(flail + 1.3)), alpha: 0.5)
        rexArm(
            pen, shoulder: off(0.095, -0.035), elbow: off(0.135, -0.075),
            hand: off(0.165 + 0.050 * boop, -0.110 + 0.030 * sin(flail)), alpha: 1)

        // The head lags the body while the cord is slack, and presses up
        // into the shoulders at the boop.
        let wobble = 0.14 * sin(2 * .pi * time * 2.7) * slack
        let head = off(0.118, -0.185 + 0.022 * boop)
        pen.fill([
            off(0.050, -0.060), off(0.135, -0.125),
            spun(-0.020, 0.060, by: rot, around: head, unit: h),
            spun(-0.085, 0.025, by: rot, around: head, unit: h),
        ], alpha: 1)
        let shut = max(boop, twist * pow(max(0, sin(spin / 2)), 0.6))
        let yell = 0.30 + 0.55 * energy * (1 - boop) + 0.25 * boop
        rexHead(
            pen, at: head, rotation: rot + 0.06 + wobble,
            blink: blinkFactor(time: time, speed: 0.26) * (1 - 0.85 * shut),
            mouth: yell)
    }
}

// MARK: - Achoo

private extension Visualizer {
    /// A sneeze. The first half of the cycle is the wind-up — the belly
    /// swelling in three hitching gulps, the head tilting further back with
    /// each, up on tiptoe, eyes squeezing shut — and then the whole rex
    /// snaps forward at once: deflates, drops, pitches over its own front
    /// foot with the head thrown down and the mouth wide, and a fan of
    /// spray flies out ahead of it. The rest is the wobble back upright, a
    /// dazed shake of the head. The sneeze gets bigger with load: past a
    /// third it lifts the rex off its feet and skids it backwards, and past
    /// two-thirds it is a full backflip.
    func drawAchoo(time: Double, energy: Double, pen: Pen) {
        // Flipped y-down like the other characters; see drawRex.
        pen.context.translateBy(x: 0, y: pen.rect.height)
        pen.context.scaleBy(x: 1, y: -1)

        let w = Double(pen.rect.width), h = Double(pen.rect.height)
        let gy = 0.87 * h
        rexGround(pen, time: time, gy: gy + 0.02 * h, speed: 0)

        let cx = 0.42 * w
        let phi = fract(time)                      // one cycle = one sneeze
        let inhaleEnd = 0.56, blastEnd = 0.66

        // The wind-up ratchets: a smooth swell with three gulps riding on it.
        let inhale = clamp01(phi / inhaleEnd)
        let gulp = max(0, sin(2 * .pi * 3 * inhale)) * (1 - inhale)
        let swell = phi < inhaleEnd ? smoothstep(inhale) + 0.10 * gulp : 1
        // The blast eases from wound-up to thrown-forward in a tenth of the
        // cycle; the recovery is a damped wobble from there back to rest.
        let u = clamp01((phi - inhaleEnd) / (blastEnd - inhaleEnd))
        let v = clamp01((phi - blastEnd) / (1 - blastEnd))
        let blast = phi < inhaleEnd ? 0 : smoothstep(u)
        let settle = phi < blastEnd ? 0 : exp(-3.5 * v) * cos(2 * .pi * 1.3 * v)
        let lurch = phi < blastEnd ? blast : settle
        let lurchFwd = max(0, lurch)
        let swellNow = swell * (1 - blast)
        let dip = phi < inhaleEnd ? 0 : (phi < blastEnd ? blast : exp(-4 * v))

        // The knock-back: a hop backwards that scales with load, and past
        // two-thirds a whole backflip — whole turns only, as boing's are.
        let knock = clamp01((energy - 0.30) / 0.70)
        let flips = clamp01((energy - 0.68) / 0.14).rounded()
        let airStart = 0.62, airEnd = 0.86
        var air = 0.0, tAir = 0.0
        if phi > airStart && phi < airEnd {
            tAir = (phi - airStart) / (airEnd - airStart)
            air = sin(.pi * tAir)
        }
        let land = (phi >= airEnd && phi < airEnd + 0.10)
            ? sin(.pi * (phi - airEnd) / 0.10) * knock : 0
        let back: Double
        if phi < airStart {
            back = 0
        } else if phi < airEnd {
            back = smoothstep(tAir)
        } else {
            back = 1 - smoothstep((phi - airEnd) / (1 - airEnd))
        }
        let x = cx - 0.10 * h * knock * back

        let k = 1 + (0.22 + 0.10 * energy) * swellNow
        let sy = k * (1 - 0.18 * dip) * (1 - 0.25 * land)
        let sx = k * (1 + 0.16 * dip) * (1 + 0.22 * land)
        let body = CGPoint(
            x: x,
            y: 0.600 * h - 0.035 * h * swellNow + 0.045 * h * dip
                - 0.10 * h * knock * air + 0.040 * h * land)
        let rot = -0.14 * swellNow + (0.40 + 0.20 * energy) * lurch
            - 2 * .pi * flips * smoothstep(tAir)
        func off(_ dx: Double, _ dy: Double) -> CGPoint {
            spun(dx, dy, by: rot, around: body, unit: h)
        }

        rexZoom(pen, aboutX: x, groundY: gy, factor: 1.24)
        rexShadow(
            pen, cx: x + 0.01 * h, gy: gy,
            width: 0.165 + 0.030 * swellNow - 0.060 * air,
            alpha: 0.16 * (1 - 0.5 * air))

        // Landing dust after the knock-back, and skid streaks behind it.
        if land > 0.02 {
            let dp = (phi - airEnd) / 0.10
            for side in [-1.0, 1.0] {
                pen.dot(
                    at: CGPoint(
                        x: x + side * (0.09 + 0.12 * dp) * h,
                        y: gy - 0.02 * h - 0.03 * h * dp),
                    radius: 0.018 * (1 - 0.4 * dp), alpha: (1 - dp) * 0.45 * knock)
            }
        }

        // Legs: planted, on tiptoe through the wind-up — the body rises off
        // them — and the front foot slides out to catch the lurch; tucked
        // through the knock-back hop.
        if air > 0.02 {
            let footFar = off(0.045, 0.165), footNear = off(0.110, 0.150)
            rexPlantLeg(
                pen, hip: off(-0.050, 0.075), footX: footFar.x, footY: footFar.y,
                kneeOut: 0.070, mirror: 1, alpha: 0.85)
            rexPlantLeg(
                pen, hip: off(0.042, 0.075), footX: footNear.x, footY: footNear.y,
                kneeOut: 0.072, mirror: 1, alpha: 1)
        } else {
            let bend = 0.040 + 0.030 * (dip + land)
            rexPlantLeg(
                pen, hip: off(-0.050, 0.075), footX: x - 0.085 * h, footY: gy,
                kneeOut: bend, mirror: 1, alpha: 0.85)
            rexPlantLeg(
                pen, hip: off(0.042, 0.075), footX: x + (0.080 + 0.060 * lurchFwd) * h,
                footY: gy, kneeOut: bend + 0.008, mirror: 1, alpha: 1)
        }

        // The tail rises with the breath and whips down with the sneeze.
        rexTail(
            pen, base: off(-0.140, -0.005),
            wag1: -0.045 * h * swellNow + 0.035 * h * lurch,
            wag2: -0.090 * h * swellNow + 0.070 * h * lurch,
            mirror: 1, alpha: 1)

        pen.fillEllipse(at: body, rx: 0.165 * sx, ry: 0.120 * sy, rotation: rot, alpha: 1)

        // Arms: up to the face through the wind-up, flung forward on the
        // sneeze, thrown up through the hop.
        if air > 0.02 {
            rexArm(pen, shoulder: off(0.095, -0.030), elbow: off(0.115, -0.075),
                   hand: off(0.130, -0.125), alpha: 1)
        } else {
            let s = swellNow
            rexArm(
                pen, shoulder: off(0.098, 0.010 - 0.02 * s),
                elbow: off(lerp(0.130, 0.118, s) + 0.030 * lurchFwd, lerp(0.034, -0.045, s)),
                hand: off(lerp(0.158, 0.108, s) + 0.060 * lurchFwd, lerp(0.006, -0.100, s) + 0.040 * lurchFwd),
                alpha: 1)
        }

        // The head: back and back and back, then thrown down; a shake on
        // the way to recovery.
        let bob = 0.07 * gulp * (phi < inhaleEnd ? 1 : 0)
        let shake = phi < blastEnd ? 0 : 0.10 * sin(2 * .pi * 5 * v) * exp(-3 * v)
        let headRot = rot - 0.50 * swellNow + bob + 0.30 * lurch + shake + 0.06
        let head = off(0.118, -0.185)
        pen.fill([
            off(0.050, -0.060), off(0.135, -0.125),
            spun(-0.020, 0.060, by: rot, around: head, unit: h),
            spun(-0.085, 0.025, by: rot, around: head, unit: h),
        ], alpha: 1)
        let shut = phi < inhaleEnd ? 0 : (phi < blastEnd ? blast : exp(-6 * v))
        let mouth = max(0.55 * swellNow, phi < inhaleEnd ? 0 : (phi < blastEnd ? blast : exp(-5 * v)))
        rexHead(
            pen, at: head, rotation: headRot,
            blink: blinkFactor(time: time, speed: 0.235) * (1 - 0.65 * swellNow) * (1 - 0.9 * shut),
            mouth: mouth, grin: 0.5 * (1 - mouth))

        // The spray: a fan of lines and a few droplets, launched from where
        // the snout was at the moment of the sneeze and flying on from there
        // whatever the rex does next.
        let s = clamp01((phi - 0.63) / 0.27)
        if s > 0 && s < 1 {
            let origin = CGPoint(x: cx + 0.250 * h, y: 0.610 * h)
            let aim = 0.50
            for k in 0..<4 {
                let ang = aim + (Double(k) - 1.5) * (0.20 + 0.14 * s)
                let r0 = (0.04 + 0.19 * s) * h, r1 = r0 + 0.08 * h
                pen.stroke(
                    [CGPoint(x: origin.x + r0 * cos(ang), y: origin.y + r0 * sin(ang)),
                     CGPoint(x: origin.x + r1 * cos(ang), y: origin.y + r1 * sin(ang))],
                    width: 0.022, alpha: 0.80 * (1 - s) * (1 - 0.15 * abs(Double(k) - 1.5)))
            }
            for k in 0..<3 {
                let ang = aim + (Double(k) - 1) * 0.36
                let r = (0.07 + 0.22 * s) * h
                pen.dot(
                    at: CGPoint(
                        x: origin.x + r * cos(ang),
                        y: origin.y + r * sin(ang) + 0.10 * h * s * s),
                    radius: 0.020 * (1 - 0.3 * s), alpha: 0.85 * (1 - s))
            }
        }
    }
}

// MARK: - Shred

private extension Visualizer {
    /// A skateboard. Full-width crossings like the dash, but on wheels: a
    /// push off the back foot to get going, a crouch, and an ollie through
    /// the middle of every crossing — the deck pops nose-up and follows the
    /// feet into the air, lands with a squash and a puff of dust at each
    /// wheel — then a kick-turn at the end, the nose rearing up and the deck
    /// pivoting on its tail to face the way back. Past two-thirds load the
    /// ollie turns into a trick: the deck spins a full turn end over end
    /// under the tucked feet and the rex catches it on the way down.
    func drawShred(time: Double, energy: Double, pen: Pen) {
        // Flipped y-down like the other characters; see drawRex.
        pen.context.translateBy(x: 0, y: pen.rect.height)
        pen.context.scaleBy(x: 1, y: -1)

        let w = Double(pen.rect.width), h = Double(pen.rect.height)
        let gy = 0.87 * h
        rexGround(pen, time: time, gy: gy + 0.02 * h, speed: 0)

        let crossing = time.rounded(.down)
        let f = time - crossing                   // one cycle = one crossing
        let m: Double = Int(crossing) % 2 == 0 ? 1 : -1
        let xe = 0.5 - 0.5 * cos(.pi * f)
        let x = lerp(0.25 * w, 0.75 * w, m > 0 ? xe : 1 - xe)
        let speed = sin(.pi * f)

        // The kick-turn straddles the boundary: nose up over the last tenth
        // of one crossing, down over the first tenth of the next. The pivot
        // itself is seen end-on — rex and deck together, via `rexTurn` —
        // and the mirror flip hides inside it.
        let turn = f < 0.12 ? 1 - smoothstep(f / 0.12)
            : (f > 0.88 ? smoothstep((f - 0.88) / 0.12) : 0)

        let push = (f > 0.10 && f < 0.30) ? sin(.pi * (f - 0.10) / 0.20) : 0
        let crouch = (f > 0.30 && f < 0.40) ? sin(.pi * (f - 0.30) / 0.10) : 0
        var air = 0.0, tAir = 0.0
        if f > 0.40 && f < 0.64 {
            tAir = (f - 0.40) / 0.24
            air = sin(.pi * tAir)
        }
        let land = (f >= 0.64 && f < 0.76) ? sin(.pi * (f - 0.64) / 0.12) : 0
        let jumpH = (0.07 + 0.06 * energy) * h
        let tricks = clamp01((energy - 0.62) / 0.16).rounded()

        // The deck lags the feet a little into the air; the trick spins it a
        // whole turn — never a partial one, for boing's reason.
        let deckY0 = gy - 0.075 * h
        let deckC = CGPoint(x: x, y: deckY0 - jumpH * air * 0.85)
        let deckRot = -m * (0.55 * turn + 0.40 * cos(.pi * tAir) * air * (1 - tricks))
            - m * 2 * .pi * tricks * smoothstep(tAir)
        func deck(_ dx: Double, _ dy: Double) -> CGPoint {
            spun(dx, dy, by: deckRot, around: deckC, unit: h)
        }

        let squash = max(crouch, land)
        let stretch = 1 + 0.08 * abs(cos(.pi * tAir)) * air
        let sy = (1 - 0.20 * squash) * stretch
        let sx = (1 + 0.18 * squash) / stretch
        let body = CGPoint(
            x: x,
            y: deckY0 - jumpH * air - 0.235 * h + 0.050 * h * crouch
                + 0.045 * h * land + 0.025 * h * push)
        let rot = m * (0.12 + 0.16 * speed * (1 - air)) - m * 0.33 * turn
        func off(_ dx: Double, _ dy: Double) -> CGPoint {
            spun(dx * m, dy, by: rot, around: body, unit: h)
        }

        rexZoom(pen, aboutX: x, groundY: gy, factor: 1.20)
        rexShadow(
            pen, cx: x, gy: gy, width: 0.175 - 0.060 * air,
            alpha: 0.16 * (1 - 0.5 * air))
        rexTurn(pen, aboutX: x, width: 1 - 0.88 * turnWindow(f, span: 0.06))

        // Speed lines through the fast middle of the crossing.
        let lineAlpha = 0.45 * speed * clamp01(0.20 + energy) * (1 - turn)
        if lineAlpha > 0.03 {
            for k in 0..<3 {
                let y = body.y + (Double(k) - 1) * 0.075 * h
                pen.stroke(
                    [CGPoint(x: x - m * (0.22 + 0.03 * Double(k)) * h, y: y),
                     CGPoint(x: x - m * (0.42 + 0.06 * Double(k)) * h, y: y)],
                    width: 0.022, alpha: lineAlpha * (1 - 0.22 * Double(k)))
            }
        }
        // Landing dust at each wheel; a scuff behind the pushing foot.
        if land > 0.02 {
            let dp = (f - 0.64) / 0.12
            for side in [-1.0, 1.0] {
                pen.dot(
                    at: CGPoint(
                        x: x + side * (0.14 + 0.10 * dp) * h,
                        y: gy - 0.02 * h - 0.03 * h * dp),
                    radius: 0.017 * (1 - 0.4 * dp), alpha: (1 - dp) * 0.40)
            }
        }
        if push > 0.02 {
            for k in 0..<2 {
                pen.dot(
                    at: CGPoint(
                        x: x - m * (0.26 + 0.08 * Double(k) + 0.10 * push) * h,
                        y: gy - 0.02 * h - 0.025 * h * Double(k)),
                    radius: 0.015, alpha: 0.40 * push * (1 - 0.3 * Double(k)))
            }
        }

        // The deck: wheels under, then the board with its kicktails.
        pen.dot(at: deck(-0.135 * m, 0.040), radius: 0.028, alpha: 1)
        pen.dot(at: deck(0.135 * m, 0.040), radius: 0.028, alpha: 1)
        pen.stroke(
            [deck(-0.215 * m, -0.030), deck(-0.165 * m, 0),
             deck(0.165 * m, 0), deck(0.215 * m, -0.030)],
            width: 0.040, alpha: 1)

        // Feet: on the deck — riding it through a plain ollie — except the
        // back foot pushing off the ground, and both tucked up for the trick.
        let backOnDeck = deck(-0.095 * m, -0.014), frontOnDeck = deck(0.085 * m, -0.014)
        let footBack: CGPoint, footFront: CGPoint
        if air > 0.02 && tricks > 0 {
            footBack = off(-0.050, 0.150)
            footFront = off(0.065, 0.140)
        } else if push > 0.02 {
            footBack = CGPoint(
                x: x - m * (0.10 + 0.22 * push) * h,
                y: lerp(backOnDeck.y, gy, push))
            footFront = frontOnDeck
        } else {
            footBack = backOnDeck
            footFront = frontOnDeck
        }
        rexPlantLeg(
            pen, hip: off(-0.050, 0.075), footX: footBack.x, footY: footBack.y,
            kneeOut: 0.045 + 0.040 * squash, mirror: m, alpha: 0.85)

        rexTail(
            pen, base: off(-0.140, -0.005),
            wag1: 0.024 * h * sin(2 * .pi * time * 3.1) * (0.5 + 0.5 * speed) - 0.030 * h * air,
            wag2: 0.050 * h * sin(2 * .pi * time * 3.1 - 0.7) * (0.5 + 0.5 * speed) - 0.060 * h * air,
            mirror: m, alpha: 1)

        pen.fillEllipse(at: body, rx: 0.165 * sx, ry: 0.120 * sy, rotation: rot, alpha: 1)
        rexPlantLeg(
            pen, hip: off(0.042, 0.075), footX: footFront.x, footY: footFront.y,
            kneeOut: 0.050 + 0.040 * squash, mirror: m, alpha: 1)

        // Arms out for balance, the near one leading, both up in the air.
        let wave = 0.02 * sin(2 * .pi * time * 3)
        rexArm(
            pen, shoulder: off(0.060, -0.020), elbow: off(0.080, -0.060),
            hand: off(0.090, -0.105), alpha: 0.4)
        rexArm(
            pen, shoulder: off(0.095, -0.030),
            elbow: off(lerp(0.135, 0.118, air), lerp(-0.055, -0.080, air)),
            hand: off(lerp(0.175, 0.135, air), lerp(-0.085 + wave, -0.135, air)),
            alpha: 1)

        // The head lands a beat after the deck does.
        let lagF = fract(f - 0.04)
        let lagLand = (lagF >= 0.64 && lagF < 0.76) ? sin(.pi * (lagF - 0.64) / 0.12) : 0
        let head = off(0.115, -0.182 + 0.030 * lagLand)
        pen.fill([
            off(0.048, -0.058), off(0.132, -0.122),
            spun(-0.020 * m, 0.060, by: rot, around: head, unit: h),
            spun(-0.085 * m, 0.025, by: rot, around: head, unit: h),
        ], alpha: 1)
        let whee = air * (0.35 + 0.55 * energy)
        rexHead(
            pen, at: head, rotation: rot + m * (0.05 + 0.10 * lagLand), mirror: m,
            blink: blinkFactor(time: time, speed: 0.24) * (1 - 0.5 * land),
            mouth: whee, grin: 0.7 * (1 - whee))
    }
}

// MARK: - Adventures

private extension Visualizer {
    /// Four prop-driven routines share a rig, but have separate choreography.
    /// All coordinates remain deterministic, including ribbons, flame and spray.
    func drawAdventure(time: Double, energy: Double, pen: Pen) {
        let h = Double(pen.rect.height), w = Double(pen.rect.width)
        pen.context.translateBy(x: 0, y: h)
        pen.context.scaleBy(x: 1, y: -1)
        let phase = 2 * Double.pi * time
        let beat = 0.5 - 0.5 * cos(phase)
        let flap = sin(phase)
        let gy = 0.88 * h
        let x = w * (self == .dragon ? 0.42 : 0.48)
        let crouch = self == .lift ? beat : (self == .ninja ? pow(beat, 3) : 0)
        let hover = self == .dragon ? 0.07 + 0.035 * flap : 0
        let ride = self == .surf ? 0.025 * sin(phase) : 0
        let body = CGPoint(x: x, y: (0.59 + 0.09 * crouch - hover + ride) * h)
        let tilt: Double = self == .surf ? 0.17 * sin(phase) :
            (self == .ninja ? 0.24 * sin(phase) : -0.035 * flap)
        func pt(_ dx: Double, _ dy: Double) -> CGPoint {
            spun(dx, dy, by: tilt, around: body, unit: h)
        }
        if self != .dragon && self != .surf {
            rexGround(pen, time: time, gy: gy, speed: self == .ninja ? 0.4 : 0)
        }
        if self == .surf {
            // Two traveling wave crests and droplets beneath the carving board.
            for row in 0..<2 {
                let points = (0...32).map { i -> CGPoint in
                    let u = Double(i) / 32
                    return CGPoint(x: (0.08 + 0.84 * u) * w,
                                   y: gy + (0.025 * Double(row) + 0.035 * sin(u * 4 * .pi - phase)) * h)
                }
                pen.stroke(points, width: row == 0 ? 0.032 : 0.018, alpha: row == 0 ? 0.65 : 0.25)
            }
            for i in 0..<4 {
                let u = fract(time + Double(i) / 4)
                pen.dot(at: CGPoint(x: x - (0.22 + 0.20 * u) * h,
                                    y: gy - (0.02 + (0.12 + 0.08 * energy) * sin(.pi * u)) * h),
                        radius: 0.015 * (1 - 0.5 * u), alpha: 0.65 * (1 - u))
            }
        }
        rexZoom(pen, aboutX: x, groundY: gy, factor: 1.18)
        rexShadow(pen, cx: x, gy: gy, width: 0.19 - hover, alpha: 0.15)

        // The barbell goes down first, behind everything: at the bottom of
        // the squat the bar sits across the back of the neck, and drawn over
        // the head it read as a rod through the face.
        let barY = (0.28 + 0.26 * beat) * h
        if self == .lift {
            pen.stroke([CGPoint(x: x - 0.39 * h, y: barY), CGPoint(x: x + 0.39 * h, y: barY)],
                       width: 0.030, alpha: 1)
            for side in [-1.0, 1.0] {
                for plate in 0..<2 {
                    let px = x + side * (0.30 + Double(plate) * 0.065) * h
                    pen.stroke([CGPoint(x: px, y: barY - 0.07 * h), CGPoint(x: px, y: barY + 0.07 * h)],
                               width: 0.05, alpha: 1)
                }
            }
        }

        if self == .dragon {
            // Bat-like wings, both raised from the shoulder blades and swept
            // back over the tail — a side view, so the near wing beats in
            // front of the far one and neither crosses the face. A strong
            // leading edge with a scalloped membrane behind it.
            for (offset, alpha) in [(-0.06, 0.50), (0.04, 0.85)] {
                let root = pt(-0.02 + offset, -0.05)
                let tip = pt(-0.36 + offset, -0.22 - 0.13 * flap)
                pen.fill([root, pt(-0.15 + offset, -0.31 - 0.06 * flap), tip,
                          pt(-0.27 + offset, -0.07), pt(-0.17 + offset, -0.12),
                          pt(-0.09 + offset, -0.01)], alpha: alpha)
                pen.stroke([root, tip], width: 0.021, alpha: 1)
            }
        }
        if self == .surf {
            pen.fillEllipse(at: CGPoint(x: x, y: gy - 0.025 * h),
                            rx: 0.33, ry: 0.030, rotation: tilt * 0.5, alpha: 1)
        }

        let footY = self == .dragon ? body.y + 0.18 * h : gy - (self == .surf ? 0.055 * h : 0)
        rexPlantLeg(pen, hip: pt(-0.05, 0.065), footX: x - 0.10 * h, footY: footY,
                    kneeOut: 0.05 + 0.06 * crouch, mirror: 1, alpha: 0.65)
        rexTail(pen, base: pt(-0.14, 0), wag1: 0.022 * h * sin(phase - 0.5),
                wag2: 0.045 * h * sin(phase - 1), mirror: 1, alpha: 1)
        // Three dorsal points give the larger silhouette a little attitude.
        for i in 0..<3 {
            let dx = -0.14 + Double(i) * 0.055
            pen.fill([pt(dx - 0.035, -0.060), pt(dx - 0.022, -0.155),
                      pt(dx + 0.025, -0.09)], alpha: 1)
        }
        pen.fillEllipse(at: body, rx: 0.17 * (1 + 0.08 * crouch),
                        ry: 0.125 * (1 - 0.10 * crouch), rotation: tilt, alpha: 1)
        rexPlantLeg(pen, hip: pt(0.045, 0.07), footX: x + (0.11 + 0.035 * crouch) * h,
                    footY: footY, kneeOut: 0.055 + 0.05 * crouch, mirror: 1, alpha: 1)
        let head = pt(0.11, -0.19)
        pen.fill([pt(0.025, -0.07), pt(0.12, -0.15),
                  pt(0.15, -0.19), pt(0.055, -0.22)], alpha: 1)
        rexHead(pen, at: head, rotation: tilt + 0.04,
                blink: blinkFactor(time: time, speed: 0.19),
                mouth: self == .dragon ? 0.8 : 0, grin: 0.8)

        if self == .lift {
            // Full press at the start, squat at mid-cycle; hands stay on the
            // bar, which was drawn behind the body above.
            for side in [-1.0, 1.0] {
                rexArm(pen, shoulder: pt(side * 0.09, -0.03),
                       elbow: CGPoint(x: x + side * 0.19 * h, y: body.y - 0.04 * h),
                       hand: CGPoint(x: x + side * 0.23 * h, y: barY), alpha: 1)
            }
        } else if self == .ninja {
            // The sword traces a wide arc; the ribbon follows with a phase lag.
            let angle = -1.4 + 2.2 * smoothstep(beat)
            let hand = pt(0.19, -0.02)
            rexArm(pen, shoulder: pt(0.08, -0.015), elbow: pt(0.14, 0.045), hand: hand, alpha: 1)
            let tip = CGPoint(x: hand.x + 0.31 * h * cos(angle), y: hand.y + 0.31 * h * sin(angle))
            pen.stroke([hand, tip], width: 0.033, alpha: 1)
            pen.stroke([CGPoint(x: hand.x - 0.04 * h * sin(angle), y: hand.y + 0.04 * h * cos(angle)),
                        CGPoint(x: hand.x + 0.04 * h * sin(angle), y: hand.y - 0.04 * h * cos(angle))], width: 0.026, alpha: 1)
            pen.punchStroke([CGPoint(x: head.x - 0.09 * h, y: head.y - 0.04 * h),
                             CGPoint(x: head.x + 0.07 * h, y: head.y - 0.04 * h)], width: 0.018)
            for side in [-1.0, 1.0] {
                pen.stroke([CGPoint(x: head.x - 0.08 * h, y: head.y - 0.035 * h),
                            pt(-0.12, -0.20 + side * 0.025),
                            pt(-0.25 - 0.06 * energy, -0.20 + side * 0.05 + 0.035 * sin(phase - 1))],
                           width: 0.027, alpha: 0.8)
            }
            let arc = (0...12).map { i -> CGPoint in
                let a = angle - Double(i) * 0.065
                return CGPoint(x: hand.x + 0.35 * h * cos(a), y: hand.y + 0.35 * h * sin(a))
            }
            pen.stroke(arc, width: 0.018, alpha: 0.15 + 0.35 * energy)
        } else {
            rexArm(pen, shoulder: pt(0.095, -0.015), elbow: pt(0.15, 0.015),
                   hand: pt(0.20, self == .surf ? -0.08 : -0.025), alpha: 1)
        }
        if self == .dragon {
            let fire = (0.4 + 0.6 * energy) * (0.65 + 0.35 * sin(phase * 2))
            let origin = CGPoint(x: head.x + 0.14 * h, y: head.y + 0.05 * h)
            pen.fill([origin,
                      CGPoint(x: origin.x + 0.13 * h, y: origin.y - 0.045 * h),
                      CGPoint(x: origin.x + (0.16 + 0.15 * fire) * h, y: origin.y - 0.065 * h),
                      CGPoint(x: origin.x + 0.21 * fire * h, y: origin.y + 0.01 * h),
                      CGPoint(x: origin.x + 0.27 * fire * h, y: origin.y + 0.07 * h),
                      CGPoint(x: origin.x + 0.08 * h, y: origin.y + 0.045 * h)], alpha: 0.45 + 0.5 * energy)
        }
    }
}
