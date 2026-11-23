// Development app: a window that hosts the screensaver view.
//
// Options:
//   --effect NAME       use only this effect
//   --options           show the configuration sheet
//   --size WxH          window content size (default 1200x700)
//   --frames N          run N frames without pacing, print the times, exit
//   --snapshot FILE     with --frames: write the last frame as a PNG file
//   --cycle N           run N effects without pacing, print their names, exit

import AppKit
import ScreenSaver

func argument(after flag: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var view: TtfxSaverView!
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        var size = NSSize(width: 1200, height: 700)
        if let parts = argument(after: "--size")?.split(separator: "x").compactMap({ Double($0) }),
            parts.count == 2
        {
            size = NSSize(width: parts[0], height: parts[1])
        }
        let frame = NSRect(origin: .zero, size: size)
        window = NSWindow(
            contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "ttfx screensaver"
        view = TtfxSaverView(frame: frame, isPreview: false)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let effect = argument(after: "--effect") {
            view.forcedEffect = effect
        }
        view.startAnimation()

        if let frames = argument(after: "--frames").flatMap({ Int($0) }) {
            benchmark(frames: frames)
            NSApp.terminate(nil)
            return
        }
        if let count = argument(after: "--cycle").flatMap({ Int($0) }) {
            printCycle(count: count)
            NSApp.terminate(nil)
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: view.animationTimeInterval, repeats: true) {
            [weak self] _ in
            self?.view.animateOneFrame()
        }
        if CommandLine.arguments.contains("--options"), let sheet = view.configureSheet {
            window.beginSheet(sheet)
        }
    }

    /// Runs `frames` frames and prints the mean time of a step and of a draw.
    private func benchmark(frames: Int) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        var stepTime = 0.0
        var drawTime = 0.0
        var count = 0
        for _ in 0..<frames {
            // Stop at the last frame of the effect, so that the snapshot
            // shows the text.
            if view.completedEffects > 0 { break }
            count += 1
            let start = CFAbsoluteTimeGetCurrent()
            view.animateOneFrame()
            let middle = CFAbsoluteTimeGetCurrent()
            view.cacheDisplay(in: view.bounds, to: bitmap)
            stepTime += middle - start
            drawTime += CFAbsoluteTimeGetCurrent() - middle
        }
        let divisor = Double(max(count, 1))
        print(
            String(
                format: "%@: %d frames, mean step %.3f ms, mean draw %.3f ms",
                view.currentEffect ?? "-", count, stepTime / divisor * 1000,
                drawTime / divisor * 1000))
        if let path = argument(after: "--snapshot"),
            let data = bitmap.representation(using: .png, properties: [:])
        {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Runs `count` effects and prints the name of each one. The hold time
    /// and the effects that use wall time run in real time.
    private func printCycle(count: Int) {
        var last: String?
        var seen = 0
        while true {
            view.animateOneFrame()
            guard view.currentEffect != last else { continue }
            if seen == count { break }
            last = view.currentEffect
            seen += 1
            print(last ?? "-")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
