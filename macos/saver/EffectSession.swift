import Foundation

/// The effects that the Rust core can run.
enum Effects {
    static let names: [String] = (0..<ttfx_saver_effect_count()).compactMap { index in
        ttfx_saver_effect_name(index).map { String(cString: $0) }
    }
}

/// One effect run in the Rust core.
final class EffectSession {
    let cols: Int
    let rows: Int
    private let pointer: OpaquePointer

    /// Returns nil if the core cannot start the effect.
    init?(text: Data, effect: String, cols: Int, rows: Int, seed: UInt64) {
        guard cols > 0, rows > 0, !text.isEmpty else { return nil }
        let pointer = text.withUnsafeBytes { bytes in
            ttfx_saver_new(
                bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, effect,
                Int32(clamping: cols), Int32(clamping: rows), seed)
        }
        guard let pointer else { return nil }
        self.pointer = pointer
        self.cols = cols
        self.rows = rows
    }

    deinit {
        ttfx_saver_free(pointer)
    }

    /// Makes the next frame. 1 = frame ready, 0 = effect complete, -1 = error.
    func step() -> Int32 {
        ttfx_saver_step(pointer)
    }

    /// The last frame: `cols * rows` cells, top row first.
    var cells: UnsafeBufferPointer<TtfxCell> {
        UnsafeBufferPointer(start: ttfx_saver_cells(pointer), count: cols * rows)
    }
}
