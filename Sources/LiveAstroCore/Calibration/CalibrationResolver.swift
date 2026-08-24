import Foundation

/// Resolves a session's calibration from the lights' header metadata: matches the
/// library, loads/scales the master dark, builds the session flat, and constructs
/// the `Calibrator`. Actor-free and self-contained (only file I/O + core types), so
/// it runs equally on the main actor (peek-at-Start) or the stacking consume task
/// (first-sub resolution for an empty-folder start), and is directly unit-testable.
public enum CalibrationResolver {
    public struct Resolution {
        public var calibrator: Calibrator?
        public var messages: [String]
        public var hasDark: Bool
        public var hasFlat: Bool
    }

    public static func resolve(
        metadata: SourceMetadata, library: CalibrationLibrary, scaleEnabled: Bool,
        flatsFolder: URL?, darkFlatsFolder: URL?,
        legacyDarkPath: String?, legacyFlatPath: String?) -> Resolution {

        var messages: [String] = []
        let entries = library.all()
        var darkImage: AstroImage?
        var biasImage: AstroImage?

        if !entries.isEmpty {
            let result = CalibrationMatcher.match(light: metadata, library: entries,
                            options: .init(scaleEnabled: scaleEnabled))
            messages.append(contentsOf: result.warnings.map { "Calibration: \($0)" })
            if let b = result.bias {
                biasImage = library.master(for: b)
                if biasImage == nil { messages.append("Calibration: matched a bias but its master file could not be loaded.") }
            }
            switch result.dark {
            case .exact(let f):
                if let img = library.master(for: f) {
                    darkImage = img
                    messages.append("Calibration: matched \(describe(f)).")
                } else {
                    messages.append("Calibration: matched \(describe(f)) but its master file could not be loaded — continuing without a dark.")
                }
            case .scaled(let base, let biasF, let factor):
                if let d = library.master(for: base),
                   let bi = library.master(for: biasF),
                   let scaled = DarkScaler.scale(dark: d, bias: bi, factor: factor) {
                    darkImage = scaled
                    messages.append("Calibration: scaled \(describe(base)) to this exposure.")
                } else {
                    messages.append("Calibration: could not scale \(describe(base)) (missing master or size mismatch) — continuing without a dark.")
                }
            case .none(let reason):
                messages.append("Calibration: \(reason)")
            }
        }

        // Legacy explicit dark selection as a fallback when the library had no match.
        if darkImage == nil, let p = legacyDarkPath {
            do {
                darkImage = try MasterBuilder.load(URL(fileURLWithPath: p))
                messages.append("Calibration: using selected dark file.")
            } catch {
                messages.append("Calibration: selected dark could not be read — \(error.localizedDescription).")
            }
        }

        // Session flat: build fresh from the chosen flats folder (offset = dark-flats else bias).
        var flatImage: AstroImage?
        if let flatsFolder {
            var offset = biasImage
            if let dfFolder = darkFlatsFolder {
                let dfURLs = CalibrationLibrary.fitsFiles(in: dfFolder)
                if dfURLs.isEmpty {
                    messages.append("Calibration: no dark-flats in that folder — using bias as the flat offset.")
                } else {
                    do { offset = try MasterBuilder.combine(fitsURLs: dfURLs, kind: .bias, bias: nil) }
                    catch { messages.append("Calibration: dark-flats build failed — \(error.localizedDescription); using bias instead.") }
                }
            }
            let urls = CalibrationLibrary.fitsFiles(in: flatsFolder)
            if urls.isEmpty {
                messages.append("Calibration: no flats found in the flats folder — continuing without a flat.")
            } else {
                do {
                    flatImage = try MasterBuilder.combine(fitsURLs: urls, kind: .flat, bias: offset)
                    messages.append("Calibration: built master flat from \(urls.count) flats\(offset != nil ? " (offset subtracted)" : "").")
                } catch {
                    messages.append("Calibration: flat build failed — \(error.localizedDescription); continuing without a flat.")
                }
            }
        } else if let p = legacyFlatPath {
            do {
                // Normalize legacy/external master flats (idempotent) so a non-normalized
                // file can't over/under-correct — matches the session-flat path.
                flatImage = MasterBuilder.normalizedFlat(try MasterBuilder.load(URL(fileURLWithPath: p)))
                messages.append("Calibration: using selected flat file.")
            } catch {
                messages.append("Calibration: selected flat could not be read — \(error.localizedDescription).")
            }
        }

        let cal = (darkImage != nil || flatImage != nil) ? Calibrator(dark: darkImage, flat: flatImage) : nil
        return Resolution(calibrator: cal, messages: messages,
                          hasDark: darkImage != nil, hasFlat: flatImage != nil)
    }

    static func describe(_ f: MasterFrame) -> String {
        var parts: [String] = []
        if let e = f.exposureSeconds { parts.append("\(Int(e))s") }
        if let t = f.setTempC { parts.append("\(Int(t))°C") }
        if let g = f.gain { parts.append("gain \(Int(g))") }
        return "\(f.camera) dark" + (parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))")
    }
}
