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
    public var rejectionEnabled: Bool
    public var rejectionStrength: RejectionStrength
    public var frameWeightingEnabled: Bool
    public var backgroundNormalizationEnabled: Bool
    public var scaleNormalizationEnabled: Bool
    public var processorBackend: ProcessorBackend
    public var displayAdjustments: DisplayAdjustments
    public var relayRetentionDays: Int
    public var demosaic: DemosaicMethod

    public init(sourceModeRaw: String, watchFolderPath: String?, filePrefix: String,
                neutralizeBackground: Bool, subExposureSeconds: Double, targetName: String,
                calibration: CalibrationSelection,
                rejectionEnabled: Bool = true, rejectionStrength: RejectionStrength = .medium,
                frameWeightingEnabled: Bool = true,
                backgroundNormalizationEnabled: Bool = true,
                scaleNormalizationEnabled: Bool = true,
                processorBackend: ProcessorBackend = .none,
                displayAdjustments: DisplayAdjustments = .neutral,
                relayRetentionDays: Int = 7,
                demosaic: DemosaicMethod = .rcd) {
        self.sourceModeRaw = sourceModeRaw; self.watchFolderPath = watchFolderPath
        self.filePrefix = filePrefix; self.neutralizeBackground = neutralizeBackground
        self.subExposureSeconds = subExposureSeconds; self.targetName = targetName
        self.calibration = calibration
        self.rejectionEnabled = rejectionEnabled; self.rejectionStrength = rejectionStrength
        self.frameWeightingEnabled = frameWeightingEnabled
        self.backgroundNormalizationEnabled = backgroundNormalizationEnabled
        self.scaleNormalizationEnabled = scaleNormalizationEnabled
        self.processorBackend = processorBackend; self.displayAdjustments = displayAdjustments
        self.relayRetentionDays = relayRetentionDays
        self.demosaic = demosaic
    }

    /// Convenience no-arg init that returns the application's fresh-launch defaults.
    public init() { self = .defaults }

    // Backward-compatible decode: older blobs lack the rejection keys → default them
    // (so updating the app doesn't wipe the user's other saved settings).
    private enum CodingKeys: String, CodingKey {
        case sourceModeRaw, watchFolderPath, filePrefix, neutralizeBackground
        case subExposureSeconds, targetName, calibration, rejectionEnabled, rejectionStrength
        case frameWeightingEnabled, backgroundNormalizationEnabled, scaleNormalizationEnabled, processorBackend, displayAdjustments
        case relayRetentionDays, demosaic
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceModeRaw = try c.decode(String.self, forKey: .sourceModeRaw)
        watchFolderPath = try c.decodeIfPresent(String.self, forKey: .watchFolderPath)
        filePrefix = try c.decode(String.self, forKey: .filePrefix)
        neutralizeBackground = try c.decode(Bool.self, forKey: .neutralizeBackground)
        subExposureSeconds = try c.decode(Double.self, forKey: .subExposureSeconds)
        targetName = try c.decode(String.self, forKey: .targetName)
        calibration = try c.decode(CalibrationSelection.self, forKey: .calibration)
        rejectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .rejectionEnabled) ?? true
        rejectionStrength = try c.decodeIfPresent(RejectionStrength.self, forKey: .rejectionStrength) ?? .medium
        frameWeightingEnabled = try c.decodeIfPresent(Bool.self, forKey: .frameWeightingEnabled) ?? true
        backgroundNormalizationEnabled = try c.decodeIfPresent(Bool.self, forKey: .backgroundNormalizationEnabled) ?? true
        scaleNormalizationEnabled = try c.decodeIfPresent(Bool.self, forKey: .scaleNormalizationEnabled) ?? true
        processorBackend = try c.decodeIfPresent(ProcessorBackend.self, forKey: .processorBackend) ?? .none
        displayAdjustments = try c.decodeIfPresent(DisplayAdjustments.self, forKey: .displayAdjustments) ?? .neutral
        relayRetentionDays = try c.decodeIfPresent(Int.self, forKey: .relayRetentionDays) ?? 7
        demosaic = try c.decodeIfPresent(DemosaicMethod.self, forKey: .demosaic) ?? .rcd
    }

    /// Matches the app's fresh-launch defaults (Siril mode, live_stack prefix, 60 s).
    public static var defaults: SessionSettings {
        SessionSettings(sourceModeRaw: "Stacker output (Siril)", watchFolderPath: nil,
                        filePrefix: "live_stack", neutralizeBackground: false,
                        subExposureSeconds: 60, targetName: "",
                        calibration: CalibrationSelection(darkPath: nil, flatPath: nil, biasPath: nil),
                        rejectionEnabled: true, rejectionStrength: .medium,
                        frameWeightingEnabled: true,
                        backgroundNormalizationEnabled: true,
                        scaleNormalizationEnabled: true,
                        processorBackend: .none, displayAdjustments: .neutral,
                        relayRetentionDays: 7,
                        demosaic: .rcd)
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
