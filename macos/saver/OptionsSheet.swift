import AppKit

/// The configuration sheet. The controls are made in code; there is no nib.
final class OptionsSheet: NSObject {
    let window: NSWindow

    private var settings: Settings
    private let onSave: () -> Void
    private var effectBoxes: [NSButton] = []
    private let fontPopup = NSPopUpButton()
    private let sizePopup = NSPopUpButton()
    private let ratePopup = NSPopUpButton()
    private let holdPopup = NSPopUpButton()

    /// `onSave` runs after the settings are saved.
    init(settings: Settings, onSave: @escaping () -> Void) {
        self.settings = settings
        self.onSave = onSave
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.title = "ttfx"
        window.isReleasedWhenClosed = false
        super.init()
        buildContent()
    }

    // -------------------------------------------------------------- layout

    private func buildContent() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(heading("Effects"))
        let effects = effectGrid()
        stack.addArrangedSubview(effects)
        let selection = NSStackView(views: [
            NSButton(title: "Select All", target: self, action: #selector(selectAll(_:))),
            NSButton(title: "Select None", target: self, action: #selector(selectNone(_:))),
            NSButton(title: "Defaults", target: self, action: #selector(selectDefaults(_:))),
        ])
        stack.addArrangedSubview(selection)

        stack.addArrangedSubview(heading("Display"))
        stack.addArrangedSubview(settingsGrid())

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "OK", target: self, action: #selector(save(_:)))
        ok.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, ok])
        stack.addArrangedSubview(buttons)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            // The leading alignment does not keep the trailing margin.
            stack.widthAnchor.constraint(greaterThanOrEqualTo: effects.widthAnchor, constant: 40),
        ])
        window.contentView = content
        window.setContentSize(stack.fittingSize)
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    /// One check box for each effect, in four columns.
    private func effectGrid() -> NSGridView {
        let names = Effects.names
        effectBoxes = names.map { name in
            let box = NSButton(checkboxWithTitle: name, target: nil, action: nil)
            box.state = settings.enabledEffects.contains(name) ? .on : .off
            return box
        }
        let columns = 4
        let rowCount = (names.count + columns - 1) / columns
        var rows: [[NSView]] = []
        for row in 0..<rowCount {
            // The names go down the columns.
            rows.append(
                (0..<columns).map { column in
                    let index = column * rowCount + row
                    return index < effectBoxes.count ? effectBoxes[index] : NSView()
                })
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 4
        grid.columnSpacing = 16
        return grid
    }

    private func settingsGrid() -> NSGridView {
        var families = NSFontManager.shared.availableFontFamilies.filter { family in
            NSFont(name: family, size: 12)?.isFixedPitch ?? false
        }
        if !families.contains(settings.fontName) {
            families.insert(settings.fontName, at: 0)
        }
        fontPopup.addItems(withTitles: families)
        fontPopup.selectItem(withTitle: settings.fontName)

        fill(sizePopup, Settings.fontSizes, selected: settings.fontSize) { "\(Int($0)) pt" }
        fill(ratePopup, Settings.frameRates.map(Double.init), selected: Double(settings.frameRate)) {
            "\(Int($0)) frames per second"
        }
        fill(holdPopup, Settings.holdTimes, selected: settings.holdTime) { "\(Int($0)) s" }

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Font:"), fontPopup],
            [NSTextField(labelWithString: "Font size:"), sizePopup],
            [NSTextField(labelWithString: "Speed:"), ratePopup],
            [NSTextField(labelWithString: "Time between effects:"), holdPopup],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        return grid
    }

    /// Fills a popup with `values`. Each item keeps its value in `tag`
    /// (multiplied by 100). A stored value that is not in the list is added.
    private func fill(
        _ popup: NSPopUpButton, _ values: [Double], selected: Double, title: (Double) -> String
    ) {
        var values = values
        if !values.contains(selected) {
            values.append(selected)
            values.sort()
        }
        for value in values {
            popup.addItem(withTitle: title(value))
            popup.lastItem?.tag = Int((value * 100).rounded())
        }
        popup.selectItem(withTag: Int((selected * 100).rounded()))
    }

    private func value(of popup: NSPopUpButton) -> Double {
        Double(popup.selectedTag()) / 100
    }

    // ------------------------------------------------------------- actions

    @objc private func selectAll(_ sender: Any?) {
        effectBoxes.forEach { $0.state = .on }
    }

    @objc private func selectNone(_ sender: Any?) {
        effectBoxes.forEach { $0.state = .off }
    }

    @objc private func selectDefaults(_ sender: Any?) {
        effectBoxes.forEach { $0.state = Settings.defaultEffects.contains($0.title) ? .on : .off }
    }

    @objc private func cancel(_ sender: Any?) {
        close()
    }

    @objc private func save(_ sender: Any?) {
        settings.enabledEffects = Set(effectBoxes.filter { $0.state == .on }.map(\.title))
        if let font = fontPopup.titleOfSelectedItem {
            settings.fontName = font
        }
        settings.fontSize = value(of: sizePopup)
        settings.frameRate = Int(value(of: ratePopup))
        settings.holdTime = value(of: holdPopup)
        settings.save()
        onSave()
        close()
    }

    private func close() {
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }
}
