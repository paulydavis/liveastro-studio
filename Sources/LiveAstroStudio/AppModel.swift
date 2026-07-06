import SwiftUI
import LiveAstroCore

@Observable
@MainActor
final class AppModel {
    // Session profile draft (bound to the control form)
    var targetName = ""
    var telescope = ""
    var camera = ""
    var mount = ""
    var filter = ""
    var locationLabel = ""
    var bortleText = ""
    var subExposureText = "60"
    var notes = ""

    var watchFolder: URL?
    var isRunning = false
    var latestImage: CGImage?
    var latestRecord: SnapshotRecord?
    var sessionStart: Date?
    var sessionEnd: Date?
    var log: [String] = []
    var replayURL: URL?
    var isGeneratingReplay = false
    var errorMessage: String?

    private var pipeline: SessionPipeline?

    var profile: SessionProfile {
        SessionProfile(targetName: targetName, telescope: telescope, camera: camera,
                       mount: mount, filter: filter, locationLabel: locationLabel,
                       bortle: Int(bortleText), subExposureSeconds: Double(subExposureText) ?? 60,
                       notes: notes)
    }

    var integrationCaption: String {
        guard let rec = latestRecord else { return "waiting for first stack…" }
        return IntegrationFormat.caption(seconds: rec.estimatedIntegrationSeconds,
                                         frames: rec.index,
                                         subSeconds: profile.subExposureSeconds)
    }

    func startSession() {
        guard !isRunning else { return }
        guard let folder = watchFolder else { errorMessage = "Pick a watch folder first."; return }
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveAstro", isDirectory: true)
        let p = SessionPipeline(watchFolder: folder, profile: profile, rootDirectory: root)
        p.onUpdate = { [weak self] image, record in
            Task { @MainActor in
                self?.latestImage = image
                self?.latestRecord = record
                self?.log.append("✓ update \(record.index) — \(record.snapshotFile)")
            }
        }
        p.onLog = { [weak self] message in
            Task { @MainActor in self?.log.append("⚠ \(message)") }
        }
        do {
            try p.start()
            pipeline = p
            isRunning = true
            sessionStart = Date()
            sessionEnd = nil
            replayURL = nil
            log.append("Session started — watching \(folder.path)")
        } catch {
            errorMessage = "Start failed: \(error.localizedDescription)"
        }
    }

    func endSession() {
        guard let p = pipeline else { return }
        isGeneratingReplay = true
        log.append("Ending session — generating replay…")
        Task.detached { [weak self] in
            do {
                let url = try p.end()
                await MainActor.run {
                    self?.replayURL = url
                    self?.log.append("Replay ready: \(url.lastPathComponent)")
                }
            } catch {
                await MainActor.run { self?.errorMessage = "Replay failed: \(error)" }
            }
            await MainActor.run {
                self?.isRunning = false
                self?.isGeneratingReplay = false
                self?.pipeline = nil
                self?.sessionEnd = Date()
            }
        }
    }
}
