import Foundation

public struct GraXpertProcessor: Processor {
    private let executable: URL
    private let runner: ProcessRunner
    private let denoiseStrength: Double
    private let fileManager: FileManager

    public init(executable: URL, runner: ProcessRunner = FoundationProcessRunner(),
                denoiseStrength: Double = 0.5, fileManager: FileManager = .default) {
        self.executable = executable; self.runner = runner
        self.denoiseStrength = denoiseStrength; self.fileManager = fileManager
    }

    public var name: String { "GraXpert" }
    public var isAvailable: Bool { fileManager.fileExists(atPath: executable.path) }

    public static func defaultExecutable(fileManager: FileManager = .default) -> URL? {
        let url = URL(fileURLWithPath: "/Applications/GraXpert.app/Contents/MacOS/GraXpert")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    public func process(masterURL: URL, outputURL: URL, log: ((String) -> Void)?) throws {
        guard isAvailable else { throw ProcessorError.notAvailable }
        let bgTmp = outputURL.deletingLastPathComponent()
            .appendingPathComponent("._graxpert_bg_\(UUID().uuidString).fits")
        defer { try? fileManager.removeItem(at: bgTmp) }

        let bgArgs = ["-cli", "-cmd", "background-extraction", "-gpu", "false",
                      "-output", bgTmp.path, masterURL.path]
        let c1 = try runner.run(executable: executable, arguments: bgArgs, log: log)
        guard c1 == 0 else { throw ProcessorError.stepFailed(cmd: "background-extraction", code: c1) }

        let strength = String(format: "%g", denoiseStrength)   // 0.5 -> "0.5"
        let dnArgs = ["-cli", "-cmd", "denoising", "-strength", strength, "-gpu", "false",
                      "-output", outputURL.path, bgTmp.path]
        let c2 = try runner.run(executable: executable, arguments: dnArgs, log: log)
        guard c2 == 0 else { throw ProcessorError.stepFailed(cmd: "denoising", code: c2) }

        let altOutput = outputURL.deletingPathExtension().appendingPathExtension("fits")
        guard fileManager.fileExists(atPath: outputURL.path) || fileManager.fileExists(atPath: altOutput.path) else {
            throw ProcessorError.noOutput
        }
    }
}
