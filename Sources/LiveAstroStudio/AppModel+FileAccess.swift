import Foundation
import AppKit
import LiveAstroCore

/// Synchronous filesystem boundary; callers own scheduling and cancellation.
protocol LocationAvailabilityChecking: Sendable {
    func check(_ url: URL, forWriting: Bool) throws
}

struct FileLocationAvailability: LocationAvailabilityChecking {
    func check(_ url: URL, forWriting: Bool) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isWritableKey])
        if forWriting {
            guard values.isDirectory == true, values.isWritable == true else { throw CocoaError(.fileWriteNoPermission) }
        } else if values.isDirectory == true {
            _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        } else {
            let handle = try FileHandle(forReadingFrom: url)
            try handle.close()
        }
    }
}

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
    let availability: (any LocationAvailabilityChecking)?

    func validateAvailability() throws {
        guard let availability else { return }
        try Task.checkCancellation()
        try availability.check(output, forWriting: true)
        for lease in leases.dropFirst() {
            try Task.checkCancellation()
            try availability.check(lease.url, forWriting: false)
        }
        try Task.checkCancellation()
    }

    func relayed(to input: URL) -> OperationFileAccess {
        OperationFileAccess(input: input, output: output, darkPath: darkPath, flatPath: flatPath,
                            biasPath: biasPath, flats: flats, darkFlats: darkFlats, leases: leases, availability: availability)
    }
}

extension AppModel {
    var isStorePreview: Bool { distribution.isStorePreview }

    @discardableResult
    func selectLocation(_ url: URL, key: String) -> Bool {
        do {
            let lease = try authorizedLocations.select(url, key: key)
            invalidateAccessRestoration()
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
        invalidateAccessRestoration()
        if darkFlats { sessionDarkFlatsFolder = selected } else { sessionFlatsFolder = selected }
        if isStorePreview { userDefaults.set(selected?.path, forKey: darkFlats ? "StorePreview.darkFlatsPath" : "StorePreview.flatsPath") }
    }

    func acquireReadableLocation(_ url: URL) throws -> FileAccessLease {
        try authorizedLocations.acquire(url: url)
    }

    func acquireOutputLocation() throws -> FileAccessLease {
        guard isStorePreview else { return FileAccessLease(url: liveAstroRoot) }
        let lease = try authorizedLocations.acquire(key: "output")
        selectedOutputFolder = lease.url
        return lease
    }

    func acquireOperationAccess(input: URL) throws -> OperationFileAccess {
        if isStorePreview { invalidateAccessRestoration() }
        let results = acquireSelections(input: input, includeOutput: true)
        var locations: [SelectionRole: FileAccessLease] = [:]
        var leases: [FileAccessLease] = []
        // Preserve output-first error precedence. No filesystem work starts unless
        // every required acquisition succeeded; successful renewals are already saved.
        for (role, result) in results {
            let lease = try result.get()
            locations[role] = lease
            leases.append(lease)
        }
        return OperationFileAccess(input: locations[.input]!.url, output: locations[.output]!.url,
                                   darkPath: locations[.dark]?.url.path, flatPath: locations[.flat]?.url.path,
                                   biasPath: locations[.bias]?.url.path, flats: locations[.flats]?.url,
                                   darkFlats: locations[.darkFlats]?.url, leases: leases,
                                   availability: isStorePreview ? locationAvailability : nil)
    }

    private enum SelectionRole: Hashable { case output, input, dark, flat, bias, flats, darkFlats }

    /// One synchronous authorization batch. Current selections change only from
    /// successfully resolved tokens, even when another required location fails.
    private func acquireSelections(input: URL?, includeOutput: Bool) -> [(SelectionRole, Result<FileAccessLease, Error>)] {
        var requests: [(SelectionRole, AuthorizedLocations.Request)] = []
        if includeOutput { requests.append((.output, isStorePreview ? .key("output") : .url(liveAstroRoot))) }
        if let input { requests.append((.input, .url(input))) }
        for (role, path) in [(SelectionRole.dark, calibration.darkPath), (.flat, calibration.flatPath), (.bias, calibration.biasPath)] {
            if let path { requests.append((role, .url(URL(fileURLWithPath: path)))) }
        }
        if let url = sessionFlatsFolder { requests.append((.flats, .url(url))) }
        if let url = sessionDarkFlatsFolder { requests.append((.darkFlats, .url(url))) }
        let results = zip(requests, authorizedLocations.acquireGroup(requests.map(\.1))).map { ($0.0.0, $0.1) }
        guard isStorePreview else { return results }
        for (role, result) in results {
            guard case .success(let lease) = result else { continue }
            switch role {
            case .output: selectedOutputFolder = lease.url
            case .input:
                if watchFolder?.standardizedFileURL.path == input?.standardizedFileURL.path { watchFolder = lease.url }
            case .dark: calibration.darkPath = lease.url.path
            case .flat: calibration.flatPath = lease.url.path
            case .bias: calibration.biasPath = lease.url.path
            case .flats: sessionFlatsFolder = lease.url
            case .darkFlats: sessionDarkFlatsFolder = lease.url
            }
        }
        userDefaults.set(sessionFlatsFolder?.path, forKey: "StorePreview.flatsPath")
        userDefaults.set(sessionDarkFlatsFolder?.path, forKey: "StorePreview.darkFlatsPath")
        CalibrationStore.save(calibration, to: userDefaults)
        saveSettings()
        return results
    }

    func invalidateAccessRestoration() {
        accessRestorationID = nil
        accessRestorationTask?.cancel()
        accessRestorationTask = nil
    }

    func restoreAuthorizedSelections() {
        guard isStorePreview else { return }
        invalidateAccessRestoration()
        var checks: [(FileAccessLease, Bool)] = []
        selectedOutputFolder = authorizedLocations.displayURL(key: "output")
        for dark in [false, true] {
            guard let path = userDefaults.string(forKey: dark ? "StorePreview.darkFlatsPath" : "StorePreview.flatsPath") else { continue }
            let displayed = URL(fileURLWithPath: path)
            if dark { sessionDarkFlatsFolder = displayed } else { sessionFlatsFolder = displayed }
        }
        if let displayed = authorizedLocations.displayURL(key: "capture") { watchFolder = displayed }
        for (role, result) in acquireSelections(input: watchFolder, includeOutput: selectedOutputFolder != nil) {
            switch result {
            case .success(let lease): checks.append((lease, role == .output))
            case .failure(let error): reportFileAccess(error)
            }
        }
        guard !checks.isEmpty else { return }
        let id = UUID()
        accessRestorationID = id
        let checker = locationAvailability
        accessRestorationTask = Task.detached { [weak self, checks] in
            defer { withExtendedLifetime(checks) {} }
            let owner = self
            var failure: Error?
            do {
                for (lease, writing) in checks {
                    try Task.checkCancellation()
                    try checker.check(lease.url, forWriting: writing)
                }
            } catch { failure = error }
            let result = failure
            await MainActor.run {
                guard let self = owner, self.accessRestorationID == id else { return }
                self.accessRestorationID = nil
                self.accessRestorationTask = nil
                if let result { self.reportFileAccess(result) }
            }
        }
    }
}
