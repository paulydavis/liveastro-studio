import Foundation

/// Atomic-or-nothing output replacement shared by the master-path processors.
///
/// The defect class this kills (found in Paul's post-merge review, same family
/// as the round-9 GraXpert pre-run-cleanup finding): a remove-then-move swap
/// destroys the previous good `master_processed` output when the move fails
/// after the removal. `FileManager.replaceItemAt` preserves the original on
/// failure; a plain move is used only when no original exists (nothing to lose).
public enum FileReplace {
    /// Replace `destination` with the file at `temp`.
    /// On success `temp` is consumed. On ANY failure the previous
    /// `destination` (if it existed) remains in place; the caller owns
    /// cleaning up `temp`.
    public static func replaceItem(at destination: URL, withItemAt temp: URL,
                            fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temp)
        } else {
            try fileManager.moveItem(at: temp, to: destination)
        }
    }
}
