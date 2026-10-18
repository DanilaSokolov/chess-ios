import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A game's PGN as a file to share: "alice-Bob-2026-10-16.pgn". Apps that
/// take text rather than files get the same PGN as plain text.
///
/// `nonisolated`: the system asks for the file off the main actor, and the
/// app's types are on the main actor by default.
nonisolated struct PGNFile: Transferable, Sendable {
    let text: String
    let fileName: String

    /// PGN has no system-declared type; the one the system derives from the
    /// extension does, and plain text if it cannot.
    static let contentType = UTType(filenameExtension: "pgn") ?? .plainText

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: contentType) { file in
            SentTransferredFile(try file.writeToTemporaryFile())
        }
        ProxyRepresentation(exporting: { file in file.text })
    }

    /// Writes the text into a folder of its own, so the file keeps its name
    /// and two exports of the same game do not touch each other's file.
    private func writeToTemporaryFile() throws -> URL {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: fileName, directoryHint: .notDirectory)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }
}
