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
    private static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.isoWithFractional.string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = Self.isoWithFractional.date(from: string) ?? Self.isoPlain.date(from: string) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "unparseable ISO8601 date: \(string)"))
        }
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
