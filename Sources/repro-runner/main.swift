import Foundation
import CoreGraphics
import LiveAstroCore

// Headless native-stacking session for the live-watcher stall repro. Drives the SAME LiveAstroCore
// pipeline the GUI app uses (FolderFrameSource(.live) → StackEngine → SessionPipeline), so the
// watcher/pipeline stall reproduces identically — but unattended, logging every onLog line (including
// the "watcher alive: …" heartbeat) and a snapshot tally to stdout. Pair with Scripts/drip_subs.sh.
//
// Usage: repro-runner <watch-folder> <session-root> <duration-sec> [prefix=Light_]

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: repro-runner <watch-folder> <session-root> <duration-sec> [prefix]\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: args[1], isDirectory: true)
let root = URL(fileURLWithPath: args[2], isDirectory: true)
let duration = Double(args[3]) ?? 10800
let prefix = args.count > 4 ? args[4] : "Light_"

let fmt = DateFormatter()
fmt.dateFormat = "HH:mm:ss"
let outLock = NSLock()
func stamp(_ s: String) {
    outLock.lock(); print("\(fmt.string(from: Date()))  \(s)"); fflush(stdout); outLock.unlock()
}

let source = FolderFrameSource(folder: folder, mode: .live,
                               fileNamePrefix: prefix.isEmpty ? nil : prefix)
let engine = StackEngine()
let profile = SessionProfile(targetName: "watcher-stall-repro", subExposureSeconds: 10)
let pipeline = SessionPipeline(nativeSource: source, engine: engine, profile: profile, rootDirectory: root)

let snapLock = NSLock()
var snapshots = 0
pipeline.onLog = { stamp($0) }
pipeline.onUpdate = { _, _ in
    snapLock.lock(); snapshots += 1; let n = snapshots; snapLock.unlock()
    if n % 25 == 0 { stamp("── \(n) snapshots committed ──") }
}

do {
    try pipeline.start()
} catch {
    stamp("start FAILED: \(error)")
    exit(1)
}
stamp("repro-runner started — watching \(folder.path), prefix '\(prefix)', session root \(root.path), for \(Int(duration))s")

// End after the duration on a background queue (never from inside a callback → no reentrant end).
DispatchQueue.global().asyncAfter(deadline: .now() + duration) {
    snapLock.lock(); let n = snapshots; snapLock.unlock()
    stamp("duration reached — ending (\(n) snapshots)")
    if let out = try? pipeline.end() { stamp("session written: \(out.path)") }
    stamp("repro-runner done — \(n) snapshots total")
    exit(0)
}

// Keep the process alive; the watcher queue + consumer task run independently. The timer's exit() ends it.
DispatchSemaphore(value: 0).wait()
