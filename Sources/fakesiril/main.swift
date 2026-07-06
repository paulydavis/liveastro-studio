import Foundation
import LiveAstroCore

// Simulates Siril livestacking: rewrites live_stack.fit in place with growing SNR,
// including a partial-write phase to exercise the watcher's completeness check.
// Usage: swift run fakesiril <folder> [--interval seconds] [--count n]

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: fakesiril <folder> [--interval 5] [--count 40]")
    exit(1)
}
let folder = URL(fileURLWithPath: args[1], isDirectory: true)
func option(_ name: String, default value: Double) -> Double {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Double(args[i + 1]) else { return value }
    return v
}
let interval = option("--interval", default: 5)
let count = Int(option("--count", default: 40))

try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let url = folder.appendingPathComponent("live_stack.fit")
let width = 800, height = 500

// Fixed synthetic starfield (seeded LCG so every run looks the same).
var seed: UInt64 = 0x5EED
func rand() -> Double {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Double(seed >> 33) / Double(UInt32.max)
}
let stars: [(x: Int, y: Int, brightness: Double)] = (0..<120).map { _ in
    (Int(rand() * Double(width)), Int(rand() * Double(height)), 0.3 + rand() * 0.7)
}

for k in 1...count {
    // Signal grows linearly with k; noise stddev shrinks like 1/sqrt(k). Classic stacking behavior.
    let noiseScale = 0.08 / Double(k).squareRoot()
    var px = [Float](repeating: 0, count: width * height)
    for i in 0..<px.count {
        px[i] = Float(max(0, 0.02 + (rand() - 0.5) * 2 * noiseScale))
    }
    for s in stars {
        let signal = Float(min(1, s.brightness * (0.3 + 0.7 * Double(k) / Double(count))))
        for dy in -2...2 {
            for dx in -2...2 {
                let x = s.x + dx, y = s.y + dy
                guard x >= 0, x < width, y >= 0, y < height else { continue }
                let falloff = Float(1) / Float(1 + dx * dx + dy * dy)
                let idx = y * width + x
                px[idx] = min(1, px[idx] + signal * falloff)
            }
        }
    }
    let data = FITSWriter.float32(width: width, height: height, channels: 1, pixels: px)
    try data.prefix(data.count / 2).write(to: url)   // partial write
    Thread.sleep(forTimeInterval: 0.3)
    try data.write(to: url)                          // complete write
    print("fakesiril: stack update \(k)/\(count)")
    if k < count { Thread.sleep(forTimeInterval: interval) }
}
print("fakesiril: done")
