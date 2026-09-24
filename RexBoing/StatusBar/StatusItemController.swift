import AppKit
import SwiftUI
import Combine
import QuartzCore

/// Forwards display-link callbacks through a weak reference.
///
/// `CADisplayLink` retains its target until `invalidate()` is called, so a
/// controller that is its own target can never be released: the `deinit`
/// holding the `invalidate()` call becomes unreachable, and the link would
/// fire into a leaked controller forever. With the proxy in between, the link
/// retains only this small object, the controller stays releasable, and its
/// `deinit` really does tear the link down.
@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var controller: StatusItemController?

    @objc func step(_ link: CADisplayLink) {
        controller?.step(link)
    }
}

/// Owns the `NSStatusItem`: the animated visualiser, the live readouts, and the
/// popover that hosts the dashboard.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let engine: MetricsEngine
    private let preferences = Preferences.shared
    private let popover = NSPopover()

    private var displayLink: CADisplayLink?
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?
    private var buttonAppearanceObservation: NSKeyValueObservation?

    /// The visualiser's own clock, in cycles. Advances at a rate set by load,
    /// so the drawing never has to know what the machine is doing — it is a
    /// pure function of this and of `smoothedLoad`.
    ///
    /// Deliberately unbounded rather than wrapped. Nothing here repeats on a
    /// fixed period — that is the point — so there is no period to wrap to, and
    /// a double has precision to spare: a year of running at two cycles a
    /// second lands around 6×10⁷, where the gap between representable values is
    /// still under a hundredth of a microsecond.
    private var clock: Double = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var scheduledFrameRate: Double = 0
    private var currentLoad: Double = 0
    /// `currentLoad` eased towards. CPU is sampled once a second; without this
    /// every sample lands as a visible jolt in the pace and the amplitude.
    private var smoothedLoad: Double = 0
    private var isPaused = false
    /// A display link has no useful output while another login session owns the
    /// display, or while AppKit knows the status item's window is fully covered.
    /// These are animation-only gates: sampling continues so history remains
    /// complete when the user returns.
    private var sessionIsActive = true
    private var statusItemIsVisible = true
    /// Cached because `shouldAnimate` is consulted more than once per display
    /// frame. The workspace notification below keeps it current.
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private var cachedTooltip = ""

    // MARK: Frame state
    //
    // Only the readouts are cached. They cost real text layout and change at
    // most once a second; the visualiser is redrawn every frame because it is
    // cheap and because caching it would be caching a continuum.

    private struct ReadoutIdentity: Equatable {
        var cells: [ReadoutCell]
        var monochrome: Bool
        var layout: StatusBarRenderer.Layout
        var scale: CGFloat
        var appearance: Int
    }

    private var readoutIdentity: ReadoutIdentity?

    /// The preferences the per-frame path reads, copied out of `Preferences`.
    ///
    /// Reading an `@Published` property is not a field load: it goes through
    /// Combine's enclosing-instance subscript, which does a dynamic cast and a
    /// protocol-conformance lookup on every access. The display link read
    /// four of them per frame, twice over, and a profile of a live instance
    /// put that at half the cost of `step` — more than advancing the clock,
    /// easing the load and retuning the link together. Refreshed in
    /// `refresh`, which every preference change already goes through.
    private struct FrameSettings {
        var animation: AnimationQuality
        var showVisualizer: Bool
        var visualizer: Visualizer
        var monochrome: Bool
        var refreshInterval: TimeInterval

        @MainActor init(_ preferences: Preferences) {
            animation = preferences.animation
            showVisualizer = preferences.showVisualizer
            visualizer = preferences.visualizer
            monochrome = preferences.monochromeMenuBar
            refreshInterval = preferences.refreshInterval
        }
    }

    private var settings: FrameSettings

    /// Time constant for easing towards a new load sample, in seconds.
    ///
    /// Scaled to the sampling interval. A fixed half second absorbed a
    /// one-second cadence, but at two or five seconds the ease finished long
    /// before the next sample arrived, so the pace and the colour ramp moved
    /// in visible steps — a quick lurch, then a plateau — at exactly the
    /// settings chosen for a calmer menu bar. Just under half the interval
    /// keeps the glide going until the next sample takes over, and never
    /// drops below the half second that keeps a burst of work visible as
    /// soon as you look.
    private var loadResponse: Double { max(0.55, 0.45 * settings.refreshInterval) }

    private let canvas = VisualCanvas()
    private var layout = StatusBarRenderer.Layout(size: .zero, visual: .zero, textOrigin: 0)
    private var renderScale: CGFloat = 2
    private var appearanceStamp = 0

    /// The label colour, resolved opaque, with its own alpha kept aside for the
    /// layer. Resolved once per sample under the button's appearance so the
    /// per-frame drawing path never has to touch a dynamic colour.
    ///
    /// This is where the visualiser's colour starts, not where it ends: at rest
    /// the field is drawn in it, and `LoadInk` carries it up its ramp as the
    /// machine works.
    private var neutralInk: NSColor = .labelColor
    private var inkAlpha: Float = 1

    /// Last ramped colour, with the load it was built for.
    ///
    /// The ramp is resolved per frame rather than per sample, because the load
    /// underneath it glides between samples and a colour that stepped once a
    /// second would visibly pop against motion that does not. Per frame is the
    /// right rate to *look* at it and the wrong one to rebuild it, hence the
    /// memo: a colour a thousandth of the way along a continuous ramp is the
    /// colour already on screen.
    private var rampedInk: NSColor?
    private var rampedInkLoad: Double = -1

    private var readoutLayer: CALayer?
    private var visualLayer: CALayer?

    init(engine: MetricsEngine) {
        self.engine = engine
        self.settings = FrameSettings(Preferences.shared)
        Self.seedPreferredPositionIfNeeded()
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        configurePopover()
        observe()
        // Started where the machine actually is, so the first second on screen
        // is not a ramp up from an idle the Mac was never at.
        currentLoad = engine.snapshot.cpu.total
        smoothedLoad = currentLoad
        refresh(engine.snapshot, force: true)
        startAnimation()
    }

    isolated deinit {
        displayLink?.invalidate()
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Setup

    /// macOS keeps status item ordering as a number per item, stored in the
    /// owning app's defaults under `NSStatusItem Preferred Position <name>`.
    /// Larger values sit further to the left. `<name>` is the autosave name
    /// set in `configureButton` — still the app's original one, on purpose.
    private static let positionKey = "NSStatusItem Preferred Position Zoomies"
    private static let didSeedPositionKey = "didSeedStatusItemPosition"

    /// Where a first-run item is placed. Chosen to land among the ordinary
    /// utility items rather than at the extreme left.
    ///
    /// Without this, macOS gives a brand-new status item the leftmost slot —
    /// which on a Mac running a menu bar manager (Hidden Bar, Bartender, Ice)
    /// is exactly the region those tools collapse. The app then appears to have
    /// launched and done nothing. Hidden Bar's own separator sits at 751 and
    /// everything it hides is above that, so a mid-range value keeps Rex Boing in
    /// the always-visible band.
    private static let defaultPosition = 300

    /// Runs before the status item is created, so the value is in place when
    /// AppKit reads it. Only ever seeds once — after that the position belongs
    /// to the user, who can ⌘-drag the item wherever they like.
    private static func seedPreferredPositionIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didSeedPositionKey) else { return }
        defaults.set(true, forKey: didSeedPositionKey)

        guard defaults.object(forKey: positionKey) == nil else { return }
        defaults.set(defaultPosition, forKey: positionKey)
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        // Persists the position across launches, including any ⌘-drag. The
        // name is the app's original one, kept deliberately: it is the key
        // every existing install has saved its placement under, and renaming
        // it would send the item back to the leftmost slot on all of them.
        statusItem.autosaveName = "Zoomies"
        button.target = self
        button.action = #selector(handleClick)
        // Mouse *down*, not up: system menu extras and every RunCat-style
        // item respond on the press, and the released-based version read as
        // lag — the dashboard did nothing for as long as the button was held.
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.imagePosition = .imageOnly
        button.toolTip = "Rex Boing"
    }

    /// The dashboard content is *not* installed here. A hosting view keeps its
    /// SwiftUI graph alive — and observing the engine — for as long as it
    /// exists, whether or not the popover is on screen. Built once at launch,
    /// the closed dashboard kept re-evaluating all seven cards on every sample,
    /// and the observation bookkeeping that each pass allocates is never given
    /// back: measured on a two-day-old instance, a quarter of a CPU core and a
    /// couple of hundred megabytes of registrar tables, growing by the tick.
    /// The content is created when the popover opens and torn down when it
    /// closes, so a closed dashboard costs what it looks like it costs: nothing.
    private func configurePopover() {
        popover.behavior = .transient
        // No entrance animation: the dashboard should appear on the press,
        // the way a system menu does. The quarter second of scale-in read as
        // the app being slow to respond rather than as polish.
        popover.animates = false
        popover.delegate = self
    }

    private func observe() {
        // `DispatchQueue.main` rather than `RunLoop.main`: the run loop
        // scheduler delivers in the default mode only, so every menu bar
        // update stalled for as long as any menu was open or a scroll was in
        // flight — exactly when the numbers are being read.
        engine.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                self.currentLoad = snapshot.cpu.total
                // Keep the latest load, but avoid text/layout/layer work when
                // there is no status-item window a user can see. The visibility
                // and session notifications force one complete refresh on return.
                guard self.sessionIsActive, self.statusItemIsVisible else { return }
                self.refresh(snapshot)
            }
            .store(in: &cancellables)

        // Any of these change the item's layout, so re-render immediately
        // rather than waiting for the next sample.
        Publishers.MergeMany(
            preferences.$readouts.map { _ in () }.eraseToAnyPublisher(),
            preferences.$showVisualizer.map { _ in () }.eraseToAnyPublisher(),
            preferences.$visualizer.map { _ in () }.eraseToAnyPublisher(),
            preferences.$monochromeMenuBar.map { _ in () }.eraseToAnyPublisher(),
            preferences.$temperatureUnit.map { _ in () }.eraseToAnyPublisher(),
            preferences.$animation.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            guard let self else { return }
            self.refresh(self.engine.snapshot, force: true)
        }
        .store(in: &cancellables)

        // There is no point animating while the display is off or another fast-
        // user-switching session owns it. Display sleep pauses telemetry too;
        // session inactivity only pauses pixels, preserving background history.
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(true) }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(false) }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setSessionActive(false) }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setSessionActive(true) }
        })

        // System wake, distinct from display wake: on Apple silicon the
        // uptime clock keeps ticking through sleep, so the engine cannot
        // infer a short sleep from its clocks — it has to be told, or the
        // first post-wake tick publishes deltas that span the sleep.
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.noteSystemWake() }
        })

        // Reduce Motion can be toggled while the app is running.
        observers.append(center.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self.refresh(self.engine.snapshot, force: true)
            }
        })

        // Dragging the item to a display with a different backing scale changes
        // what a crisp frame is, so both caches have to be redrawn for it.
        let defaultCenter = NotificationCenter.default
        if let statusWindow = statusItem.button?.window {
            observers.append(defaultCenter.addObserver(
                forName: NSWindow.didChangeBackingPropertiesNotification,
                object: statusWindow, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateStatusItemVisibility()
                    self.refresh(self.engine.snapshot, force: true)
                }
            })

            // AppKit's occlusion state accounts for the window being fully covered
            // or removed from the visible menu-bar space. Pause the display link in
            // either case; its next visible-state notification redraws immediately.
            observers.append(defaultCenter.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: statusWindow, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStatusItemVisibility() }
            })
        }
        updateStatusItemVisibility()

        // Switching between light and dark invalidates every cached frame.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.appearanceStamp &+= 1
                self.refresh(self.engine.snapshot, force: true)
            }
        }

        // The readout ink is resolved under the *button's* appearance (see
        // `refresh`), which can move without the app-level one — per-display
        // appearance is the usual way — so watch both. Where the two fire for
        // the same switch the second pass finds an identical `ReadoutIdentity`
        // short of the stamp and merely re-rasterises once more.
        buttonAppearanceObservation = statusItem.button?
            .observe(\.effectiveAppearance) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.appearanceStamp &+= 1
                    self.refresh(self.engine.snapshot, force: true)
                }
            }
    }

    private func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        engine.setSamplingPaused(paused)
        retuneAnimation()
        // A still pose while asleep, and motion again on wake.
        refresh(engine.snapshot, force: true)
    }

    private func setSessionActive(_ active: Bool) {
        guard sessionIsActive != active else { return }
        sessionIsActive = active
        if active { updateStatusItemVisibility() }
        retuneAnimation()
        refresh(engine.snapshot, force: true)
    }

    private func updateStatusItemVisibility() {
        guard let window = statusItem.button?.window else { return }
        let visible = window.occlusionState.contains(.visible)
        guard statusItemIsVisible != visible else { return }
        statusItemIsVisible = visible
        retuneAnimation()
        if visible { refresh(engine.snapshot, force: true) }
    }

    // MARK: - Animation

    /// The visualiser is driven by a display link rather than a timer.
    ///
    /// A timer at some chosen frequency and a screen refreshing at another beat
    /// against each other: frames land unevenly however precisely they are
    /// scheduled, and the stutter that produces is far more visible than a low
    /// frame rate is. A display link fires in step with the display, so every
    /// frame lands on a refresh, and asking it for a rate lets the system pick
    /// the nearest cadence it can actually deliver instead of us guessing.
    private func startAnimation() {
        guard displayLink == nil, let button = statusItem.button else { return }
        let proxy = DisplayLinkProxy()
        proxy.controller = self
        let link = button.displayLink(
            target: proxy, selector: #selector(DisplayLinkProxy.step(_:)))
        // `.common` keeps the animation running while a menu is tracking.
        link.add(to: .main, forMode: .common)
        displayLink = link
        retuneAnimation()
    }

    /// Brings the display link into line with the current state: paused when
    /// nothing is moving, otherwise asking for the frame rate the motion needs.
    private func retuneAnimation(
        rate proposedRate: (fps: Double, pace: Double)? = nil
    ) {
        guard let link = displayLink else { return }

        guard shouldAnimate else {
            link.isPaused = true
            scheduledFrameRate = 0
            return
        }

        let rate = proposedRate ?? animationRate
        if link.isPaused {
            link.isPaused = false
            lastFrameTime = 0
        }

        // Re-tune only when the requested rate has moved enough to matter,
        // otherwise every sample would renegotiate the cadence.
        guard scheduledFrameRate == 0
            || abs(rate.fps - scheduledFrameRate) / scheduledFrameRate > 0.2
        else { return }

        scheduledFrameRate = rate.fps
        let fps = Float(rate.fps)
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: max(1, fps * 0.5), maximum: fps, preferred: fps)
    }

    /// See `Visualizer.minimumFramesPerCycle`; shared with the settings
    /// preview so both clamp the pace the same way.
    private static var minimumFramesPerCycle: Double { Visualizer.minimumFramesPerCycle }

    /// Frame rate and animation pace for the current load, as a matched pair.
    ///
    /// These have to be solved together. The frame rate follows the pace, but
    /// the quality setting caps it, and a pace that ignores that cap goes
    /// stroboscopic: the motion advances most of a cycle between frames and
    /// at maximum load appears to crawl. Clamping the pace to what the frame
    /// rate can actually show keeps the motion legible at every quality level.
    ///
    /// The floor matters as much as the ceiling. An idling field asks for a
    /// third of a cycle a second, and a frame rate derived from that alone
    /// would be a slideshow, so the rate never drops below a third of the
    /// ceiling — which is what makes a resting visualiser look unhurried rather
    /// than broken.
    private var animationRate: (fps: Double, pace: Double) {
        let animation = settings.animation
        let ceiling = animation.maximumFrameRate
        guard ceiling > 0 else { return (0, 0) }

        let desired = settings.visualizer.rate(
            forLoad: smoothedLoad, speedFactor: animation.paceFactor)
        let floor = max(6, ceiling / 3)
        let fps = min(ceiling, max(floor, desired * animation.framesPerCycle))
        // The pace is held to the *minimum* frames a cycle needs, not to the
        // setting's target. A higher setting should buy smoothness, not cost
        // the visualiser its top speed.
        return (fps, min(desired, fps / Self.minimumFramesPerCycle))
    }

    fileprivate func step(_ link: CADisplayLink) {
        guard shouldAnimate else {
            retuneAnimation()
            return
        }

        let now = link.timestamp
        // The first frame after a pause has no meaningful elapsed time.
        let delta = lastFrameTime == 0 ? 0 : min(0.25, max(0, now - lastFrameTime))
        lastFrameTime = now

        var resolvedRate: (fps: Double, pace: Double)?
        if delta > 0 {
            // Exponential easing towards the last sample, framed in seconds so
            // the response is the same whatever rate the link is running at.
            smoothedLoad += (currentLoad - smoothedLoad)
                * (1 - exp(-delta / loadResponse))
            // Clamped against the rate the link is actually tuned to, not the
            // ideal one: retune has a 20% hysteresis band, and a pace derived
            // from the fresh ideal while the link still runs the older, lower
            // cadence spends fewer frames per cycle than the aliasing floor —
            // the exact stroboscopic failure the clamp exists to prevent.
            let rate = animationRate
            resolvedRate = rate
            let deliverable = scheduledFrameRate > 0
                ? min(rate.fps, scheduledFrameRate) : rate.fps
            clock += min(rate.pace, deliverable / Self.minimumFramesPerCycle) * delta
        }

        present()
        // Cheap: the rate only actually changes when the load has moved enough
        // to matter, and the pace now glides between samples rather than
        // stepping at them, so this has to be checked more often than once a
        // sample to keep up with it.
        // Reuse the matched rate/pace pair already calculated above. This runs
        // every drawn frame, so even small duplicate preference and rate work is
        // worth removing in an app intended to stay alive indefinitely.
        retuneAnimation(rate: resolvedRate)
    }

    private var shouldAnimate: Bool {
        guard settings.animation.isAnimated,
              settings.showVisualizer,
              !isPaused,
              sessionIsActive,
              statusItemIsVisible
        else {
            return false
        }
        return !reduceMotion
    }

    // MARK: - Rendering

    private func refresh(_ snapshot: Snapshot, force: Bool = false) {
        settings = FrameSettings(preferences)
        // The easing loop is the only thing that advances `smoothedLoad`, and
        // it is not running when animation is off, Reduce Motion is on, or the
        // item is paused — modes that still draw a still pose whose amplitude
        // and colour ramp off this value. Snap it to the sample here, or the
        // still frame holds whatever the load was when easing last ran.
        if !shouldAnimate { smoothedLoad = currentLoad }
        updateTooltip(for: snapshot)

        // Resolved once, inside the button's own appearance. `labelColor` is
        // dynamic, and rendering eagerly means it would otherwise resolve
        // against whatever appearance happened to be current — which for an
        // accessory app is not reliably the menu bar's.
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            let label = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .labelColor
            // Drawn opaque, with the label colour's own transparency applied to
            // the layer instead. The visualisers overlap themselves constantly
            // — that is what the depth cues are made of — and translucent ink
            // would let every crossing brighten.
            let resolved = label.withAlphaComponent(1)
            // Switching between light and dark moves the foot of the ramp, so
            // anything built on the old one is stale.
            if resolved != neutralInk { rampedInk = nil }
            neutralInk = resolved
            inkAlpha = Float(label.alphaComponent)
            rebuildReadouts(snapshot, force: force)
            configureVisualLayer()
        }

        // The frame rate follows the load, so it has to be renegotiated when a
        // new sample lands and not only when a setting changes — otherwise a
        // link tuned for an idle machine keeps delivering idle frames while the
        // motion underneath it races, which is the stroboscopic failure the
        // pace clamp exists to prevent.
        retuneAnimation()
        // The one retry path for a display link that could not be made at
        // init because the button did not exist yet. `startAnimation` already
        // guards the created case, so this is a nil check per sample.
        if displayLink == nil { startAnimation() }
        // An active display link will draw this state on its next scheduled
        // frame. Avoid inserting an extra unsynchronised frame on every sample.
        if force || !shouldAnimate { present() }
    }

    private func rebuildReadouts(_ snapshot: Snapshot, force: Bool) {
        var cells = preferences.readouts.map { cell(for: $0, snapshot: snapshot) }
        // Turning off the visualiser *and* every readout would leave a blank sliver
        // of menu bar that is nearly impossible to find and click. Fall back to
        // CPU so the item always has something to show.
        if cells.isEmpty, !preferences.showVisualizer {
            cells = [cell(for: .cpu, snapshot: snapshot)]
        }

        let layout = StatusBarRenderer.layout(
            cells: cells, hasVisual: preferences.showVisualizer)
        self.layout = layout
        renderScale = statusItem.button?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2

        // At idle the formatted cells are identical sample after sample — "3%"
        // follows "3%" for minutes at a time — and re-rasterising text to
        // arrive at the same pixels is pure waste.
        let identity = ReadoutIdentity(
            cells: cells, monochrome: preferences.monochromeMenuBar,
            layout: layout, scale: renderScale, appearance: appearanceStamp)
        guard force || identity != readoutIdentity else { return }
        readoutIdentity = identity

        let image = StatusBarRenderer.renderReadouts(
            cells: cells, layout: layout,
            monochrome: preferences.monochromeMenuBar, scale: renderScale)

        // Pin the item to the width of what it is about to show.
        //
        // With `NSStatusItem.variableLength`, changing the content makes AppKit
        // re-measure the item and push fresh scene settings to the window
        // server — a synchronous IPC round trip plus a CoreAnimation fence.
        // An explicit length lets the window server leave the scene untouched,
        // which is what reduces an animation frame to a layer property
        // assignment.
        if layout.size.width > 0, statusItem.length != layout.size.width {
            statusItem.length = layout.size.width
        }

        guard let button = statusItem.button else { return }
        let layer = readoutLayer ?? makeLayer(on: button)
        withoutAnimation {
            layer.frame = CGRect(origin: .zero, size: layout.size)
            layer.contentsScale = renderScale
            layer.contents = image
        }
    }

    /// Puts the visualiser's layer where the layout says it goes. The drawing
    /// itself happens in `present`, on every frame.
    private func configureVisualLayer() {
        guard settings.showVisualizer else {
            visualLayer?.isHidden = true
            return
        }
        guard let button = statusItem.button else { return }

        let parent = readoutLayer ?? makeLayer(on: button)
        let layer = visualLayer ?? makeVisualLayer(in: parent)
        withoutAnimation {
            layer.isHidden = false
            layer.frame = layout.visual
            layer.contentsScale = renderScale
            layer.opacity = inkAlpha
        }
    }

    /// Asks for the current instant to be redrawn.
    ///
    /// The visualiser lives in a sublayer we own rather than in `button.image`.
    /// Assigning the image runs NSButtonCell's invalidation path and makes the
    /// status item re-publish itself to the window server; marking a sublayer
    /// dirty is a plain CoreAnimation update with none of that around it. The
    /// button's own image is left empty so there is nothing drawn over the top.
    private func present() {
        guard settings.showVisualizer, let layer = visualLayer else { return }
        canvas.visual = settings.visualizer
        // A still frame is a moment, not the start of a cycle.
        canvas.time = shouldAnimate ? clock : Visualizer.restingTime
        canvas.load = smoothedLoad
        canvas.color = currentInk
        layer.setNeedsDisplay()
    }

    /// The visualiser's ink for the load on screen right now.
    ///
    /// Monochrome keeps its promise here: the setting exists for people who
    /// want the menu bar to look like the menu bar, and a colour ramp is
    /// precisely what it is opting out of.
    private var currentInk: NSColor {
        guard !settings.monochrome else { return neutralInk }

        // Two hundred steps across the ramp: finer than the eye resolves in a
        // thirty-point field, coarse enough that a machine sitting at a steady
        // load rebuilds nothing.
        let quantised = (smoothedLoad * 200).rounded() / 200
        if let cached = rampedInk, quantised == rampedInkLoad { return cached }

        let color = LoadInk.color(forLoad: quantised, neutral: neutralInk)
        rampedInk = color
        rampedInkLoad = quantised
        return color
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func makeLayer(on button: NSStatusBarButton) -> CALayer {
        button.wantsLayer = true
        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: layout.size)
        layer.contentsGravity = .center
        layer.contentsScale = renderScale
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        button.layer?.addSublayer(layer)
        readoutLayer = layer
        return layer
    }

    /// The visualiser rides in its own sublayer, pinned to the left of the item
    /// so it stays put if AppKit ever gives the button a different width than
    /// the readouts asked for.
    private func makeVisualLayer(in parent: CALayer) -> CALayer {
        let layer = CALayer()
        layer.frame = layout.visual
        layer.contentsScale = renderScale
        layer.delegate = canvas
        layer.autoresizingMask = [.layerMaxXMargin, .layerMinYMargin, .layerMaxYMargin]
        parent.addSublayer(layer)
        visualLayer = layer
        return layer
    }

    private func cell(for readout: MenuBarReadout, snapshot: Snapshot) -> ReadoutCell {
        let unit = preferences.temperatureUnit
        var value = "—"
        var tint: NSColor?
        var caption = readout.badge

        switch readout {
        case .cpu:
            value = Format.percent(snapshot.cpu.total)
            tint = Severity.load(snapshot.cpu.total).color
        case .gpu:
            value = snapshot.gpu.available ? Format.percent(snapshot.gpu.utilization) : "—"
            tint = Severity.load(snapshot.gpu.utilization).color
        case .memory:
            value = Format.percent(snapshot.memory.fractionUsed)
            tint = Severity.memory(snapshot.memory.pressureLevel).color
        case .swap:
            value = Format.compactBytes(snapshot.memory.swap.used)
            tint = Severity.load(snapshot.memory.swap.fraction).color
        case .cpuTemperature:
            if let celsius = snapshot.thermal.cpuCelsius {
                value = String(format: "%.0f°", Format.temperatureValue(celsius, unit: unit))
                tint = Severity.temperature(celsius).color
            }
        case .gpuTemperature:
            if let celsius = snapshot.thermal.gpuCelsius {
                value = String(format: "%.0f°", Format.temperatureValue(celsius, unit: unit))
                tint = Severity.temperature(celsius).color
            }
        case .power:
            if let watts = snapshot.power.totalWatts {
                value = String(format: "%.1fW", watts)
            }
        case .network:
            // Throughput is inherently two numbers, so the caption row carries
            // the download rate and the value row the upload rate.
            caption = "↓" + Format.compactRate(snapshot.network.rxBytesPerSecond)
            value = "↑" + Format.compactRate(snapshot.network.txBytesPerSecond)
        case .disk:
            caption = "R" + Format.compactRate(snapshot.disk.readBytesPerSecond)
            value = "W" + Format.compactRate(snapshot.disk.writeBytesPerSecond)
        case .battery:
            if snapshot.battery.present {
                value = Format.percent(snapshot.battery.percentage)
                tint = snapshot.battery.percentage < 0.2 && !snapshot.battery.isCharging
                    ? Severity.critical.color : nil
            }
        }

        return ReadoutCell(
            caption: caption,
            value: value,
            tint: tint,
            width: StatusBarRenderer.width(for: readout))
    }

    /// Assigning a tooltip tears down and rebuilds the button's tracking rect,
    /// so it belongs here — once per sample — rather than on the animation path.
    private func updateTooltip(for snapshot: Snapshot) {
        var lines = ["CPU \(Format.percent(snapshot.cpu.total, decimals: 1))"]
        if snapshot.gpu.available {
            lines.append("GPU \(Format.percent(snapshot.gpu.utilization))")
        }
        lines.append("Memory \(Format.bytes(snapshot.memory.used)) of \(Format.bytes(snapshot.memory.total))")
        if snapshot.memory.swap.used > 0 {
            lines.append("Swap \(Format.bytes(snapshot.memory.swap.used))")
        }
        if let celsius = snapshot.thermal.cpuCelsius {
            lines.append("CPU \(Format.temperature(celsius, unit: preferences.temperatureUnit))")
        }

        let tooltip = lines.joined(separator: "\n")
        guard tooltip != cachedTooltip else { return }
        cachedTooltip = tooltip
        statusItem.button?.toolTip = tooltip
        statusItem.button?.setAccessibilityLabel(
            "Rex Boing. " + tooltip.replacingOccurrences(of: "\n", with: ", "))
    }

    // MARK: - Interaction

    @objc private func handleClick() {
        // A synthesised activation — VoiceOver, or anything driving the item
        // through the accessibility API — arrives with no current event. Bailing
        // out on that made the status item completely inert for those callers;
        // the sensible default is the same thing a plain click does.
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }

        // A ⌘-press is the system's grab-and-drag for rearranging the item;
        // opening the dashboard on it would fight the drag.
        if event.modifierFlags.contains(.command) { return }

        if event.type == .rightMouseDown || event.type == .rightMouseUp
            || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    /// True while `togglePopover` is the one closing the popover, so the
    /// delegate can tell a deliberate toggle from a transient dismissal.
    private var isClosingViaToggle = false
    /// When the popover was last closed by something other than the toggle —
    /// the transient click-outside monitor, or the escape key.
    private var lastExternalPopoverClose: CFTimeInterval = 0

    private func togglePopover() {
        if popover.isShown {
            isClosingViaToggle = true
            popover.performClose(nil)
            return
        }

        // Acting on mouse-down races the transient dismissal: when the
        // popover is open and the item is pressed again, this action and the
        // popover's own click-outside monitor both see the same event, in no
        // guaranteed order. If the monitor won, the popover is already closed
        // by the time this runs — but the press meant "close", not "reopen".
        // Toggle-closes are exempt from the stamp, so an open right after a
        // deliberate close is never swallowed.
        guard CACurrentMediaTime() - lastExternalPopoverClose > 0.25 else { return }

        // The window check mirrors what `popover.show` will assert: a
        // button collapsed out of the bar by a menu-bar manager has no
        // window, and raising through `show` *after* the hosting content
        // is installed and the sampling counter bumped would strand both —
        // the exact always-observing leak the popover teardown exists to
        // prevent.
        guard let button = statusItem.button, button.window != nil else { return }
        let size = CGSize(
            width: Metrics.dashboardWidth,
            height: Metrics.dashboardHeight(on: button.window?.screen))
        let hosting = NSHostingController(
            rootView: DashboardView(height: size.height)
                .environmentObject(engine)
                .environmentObject(preferences))
        // The dashboard is a fixed-size view, and saying so *before* `show`
        // matters: left to measure the SwiftUI content itself, the popover
        // learns the width a layout pass after it has been positioned. Near
        // the right edge of the screen it opened at a provisional size and
        // then grew straight past the edge, clipping the trailing column.
        // Told up front, AppKit slides the window left to keep all of it on
        // screen and lets the arrow stay under the item.
        hosting.preferredContentSize = size
        popover.contentViewController = hosting
        popover.contentSize = size
        engine.beginDashboardSampling()
        engine.refreshNow()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Bring the popover's window forward so it takes key focus, which
        // an accessory app does not get automatically.
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let dashboard = NSMenuItem(
            title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "")
        dashboard.target = self
        menu.addItem(dashboard)

        let breakdown = NSMenuItem(
            title: "Process Breakdown…", action: #selector(openProcessBreakdown),
            keyEquivalent: "")
        breakdown.target = self
        menu.addItem(breakdown)

        menu.addItem(.separator())

        // The cast, one click away. Switching characters is the setting
        // people change most, and a trip through the settings window for it
        // is a poor trade for a menu that is already open.
        let character = NSMenuItem(title: "Character", action: nil, keyEquivalent: "")
        let characters = NSMenu(title: "Character")
        for visual in Visualizer.allCases {
            let item = NSMenuItem(
                title: visual.name, action: #selector(selectCharacter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = visual.rawValue
            item.state = visual == preferences.visualizer ? .on : .off
            item.image = VisualizerIcon.menuImage(for: visual)
            item.toolTip = visual.detail
            characters.addItem(item)
        }
        character.submenu = characters
        menu.addItem(character)

        let showVisualizer = NSMenuItem(
            title: "Show Visualizer", action: #selector(toggleVisualizer), keyEquivalent: "")
        showVisualizer.target = self
        showVisualizer.state = preferences.showVisualizer ? .on : .off
        menu.addItem(showVisualizer)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let about = NSMenuItem(title: "About Rex Boing", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Rex Boing", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Detach again so the next left click opens the popover instead of the menu.
        statusItem.menu = nil
    }

    @objc private func openDashboard() { togglePopover() }

    /// Opens the breakdown on the newest retained sample, riding the stream
    /// from there — the same window a graph click opens, without the graph.
    @objc private func openProcessBreakdown() {
        let latest = engine.processHistory.samples.last?.timestamp ?? Date()
        ProcessInspectorWindowController.shared.show(
            engine: engine, metric: .cpu, at: latest)
    }

    @objc private func selectCharacter(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let visual = Visualizer(rawValue: raw) else { return }
        preferences.visualizer = visual
    }

    @objc private func toggleVisualizer() {
        preferences.showVisualizer.toggle()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show(engine: engine)
    }

    @objc private func openAbout() {
        AboutPanel.show()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        if isClosingViaToggle {
            isClosingViaToggle = false
        } else {
            // Closed from outside the toggle — remember when, so a press
            // that raced the transient dismissal does not instantly reopen.
            lastExternalPopoverClose = CACurrentMediaTime()
        }
        engine.endDashboardSampling()
        // Release the dashboard with the popover. See `configurePopover`.
        popover.contentViewController = nil
    }
}
