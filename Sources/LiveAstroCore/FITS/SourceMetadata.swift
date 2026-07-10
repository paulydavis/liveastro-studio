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
    public var ccdTempC: Double?
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
        func num(_ key: String) -> Double? { clean(key).flatMap { Double($0) } }

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
        siteLat = num("SITELAT")
        siteLon = num("SITELONG")
    }
}
