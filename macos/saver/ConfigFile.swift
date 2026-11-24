import Foundation

/// The optional file `~/.config/macttfx/config`. Each line is `key = value`.
/// Empty lines and lines that start with `#` are ignored.
///
///     font_size = 24
///     text_file = ~/notes/banner.txt
///
/// A value in the file overrides the same value in the options sheet.
struct ConfigFile {
    var fontSize: Double?
    var textFile: URL?

    /// The home directory of the user. The screensaver host has a sandbox,
    /// thus `NSHomeDirectory()` gives the container and not this directory.
    private static var home: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    static var url: URL {
        home.appendingPathComponent(".config/macttfx/config")
    }

    static func load() -> ConfigFile {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return ConfigFile()
        }
        return parse(contents)
    }

    static func parse(_ contents: String) -> ConfigFile {
        var config = ConfigFile()
        for line in contents.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "font_size":
                if let size = Double(value), Settings.fontSizeRange.contains(size) {
                    config.fontSize = size
                }
            case "text_file":
                if !value.isEmpty {
                    config.textFile = resolve(value)
                }
            default:
                break
            }
        }
        return config
    }

    /// An absolute path, a path that starts with `~`, or a path relative to
    /// the directory of the config file.
    private static func resolve(_ path: String) -> URL {
        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2)))
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return url.deletingLastPathComponent().appendingPathComponent(path)
    }
}
