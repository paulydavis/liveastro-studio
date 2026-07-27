import Foundation

/// A pluggable post-stack image processor (background extraction, denoising, …).
public protocol Processor {
    var name: String { get }
    /// True when the backend can actually run (e.g. its tool is installed).
    var isAvailable: Bool { get }
    /// Read `masterURL`, write the processed result requested at `outputURL`.
    /// Returns the actual output path, which may differ when a backend appends
    /// or replaces the file extension.
    func process(masterURL: URL, outputURL: URL, log: ((String) -> Void)?) throws -> URL
}

/// User-selectable processing backend.
public enum ProcessorBackend: String, CaseIterable, Codable {
    case none, graxpert
}

public enum ProcessorError: Error, Equatable {
    case notAvailable
    case stepFailed(cmd: String, code: Int32)
    case noOutput
}
