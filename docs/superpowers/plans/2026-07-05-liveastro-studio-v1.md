# LiveAstro Studio v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS app that watches Siril live-stack output, shows it in an OBS-friendly broadcast window, records per-update snapshots, and auto-generates a 45-second stack-evolution MP4 at session end.

**Architecture:** Swift Package with a UI-free `LiveAstroCore` library (FITS reader, autostretch, watcher, session, replay — all TDD via `swift test`) plus a thin SwiftUI executable `LiveAstroStudio` (control window + 1920×1080 broadcast window). A `fakesiril` executable simulates Siril for dev/e2e. Video via AVFoundation `AVAssetWriter` — no ffmpeg.

**Tech Stack:** Swift 5.10 tools / Swift 6 toolchain, SwiftUI, AVFoundation, CoreGraphics/ImageIO, CryptoKit, XCTest. Zero external SPM dependencies.

**Spec:** `docs/superpowers/specs/2026-07-05-liveastro-studio-v1-design.md` (approved 2026-07-05).

## Global Constraints

- Platform floor: **macOS 14** (`platforms: [.macOS(.v14)]`).
- **Zero external SPM dependencies.** No ffmpeg — AVFoundation only.
- All logic lives in `LiveAstroCore` (imports Foundation/CoreGraphics/ImageIO/AVFoundation/AppKit-for-text-only; **no SwiftUI**). App target stays thin.
- FITS reader scope (spec §5.3): SIMPLE conforming, single primary HDU, `BITPIX ∈ {8, 16, 32, -32, -64}`, `NAXIS ∈ {2, 3}` (NAXIS3 must be 3), honors `BSCALE`/`BZERO` and `ROWORDER`, big-endian data. Anything else → typed error.
- Broadcast window: fixed 1920×1080 content, dark, non-interactive, never blanks on error (spec §5.6, §7).
- Replay default: 45 s, 30 fps, 1920×1080, H.264 MP4 (spec §5.8).
- Session storage root: `~/Documents/LiveAstro/<session-id>/` (spec §6). Manifest JSON keys are snake_case, dates ISO8601 (spec §6 example).
- Every commit: `swift test` green. Work on branch `feature/v1-spec`. Never commit to main. Commit trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` is allowed in this repo.
- All commands run from repo root: `/Users/pauldavis/Desktop/liveastro-studio`.

## File Map

```
Package.swift
Sources/LiveAstroCore/
  FITS/FITSTypes.swift        # FITSHeader, FITSImage, FITSError
  FITS/FITSReader.swift       # header parse + data decode
  FITS/FITSWriter.swift       # minimal float32 writer (tests + fakesiril)
  Imaging/AstroImage.swift    # AstroImage, ChannelStats, stats computation
  Imaging/ImageLoader.swift   # FITS + ImageIO dispatch
  Imaging/AutoStretch.swift   # MTF autostretch + CGImage packing
  Watch/StackFileWatcher.swift
  Session/SessionModels.swift # SessionProfile, SnapshotRecord, SessionManifest, JSON coding, caption formatting
  Session/SessionManager.swift
  Session/SnapshotRecorder.swift
  Replay/FrameSelector.swift
  Replay/ReplayGenerator.swift
  Pipeline/SessionPipeline.swift
Sources/LiveAstroStudio/
  LiveAstroApp.swift
  AppModel.swift
  ControlView.swift
  BroadcastView.swift
Sources/fakesiril/main.swift
Tests/LiveAstroCoreTests/
  FITSReaderTests.swift
  AstroImageTests.swift
  ImageLoaderTests.swift
  AutoStretchTests.swift
  StackFileWatcherTests.swift
  SessionManagerTests.swift
  SnapshotRecorderTests.swift
  FrameSelectorTests.swift
  ReplayGeneratorTests.swift
  EndToEndTests.swift
docs/validation/obs-youtube-checklist.md
```

---

### Task 1: Package Scaffold

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/LiveAstroCore/Placeholder.swift`, `Sources/LiveAstroStudio/main.swift` (temporary), `Tests/LiveAstroCoreTests/ScaffoldTests.swift`

**Interfaces:**
- Produces: buildable package `LiveAstroCore` (library), `LiveAstroStudio` (executable), test target. Later tasks add files to these targets; nothing else changes `Package.swift` until Task 12 adds `fakesiril`.

- [ ] **Step 1: Write Package.swift and .gitignore**

`Package.swift`:
```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LiveAstroStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LiveAstroCore"),
        .executableTarget(name: "LiveAstroStudio", dependencies: ["LiveAstroCore"]),
        .testTarget(name: "LiveAstroCoreTests", dependencies: ["LiveAstroCore"]),
    ]
)
```

`.gitignore`:
```
.build/
.DS_Store
xcuserdata/
*.xcodeproj
DerivedData/
```

- [ ] **Step 2: Add minimal sources so all targets compile**

`Sources/LiveAstroCore/Placeholder.swift`:
```swift
// Removed once real modules land (Task 2+).
public enum LiveAstroCore {
    public static let version = "0.1.0"
}
```

`Sources/LiveAstroStudio/main.swift`:
```swift
import LiveAstroCore
print("LiveAstro Studio scaffold — core \(LiveAstroCore.version)")
```

`Tests/LiveAstroCoreTests/ScaffoldTests.swift`:
```swift
import XCTest
@testable import LiveAstroCore

final class ScaffoldTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(LiveAstroCore.version, "0.1.0")
    }
}
```

- [ ] **Step 3: Verify build + test**

Run: `swift build && swift test`
Expected: build succeeds; 1 test passes.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "chore: SPM scaffold — core lib, app executable, test target

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: FITS Reader + Writer

**Files:**
- Create: `Sources/LiveAstroCore/FITS/FITSTypes.swift`, `Sources/LiveAstroCore/FITS/FITSReader.swift`, `Sources/LiveAstroCore/FITS/FITSWriter.swift`
- Test: `Tests/LiveAstroCoreTests/FITSReaderTests.swift`
- Delete: `Sources/LiveAstroCore/Placeholder.swift` and `ScaffoldTests.swift` (move `version` nowhere — drop it)

**Interfaces:**
- Produces:
  - `struct FITSHeader { bitpix: Int; dims: [Int]; bscale: Double; bzero: Double; bottomUp: Bool; headerBytes: Int; width/height/channels: Int; dataBytes: Int; minimumFileSize: Int }`
  - `struct FITSImage { width: Int; height: Int; channels: Int; pixels: [Float] /* planar, top-down, 0…1 */ }`
  - `enum FITSError: Error, Equatable { notFITS, truncatedHeader, truncatedData(expected: Int, actual: Int), unsupported(String), malformedHeader(String) }`
  - `enum FITSReader { static func readHeader(_ data: Data) throws -> FITSHeader; static func read(_ data: Data) throws -> FITSImage }`
  - `enum FITSWriter { static func float32(width: Int, height: Int, channels: Int, pixels: [Float], bottomUp: Bool = false) -> Data }`
- Consumers: Task 3 (ImageLoader loads via FITSReader), Task 5 (watcher uses `readHeader(...).minimumFileSize` for completeness), Task 12 (fakesiril uses FITSWriter).

- [ ] **Step 1: Write failing tests**

`Tests/LiveAstroCoreTests/FITSReaderTests.swift`:
```swift
import XCTest
@testable import LiveAstroCore

final class FITSReaderTests: XCTestCase {

    func testRejectsNonFITS() {
        XCTAssertThrowsError(try FITSReader.readHeader(Data(repeating: 0x41, count: 2880))) {
            XCTAssertEqual($0 as? FITSError, .notFITS)
        }
    }

    func testTruncatedHeaderThrows() {
        let full = FITSWriter.float32(width: 4, height: 4, channels: 1,
                                      pixels: [Float](repeating: 0.5, count: 16))
        XCTAssertThrowsError(try FITSReader.readHeader(full.prefix(100))) {
            XCTAssertEqual($0 as? FITSError, .truncatedHeader)
        }
    }

    func testFloat32RoundTripMono() throws {
        let px: [Float] = (0..<16).map { Float($0) / 15.0 }
        let data = FITSWriter.float32(width: 4, height: 4, channels: 1, pixels: px)
        let img = try FITSReader.read(data)
        XCTAssertEqual(img.width, 4); XCTAssertEqual(img.height, 4); XCTAssertEqual(img.channels, 1)
        for (a, b) in zip(img.pixels, px) { XCTAssertEqual(a, b, accuracy: 1e-6) }
    }

    func testFloat32RoundTripRGB() throws {
        let px = [Float](repeating: 0.25, count: 2 * 2 * 3)
        let data = FITSWriter.float32(width: 2, height: 2, channels: 3, pixels: px)
        let img = try FITSReader.read(data)
        XCTAssertEqual(img.channels, 3)
        XCTAssertEqual(img.pixels.count, 12)
    }

    func testBottomUpRowsAreFlipped() throws {
        // 2x2, values row-major top-down: [0,1, 2,3]. Written bottom-up they are stored [2,3, 0,1].
        let data = FITSWriter.float32(width: 2, height: 2, channels: 1,
                                      pixels: [0, 1, 2, 3], bottomUp: true)
        let img = try FITSReader.read(data)
        XCTAssertEqual(img.pixels, [0, 1, 2, 3]) // reader restores top-down
    }

    func testInt16WithBZeroNormalizes() throws {
        // Siril unsigned-16 convention: BZERO=32768. Raw -32768 -> physical 0 -> 0.0; raw 32767 -> 65535 -> ~1.0
        var data = FITSTestBuilder.header(cards: [
            ("SIMPLE", "T"), ("BITPIX", "16"), ("NAXIS", "2"),
            ("NAXIS1", "2"), ("NAXIS2", "1"), ("BZERO", "32768"), ("BSCALE", "1"),
        ])
        for raw in [Int16.min, Int16.max] {
            var be = raw.bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        }
        data.append(Data(repeating: 0, count: 2880 - 4)) // pad data block
        let img = try FITSReader.read(data)
        XCTAssertEqual(img.pixels[0], 0.0, accuracy: 1e-4)
        XCTAssertEqual(img.pixels[1], 1.0, accuracy: 1e-4)
    }

    func testUnsupportedBitpixThrows() {
        let data = FITSTestBuilder.header(cards: [
            ("SIMPLE", "T"), ("BITPIX", "64"), ("NAXIS", "2"), ("NAXIS1", "1"), ("NAXIS2", "1"),
        ])
        XCTAssertThrowsError(try FITSReader.readHeader(data)) {
            XCTAssertEqual($0 as? FITSError, .unsupported("BITPIX 64"))
        }
    }

    func testMinimumFileSizeAndTruncatedData() throws {
        let px = [Float](repeating: 0, count: 100 * 100)
        let data = FITSWriter.float32(width: 100, height: 100, channels: 1, pixels: px)
        let h = try FITSReader.readHeader(data)
        XCTAssertEqual(h.minimumFileSize, h.headerBytes + 100 * 100 * 4)
        XCTAssertThrowsError(try FITSReader.read(data.prefix(h.minimumFileSize - 1)))
    }
}

/// Builds raw FITS headers for edge-case tests (FITSWriter covers the happy path).
enum FITSTestBuilder {
    static func card(_ key: String, _ value: String) -> String {
        let k = key.padding(toLength: 8, withPad: " ", startingAt: 0)
        return "\(k)= \(value)".padding(toLength: 80, withPad: " ", startingAt: 0)
    }
    static func header(cards: [(String, String)]) -> Data {
        var s = cards.map { card($0.0, $0.1) }.joined()
        s += "END".padding(toLength: 80, withPad: " ", startingAt: 0)
        while s.count % 2880 != 0 { s += String(repeating: " ", count: 80) }
        return s.data(using: .ascii)!
    }
}
```

