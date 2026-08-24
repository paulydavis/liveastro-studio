import Foundation

/// Pure resolution of which library master(s) calibrate a session, from the
/// lights' header metadata. No I/O — the caller loads/scales the chosen masters
/// and builds the Calibrator. Decisions per the calibration-library design:
/// hybrid match, exact-exposure preferred with bias-enabled scaling fallback,
/// ±tolerance on set-point temperature, uncooled frames matched ignoring temp.
public enum CalibrationMatcher {

    public struct Options {
        public var scaleEnabled: Bool
        public var tempToleranceC: Double
        public init(scaleEnabled: Bool = true, tempToleranceC: Double = 2.0) {
            self.scaleEnabled = scaleEnabled; self.tempToleranceC = tempToleranceC
        }
    }

    public enum DarkMatch: Equatable {
        case exact(MasterFrame)
        case scaled(base: MasterFrame, bias: MasterFrame, factor: Double)
        case none(reason: String)
    }

    public struct Result: Equatable {
        public var dark: DarkMatch
        public var bias: MasterFrame?
        public var warnings: [String]
    }

    public static func match(light: SourceMetadata, library: [MasterFrame],
                             options: Options = Options()) -> Result {
        var warnings: [String] = []

        let lightTemp = light.setTempC ?? light.ccdTempC
        if lightTemp == nil { warnings.append("Lights have no temperature — matching darks ignoring temperature.") }
        if light.instrument == nil { warnings.append("Lights have no camera name — matching on gain/exposure only.") }

        let bias = firstMatchingBias(light: light, library: library)

        // Darks matching camera + gain + binning.
        let darks = library.filter { $0.kind == .dark && keyMatches($0, light) }
        if darks.isEmpty {
            return Result(dark: .none(reason: "No dark in the library for this camera and gain."),
                          bias: bias, warnings: warnings)
        }

        // Apply temperature tolerance when the lights carry a temperature.
        let tempOK: (MasterFrame) -> Bool = { frame in
            guard let lt = lightTemp, let ft = frame.setTempC else { return true }
            return abs(ft - lt) <= options.tempToleranceC
        }
        let candidates = darks.filter(tempOK)
        if candidates.isEmpty {
            return Result(dark: .none(reason: "No dark within \(fmt(options.tempToleranceC)) °C of the lights' temperature."),
                          bias: bias, warnings: warnings)
        }

        // Exact exposure wins.
        if let lightExp = light.exposureSeconds,
           let exact = candidates.first(where: { exposureMatches($0.exposureSeconds, lightExp) }) {
            return Result(dark: .exact(exact), bias: bias, warnings: warnings)
        }
        // A single candidate with no recorded exposure is treated as usable as-is.
        if light.exposureSeconds == nil, let only = candidates.first {
            return Result(dark: .exact(only), bias: bias, warnings: warnings)
        }

        // Scale the nearest-exposure dark using bias.
        if options.scaleEnabled, let lightExp = light.exposureSeconds {
            let scalable = candidates.filter { ($0.exposureSeconds ?? 0) > 0 }
            if let base = scalable.min(by: { abs(($0.exposureSeconds ?? 0) - lightExp) < abs(($1.exposureSeconds ?? 0) - lightExp) }),
               let baseExp = base.exposureSeconds, let bias {
                let factor = lightExp / baseExp
                warnings.append("No \(fmt(lightExp)) s dark — scaling the \(fmt(baseExp)) s dark ×\(fmt(factor)) using bias.")
                return Result(dark: .scaled(base: base, bias: bias, factor: factor), bias: bias, warnings: warnings)
            }
            let why = bias == nil ? "no matching bias to scale with" : "no dark with a recorded exposure to scale"
            return Result(dark: .none(reason: "No exact-exposure dark and \(why)."), bias: bias, warnings: warnings)
        }

        return Result(dark: .none(reason: "No dark at this exposure (exposure scaling is off)."),
                      bias: bias, warnings: warnings)
    }

    // MARK: - Predicates

    /// camera (when named) + gain + binning must agree; nil light fields don't filter.
    private static func keyMatches(_ f: MasterFrame, _ light: SourceMetadata) -> Bool {
        if let cam = light.instrument, !sameCamera(f.camera, cam) { return false }
        if let g = light.gain, let fg = f.gain, abs(fg - g) > 0.5 { return false }
        if let b = light.binning, let fb = f.binning, fb != b { return false }
        return true
    }

    private static func firstMatchingBias(light: SourceMetadata, library: [MasterFrame]) -> MasterFrame? {
        library.first { $0.kind == .bias && keyMatches($0, light) }
    }

    private static func sameCamera(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    private static func exposureMatches(_ frameExp: Double?, _ lightExp: Double) -> Bool {
        guard let fe = frameExp else { return false }
        return abs(fe - lightExp) <= max(0.5, lightExp * 0.01)   // ≤0.5 s or 1%
    }

    private static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2g", v)
    }
}
