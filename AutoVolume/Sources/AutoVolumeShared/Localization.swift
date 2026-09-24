import Foundation

/// The language a user picks in Settings. `.system` follows the OS language
/// and is resolved to a concrete `ResolvedLanguage` at lookup time.
public enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system, chinese, english, korean, japanese, russian

    public var id: String { rawValue }

    /// Native self-name shown in the language picker; `.system` is localized
    /// via `L10n` ("跟随系统" / "System" / …) rather than hardcoded here.
    public var displayName: String {
        switch self {
        case .system: return L10n.t(.languageSystem)
        case .chinese: return "中文"
        case .english: return "English"
        case .korean: return "한국어"
        case .japanese: return "日本語"
        case .russian: return "Русский"
        }
    }
}

/// The concrete language a piece of UI text is rendered in, after resolving
/// `.system` (and any language without its own table) down to one of these.
public enum ResolvedLanguage: String {
    case zh, en, ko, ja, ru

    /// Resolves an `AppLanguage` choice to a concrete language. `.system`
    /// uses `systemLanguageCode` (normally the language subtag of
    /// `Locale.preferredLanguages.first`); unsupported codes fall back to
    /// English. Explicit user choices always win.
    public static func resolve(_ language: AppLanguage, systemLanguageCode: String) -> ResolvedLanguage {
        switch language {
        case .system:
            switch systemLanguageCode {
            case "zh": return .zh
            case "ko": return .ko
            case "ja": return .ja
            case "ru": return .ru
            default: return .en
            }
        case .chinese: return .zh
        case .english: return .en
        case .korean: return .ko
        case .japanese: return .ja
        case .russian: return .ru
        }
    }

}

/// The `.lproj` folder name candidates for `language`, in priority order, for the process-wide
/// `Bundle.localizedString(forKey:value:table:)` swizzle (in `AutoVolumeApp`) that forces
/// third-party frameworks like Sparkle to follow the app's language choice.
///
/// English needs two candidates rather than one: Sparkle 2.10's own framework bundle ships
/// only `Base.lproj` (no `en.lproj`), while AppKit's bundle ships `en.lproj` (no
/// `Base.lproj`). A single fixed folder name would silently fail to redirect one of the two —
/// trying `"en"` first and falling back to `"Base"` covers both. The other languages only ship
/// their own named folder, so a single candidate is enough.
public func localizationFolderCandidates(for language: ResolvedLanguage) -> [String] {
    switch language {
    case .zh: return ["zh_CN"]
    case .ja: return ["ja"]
    case .ko: return ["ko"]
    case .ru: return ["ru"]
    case .en: return ["en", "Base"]
    }
}