- [ ] **Step 2: Run tests — expect compile failure (types don't exist)**

Run: `swift test 2>&1 | tail -5` — Expected: FAIL, `cannot find 'FITSWriter'` etc.

- [ ] **Step 3: Implement types, reader, writer**

`Sources/LiveAstroCore/FITS/FITSTypes.swift`:
```swift
import Foundation

public struct FITSHeader: Equatable {
    public let bitpix: Int
    public let dims: [Int]          // [NAXIS1, NAXIS2] or [NAXIS1, NAXIS2, 3]
    public let bscale: Double
    public let bzero: Double
    public let bottomUp: Bool       // ROWORDER, FITS default is bottom-up
    public let headerBytes: Int

    public var width: Int { dims[0] }
    public var height: Int { dims[1] }
    public var channels: Int { dims.count == 3 ? dims[2] : 1 }
    public var dataBytes: Int { dims.reduce(1, *) * abs(bitpix) / 8 }
    /// Watcher completeness check: file must be at least this many bytes.
    public var minimumFileSize: Int { headerBytes + dataBytes }
}

public struct FITSImage: Equatable {
    public let width: Int
    public let height: Int
    public let channels: Int
    /// Planar (channel-major), row-major top-down within each plane, normalized 0…1.
    public let pixels: [Float]
}

public enum FITSError: Error, Equatable {
    case notFITS
    case truncatedHeader
    case truncatedData(expected: Int, actual: Int)
    case unsupported(String)
    case malformedHeader(String)
}
```

`Sources/LiveAstroCore/FITS/FITSReader.swift`:
```swift
import Foundation

public enum FITSReader {

    public static func readHeader(_ data: Data) throws -> FITSHeader {
        guard data.count >= 6, String(data: data.prefix(6), encoding: .ascii) == "SIMPLE" else {
            if data.count < 2880 { throw data.prefix(6).elementsEqual("SIMPLE".utf8) ? FITSError.truncatedHeader : FITSError.notFITS }
            throw FITSError.notFITS
        }
        var cards: [String: String] = [:]
        var headerBytes: Int?
        var block = 0
        while headerBytes == nil {
            let base = block * 2880
            guard base + 2880 <= data.count else { throw FITSError.truncatedHeader }
            for i in 0..<36 {
                let start = base + i * 80
                guard let card = String(data: data.subdata(in: start..<(start + 80)), encoding: .ascii) else {
                    throw FITSError.malformedHeader("non-ASCII card at byte \(start)")
                }
                let key = String(card.prefix(8)).trimmingCharacters(in: .whitespaces)
                if key == "END" { headerBytes = base + 2880; break }
                let idx8 = card.index(card.startIndex, offsetBy: 8)
                if card[idx8...].hasPrefix("= ") {
                    let raw = String(card[card.index(idx8, offsetBy: 2)...])
                    let value = raw.split(separator: "/", maxSplits: 1)[0]
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                        .trimmingCharacters(in: .whitespaces)
                    cards[key] = value
                }
            }
            block += 1
        }

        func intValue(_ key: String) throws -> Int {
            guard let s = cards[key], let v = Int(s) else { throw FITSError.malformedHeader("missing/bad \(key)") }
            return v
        }

        let bitpix = try intValue("BITPIX")
        guard [8, 16, 32, -32, -64].contains(bitpix) else { throw FITSError.unsupported("BITPIX \(bitpix)") }
        let naxis = try intValue("NAXIS")
        guard naxis == 2 || naxis == 3 else { throw FITSError.unsupported("NAXIS \(naxis)") }
        var dims = [try intValue("NAXIS1"), try intValue("NAXIS2")]
        if naxis == 3 {
            let c = try intValue("NAXIS3")
            guard c == 3 else { throw FITSError.unsupported("NAXIS3 \(c) (expected 3)") }
            dims.append(c)
        }
        guard dims[0] > 0, dims[1] > 0 else { throw FITSError.malformedHeader("non-positive dimensions") }
        let bscale = cards["BSCALE"].flatMap(Double.init) ?? 1
        let bzero = cards["BZERO"].flatMap(Double.init) ?? 0
        let bottomUp = (cards["ROWORDER"] ?? "BOTTOM-UP").uppercased() != "TOP-DOWN"
        return FITSHeader(bitpix: bitpix, dims: dims, bscale: bscale, bzero: bzero,
                          bottomUp: bottomUp, headerBytes: headerBytes!)
    }

    public static func read(_ data: Data) throws -> FITSImage {
        let h = try readHeader(data)
        guard data.count >= h.minimumFileSize else {
            throw FITSError.truncatedData(expected: h.minimumFileSize, actual: data.count)
        }
        let raw = data.subdata(in: h.headerBytes..<(h.headerBytes + h.dataBytes))
        let n = h.dims.reduce(1, *)
        var px = [Float](repeating: 0, count: n)

        func physical(_ v: Double) -> Double { h.bzero + h.bscale * v }

        raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            switch h.bitpix {
            case 8:
                for i in 0..<n { px[i] = Float(physical(Double(buf[i])) / 255.0) }
            case 16:
                let p = buf.bindMemory(to: Int16.self)
                for i in 0..<n { px[i] = Float(physical(Double(Int16(bigEndian: p[i]))) / 65535.0) }
            case 32:
                let p = buf.bindMemory(to: Int32.self)
                for i in 0..<n { px[i] = Float(physical(Double(Int32(bigEndian: p[i]))) / 4294967295.0) }
            case -32:
                let p = buf.bindMemory(to: UInt32.self)
                for i in 0..<n { px[i] = Float(physical(Double(Float(bitPattern: UInt32(bigEndian: p[i]))))) }
            case -64:
                let p = buf.bindMemory(to: UInt64.self)
                for i in 0..<n { px[i] = Float(physical(Double(bitPattern: UInt64(bigEndian: p[i])))) }
            default:
                preconditionFailure("validated in readHeader")
            }
        }
        for i in 0..<n { px[i] = min(max(px[i], 0), 1) }

        if h.bottomUp {
            let plane = h.width * h.height
            for c in 0..<h.channels {
                for row in 0..<(h.height / 2) {
                    let a = c * plane + row * h.width
                    let b = c * plane + (h.height - 1 - row) * h.width
                    for col in 0..<h.width { px.swapAt(a + col, b + col) }
                }
            }
        }
        return FITSImage(width: h.width, height: h.height, channels: h.channels, pixels: px)
    }
}
```

`Sources/LiveAstroCore/FITS/FITSWriter.swift`:
```swift
import Foundation

/// Minimal FITS writer: float32, mono or 3-channel. Used by tests and fakesiril.
public enum FITSWriter {

    public static func float32(width: Int, height: Int, channels: Int,
                               pixels: [Float], bottomUp: Bool = false) -> Data {
        precondition(pixels.count == width * height * channels)
        precondition(channels == 1 || channels == 3)

        func card(_ key: String, _ value: String) -> String {
            let k = key.padding(toLength: 8, withPad: " ", startingAt: 0)
            return "\(k)= \(value)".padding(toLength: 80, withPad: " ", startingAt: 0)
        }
        var cards = [card("SIMPLE", "T"), card("BITPIX", "-32"),
                     card("NAXIS", channels == 1 ? "2" : "3"),
                     card("NAXIS1", "\(width)"), card("NAXIS2", "\(height)")]
        if channels == 3 { cards.append(card("NAXIS3", "3")) }
        cards.append(card("ROWORDER", bottomUp ? "'BOTTOM-UP'" : "'TOP-DOWN'"))
        var s = cards.joined() + "END".padding(toLength: 80, withPad: " ", startingAt: 0)
        while s.count % 2880 != 0 { s += String(repeating: " ", count: 80) }
        var data = s.data(using: .ascii)!

        let plane = width * height
        for c in 0..<channels {
            for row in 0..<height {
                let srcRow = bottomUp ? (height - 1 - row) : row
                for col in 0..<width {
                    var be = pixels[c * plane + srcRow * width + col].bitPattern.bigEndian
                    withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
                }
            }
        }
        while data.count % 2880 != 0 { data.append(0) }
        return data
    }
}
```

Delete `Sources/LiveAstroCore/Placeholder.swift`, `Tests/LiveAstroCoreTests/ScaffoldTests.swift`, and replace `Sources/LiveAstroStudio/main.swift` contents with:
```swift
import LiveAstroCore
print("LiveAstro Studio — GUI arrives in Task 11")
```

- [ ] **Step 4: Run tests — expect all pass**

Run: `swift test 2>&1 | tail -3` — Expected: `Test Suite 'All tests' passed`, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: FITS reader (BITPIX 8/16/32/-32/-64, NAXIS 2/3, BSCALE/BZERO, ROWORDER) + minimal float32 writer

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: AstroImage, Stats, ImageLoader

**Files:**
- Create: `Sources/LiveAstroCore/Imaging/AstroImage.swift`, `Sources/LiveAstroCore/Imaging/ImageLoader.swift`
- Test: `Tests/LiveAstroCoreTests/AstroImageTests.swift`, `Tests/LiveAstroCoreTests/ImageLoaderTests.swift`

**Interfaces:**
- Consumes: `FITSReader.read`, `FITSImage`.
- Produces:
  - `struct ChannelStats: Codable, Equatable { mean: Double; median: Double; stddev: Double }`
  - `struct AstroImage { width: Int; height: Int; channels: Int; pixels: [Float] /* planar top-down 0…1 */; sourceIsLinear: Bool; stats: [ChannelStats] }`
  - `AstroImage.init(width:height:channels:pixels:sourceIsLinear:)` — computes stats (stride-sampled ≤ 262144 samples/channel).
  - `enum ImageLoaderError: Error { unsupportedFormat(String), decodeFailed(String) }`
  - `enum ImageLoader { static let fitsExtensions: Set<String>; static func load(url: URL) throws -> AstroImage }`
- Consumers: Task 4 (AutoStretch input), Task 10 (pipeline), Task 8 (thumbnails).

- [ ] **Step 1: Write failing tests**

`Tests/LiveAstroCoreTests/AstroImageTests.swift`:
```swift
import XCTest
@testable import LiveAstroCore

final class AstroImageTests: XCTestCase {
    func testStatsUniform() {
        let img = AstroImage(width: 10, height: 10, channels: 1,
                             pixels: [Float](repeating: 0.5, count: 100), sourceIsLinear: true)
        XCTAssertEqual(img.stats[0].mean, 0.5, accuracy: 1e-6)
        XCTAssertEqual(img.stats[0].median, 0.5, accuracy: 1e-6)
        XCTAssertEqual(img.stats[0].stddev, 0.0, accuracy: 1e-6)
    }
    func testStatsPerChannel() {
        var px = [Float](repeating: 0.1, count: 4)   // channel 0
        px += [Float](repeating: 0.9, count: 4)       // channel 1
        px += [Float](repeating: 0.5, count: 4)       // channel 2
        let img = AstroImage(width: 2, height: 2, channels: 3, pixels: px, sourceIsLinear: true)
        XCTAssertEqual(img.stats[0].mean, 0.1, accuracy: 1e-6)
        XCTAssertEqual(img.stats[1].mean, 0.9, accuracy: 1e-6)
        XCTAssertEqual(img.stats[2].mean, 0.5, accuracy: 1e-6)
    }
    func testMedianOddSpread() {
        let img = AstroImage(width: 5, height: 1, channels: 1,
                             pixels: [0.0, 0.1, 0.2, 0.9, 1.0], sourceIsLinear: true)
        XCTAssertEqual(img.stats[0].median, 0.2, accuracy: 1e-6)
    }
}
```

`Tests/LiveAstroCoreTests/ImageLoaderTests.swift`:
```swift
import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LiveAstroCore

final class ImageLoaderTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ilt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testLoadsFITSAsLinear() throws {
        let url = tmp.appendingPathComponent("stack.fit")
        try FITSWriter.float32(width: 4, height: 4, channels: 1,
                               pixels: [Float](repeating: 0.25, count: 16)).write(to: url)
        let img = try ImageLoader.load(url: url)
        XCTAssertTrue(img.sourceIsLinear)
        XCTAssertEqual(img.width, 4)
        XCTAssertEqual(img.stats[0].mean, 0.25, accuracy: 1e-4)
    }

    func testLoadsPNGAsDisplayReady() throws {
        let url = tmp.appendingPathComponent("stack.png")
        try writePNG(to: url, gray: 128, width: 8, height: 8)
        let img = try ImageLoader.load(url: url)
        XCTAssertFalse(img.sourceIsLinear)
        XCTAssertEqual(img.channels, 3)
        XCTAssertEqual(img.stats[0].mean, 128.0 / 255.0, accuracy: 0.02)
    }

    func testUnsupportedExtensionThrows() {
        XCTAssertThrowsError(try ImageLoader.load(url: tmp.appendingPathComponent("x.xisf")))
    }

    private func writePNG(to url: URL, gray: UInt8, width: Int, height: Int) throws {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let g = CGFloat(gray) / 255.0
        ctx.setFillColor(CGColor(red: g, green: g, blue: g, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }
}
```

- [ ] **Step 2: Run — expect compile failure.** `swift test 2>&1 | tail -3`

- [ ] **Step 3: Implement**

`Sources/LiveAstroCore/Imaging/AstroImage.swift`:
```swift
import Foundation

public struct ChannelStats: Codable, Equatable {
    public let mean: Double
    public let median: Double
    public let stddev: Double
    public init(mean: Double, median: Double, stddev: Double) {
        self.mean = mean; self.median = median; self.stddev = stddev
    }
}

public struct AstroImage {
    public let width: Int
    public let height: Int
    public let channels: Int
    /// Planar (channel-major), row-major top-down, 0…1.
    public let pixels: [Float]
    /// True for FITS (linear data needing autostretch); false for PNG/JPG/TIFF.
    public let sourceIsLinear: Bool
    public let stats: [ChannelStats]

    public init(width: Int, height: Int, channels: Int, pixels: [Float], sourceIsLinear: Bool) {
        precondition(pixels.count == width * height * channels)
        self.width = width; self.height = height; self.channels = channels
        self.pixels = pixels; self.sourceIsLinear = sourceIsLinear
        let plane = width * height
        self.stats = (0..<channels).map { c in
            Self.computeStats(pixels[(c * plane)..<((c + 1) * plane)])
        }
    }

    /// Stats over a stride-sampled subset (≤ 262144 samples) — full sort of a 24MP plane is wasteful.
    static func computeStats(_ slice: ArraySlice<Float>) -> ChannelStats {
        let n = slice.count
        let stride = max(1, n / 262_144)
        var samples: [Float] = []
        samples.reserveCapacity(n / stride + 1)
        var i = slice.startIndex
        while i < slice.endIndex { samples.append(slice[i]); i += stride }
        let count = Double(samples.count)
        let mean = samples.reduce(0.0) { $0 + Double($1) } / count
        let variance = samples.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / count
        samples.sort()
        let median = Double(samples[samples.count / 2])
        return ChannelStats(mean: mean, median: median, stddev: variance.squareRoot())
    }
}
```

`Sources/LiveAstroCore/Imaging/ImageLoader.swift`:
```swift
import Foundation
import CoreGraphics
import ImageIO

public enum ImageLoaderError: Error {
    case unsupportedFormat(String)
    case decodeFailed(String)
}

public enum ImageLoader {
    public static let fitsExtensions: Set<String> = ["fit", "fits", "fts"]
    public static let bitmapExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff"]

    public static func load(url: URL) throws -> AstroImage {
        let ext = url.pathExtension.lowercased()
        if fitsExtensions.contains(ext) {
            let fits = try FITSReader.read(try Data(contentsOf: url, options: .alwaysMapped))
            return AstroImage(width: fits.width, height: fits.height, channels: fits.channels,
                              pixels: fits.pixels, sourceIsLinear: true)
        }
        if bitmapExtensions.contains(ext) { return try loadBitmap(url: url) }
        throw ImageLoaderError.unsupportedFormat(ext)
    }

    private static func loadBitmap(url: URL) throws -> AstroImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageLoaderError.decodeFailed("cannot open \(url.lastPathComponent)")
        }
        // Thumbnail-with-transform applies EXIF orientation; max dimension huge = full size.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 20_000,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ImageLoaderError.decodeFailed("cannot decode \(url.lastPathComponent)")
        }
        let w = cg.width, h = cg.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ImageLoaderError.decodeFailed("context")
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let plane = w * h
        var px = [Float](repeating: 0, count: plane * 3)
        for p in 0..<plane {
            px[p]             = Float(rgba[p * 4])     / 255.0
            px[plane + p]     = Float(rgba[p * 4 + 1]) / 255.0
            px[2 * plane + p] = Float(rgba[p * 4 + 2]) / 255.0
        }
        return AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: false)
    }
}
```

- [ ] **Step 4: Run — expect pass.** `swift test 2>&1 | tail -3`

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: AstroImage with per-channel stats + ImageLoader (FITS linear, PNG/JPG/TIFF via ImageIO)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: AutoStretch

**Files:**
- Create: `Sources/LiveAstroCore/Imaging/AutoStretch.swift`
- Test: `Tests/LiveAstroCoreTests/AutoStretchTests.swift`

**Interfaces:**
- Consumes: `AstroImage`.
- Produces:
  - `enum AutoStretch { static func mtf(_ x: Double, _ m: Double) -> Double; static func stretch(_ image: AstroImage, targetBackground: Double = 0.25, shadowsClipping: Double = -2.8) -> AstroImage; static func makeCGImage(_ image: AstroImage) -> CGImage? }`
  - Stretch is **linked**: one transform computed from the mean-of-channels sample, applied to all channels (spec §5.4).
- Consumers: Task 10 (pipeline), Task 7 (snapshot PNG), Task 11 (broadcast display).

- [ ] **Step 1: Write failing tests**

`Tests/LiveAstroCoreTests/AutoStretchTests.swift`:
```swift
import XCTest
@testable import LiveAstroCore

final class AutoStretchTests: XCTestCase {
    func testMTFEndpointsAndIdentity() {
        XCTAssertEqual(AutoStretch.mtf(0, 0.3), 0)
        XCTAssertEqual(AutoStretch.mtf(1, 0.3), 1)
        XCTAssertEqual(AutoStretch.mtf(0.42, 0.5), 0.42, accuracy: 1e-9) // m=0.5 is identity
        XCTAssertEqual(AutoStretch.mtf(0.25, 0.25), 0.5, accuracy: 1e-9) // maps m to 0.5? No: MTF(m, m)=0.5
    }

    func testStretchPutsMedianNearTarget() {
        // Skewed dark linear image: background ~0.02 with noise, a few bright pixels.
        var rng = SystemRandomNumberGenerator()
        var px = (0..<10_000).map { _ in Float(0.02 + Double.random(in: -0.005...0.005, using: &rng)) }
        for i in 0..<20 { px[i * 500] = 0.8 }
        let img = AstroImage(width: 100, height: 100, channels: 1, pixels: px, sourceIsLinear: true)
        let out = AutoStretch.stretch(img)
        XCTAssertEqual(out.stats[0].median, 0.25, accuracy: 0.05)
        XCTAssertTrue(out.stats[0].median > img.stats[0].median * 3, "should brighten dramatically")
    }

    func testStretchIsMonotonic() {
        let px: [Float] = [0.0, 0.01, 0.02, 0.05, 0.2, 1.0] + [Float](repeating: 0.02, count: 94)
        let img = AstroImage(width: 10, height: 10, channels: 1, pixels: px, sourceIsLinear: true)
        let out = AutoStretch.stretch(img)
        for i in 1..<6 { XCTAssertGreaterThanOrEqual(out.pixels[i], out.pixels[i - 1]) }
        XCTAssertEqual(out.pixels[5], 1.0, accuracy: 1e-5)
    }

    func testLinkedChannelsPreserveRatios() {
        // Red channel brighter than blue everywhere; after linked stretch red stays >= blue.
        let plane = 100
        var px = [Float](repeating: 0.04, count: plane)        // R
        px += [Float](repeating: 0.02, count: plane)           // G
        px += [Float](repeating: 0.01, count: plane)           // B
        let img = AstroImage(width: 10, height: 10, channels: 3, pixels: px, sourceIsLinear: true)
        let out = AutoStretch.stretch(img)
        XCTAssertGreaterThan(out.pixels[0], out.pixels[plane])       // R > G
        XCTAssertGreaterThan(out.pixels[plane], out.pixels[2*plane]) // G > B
    }

    func testMakeCGImage() {
        let img = AstroImage(width: 4, height: 2, channels: 3,
                             pixels: [Float](repeating: 0.5, count: 24), sourceIsLinear: false)
        let cg = AutoStretch.makeCGImage(img)
        XCTAssertEqual(cg?.width, 4)
        XCTAssertEqual(cg?.height, 2)
    }
}
```

Note on `testMTFEndpointsAndIdentity` last line: MTF(x=m, m) = ((m−1)m)/((2m−1)m − m) = (m−1)/(2m−2) = 0.5 — passing the midtone value itself always yields 0.5. That identity is exactly why `midtone = mtf(r, targetBackground)` solves “map r to targetBackground”.

- [ ] **Step 2: Run — expect compile failure.**

- [ ] **Step 3: Implement**

`Sources/LiveAstroCore/Imaging/AutoStretch.swift`:
```swift
import Foundation
import CoreGraphics

/// Midtone-transfer-function autostretch (PixInsight STF / Siril autostretch family).
/// Linear FITS displayed raw is a black rectangle; this makes it look like Siril's preview.
public enum AutoStretch {

    /// MTF(x, m) — midtones transfer function with midtones balance m.
    public static func mtf(_ x: Double, _ m: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        return ((m - 1) * x) / (((2 * m - 1) * x) - m)
    }

    /// Linked autostretch: statistics from the mean-of-channels sample, one transform for all channels.
    public static func stretch(_ image: AstroImage,
                               targetBackground: Double = 0.25,
                               shadowsClipping: Double = -2.8) -> AstroImage {
        let plane = image.width * image.height
        // Combined luminance sample (mean across channels), stride-sampled.
        let stride = max(1, plane / 262_144)
        var sample: [Float] = []
        sample.reserveCapacity(plane / stride + 1)
        var i = 0
        while i < plane {
            var s: Float = 0
            for c in 0..<image.channels { s += image.pixels[c * plane + i] }
            sample.append(s / Float(image.channels))
            i += stride
        }
        sample.sort()
        let median = Double(sample[sample.count / 2])
        var deviations = sample.map { abs(Double($0) - median) }
        deviations.sort()
        let madn = 1.4826 * deviations[deviations.count / 2]

        let shadow = min(max(median + shadowsClipping * madn, 0), 1)
        let denom = max(1 - shadow, 1e-9)
        let r = min(max((median - shadow) / denom, 1e-9), 1)
        let midtone = mtf(r, targetBackground)

        var out = [Float](repeating: 0, count: image.pixels.count)
        for idx in 0..<image.pixels.count {
            let x = (Double(image.pixels[idx]) - shadow) / denom
            out[idx] = Float(mtf(min(max(x, 0), 1), midtone))
        }
        return AstroImage(width: image.width, height: image.height, channels: image.channels,
                          pixels: out, sourceIsLinear: false)
    }

    /// Pack planar float image into an 8-bit CGImage (gray or RGBX).
    public static func makeCGImage(_ image: AstroImage) -> CGImage? {
        let w = image.width, h = image.height, plane = w * h
        if image.channels == 1 {
            var buf = [UInt8](repeating: 0, count: plane)
            for p in 0..<plane { buf[p] = UInt8(min(max(image.pixels[p], 0), 1) * 255) }
            return buf.withUnsafeMutableBytes { ptr in
                CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                          bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
            }
        }
        var buf = [UInt8](repeating: 255, count: plane * 4)
        for p in 0..<plane {
            buf[p * 4]     = UInt8(min(max(image.pixels[p], 0), 1) * 255)
            buf[p * 4 + 1] = UInt8(min(max(image.pixels[plane + p], 0), 1) * 255)
            buf[p * 4 + 2] = UInt8(min(max(image.pixels[2 * plane + p], 0), 1) * 255)
        }
        return buf.withUnsafeMutableBytes { ptr in
            CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
    }
}
```

- [ ] **Step 4: Run — expect pass.** `swift test 2>&1 | tail -3`

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: linked MTF autostretch + CGImage packing

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: StackFileWatcher

**Files:**
- Create: `Sources/LiveAstroCore/Watch/StackFileWatcher.swift`
- Test: `Tests/LiveAstroCoreTests/StackFileWatcherTests.swift`

**Interfaces:**
- Consumes: `FITSReader.readHeader(...).minimumFileSize`, `ImageLoader.fitsExtensions/bitmapExtensions`.
- Produces:
  - `struct StackUpdate: Equatable, Sendable { let url: URL; let fileSize: Int }`
  - `final class StackFileWatcher { init(folder: URL, quietPeriod: TimeInterval = 0.5, pollInterval: TimeInterval = 2.0); let updates: AsyncStream<StackUpdate>; func start() throws; func stop() }`
  - Semantics: watches the folder for writes (Siril rewrites `live_stack.fit` in place); debounces; FITS accepted only when `size >= minimumFileSize` from parsed header; bitmaps accepted when size stable across two consecutive scans; hidden/temp files ignored; identical content (size + head/tail SHA256) never emitted twice.
- Consumers: Task 10 (pipeline).

- [ ] **Step 1: Write failing tests**

`Tests/LiveAstroCoreTests/StackFileWatcherTests.swift`:
```swift
import XCTest
@testable import LiveAstroCore

final class StackFileWatcherTests: XCTestCase {
    var tmp: URL!
    var watcher: StackFileWatcher!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        watcher?.stop()
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeFITS(_ value: Float, size: Int = 8) -> Data {
        FITSWriter.float32(width: size, height: size, channels: 1,
                           pixels: [Float](repeating: value, count: size * size))
    }

    /// Collects updates into an actor-guarded array.
    private func collect(_ watcher: StackFileWatcher) -> Collector {
        let c = Collector()
        Task { for await u in watcher.updates { await c.add(u) } }
        return c
    }

    actor Collector {
        private(set) var items: [StackUpdate] = []
        func add(_ u: StackUpdate) { items.append(u) }
        func waitForCount(_ n: Int, timeout: TimeInterval) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if items.count >= n { return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return items.count >= n
        }
    }

    func testEmitsOnCompleteFITSWrite() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.5)
        let collector = collect(watcher)
        try watcher.start()
        try makeFITS(0.5).write(to: tmp.appendingPathComponent("live_stack.fit"))
        let got = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(got, "expected one update for a complete FITS write")
    }

    func testIgnoresPartialFITSUntilComplete() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.3)
        let collector = collect(watcher)
        try watcher.start()
        let full = makeFITS(0.5, size: 64)
        let url = tmp.appendingPathComponent("live_stack.fit")
        try full.prefix(full.count / 2).write(to: url)      // partial: header claims more data
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let premature = await collector.waitForCount(1, timeout: 0.1)
        XCTAssertFalse(premature, "must not emit for a partial FITS file")
        try full.write(to: url)                              // complete rewrite
        let got = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(got)
    }

    func testDeduplicatesIdenticalContent() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.3)
        let collector = collect(watcher)
        try watcher.start()
        let url = tmp.appendingPathComponent("live_stack.fit")
        let data = makeFITS(0.5)
        try data.write(to: url)
        _ = await collector.waitForCount(1, timeout: 5)
        try data.write(to: url)                              // same bytes again
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let items = await collector.items
        XCTAssertEqual(items.count, 1, "identical content must not re-emit")
    }

    func testEmitsAgainOnChangedContent() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.3)
        let collector = collect(watcher)
        try watcher.start()
        let url = tmp.appendingPathComponent("live_stack.fit")
        try makeFITS(0.3).write(to: url)
        _ = await collector.waitForCount(1, timeout: 5)
        try makeFITS(0.6).write(to: url)
        let got = await collector.waitForCount(2, timeout: 5)
        XCTAssertTrue(got, "changed content must emit a second update")
    }

    func testIgnoresTempAndHiddenFiles() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.3)
        let collector = collect(watcher)
        try watcher.start()
        try makeFITS(0.5).write(to: tmp.appendingPathComponent(".hidden.fit"))
        try Data("x".utf8).write(to: tmp.appendingPathComponent("scratch.tmp"))
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let items = await collector.items
        XCTAssertTrue(items.isEmpty)
    }
}
```

- [ ] **Step 2: Run — expect compile failure.**

- [ ] **Step 3: Implement**

`Sources/LiveAstroCore/Watch/StackFileWatcher.swift`:
```swift
import Foundation
import CryptoKit

public struct StackUpdate: Equatable, Sendable {
    public let url: URL
    public let fileSize: Int
}

/// Watches a folder for completed writes of stack images.
/// Siril rewrites live_stack.fit in place, so this is modification-watching with
/// write-completion checks, not new-file detection (spec §5.2).
public final class StackFileWatcher {
    public let updates: AsyncStream<StackUpdate>

    private let folder: URL
    private let quietPeriod: TimeInterval
    private let pollInterval: TimeInterval
    private let queue = DispatchQueue(label: "liveastro.watcher")
    private var continuation: AsyncStream<StackUpdate>.Continuation!
    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var debounceWork: DispatchWorkItem?
    private var folderFD: Int32 = -1

    /// Per-file state for stability + dedupe.
    private var lastSeenSize: [String: Int] = [:]
    private var lastEmittedDigest: [String: String] = [:]

    public init(folder: URL, quietPeriod: TimeInterval = 0.5, pollInterval: TimeInterval = 2.0) {
        self.folder = folder
        self.quietPeriod = quietPeriod
        self.pollInterval = pollInterval
        var cont: AsyncStream<StackUpdate>.Continuation!
        self.updates = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func start() throws {
        folderFD = open(folder.path, O_EVTONLY)
        guard folderFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "cannot open \(folder.path)"])
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: folderFD, eventMask: [.write, .extend], queue: queue)
        src.setEventHandler { [weak self] in self?.scheduleScan() }
        src.resume()
        source = src

        // Poll fallback: catches events DispatchSource misses (network volumes, in-place mmap writes).
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.scan() }
        timer.resume()
        pollTimer = timer
    }

    public func stop() {
        source?.cancel(); source = nil
        pollTimer?.cancel(); pollTimer = nil
        if folderFD >= 0 { close(folderFD); folderFD = -1 }
        continuation.finish()
    }

    private func scheduleScan() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + quietPeriod, execute: work)
    }

    private func scan() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names {
            guard !name.hasPrefix("."), !name.lowercased().hasSuffix(".tmp") else { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            let isFITS = ImageLoader.fitsExtensions.contains(ext)
            guard isFITS || ImageLoader.bitmapExtensions.contains(ext) else { continue }

            let url = folder.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.intValue, size > 0 else { continue }

            let previousSize = lastSeenSize[name]
            lastSeenSize[name] = size

            if isFITS {
                // Bulletproof completeness: header declares exact expected data length (spec §5.2).
                guard let head = try? readHead(url: url, bytes: 32 * 2880),
                      let header = try? FITSReader.readHeader(head),
                      size >= header.minimumFileSize else { continue }
            } else {
                // Bitmaps: require size stable across two consecutive scans.
                guard previousSize == size else { continue }
            }

            let digest = contentDigest(url: url, size: size)
            guard lastEmittedDigest[name] != digest else { continue }
            lastEmittedDigest[name] = digest
            continuation.yield(StackUpdate(url: url, fileSize: size))
        }
    }

    private func readHead(url: URL, bytes: Int) throws -> Data {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        return try fh.read(upToCount: bytes) ?? Data()
    }

    /// Cheap content identity: SHA256 over size + first/last 64 KB.
    private func contentDigest(url: URL, size: Int) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return UUID().uuidString }
        defer { try? fh.close() }
        var hasher = SHA256()
        hasher.update(data: Data("\(size)".utf8))
        if let head = try? fh.read(upToCount: 65536) { hasher.update(data: head) }
        if size > 131_072 {
            try? fh.seek(toOffset: UInt64(size - 65536))
            if let tail = try? fh.read(upToCount: 65536) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Run — expect pass.** `swift test 2>&1 | tail -3` (watcher tests take ~10 s of real time; that's the debounce/poll clocks, not a hang).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: StackFileWatcher — debounced folder watch, FITS header-length completeness, content dedupe

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Session Models + SessionManager

**Files:**
- Create: `Sources/LiveAstroCore/Session/SessionModels.swift`, `Sources/LiveAstroCore/Session/SessionManager.swift`
- Test: `Tests/LiveAstroCoreTests/SessionManagerTests.swift`

**Interfaces:**
- Produces:
  - `struct SessionProfile: Codable, Equatable { targetName, telescope, camera, mount, filter, locationLabel: String; bortle: Int?; subExposureSeconds: Double; notes: String }` (memberwise init, all with sensible `""`/nil defaults)
  - `struct SnapshotRecord: Codable, Equatable { index: Int; timestamp: Date; sourceFile: String; snapshotFile: String; estimatedIntegrationSeconds: Double; width: Int; height: Int; mean: Double; median: Double; stddev: Double }`
  - `struct SessionManifest: Codable, Equatable { sessionId: String; targetName: String; startTime: Date; endTime: Date?; subExposureSeconds: Double; bortle: Int?; locationLabel, telescope, camera, mount, filter, notes: String; snapshots: [SnapshotRecord] }`
  - `enum ManifestCoding { static func encoder() -> JSONEncoder; static func decoder() -> JSONDecoder }` — snake_case keys, ISO8601 dates, pretty + sorted.
  - `enum IntegrationFormat { static func caption(seconds: Double, frames: Int, subSeconds: Double) -> String }` → `"2h 14m · 402 × 20s"` (hours omitted when 0: `"14m 30s · 12 × 60s"`; sub shown without decimals when whole).
  - `final class SessionManager { enum State { idle, running, ended }; init(rootDirectory: URL); private(set) var state/manifest/sessionDirectory; func startSession(profile: SessionProfile, at: Date = .init()) throws -> URL; func recordSnapshot(_: SnapshotRecord) throws; func endSession(at: Date = .init()) throws; var acceptedCount: Int; var estimatedIntegrationSeconds: Double; static func sessionId(date: Date, targetName: String) -> String }`
  - Manifest written atomically (`.atomic`) after start, every snapshot, and end (spec §5.5, §7).
  - `sessionId`: `yyyy-MM-dd` + `-` + slug (lowercased alphanumerics of target, max 24 chars, `"session"` if empty).
- Consumers: Tasks 7, 9, 10, 11.

- [ ] **Step 1: Write failing tests**

`Tests/LiveAstroCoreTests/SessionManagerTests.swift`:
```swift
import XCTest
@testable import LiveAstroCore

final class SessionManagerTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private var profile: SessionProfile {
        SessionProfile(targetName: "NGC 6888 Crescent Nebula", telescope: "120 APO",
                       camera: "ASI2600MC Air", mount: "AM5N", filter: "Dual-band",
                       locationLabel: "Round Rock, TX", bortle: 7,
                       subExposureSeconds: 120, notes: "")
    }

    func testSessionIdSlug() {
        let d = ISO8601DateFormatter().date(from: "2026-07-05T22:15:00-05:00")!
        let id = SessionManager.sessionId(date: d, targetName: "NGC 6888")
        XCTAssertTrue(id.hasSuffix("-ngc6888"), "got \(id)")
        XCTAssertTrue(id.hasPrefix("2026-07-0")) // day depends on local zone; prefix is stable enough
    }

    func testStartCreatesDirectoryAndManifest() throws {
        let mgr = SessionManager(rootDirectory: tmp)
        let dir = try mgr.startSession(profile: profile)
        XCTAssertEqual(mgr.state, .running)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("snapshots").path))
        let json = try String(contentsOf: dir.appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("\"session_id\""), "keys must be snake_case")
        XCTAssertTrue(json.contains("\"sub_exposure_seconds\""))
    }

    func testRecordSnapshotAppendsAndPersists() throws {
        let mgr = SessionManager(rootDirectory: tmp)
        let dir = try mgr.startSession(profile: profile)
        let rec = SnapshotRecord(index: 1, timestamp: Date(), sourceFile: "live_stack.fit",
                                 snapshotFile: "snapshots/0001.png",
                                 estimatedIntegrationSeconds: 120, width: 100, height: 80,
                                 mean: 0.1, median: 0.08, stddev: 0.02)
        try mgr.recordSnapshot(rec)
        XCTAssertEqual(mgr.acceptedCount, 1)
        XCTAssertEqual(mgr.estimatedIntegrationSeconds, 120)
        let data = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        let loaded = try ManifestCoding.decoder().decode(SessionManifest.self, from: data)
        XCTAssertEqual(loaded.snapshots.count, 1)
        XCTAssertEqual(loaded.snapshots[0], rec)
    }

    func testEndSessionSetsEndTime() throws {
        let mgr = SessionManager(rootDirectory: tmp)
        let dir = try mgr.startSession(profile: profile)
        try mgr.endSession()
        XCTAssertEqual(mgr.state, .ended)
        let loaded = try ManifestCoding.decoder()
            .decode(SessionManifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertNotNil(loaded.endTime)
    }

    func testRecordBeforeStartThrows() {
        let mgr = SessionManager(rootDirectory: tmp)
        let rec = SnapshotRecord(index: 1, timestamp: Date(), sourceFile: "a", snapshotFile: "b",
                                 estimatedIntegrationSeconds: 0, width: 1, height: 1,
                                 mean: 0, median: 0, stddev: 0)
        XCTAssertThrowsError(try mgr.recordSnapshot(rec))
    }

    func testCaptionFormat() {
        XCTAssertEqual(IntegrationFormat.caption(seconds: 8040, frames: 402, subSeconds: 20),
                       "2h 14m · 402 × 20s")
        XCTAssertEqual(IntegrationFormat.caption(seconds: 870, frames: 12, subSeconds: 72.5),
                       "14m 30s · 12 × 72.5s")
    }
}
```

- [ ] **Step 2: Run — expect compile failure.**

- [ ] **Step 3: Implement**

`Sources/LiveAstroCore/Session/SessionModels.swift`:
```swift
import Foundation

