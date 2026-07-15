import Foundation
import CoreGraphics
import LiveAstroCore

// Test-support executable (NOT shipped in the app). CrashArtifactBuilder runs this to a
// coordinated point, then SIGKILLs it so tests get a GENUINE killed-process on-disk aftermath.
//
// Every scenario:  <scenario> <root> <flag>
//   - drives a REAL LiveAstroCore operation (SessionManager / FrameRelay),
//   - touches <flag> at its coordinated point,
//   - blocks forever on a never-signaled semaphore so SIGKILL lands mid-state.
//
// Scenarios:
//   session-midframes <root> <flag>  begin a session, record 3 real snapshots, touch flag, block.
//   manifest-midwrite <root> <flag>  begin a session, loop rewriting the manifest with a growing
//                                     snapshot list; touch flag after the FIRST write, then block.
//   relay-midcopy <src> <dst> <flag> start a FrameRelay against a large source, touch flag after
//                                     the first tick begins, then block. (Here <root>==<src>; the
//                                     builder passes a single aftermath root, so dst is derived.)

func touchFlag(_ path: String) {
    FileManager.default.createFile(atPath: path, contents: Data("ready".utf8))
}

/// Block forever on a semaphore that is never signaled — SIGKILL is the only way out.
func blockForever() -> Never {
    let never = DispatchSemaphore(value: 0)
    never.wait()
    fatalError("unreachable: never signaled")
}

/// A tiny real CGImage + linear AstroImage so SnapshotRecorder writes a genuine PNG.
func makeSnapshotInputs() -> (CGImage, AstroImage) {
    let w = 8, h = 8
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 0.5, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let cg = ctx.makeImage()!
    let pixels = [Float](repeating: 0.5, count: w * h)   // single channel, linear
    let linear = AstroImage(width: w, height: h, channels: 1, pixels: pixels, sourceIsLinear: true)
    return (cg, linear)
}

func profile() -> SessionProfile {
    SessionProfile(targetName: "Crash Test", telescope: "T", camera: "C", mount: "M",
                   filter: "F", locationLabel: "L", bortle: 5, subExposureSeconds: 60, notes: "")
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: faulthelper <scenario> <root> <flag>\n".utf8))
    exit(2)
}
let scenario = args[1]
let root = URL(fileURLWithPath: args[2], isDirectory: true)
let flag = args[3]

do {
    switch scenario {
    case "session-midframes":
        let mgr = SessionManager(rootDirectory: root)
        let dir = try mgr.startSession(profile: profile())
        let recorder = SnapshotRecorder(sessionDirectory: dir)
        let (cg, linear) = makeSnapshotInputs()
        for i in 0..<3 {
            let rec = try recorder.save(cgImage: cg, linear: linear, sourceFile: "live_stack.fit",
                                        index: i, timestamp: Date(), estimatedIntegrationSeconds: 60)
            try mgr.recordSnapshot(rec)
        }
        touchFlag(flag)          // 3 snapshots durable; session still running
        blockForever()

    case "manifest-midwrite":
        let mgr = SessionManager(rootDirectory: root)
        let dir = try mgr.startSession(profile: profile())
        let recorder = SnapshotRecorder(sessionDirectory: dir)
        let (cg, linear) = makeSnapshotInputs()
        var i = 0
        // Loop rewriting the manifest with a growing snapshot list; flag after the first write.
        while true {
            let rec = try recorder.save(cgImage: cg, linear: linear, sourceFile: "live_stack.fit",
                                        index: i, timestamp: Date(), estimatedIntegrationSeconds: 60)
            try mgr.recordSnapshot(rec)
            if i == 0 { touchFlag(flag) }   // first write landed → coordinated point
            i += 1
            if i == 1 { blockForever() }    // block after the first write so SIGKILL is deterministic
        }

    case "relay-midcopy":
        // Single-root form: derive src/dst subdirs so the builder can pass one aftermath root.
        let src = root.appendingPathComponent("src", isDirectory: true)
        let dst = root.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        // A large source file so the copy is genuinely mid-flight when we block.
        let big = src.appendingPathComponent("Light_0001_10.0s_0001.fit")
        FileManager.default.createFile(atPath: big.path,
                                       contents: Data(count: 64 * 1024 * 1024))   // 64 MiB
        let relay = FrameRelay(source: src, destination: dst, pollSeconds: 0.05,
                               sessionScoped: false, stabilityInterval: 0.01)
        var flagged = false
        relay.onLog = { (_: String) in
            if !flagged { flagged = true; touchFlag(flag) }   // first tick began
        }
        try relay.start()
        blockForever()

    default:
        FileHandle.standardError.write(Data("unknown scenario: \(scenario)\n".utf8))
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("faulthelper error: \(error)\n".utf8))
    exit(1)
}
