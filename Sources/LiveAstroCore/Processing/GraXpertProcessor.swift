import Foundation

public struct GraXpertProcessor: Processor {
    private let executable: URL
    private let runner: ProcessRunner
    private let denoiseStrength: Double
    private let fileManager: FileManager
    public static let defaultTimeoutSeconds: TimeInterval = 30 * 60

    public init(executable: URL, runner: ProcessRunner? = nil,
                denoiseStrength: Double = 0.5, fileManager: FileManager = .default) {
        self.executable = executable
        self.runner = runner ?? FoundationProcessRunner(timeoutSeconds: Self.defaultTimeoutSeconds)
        self.denoiseStrength = denoiseStrength; self.fileManager = fileManager
    }

    public var name: String { "GraXpert" }
    public var isAvailable: Bool { fileManager.fileExists(atPath: executable.path) }

    public static func defaultExecutable(fileManager: FileManager = .default) -> URL? {
        let url = URL(fileURLWithPath: "/Applications/GraXpert.app/Contents/MacOS/GraXpert")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    public func process(masterURL: URL, outputURL: URL, log: ((String) -> Void)?) throws -> URL {
        guard isAvailable else { throw ProcessorError.notAvailable }
        let workOutputURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".graxpert-output-\(UUID().uuidString).fit")
        let bgTmp = outputURL.deletingLastPathComponent()
            .appendingPathComponent("graxpert-bg-\(UUID().uuidString).fits")
        defer {
            for url in outputVariants(for: bgTmp) {
                try? fileManager.removeItem(at: url)
            }
            for url in outputVariants(for: workOutputURL) {
                try? fileManager.removeItem(at: url)
            }
        }

        let bgArgs = ["-cli", "-cmd", "background-extraction", "-gpu", "false",
                      "-output", bgTmp.path, masterURL.path]
        let c1 = try runner.run(executable: executable, arguments: bgArgs, log: log)
        guard c1 == 0 else { throw ProcessorError.stepFailed(cmd: "background-extraction", code: c1) }
        guard let bgOutput = firstExistingOutput(for: bgTmp) else { throw ProcessorError.noOutput }

        let strength = String(format: "%g", denoiseStrength)   // 0.5 -> "0.5"
        let dnArgs = ["-cli", "-cmd", "denoising", "-strength", strength, "-gpu", "false",
                      "-output", workOutputURL.path, bgOutput.path]
        let c2 = try runner.run(executable: executable, arguments: dnArgs, log: log)
        guard c2 == 0 else { throw ProcessorError.stepFailed(cmd: "denoising", code: c2) }

        guard let produced = firstExistingOutput(for: workOutputURL) else {
            throw ProcessorError.noOutput
        }
        let finalProduced: URL
        if produced.path == workOutputURL.path + ".fits" {
            finalProduced = URL(fileURLWithPath: outputURL.path + ".fits")
        } else if produced.path == workOutputURL.deletingPathExtension()
            .appendingPathExtension("fits").path {
            finalProduced = outputURL.deletingPathExtension().appendingPathExtension("fits")
        } else {
            finalProduced = outputURL
        }
        for url in outputVariants(for: outputURL) {
            try? fileManager.removeItem(at: url)
        }
        try fileManager.moveItem(at: produced, to: finalProduced)
        return finalProduced
    }

    private func firstExistingOutput(for requested: URL) -> URL? {
        outputVariants(for: requested).first { fileManager.fileExists(atPath: $0.path) }
    }

    private func outputVariants(for requested: URL) -> [URL] {
        var variants = [requested]
        let replaced = requested.deletingPathExtension().appendingPathExtension("fits")
        if replaced.path != requested.path { variants.append(replaced) }
        let appended = URL(fileURLWithPath: requested.path + ".fits")
        if !variants.contains(appended) { variants.append(appended) }
        return variants
    }
}
