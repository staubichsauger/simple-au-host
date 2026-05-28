import Foundation

struct ManagedSessionFile: Identifiable, Hashable {
    let url: URL
    let lastModifiedDate: Date

    var id: URL { url }

    var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }

    var modifiedDateLabel: String {
        Self.modifiedDateFormatter.string(from: lastModifiedDate)
    }

    private static let modifiedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

struct SAHManagedStorageDirectories {
    let root: URL
    let sessions: URL
    let chainPresets: URL
    let parameterPresets: URL
}

enum SAHManagedSessionStore {
    private static let appFolderName = "SAH"
    private static let sessionsFolderName = "Sessions"
    private static let chainPresetsFolderName = "Chain Presets"
    private static let parameterPresetsFolderName = "Parameter Presets"
    private static let sessionFileExtension = "sahsession"

    static func ensureDirectories(fileManager: FileManager = .default) throws -> SAHManagedStorageDirectories {
        let musicDirectory = try musicDirectoryURL(fileManager: fileManager)
        let root = musicDirectory.appendingPathComponent(appFolderName, isDirectory: true)
        let sessions = root.appendingPathComponent(sessionsFolderName, isDirectory: true)
        let chainPresets = root.appendingPathComponent(chainPresetsFolderName, isDirectory: true)
        let parameterPresets = root.appendingPathComponent(parameterPresetsFolderName, isDirectory: true)

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: chainPresets, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: parameterPresets, withIntermediateDirectories: true, attributes: nil)

        return SAHManagedStorageDirectories(
            root: root,
            sessions: sessions,
            chainPresets: chainPresets,
            parameterPresets: parameterPresets
        )
    }

    static func managedSessions(fileManager: FileManager = .default) throws -> [ManagedSessionFile] {
        let directories = try ensureDirectories(fileManager: fileManager)
        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let fileURLs = try fileManager.contentsOfDirectory(
            at: directories.sessions,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        return try fileURLs.compactMap { url in
            let resourceValues = try url.resourceValues(forKeys: resourceKeys)
            guard resourceValues.isRegularFile == true else {
                return nil
            }
            guard url.pathExtension.caseInsensitiveCompare(sessionFileExtension) == .orderedSame else {
                return nil
            }
            return ManagedSessionFile(
                url: url,
                lastModifiedDate: resourceValues.contentModificationDate ?? .distantPast
            )
        }
        .sorted { lhs, rhs in
            if lhs.lastModifiedDate == rhs.lastModifiedDate {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            return lhs.lastModifiedDate > rhs.lastModifiedDate
        }
    }

    static func sessionsDirectoryURL(fileManager: FileManager = .default) throws -> URL {
        try ensureDirectories(fileManager: fileManager).sessions
    }

    static func chainPresetsDirectoryURL(fileManager: FileManager = .default) throws -> URL {
        try ensureDirectories(fileManager: fileManager).chainPresets
    }

    static func parameterPresetsDirectoryURL(fileManager: FileManager = .default) throws -> URL {
        try ensureDirectories(fileManager: fileManager).parameterPresets
    }

    private static func musicDirectoryURL(fileManager: FileManager) throws -> URL {
        if let url = fileManager.urls(for: .musicDirectory, in: .userDomainMask).first {
            return url
        }
        throw AudioHostError("The Music folder could not be located.")
    }
}
