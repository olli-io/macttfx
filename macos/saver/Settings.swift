import Foundation
import ScreenSaver

/// The user settings of the screensaver.
struct Settings {
    static let moduleName = "org.ttfx.screensaver"

    static let fontSizes: [Double] = [8, 10, 12, 14, 16, 18, 20, 24, 28, 32, 40, 48]
    static let frameRates: [Int] = [15, 24, 30, 60]
    static let holdTimes: [Double] = [0, 1, 2, 3, 5, 10, 30]

    /// The effects that are enabled by default.
    static let defaultEffects = [
        "burn", "binarypath", "decrypt", "errorcorrect", "laseretch", "orbittingvolley", "smoke",
        "thunderstorm", "vhstape", "waves", "matrix", "blackhole",
    ]

    /// The effects that the random selection uses.
    var enabledEffects = Set(defaultEffects)

    /// The enabled effects that are in `names`.
    func cycle(from names: [String]) -> [String] {
        names.filter { enabledEffects.contains($0) }
    }

    var fontName = "Menlo"
    var fontSize: Double = 16
    var frameRate = 60
    /// Seconds to show the last frame of an effect.
    var holdTime: Double = 3

    private enum Key {
        static let enabledEffects = "enabledEffects"
        static let fontName = "fontName"
        static let fontSize = "fontSize"
        static let frameRate = "frameRate"
        static let holdTime = "holdTime"
    }

    private static var defaults: UserDefaults {
        ScreenSaverDefaults(forModuleWithName: moduleName) ?? .standard
    }

    static func load() -> Settings {
        let defaults = Settings.defaults
        var settings = Settings()
        if let names = defaults.stringArray(forKey: Key.enabledEffects) {
            settings.enabledEffects = Set(names)
        }
        if let name = defaults.string(forKey: Key.fontName), !name.isEmpty {
            settings.fontName = name
        }
        let fontSize = defaults.double(forKey: Key.fontSize)
        if fontSize >= 4 && fontSize <= 200 {
            settings.fontSize = fontSize
        }
        let frameRate = defaults.integer(forKey: Key.frameRate)
        if frameRate >= 1 && frameRate <= 120 {
            settings.frameRate = frameRate
        }
        if defaults.object(forKey: Key.holdTime) != nil {
            settings.holdTime = max(0, defaults.double(forKey: Key.holdTime))
        }
        return settings
    }

    func save() {
        let defaults = Settings.defaults
        defaults.set(enabledEffects.sorted(), forKey: Key.enabledEffects)
        defaults.set(fontName, forKey: Key.fontName)
        defaults.set(fontSize, forKey: Key.fontSize)
        defaults.set(frameRate, forKey: Key.frameRate)
        defaults.set(holdTime, forKey: Key.holdTime)
        defaults.synchronize()
    }
}
