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
            // Append only the LIGHT-level warnings (temperature / camera). The scaling warning is
            // dark-specific — the actually-chosen dark logs its own "scaled X" message below, so
            // emitting it here could name a dark that a later retry abandons.
            messages.append(contentsOf: firstMatch.warnings
                .filter { !$0.contains("scaling the") }
                .map { "Calibration: \($0)" })
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
                    guard let d = library.master(for: base), dimensionsOK(d, metadata) else {
                        excluded.insert(base.id)
                        messages.append("Calibration: \(describe(base)) is unusable (missing/corrupt or wrong size) — trying another dark.")
                        continue
                    }
                    // Scale needs a bias matching THIS dark's shape. The light-matched bias usually
                    // fits, but when the light carries no dimensions it might not — so fall back to any
                    // matching bias whose loaded shape equals the dark's, rather than discarding a
                    // valid dark over a shape-mismatched bias (retry the bias, not the dark).
                    guard let bi = biasFitting(dark: d, light: metadata, library: library, preferred: biasImage),
                          let scaled = DarkScaler.scale(dark: d, bias: bi, factor: factor) else {
                        excluded.insert(base.id)
                        messages.append("Calibration: no bias compatible with \(describe(base)) to scale it — trying another dark.")
                        continue
                    }
                    darkImage = scaled
                    messages.append("Calibration: scaled \(describe(base)) to this exposure.")
                case .none(let reason):
                    messages.append("Calibration: \(reason)")
                    break darkLoop
                }
            }
        }

        // Legacy explicit dark selection as a fallback when the library had no match.
        if darkImage == nil, let p = legacyDarkPath {
            do {
                let img = try MasterBuilder.load(URL(fileURLWithPath: p))
                if dimensionsOK(img, metadata) {
                    darkImage = img
                    messages.append("Calibration: using selected dark file.")
                } else {
                    // Validate BEFORE reporting active — else hasDark lies and the Calibrator skips it.
                    messages.append("Calibration: selected dark doesn't match these lights' size — skipping it.")
                }
            } catch {
                messages.append("Calibration: selected dark could not be read — \(error.localizedDescription).")
            }
        }

        // Session flat: build fresh from the chosen flats folder (offset = dark-flats else bias).
        // Build against the light's TARGET dimensions when known, so a stray wrong-size frame that
        // sorts first can't hijack the reference dimensions and discard the valid same-size flats.
        let targetDims: (width: Int, height: Int, channels: Int)? = {
            if let w = metadata.width, let h = metadata.height, let c = metadata.channels { return (w, h, c) }
            return nil
        }()
        var flatImage: AstroImage?
        if let flatsFolder {
            var offset = biasImage
            if let dfFolder = darkFlatsFolder {
                let dfURLs = CalibrationLibrary.fitsFiles(in: dfFolder)
                if dfURLs.isEmpty {
                    messages.append("Calibration: no dark-flats in that folder — using bias as the flat offset.")
                } else {
                    do { offset = try MasterBuilder.combineDetailed(fitsURLs: dfURLs, kind: .bias, bias: nil, expected: targetDims).image }
                    catch { messages.append("Calibration: dark-flats build failed — \(error.localizedDescription); using bias instead.") }
                }
            }
            let urls = CalibrationLibrary.fitsFiles(in: flatsFolder)
            if urls.isEmpty {
                messages.append("Calibration: no flats found in the flats folder — continuing without a flat.")
            } else {
                do {
                    let built = try MasterBuilder.combineDetailed(fitsURLs: urls, kind: .flat, bias: offset, expected: targetDims)
                    if dimensionsOK(built.image, metadata) {
                        flatImage = built.image
                        // Report the offset HONESTLY: a dimension-mismatched offset is silently skipped
                        // by the builder, so don't claim "subtracted" unless it actually was.
                        let offsetNote = built.offsetApplied ? " (offset subtracted)"
                            : (offset != nil ? " (offset skipped — size mismatch)" : "")
                        messages.append("Calibration: built master flat from \(built.contributingCount) flats\(offsetNote).")
                    } else {
                        // Validate the built flat's size against the lights before reporting hasFlat.
                        messages.append("Calibration: built flat doesn't match these lights' size — skipping the flat.")
                    }
                } catch {
                    messages.append("Calibration: flat build failed — \(error.localizedDescription); continuing without a flat.")
                }
            }
        } else if let p = legacyFlatPath {
            do {
                // Normalize legacy/external master flats (idempotent) so a non-normalized
                // file can't over/under-correct — matches the session-flat path.
                let img = MasterBuilder.normalizedFlat(try MasterBuilder.load(URL(fileURLWithPath: p)))
                if dimensionsOK(img, metadata) {
                    flatImage = img
                    messages.append("Calibration: using selected flat file.")
                } else {
                    messages.append("Calibration: selected flat doesn't match these lights' size — skipping it.")
                }
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

    /// A bias whose loaded shape fits `dark` (so scaling won't fail on a shape mismatch): the
    /// already-resolved bias if it fits, else any matching library bias whose loaded shape equals
    /// the dark's. Returns nil if none fit.
    private static func biasFitting(dark: AstroImage, light: SourceMetadata,
                                    library: CalibrationLibrary, preferred: AstroImage?) -> AstroImage? {
        func fits(_ img: AstroImage) -> Bool {
            img.width == dark.width && img.height == dark.height && img.channels == dark.channels
        }
        if let p = preferred, fits(p) { return p }
        for b in CalibrationMatcher.matchingBiases(light: light, library: library.all()) {
            if let img = library.master(for: b), fits(img) { return img }
        }
        return nil
    }

    static func describe(_ f: MasterFrame) -> String {
        // Int(_:) traps on a finite-but-huge Double; Int(exactly:) is nil out of range → safe format.
        func intStr(_ v: Double) -> String { Int(exactly: v.rounded()).map(String.init) ?? String(format: "%.2g", v) }
        var parts: [String] = []
        if let e = f.exposureSeconds { parts.append("\(intStr(e))s") }
        if let t = f.setTempC { parts.append("\(intStr(t))°C") }
        if let g = f.gain { parts.append("gain \(intStr(g))") }
        return "\(f.camera) dark" + (parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))")
    }
}
