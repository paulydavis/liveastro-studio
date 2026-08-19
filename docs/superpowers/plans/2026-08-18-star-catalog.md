# Star Catalog (plate-solve sub-project 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A bundled, queryable bright-star catalog (Gaia DR3, G ≤ 8.5) — the data foundation the plate-solver matches detected stars against.

**Architecture:** A compact little-endian binary (`CatalogStar` records) with a pure-Swift loader and a declination-band spatial query, plus a one-time Python generator that extracts a bright Gaia DR3 subset into the bundled resource. The Swift loader + query are fully testable against synthetic catalogs (no real data needed); the real `brightstars.bin` is generated once and bundled via `Bundle.module`.

**Tech Stack:** Swift 5.10 (`LiveAstroCore`), XCTest; Python 3 + `astroquery` for the one-time generator.

## Global Constraints

- Branch `feature/star-catalog` (off main). NEVER commit to / base on / rebase onto `main`.
- Commit trailer on every commit: `Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j`. NO `Co-Authored-By`.
- **Source = Gaia DR3** (the same catalog Siril uses — confirmed: Siril's `siril_cat_healpix8_astro.dat` is a "Siril Gaia DR3 astrometric extract"). Attribution: Gaia DR3 (ESA/Gaia/DPAC). Zero external RUNTIME dependency — the subset is bundled.
- Bundle only `{ra, dec, mag}` (Float32 degrees / mag). No proper motion, color, or multi-band. Bright subset G ≤ 8.5, all-sky.
- Spatial separation MUST use unit-vector dot-product (correct across the RA 0/360 seam and near the poles) — never raw RA subtraction.
- This sub-project is catalog ONLY. No solving, no rotation, no UI (sub-projects 2 & 3).
- Run only ONE `swift test` / `swift build` at a time (SPM build lock).

---

## File Structure

- `Sources/LiveAstroCore/PlateSolve/CatalogStar.swift` — the celestial star value type (Task 1).
- `Sources/LiveAstroCore/PlateSolve/StarCatalog.swift` — binary loader + spatial query + `bundled()` (Tasks 1–3).
- `Sources/LiveAstroCore/Resources/brightstars.bin` — the generated Gaia DR3 subset (Task 3).
- `Scripts/generate_star_catalog.py` — one-time generator (Task 3).
- `Package.swift` — declare the `LiveAstroCore` resource (Task 3).
- `Tests/LiveAstroCoreTests/StarCatalogTests.swift` — all tests (Tasks 1–3).

Current: `Package.swift` `LiveAstroCore` target (line 11) has NO resources → `Bundle.module` for it is created only once Task 3 adds a resource. The app bundles `Help.md` via `Bundle.module` (`HelpView.swift:20`) — the pattern to mirror.

---

### Task 1: `CatalogStar` + binary format (writer + loader)

**Files:**
- Create: `Sources/LiveAstroCore/PlateSolve/CatalogStar.swift`
- Create: `Sources/LiveAstroCore/PlateSolve/StarCatalog.swift`
- Test: `Tests/LiveAstroCoreTests/StarCatalogTests.swift`

**Interfaces:**
- Produces: `struct CatalogStar: Equatable { let ra: Float; let dec: Float; let mag: Float }` (celestial degrees). `struct StarCatalog`: `static func encode(_ stars: [CatalogStar]) -> Data`, `init(data: Data) throws`, `var stars: [CatalogStar]`, `var count: Int`, `enum CatalogError: Error { case badMagic, badVersion, truncated }`. Task 2 consumes `stars`/`count`; Task 3 consumes `init(data:)`.

**Format:** header = magic `"LASC"` (4 ASCII bytes) + `version: UInt32` (=1) + `count: UInt32`, all little-endian; then `count` records of `{ra: Float32, dec: Float32, mag: Float32}` little-endian (12 bytes each). Records sorted by ascending `dec` (the encoder sorts).

- [ ] **Step 1: Write the failing test**

Create `Tests/LiveAstroCoreTests/StarCatalogTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

final class StarCatalogTests: XCTestCase {
    func testEncodeDecodeRoundTrip() throws {
        let stars = [CatalogStar(ra: 10.5, dec: -20.25, mag: 6.1),
                     CatalogStar(ra: 200.0, dec: 45.5, mag: 7.9),
                     CatalogStar(ra: 359.9, dec: 0.0, mag: 4.2)]
        let data = StarCatalog.encode(stars)
        let cat = try StarCatalog(data: data)
        XCTAssertEqual(cat.count, 3)
        // stored sorted by ascending dec
        XCTAssertEqual(cat.stars, stars.sorted { $0.dec < $1.dec })
    }

    func testBadMagicThrows() {
        var data = StarCatalog.encode([CatalogStar(ra: 1, dec: 2, mag: 3)])
        data[0] = 0x00   // corrupt magic
        XCTAssertThrowsError(try StarCatalog(data: data)) { error in
            XCTAssertEqual(error as? StarCatalog.CatalogError, .badMagic)
        }
    }

    func testTruncatedThrows() {
        let data = StarCatalog.encode([CatalogStar(ra: 1, dec: 2, mag: 3)])
        XCTAssertThrowsError(try StarCatalog(data: data.prefix(14))) { error in
            XCTAssertEqual(error as? StarCatalog.CatalogError, .truncated)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StarCatalogTests`
Expected: FAIL to compile — no `CatalogStar` / `StarCatalog`.

- [ ] **Step 3: Implement `CatalogStar` + `StarCatalog` encode/decode**

Create `Sources/LiveAstroCore/PlateSolve/CatalogStar.swift`:

```swift
import Foundation

/// A catalog star in celestial coordinates (Gaia DR3 bright subset). Distinct from
/// `StarDetector.Star`, which is screen-space; the plate-solver projects catalog → screen.
public struct CatalogStar: Equatable {
    public let ra: Float    // decimal degrees [0,360)
    public let dec: Float   // decimal degrees [-90,90]
    public let mag: Float   // Gaia G magnitude
    public init(ra: Float, dec: Float, mag: Float) { self.ra = ra; self.dec = dec; self.mag = mag }
}
```

Create `Sources/LiveAstroCore/PlateSolve/StarCatalog.swift`:

```swift
import Foundation

/// A bright-star catalog (Gaia DR3, G ≤ 8.5) loaded from the compact `brightstars.bin` resource.
/// Little-endian: magic "LASC" + UInt32 version + UInt32 count, then count × {ra,dec,mag} Float32.
/// Records are stored sorted by ascending declination (enables the dec-band query in Task 2).
public struct StarCatalog {
    public enum CatalogError: Error, Equatable { case badMagic, badVersion, truncated }

    static let magic: [UInt8] = Array("LASC".utf8)
    static let version: UInt32 = 1
    static let headerSize = 12
    static let recordSize = 12

    public let stars: [CatalogStar]          // sorted by ascending dec
    public var count: Int { stars.count }

    /// Encode stars (sorted by ascending dec) to the binary format. Used by the generator + tests.
    public static func encode(_ stars: [CatalogStar]) -> Data {
        let sorted = stars.sorted { $0.dec < $1.dec }
        var data = Data(magic)
        var v = version.littleEndian, c = UInt32(sorted.count).littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &c) { data.append(contentsOf: $0) }
        for s in sorted {
            for var f in [s.ra.bitPattern.littleEndian, s.dec.bitPattern.littleEndian, s.mag.bitPattern.littleEndian] {
                withUnsafeBytes(of: &f) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.headerSize else { throw CatalogError.truncated }
        guard Array(bytes[0..<4]) == Self.magic else { throw CatalogError.badMagic }
        func u32(_ off: Int) -> UInt32 {
            UInt32(bytes[off]) | UInt32(bytes[off+1]) << 8 | UInt32(bytes[off+2]) << 16 | UInt32(bytes[off+3]) << 24
        }
        func f32(_ off: Int) -> Float { Float(bitPattern: u32(off)) }
        guard u32(4) == Self.version else { throw CatalogError.badVersion }
        let n = Int(u32(8))
        guard bytes.count >= Self.headerSize + n * Self.recordSize else { throw CatalogError.truncated }
        var out = [CatalogStar](); out.reserveCapacity(n)
        for i in 0..<n {
            let o = Self.headerSize + i * Self.recordSize
            out.append(CatalogStar(ra: f32(o), dec: f32(o+4), mag: f32(o+8)))
        }
        self.stars = out
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StarCatalogTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/PlateSolve/CatalogStar.swift Sources/LiveAstroCore/PlateSolve/StarCatalog.swift Tests/LiveAstroCoreTests/StarCatalogTests.swift
git commit -m "feat: CatalogStar + StarCatalog binary format (Gaia DR3 bright subset)

Compact little-endian {ra,dec,mag} Float32 records, dec-sorted, magic
LASC + version + count. encode/decode round-trip + header validation.

Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j"
```

---

### Task 2: Spatial query `stars(nearRA:dec:radiusDegrees:)`

**Files:**
- Modify: `Sources/LiveAstroCore/PlateSolve/StarCatalog.swift`
- Test: `Tests/LiveAstroCoreTests/StarCatalogTests.swift`

**Interfaces:**
- Consumes: `stars` (dec-sorted, Task 1).
- Produces: `func stars(nearRA ra: Double, dec: Double, radiusDegrees: Double) -> [CatalogStar]`.

- [ ] **Step 1: Write the failing tests**

Add to `StarCatalogTests`:

```swift
    private func cat(_ s: [CatalogStar]) -> StarCatalog { try! StarCatalog(data: StarCatalog.encode(s)) }

    func testQueryReturnsWithinRadiusExcludesOutside() {
        let c = cat([CatalogStar(ra: 100, dec: 10, mag: 5),    // center
                     CatalogStar(ra: 100.5, dec: 10, mag: 6),  // ~0.49° away → inside 1°
                     CatalogStar(ra: 105, dec: 10, mag: 7)])   // ~4.9° away → outside 1°
        let got = c.stars(nearRA: 100, dec: 10, radiusDegrees: 1.0)
        XCTAssertEqual(Set(got.map { $0.mag }), [5, 6])
    }

    func testQueryHandlesRA0Seam() {
        // stars straddling the 0h seam must both be found (dot-product, not RA subtraction)
        let c = cat([CatalogStar(ra: 359.7, dec: 0, mag: 5),
                     CatalogStar(ra: 0.3, dec: 0, mag: 6),
                     CatalogStar(ra: 180, dec: 0, mag: 7)])   // opposite side → excluded
        let got = c.stars(nearRA: 0.0, dec: 0.0, radiusDegrees: 1.0)
        XCTAssertEqual(Set(got.map { $0.mag }), [5, 6])
    }

    func testQueryNearPole() {
        // near the pole RA converges; two stars at dec 89.5 with very different RA are both close
        let c = cat([CatalogStar(ra: 0, dec: 89.6, mag: 5),
                     CatalogStar(ra: 180, dec: 89.6, mag: 6),  // ~0.8° away over the pole
                     CatalogStar(ra: 90, dec: 80, mag: 7)])    // ~9.6° away → excluded
        let got = c.stars(nearRA: 90, dec: 90, radiusDegrees: 1.0)
        XCTAssertEqual(Set(got.map { $0.mag }), [5, 6])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter StarCatalogTests`
Expected: FAIL to compile — no `stars(nearRA:dec:radiusDegrees:)`.

- [ ] **Step 3: Implement the dec-band + dot-product query**

Add to `StarCatalog` (in `StarCatalog.swift`):

```swift
    /// All catalog stars within `radiusDegrees` angular separation of (ra, dec). Uses a
    /// declination-band prefilter (`|dec − center| ≤ radius`) over the dec-sorted array, then
    /// unit-vector dot-product for the exact separation — correct across the RA 0/360 seam and
    /// at the poles (no RA-subtraction wrap bug).
    public func stars(nearRA ra: Double, dec: Double, radiusDegrees: Double) -> [CatalogStar] {
        let d2r = Double.pi / 180
        let cosR = cos(radiusDegrees * d2r)
        // center unit vector
        let cr = ra * d2r, cd = dec * d2r
        let cx = cos(cd) * cos(cr), cy = cos(cd) * sin(cr), cz = sin(cd)
        // dec band: stars are dec-sorted, so only scan those within radius in declination.
        let loDec = Float(dec - radiusDegrees), hiDec = Float(dec + radiusDegrees)
        var out: [CatalogStar] = []
        for s in stars {
            if s.dec < loDec { continue }
            if s.dec > hiDec { break }            // sorted → past the band, stop
            let sr = Double(s.ra) * d2r, sd = Double(s.dec) * d2r
            let dot = cos(sd) * cos(sr) * cx + cos(sd) * sin(sr) * cy + sin(sd) * cz
            if dot >= cosR { out.append(s) }
        }
        return out
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter StarCatalogTests`
Expected: PASS (6 tests: 3 from Task 1 + 3 query).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/PlateSolve/StarCatalog.swift Tests/LiveAstroCoreTests/StarCatalogTests.swift
git commit -m "feat: StarCatalog dec-band + dot-product spatial query

stars(nearRA:dec:radiusDegrees:) — dec-band prefilter over the dec-sorted
records, unit-vector dot-product for exact separation (RA-seam + pole safe).

Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j"
```

---

### Task 3: Generator + bundle the Gaia DR3 subset + `bundled()`

**Files:**
- Create: `Scripts/generate_star_catalog.py`
- Create: `Sources/LiveAstroCore/Resources/brightstars.bin` (generated)
- Modify: `Package.swift` (add `resources: [.copy("Resources")]` to the `LiveAstroCore` target)
- Modify: `Sources/LiveAstroCore/PlateSolve/StarCatalog.swift` (add `bundled()`)
- Test: `Tests/LiveAstroCoreTests/StarCatalogTests.swift` (gated bundled test)

**Interfaces:**
- Consumes: `StarCatalog.encode` / `init(data:)` (Task 1), the binary format.
- Produces: `static func bundled() -> StarCatalog?`.

- [ ] **Step 1: Write the generator**

Create `Scripts/generate_star_catalog.py` (writes the SAME format `StarCatalog.encode` produces):

```python
#!/usr/bin/env python3
"""Generate brightstars.bin: Gaia DR3 (the catalog Siril uses) filtered to G<=8.5, all-sky,
packed into the LASC binary format {magic "LASC", u32 version=1, u32 count, then count×
{ra,dec,mag} float32 LE}, records sorted by ascending dec.
Requires: pip install astroquery   (astropy is already present)
Run: python3 Scripts/generate_star_catalog.py  ->  Sources/LiveAstroCore/Resources/brightstars.bin
"""
import struct, os
from astroquery.gaia import Gaia

MAG_LIMIT = 8.5
OUT = os.path.join(os.path.dirname(__file__), "..", "Sources", "LiveAstroCore", "Resources", "brightstars.bin")

def fetch():
    job = Gaia.launch_job_async(
        f"SELECT ra, dec, phot_g_mean_mag FROM gaiadr3.gaia_source "
        f"WHERE phot_g_mean_mag <= {MAG_LIMIT} AND ra IS NOT NULL AND dec IS NOT NULL "
        f"AND phot_g_mean_mag IS NOT NULL")
    r = job.get_results()
    return [(float(row["ra"]), float(row["dec"]), float(row["phot_g_mean_mag"])) for row in r]

def pack(stars):
    stars = sorted(stars, key=lambda s: s[1])   # ascending dec
    buf = bytearray(b"LASC")
    buf += struct.pack("<II", 1, len(stars))
    for ra, dec, mag in stars:
        buf += struct.pack("<fff", ra, dec, mag)
    return bytes(buf)

if __name__ == "__main__":
    stars = fetch()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(pack(stars))
    print(f"wrote {len(stars)} stars -> {OUT} ({os.path.getsize(OUT)} bytes)")
```

- [ ] **Step 2: Generate the data (one-time, needs network)**

Run: `pip install astroquery && python3 Scripts/generate_star_catalog.py`
Expected: `wrote <N> stars -> .../brightstars.bin (<bytes>)` with N in the ~40k–150k range and bytes ≈ 12 + 12·N (≈ 0.5–2 MB). If the Gaia async query is unavailable in this environment, this step is deferred — Tasks 1–2 (loader + query) are already committed and green, and `bundled()` (Step 4) returns nil gracefully until the file exists. Do NOT block the task on the network fetch; note it in the report and continue to Steps 3–5.

- [ ] **Step 3: Declare the resource in `Package.swift`**

Change the `LiveAstroCore` target (line 11) from:

```swift
        .target(name: "LiveAstroCore"),
```

to:

```swift
        .target(name: "LiveAstroCore", resources: [.copy("Resources")]),
```

(`.copy` — the `.bin` is opaque; no SPM processing. This also synthesizes `Bundle.module` for `LiveAstroCore`.) NOTE: SPM requires `Sources/LiveAstroCore/Resources/` to EXIST with at least one file at build time. If Step 2 was deferred, create the directory with a generated 12-byte empty-catalog placeholder so the build succeeds: `printf 'LASC\1\0\0\0\0\0\0\0' > Sources/LiveAstroCore/Resources/brightstars.bin` (magic + version 1 + count 0). The gated test (Step 5) skips on `count == 0`.

- [ ] **Step 4: Add `bundled()`**

Add to `StarCatalog` (in `StarCatalog.swift`):

```swift
    /// Load the bundled Gaia DR3 bright subset. Returns nil if the resource is missing or malformed,
    /// so callers degrade gracefully before the catalog is generated.
    public static func bundled() -> StarCatalog? {
        guard let url = Bundle.module.url(forResource: "brightstars", withExtension: "bin"),
              let data = try? Data(contentsOf: url),
              let cat = try? StarCatalog(data: data) else { return nil }
        return cat
    }
```

- [ ] **Step 5: Add the gated bundled test**

Add to `StarCatalogTests`:

```swift
    /// The real bundled catalog loads and is queryable. Skipped until brightstars.bin is generated
    /// (placeholder has count 0), so the suite stays green pre-data.
    func testBundledCatalogLoadsAndQueries() throws {
        guard let cat = StarCatalog.bundled(), cat.count > 0 else {
            throw XCTSkip("brightstars.bin not generated yet (or empty placeholder)")
        }
        XCTAssertGreaterThan(cat.count, 10_000, "expected a substantial Gaia DR3 bright subset")
        // a dense region (galactic plane, ~Cygnus) should return some bright stars
        let got = cat.stars(nearRA: 305.0, dec: 40.0, radiusDegrees: 3.0)
        XCTAssertFalse(got.isEmpty, "expected catalog stars in a dense region")
    }
```

- [ ] **Step 6: Build + run the full suite**

Run: `swift build` then `swift test 2>&1 | tail -15`
Expected: build succeeds (resource bundled); all tests pass — the bundled test either verifies a real catalog or `XCTSkip`s on the placeholder.

- [ ] **Step 7: Commit**

```bash
git add Scripts/generate_star_catalog.py Package.swift Sources/LiveAstroCore/PlateSolve/StarCatalog.swift Sources/LiveAstroCore/Resources/brightstars.bin Tests/LiveAstroCoreTests/StarCatalogTests.swift
git commit -m "feat: bundle Gaia DR3 bright subset + StarCatalog.bundled()

Generator (astroquery.gaia, G<=8.5) -> brightstars.bin, bundled as a
LiveAstroCore resource; bundled() loads it (nil-graceful). Gaia DR3 =
the catalog Siril uses. Gated bundled test skips until data is generated.

Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j"
```

---

## Self-Review

**Spec coverage:** CatalogStar (T1) ✓; binary format + loader (T1) ✓; header validation errors (T1) ✓; dec-band + dot-product query, seam + pole (T2) ✓; generator from Gaia DR3 (T3) ✓; Package.swift resource + bundled() nil-graceful (T3) ✓; gated bundled test (T3) ✓; Gaia DR3 = Siril's source + attribution (T3 generator docstring + commit) ✓; zero runtime dep (bundled) ✓; RA-seam/pole correctness (T2 tests) ✓.

**Placeholder scan:** no TBD/TODO in code; the deferred-data path is explicit + handled (placeholder + XCTSkip), not a hole.

**Type consistency:** `CatalogStar(ra:dec:mag:)`, `StarCatalog.encode`, `init(data:)`, `stars`, `count`, `stars(nearRA:dec:radiusDegrees:)`, `bundled()`, `CatalogError` cases identical across tasks. Format (magic "LASC", version 1, 12-byte header, 12-byte records, dec-sorted) identical in Swift `encode` and the Python generator.

## Note for after this sub-project

This delivers the queryable catalog. **Sub-project 2 (the solver)** is the research-risky next step — it should validate against the M63 frames' FITS `RA`/`DEC` ground truth early (fail-fast). Sub-project 3 applies the solved rotation north-up.
