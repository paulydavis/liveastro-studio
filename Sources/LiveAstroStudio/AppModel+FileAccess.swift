import Foundation
import AppKit
import LiveAstroCore

/// Synchronous filesystem boundary; callers own scheduling and cancellation.
protocol LocationAvailabilityChecking: Sendable {
    func check(_ url: URL, forWriting: Bool) throws
}

struct FileLocationAvailability: LocationAvailabilityChecking {
    func check(_ url: URL, forWriting: Bool) throws {
        let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isWritableKey])
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

/// Authorization for one exact finished session directory, not every child of
/// its old output root. Workers copy this value so replacing the app's retained
/// context cannot revoke access underneath an already-running reader.
struct SessionDirectoryAccess: Sendable {
    let url: URL
    private let owner: Owner
    private enum Owner: Sendable {
        case operation(OperationFileAccess)
        case independent(FileAccessLease)
    }

    init(url: URL, operation: OperationFileAccess) {
        if let output = operation.leases.first,
           let suffix = AuthorizedLocationResolver.suffix(url, under: operation.output) {
            self.url = suffix.reduce(output.canonicalURL) { $0.appendingPathComponent($1) }.standardizedFileURL
        } else {
            self.url = url.standardizedFileURL
        }
        self.owner = .operation(operation)
    }

    init(lease: FileAccessLease) {
        self.url = lease.canonicalURL
        self.owner = .independent(lease)
    }
}

extension AppModel {
    var isStorePreview: Bool { distribution.isStorePreview }

    @discardableResult
    func selectLocation(_ url: URL, key: String) async -> Bool {
        cancelCalibrationPreparation()
        locationSelectionGeneration &+= 1
        let generation = locationSelectionGeneration
        invalidateAccessRestoration()
        do {
            let prepared = try await authorizedLocations.prepareSelection(url, key: key)
            guard generation == locationSelectionGeneration else { return false }
            try authorizedLocations.commit(prepared.changes)
            let lease = try prepared.results[0].get()
            invalidateAccessRestoration()
            if key == "output" { selectedOutputFolder = lease.url }
            if key == "capture" { watchFolder = lease.url }
            return true
        } catch { if generation == locationSelectionGeneration, !(error is CancellationError) { reportFileAccess(error) }; return false }
    }

    func chooseSessionOutputFolder() {
        let panel = makeDirectoryPanel(title: "Save sessions to", message: "Choose where LiveAstro Store Preview saves session output.")
        if panel.runModal() == .OK, let url = panel.url { Task { await selectLocation(url, key: "output") } }
    }

    func selectSourceFolder(_ url: URL) async -> URL? {
        let key = "source:" + url.standardizedFileURL.absoluteString
        guard await selectLocation(url, key: key) else { return nil }
        return authorizedLocations.displayURL(key: key)
    }

    func reportFileAccess(_ error: Error) {
        errorMessage = "Folder access failed: \(error.localizedDescription) Reconnect the location or choose the folder again."
    }

    func setCalibrationFolder(_ url: URL?, darkFlats: Bool) async {
        let selected: URL?
        if let url {
            guard let resolved = await selectSourceFolder(url) else { return }
            selected = resolved
        } else { cancelCalibrationPreparation(); locationSelectionGeneration &+= 1; selected = nil }
        invalidateAccessRestoration()
        if darkFlats { sessionDarkFlatsFolder = selected } else { sessionFlatsFolder = selected }
        if isStorePreview { userDefaults.set(selected?.path, forKey: darkFlats ? "StorePreview.darkFlatsPath" : "StorePreview.flatsPath") }
    }

    func acquireReadableLocation(_ url: URL) async throws -> FileAccessLease {
        let results = try await acquireLocations([.url(url)])
        return try results[0].get()
    }

    func acquireOutputLocation() async throws -> FileAccessLease {
        guard isStorePreview else { return FileAccessLease(url: liveAstroRoot) }
        let results = try await acquireLocations([.key("output")])
        let lease = try results[0].get()
        selectedOutputFolder = lease.url
        return lease
    }

    func acquireOperationAccess(input: URL) async throws -> OperationFileAccess {
        if isStorePreview { invalidateAccessRestoration() }
        let results = try await acquireSelections(input: input, includeOutput: true)
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

    /// One captured authorization batch. Current selections change only from
    /// successfully resolved tokens, even when another required location fails.
    private func acquireSelections(input: URL?, includeOutput: Bool) async throws -> [(SelectionRole, Result<FileAccessLease, Error>)] {
        var requests: [(SelectionRole, AuthorizedLocations.Request)] = []
        if includeOutput { requests.append((.output, isStorePreview ? .key("output") : .url(liveAstroRoot))) }
        if let input { requests.append((.input, .url(input))) }
        for (role, path) in [(SelectionRole.dark, calibration.darkPath), (.flat, calibration.flatPath), (.bias, calibration.biasPath)] {
            if let path { requests.append((role, .url(URL(fileURLWithPath: path)))) }
        }
        if let url = sessionFlatsFolder { requests.append((.flats, .url(url))) }
        if let url = sessionDarkFlatsFolder { requests.append((.darkFlats, .url(url))) }
        let acquired = try await acquireLocations(requests.map(\.1))
        let results = zip(requests, acquired).map { ($0.0.0, $0.1) }
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
        selectedOutputFolder = authorizedLocations.displayURL(key: "output")
        for dark in [false, true] {
            guard let path = userDefaults.string(forKey: dark ? "StorePreview.darkFlatsPath" : "StorePreview.flatsPath") else { continue }
            let displayed = URL(fileURLWithPath: path)
            if dark { sessionDarkFlatsFolder = displayed } else { sessionFlatsFolder = displayed }
        }
        if let displayed = authorizedLocations.displayURL(key: "capture") { watchFolder = displayed }
        let id = UUID()
        accessRestorationID = id
        accessRestorationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await self.acquireSelections(input: self.watchFolder, includeOutput: self.selectedOutputFolder != nil)
                guard self.accessRestorationID == id else { return }
                var checks: [(FileAccessLease, Bool)] = []
                for (role, result) in results {
                    switch result {
                    case .success(let lease): checks.append((lease, role == .output))
                    case .failure(let error): self.reportFileAccess(error)
                    }
                }
                let checker = self.locationAvailability
                let captured = checks
                let worker = Task.detached {
                    defer { withExtendedLifetime(captured) {} }
                    for (lease, writing) in captured {
                        try Task.checkCancellation()
                        try checker.check(lease.url, forWriting: writing)
                    }
                }
                try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            } catch {
                guard self.accessRestorationID == id else { return }
                if !(error is CancellationError) { self.reportFileAccess(error) }
            }
            guard self.accessRestorationID == id else { return }
            self.accessRestorationID = nil
            self.accessRestorationTask = nil
        }
    }
}