public struct SessionProfile: Codable, Equatable {
    public var targetName: String
    public var telescope: String
    public var camera: String
    public var mount: String
    public var filter: String
    public var locationLabel: String
    public var bortle: Int?
    public var subExposureSeconds: Double
    public var notes: String

    public init(targetName: String = "", telescope: String = "", camera: String = "",
                mount: String = "", filter: String = "", locationLabel: String = "",
                bortle: Int? = nil, subExposureSeconds: Double = 60, notes: String = "") {
        self.targetName = targetName; self.telescope = telescope; self.camera = camera
        self.mount = mount; self.filter = filter; self.locationLabel = locationLabel
        self.bortle = bortle; self.subExposureSeconds = subExposureSeconds; self.notes = notes
    }
}

public struct SnapshotRecord: Codable, Equatable {
    public let index: Int
    public let timestamp: Date
    public let sourceFile: String
    public let snapshotFile: String
    public let estimatedIntegrationSeconds: Double
    public let width: Int
    public let height: Int
    public let mean: Double
    public let median: Double
    public let stddev: Double

    public init(index: Int, timestamp: Date, sourceFile: String, snapshotFile: String,
                estimatedIntegrationSeconds: Double, width: Int, height: Int,
                mean: Double, median: Double, stddev: Double) {
        self.index = index; self.timestamp = timestamp
        self.sourceFile = sourceFile; self.snapshotFile = snapshotFile
        self.estimatedIntegrationSeconds = estimatedIntegrationSeconds
        self.width = width; self.height = height
        self.mean = mean; self.median = median; self.stddev = stddev
    }
}

