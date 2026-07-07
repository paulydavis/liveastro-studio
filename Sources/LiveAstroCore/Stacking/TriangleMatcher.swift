import Foundation

/// Triangle-invariant star matching (spec §4.2). Clean-room implementation of the
/// classic method: triangles are similarity-invariant, so matching side-ratio
/// signatures across images yields vertex correspondences without initial alignment.
public enum TriangleMatcher {
    struct Triangle {
        let vertices: (Int, Int, Int)   // star indices ordered by opposite-side rank:
                                        // .0 opposite shortest, .2 opposite longest
        let invariant: (Double, Double) // (L2/L1, L3/L2), L1 ≤ L2 ≤ L3
    }

    static func triangles(_ stars: [Star], maxStars: Int) -> [Triangle] {
        let n = min(stars.count, maxStars)
        guard n >= 3 else { return [] }
        var out: [Triangle] = []
        for i in 0..<(n - 2) {
            for j in (i + 1)..<(n - 1) {
                for k in (j + 1)..<n {
                    func dist(_ a: Int, _ b: Int) -> Double {
                        let dx = stars[a].x - stars[b].x, dy = stars[a].y - stars[b].y
                        return (dx * dx + dy * dy).squareRoot()
                    }
                    // side opposite each vertex
                    let sides = [(dist(j, k), i), (dist(i, k), j), (dist(i, j), k)]
                        .sorted { $0.0 < $1.0 }
                    let (l1, l2, l3) = (sides[0].0, sides[1].0, sides[2].0)
                    guard l1 > 4 else { continue }                    // degenerate / same blob
                    let inv = (l2 / l1, l3 / l2)
                    guard inv.0 < 20, inv.1 < 20 else { continue }    // near-collinear
                    out.append(Triangle(vertices: (sides[0].1, sides[1].1, sides[2].1),
                                        invariant: inv))
                }
            }
        }
        return out
    }

    public static func correspondences(source: [Star], target: [Star],
                                       maxTriangleStars: Int = 20,
                                       invariantTolerance: Double = 0.02,
                                       minVotes: Int = 2) -> [(source: Int, target: Int)] {
        let ts = triangles(source, maxStars: maxTriangleStars)
        let tt = triangles(target, maxStars: maxTriangleStars)
        guard !ts.isEmpty, !tt.isEmpty else { return [] }
        var votes: [Int: Int] = [:]   // key = srcIdx * 4096 + dstIdx
        for a in ts {
            for b in tt {
                let r1 = abs(a.invariant.0 - b.invariant.0) / max(a.invariant.0, 1e-9)
                let r2 = abs(a.invariant.1 - b.invariant.1) / max(a.invariant.1, 1e-9)
                guard r1 < invariantTolerance, r2 < invariantTolerance else { continue }
                for (sv, tv) in [(a.vertices.0, b.vertices.0),
                                 (a.vertices.1, b.vertices.1),
                                 (a.vertices.2, b.vertices.2)] {
                    votes[sv * 4096 + tv, default: 0] += 1
                }
            }
        }
        // Greedy one-to-one assignment by vote count.
        let ranked = votes.filter { $0.value >= minVotes }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var usedS = Set<Int>(), usedT = Set<Int>()
        var out: [(source: Int, target: Int)] = []
        for (key, _) in ranked {
            let s = key / 4096, t = key % 4096
            guard !usedS.contains(s), !usedT.contains(t) else { continue }
            usedS.insert(s); usedT.insert(t)
            out.append((source: s, target: t))
        }
        return out
    }
}
