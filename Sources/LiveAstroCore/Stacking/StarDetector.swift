import Foundation

public struct Star: Equatable {
    public let x: Double
    public let y: Double
    public let flux: Double
}

/// Threshold + connected-component star finder with grid-interpolated background
/// (spec §4.2). Deterministic, no randomness.
public enum StarDetector {
    public static func detect(luminance: [Float], width: Int, height: Int,
                              maxStars: Int = 60, sigmaThreshold: Double = 5.0) -> [Star] {
        precondition(luminance.count == width * height)
        guard width >= 1, height >= 1 else { return [] }
        // Star blobs (5-10 px) ≪ cell, so each cell's median stays an unbiased sky estimate.
        let cell = 32
        let gw = max(1, (width + cell - 1) / cell), gh = max(1, (height + cell - 1) / cell)
        var bgGrid = [Float](repeating: 0, count: gw * gh)
        var sigGrid = [Float](repeating: 0, count: gw * gh)
        for gy in 0..<gh {
            for gx in 0..<gw {
                var vals: [Float] = []
                vals.reserveCapacity(cell * cell)
                for y in (gy * cell)..<min((gy + 1) * cell, height) {
                    for x in (gx * cell)..<min((gx + 1) * cell, width) {
                        vals.append(luminance[y * width + x])
                    }
                }
                guard !vals.isEmpty else {
                    // Degenerate cell (zero-area input region): flat background, sigma floor.
                    bgGrid[gy * gw + gx] = 0
                    sigGrid[gy * gw + gx] = 1e-6
                    continue
                }
                vals.sort()
                let med = vals[vals.count / 2]
                var dev = vals.map { abs($0 - med) }
                dev.sort()
                bgGrid[gy * gw + gx] = med
                // 1.4826 = 1 / Φ⁻¹(0.75): MAD→σ consistency factor for Gaussian data
                sigGrid[gy * gw + gx] = max(1.4826 * dev[dev.count / 2], 1e-6)
            }
        }
        // Bilinear grid interpolation at pixel (x, y): grid coords in cell-center space.
        func gridAt(_ grid: [Float], _ x: Int, _ y: Int) -> Float {
            let fx = (Float(x) - Float(cell) / 2) / Float(cell)
            let fy = (Float(y) - Float(cell) / 2) / Float(cell)
            let x0 = min(max(Int(floor(fx)), 0), gw - 1), y0 = min(max(Int(floor(fy)), 0), gh - 1)
            let x1 = min(x0 + 1, gw - 1), y1 = min(y0 + 1, gh - 1)
            let tx = min(max(fx - Float(x0), 0), 1), ty = min(max(fy - Float(y0), 0), 1)
            let a = grid[y0 * gw + x0] * (1 - tx) + grid[y0 * gw + x1] * tx
            let b = grid[y1 * gw + x0] * (1 - tx) + grid[y1 * gw + x1] * tx
            return a * (1 - ty) + b * ty
        }

        var mask = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                mask[i] = Double(luminance[i]) >
                    Double(gridAt(bgGrid, x, y)) + sigmaThreshold * Double(gridAt(sigGrid, x, y))
            }
        }

        var visited = [Bool](repeating: false, count: width * height)
        var stars: [Star] = []
        // minArea 3 excludes hot pixels and 2-px noise (too small to centroid);
        // maxArea 400 rejects smeared cosmic rays, nebula patches, and dust donuts.
        let minArea = 3, maxArea = 400
        for start in 0..<mask.count where mask[start] && !visited[start] {
            var stack = [start]
            visited[start] = true
            var member: [Int] = []
            while let i = stack.popLast() {
                member.append(i)
                let x = i % width, y = i / width
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let n = ny * width + nx
                    if mask[n] && !visited[n] { visited[n] = true; stack.append(n) }
                }
            }
            guard member.count >= minArea, member.count <= maxArea else { continue }
            var flux = 0.0, cx = 0.0, cy = 0.0
            for i in member {
                let x = i % width, y = i / width
                let f = Double(luminance[i] - gridAt(bgGrid, x, y))
                guard f > 0 else { continue }
                flux += f; cx += f * Double(x); cy += f * Double(y)
            }
            guard flux > 0 else { continue }
            stars.append(Star(x: cx / flux, y: cy / flux, flux: flux))
        }
        stars.sort { $0.flux > $1.flux }
        return Array(stars.prefix(maxStars))
    }
}