public struct SessionManifest: Codable, Equatable {
    public let sessionId: String
    public var targetName: String
    public var startTime: Date
    public var endTime: Date?
    public var subExposureSeconds: Double
    public var bortle: Int?
    public var locationLabel: String
    public var telescope: String
    public var camera: String
    public var mount: String
    public var filter: String
    public var notes: String
    public var snapshots: [SnapshotRecord]
}

public enum ManifestCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

public enum IntegrationFormat {
    /// "2h 14m · 402 × 20s" — hours omitted when zero; sub-length decimals shown only when fractional.
    public static func caption(seconds: Double, frames: Int, subSeconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let time: String
        if h > 0 { time = "\(h)h \(m)m" }
        else if m > 0 { time = s > 0 ? "\(m)m \(s)s" : "\(m)m" }
        else { time = "\(s)s" }
        let sub = subSeconds.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(subSeconds))s" : "\(subSeconds)s"
        return "\(time) · \(frames) × \(sub)"
    }
}
```

`Sources/LiveAstroCore/Session/SessionManager.swift`:
```swift
import Foundation

public enum SessionError: Error, Equatable {
    case notRunning
    case alreadyRunning
}

public final class SessionManager {
    public enum State: Equatable { case idle, running, ended }

    public private(set) var state: State = .idle
    public private(set) var manifest: SessionManifest?
    public private(set) var sessionDirectory: URL?
    private let rootDirectory: URL

