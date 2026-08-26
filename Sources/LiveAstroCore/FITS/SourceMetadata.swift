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
    public var width: Int?           // NAXIS1 — sensor width, for validating a master matches these lights
    public var height: Int?          // NAXIS2 — sensor height
    public var channels: Int?        // NAXIS3 (else 1 for a 2-D frame) — validated against the master
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
        // Convert a numeric card to a bounded Int. num() rejects NaN/Inf, but a FINITE but huge
        // value (e.g. XBINNING = 1e100) still TRAPS Int(_:) — so require the rounded value to sit
        // within [min, max] (both Int-representable) before converting. Rejects out-of-range as nil.
        func intCard(_ key: String, min: Int = 1, max: Int) -> Int? {
            guard let v = num(key) else { return nil }
            let r = v.rounded()
            guard r >= Double(min), r <= Double(max) else { return nil }
            return Int(r)
        }
        // A finite value within a physically-plausible range. Rejects corrupt magnitudes (e.g.
        // EXPTIME=1e100) at the source, before they can flow into dark scaling and produce a
        // non-finite (blacked-out) calibrated frame.
        func boundedNum(_ keys: [String], min: Double, max: Double) -> Double? {
            for key in keys { if let v = num(key), v >= min, v <= max { return v } }
            return nil
        }

        object = clean("OBJECT")
        ra = num("RA"); dec = num("DEC")
        focalLengthMM = num("FOCALLEN")
        pixelSizeUM = num("XPIXSZ") ?? num("YPIXSZ")
        instrument = clean("INSTRUME")
        telescope = clean("TELESCOP")
        filter = clean("FILTER")
        exposureSeconds = boundedNum(["EXPTIME", "EXPOSURE"], min: 0, max: 86_400)   // ≤ 24 h
        dateObs = clean("DATE-OBS")
        gain = boundedNum(["GAIN"], min: 0, max: 1_000_000)
        ccdTempC = boundedNum(["CCD-TEMP"], min: -273.15, max: 10_000)               // ≥ absolute zero
        setTempC = boundedNum(["SET-TEMP"], min: -273.15, max: 10_000)
        binning = intCard("XBINNING", max: 64)            // practical binning ceiling
        width = intCard("NAXIS1", max: 100_000)           // sensor axis lengths — far above any real
        height = intCard("NAXIS2", max: 100_000)          // sensor (~14k), bounded vs corrupt headers
        // Channels: NAXIS3 for a 3-plane cube (RGB), else 1 for a 2-D image. Used to validate a
        // master's channel count matches these lights (a same-size wrong-channel dark is unusable).
        channels = intCard("NAXIS3", max: 4) ?? ((width != nil && height != nil) ? 1 : nil)
        siteLat = num("SITELAT")
        siteLon = num("SITELONG")
    }
}
