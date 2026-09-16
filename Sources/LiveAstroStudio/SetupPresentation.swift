import Foundation
import LiveAstroCore

enum SetupPresentation {
    struct CalibrationSummary {
        let flats: String
        let darkFlats: String
        let darks: String
        let bias: String
    }

    static func targetTitle(_ target: String) -> String {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled session" : trimmed
    }

    static func calibration(flats: URL?, darkFlats: URL?, library: [MasterFrame]) -> CalibrationSummary {
        func inventory(_ kind: MasterKind) -> String {
            let count = library.filter { $0.kind == kind }.count
            return count == 0 ? "None in library" : "\(count) in library"
        }
        // Inventory is not a matching decision. Incoming FITS headers determine which
        // library masters can actually be used; selecting a folder does not validate it.
        return CalibrationSummary(flats: flats?.lastPathComponent ?? "Not selected",
                                  darkFlats: darkFlats?.lastPathComponent ?? "Not selected",
                                  darks: inventory(.dark), bias: inventory(.bias))
    }
}