    public init(rootDirectory: URL) { self.rootDirectory = rootDirectory }

    public var acceptedCount: Int { manifest?.snapshots.count ?? 0 }
    public var estimatedIntegrationSeconds: Double {
        Double(acceptedCount) * (manifest?.subExposureSeconds ?? 0)
    }

    public static func sessionId(date: Date, targetName: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        var slug = targetName.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        if slug.isEmpty { slug = "session" }
        return "\(fmt.string(from: date))-\(String(slug.prefix(24)))"
    }

    @discardableResult
    public func startSession(profile: SessionProfile, at date: Date = .init()) throws -> URL {
        guard state != .running else { throw SessionError.alreadyRunning }
        let id = Self.sessionId(date: date, targetName: profile.targetName)
        let dir = rootDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("snapshots"), withIntermediateDirectories: true)
        manifest = SessionManifest(
            sessionId: id, targetName: profile.targetName, startTime: date, endTime: nil,
            subExposureSeconds: profile.subExposureSeconds, bortle: profile.bortle,
            locationLabel: profile.locationLabel, telescope: profile.telescope,
            camera: profile.camera, mount: profile.mount, filter: profile.filter,
            notes: profile.notes, snapshots: [])
        sessionDirectory = dir
        state = .running
        try persist()
        return dir
    }

    public func recordSnapshot(_ record: SnapshotRecord) throws {
        guard state == .running, manifest != nil else { throw SessionError.notRunning }
        manifest!.snapshots.append(record)
        try persist()
    }

    public func endSession(at date: Date = .init()) throws {
        guard state == .running, manifest != nil else { throw SessionError.notRunning }
        manifest!.endTime = date
        state = .ended
        try persist()
    }

    /// Atomic write: temp file + rename via Data(.atomic). Crash loses at most the in-flight update (spec §7).
    private func persist() throws {
        guard let dir = sessionDirectory, let m = manifest else { return }
        let data = try ManifestCoding.encoder().encode(m)
        try data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
    }
}
```

- [ ] **Step 4: Run — expect pass.** `swift test 2>&1 | tail -3`

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: session models, snake_case manifest coding, SessionManager state machine, caption formatting

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: SnapshotRecorder

**Files:**
- Create: `Sources/LiveAstroCore/Session/SnapshotRecorder.swift`
- Test: `Tests/LiveAstroCoreTests/SnapshotRecorderTests.swift`

**Interfaces:**
- Consumes: `CGImage` (from `AutoStretch.makeCGImage`), `AstroImage` (linear, for stats), `SnapshotRecord`.
- Produces:
  - `final class SnapshotRecorder { init(sessionDirectory: URL); func save(cgImage: CGImage, linear: AstroImage, sourceFile: String, index: Int, timestamp: Date, estimatedIntegrationSeconds: Double) throws -> SnapshotRecord }`
  - Writes `snapshots/%04d.png`; record's stats come from `linear.stats[0]` (first channel — for RGB this is R; documented compromise, spec only asks for basic stats).
- Consumers: Task 10 (pipeline).

- [ ] **Step 1: Write failing test**

`Tests/LiveAstroCoreTests/SnapshotRecorderTests.swift`:
```swift
import XCTest
import CoreGraphics
@testable import LiveAstroCore

final class SnapshotRecorderTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("snapshots"),
                                                withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testSaveWritesPNGAndReturnsRecord() throws {
        let img = AstroImage(width: 8, height: 6, channels: 1,
                             pixels: [Float](repeating: 0.1, count: 48), sourceIsLinear: true)
        let cg = AutoStretch.makeCGImage(AutoStretch.stretch(img))!
        let rec = try SnapshotRecorder(sessionDirectory: tmp).save(
            cgImage: cg, linear: img, sourceFile: "live_stack.fit",
            index: 3, timestamp: Date(), estimatedIntegrationSeconds: 360)
        XCTAssertEqual(rec.snapshotFile, "snapshots/0003.png")
        XCTAssertEqual(rec.width, 8); XCTAssertEqual(rec.height, 6)
        XCTAssertEqual(rec.mean, 0.1, accuracy: 1e-4)
        let path = tmp.appendingPathComponent(rec.snapshotFile).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertNotNil(try? ImageLoader.load(url: tmp.appendingPathComponent(rec.snapshotFile)))
    }
}
```

- [ ] **Step 2: Run — expect compile failure.**

- [ ] **Step 3: Implement**

`Sources/LiveAstroCore/Session/SnapshotRecorder.swift`:
```swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum SnapshotError: Error { case encodeFailed }

public final class SnapshotRecorder {
    private let sessionDirectory: URL

    public init(sessionDirectory: URL) { self.sessionDirectory = sessionDirectory }

    /// Saves a display-ready (post-stretch) PNG and returns its manifest record (spec §5.7).
    public func save(cgImage: CGImage, linear: AstroImage, sourceFile: String,
                     index: Int, timestamp: Date,
                     estimatedIntegrationSeconds: Double) throws -> SnapshotRecord {
        let name = String(format: "snapshots/%04d.png", index)
        let url = sessionDirectory.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SnapshotError.encodeFailed
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { throw SnapshotError.encodeFailed }

        let stats = linear.stats[0]
        return SnapshotRecord(index: index, timestamp: timestamp, sourceFile: sourceFile,
                              snapshotFile: name,
                              estimatedIntegrationSeconds: estimatedIntegrationSeconds,
                              width: linear.width, height: linear.height,
                              mean: stats.mean, median: stats.median, stddev: stats.stddev)
    }
}
```

- [ ] **Step 4: Run — expect pass.** Then commit:

```bash
git add -A && git commit -m "feat: SnapshotRecorder — post-stretch PNG snapshots with linear stats

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: FrameSelector

**Files:**
- Create: `Sources/LiveAstroCore/Replay/FrameSelector.swift`
- Test: `Tests/LiveAstroCoreTests/FrameSelectorTests.swift`

**Interfaces:**
- Consumes: `AstroImage`, `ImageLoader.load`.
- Produces:
  - `enum FrameSelector { static func logSpacedIndices(count: Int, maxKeyframes: Int) -> [Int]; static func select(count: Int, maxKeyframes: Int, difference: (Int, Int) -> Double, differenceThreshold: Double = 0.01) -> [Int]; static func thumbnailDifference(_ a: AstroImage, _ b: AstroImage) -> Double; static func selectSnapshots(urls: [URL], maxKeyframes: Int = 45) throws -> [Int] }`
  - `logSpacedIndices`: always contains 0 and count−1; early-biased (`round(count^f) − 1` for f ∈ [0,1]); sorted unique. If `count <= maxKeyframes` returns all indices.
  - `select`: applies log spacing then drops frames whose visual difference from the last kept frame is below threshold (first/last never dropped).
  - `thumbnailDifference`: block-average both images to 64×64 grayscale, mean absolute difference (0 = identical).
  - `selectSnapshots`: convenience for the pipeline — loads URLs, memoizes 64×64 thumbnails, runs `select`.
- Consumers: Task 10 (pipeline `end()`).

- [ ] **Step 1: Write failing tests**

