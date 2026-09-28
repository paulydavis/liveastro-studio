import Foundation
import LiveAstroCore

struct LocationReferenceSnapshot {
    let capture: URL?
    let output: URL?
    let dark: String?
    let flat: String?
    let bias: String?
    let flats: URL?
    let darkFlats: URL?
    let library: [UUID: String]
}

extension AppModel {
    func captureLocationReferences() -> LocationReferenceSnapshot {
        LocationReferenceSnapshot(capture: watchFolder, output: selectedOutputFolder,
                                  dark: calibration.darkPath, flat: calibration.flatPath, bias: calibration.biasPath,
                                  flats: sessionFlatsFolder, darkFlats: sessionDarkFlatsFolder,
                                  library: Dictionary(uniqueKeysWithValues: calibrationLibrary.all().compactMap { entry in
            entry.sourcePath.map { (entry.id, $0) }
        }))
    }

    func acquireLocations(_ requests: [AuthorizedLocations.Request]) async throws -> [Result<FileAccessLease, Error>] {
        let generation = locationSelectionGeneration
        let references = captureLocationReferences()
        let prepared = try await authorizedLocations.prepare(requests)
        try Task.checkCancellation()
        guard generation == locationSelectionGeneration,
              references.capture == watchFolder, references.output == selectedOutputFolder,
              references.dark == calibration.darkPath, references.flat == calibration.flatPath,
              references.bias == calibration.biasPath, references.flats == sessionFlatsFolder,
              references.darkFlats == sessionDarkFlatsFolder else { throw CancellationError() }
        let changes = try reconcileLocationReferences(references, prepared: prepared)
        try authorizedLocations.commit(changes)
        return prepared.results
    }

    func reconcileLocationReferences(_ captured: LocationReferenceSnapshot,
                                     prepared: AuthorizedLocations.PreparedAccess) throws -> [AuthorizedLocations.GrantChange] {
        guard isStorePreview else { return prepared.changes }
        let relocations = prepared.relocations.filter { authorizedLocations.matches($0) }.sorted {
            $0.oldRoot.pathComponents.count > $1.oldRoot.pathComponents.count
        }
        func relocated(_ path: String?) -> String? {
            guard let path else { return nil }
            let url = URL(fileURLWithPath: path)
            for relocation in relocations {
                if let suffix = AuthorizedLocationResolver.suffix(url, under: relocation.oldRoot) {
                    return suffix.reduce(relocation.newRoot) { $0.appendingPathComponent($1) }.standardizedFileURL.path
                }
            }
            return path
        }
        func relocatedURL(_ url: URL?) -> URL? { relocated(url?.path).map { URL(fileURLWithPath: $0) } }
        let current = calibrationLibrary.all()
        var libraryUpdates: [UUID: URL] = [:]
        var withheld: Set<String> = []
        for entry in current {
            guard let path = entry.sourcePath else { continue }
            if captured.library[entry.id] == path {
                if let next = relocated(path), next != path { libraryUpdates[entry.id] = URL(fileURLWithPath: next) }
            } else {
                for relocation in relocations where AuthorizedLocationResolver.suffix(URL(fileURLWithPath: path), under: relocation.oldRoot) != nil {
                    withheld.insert(relocation.key)
                }
            }
        }
        // A failed library write leaves the old grant intact, including its old
        // matching root. Already resolved current access is not authorization to
        // discard the old reference identities.
        let savedEntries = try calibrationLibrary.updateSourceDirectories(libraryUpdates, expectedSourcePaths: captured.library)
        // A background library mutation may have raced the earlier read. Do not
        // renew away the old matching root while any unmatched consumer remains.
        for entry in savedEntries {
            guard let path = entry.sourcePath, libraryUpdates[entry.id]?.path != path else { continue }
            for relocation in relocations where AuthorizedLocationResolver.suffix(URL(fileURLWithPath: path), under: relocation.oldRoot) != nil {
                withheld.insert(relocation.key)
            }
        }
        if watchFolder == captured.capture { watchFolder = relocatedURL(watchFolder) }
        if selectedOutputFolder == captured.output { selectedOutputFolder = relocatedURL(selectedOutputFolder) }
        if calibration.darkPath == captured.dark { calibration.darkPath = relocated(calibration.darkPath) }
        if calibration.flatPath == captured.flat { calibration.flatPath = relocated(calibration.flatPath) }
        if calibration.biasPath == captured.bias { calibration.biasPath = relocated(calibration.biasPath) }
        if sessionFlatsFolder == captured.flats { sessionFlatsFolder = relocatedURL(sessionFlatsFolder) }
        if sessionDarkFlatsFolder == captured.darkFlats { sessionDarkFlatsFolder = relocatedURL(sessionDarkFlatsFolder) }
        userDefaults.set(sessionFlatsFolder?.path, forKey: "StorePreview.flatsPath")
        userDefaults.set(sessionDarkFlatsFolder?.path, forKey: "StorePreview.darkFlatsPath")
        CalibrationStore.save(calibration, to: userDefaults)
        saveSettings()
        if !libraryUpdates.isEmpty { refreshLibraryEntries() }
        // A master being built may not have an index entry yet. It can publish
        // its captured old source after this snapshot. Preserve that matching
        // root until a later acquisition can reconcile the completed entry.
        if let pendingSource = calibrationAdditionSource {
            withheld.formUnion(relocations.filter {
                AuthorizedLocationResolver.suffix(pendingSource, under: $0.oldRoot) != nil
            }.map(\.key))
        }
        return prepared.changes.filter { !withheld.contains($0.key) }
    }
}
