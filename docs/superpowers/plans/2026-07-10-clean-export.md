# Clean Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export a color-balanced, header-complete, FITS-standard-compliant `master.fit` so LiveAstro → Siril/PixInsight (plate solve, SPCC, dark/flat matching) works with no friction or warnings.

**Architecture:** The raw subs already carry all astronomical metadata (OBJECT/RA/DEC/FOCALLEN/pixel size/etc.); Clean Export *propagates* it. A pure `SourceMetadata` parser turns the first sub's FITS keywords into a struct; the FITS writer is fixed to emit standard fixed-format cards plus that metadata; the session pipeline captures the metadata from the first accepted frame and applies additive-only background neutralization to the master before writing.

**Tech Stack:** Swift 5.10, macOS 14+, LiveAstroCore (Foundation only, zero external deps), XCTest.

## Global Constraints

- Swift 5.10, macOS 14+. LiveAstroCore uses **Foundation only** — zero external dependencies.
- Core tests run via `swift test --filter LiveAstroCoreTests`.
- `StackAccumulator` stays **UNCHANGED**.
- `neutralizeBackgroundAdditive` on the master is **additive-only** — do NOT apply the multiplicative `neutralizeBackground` to the saved master. The live display path (`SessionPipeline.displayCGImage`) keeps full additive+multiplicative — a deliberate asymmetry; do not change it.
- RA/DEC are written **verbatim as decimal degrees** (what the Seestar records and Siril reads) — no sexagesimal conversion.
- The RGB master is already debayered — **never write `BAYERPAT`** on a 3-channel master.
- FITS cards must be **standard fixed-format**: value indicator `= ` in columns 9–10; numeric/logical values right-justified ending at column 30; quoted strings starting at column 11. This is the fix for Siril's "SIMPLE card doesn't respect the FITS Standard" warning.
- Every FITS header is padded to a 2880-byte block boundary.
- TDD throughout; frequent commits.

---

### Task 1: `SourceMetadata` struct + FITS-keyword parser

**Files:**
- Create: `Sources/LiveAstroCore/FITS/SourceMetadata.swift`
- Test: `Tests/LiveAstroCoreTests/SourceMetadataTests.swift`