/// A namespaced localization key, for example `L10nKey.settingsLanguage`.
/// Keys are declared as `public static let` constants in an extension so
/// later tasks can add keys by adding a constant plus table entries.
public struct L10nKey: RawRepresentable, Hashable {
    public let rawValue: String
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension L10nKey {
    public static let languageSystem = L10nKey(rawValue: "language.system")
    public static let settingsLanguage = L10nKey(rawValue: "settings.language")

    // MARK: - Task 3: keyed alerts and error messages

    public static let alertNTFSOnboarding = L10nKey(rawValue: "alert.ntfs.onboarding")
    public static let alertNTFSInstallFailed = L10nKey(rawValue: "alert.ntfs.installFailed")
    public static let alertNTFSMountFailed = L10nKey(rawValue: "alert.ntfs.mountFailed")

    public static let errorConnectivityWebDAVUnauthorized = L10nKey(rawValue: "error.connectivity.webdav.unauthorized")
    public static let errorConnectivityWebDAVForbidden = L10nKey(rawValue: "error.connectivity.webdav.forbidden")
    public static let errorConnectivityWebDAVNotFound = L10nKey(rawValue: "error.connectivity.webdav.notFound")
    public static let errorConnectivityUnreachable = L10nKey(rawValue: "error.connectivity.unreachable")
    public static let errorConnectivitySMBUnreachable = L10nKey(rawValue: "error.connectivity.smb.unreachable")
    public static let errorConnectivityAFPUnreachable = L10nKey(rawValue: "error.connectivity.afp.unreachable")
    public static let errorConnectivityNFSUnreachable = L10nKey(rawValue: "error.connectivity.nfs.unreachable")
    public static let errorConnectivityTestFailed = L10nKey(rawValue: "error.connectivity.testFailed")

    public static let errorAgentMountCommandFailed = L10nKey(rawValue: "error.agent.mountCommandFailed")
    public static let errorAgentMountUnresponsive = L10nKey(rawValue: "error.agent.mountUnresponsive")

    // MARK: - Task 4: full app UI (list, editor, menu, status, settings, about)

    public static let appProductName = L10nKey(rawValue: "app.productName")

    public static let listEmptyTitle = L10nKey(rawValue: "list.emptyTitle")
    public static let listEmptyDescription = L10nKey(rawValue: "list.emptyDescription")
    public static let listAdd = L10nKey(rawValue: "list.add")
    public static let listEdit = L10nKey(rawValue: "list.edit")
    public static let listRemove = L10nKey(rawValue: "list.remove")
    public static let listMount = L10nKey(rawValue: "list.mount")
    public static let listUnmount = L10nKey(rawValue: "list.unmount")
    public static let listAlerts = L10nKey(rawValue: "list.alerts")
    public static let listClearAlerts = L10nKey(rawValue: "list.clearAlerts")
    public static let listNoAlerts = L10nKey(rawValue: "list.noAlerts")
    public static let listNtfsReadWriteBadge = L10nKey(rawValue: "list.ntfsReadWriteBadge")
    public static let listIntervalMinutesShort = L10nKey(rawValue: "list.intervalMinutesShort")

    public static let editorTest = L10nKey(rawValue: "editor.test")
    public static let editorSaveAndMount = L10nKey(rawValue: "editor.saveAndMount")
    public static let editorSave = L10nKey(rawValue: "editor.save")
    public static let editorCancel = L10nKey(rawValue: "editor.cancel")
    public static let editorName = L10nKey(rawValue: "editor.name")
    public static let editorServer = L10nKey(rawValue: "editor.server")
    public static let editorRemotePath = L10nKey(rawValue: "editor.remotePath")
    public static let editorRemotePathHelp = L10nKey(rawValue: "editor.remotePathHelp")
    public static let editorUsername = L10nKey(rawValue: "editor.username")
    public static let editorPassword = L10nKey(rawValue: "editor.password")
    public static let editorProtocolLabel = L10nKey(rawValue: "editor.protocolLabel")
    public static let editorMountPoint = L10nKey(rawValue: "editor.mountPoint")
    public static let editorCheckInterval = L10nKey(rawValue: "editor.checkInterval")
    public static let editorEveryMinutes = L10nKey(rawValue: "editor.everyMinutes")
    public static let editorShowPassword = L10nKey(rawValue: "editor.showPassword")
    public static let editorHidePassword = L10nKey(rawValue: "editor.hidePassword")
    public static let editorSmbDialect = L10nKey(rawValue: "editor.smbDialect")
    public static let editorSmbMultichannel = L10nKey(rawValue: "editor.smbMultichannel")
    public static let editorSmbAsyncReads = L10nKey(rawValue: "editor.smbAsyncReads")
    public static let editorSmbDialectAuto = L10nKey(rawValue: "editor.smbDialectAuto")

    public static let statusWorking = L10nKey(rawValue: "status.working")
    public static let statusTesting = L10nKey(rawValue: "status.testing")
    public static let statusMounting = L10nKey(rawValue: "status.mounting")
    public static let statusUnmounting = L10nKey(rawValue: "status.unmounting")
    public static let statusUnmountSucceeded = L10nKey(rawValue: "status.unmountSucceeded")
    public static let statusMountSucceeded = L10nKey(rawValue: "status.mountSucceeded")
    public static let statusTestSucceeded = L10nKey(rawValue: "status.testSucceeded")
    public static let statusSaved = L10nKey(rawValue: "status.saved")

    public static let menuViewLogs = L10nKey(rawValue: "menu.viewLogs")
    public static let menuExportDiagnostics = L10nKey(rawValue: "menu.exportDiagnostics")
    public static let menuSettings = L10nKey(rawValue: "menu.settings")
    public static let menuCheckForUpdates = L10nKey(rawValue: "menu.checkForUpdates")
    public static let menuQuit = L10nKey(rawValue: "menu.quit")

    public static let aboutProductName = L10nKey(rawValue: "about.productName")
    public static let aboutVersion = L10nKey(rawValue: "about.version")
    public static let aboutWebsite = L10nKey(rawValue: "about.website")

    public static let alertOk = L10nKey(rawValue: "alert.ok")
    public static let alertExportDiagnosticsFailedTitle = L10nKey(rawValue: "alert.exportDiagnosticsFailedTitle")

    public static let errorCommandConnectionTestFailed = L10nKey(rawValue: "error.command.connectionTestFailed")
    public static let errorCommandMountFailed = L10nKey(rawValue: "error.command.mountFailed")
    public static let errorCommandUnmountFailed = L10nKey(rawValue: "error.command.unmountFailed")
    public static let errorCommandFinderFailed = L10nKey(rawValue: "error.command.finderFailed")
    public static let errorCommandGenericFailed = L10nKey(rawValue: "error.command.genericFailed")

    public static let errorMountWebdavFinder5014 = L10nKey(rawValue: "error.mount.webdavFinder5014")
    public static let errorMountWebdavExit22 = L10nKey(rawValue: "error.mount.webdavExit22")
    public static let errorMountVolumeNotResponding = L10nKey(rawValue: "error.mount.volumeNotResponding")
    public static let errorMountVolumeNotRespondingAfterStaleClear = L10nKey(rawValue: "error.mount.volumeNotRespondingAfterStaleClear")
    public static let errorMountVolumeNotRespondingAfterOccupiedClear = L10nKey(rawValue: "error.mount.volumeNotRespondingAfterOccupiedClear")
    public static let errorMountVolumeNotRespondingAtRemotePath = L10nKey(rawValue: "error.mount.volumeNotRespondingAtRemotePath")

    public static let errorFinderNotResponding = L10nKey(rawValue: "error.finder.notResponding")
    public static let errorFinderOpenFailed = L10nKey(rawValue: "error.finder.openFailed")

    // MARK: - Final review wave: remaining hardcoded English

    public static let errorMountInvalidRemotePath = L10nKey(rawValue: "error.mount.invalidRemotePath")
    public static let errorDiagnosticsZipFailed = L10nKey(rawValue: "error.diagnostics.zipFailed")

    public static let settingsSectionLogging = L10nKey(rawValue: "settings.sectionLogging")
    public static let settingsLogLevel = L10nKey(rawValue: "settings.logLevel")
    public static let settingsLogLevelAll = L10nKey(rawValue: "settings.logLevelAll")
    public static let settingsLogLevelWarning = L10nKey(rawValue: "settings.logLevelWarning")
    public static let settingsLogLevelError = L10nKey(rawValue: "settings.logLevelError")
    public static let settingsLogLevelHelp = L10nKey(rawValue: "settings.logLevelHelp")
    public static let settingsSectionMounting = L10nKey(rawValue: "settings.sectionMounting")
    public static let settingsOpenFinderAfterMount = L10nKey(rawValue: "settings.openFinderAfterMount")
    public static let settingsOpenFinderAfterMountHelp = L10nKey(rawValue: "settings.openFinderAfterMountHelp")
    public static let settingsSectionNTFS = L10nKey(rawValue: "settings.sectionNTFS")
    public static let settingsNtfsAutoMount = L10nKey(rawValue: "settings.ntfsAutoMount")
    public static let settingsNtfsAutoMountHelp = L10nKey(rawValue: "settings.ntfsAutoMountHelp")

    // MARK: - Task 5: Settings TabView (General/NTFS/About)

    public static let settingsTabGeneral = L10nKey(rawValue: "settings.tab.general")
    public static let settingsTabNTFS = L10nKey(rawValue: "settings.tab.ntfs")
    public static let settingsTabAbout = L10nKey(rawValue: "settings.tab.about")
}

extension Notification.Name {
    public static let autoVolumeLanguageChanged = Notification.Name("autoVolumeLanguageChanged")
}

/// The shared localization lookup, used by both the app and the agent.
/// Thread-safe: the current language is kept behind a lock.
public enum L10n {
    private static let lock = NSLock()
    private static var _language: AppLanguage = .system

