import Foundation

/// Persistable snapshot of the control-form settings. `sourceModeRaw` holds the
/// app's SourceMode.rawValue string so LiveAstroCore stays independent of the
/// app-layer enum.
public struct SessionSettings: Codable, Equatable {
    public var sourceModeRaw: String
    public var watchFolderPath: String?
    public var filePrefix: String
    public var neutralizeBackground: Bool
    public var subExposureSeconds: Double
    public var targetName: String
    public var calibration: CalibrationSelection

    public init(sourceModeRaw: String, watchFolderPath: String?, filePrefix: String,
                neutralizeBackground: Bool, subExposureSeconds: Double,
                targetName: String, calibration: CalibrationSelection) {
        self.sourceModeRaw = sourceModeRaw; self.watchFolderPath = watchFolderPath
        self.filePrefix = filePrefix; self.neutralizeBackground = neutralizeBackground
        self.subExposureSeconds = subExposureSeconds; self.targetName = targetName
        self.calibration = calibration
    }

    /// Matches the app's fresh-launch defaults (Siril mode, live_stack prefix, 60 s).
    public static var defaults: SessionSettings {
        SessionSettings(sourceModeRaw: "Stacker output (Siril)", watchFolderPath: nil,
                        filePrefix: "live_stack", neutralizeBackground: false,
                        subExposureSeconds: 60, targetName: "",
                        calibration: CalibrationSelection(darkPath: nil, flatPath: nil, biasPath: nil))
    }
}

public enum SessionSettingsStore {
    static let key = "sessionSettings.v1"

    public static func load(_ d: UserDefaults) -> SessionSettings {
        guard let data = d.data(forKey: key),
              let s = try? JSONDecoder().decode(SessionSettings.self, from: data)
        else { return .defaults }
        return s
    }

    public static func save(_ s: SessionSettings, to d: UserDefaults) {
        if let data = try? JSONEncoder().encode(s) { d.set(data, forKey: key) }
    }
}
