import Foundation

/// Master-path consumer of `Denoiser` (spec §2.3): reads the linear master via
/// `readLinear`, runs the same two stages in linear domain (the engine picks the
/// linear-domain constants from `sourceIsLinear` — plan finding F3), and writes
/// the result through the existing writer with the temp+rename no-partial-files
/// pattern (the GraXpert-fix precedent). Always available — gives users without
/// GraXpert a denoise option. `master.fit` is never mutated.
public struct NativeDenoiseProcessor: Processor {
    private let strength: Float
    private let fileManager: FileManager

    public init(strength: Float = 0.5, fileManager: FileManager = .default) {
        self.strength = strength
        self.fileManager = fileManager
    }

    public var name: String { "Native NR" }
    public var isAvailable: Bool { true }

    public func process(masterURL: URL, outputURL: URL, log: ((String) -> Void)?) throws -> URL {
        let data = try Data(contentsOf: masterURL)
        let fits = try FITSReader.readLinear(data)
        let header = try FITSReader.readHeader(data)
        log?("Native NR: \(fits.width)x\(fits.height)x\(fits.channels), strength \(strength)")

        let image = AstroImage(width: fits.width, height: fits.height,
                               channels: fits.channels, pixels: fits.pixels,
                               sourceIsLinear: true)                    // linear-domain mapping
        let denoised = Denoiser.apply(image, strength: strength)

        // Propagate the master's astronomical metadata + stack provenance.
        let metadata = SourceMetadata(fitsKeywords: header.keywords)
        let stackCount = header.keywords["STACKCNT"].flatMap { Int($0) }
        let totalExp = header.keywords["TOTALEXP"].flatMap { Double($0) }
        let out = FITSWriter.float32(width: denoised.width, height: denoised.height,
                                     channels: denoised.channels, pixels: denoised.pixels,
                                     metadata: metadata, stackCount: stackCount,
                                     totalExposureSeconds: totalExp)

        // Temp + rename: no partial master_processed.fit is ever observable.
        let tmp = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".native-denoise-\(UUID().uuidString).fit")
        do {
            try out.write(to: tmp)
            if fileManager.fileExists(atPath: outputURL.path) {
                try fileManager.removeItem(at: outputURL)
            }
            try fileManager.moveItem(at: tmp, to: outputURL)
        } catch {
            try? fileManager.removeItem(at: tmp)
            throw error
        }
        log?("Native NR: wrote \(outputURL.lastPathComponent)")
        return outputURL
    }
}
