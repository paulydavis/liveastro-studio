import Foundation

/// Data-parallel helpers for pixel-O(N) loops. Splits a row range into
/// contiguous bands run concurrently across cores; each band writes disjoint
/// output rows, so no locks are needed. Callers stay byte-identical to a serial
/// loop because every output element is written by exactly one band.
enum Parallel {
    /// Run `body` over contiguous row bands of `[0, height)` concurrently. Below
    /// `minRows` rows (or on a single-core machine) runs a single serial band —
    /// avoids GCD overhead on small/test images. Blocks until all bands finish.
    /// `body` receives a half-open row range and must write only rows in it.
    static func rows(_ height: Int, minRows: Int = 64, _ body: (Range<Int>) -> Void) {
        guard height > 0 else { return }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        if height < minRows || cores <= 1 {
            body(0..<height)
            return
        }
        let bandCount = min(cores, height)
        DispatchQueue.concurrentPerform(iterations: bandCount) { b in
            let lo = b * height / bandCount
            let hi = (b + 1) * height / bandCount
            if lo < hi { body(lo..<hi) }
        }
    }
}