`Tests/LiveAstroCoreTests/FrameSelectorTests.swift`:
```swift
import XCTest
@testable import LiveAstroCore

final class FrameSelectorTests: XCTestCase {

    func testSmallCountReturnsAll() {
        XCTAssertEqual(FrameSelector.logSpacedIndices(count: 5, maxKeyframes: 10), [0, 1, 2, 3, 4])
    }

    func testAlwaysIncludesFirstAndLast() {
        let idx = FrameSelector.logSpacedIndices(count: 1000, maxKeyframes: 30)
        XCTAssertEqual(idx.first, 0)
        XCTAssertEqual(idx.last, 999)
        XCTAssertLessThanOrEqual(idx.count, 31)
    }

    func testEarlyBias() {
        let idx = FrameSelector.logSpacedIndices(count: 1000, maxKeyframes: 30)
        let firstHalf = idx.filter { $0 < 500 }.count
        let secondHalf = idx.filter { $0 >= 500 }.count
        XCTAssertGreaterThan(firstHalf, secondHalf,
                             "log spacing must sample the early session more densely")
    }

    func testSortedUnique() {
        let idx = FrameSelector.logSpacedIndices(count: 100, maxKeyframes: 50)
        XCTAssertEqual(idx, Array(Set(idx)).sorted())
    }

    func testDedupeDropsNearIdenticalButKeepsEnds() {
        // difference: everything identical except index 0 vs anything.
        let picked = FrameSelector.select(count: 100, maxKeyframes: 20,
                                          difference: { a, b in (a == 0 || b == 0) ? 1.0 : 0.0 })
        XCTAssertEqual(picked.first, 0)
        XCTAssertEqual(picked.last, 99, "final frame survives even when visually identical")
        XCTAssertLessThanOrEqual(picked.count, 3, "middle duplicates removed")
    }

    func testThumbnailDifference() {
        let a = AstroImage(width: 128, height: 128, channels: 1,
                           pixels: [Float](repeating: 0.2, count: 128 * 128), sourceIsLinear: false)
        let b = AstroImage(width: 128, height: 128, channels: 1,
                           pixels: [Float](repeating: 0.8, count: 128 * 128), sourceIsLinear: false)
        XCTAssertEqual(FrameSelector.thumbnailDifference(a, a), 0, accuracy: 1e-6)
        XCTAssertEqual(FrameSelector.thumbnailDifference(a, b), 0.6, accuracy: 0.01)
    }
}
```

- [ ] **Step 2: Run — expect compile failure.**

- [ ] **Step 3: Implement**

`Sources/LiveAstroCore/Replay/FrameSelector.swift`:
```swift
import Foundation

/// Keyframe selection for the stack-evolution replay (spec §5.8).
/// Improvement is dramatic early and slow late, so sampling is logarithmic over index.
public enum FrameSelector {

    public static func logSpacedIndices(count: Int, maxKeyframes: Int) -> [Int] {
        guard count > 0 else { return [] }
        guard count > maxKeyframes else { return Array(0..<count) }
        var out: Set<Int> = [0, count - 1]
        for j in 0..<maxKeyframes {
            let f = Double(j) / Double(maxKeyframes - 1)
            let idx = Int((pow(Double(count), f) - 1).rounded())
            out.insert(min(max(idx, 0), count - 1))
        }
        return out.sorted()
    }

    /// Log spacing + near-duplicate removal. `difference(i, j)` returns 0 for identical frames.
    public static func select(count: Int, maxKeyframes: Int,
                              difference: (Int, Int) -> Double,
                              differenceThreshold: Double = 0.01) -> [Int] {
        let candidates = logSpacedIndices(count: count, maxKeyframes: maxKeyframes)
        guard candidates.count > 2 else { return candidates }
        var kept: [Int] = [candidates[0]]
        for idx in candidates.dropFirst() {
            let isLast = idx == candidates.last
            if isLast || difference(kept.last!, idx) >= differenceThreshold {
                kept.append(idx)
            }
        }
        return kept
    }

    /// Mean absolute difference of 64×64 block-averaged grayscale thumbnails.
    public static func thumbnailDifference(_ a: AstroImage, _ b: AstroImage) -> Double {
        let ta = grayThumbnail(a), tb = grayThumbnail(b)
        var sum = 0.0
        for i in 0..<ta.count { sum += abs(Double(ta[i]) - Double(tb[i])) }
        return sum / Double(ta.count)
    }

    /// Pipeline convenience: load snapshot PNGs, memoize thumbnails, select.
    public static func selectSnapshots(urls: [URL], maxKeyframes: Int = 45) throws -> [Int] {
        var thumbs: [Int: [Float]] = [:]
        func thumb(_ i: Int) throws -> [Float] {
            if let t = thumbs[i] { return t }
            let t = grayThumbnail(try ImageLoader.load(url: urls[i]))
            thumbs[i] = t
            return t
        }
        return select(count: urls.count, maxKeyframes: maxKeyframes) { i, j in
            guard let a = try? thumb(i), let b = try? thumb(j) else { return 1.0 }
            var sum = 0.0
            for k in 0..<a.count { sum += abs(Double(a[k]) - Double(b[k])) }
            return sum / Double(a.count)
        }
    }

    static func grayThumbnail(_ img: AstroImage, size: Int = 64) -> [Float] {
        let plane = img.width * img.height
        var out = [Float](repeating: 0, count: size * size)
        for ty in 0..<size {
            for tx in 0..<size {
                let x0 = tx * img.width / size, x1 = max(x0 + 1, (tx + 1) * img.width / size)
                let y0 = ty * img.height / size, y1 = max(y0 + 1, (ty + 1) * img.height / size)
                var acc: Float = 0; var n = 0
                for y in y0..<min(y1, img.height) {
                    for x in x0..<min(x1, img.width) {
                        var v: Float = 0
                        for c in 0..<img.channels { v += img.pixels[c * plane + y * img.width + x] }
                        acc += v / Float(img.channels); n += 1
                    }
                }
                out[ty * size + tx] = n > 0 ? acc / Float(n) : 0
            }
        }
        return out
    }
}
```

- [ ] **Step 4: Run — expect pass.** Then commit:

```bash
git add -A && git commit -m "feat: FrameSelector — log-spaced early-biased sampling with visual dedupe

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: ReplayGenerator

**Files:**
- Create: `Sources/LiveAstroCore/Replay/ReplayGenerator.swift`
- Test: `Tests/LiveAstroCoreTests/ReplayGeneratorTests.swift`

**Interfaces:**
- Consumes: keyframe PNG URLs + captions.
- Produces:
  - `struct ReplaySettings { var duration: Double = 45; var fps: Int = 30; var width: Int = 1920; var height: Int = 1080; var crossfade: Double = 0.5 }`
  - `struct ReplayKeyframe { let imageURL: URL; let caption: String }`
  - `final class ReplayGenerator { init(settings: ReplaySettings = .init()); func render(keyframes: [ReplayKeyframe], to outputURL: URL) throws }` (synchronous; callers run it off the main thread)
  - `static func aspectFitRect(image: CGSize, in canvas: CGSize) -> CGRect` (unit-testable)
  - Output: H.264 MP4 via AVAssetWriter; each keyframe gets an equal time slice with a crossfade into the next; caption drawn bottom-left with a font scaled to canvas height.
- Consumers: Task 10 (pipeline `end()`).

- [ ] **Step 1: Write failing tests**

`Tests/LiveAstroCoreTests/ReplayGeneratorTests.swift`:
```swift
import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LiveAstroCore

final class ReplayGeneratorTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testAspectFit() {
        // Wide image in 16:9 canvas: full width, letterboxed height.
        let r = ReplayGenerator.aspectFitRect(image: CGSize(width: 200, height: 50),
                                              in: CGSize(width: 160, height: 90))
        XCTAssertEqual(r.width, 160, accuracy: 0.01)
        XCTAssertEqual(r.height, 40, accuracy: 0.01)
        XCTAssertEqual(r.midY, 45, accuracy: 0.01)
        // Tall image: full height, pillarboxed.
        let r2 = ReplayGenerator.aspectFitRect(image: CGSize(width: 50, height: 200),
                                               in: CGSize(width: 160, height: 90))
        XCTAssertEqual(r2.height, 90, accuracy: 0.01)
        XCTAssertEqual(r2.midX, 80, accuracy: 0.01)
    }

    func testRendersValidMP4() throws {
        var urls: [URL] = []
        for (i, shade) in [0.1, 0.5, 0.9].enumerated() {
            let url = tmp.appendingPathComponent("kf\(i).png")
            try writePNG(to: url, gray: shade, width: 320, height: 180)
            urls.append(url)
        }
        var settings = ReplaySettings()
        settings.duration = 2; settings.fps = 10
        settings.width = 320; settings.height = 180; settings.crossfade = 0.2
        let out = tmp.appendingPathComponent("replay.mp4")
        try ReplayGenerator(settings: settings).render(
            keyframes: urls.enumerated().map {
                ReplayKeyframe(imageURL: $0.element, caption: "\($0.offset + 1) × 20s")
            }, to: out)

        let asset = AVURLAsset(url: out)
        let exp = expectation(description: "load")
        Task {
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            XCTAssertEqual(CMTimeGetSeconds(duration), 2.0, accuracy: 0.25)
            XCTAssertEqual(tracks.count, 1)
            let size = try await tracks[0].load(.naturalSize)
            XCTAssertEqual(size.width, 320); XCTAssertEqual(size.height, 180)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
    }

    func testEmptyKeyframesThrows() {
        XCTAssertThrowsError(try ReplayGenerator().render(
            keyframes: [], to: tmp.appendingPathComponent("x.mp4")))
    }

    private func writePNG(to url: URL, gray: Double, width: Int, height: Int) throws {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }
}
```

- [ ] **Step 2: Run — expect compile failure.**

- [ ] **Step 3: Implement**

`Sources/LiveAstroCore/Replay/ReplayGenerator.swift`:
```swift
import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import AppKit // NSAttributedString text drawing only — no UI

public struct ReplaySettings {
    public var duration: Double = 45
    public var fps: Int = 30
    public var width: Int = 1920
    public var height: Int = 1080
    public var crossfade: Double = 0.5
    public init() {}
}

public struct ReplayKeyframe {
    public let imageURL: URL
    public let caption: String
    public init(imageURL: URL, caption: String) {
        self.imageURL = imageURL; self.caption = caption
    }
}

public enum ReplayError: Error {
    case noKeyframes
    case decodeFailed(String)
    case writerFailed(String)
}

public final class ReplayGenerator {
    private let settings: ReplaySettings

    public init(settings: ReplaySettings = .init()) { self.settings = settings }

    public static func aspectFitRect(image: CGSize, in canvas: CGSize) -> CGRect {
        let scale = min(canvas.width / image.width, canvas.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (canvas.width - size.width) / 2,
                      y: (canvas.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    public func render(keyframes: [ReplayKeyframe], to outputURL: URL) throws {
        guard !keyframes.isEmpty else { throw ReplayError.noKeyframes }
        try? FileManager.default.removeItem(at: outputURL)

        let images: [CGImage] = try keyframes.map {
            guard let src = CGImageSourceCreateWithURL($0.imageURL as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw ReplayError.decodeFailed($0.imageURL.lastPathComponent)
            }
            return cg
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: settings.width,
                kCVPixelBufferHeightKey as String: settings.height,
            ])
        writer.add(input)
        guard writer.startWriting() else {
            throw ReplayError.writerFailed(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(1, Int(settings.duration * Double(settings.fps)))
        let segSeconds = settings.duration / Double(keyframes.count)
        let fadeStartFraction = max(0, 1 - settings.crossfade / segSeconds)

        for f in 0..<totalFrames {
            let pos = Double(f) / Double(totalFrames) * Double(keyframes.count)
            let i = min(Int(pos), keyframes.count - 1)
            let frac = pos - Double(i)
            let j = min(i + 1, keyframes.count - 1)
            let blend = (i == j || frac < fadeStartFraction)
                ? 0.0 : (frac - fadeStartFraction) / max(1e-9, 1 - fadeStartFraction)
            let caption = blend < 0.5 ? keyframes[i].caption : keyframes[j].caption
            let buffer = try makeFrame(base: images[i], next: images[j],
                                       blend: blend, caption: caption, pool: adaptor.pixelBufferPool)
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            adaptor.append(buffer, withPresentationTime:
                CMTime(value: CMTimeValue(f), timescale: CMTimeScale(settings.fps)))
        }

        input.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        guard writer.status == .completed else {
            throw ReplayError.writerFailed(writer.error?.localizedDescription ?? "\(writer.status)")
        }
    }

    private func makeFrame(base: CGImage, next: CGImage, blend: Double,
                           caption: String, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) }
        if pixelBuffer == nil {
            CVPixelBufferCreate(nil, settings.width, settings.height, kCVPixelFormatType_32ARGB,
                                [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                                &pixelBuffer)
        }
        guard let buffer = pixelBuffer else { throw ReplayError.writerFailed("pixel buffer") }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                  width: settings.width, height: settings.height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
            throw ReplayError.writerFailed("frame context")
        }
        let canvas = CGSize(width: settings.width, height: settings.height)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: canvas))

        let baseRect = Self.aspectFitRect(
            image: CGSize(width: base.width, height: base.height), in: canvas)
        ctx.draw(base, in: baseRect)
        if blend > 0 {
            let nextRect = Self.aspectFitRect(
                image: CGSize(width: next.width, height: next.height), in: canvas)
            ctx.setAlpha(CGFloat(blend))
            ctx.draw(next, in: nextRect)
            ctx.setAlpha(1)
        }

        // Caption bottom-left, safe margin, scaled to canvas height.
        let fontSize = CGFloat(settings.height) * 0.040
        let margin = CGFloat(settings.height) * 0.045
        let attr = NSAttributedString(string: caption, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ])
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        attr.draw(at: NSPoint(x: margin, y: margin))
        NSGraphicsContext.restoreGraphicsState()

