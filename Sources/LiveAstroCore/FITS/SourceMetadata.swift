import Foundation

/// Astronomical metadata read from a source sub's FITS header, propagated to
/// the exported master. All fields optional — absent cards stay nil.
public struct SourceMetadata: Equatable {
    public var object: String?
    public var ra: Double?          // decimal degrees, verbatim from source
    public var dec: Double?         // decimal degrees, verbatim from source
    public var focalLengthMM: Double?
    public var pixelSizeUM: Double?
    public var instrument: String?
    public var telescope: String?
    public var filter: String?
    public var exposureSeconds: Double?
    public var dateObs: String?     // ISO-ish string, verbatim
    public var gain: Double?
    public var ccdTempC: Double?     // CCD-TEMP: actual sensor temperature
    public var setTempC: Double?     // SET-TEMP: cooler set-point (preferred for dark matching)
    public var binning: Int?         // XBINNING
    public var siteLat: Double?
    public var siteLon: Double?

    public init() {}

    public init(fitsKeywords k: [String: String]) {
        func clean(_ key: String) -> String? {
            guard let raw = k[key] else { return nil }
            var s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("'") && s.hasSuffix("'") && s.count >= 2 {
                s = String(s.dropFirst().dropLast())
            }
            s = s.trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? nil : s
        }
        func num(_ key: String) -> Double? {
            guard let s = clean(key) else { return nil }
            // FITS permits Fortran-style D/d exponents (e.g. 1.8D+02); Swift's Double(_:) rejects
            // them, so normalize D→E first. Then reject non-finite (NaN/±Inf) — a "nan" card must
            // never reach Int(Double.nan.rounded()), which traps.
            let normalized = s.replacingOccurrences(of: "D", with: "E")
                              .replacingOccurrences(of: "d", with: "E")
            guard let v = Double(normalized), v.isFinite else { return nil }
            return v
        }

        object = clean("OBJECT")
        ra = num("RA"); dec = num("DEC")
        focalLengthMM = num("FOCALLEN")
        pixelSizeUM = num("XPIXSZ") ?? num("YPIXSZ")
        instrument = clean("INSTRUME")
        telescope = clean("TELESCOP")
        filter = clean("FILTER")
        exposureSeconds = num("EXPTIME") ?? num("EXPOSURE")
        dateObs = clean("DATE-OBS")
        gain = num("GAIN")
        ccdTempC = num("CCD-TEMP")
        setTempC = num("SET-TEMP")
        // num() already guarantees finite; require a positive binning factor (0/negative is invalid).
        binning = num("XBINNING").flatMap { $0 >= 1 ? Int($0.rounded()) : nil }
        siteLat = num("SITELAT")
        siteLon = num("SITELONG")
    }
}