    public static var language: AppLanguage {
        lock.lock()
        defer { lock.unlock() }
        return _language
    }

    /// The concrete language currently in effect, resolving `.system` via
    /// `Locale.preferredLanguages.first`.
    public static var resolved: ResolvedLanguage {
        ResolvedLanguage.resolve(language, systemLanguageCode: systemLanguageCode())
    }

    private static func systemLanguageCode() -> String {
        guard let preferred = Locale.preferredLanguages.first else { return "en" }
        return Locale(identifier: preferred).language.languageCode?.identifier ?? "en"
    }

    /// Sets the active language. Posts `.autoVolumeLanguageChanged` on the
    /// main thread if the language actually changed.
    public static func setLanguage(_ language: AppLanguage) {
        lock.lock()
        let changed = _language != language
        _language = language
        lock.unlock()

        guard changed else { return }

        if Thread.isMainThread {
            NotificationCenter.default.post(name: .autoVolumeLanguageChanged, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .autoVolumeLanguageChanged, object: nil)
            }
        }
    }

    /// Looks up `key` in the current language, substituting `args`
    /// positionally (`%1$@`, `%2$@`, …).
    public static func t(_ key: L10nKey, _ args: String...) -> String {
        t(key, args: args, in: resolved)
    }

    public static func t(_ key: L10nKey, args: [String]) -> String {
        t(key, args: args, in: resolved)
    }

