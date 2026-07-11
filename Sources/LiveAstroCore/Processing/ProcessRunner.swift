import Foundation

/// Abstraction over launching an external process. The real implementation
/// uses Foundation `Process`; tests inject a fake that records commands.
public protocol ProcessRunner {
    /// Run `executable` with `arguments`, forwarding merged stdout/stderr lines to
    /// `log`. Returns the process exit code. Throws if the process cannot launch.
    func run(executable: URL, arguments: [String], log: ((String) -> Void)?) throws -> Int32
}

public struct FoundationProcessRunner: ProcessRunner {
    public init() {}
    public func run(executable: URL, arguments: [String], log: ((String) -> Void)?) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        if let log {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty, let s = String(data: data, encoding: .utf8) {
                    s.split(separator: "\n").forEach { log(String($0)) }
                }
            }
        }
        try process.run()
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        return process.terminationStatus
    }
}
