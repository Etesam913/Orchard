import Foundation
import os

private let logger = Logger(subsystem: "com.thdxg.orchard", category: "WorkspacePersistence")

/// Current schema version. Bump when the snapshot types change shape.
/// Adding an optional field does NOT require a bump — Codable decodes
/// missing fields as nil / default. Removing or renaming fields does.
private let currentSchemaVersion = 3

// MARK: - Persistence

final class WorkspaceStore {
    private let fileURL: URL

    init(fileURL: URL = FileStorage.fileURL(filename: "workspaces_v3.json")) {
        self.fileURL = fileURL
    }

    func load() -> [WorkspaceSnapshot] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            // Try the envelope format first (version + workspaces).
            if let file = try? decoder.decode(WorkspacesFile.self, from: data) {
                return migrate(file).workspaces
            }
            // Fallback: pre-envelope format where the file was a bare array
            // of WorkspaceSnapshot. Upgrade on next save.
            return try decoder.decode([WorkspaceSnapshot].self, from: data)
        } catch {
            logger.error("Failed to load workspaces: \(error)")
            return []
        }
    }

    func save(_ snapshots: [WorkspaceSnapshot]) {
        do {
            let file = WorkspacesFile(version: currentSchemaVersion, workspaces: snapshots)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            try encoder.encode(file).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save workspaces: \(error)")
        }
    }

    /// Apply any needed in-memory migrations. Currently a no-op — future
    /// schema bumps add cases here.
    private func migrate(_ file: WorkspacesFile) -> WorkspacesFile {
        // switch file.version {
        // case 3: return file
        // case 4: return migrateV4(file)
        // ...
        // }
        file
    }
}
