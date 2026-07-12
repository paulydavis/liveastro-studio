import Foundation

/// Applies master dark/flat calibration to a raw CFA frame before debayer.
/// Masters are canonical top-down; a bottom-up light gets a vertically flipped
/// master so photosites align. Never throws — a size-mismatched master is
/// skipped and logged so calibration can never break the session.
public final class Calibrator {
    private let dark: AstroImage?
    private let flat: AstroImage?
    public var onLog: ((String) -> Void)?

    // Masters aligned to the current light orientation, cached: every frame in a
    // session shares `bottomUp`, so alignment is computed at most once.
    // `alignedForBottomUp == nil` means "not yet aligned".
    private var alignedDark: AstroImage?
    private var alignedFlat: AstroImage?
    private var alignedForBottomUp: Bool?
    private var loggedDarkMismatch = false
    private var loggedFlatMismatch = false
    /// Serializes the alignment/logging prefix of apply() — it is called
    /// concurrently by the import worker pool (see apply()).
    private let lock = NSLock()

    public init(dark: AstroImage?, flat: AstroImage?) {
        self.dark = dark
        self.flat = flat
    }

    public func apply(_ frame: RawFrame) -> RawFrame {
        guard dark != nil || flat != nil else { return frame }

        let light = frame.image
        let n = light.pixels.count

        // Alignment computation + mismatch-logging mutate shared state, and apply()
        // is called concurrently by the import worker pool (BatchImporter). Serialize
        // just that prefix under the lock; the per-pixel calibration below runs on the
        // captured `d`/`f` locals, so it stays lock-free / parallel.
        let d: AstroImage?
        let f: AstroImage?
        lock.lock()
        computeAlignment(for: frame.bottomUp)
        d = usable(alignedDark, light: light, kind: "dark", logged: &loggedDarkMismatch)
        f = usable(alignedFlat, light: light, kind: "flat", logged: &loggedFlatMismatch)
        lock.unlock()

        if d == nil && f == nil { return frame }

        var out = [Float](repeating: 0, count: n)
        light.pixels.withUnsafeBufferPointer { L in
            for i in 0..<n {
                var v = L[i]
                if let d { v -= d.pixels[i] }
                if let f {
                    let denom = max(f.pixels[i], MasterBuilder.flatFloor)
                    v /= denom
                }
                out[i] = v.isFinite ? min(max(v, 0), 1) : 0
            }
        }
        let image = AstroImage(width: light.width, height: light.height,
                               channels: light.channels, pixels: out, sourceIsLinear: true)
        return RawFrame(image: image, bayerPattern: frame.bayerPattern, bottomUp: frame.bottomUp,
                        timestamp: frame.timestamp, sourceName: frame.sourceName)
    }

    private func computeAlignment(for bottomUp: Bool) {
        if alignedForBottomUp == bottomUp { return }
        alignedForBottomUp = bottomUp
        alignedDark = dark.map { bottomUp ? Self.verticalFlip($0) : $0 }
        alignedFlat = flat.map { bottomUp ? Self.verticalFlip($0) : $0 }
    }

    /// Return the master if its dimensions match the light; else nil, logging once.
    private func usable(_ master: AstroImage?, light: AstroImage, kind: String,
                        logged: inout Bool) -> AstroImage? {
        guard let master else { return nil }
        guard master.width == light.width, master.height == light.height,
              master.channels == light.channels else {
            if !logged { onLog?("master \(kind) \(master.width)×\(master.height) ≠ light " +
                                "\(light.width)×\(light.height) — skipping \(kind)"); logged = true }
            return nil
        }
        return master
    }

    /// Reverse row order within each channel plane.
    static func verticalFlip(_ img: AstroImage) -> AstroImage {
        let w = img.width, h = img.height, plane = w * h
        var out = [Float](repeating: 0, count: img.pixels.count)
        for c in 0..<img.channels {
            for y in 0..<h {
                let src = c * plane + (h - 1 - y) * w
                let dst = c * plane + y * w
                out.replaceSubrange(dst..<(dst + w), with: img.pixels[src..<(src + w)])
            }
        }
        return AstroImage(width: w, height: h, channels: img.channels,
                          pixels: out, sourceIsLinear: img.sourceIsLinear)
    }
}
