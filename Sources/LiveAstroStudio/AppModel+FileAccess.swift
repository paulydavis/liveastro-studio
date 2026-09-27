import Foundation
import AppKit
import LiveAstroCore

/// One captured operation, shared with workers and the post-session context.
/// Replacing a selection changes future operations only.
struct OperationFileAccess: Sendable {
    let input: URL
    let output: URL
    let darkPath: String?
    let flatPath: String?
    let biasPath: String?
    var calibration: CalibrationSelection { CalibrationSelection(darkPath: darkPath, flatPath: flatPath, biasPath: biasPath) }
    let flats: URL?
    let darkFlats: URL?
    let leases: [FileAccessLease]

    func relayed(to input: URL) -> OperationFileAccess {
        OperationFileAccess(input: input, output: output, darkPath: darkPath, flatPath: flatPath,
                            biasPath: biasPath, flats: flats, darkFlats: darkFlats, leases: leases)
    }
}

extension AppModel {
    var isStorePreview: Bool { distribution.isStorePreview }

    @discardableResult
    func selectLocation(_ url: URL, key: String) -> Bool {
        do {
            let lease = try authorizedLocations.select(url, key: key)
            if key == "output" { selectedOutputFolder = lease.url }
            if key == "capture" { watchFolder = lease.url }
            return true
        } catch { reportFileAccess(error); return false }
    }

    func chooseSessionOutputFolder() {
        let panel = makeDirectoryPanel(title: "Save sessions to", message: "Choose where LiveAstro Store Preview saves session output.")
        if panel.runModal() == .OK, let url = panel.url { selectLocation(url, key: "output") }
    }

    func selectSourceFolder(_ url: URL) -> URL? {
        do { return try authorizedLocations.select(url, key: "source:" + url.standardizedFileURL.absoluteString).url }
        catch { reportFileAccess(error); return nil }
    }

    func reportFileAccess(_ error: Error) {
        errorMessage = "Folder access failed: \(error.localizedDescription) Reconnect the location or choose the folder again."
    }

    func setCalibrationFolder(_ url: URL?, darkFlats: Bool) {
        let selected: URL?
        if let url {
            guard let resolved = selectSourceFolder(url) else { return }
            selected = resolved
        } else { selected = nil }
        if darkFlats { sessionDarkFlatsFolder = selected } else { sessionFlatsFolder = selected }
        if isStorePreview { userDefaults.set(selected?.path, forKey: darkFlats ? "StorePreview.darkFlatsPath" : "StorePreview.flatsPath") }
    }

    func acquireReadableLocation(_ url: URL) throws -> FileAccessLease {
        let lease = try authorizedLocations.acquire(url: url)
        if isStorePreview {
            let values = try lease.url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
            if values.isDirectory == true {
                _ = try FileManager.default.contentsOfDirectory(at: lease.url, includingPropertiesForKeys: nil)
            } else {
                let handle = try FileHandle(forReadingFrom: lease.url)
                try handle.close()
            }
        }
        return lease
    }

    func acquireOutputLocation() throws -> FileAccessLease {
        guard isStorePreview else { return FileAccessLease(url: liveAstroRoot) }
        let lease = try authorizedLocations.acquire(key: "output")
        let values = try lease.url.resourceValues(forKeys: [.isDirectoryKey, .isWritableKey])
        guard values.isDirectory == true, values.isWritable == true else {
            throw CocoaError(.fileWriteNoPermission)
        }
        selectedOutputFolder = lease.url
        return lease
    }

    func acquireOperationAccess(input: URL) throws -> OperationFileAccess {
        // The required output is checked before any capture/calibration enumeration.
        let output = try acquireOutputLocation()
        let source = try acquireReadableLocation(input)
        var leases = [output, source]
        func resolve(_ url: URL?) throws -> URL? {
            guard let url else { return nil }
            let lease = try acquireReadableLocation(url)
            leases.append(lease)
            return lease.url
        }
        var selected = calibration
        selected.darkPath = try resolve(calibration.darkPath.map { URL(fileURLWithPath: $0) })?.path
        selected.flatPath = try resolve(calibration.flatPath.map { URL(fileURLWithPath: $0) })?.path
        selected.biasPath = try resolve(calibration.biasPath.map { URL(fileURLWithPath: $0) })?.path
        let flats = try resolve(sessionFlatsFolder), darkFlats = try resolve(sessionDarkFlatsFolder)
        return OperationFileAccess(input: source.url, output: output.url, darkPath: selected.darkPath, flatPath: selected.flatPath, biasPath: selected.biasPath,
                                   flats: flats, darkFlats: darkFlats, leases: leases)
    }

    func restoreAuthorizedSelections() {
        guard isStorePreview else { return }
        selectedOutputFolder = authorizedLocations.displayURL(key: "output")
        if selectedOutputFolder != nil {
            do { selectedOutputFolder = try acquireOutputLocation().url }
            catch { reportFileAccess(error) }
        }
        for dark in [false, true] {
            guard let path = userDefaults.string(forKey: dark ? "StorePreview.darkFlatsPath" : "StorePreview.flatsPath") else { continue }
            let displayed = URL(fileURLWithPath: path)
            if dark { sessionDarkFlatsFolder = displayed } else { sessionFlatsFolder = displayed }
            do {
                let resolved = try acquireReadableLocation(displayed).url
                if dark { sessionDarkFlatsFolder = resolved } else { sessionFlatsFolder = resolved }
                userDefaults.set(resolved.path, forKey: dark ? "StorePreview.darkFlatsPath" : "StorePreview.flatsPath")
            } catch { reportFileAccess(error) }
        }
        if let displayed = authorizedLocations.displayURL(key: "capture") { watchFolder = displayed }
        if let folder = watchFolder {
            do { watchFolder = try acquireReadableLocation(folder).url }
            catch { reportFileAccess(error) }
        }
        func restorePath(_ path: String?) -> String? {
            guard let path else { return nil }
            do {
                return try acquireReadableLocation(URL(fileURLWithPath: path)).url.path
            } catch { reportFileAccess(error); return path }
        }
        let previousCalibration = calibration
        calibration.darkPath = restorePath(calibration.darkPath)
        calibration.flatPath = restorePath(calibration.flatPath)
        calibration.biasPath = restorePath(calibration.biasPath)
        if calibration != previousCalibration {
            var settings = SessionSettingsStore.load(userDefaults)
            settings.calibration = calibration
            SessionSettingsStore.save(settings, to: userDefaults)
            CalibrationStore.save(calibration, to: userDefaults)
        }
    }
}
