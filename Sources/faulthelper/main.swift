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
//   manifest-midwrite <root> <flag>  begin a session, pre-seed a LARGE (multi-MB) manifest, then
//                                     LOOP FOREVER rewriting it via an explicit staged atomic write
//                                     (stage temp file in same dir → touch flag → rename to publish;
//                                     tight loop, no sleeps, never blocks). The flag first appears
//                                     only AFTER staged bytes are on disk with publication pending,
//                                     so the builder's SIGKILL opens strictly inside an open write
//                                     transaction. Guarantee under test: any kill point leaves a
//                                     COMPLETE published manifest version (never a torn file).
//   relay-midcopy <src> <dst> <flag> start a FrameRelay against a large source; the pre-approved
//                                     onPrePublish sync hook touches the flag then blocks forever, so
//                                     the SIGKILL lands GENUINELY between the staged copy and the
//                                     atomic publish — .relaytmp present, no glob-visible dest.
//                                     (Here <root>==<src>; the builder passes a single aftermath
//                                     root, so dst is derived.)

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
        // Build a record that serializes to a LARGE JSON payload (a fat `sourceFile` string) so each
        // manifest write moves multiple MB — this widens the tear window enough that a NON-atomic
        // write is observably caught mid-write, while keeping the pre-seed fast (few records, so no
        // quadratic build cost). All records reference the SAME real on-disk PNG (index 0), so clauses
        // 2 & 4 (exists + decodable) hold for every listed entry.
        let seedRec = try recorder.save(cgImage: cg, linear: linear, sourceFile: "live_stack.fit",
                                        index: 0, timestamp: Date(), estimatedIntegrationSeconds: 60)
        let fatSource = String(repeating: "x", count: 40_000)   // ~40 KB per record
        func fatRecord(_ idx: Int) -> SnapshotRecord {
            SnapshotRecord(index: idx, timestamp: Date(), sourceFile: fatSource,
                           snapshotFile: seedRec.snapshotFile,
                           estimatedIntegrationSeconds: seedRec.estimatedIntegrationSeconds,
                           width: seedRec.width, height: seedRec.height,
                           mean: seedRec.mean, median: seedRec.median, stddev: seedRec.stddev)
        }
        // Pre-seed 120 fat records → ~5 MB manifest. Only 120 (fast) intermediate writes.
        // The seam is NOT installed yet, so these use the default atomic write path.
        for idx in 0..<120 { try mgr.recordSnapshot(fatRecord(idx)) }
        // F3 (review2) + review3 P2: the readiness flag must be touched from INSIDE an open write
        // transaction. The previous seam impl did `touchFlag(); data.write(.atomic)` — but the flag
        // preceded the write() call, so the builder's SIGKILL (which fires as soon as it sees the
        // flag) could land while this process was preempted BETWEEN touchFlag and write(), i.e. with
        // no write in flight at all — the "provably overlaps an in-flight write" claim was overstated.
        // FIX: an EXPLICIT staged atomic write mirroring what Data(.atomic) does (temp file in the
        // same directory + rename(2) to publish), with the flag set only AFTER staging has begun:
        //   (a) write the full new manifest bytes to `<manifest>.staged-<pid>` (same dir),
        //   (b) touchFlag — staged bytes durable, publication (rename) still pending,
        //   (c) rename(staged, manifest) — the single atomic publish.
        //
        // GUARANTEED: the flag first appears only while staged-but-unpublished bytes exist on disk,
        // so the earliest instant the builder can kill is strictly inside an open write transaction —
        // the kill can never land before a challenged write has begun (no vacuous pass on the idle
        // pre-seeded manifest), and every later iteration re-enters that transaction (stage→publish).
        // NOT guaranteed: WHICH complete version survives (the previously published one, the newly
        // published one, or a leftover unpublished `.staged-*` temp alongside a published version),
        // nor the exact phase of a later cycle the kill lands in (staging, publish, or the brief
        // re-encode between cycles). What the cell asserts is exactly what IS guaranteed: the
        // PUBLISHED manifest.json is at every instant SOME complete version — it only ever changes
        // via an atomic rename of fully staged bytes. A leftover `.staged-<pid>` temp after SIGKILL
        // is the same aftermath a killed Data(.atomic) write can leave: never published, never read.
        mgr.manifestWriter = { data, url in
            let staged = url.path + ".staged-\(getpid())"
            try data.write(to: URL(fileURLWithPath: staged))   // (a) stage the full bytes, same dir
            touchFlag(flag)                                    // (b) transaction open: staged, unpublished
            guard rename(staged, url.path) == 0 else {         // (c) atomic publish
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSLocalizedDescriptionKey: "rename(\(staged)) failed"])
            }
        }
        var i = 120
        // Loop FOREVER rewriting the ~5 MB manifest — a tight loop with no sleeps, no blocking, and
        // no per-iteration PNG encode, so the big staged write + publish DOMINATES the loop. Whatever
        // instant the kill lands, the published manifest on disk is SOME complete version, never a
        // torn/half-serialized file. (The test asserts only that it parses.)
        while true {
            try mgr.recordSnapshot(fatRecord(i))
            i += 1
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
        // Pre-approved sync hook (FIRST JUSTIFIED USE): the relay copies src → staged `.relaytmp`,
        // re-stats to verify the copy is faithful, then calls onPrePublish RIGHT BEFORE the atomic
        // rename. Here we touch the flag (so the builder SIGKILLs us) and block forever — the kill
        // therefore lands GENUINELY between staged-copy and publish: `.relaytmp` is on disk, no
        // glob-visible destination file exists yet.
        relay.onPrePublish = { touchFlag(flag); blockForever() }
        try relay.start()
        blockForever()   // unreachable once a file relays, but keeps main alive until then

    default:
        FileHandle.standardError.write(Data("unknown scenario: \(scenario)\n".utf8))
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("faulthelper error: \(error)\n".utf8))
    exit(1)
}