**Interfaces:**
- Consumes: nothing (pure).
- Produces: `public struct SourceMetadata: Equatable` with `public init(fitsKeywords: [String: String])`; fields (all `Optional`): `object: String?`, `ra: Double?`, `dec: Double?`, `focalLengthMM: Double?`, `pixelSizeUM: Double?`, `instrument: String?`, `telescope: String?`, `filter: String?`, `exposureSeconds: Double?`, `dateObs: String?`, `gain: Double?`, `ccdTempC: Double?`, `siteLat: Double?`, `siteLon: Double?`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class SourceMetadataTests: XCTestCase {
    // Real cards from a Seestar S30 Pro sub (values verbatim).
    private let seestar: [String: String] = [
        "OBJECT": "NGC 6960", "RA": "314.36667", "DEC": "31.834722",
        "FOCALLEN": "160.0", "XPIXSZ": "2.90000009536743", "YPIXSZ": "2.90000009536743",
        "INSTRUME": "imx585", "TELESCOP": "S30 Pro_041c45cb", "FILTER": "LP",
        "EXPTIME": "30.0", "DATE-OBS": "2026-07-10T03:51:36.210844",
        "GAIN": "200", "CCD-TEMP": "35.0", "SITELAT": "30.5699", "SITELONG": "-97.6027",
    ]

    func testParsesSeestarHeader() {
        let m = SourceMetadata(fitsKeywords: seestar)
        XCTAssertEqual(m.object, "NGC 6960")
        XCTAssertEqual(m.ra ?? 0, 314.36667, accuracy: 1e-5)
        XCTAssertEqual(m.dec ?? 0, 31.834722, accuracy: 1e-5)
        XCTAssertEqual(m.focalLengthMM ?? 0, 160.0, accuracy: 1e-6)
        XCTAssertEqual(m.pixelSizeUM ?? 0, 2.9, accuracy: 1e-3)
        XCTAssertEqual(m.instrument, "imx585")
        XCTAssertEqual(m.telescope, "S30 Pro_041c45cb")
        XCTAssertEqual(m.filter, "LP")
        XCTAssertEqual(m.exposureSeconds ?? 0, 30.0, accuracy: 1e-6)
        XCTAssertEqual(m.dateObs, "2026-07-10T03:51:36.210844")
        XCTAssertEqual(m.gain ?? 0, 200, accuracy: 1e-6)
        XCTAssertEqual(m.siteLat ?? 0, 30.5699, accuracy: 1e-4)
        XCTAssertEqual(m.siteLon ?? 0, -97.6027, accuracy: 1e-4)
    }

    func testStripsQuotesAndWhitespace() {
        let m = SourceMetadata(fitsKeywords: ["OBJECT": "'NGC 6960 '", "RA": " 314.5 "])
        XCTAssertEqual(m.object, "NGC 6960")   // quotes stripped, trailing space trimmed
        XCTAssertEqual(m.ra ?? 0, 314.5, accuracy: 1e-6)
    }

    func testMissingCardsAreNil() {
        let m = SourceMetadata(fitsKeywords: ["OBJECT": "M31"])
        XCTAssertEqual(m.object, "M31")
        XCTAssertNil(m.ra); XCTAssertNil(m.dec); XCTAssertNil(m.focalLengthMM)
        XCTAssertNil(m.filter); XCTAssertNil(m.dateObs); XCTAssertNil(m.gain)
    }

    func testEmptyIsAllNil() {
        let m = SourceMetadata(fitsKeywords: [:])
        XCTAssertEqual(m, SourceMetadata(fitsKeywords: [:]))
        XCTAssertNil(m.object); XCTAssertNil(m.ra)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SourceMetadataTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'SourceMetadata' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Astronomical metadata read from a source sub's FITS header, propagated to
/// the exported master. All fields optional — absent cards stay nil.
public struct SourceMetadata: Equatable {
    public var object: String?
    public var ra: Double?          // decimal degrees, verbatim from source
    public var dec: Double?         // decimal degrees, verbatim from source
    public var focalLengthMM: Double?
    public var pixelSizeUM: Double?
    public var instrument: String?
    public var telescope: String?
    public var filter: String?
    public var exposureSeconds: Double?
    public var dateObs: String?     // ISO-ish string, verbatim
    public var gain: Double?
    public var ccdTempC: Double?
    public var siteLat: Double?
    public var siteLon: Double?

    public init() {}

    public init(fitsKeywords k: [String: String]) {
        func clean(_ key: String) -> String? {
            guard let raw = k[key] else { return nil }
            var s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("'") && s.hasSuffix("'") && s.count >= 2 {
                s = String(s.dropFirst().dropLast())
            }
            s = s.trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? nil : s
        }
        func num(_ key: String) -> Double? { clean(key).flatMap { Double($0) } }

        object = clean("OBJECT")
        ra = num("RA"); dec = num("DEC")
        focalLengthMM = num("FOCALLEN")
        pixelSizeUM = num("XPIXSZ") ?? num("YPIXSZ")
        instrument = clean("INSTRUME")
        telescope = clean("TELESCOP")
        filter = clean("FILTER")
        exposureSeconds = num("EXPTIME") ?? num("EXPOSURE")
        dateObs = clean("DATE-OBS")
        gain = num("GAIN")
        ccdTempC = num("CCD-TEMP")
        siteLat = num("SITELAT")
        siteLon = num("SITELONG")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SourceMetadataTests 2>&1 | tail -5`
Expected: PASS — 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/FITS/SourceMetadata.swift Tests/LiveAstroCoreTests/SourceMetadataTests.swift
git commit -m "feat: SourceMetadata parser from FITS keywords"
```

---

### Task 2: FITSWriter — FITS-standard fixed-format cards

**Files:**
- Modify: `Sources/LiveAstroCore/FITS/FITSWriter.swift:11-20`
- Test: `Tests/LiveAstroCoreTests/FITSWriterFormatTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: no signature change to `FITSWriter.float32(width:height:channels:pixels:bottomUp:)`; only the emitted card *bytes* change to standard fixed-format. Later tasks rely on `card`/`cardStr` helpers existing inside `float32`.

**Context:** Today `card("SIMPLE","T")` emits `"SIMPLE  = T"` left-justified — non-standard, which is what makes Siril warn. Fixed-format requires the value indicator `= ` in columns 9–10 (0-indexed bytes 8–9) and the value right-justified ending at column 30 (numeric/logical), or a quoted string starting at column 11.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class FITSWriterFormatTests: XCTestCase {
    private func header(_ data: Data) -> String {
        // header is ASCII up to and including the END card's block
        String(data: data.prefix(2880), encoding: .ascii)!
    }
    private func card(_ header: String, at index: Int) -> String {
        let start = header.index(header.startIndex, offsetBy: index * 80)
        let end = header.index(start, offsetBy: 80)
        return String(header[start..<end])
    }

    func testSimpleCardIsFixedFormat() {
        let d = FITSWriter.float32(width: 2, height: 2, channels: 1, pixels: [0,0,0,0])
        let c = card(header(d), at: 0)
        // "SIMPLE  =                    T" — 'T' at column 30 (index 29)
        XCTAssertTrue(c.hasPrefix("SIMPLE  = "))
        XCTAssertEqual(Array(c)[29], "T")
        XCTAssertEqual(c.count, 80)
    }

    func testIntegerCardsRightJustifiedToCol30() {
        let d = FITSWriter.float32(width: 5, height: 7, channels: 1, pixels: [Float](repeating: 0, count: 35))
        let h = header(d)
        // NAXIS1 = 5 : '5' ends at column 30 (index 29)
        let naxis1 = (0..<10).map { card(h, at: $0) }.first { $0.hasPrefix("NAXIS1 ") }!
        XCTAssertEqual(Array(naxis1)[29], "5")
        let bitpix = (0..<10).map { card(h, at: $0) }.first { $0.hasPrefix("BITPIX ") }!
        XCTAssertTrue(bitpix.hasPrefix("BITPIX  = "))
        // BITPIX -32: '2' at col 30
        XCTAssertEqual(Array(bitpix)[29], "2")
    }

    func testStringCardQuotedFromCol11() {
        let d = FITSWriter.float32(width: 2, height: 2, channels: 1, pixels: [0,0,0,0])
        let roworder = (0..<10).map { card(header(d), at: $0) }.first { $0.hasPrefix("ROWORDER") }!
        // quoted string: opening quote at column 11 (index 10)
        XCTAssertEqual(Array(roworder)[10], "'")
        XCTAssertTrue(roworder.contains("TOP-DOWN"))
    }

    func testHeaderIsBlockAligned() {
        let d = FITSWriter.float32(width: 3, height: 3, channels: 3, pixels: [Float](repeating: 0, count: 27))
        // find END card, header length must be a 2880 multiple
        XCTAssertEqual(d.count % 2880, 0)
    }

    func testStillRoundTripsThroughReader() throws {
        let px: [Float] = (0..<12).map { Float($0) / 12.0 }
        let d = FITSWriter.float32(width: 2, height: 2, channels: 3, pixels: px)
        let img = try FITSReader.readImage(d)   // existing reader entry point
        XCTAssertEqual(img.width, 2); XCTAssertEqual(img.height, 2); XCTAssertEqual(img.channels, 3)
    }
}
```

> If `FITSReader.readImage` is not the exact reader entry point, use the one the existing `FITSReaderTests` use (check `Tests/LiveAstroCoreTests/FITSReaderTests.swift` — e.g. `testFloat32RoundTripRGB`) and mirror it.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FITSWriterFormatTests 2>&1 | tail -8`
Expected: FAIL — `testSimpleCardIsFixedFormat` fails (current 'T' is at index 10, not 29).

- [ ] **Step 3: Write minimal implementation**

Replace the `card` helper and structural-card construction (FITSWriter.swift lines 11–20) with fixed-format helpers:

```swift
// Fixed-format numeric/logical card: value right-justified, ending at column 30.
func card(_ key: String, _ value: String) -> String {
    let k = key.padding(toLength: 8, withPad: " ", startingAt: 0)
    let valField = String(repeating: " ", count: max(0, 20 - value.count)) + value  // cols 11-30
    return "\(k)= \(valField)".padding(toLength: 80, withPad: " ", startingAt: 0)
}
// Fixed-format string card: single-quoted, left-justified from column 11,
// padded to at least 8 chars inside the quotes (FITS §4.2.1).
func cardStr(_ key: String, _ value: String) -> String {
    let k = key.padding(toLength: 8, withPad: " ", startingAt: 0)
    let inner = value.count < 8 ? value.padding(toLength: 8, withPad: " ", startingAt: 0) : value
    return "\(k)= '\(inner)'".padding(toLength: 80, withPad: " ", startingAt: 0)
}
var cards = [card("SIMPLE", "T"), card("BITPIX", "-32"),
             card("NAXIS", channels == 1 ? "2" : "3"),
             card("NAXIS1", "\(width)"), card("NAXIS2", "\(height)")]
if channels == 3 { cards.append(card("NAXIS3", "3")) }
cards.append(cardStr("ROWORDER", bottomUp ? "BOTTOM-UP" : "TOP-DOWN"))
```

(Everything from `var s = cards.joined() ...` onward stays unchanged.)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FITSWriterFormatTests 2>&1 | tail -5`
Then regression: `swift test --filter FITSReaderTests 2>&1 | tail -5`
Expected: both PASS (reader still round-trips; `testBottomUpRowsAreFlipped` still passes — ROWORDER value unchanged, only quoting/format changed).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/FITS/FITSWriter.swift Tests/LiveAstroCoreTests/FITSWriterFormatTests.swift
git commit -m "fix: FITS-standard fixed-format cards (kills Siril SIMPLE-card warning)"
```

---

### Task 3: FITSWriter — optional metadata + stacking cards

**Files:**
- Modify: `Sources/LiveAstroCore/FITS/FITSWriter.swift` (add an overload/params to `float32`)
- Test: `Tests/LiveAstroCoreTests/FITSWriterMetadataTests.swift`

**Interfaces:**
- Consumes: `SourceMetadata` (Task 1); the `card`/`cardStr` helpers (Task 2).
- Produces: `FITSWriter.float32(width:height:channels:pixels:bottomUp:metadata:stackCount:totalExposureSeconds:)` where `metadata: SourceMetadata? = nil`, `stackCount: Int? = nil`, `totalExposureSeconds: Double? = nil` — all defaulted so existing call sites keep working. Emits propagated cards (only for non-nil fields), `STACKCNT`, `TOTALEXP`, and a `HISTORY` provenance card. Never emits `BAYERPAT`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class FITSWriterMetadataTests: XCTestCase {
    private func headerText(_ data: Data) -> String {
        // read ASCII header blocks until END
        var text = ""
        var offset = 0
        while offset < data.count {
            let block = String(data: data.subdata(in: offset..<min(offset+2880, data.count)), encoding: .ascii) ?? ""
            text += block; offset += 2880
            if block.contains("END     ") { break }
        }
        return text
    }

    func testEmitsMetadataCards() {
        var m = SourceMetadata()
        m.object = "NGC 6960"; m.ra = 314.36667; m.dec = 31.834722
        m.focalLengthMM = 160; m.pixelSizeUM = 2.9; m.filter = "LP"
        m.exposureSeconds = 30; m.dateObs = "2026-07-10T03:51:36"
        let d = FITSWriter.float32(width: 2, height: 2, channels: 3,
                                   pixels: [Float](repeating: 0, count: 12),
                                   metadata: m, stackCount: 606, totalExposureSeconds: 18180)
        let h = headerText(d)
        XCTAssertTrue(h.contains("OBJECT  = 'NGC 6960"))
        XCTAssertTrue(h.contains("RA      ="))
        XCTAssertTrue(h.contains("314.36667"))
        XCTAssertTrue(h.contains("DEC     ="))
        XCTAssertTrue(h.contains("FOCALLEN="))
        XCTAssertTrue(h.contains("FILTER  = 'LP"))
        XCTAssertTrue(h.contains("STACKCNT="))
        XCTAssertTrue(h.contains("606"))
        XCTAssertTrue(h.contains("TOTALEXP="))
        XCTAssertTrue(h.contains("HISTORY"))
    }

    func testNeverEmitsBayerPatternOnRGB() {
        var m = SourceMetadata(); m.object = "X"
        let d = FITSWriter.float32(width: 2, height: 2, channels: 3,
                                   pixels: [Float](repeating: 0, count: 12), metadata: m)
        XCTAssertFalse(headerText(d).contains("BAYERPAT"))
    }

    func testNilFieldsOmitted() {
        var m = SourceMetadata(); m.object = "M31"   // everything else nil
        let d = FITSWriter.float32(width: 2, height: 2, channels: 1,
                                   pixels: [0,0,0,0], metadata: m)
        let h = headerText(d)
        XCTAssertTrue(h.contains("OBJECT  = 'M31"))
        XCTAssertFalse(h.contains("RA      ="))
        XCTAssertFalse(h.contains("FOCALLEN="))
        XCTAssertFalse(h.contains("FILTER  ="))
    }

    func testMetadataRoundTripsThroughReader() throws {
        var m = SourceMetadata(); m.object = "NGC 6960"; m.ra = 314.36667
        let d = FITSWriter.float32(width: 2, height: 2, channels: 3,
                                   pixels: [Float](repeating: 0, count: 12), metadata: m)
        let hdr = try FITSReader.readHeader(d)
        XCTAssertEqual(hdr.keywords["OBJECT"]?.replacingOccurrences(of: "'", with: "").trimmingCharacters(in: .whitespaces), "NGC 6960")
        XCTAssertEqual(Double(hdr.keywords["RA"]!.trimmingCharacters(in: .whitespaces))!, 314.36667, accuracy: 1e-5)
    }

    func testNoMetadataMatchesTask2Output() {
        let px = [Float](repeating: 0.25, count: 12)
        let a = FITSWriter.float32(width: 2, height: 2, channels: 3, pixels: px)
        let b = FITSWriter.float32(width: 2, height: 2, channels: 3, pixels: px, metadata: nil)
        XCTAssertEqual(a, b)   // defaulted metadata == no metadata
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FITSWriterMetadataTests 2>&1 | tail -8`
Expected: FAIL — `float32` has no `metadata:` parameter (compile error).

- [ ] **Step 3: Write minimal implementation**

Change the `float32` signature and append metadata cards after the structural cards (before the `ROWORDER`/END assembly is fine — append to `cards` before joining). Add the parameters:

```swift
public static func float32(width: Int, height: Int, channels: Int,
                           pixels: [Float], bottomUp: Bool = false,
                           metadata: SourceMetadata? = nil,
                           stackCount: Int? = nil,
                           totalExposureSeconds: Double? = nil) -> Data {
```

After the existing `cards.append(cardStr("ROWORDER", ...))` line, insert:

```swift
    if let m = metadata {
        if let v = m.object { cards.append(cardStr("OBJECT", v)) }
        if let v = m.ra { cards.append(card("RA", trim(v))) }
        if let v = m.dec { cards.append(card("DEC", trim(v))) }
        if let v = m.focalLengthMM { cards.append(card("FOCALLEN", trim(v))) }
        if let v = m.pixelSizeUM { cards.append(card("XPIXSZ", trim(v))); cards.append(card("YPIXSZ", trim(v))) }
        if let v = m.instrument { cards.append(cardStr("INSTRUME", v)) }
        if let v = m.telescope { cards.append(cardStr("TELESCOP", v)) }
        if let v = m.filter { cards.append(cardStr("FILTER", v)) }
        if let v = m.exposureSeconds { cards.append(card("EXPTIME", trim(v))) }
        if let v = m.dateObs { cards.append(cardStr("DATE-OBS", v)) }
        if let v = m.gain { cards.append(card("GAIN", trim(v))) }
        if let v = m.ccdTempC { cards.append(card("CCD-TEMP", trim(v))) }
        if let v = m.siteLat { cards.append(card("SITELAT", trim(v))) }
        if let v = m.siteLon { cards.append(card("SITELONG", trim(v))) }
    }
    if let n = stackCount { cards.append(card("STACKCNT", "\(n)")) }
    if let t = totalExposureSeconds { cards.append(card("TOTALEXP", trim(t))) }
    cards.append("HISTORY Stacked by LiveAstro Studio".padding(toLength: 80, withPad: " ", startingAt: 0))
    // Note: BAYERPAT intentionally omitted — the RGB master is already debayered.
```

Add a small `trim` helper next to `card`/`cardStr` (formats doubles without trailing noise):

```swift
    func trim(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
        return String(d)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FITSWriterMetadataTests 2>&1 | tail -5`
Then: `swift test --filter "FITSWriterFormatTests|FITSReaderTests" 2>&1 | tail -5`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/FITS/FITSWriter.swift Tests/LiveAstroCoreTests/FITSWriterMetadataTests.swift
git commit -m "feat: FITSWriter emits propagated metadata + stacking provenance cards"
```

---

### Task 4: `RawFrame` carries `SourceMetadata`; `FolderFrameSource` populates it

**Files:**
- Modify: `Sources/LiveAstroCore/Sources/FrameSource.swift:4-14` (add field to `RawFrame`)
- Modify: `Sources/LiveAstroCore/Sources/FolderFrameSource.swift:156-182` (build metadata from `header.keywords`)
- Test: `Tests/LiveAstroCoreTests/FolderFrameSourceMetadataTests.swift`

**Interfaces:**
- Consumes: `SourceMetadata(fitsKeywords:)` (Task 1); `FITSReader.readHeader(...).keywords` (existing).
- Produces: `RawFrame` gains `public let metadata: SourceMetadata?` (defaulted to `nil` in the initializer so other `RawFrame(...)` call sites keep compiling); `FolderFrameSource` sets it from the sub's `header.keywords`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class FolderFrameSourceMetadataTests: XCTestCase {
    func testFrameCarriesSourceMetadata() throws {
        // Write a temp FITS sub with astro cards, point the source at it, read one frame.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var m = SourceMetadata(); m.object = "NGC 6960"; m.ra = 314.36667; m.filter = "LP"; m.focalLengthMM = 160
        let fits = FITSWriter.float32(width: 2, height: 2, channels: 1, pixels: [0.1,0.2,0.3,0.4], metadata: m)
        try fits.write(to: dir.appendingPathComponent("Light_NGC 6960_30.0s_LP_0001.fit"))

        let source = FolderFrameSource(folder: dir, prefix: "Light_")   // match the real initializer
        guard let frame = try source.nextFrame() else { return XCTFail("no frame") }  // match real API
        XCTAssertEqual(frame.metadata?.object, "NGC 6960")
        XCTAssertEqual(frame.metadata?.ra ?? 0, 314.36667, accuracy: 1e-5)
        XCTAssertEqual(frame.metadata?.filter, "LP")
    }
}
```

> Adjust `FolderFrameSource(folder:prefix:)` and `nextFrame()` to the source's real construction/iteration API — check `FolderFrameSource.swift` and how `FolderFrameSourceTests`/`SessionPipeline` drive it. The assertion (frame carries parsed metadata) is the point.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FolderFrameSourceMetadataTests 2>&1 | tail -6`
Expected: FAIL — `RawFrame` has no `metadata` member.

- [ ] **Step 3: Write minimal implementation**

In `FrameSource.swift`, add the field to `RawFrame` and its initializer (keep the existing params; add a defaulted `metadata`):

```swift
public struct RawFrame {
    // ...existing fields...
    public let sourceName: String
    public let metadata: SourceMetadata?

    public init(/* ...existing params... */,
                timestamp: Date, sourceName: String, metadata: SourceMetadata? = nil) {
        // ...existing assignments...
        self.timestamp = timestamp; self.sourceName = sourceName
        self.metadata = metadata
    }
}
```

In `FolderFrameSource.swift`, where the header is read (line ~156) and the `RawFrame` is constructed (line ~182), build and pass the metadata:

```swift
        let header = try FITSReader.readHeader(data)
        let bayerPattern = BayerPattern(headerValue: header.bayerPattern)
        let bottomUp = header.bottomUp
        let dateObs = header.dateObs
        let metadata = SourceMetadata(fitsKeywords: header.keywords)   // NEW
        // ...existing frame decode...
        return RawFrame(/* ...existing args..., */
                        timestamp: timestamp, sourceName: url.lastPathComponent,
                        metadata: metadata)                            // NEW
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FolderFrameSourceMetadataTests 2>&1 | tail -5`
Then regression: `swift test --filter LiveAstroCoreTests 2>&1 | tail -5`
Expected: new test PASSES; existing suite still green (defaulted `metadata` keeps other `RawFrame(...)` sites compiling).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Sources/FrameSource.swift Sources/LiveAstroCore/Sources/FolderFrameSource.swift Tests/LiveAstroCoreTests/FolderFrameSourceMetadataTests.swift
git commit -m "feat: RawFrame carries SourceMetadata; FolderFrameSource populates it"
```

---

### Task 5: SessionPipeline — capture first-frame metadata + additive-balance the master

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (capture in `handleNative` ~line 128; use in `end()` ~line 213-216)
- Test: `Tests/LiveAstroCoreTests/CleanExportPipelineTests.swift`

**Interfaces:**
- Consumes: `RawFrame.metadata` (Task 4); `AutoStretch.neutralizeBackgroundAdditive(_:)` (existing, returns `AstroImage`, guards `channels == 3`); `FITSWriter.float32(...metadata:stackCount:totalExposureSeconds:)` (Task 3); `engine.acceptedCount`, `engine.stackFrameCount` (existing); `profile.subExposureSeconds` (existing).
- Produces: a captured `private var sourceMetadata: SourceMetadata?` on `SessionPipeline`, set on the first accepted frame; `end()` writes a color-balanced, metadata-rich master.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class CleanExportPipelineTests: XCTestCase {
    // Drive a native session over a folder of synthetic subs with a green pedestal,
    // then inspect the written master.fit. (Mirror the harness used by the existing
    // native-pipeline e2e test — NativePipelineTests — for session setup.)

    func testMasterHasMetadataAndIsBalancedWhenNeutralizeOn() throws {
        let (dir, sessionRoot) = try makeGreenSession(neutralize: true)   // helper below
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: sessionRoot) }
        let master = try findMaster(in: sessionRoot)
        let hdr = try FITSReader.readHeader(master)
        // metadata propagated
        XCTAssertEqual(hdr.keywords["OBJECT"]?.replacingOccurrences(of: "'", with: "").trimmingCharacters(in: .whitespaces), "NGC 6960")
        XCTAssertNotNil(hdr.keywords["RA"])
        XCTAssertNotNil(hdr.keywords["STACKCNT"])
        // green pedestal removed: per-channel background medians within tolerance
        let img = try FITSReader.readImage(master)
        let bg = channelBackgroundMedians(img)   // helper: sigma-clipped median per channel
        XCTAssertLessThan(abs(bg[1] - bg[0]), 0.01)   // G≈R
        XCTAssertLessThan(abs(bg[1] - bg[2]), 0.01)   // G≈B
    }

    func testMasterRawWhenNeutralizeOff() throws {
        let (dir, sessionRoot) = try makeGreenSession(neutralize: false)
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: sessionRoot) }
        let img = try FITSReader.readImage(try findMaster(in: sessionRoot))
        let bg = channelBackgroundMedians(img)
        XCTAssertGreaterThan(bg[1] - bg[0], 0.02)   // green pedestal still present (not balanced)
    }
}
```

> Implement `makeGreenSession`, `findMaster`, `channelBackgroundMedians` as private helpers in the test file. `makeGreenSession` writes ≥ 3 tiny synthetic subs (each a 3-channel image with a green background pedestal, a couple of shared "stars" so registration succeeds, and the NGC 6960 metadata cards via `FITSWriter.float32(..., metadata:)`), constructs a `SessionPipeline` in native mode with `neutralizeBackground = neutralize`, runs it to completion (`end()`), and returns the source and session-root dirs. **Model the setup on the existing `NativePipelineTests`** (find it: `grep -rl "SessionPipeline" Tests/`) — reuse its session-construction pattern verbatim so the harness matches reality.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CleanExportPipelineTests 2>&1 | tail -8`
Expected: FAIL — master lacks metadata cards / is not balanced.

- [ ] **Step 3: Write minimal implementation**

In `SessionPipeline`, add the stored property (near the other private vars):

```swift
    private var sourceMetadata: SourceMetadata?
```

In `handleNative`, capture on the first accepted frame — inside `case .becameReference, .stacked:` set it once from the raw frame (before calibration, so it's the true source header):

```swift
    private func handleNative(_ rawFrame: RawFrame, engine: StackEngine) {
        if cancelled.isSet { return }
        if sourceMetadata == nil, let m = rawFrame.metadata { sourceMetadata = m }
        let frame = calibrator?.apply(rawFrame) ?? rawFrame
        // ...unchanged...
```

In `end()`, replace the master-write block (lines ~213-216) with balance + metadata:

```swift
        if let eng = engine, let master = eng.currentStack() {
            let balanced = neutralizeBackground
                ? AutoStretch.neutralizeBackgroundAdditive(master)   // additive-ONLY (choice A)
                : master
            let totalExp = Double(eng.stackFrameCount) * profile.subExposureSeconds
            let masterData = FITSWriter.float32(
                width: balanced.width, height: balanced.height, channels: balanced.channels,
                pixels: balanced.pixels,
                metadata: sourceMetadata,
                stackCount: eng.acceptedCount,
                totalExposureSeconds: totalExp)
            try masterData.write(to: dir.appendingPathComponent("master.fit"))
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CleanExportPipelineTests 2>&1 | tail -5`
Then full core: `swift test --filter LiveAstroCoreTests 2>&1 | tail -5`
Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Pipeline/SessionPipeline.swift Tests/LiveAstroCoreTests/CleanExportPipelineTests.swift
git commit -m "feat: master export carries source metadata + additive background balance"
```

---

### Task 6: Manifest auto-fill from source metadata (bonus)

**Files:**
- Modify: `Sources/LiveAstroCore/Session/SessionManager.swift` (fill blank manifest fields when the metadata is known)
- Test: `Tests/LiveAstroCoreTests/ManifestAutofillTests.swift`

**Interfaces:**
- Consumes: `SourceMetadata` (Task 1); `SessionManifest` fields `camera`, `telescope`, `filter` (existing, `SessionModels.swift:46-60`).
- Produces: a method `public func fillMissingMetadata(from meta: SourceMetadata)` on `SessionManager` that fills only blank (`""`) `camera`/`telescope`/`filter` on the current manifest — user-entered values are never overwritten. Called from `SessionPipeline.end()` after `sourceMetadata` is known, before `session.endSession()`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class ManifestAutofillTests: XCTestCase {
    func testFillsBlankFieldsOnly() throws {
        let mgr = SessionManager(/* root: temp dir — match real init */)
        var profile = SessionProfile.blankForTest()   // camera/telescope "" , filter "R"
        profile.filter = "R"
        try mgr.startSession(profile: profile)         // match the real startSession signature

        var meta = SourceMetadata()
        meta.instrument = "imx585"; meta.telescope = "S30 Pro"; meta.filter = "LP"
        mgr.fillMissingMetadata(from: meta)

        XCTAssertEqual(mgr.manifest?.camera, "imx585")    // was blank -> filled
        XCTAssertEqual(mgr.manifest?.telescope, "S30 Pro")// was blank -> filled
        XCTAssertEqual(mgr.manifest?.filter, "R")         // user value preserved (not overwritten)
    }
}
```

> Match `SessionManager`'s real initializer and `startSession` signature (see `SessionManager.swift:56-65`). Provide a `SessionProfile` test factory or build one inline with the real fields.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ManifestAutofillTests 2>&1 | tail -6`
Expected: FAIL — `fillMissingMetadata(from:)` does not exist.

- [ ] **Step 3: Write minimal implementation**

Add to `SessionManager`:

```swift
    /// Fill blank manifest metadata from the source header. User-entered values win.
    public func fillMissingMetadata(from meta: SourceMetadata) {
        guard manifest != nil else { return }
        if manifest!.camera.isEmpty, let v = meta.instrument { manifest!.camera = v }
        if manifest!.telescope.isEmpty, let v = meta.telescope { manifest!.telescope = v }
        if manifest!.filter.isEmpty, let v = meta.filter { manifest!.filter = v }
    }
```

Call it from `SessionPipeline.end()` (after `sourceMetadata` is set, before `try session.endSession()`):

```swift
        if let meta = sourceMetadata { session.fillMissingMetadata(from: meta) }
        try session.endSession()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ManifestAutofillTests 2>&1 | tail -5`
Then: `swift test --filter LiveAstroCoreTests 2>&1 | tail -5`
Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Session/SessionManager.swift Tests/LiveAstroCoreTests/ManifestAutofillTests.swift
git commit -m "feat: auto-fill blank manifest camera/telescope/filter from source header"
```

---

## Notes for the implementer

- **`manifest` mutability:** if `SessionManager.manifest` is not settable (`let`/private), Task 6 must make it mutable (`var`, or add a mutating method). Check before Task 6; keep the change minimal (a `private(set) var` + the fill method inside the type is cleanest).
- **Reader entry points:** the tests reference `FITSReader.readImage(_:)` and `FITSReader.readHeader(_:)`. `readHeader` is confirmed to exist and returns `.keywords`. Confirm the image-reading entry point name against `FITSReaderTests.swift` and use whatever those tests use.
- **Registration in the e2e test (Task 5):** synthetic subs need enough shared "stars" (bright points at identical positions across frames) for `StackEngine` to seed a reference and stack — otherwise frames get rejected and no master is written. Mirror the star pattern used in `NativePipelineTests`.