        return buffer
    }
}
```

- [ ] **Step 4: Run — expect pass.** `swift test 2>&1 | tail -3`

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: ReplayGenerator — AVAssetWriter H.264 MP4 with crossfades and captions, no ffmpeg

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: SessionPipeline + End-to-End Test

**Files:**
- Create: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift`
- Test: `Tests/LiveAstroCoreTests/EndToEndTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–9.
- Produces:
  - `final class SessionPipeline { init(watchFolder: URL, profile: SessionProfile, rootDirectory: URL, replaySettings: ReplaySettings = .init(), maxKeyframes: Int = 45); var onUpdate: ((CGImage, SnapshotRecord) -> Void)?; var onLog: ((String) -> Void)?; var session: SessionManager { get }; func start() throws; func end() throws -> URL /* replay.mp4 */ }`
  - `start()`: starts session + watcher, consumes the update stream on a background Task; each update: load → stretch if linear → CGImage → snapshot → record → `onUpdate`. Any per-update error → `onLog`, broadcast state untouched (spec §7).
  - `end()`: stops watcher, ends session, selects keyframes (`FrameSelector.selectSnapshots`), captions via `IntegrationFormat.caption`, renders `replay.mp4` into the session directory, returns its URL.
- Consumers: Task 11 (AppModel wraps this), e2e test.

- [ ] **Step 1: Write failing end-to-end test**

`Tests/LiveAstroCoreTests/EndToEndTests.swift`:
```swift
import XCTest
import AVFoundation
@testable import LiveAstroCore

final class EndToEndTests: XCTestCase {
    var watchDir: URL!
    var rootDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-\(UUID().uuidString)", isDirectory: true)
        watchDir = base.appendingPathComponent("watch")
        rootDir = base.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: watchDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: watchDir.deletingLastPathComponent())
    }

    /// Fake Siril: rewrites live_stack.fit N times (partial write, pause, complete),
    /// waiting for the pipeline to accept each update before the next rewrite.
    func testFullSession() throws {
        let profile = SessionProfile(targetName: "Test Nebula", telescope: "Test APO",
                                     camera: "TestCam", subExposureSeconds: 20)
        var replay = ReplaySettings()
        replay.duration = 2; replay.fps = 10; replay.width = 320; replay.height = 180

        let pipeline = SessionPipeline(watchFolder: watchDir, profile: profile,
                                       rootDirectory: rootDir, replaySettings: replay,
                                       maxKeyframes: 10)
        let updateCount = NSLock() // simple counter guard
        var accepted = 0
        pipeline.onUpdate = { _, _ in updateCount.lock(); accepted += 1; updateCount.unlock() }
        try pipeline.start()

        let stackURL = watchDir.appendingPathComponent("live_stack.fit")
        let frames = 4
        for k in 1...frames {
            // Different content each rewrite: brightness grows with k.
            let px = (0..<(32 * 32)).map { i in
                Float(k) * 0.1 + Float(i % 32) / 320.0
            }
            let data = FITSWriter.float32(width: 32, height: 32, channels: 1, pixels: px)
            try data.prefix(data.count / 2).write(to: stackURL)   // partial
            Thread.sleep(forTimeInterval: 0.1)
            try data.write(to: stackURL)                          // complete
            // Wait until the pipeline accepts this update before writing the next.
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                updateCount.lock(); let n = accepted; updateCount.unlock()
                if n >= k { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            updateCount.lock(); let n = accepted; updateCount.unlock()
            XCTAssertGreaterThanOrEqual(n, k, "update \(k) never accepted")
        }

        let replayURL = try pipeline.end()

        // Manifest
        let manifest = try ManifestCoding.decoder().decode(
            SessionManifest.self,
            from: Data(contentsOf: pipeline.session.sessionDirectory!
                .appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.snapshots.count, frames)
        XCTAssertNotNil(manifest.endTime)
        XCTAssertEqual(manifest.snapshots.last!.estimatedIntegrationSeconds,
                       Double(frames) * 20, accuracy: 0.1)

        // Snapshots on disk
        for rec in manifest.snapshots {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: pipeline.session.sessionDirectory!.appendingPathComponent(rec.snapshotFile).path))
        }

        // Replay is a real video
        XCTAssertTrue(FileManager.default.fileExists(atPath: replayURL.path))
        let exp = expectation(description: "asset")
        Task {
            let d = try await AVURLAsset(url: replayURL).load(.duration)
            XCTAssertEqual(CMTimeGetSeconds(d), 2.0, accuracy: 0.3)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
    }
}
```

- [ ] **Step 2: Run — expect compile failure.**

- [ ] **Step 3: Implement**

`Sources/LiveAstroCore/Pipeline/SessionPipeline.swift`:
```swift
import Foundation
import CoreGraphics

public enum PipelineError: Error { case renderFailed }

/// Glue: watcher → loader → stretch → broadcast callback + snapshot + manifest (spec §5.1).
/// UI-free so the end-to-end test and the app share the same wiring.
public final class SessionPipeline {
    public let session: SessionManager
    public var onUpdate: ((CGImage, SnapshotRecord) -> Void)?
    public var onLog: ((String) -> Void)?

    private let watcher: StackFileWatcher
    private let profile: SessionProfile
    private let replaySettings: ReplaySettings
    private let maxKeyframes: Int
    private var recorder: SnapshotRecorder?
    private var consumeTask: Task<Void, Never>?

    public init(watchFolder: URL, profile: SessionProfile, rootDirectory: URL,
                replaySettings: ReplaySettings = .init(), maxKeyframes: Int = 45) {
        self.watcher = StackFileWatcher(folder: watchFolder)
        self.profile = profile
        self.session = SessionManager(rootDirectory: rootDirectory)
        self.replaySettings = replaySettings
        self.maxKeyframes = maxKeyframes
    }

    public func start() throws {
        let dir = try session.startSession(profile: profile)
        recorder = SnapshotRecorder(sessionDirectory: dir)
        try watcher.start()
        consumeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let stream = self?.watcher.updates else { return }
            for await update in stream {
                self?.handle(update)
            }
        }
    }

    private func handle(_ update: StackUpdate) {
        do {
            let linear = try ImageLoader.load(url: update.url)
            let display = linear.sourceIsLinear ? AutoStretch.stretch(linear) : linear
            guard let cg = AutoStretch.makeCGImage(display) else {
                throw ImageLoaderError.decodeFailed("CGImage packing")
            }
            let index = session.acceptedCount + 1
            let record = try recorder!.save(
                cgImage: cg, linear: linear, sourceFile: update.url.lastPathComponent,
                index: index, timestamp: Date(),
                estimatedIntegrationSeconds: Double(index) * profile.subExposureSeconds)
            try session.recordSnapshot(record)
            onUpdate?(cg, record)
        } catch {
            // Spec §7: skip bad updates, keep the last good frame on the broadcast.
            onLog?("Skipped update (\(update.url.lastPathComponent)): \(error)")
        }
    }

    /// Ends the session and renders replay.mp4. Synchronous — call off the main thread.
    public func end() throws -> URL {
        watcher.stop()
        consumeTask?.cancel()
        try session.endSession()
        guard let dir = session.sessionDirectory, let manifest = session.manifest else {
            throw SessionError.notRunning
        }
        let snapshots = manifest.snapshots
        let urls = snapshots.map { dir.appendingPathComponent($0.snapshotFile) }
        let outputURL = dir.appendingPathComponent("replay.mp4")
        guard !urls.isEmpty else { return outputURL } // empty session: no replay to render
        let picked = try FrameSelector.selectSnapshots(urls: urls, maxKeyframes: maxKeyframes)
        let keyframes = picked.map { i in
            ReplayKeyframe(
                imageURL: urls[i],
                caption: "\(manifest.targetName) — " + IntegrationFormat.caption(
                    seconds: snapshots[i].estimatedIntegrationSeconds,
                    frames: snapshots[i].index,
                    subSeconds: manifest.subExposureSeconds))
        }
        try ReplayGenerator(settings: replaySettings).render(keyframes: keyframes, to: outputURL)
        return outputURL
    }
}
```

- [ ] **Step 4: Run full suite — expect pass.** `swift test 2>&1 | tail -3` (e2e takes ~15–20 s wall clock — watcher debounce cycles).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: SessionPipeline glue + fake-Siril end-to-end test (watch -> stretch -> snapshot -> manifest -> replay)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 11: SwiftUI App — Control Window + Broadcast Window

**Files:**
- Delete: `Sources/LiveAstroStudio/main.swift`
- Create: `Sources/LiveAstroStudio/LiveAstroApp.swift`, `Sources/LiveAstroStudio/AppModel.swift`, `Sources/LiveAstroStudio/ControlView.swift`, `Sources/LiveAstroStudio/BroadcastView.swift`

**Interfaces:**
- Consumes: `SessionPipeline`, `SessionProfile`, `SnapshotRecord`, `IntegrationFormat`.
- Produces: runnable GUI (`swift run LiveAstroStudio`). No core logic here — UI state + wiring only. No automated UI tests (core is covered); manual smoke check in Step 3.

- [ ] **Step 1: Implement the four files**

`Sources/LiveAstroStudio/LiveAstroApp.swift`:
```swift
import SwiftUI
import AppKit

@main
struct LiveAstroApp: App {
    @State private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup("LiveAstro Control") {
            ControlView().environment(model)
        }
        .defaultSize(width: 460, height: 640)

