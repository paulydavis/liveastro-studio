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
            let firstMatch = CalibrationMatcher.match(light: metadata, library: entries,
                                options: .init(scaleEnabled: scaleEnabled))
            messages.append(contentsOf: firstMatch.warnings.map { "Calibration: \($0)" })
            // Resolve a USABLE bias, retrying past any that are missing/corrupt/wrong-size — a bad
            // first bias must not doom every scaled-dark attempt below.
            var biasExcluded = Set<UUID>()
            while biasImage == nil {
                let usable = entries.filter { !biasExcluded.contains($0.id) }
                guard let b = CalibrationMatcher.match(light: metadata, library: usable,
                                options: .init(scaleEnabled: scaleEnabled)).bias else { break }
                if let img = library.master(for: b), dimensionsOK(img, metadata) {
                    biasImage = img
                } else {
                    biasExcluded.insert(b.id)
                    messages.append("Calibration: a matched bias is unusable (missing/corrupt or wrong size) — trying another.")
                }
            }

            // Try matched darks in preference order. A master that is missing/corrupt on disk, or the
            // wrong SIZE for these lights, must not block an otherwise-valid alternative — exclude it
            // and re-match. Terminates: each failed candidate is excluded, shrinking the set.
            var excluded = Set<UUID>()
            darkLoop: while darkImage == nil {
                let usable = entries.filter { !excluded.contains($0.id) }
                switch CalibrationMatcher.match(light: metadata, library: usable,
                                                options: .init(scaleEnabled: scaleEnabled)).dark {
                case .exact(let f):
                    if let img = library.master(for: f), dimensionsOK(img, metadata) {
                        darkImage = img
                        messages.append("Calibration: matched \(describe(f)).")
                    } else {
                        excluded.insert(f.id)
                        messages.append("Calibration: \(describe(f)) is unusable (missing/corrupt or wrong size) — trying another dark.")
                    }
                case .scaled(let base, _, let factor):
                    // Scale with the already-validated bias (resolved above), not a freshly-loaded
                    // one — so a bad first bias can't repeatedly sink an otherwise-valid scaled dark.
                    guard let bi = biasImage else {
                        messages.append("Calibration: no usable bias to scale the nearest dark — continuing without a dark.")
                        break darkLoop
                    }
                    if let d = library.master(for: base), dimensionsOK(d, metadata),
                       let scaled = DarkScaler.scale(dark: d, bias: bi, factor: factor) {
                        darkImage = scaled
                        messages.append("Calibration: scaled \(describe(base)) to this exposure.")
                    } else {
                        excluded.insert(base.id)
                        messages.append("Calibration: could not use \(describe(base)) (missing/corrupt or wrong size) — trying another dark.")
                    }
                case .none(let reason):
                    messages.append("Calibration: \(reason)")
                    break darkLoop
                }
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
                    let built = try MasterBuilder.combineDetailed(fitsURLs: urls, kind: .flat, bias: offset)
                    flatImage = built.image
                    // Report the offset HONESTLY: a dimension-mismatched offset is silently skipped
                    // by the builder, so don't claim "subtracted" unless it actually was.
                    let offsetNote = built.offsetApplied ? " (offset subtracted)"
                        : (offset != nil ? " (offset skipped — size mismatch)" : "")
                    messages.append("Calibration: built master flat from \(built.contributingCount) flats\(offsetNote).")
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

    /// A loaded master must match the lights' sensor dimensions when they're known. When the light
    /// header carries no NAXIS1/2 we can't validate here — accept and let the Calibrator skip a truly
    /// mismatched master at apply time (it already guards dimensions per-frame).
    private static func dimensionsOK(_ img: AstroImage, _ light: SourceMetadata) -> Bool {
        if let w = light.width, img.width != w { return false }
        if let h = light.height, img.height != h { return false }
        // Same-size but wrong CHANNELS is also unusable — the Calibrator skips it at apply time, so
        // accepting it here would report hasDark=true and block retrying a valid alternative.
        if let c = light.channels, img.channels != c { return false }
        return true
    }

    static func describe(_ f: MasterFrame) -> String {
        var parts: [String] = []
        if let e = f.exposureSeconds { parts.append("\(Int(e))s") }
        if let t = f.setTempC { parts.append("\(Int(t))°C") }
        if let g = f.gain { parts.append("gain \(Int(g))") }
        return "\(f.camera) dark" + (parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))")
    }
}
