import Foundation

/// Persistable choice of master files for calibration (last-used paths).
public struct CalibrationSelection: Equatable {
    public var darkPath: String?
    public var flatPath: String?
    public var biasPath: String?
    public init(darkPath: String?, flatPath: String?, biasPath: String?) {
        self.darkPath = darkPath; self.flatPath = flatPath; self.biasPath = biasPath
    }
}

public enum CalibrationStore {
    private static let darkKey = "calibration.darkPath"
    private static let flatKey = "calibration.flatPath"
    private static let biasKey = "calibration.biasPath"

    public static func load(_ d: UserDefaults) -> CalibrationSelection {
        CalibrationSelection(darkPath: d.string(forKey: darkKey),
                             flatPath: d.string(forKey: flatKey),
                             biasPath: d.string(forKey: biasKey))
    }

    public static func save(_ s: CalibrationSelection, to d: UserDefaults) {
        d.set(s.darkPath, forKey: darkKey)
        d.set(s.flatPath, forKey: flatKey)
        d.set(s.biasPath, forKey: biasKey)
    }

    /// Default masters store: ~/LiveAstro/masters/
    public static func mastersDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("LiveAstro/masters", isDirectory: true)
    }
}

public enum CalibrationLoader {
    /// Load master files into a Calibrator. Returns (nil, []) when neither is set,
    /// and a warning per file that is set but unreadable. Bias is not loaded here —
    /// it is folded into the flat at build time.
    public static func makeCalibrator(dark: URL?, flat: URL?) -> (Calibrator?, [String]) {
        var warnings: [String] = []
        func loadMaster(_ url: URL?, _ label: String) -> AstroImage? {
            guard let url else { return nil }
            do { return try MasterBuilder.load(url) }
            catch { warnings.append("Could not load master \(label): \(url.lastPathComponent)"); return nil }
        }
        let d = loadMaster(dark, "dark")
        let f = loadMaster(flat, "flat").map { MasterBuilder.normalizedFlat($0) }
        guard d != nil || f != nil else { return (nil, warnings) }
        return (Calibrator(dark: d, flat: f), warnings)
    }
}
