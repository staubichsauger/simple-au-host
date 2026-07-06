import Foundation

struct StartupPreferences {
    var launchesIntoPerformViewOnStartup: Bool
    var loadsSavedSessionOnStartup: Bool
    var startsEngineOnLaunch: Bool
    var savedSessionSelection: StartupSavedSessionSelection
    var specificSessionURL: URL?
    var opensSpecificSessionAsTemplate: Bool
    var lastSavedSessionURL: URL?
}

struct StartupPreferencesStore {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    func load() -> StartupPreferences {
        let savedSessionSelection: StartupSavedSessionSelection
        if let rawValue = userDefaults.string(forKey: Self.startupSavedSessionSelectionKey),
           let selection = StartupSavedSessionSelection(rawValue: rawValue) {
            savedSessionSelection = selection
        } else {
            savedSessionSelection = .lastSaved
        }

        return StartupPreferences(
            launchesIntoPerformViewOnStartup: userDefaults.bool(forKey: Self.launchesIntoPerformViewOnStartupKey),
            loadsSavedSessionOnStartup: userDefaults.bool(forKey: Self.loadsSavedSessionOnStartupKey),
            startsEngineOnLaunch: userDefaults.bool(forKey: Self.startsEngineOnLaunchKey),
            savedSessionSelection: savedSessionSelection,
            specificSessionURL: Self.fileURL(fromStoredPath: userDefaults.string(forKey: Self.startupSpecificSessionPathKey)),
            opensSpecificSessionAsTemplate: userDefaults.bool(forKey: Self.opensStartupSpecificSessionAsTemplateKey),
            lastSavedSessionURL: Self.fileURL(fromStoredPath: userDefaults.string(forKey: Self.lastSavedSessionPathKey))
        )
    }

    func persist(_ preferences: StartupPreferences) {
        userDefaults.set(
            preferences.launchesIntoPerformViewOnStartup,
            forKey: Self.launchesIntoPerformViewOnStartupKey
        )
        userDefaults.set(preferences.loadsSavedSessionOnStartup, forKey: Self.loadsSavedSessionOnStartupKey)
        userDefaults.set(preferences.startsEngineOnLaunch, forKey: Self.startsEngineOnLaunchKey)
        userDefaults.set(preferences.savedSessionSelection.rawValue, forKey: Self.startupSavedSessionSelectionKey)

        if let specificSessionURL = preferences.specificSessionURL {
            userDefaults.set(specificSessionURL.path, forKey: Self.startupSpecificSessionPathKey)
        } else {
            userDefaults.removeObject(forKey: Self.startupSpecificSessionPathKey)
        }

        userDefaults.set(
            preferences.opensSpecificSessionAsTemplate,
            forKey: Self.opensStartupSpecificSessionAsTemplateKey
        )
    }

    func recordLastSavedSessionURL(_ url: URL) {
        userDefaults.set(url.path, forKey: Self.lastSavedSessionPathKey)
    }

    private static let launchesIntoPerformViewOnStartupKey = "startup.launchesIntoPerformViewOnStartup"
    private static let loadsSavedSessionOnStartupKey = "startup.loadsSavedSessionOnStartup"
    private static let startsEngineOnLaunchKey = "startup.startsEngineOnLaunch"
    private static let startupSavedSessionSelectionKey = "startup.savedSessionSelection"
    private static let startupSpecificSessionPathKey = "startup.specificSessionPath"
    private static let opensStartupSpecificSessionAsTemplateKey = "startup.opensSpecificSessionAsTemplate"
    private static let lastSavedSessionPathKey = "startup.lastSavedSessionPath"

    private static func fileURL(fromStoredPath path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: false)
    }
}
