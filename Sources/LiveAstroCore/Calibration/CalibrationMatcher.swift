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

        // Only SET-TEMP is a controlled setpoint the dark library keys on. CCD-TEMP is actual sensor
        // telemetry (uncontrolled on uncooled cameras like Seestar) and must NOT drive rejection —
        // using it caused false "outside tolerance" mismatches for uncooled data.
        let lightTemp = light.setTempC
        if lightTemp == nil { warnings.append("Lights have no set-point temperature — matching darks ignoring temperature.") }
        if light.instrument == nil { warnings.append("Lights have no camera name — matching on gain/exposure only.") }

        // Temperature tolerance — applied to BOTH darks and bias when both sides carry a set-point.
        // (Bias specificity counts SET-TEMP, so bias must be temp-filtered too, else a wrong-temp
        // bias could out-rank the correct one on index order.)
        let tempOK: (MasterFrame) -> Bool = { frame in
            guard let lt = lightTemp, let ft = frame.setTempC else { return true }
            return abs(ft - lt) <= options.tempToleranceC
        }

        let bias = firstMatchingBias(light: light, library: library, tempOK: tempOK)

        // Darks matching camera + gain + binning.
        let darks = library.filter { $0.kind == .dark && keyMatches($0, light) }
        if darks.isEmpty {
            return Result(dark: .none(reason: "No dark in the library for this camera and gain."),
                          bias: bias, warnings: warnings)
        }
        // Prefer the MOST specific match: a dark that agrees on gain/binning/temp beats a legacy
        // wildcard (gain/binning/temp all nil) that matches only by camera+exposure. Without this a
        // stale under-specified entry with earlier index order could win over the correct dark.
        let candidates = rankedBySpecificity(darks.filter(tempOK), light: light)
        if candidates.isEmpty {
            return Result(dark: .none(reason: "No dark within \(fmt(options.tempToleranceC)) °C of the lights' temperature."),
                          bias: bias, warnings: warnings)
        }

        // Exact exposure wins.
        if let lightExp = light.exposureSeconds,
           let exact = candidates.first(where: { exposureMatches($0.exposureSeconds, lightExp) }) {
            return Result(dark: .exact(exact), bias: bias, warnings: warnings)
        }
        // Unknown light exposure: usable only if it's unambiguous (exactly one matching dark).
        // With several, picking `candidates.first` would apply an arbitrary insertion-order dark.
        if light.exposureSeconds == nil {
            if candidates.count == 1 {
                return Result(dark: .exact(candidates[0]), bias: bias, warnings: warnings)
            }
            return Result(
                dark: .none(reason: "Lights have no recorded exposure and \(candidates.count) darks match — can't choose one."),
                bias: bias, warnings: warnings)
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

    private static func firstMatchingBias(light: SourceMetadata, library: [MasterFrame],
                                          tempOK: (MasterFrame) -> Bool) -> MasterFrame? {
        rankedBySpecificity(library.filter { $0.kind == .bias && keyMatches($0, light) && tempOK($0) },
                            light: light).first
    }

    /// How many of gain/binning/temp are BOTH specified on the master AND on the light (i.e. actually
    /// verified to agree, not wildcard-passed). Higher = more trustworthy match.
    private static func specificity(_ f: MasterFrame, _ light: SourceMetadata) -> Int {
        var s = 0
        if light.gain != nil, f.gain != nil { s += 1 }
        if light.binning != nil, f.binning != nil { s += 1 }
        if light.setTempC != nil, f.setTempC != nil { s += 1 }
        return s
    }

    /// Stable sort by specificity descending — ties keep the original (index) order.
    private static func rankedBySpecificity(_ frames: [MasterFrame], light: SourceMetadata) -> [MasterFrame] {
        frames.enumerated().sorted { a, b in
            let sa = specificity(a.element, light), sb = specificity(b.element, light)
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map(\.element)
    }

    private static func sameCamera(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    private static func exposureMatches(_ frameExp: Double?, _ lightExp: Double) -> Bool {
        guard let fe = frameExp else { return false }
        return abs(fe - lightExp) <= max(0.5, lightExp * 0.01)   // ≤0.5 s or 1%
    }

    private static func fmt(_ v: Double) -> String {
        // Int(_:) traps on a finite-but-huge Double (e.g. a corrupt EXPTIME=1e100); Int(exactly:)
        // returns nil out of range → fall back to a float format instead of crashing.
        if v == v.rounded(), let i = Int(exactly: v) { return String(i) }
        return String(format: "%.2g", v)
    }
}