        Window("LiveAstro Broadcast", id: "broadcast") {
            BroadcastView()
                .environment(model)
                .frame(width: 1920, height: 1080)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
```

`Sources/LiveAstroStudio/AppModel.swift`:
```swift
import SwiftUI
import LiveAstroCore

@Observable
@MainActor
final class AppModel {
    // Session profile draft (bound to the control form)
    var targetName = ""
    var telescope = ""
    var camera = ""
    var mount = ""
    var filter = ""
    var locationLabel = ""
    var bortleText = ""
    var subExposureText = "60"
    var notes = ""

    var watchFolder: URL?
    var isRunning = false
    var latestImage: CGImage?
    var latestRecord: SnapshotRecord?
    var sessionStart: Date?
    var log: [String] = []
    var replayURL: URL?
    var isGeneratingReplay = false
    var errorMessage: String?

    private var pipeline: SessionPipeline?

    var profile: SessionProfile {
        SessionProfile(targetName: targetName, telescope: telescope, camera: camera,
                       mount: mount, filter: filter, locationLabel: locationLabel,
                       bortle: Int(bortleText), subExposureSeconds: Double(subExposureText) ?? 60,
                       notes: notes)
    }

    var integrationCaption: String {
        guard let rec = latestRecord else { return "waiting for first stack…" }
        return IntegrationFormat.caption(seconds: rec.estimatedIntegrationSeconds,
                                         frames: rec.index,
                                         subSeconds: profile.subExposureSeconds)
    }

    func startSession() {
        guard let folder = watchFolder else { errorMessage = "Pick a watch folder first."; return }
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveAstro", isDirectory: true)
        let p = SessionPipeline(watchFolder: folder, profile: profile, rootDirectory: root)
        p.onUpdate = { [weak self] image, record in
            Task { @MainActor in
                self?.latestImage = image
                self?.latestRecord = record
                self?.log.append("✓ update \(record.index) — \(record.snapshotFile)")
            }
        }
        p.onLog = { [weak self] message in
            Task { @MainActor in self?.log.append("⚠ \(message)") }
        }
        do {
            try p.start()
            pipeline = p
            isRunning = true
            sessionStart = Date()
            replayURL = nil
            log.append("Session started — watching \(folder.path)")
        } catch {
            errorMessage = "Start failed: \(error.localizedDescription)"
        }
    }

    func endSession() {
        guard let p = pipeline else { return }
        isGeneratingReplay = true
        log.append("Ending session — generating replay…")
        Task.detached { [weak self] in
            do {
                let url = try p.end()
                await MainActor.run {
                    self?.replayURL = url
                    self?.log.append("Replay ready: \(url.lastPathComponent)")
                }
            } catch {
                await MainActor.run { self?.errorMessage = "Replay failed: \(error)" }
            }
            await MainActor.run {
                self?.isRunning = false
                self?.isGeneratingReplay = false
                self?.pipeline = nil
            }
        }
    }
}
```

`Sources/LiveAstroStudio/ControlView.swift`:
```swift
import SwiftUI
import AppKit

struct ControlView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Watch Folder") {
                HStack {
                    Text(model.watchFolder?.path ?? "none selected")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { pickFolder() }.disabled(model.isRunning)
                }
            }
            Section("Session Profile") {
                TextField("Target name", text: $model.targetName)
                TextField("Telescope", text: $model.telescope)
                TextField("Camera", text: $model.camera)
                TextField("Mount", text: $model.mount)
                TextField("Filter", text: $model.filter)
                TextField("Location", text: $model.locationLabel)
                TextField("Bortle (1–9)", text: $model.bortleText)
                TextField("Sub-exposure seconds", text: $model.subExposureText)
                TextField("Notes", text: $model.notes)
            }
            Section {
                HStack {
                    Button("Open Broadcast Window") { openWindow(id: "broadcast") }
                    Spacer()
                    if model.isRunning {
                        Button("End Session", role: .destructive) { model.endSession() }
                            .disabled(model.isGeneratingReplay)
                    } else {
                        Button("Start Session") { model.startSession() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if model.isGeneratingReplay { ProgressView("Rendering replay…") }
                if let url = model.replayURL {
                    Button("Reveal Replay in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
            Section("Log") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.log.suffix(200).enumerated()), id: \.offset) {
                            Text($0.element).font(.system(.caption, design: .monospaced))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 120)
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
        .alert("LiveAstro", isPresented: .constant(model.errorMessage != nil)) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { model.watchFolder = panel.url }
    }
}
```

`Sources/LiveAstroStudio/BroadcastView.swift`:
```swift
import SwiftUI
import LiveAstroCore

/// The OBS-captured scene: dark, non-interactive, never blanks (spec §5.6).
struct BroadcastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Color.black
            if let cg = model.latestImage {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
            overlay
        }
        .ignoresSafeArea()
    }

    private var overlay: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.targetName.isEmpty ? "LiveAstro" : model.targetName)
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                    Text(model.integrationCaption)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(equipmentLine)
                        .font(.system(size: 24, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(elapsedLine)
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(64) // safe margins
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.8), radius: 6)
    }

    private var equipmentLine: String {
        var parts = [model.telescope, model.camera].filter { !$0.isEmpty }
        if !model.locationLabel.isEmpty {
            let bortle = model.bortleText.isEmpty ? "" : " · Bortle \(model.bortleText)"
            parts.append(model.locationLabel + bortle)
        }
        return parts.joined(separator: "  ·  ")
    }

    private var elapsedLine: String {
        guard let start = model.sessionStart else { return "" }
        let s = Int(Date().timeIntervalSince(start))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
```

- [ ] **Step 2: Build + full test suite**

Run: `swift build && swift test 2>&1 | tail -3` — Expected: build succeeds, all tests still pass.

- [ ] **Step 3: Manual smoke test**

Run: `swift run LiveAstroStudio`
Expected: Control window opens. Click "Open Broadcast Window" → 1920×1080 dark window with "LiveAstro" headline. Pick a temp folder, Start Session, copy any `.fit`/`.png` into it → image appears in broadcast window and log shows `✓ update 1`. End Session → replay generates, Reveal button appears. Quit with Cmd+Q.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: SwiftUI app — control window + 1920x1080 broadcast window wired to SessionPipeline

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 12: fakesiril Tool, README, OBS/YouTube Validation Checklist

**Files:**
- Modify: `Package.swift` (add `fakesiril` executable target)
- Create: `Sources/fakesiril/main.swift`, `README.md`, `docs/validation/obs-youtube-checklist.md`

**Interfaces:**
- Consumes: `FITSWriter`.
- Produces: `swift run fakesiril <folder> [--interval N] [--count N]` — simulates Siril livestack for demos and manual testing. Plus human-facing docs. The checklist is the **MVP DoD gate** (spec §10): a real YouTube stream must be run and results recorded before v1 is called done.

- [ ] **Step 1: Add target to Package.swift**

Replace the `targets:` array with:
```swift
    targets: [
        .target(name: "LiveAstroCore"),
        .executableTarget(name: "LiveAstroStudio", dependencies: ["LiveAstroCore"]),
        .executableTarget(name: "fakesiril", dependencies: ["LiveAstroCore"]),
        .testTarget(name: "LiveAstroCoreTests", dependencies: ["LiveAstroCore"]),
    ]
```

- [ ] **Step 2: Implement fakesiril**

`Sources/fakesiril/main.swift`:
```swift
import Foundation
import LiveAstroCore

// Simulates Siril livestacking: rewrites live_stack.fit in place with growing SNR,
// including a partial-write phase to exercise the watcher's completeness check.
// Usage: swift run fakesiril <folder> [--interval seconds] [--count n]

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: fakesiril <folder> [--interval 5] [--count 40]")
    exit(1)
}
let folder = URL(fileURLWithPath: args[1], isDirectory: true)
func option(_ name: String, default value: Double) -> Double {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Double(args[i + 1]) else { return value }
    return v
}
let interval = option("--interval", default: 5)
let count = Int(option("--count", default: 40))

try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let url = folder.appendingPathComponent("live_stack.fit")
let width = 800, height = 500

// Fixed synthetic starfield (seeded LCG so every run looks the same).
var seed: UInt64 = 0x5EED
func rand() -> Double {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Double(seed >> 33) / Double(UInt32.max)
}
let stars: [(x: Int, y: Int, brightness: Double)] = (0..<120).map { _ in
    (Int(rand() * Double(width)), Int(rand() * Double(height)), 0.3 + rand() * 0.7)
}

for k in 1...count {
    // Signal grows linearly with k; noise stddev shrinks like 1/sqrt(k). Classic stacking behavior.
    let noiseScale = 0.08 / Double(k).squareRoot()
    var px = [Float](repeating: 0, count: width * height)
    for i in 0..<px.count {
        px[i] = Float(max(0, 0.02 + (rand() - 0.5) * 2 * noiseScale))
    }
    for s in stars {
        let signal = Float(min(1, s.brightness * (0.3 + 0.7 * Double(k) / Double(count))))
        for dy in -2...2 {
            for dx in -2...2 {
                let x = s.x + dx, y = s.y + dy
                guard x >= 0, x < width, y >= 0, y < height else { continue }
                let falloff = Float(1) / Float(1 + dx * dx + dy * dy)
                let idx = y * width + x
                px[idx] = min(1, px[idx] + signal * falloff)
            }
        }
    }
    let data = FITSWriter.float32(width: width, height: height, channels: 1, pixels: px)
    try data.prefix(data.count / 2).write(to: url)   // partial write
    Thread.sleep(forTimeInterval: 0.3)
    try data.write(to: url)                          // complete write
    print("fakesiril: stack update \(k)/\(count)")
    if k < count { Thread.sleep(forTimeInterval: interval) }
}
print("fakesiril: done")
```

- [ ] **Step 3: Verify fakesiril drives the app**

Run in terminal 1: `swift run LiveAstroStudio` — pick `/tmp/fakestack` as watch folder (create it first: `mkdir -p /tmp/fakestack`), Start Session.
Run in terminal 2: `swift run fakesiril /tmp/fakestack --interval 3 --count 10`
Expected: broadcast window updates ~every 3 s with a starfield that visibly cleans up; End Session produces a replay MP4 that shows noise decreasing.

- [ ] **Step 4: Write README.md**

```markdown
# LiveAstro Studio

Turn a live astrophotography session into a polished livestream and an automatic
recap video — without manual video editing.

LiveAstro Studio watches your live-stacker's output (Siril `live_stack.fit`,
or PNG/JPG/TIFF), shows the latest stack in a clean 1920×1080 broadcast window
for OBS, records a snapshot on every stack update, and renders a 45-second
"stack evolution" MP4 when you end the session.

## Requirements

- macOS 14+
- [Siril](https://siril.org) (or any tool that periodically writes a stack image to a folder)
- [OBS](https://obsproject.com) for streaming

## Run

```bash
swift run LiveAstroStudio
```

1. Choose the folder Siril's livestack writes into.
2. Fill in the session profile (target, scope, camera, sub length…).
3. Open the Broadcast Window; in OBS add a **Window Capture** for "LiveAstro Broadcast".
4. Start Session. Stream from OBS as usual.
5. End Session → `~/Documents/LiveAstro/<session>/replay.mp4`.

## Demo without a telescope

```bash
mkdir -p /tmp/fakestack
swift run fakesiril /tmp/fakestack --interval 3 --count 20
```

Point the watch folder at `/tmp/fakestack`.

## Development

```bash
swift test   # full suite, no hardware needed
```

Design spec: `docs/superpowers/specs/2026-07-05-liveastro-studio-v1-design.md`
```

- [ ] **Step 5: Write the validation checklist**

`docs/validation/obs-youtube-checklist.md`:
```markdown
# OBS + YouTube End-to-End Validation (MVP DoD gate)

Spec §10 requires a real session streamed to YouTube via OBS before v1 is done.
Record results inline; this file is the evidence.

## Setup
- [ ] LiveAstro Studio running; broadcast window open (1920×1080)
- [ ] OBS: Settings → Video → Base & Output canvas 1920×1080, 30 fps
- [ ] OBS: add Source → macOS Screen Capture (or Window Capture) → window "LiveAstro Broadcast"
- [ ] Grant macOS Screen Recording permission to OBS if prompted
- [ ] Source fills the canvas exactly (right-click → Transform → Fit to screen)
- [ ] YouTube Studio → Create → Go Live → obtain stream key (set visibility **Unlisted** for the test)
- [ ] OBS: Settings → Stream → YouTube, paste key

## Live test (can use fakesiril if the sky doesn't cooperate)
- [ ] Start Session in LiveAstro; confirm stack updates appear
- [ ] Start Streaming in OBS; watch the YouTube preview
- [ ] Verify on a second device (phone): image updates visible within one stack cadence
- [ ] Verify overlay legibility at YouTube 1080p compression: target name, integration
      counter, equipment line, elapsed clock all readable
- [ ] Let it run ≥ 15 minutes; confirm no broadcast-window blanking or stutter
- [ ] End Session in LiveAstro while still streaming; confirm broadcast window keeps
      the final frame (no black flash on stream)
- [ ] Stop streaming; confirm replay.mp4 plays in QuickTime and looks correct

## Results
| Date | Source (real Siril / fakesiril) | Stream URL | Overlay legible? | Issues |
|------|--------------------------------|-----------|------------------|--------|
|      |                                |           |                  |        |
```

- [ ] **Step 6: Build, test, commit**

Run: `swift build && swift test 2>&1 | tail -3` — Expected: all green.

```bash
git add -A && git commit -m "feat: fakesiril simulator, README, OBS/YouTube validation checklist

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Plan Self-Review (completed)

- **Spec coverage:** §5.2 watcher → Task 5; §5.3 loader → Tasks 2–3; §5.4 stretch → Task 4; §5.5 session → Task 6; §5.6 broadcast → Task 11; §5.7 snapshots → Task 7; §5.8 replay → Tasks 8–9; §6 storage/manifest → Task 6; §7 error handling → Tasks 5/10/11 (skip-and-hold, atomic manifest) — *crash-resume offer (spec §7 last row) deferred to post-MVP; not in DoD*; §8 testing → every task + Task 10 e2e; §10 DoD → Tasks 11–12 + checklist.
- **Placeholder scan:** none — every code step is complete source.
- **Type consistency:** `AstroImage(width:height:channels:pixels:sourceIsLinear:)`, `FrameSelector.selectSnapshots(urls:maxKeyframes:)`, `IntegrationFormat.caption(seconds:frames:subSeconds:)`, `SessionPipeline.end() throws -> URL` used consistently across Tasks 3–11.
