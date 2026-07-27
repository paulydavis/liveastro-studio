import Foundation
import Darwin

/// Abstraction over launching an external process. The real implementation
/// uses Foundation `Process`; tests inject a fake that records commands.
public protocol ProcessRunner {
    /// Run `executable` with `arguments`, forwarding merged stdout/stderr lines to
    /// `log`. Returns the process exit code. Throws if the process cannot launch.
    func run(executable: URL, arguments: [String], log: ((String) -> Void)?) throws -> Int32
}

public enum ProcessRunnerError: Error, Equatable {
    case timedOut(seconds: TimeInterval)
}

public struct FoundationProcessRunner: ProcessRunner {
    public let timeoutSeconds: TimeInterval
    public let terminationGraceSeconds: TimeInterval

    public init(timeoutSeconds: TimeInterval = 60, terminationGraceSeconds: TimeInterval = 2) {
        self.timeoutSeconds = timeoutSeconds
        self.terminationGraceSeconds = terminationGraceSeconds
    }

    public func run(executable: URL, arguments: [String], log: ((String) -> Void)?) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let log else { return }   // still drain when logs are disabled
            let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "«non-UTF-8 output»"
            s.split(separator: "\n").forEach { log(String($0)) }
        }
        defer {
            handle.readabilityHandler = nil
            try? handle.close()
        }
        let finished = DispatchSemaphore(value: 0)
        let waiter = DispatchQueue(label: "LiveAstro.ProcessRunner.wait")
        var waitStarted = false
        func waitForExit() {
            guard !waitStarted else { return }
            waitStarted = true
            waiter.async {
                process.waitUntilExit()
                finished.signal()
            }
        }
        try process.run()
        waitForExit()
        if finished.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            if finished.wait(timeout: .now() + terminationGraceSeconds) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            throw ProcessRunnerError.timedOut(seconds: timeoutSeconds)
        }
        // Drain any bytes the async handler didn't deliver (process has exited; no block risk).
        if let log {
            let tail = handle.readDataToEndOfFile()
            if !tail.isEmpty {
                let s = String(data: tail, encoding: .utf8) ?? String(data: tail, encoding: .isoLatin1) ?? "«non-UTF-8 output»"
                s.split(separator: "\n").forEach { log(String($0)) }
            }
        }
        return process.terminationStatus
    }
}
