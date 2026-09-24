import Foundation

public enum LogLevel: Int, Codable, CaseIterable, Comparable {
    case info = 0
    case warning = 1
    case error = 2

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct AppSettings: Codable {
    public var logLevel: LogLevel
    public var openFinderAfterMount: Bool
    public var autoMountNTFSReadWrite: Bool
    public var language: AppLanguage

    /// `true` when the decoded JSON actually contained a `language` key. Used by
    /// `LanguageMigration` to detect settings.json files written before the language field
    /// existed, so the one-time legacy `UserDefaults` migration only applies to those. Not
    /// part of the wire format — deliberately excluded from `CodingKeys` — so it never round
    /// trips through encoding; every freshly-constructed or freshly-loaded value considers
    /// this an in-memory-only flag.
    public private(set) var languageWasPresent: Bool

    enum CodingKeys: String, CodingKey {
        case logLevel
        case openFinderAfterMount
        case autoMountNTFSReadWrite
        case language
    }

    public init(
        logLevel: LogLevel = .info,
        openFinderAfterMount: Bool = true,
        autoMountNTFSReadWrite: Bool = false,
        language: AppLanguage = .system
    ) {
        self.logLevel = logLevel
        self.openFinderAfterMount = openFinderAfterMount
        self.autoMountNTFSReadWrite = autoMountNTFSReadWrite
        self.language = language
        self.languageWasPresent = true
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.logLevel = try container.decode(LogLevel.self, forKey: .logLevel)
        self.openFinderAfterMount = try container.decode(Bool.self, forKey: .openFinderAfterMount)
        self.autoMountNTFSReadWrite = try container.decodeIfPresent(Bool.self, forKey: .autoMountNTFSReadWrite) ?? false
        self.language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        self.languageWasPresent = container.contains(.language)
    }

    /// Defaults for the case where `settings.json` doesn't exist on disk at all yet — as
    /// opposed to existing but predating the `language` field. Marked `languageWasPresent ==
    /// false` so `LanguageMigration` still runs for a user who picked a language in a
    /// pre-`AppSettings.language` release but never opened Settings again since upgrading (the
    /// file legitimately doesn't exist yet in that case; `AppSettings()`'s own default marks
    /// `languageWasPresent == true`, which would wrongly skip migration for exactly this user).
    static var defaultsForMissingFile: AppSettings {
        var settings = AppSettings()
        settings.languageWasPresent = false
        return settings
    }
}

extension AppSettings: Equatable {
    /// Hand-written to exclude `languageWasPresent`, which is in-memory bookkeeping for
    /// `LanguageMigration`, not part of a settings value's actual content — two `AppSettings`
    /// with identical fields but different migration provenance (e.g. one loaded fresh vs. one
    /// freshly constructed) must still compare equal.
    public static func == (lhs: AppSettings, rhs: AppSettings) -> Bool {
        lhs.logLevel == rhs.logLevel
            && lhs.openFinderAfterMount == rhs.openFinderAfterMount
            && lhs.autoMountNTFSReadWrite == rhs.autoMountNTFSReadWrite
            && lhs.language == rhs.language
    }
}

extension AppSettings {
    /// Returns a copy with only the given fields overridden, leaving every other field —
    /// notably `language` — untouched. Callers that only care about one field (e.g.
    /// `SettingsView`'s per-toggle `onChange` handlers) must build from the view model's
    /// current `settings` through this method rather than constructing a fresh
    /// `AppSettings(...)`, which would silently reset every field not passed in back to its
    /// default (this is exactly how a log-level or NTFS toggle used to erase the user's
    /// chosen language).
    public func updating(
        logLevel: LogLevel? = nil,
        openFinderAfterMount: Bool? = nil,
        autoMountNTFSReadWrite: Bool? = nil,
        language: AppLanguage? = nil
    ) -> AppSettings {
        var copy = self
        if let logLevel { copy.logLevel = logLevel }
        if let openFinderAfterMount { copy.openFinderAfterMount = openFinderAfterMount }
        if let autoMountNTFSReadWrite { copy.autoMountNTFSReadWrite = autoMountNTFSReadWrite }
        if let language { copy.language = language }
        return copy
    }
}

/// One-time migration from the pre-`AppSettings.language` scheme, where the app stored its
/// language choice directly in a legacy `UserDefaults` key with raw values `"english"` /
/// `"chinese"`. Pure and testable: takes the already-decoded settings plus the raw legacy
/// `UserDefaults` string (or `nil`, read by the caller) and returns updated settings only
/// when a migration should actually happen.
public enum LanguageMigration {
    public static func migrate(settings: AppSettings, legacyValue: String?) -> AppSettings? {
        guard !settings.languageWasPresent else { return nil }
        guard let legacyValue else { return nil }
        let migratedLanguage: AppLanguage
        switch legacyValue {
        case "chinese": migratedLanguage = .chinese
        case "english": migratedLanguage = .english
        default: return nil
        }
        var updated = settings
        updated.language = migratedLanguage
        return updated
    }
}

public protocol AppSettingsStore {
    func load() throws -> AppSettings
    func save(_ settings: AppSettings) throws
}

public final class JSONAppSettingsStore: AppSettingsStore {
    private let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL = JSONAppSettingsStore.defaultDirectory, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoVolume", isDirectory: true)
    }

    public var fileURL: URL {
        directory.appendingPathComponent("settings.json")
    }

    public func load() throws -> AppSettings {
        guard fileManager.fileExists(atPath: fileURL.path) else { return AppSettings.defaultsForMissingFile }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(AppSettings.self, from: data)
    }

    public func save(_ settings: AppSettings) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: [.atomic])
    }
}
