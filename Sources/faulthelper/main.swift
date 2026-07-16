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
//   manifest-midwrite <root> <flag>  begin a session, pre-seed a LARGE (multi-MB) manifest, do a
//                                     few NORMAL staged-atomic manifest writes (proving writes were
//                                     flowing), then on the CHALLENGED write: stage the full new
//                                     manifest bytes to a same-dir `.staged-<pid>` temp, touch the
//                                     flag, and BLOCK FOREVER — never publish. The builder's SIGKILL
//                                     thus lands DETERMINISTICALLY between staging and publication:
//                                     the staged temp holds the complete, closed, unpublished new
//                                     version; the previously published manifest is intact. The
//                                     aftermath is fully assertable (exact published count, exact
//                                     staged count), not a first-appearance race property.
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
        let preSeedCount = 120
        for idx in 0..<preSeedCount { try mgr.recordSnapshot(fatRecord(idx)) }
        // Review4 P2 (supersedes the review2/review3 loop): the kill must land DETERMINISTICALLY
        // inside the open write transaction, not merely "first appear" there. The previous impl
        // touched the flag between stage and publish but then LOOPED — by the time the builder's
        // polled SIGKILL (20 ms granularity) landed, the helper had completed many more full cycles,
        // so the kill actually landed at a RANDOM loop phase (possibly the re-encode gap between
        // writes). "Inside an open transaction" was a property of where the flag FIRST appeared,
        // not of where the kill LANDED.
        //
        // FIX — block at the pre-publish point. A few NORMAL seam writes run first (full
        // stage→publish cycles, proving manifest writes were flowing through the seam — not an idle
        // pre-seeded manifest). Then the CHALLENGED write:
        //   (a) stages the full new manifest bytes to `<manifest>.staged-<pid>` (same dir),
        //   (b) touches the flag — the staged temp is complete, closed, and unpublished,
        //   (c) BLOCKS FOREVER — publication (rename) never happens; SIGKILL is the only way out.
        // The kill therefore always lands between staging and publication of the challenged write,
        // and the aftermath is exactly assertable: published manifest == the last pre-challenge
        // version (preSeedCount + normalSeamWrites records), and the `.staged-<pid>` temp parses as
        // the full challenged version (one more record). This is a process-crash test, not a
        // power-loss test — no durability (fsync) claim is made about the staged bytes.
        //
        // WHY A SEAM AT ALL: a block-point cannot be interposed inside production `Data(.atomic)`.
        // The injected writer performs byte-identical staging steps (same-dir temp + rename(2), the
        // same sequence Data(.atomic) performs); the production path's crash-atomicity is separately
        // covered by the APFS in-place cells. Production leaves the seam nil (identical atomic write).
        //
        // NOTE: these constants are mirrored in the test
        // (testCrash_manifestMidwrite_killBetweenStageAndPublish_priorVersionIntact):
        // published = preSeedCount + normalSeamWrites = 123, staged = 124.
        let normalSeamWrites = 3
        var seamWrites = 0
        mgr.manifestWriter = { data, url in
            let staged = url.path + ".staged-\(getpid())"
            try data.write(to: URL(fileURLWithPath: staged))   // (a) stage the full bytes, same dir
            seamWrites += 1
            if seamWrites <= normalSeamWrites {
                // Normal pre-challenge write: publish atomically, exactly like Data(.atomic).
                guard rename(staged, url.path) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                                  userInfo: [NSLocalizedDescriptionKey: "rename(\(staged)) failed"])
                }
            } else {
                touchFlag(flag)   // (b) transaction open: staged (complete, closed), unpublished
                blockForever()    // (c) never publish — the SIGKILL lands right here
            }
        }
        // normalSeamWrites full cycles prove writes are flowing; the next write blocks pre-publish.
        for i in preSeedCount...(preSeedCount + normalSeamWrites) {
            try mgr.recordSnapshot(fatRecord(i))
        }
        fatalError("unreachable: the challenged write blocks forever")

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
