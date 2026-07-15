import Foundation

/// Handshake-gated file producer for the growing/partial-write matrix cells.
///
/// Deliberately SYNCHRONOUS: `writeChunk`/`truncate` append and flush before returning, so the
/// file size on disk reflects the call immediately. Coordination with relay/watcher ticks is the
/// TEST's job — the test interleaves these synchronous calls with tick calls explicitly, which is
/// exactly the "barriers/semaphores, not timing guesses" rule: there is no timing here at all, the
/// ordering is the program order of the test body.
final class CoordinatedWriter {
    private let url: URL
    private let handle: FileHandle

    init(url: URL) {
        // Create an empty file, then open for writing. Force-unwrap/try! is acceptable in a test
        // helper: a failure here is a broken test environment, not a condition under test.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.url = url
        self.handle = try! FileHandle(forWritingTo: url)
    }

    /// Append `data` and flush so it is durably visible to another reader/process synchronously.
    func writeChunk(_ data: Data) {
        try! handle.seekToEnd()
        try! handle.write(contentsOf: data)
        try! handle.synchronize()
    }

    /// Truncate the file to `bytes` and flush — models truncate-then-continue.
    func truncate(to bytes: Int) {
        try! handle.truncate(atOffset: UInt64(bytes))
        try! handle.synchronize()
    }

    func close() {
        try? handle.close()
    }
}
