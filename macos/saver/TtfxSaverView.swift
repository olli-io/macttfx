import AppKit
import ScreenSaver

/// The screensaver view. It runs the enabled ttfx effects in a random
/// sequence on the bundled text.
@objc(TtfxSaverView)
final class TtfxSaverView: ScreenSaverView {
    private enum Phase {
        case running
        /// The last frame stays on the screen until this time.
        case holding(until: Date)
    }

    /// If set, the view uses only this effect. For the development app.
    var forcedEffect: String? {
        didSet { nextEffect() }
    }
    /// The effect that runs now.
    private(set) var currentEffect: String?
    /// The number of effects that ran to completion.
    private(set) var completedEffects = 0

    private var settings = Settings.load()
    private var renderer: CellRenderer?
    private var session: EffectSession?
    private var phase = Phase.running
    private let text = TtfxSaverView.loadText()
    private var optionsSheet: OptionsSheet?
    private var stopObserver: NSObjectProtocol?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        applySettings()
        observeStop()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        applySettings()
        observeStop()
    }

    deinit {
        if let stopObserver {
            DistributedNotificationCenter.default().removeObserver(stopObserver)
        }
    }

    // ------------------------------------------------------------ settings

    /// Reads the settings again and starts a new effect.
    func applySettings() {
        settings = Settings.load()
        animationTimeInterval = 1 / Double(settings.frameRate)
        renderer = nil
        nextEffect()
    }

    private static func loadText() -> Data {
        let bundle = Bundle(for: TtfxSaverView.self)
        var candidates = [bundle.url(forResource: "text", withExtension: "txt")]
        // The development app is not a bundle: the text is adjacent to it.
        candidates.append(
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("text.txt"))
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                return data
            }
        }
        return Data("ttfx".utf8)
    }

    private func makeRenderer() -> CellRenderer {
        var fontSize = settings.fontSize
        // The thumbnail in System Settings shows the same grid at a small size.
        if isPreview, let screen = window?.screen ?? NSScreen.main, screen.frame.width > 0 {
            fontSize *= bounds.width / screen.frame.width
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return CellRenderer(fontName: settings.fontName, fontSize: fontSize, scale: scale)
    }

    // ----------------------------------------------------------- animation

    override func startAnimation() {
        super.startAnimation()
        if session == nil {
            nextEffect()
        }
    }

    override func stopAnimation() {
        super.stopAnimation()
        session = nil
    }

    override func animateOneFrame() {
        switch phase {
        case .running:
            guard let session else {
                nextEffect()
                return
            }
            switch session.step() {
            case 1:
                needsDisplay = true
            case 0:
                completedEffects += 1
                phase = .holding(until: Date().addingTimeInterval(settings.holdTime))
            default:
                nextEffect(advance: true)
            }
        case .holding(let until):
            if Date() >= until {
                nextEffect(advance: true)
            }
        }
    }

    /// Starts an effect: a random enabled effect that is not the current one
    /// if `advance` is true, else the current effect again (for a new
    /// layout). If an effect cannot start, a different one is tried.
    private func nextEffect(advance: Bool = false) {
        session = nil
        needsDisplay = true
        guard bounds.width > 0, bounds.height > 0 else { return }
        let renderer = self.renderer ?? makeRenderer()
        self.renderer = renderer
        let grid = renderer.gridSize(for: bounds.size)

        var candidates: [String]
        if let forcedEffect {
            candidates = [forcedEffect]
        } else {
            var cycle = settings.cycle(from: Effects.names)
            if cycle.isEmpty {
                cycle = Settings.defaultEffects.filter { Effects.names.contains($0) }
            }
            let current = currentEffect.flatMap { cycle.contains($0) ? $0 : nil }
            candidates = cycle.filter { $0 != current }.shuffled()
            if let current {
                // The current effect is the first choice for a new layout
                // and the last choice for a new effect.
                candidates.insert(current, at: advance ? candidates.count : 0)
            }
        }
        for name in candidates {
            let seed = UInt64.random(in: UInt64.min...UInt64.max)
            if let session = EffectSession(
                text: text, effect: name, cols: grid.cols, rows: grid.rows, seed: seed)
            {
                self.session = session
                currentEffect = name
                phase = .running
                return
            }
        }
        // No effect can start. Try again after a short time.
        phase = .holding(until: Date().addingTimeInterval(1))
    }

    // ------------------------------------------------------------- drawing

    override var isOpaque: Bool { true }

    override func draw(_ rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(bounds)
        guard let session, let renderer else { return }
        renderer.draw(
            cells: session.cells, cols: session.cols, rows: session.rows, in: context, bounds: bounds)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed {
            renderer = nil
            nextEffect()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The backing scale factor and the screen size are known now.
        renderer = nil
        nextEffect()
    }

    // ------------------------------------------------------------- options

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        let sheet = OptionsSheet(settings: Settings.load()) { [weak self] in
            self?.applySettings()
        }
        optionsSheet = sheet
        return sheet.window
    }

    // ---------------------------------------------------------------- stop

    /// macOS 14 and later do not destroy the views when the screensaver
    /// stops, and the host process continues to run them. The view releases
    /// the effect and stops the host process.
    private func observeStop() {
        guard ProcessInfo.processInfo.processName.contains("legacyScreenSaver") else { return }
        stopObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screensaver.willstop"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.session = nil
            if !self.isPreview {
                exit(0)
            }
        }
    }
}