    /// Looks up `key` in `language` specifically, exposed for tests.
    /// Lookup order: `language`'s table, then the English table, then the
    /// raw key itself.
    public static func t(_ key: L10nKey, args: [String], in language: ResolvedLanguage) -> String {
        let format = tables[language]?[key.rawValue] ?? tables[.en]?[key.rawValue] ?? key.rawValue
        // Only skip formatting for templates with no positional placeholders at all — a
        // template that DOES have `%n$@` placeholders must always be run through
        // `String(format:)`, even with zero args, so the caller never sees a literal "%1$@" in
        // the UI. `padded` below covers the zero-args case by padding all the way up to
        // `requiredCount`.
        guard maxPositionalArgumentIndex(in: format) > 0 else { return format }
        return String(format: format, arguments: padded(args, for: format))
    }

    /// Pads `args` with empty strings up to the highest `%n$@` placeholder index referenced
    /// in `format`. `String(format:arguments:)` with positional specifiers reads directly into
    /// the arguments array by index — if the caller supplies fewer args than the format
    /// references, that's undefined behavior (a crash), not a graceful no-op. Padding with ""
    /// keeps every call safe regardless of how many args the caller actually has on hand.
    /// Extra args beyond what the format references are left as-is; `String(format:)` ignores
    /// unused trailing arguments.
    private static func padded(_ args: [String], for format: String) -> [String] {
        let requiredCount = maxPositionalArgumentIndex(in: format)
        guard args.count < requiredCount else { return args }
        return args + Array(repeating: "", count: requiredCount - args.count)
    }

    /// Scans `format` for `%<digits>$` positional specifiers (as used by every table entry,
    /// e.g. `%1$@`, `%2$@`) and returns the highest index referenced, or 0 if none are found.
    private static func maxPositionalArgumentIndex(in format: String) -> Int {
        var maxIndex = 0
        let chars = Array(format)
        var i = 0
        while i < chars.count {
            guard chars[i] == "%" else {
                i += 1
                continue
            }
            var j = i + 1
            var digits = ""
            while j < chars.count, chars[j].isNumber {
                digits.append(chars[j])
                j += 1
            }
            if j < chars.count, chars[j] == "$", !digits.isEmpty, let index = Int(digits) {
                maxIndex = max(maxIndex, index)
                i = j + 1
            } else {
                i += 1
            }
        }
        return maxIndex
    }

    static let tables: [ResolvedLanguage: [String: String]] = [
        .zh: zhTable,
        .en: enTable,
        .ko: koTable,
        .ja: jaTable,
        .ru: ruTable
    ]

    /// Exposes a language's table for tests (no `@testable` import available
    /// since these are separately-compiled swiftc targets, not an SPM build).
    public static func table(_ language: ResolvedLanguage) -> [String: String] {
        tables[language] ?? [:]
    }

    /// The keys of the English table, used as the canonical key set for
    /// completeness tests.
    public static var allKeys: [String] {
        Array(enTable.keys)
    }
}
