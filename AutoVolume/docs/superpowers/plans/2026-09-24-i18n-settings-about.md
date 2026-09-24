# Multi-language UI, Settings Tabs, About Page — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every user-visible string in AutoVolume, including Sparkle's update flow, follows one live-switchable language setting (System / 中文 / English / 한국어 / 日本語 / Русский). Settings becomes a tab view with an About tab.

**Architecture:** An in-code key → string table (`L10n`) lives in `AutoVolumeShared`, so the app and the agent share it. The language choice is stored in `settings.json`. A `Bundle` swizzle, ported from InceptLaunch, forces Sparkle's `.lproj`. Alerts store `messageKey` + `messageArgs` and are rendered when displayed.

**Tech Stack:** Swift 5 mode via raw `swiftc`, SwiftUI + AppKit, Sparkle 2.10.0.

**Spec:** `AutoVolume/docs/superpowers/specs/2026-09-24-i18n-settings-about-design.md`

## Global Constraints

- Build/test: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 AutoVolume/script/build_and_run.sh --no-launch`. Shell tests, all manual tests, and the binary-compat gate must pass with zero compiler warnings.
- New `.swift` files must be added to the correct `swiftc` list in `AutoVolume/script/build_and_run.sh`: the shared list for `AutoVolumeShared/*`, the app list for `AutoVolumeApp/*`.
- Min macOS 14.0 APIs only.
- Tests go in `AutoVolume/ManualTests/AutoVolumeManualTests.swift` (one function per test, registered in the `tests` array). They may only exercise `AutoVolumeShared`.
- Languages: `system, chinese, english, korean, japanese, russian`. Resolved tables: `zh, en, ko, ja, ru`. Sparkle folders: zh → `zh_CN`, ja → `ja`, ko → `ko`, ru → `ru`, en → none (all verified present in the embedded Sparkle.framework).
- Product name "AutoVolume" stays untranslated. "智卷" appears in zh only.
- Log messages (`AutoVolumeLogger`) stay in English. Do not localize them.
- **Never:** git commit/push, gh release, change versions (the controller bumps to 0.1.53 at the end), launch `dist/AutoVolume.app` or the agent, or mount/unmount real volumes.
- Every new key must be added to **all five** tables in the same task. The completeness test enforces this.

## Review Focus

1. The user switches language while the popover, editor, or Settings is open. All three re-render immediately, and window titles update.
2. `settings.json` and `alerts.json` written by 0.1.52 (no `language` field / no key fields) still load. The old `AutoVolume.language` preference (chinese/english) migrates.
3. Sparkle's "Check for Updates" window uses the chosen language, including System → Chinese on a Chinese Mac.
4. A translated format string whose placeholders don't match English would crash or garble. The placeholder-parity test covers it.
5. An alert recorded in Chinese, viewed after switching to Japanese, shows Japanese.

---

### Task 1: Localization core

**Files:**
- Create: `AutoVolume/Sources/AutoVolumeShared/Localization.swift` (`AppLanguage`, `ResolvedLanguage`, `L10nKey`, `L10n`, notification name)
- Create: `AutoVolume/Sources/AutoVolumeShared/Localization+Tables.swift` (five `[String: String]` tables; split into per-language files if it passes about 700 lines)
- Modify: `AutoVolume/script/build_and_run.sh` (shared list)
- Test: `AutoVolume/ManualTests/AutoVolumeManualTests.swift`

**Interfaces (produced, used by all later tasks):**

```swift
public enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system, chinese, english, korean, japanese, russian
    public var id: String { rawValue }
    /// Native self-name; `.system` is localized via L10n ("跟随系统" / "System" / …).
    public var displayName: String
}
public enum ResolvedLanguage: String { case zh, en, ko, ja, ru
    public static func resolve(_ language: AppLanguage, systemLanguageCode: String) -> ResolvedLanguage
    /// Sparkle .lproj folder, nil for English.
    public var sparkleFolder: String?
}
public struct L10nKey: RawRepresentable, Hashable { public let rawValue: String; public init(rawValue: String) }
extension Notification.Name { public static let autoVolumeLanguageChanged: Notification.Name }
public enum L10n {
    public static var language: AppLanguage { get }            // thread-safe (NSLock)
    public static var resolved: ResolvedLanguage { get }        // uses Locale.preferredLanguages.first for .system
    public static func setLanguage(_ language: AppLanguage)     // posts .autoVolumeLanguageChanged on main if changed
    public static func t(_ key: L10nKey, _ args: String...) -> String
    public static func t(_ key: L10nKey, args: [String]) -> String
    public static func t(_ key: L10nKey, args: [String], in language: ResolvedLanguage) -> String   // for tests
    static let tables: [ResolvedLanguage: [String: String]]    // internal; @testable not available — expose `public static func table(_:) -> [String: String]`
    public static var allKeys: [String] { get }                 // keys of the English table
}
```

Semantics:
- Lookup goes resolved table → English table → `key.rawValue`.
- Args are substituted with `String(format:)` using positional `%1$@`, `%2$@`.
- `.system` resolution: take the language subtag of `Locale.preferredLanguages.first`, where "zh-Hans-CN" → "zh" (use `Locale(identifier:).language.languageCode?.identifier`).
- Keys are namespaced strings declared as `static let` on `L10nKey`, for example `L10nKey.languageSystem = "language.system"`.

Starter keys for this task: `language.system`, `settings.language`. Later tasks add the rest.

- [ ] **Step 1: Write failing tests** (register all):

```swift
func testL10nEveryKeyExistsInAllLanguages() throws {
    for language in [ResolvedLanguage.zh, .en, .ko, .ja, .ru] {
        let table = L10n.table(language)
        for key in L10n.allKeys {
            try expect(!(table[key] ?? "").isEmpty, "\(language.rawValue) missing key \(key)")
        }
    }
}

func testL10nPlaceholdersMatchEnglish() throws {
    let english = L10n.table(.en)
    func placeholders(_ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%\\d+\\$@")
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }.sorted()
    }
    for language in [ResolvedLanguage.zh, .ko, .ja, .ru] {
        for (key, value) in L10n.table(language) {
            try expect(placeholders(value) == placeholders(english[key] ?? ""), "\(language.rawValue) placeholder mismatch for \(key)")
        }
    }
}

func testResolvedLanguageFromSystemCodes() throws {
    try expect(ResolvedLanguage.resolve(.system, systemLanguageCode: "zh") == .zh, "zh")
    try expect(ResolvedLanguage.resolve(.system, systemLanguageCode: "ja") == .ja, "ja")
    try expect(ResolvedLanguage.resolve(.system, systemLanguageCode: "ko") == .ko, "ko")
    try expect(ResolvedLanguage.resolve(.system, systemLanguageCode: "ru") == .ru, "ru")
    try expect(ResolvedLanguage.resolve(.system, systemLanguageCode: "de") == .en, "de falls back to en")
    try expect(ResolvedLanguage.resolve(.korean, systemLanguageCode: "zh") == .ko, "explicit choice wins")
    try expect(ResolvedLanguage.zh.sparkleFolder == "zh_CN" && ResolvedLanguage.en.sparkleFolder == nil, "sparkle folders")
}

func testL10nFallsBackToEnglishThenKey() throws {
    try expect(L10n.t(L10nKey(rawValue: "no.such.key"), args: [], in: .ja) == "no.such.key", "unknown key returns key")
    try expect(L10n.t(.settingsLanguage, args: [], in: .zh) == "语言", "zh settings.language")
    try expect(L10n.t(.settingsLanguage, args: [], in: .en) == "Language", "en settings.language")
}
```

- [ ] **Step 2: Run the build.** Expected: compile failure (types missing).
- [ ] **Step 3: Implement `Localization.swift` and the tables.** Starter values:
  - `language.system`: zh "跟随系统", en "System", ko "시스템 설정", ja "システム設定", ru "Как в системе".
  - `settings.language`: zh "语言", en "Language", ko "언어", ja "言語", ru "Язык".
- [ ] **Step 4: Run the build.** Expected: all tests pass.

---

### Task 2: Persist language, migrate, Sparkle override, launch wiring

**Files:**
- Modify: `AutoVolume/Sources/AutoVolumeShared/AppSettings.swift` (add `language: AppLanguage`, `decodeIfPresent` → `.system`, add to init with default `.system`)
- Create: `AutoVolume/Sources/AutoVolumeApp/BundleLocalizationOverride.swift` (port of `/Users/xiaoan/Documents/code/InceptLaunch/Sources/iLaunch/Support/BundleLocalizationOverride.swift`, driven by `L10n.resolved.sparkleFolder`; thread-safe; activate once)
- Modify: `AutoVolume/Sources/AutoVolumeApp/AutoVolumeApp.swift`: in `applicationDidFinishLaunching`, after the watchdog and before `UpdateService()`:
  1. Load settings.
  2. Run the migration.
  3. `L10n.setLanguage(settings.language)`.
  4. `Bundle.activateLanguageOverride()`.
- Modify: `AutoVolume/Sources/AutoVolumeApp/AppViewModel.swift`:
  - Remove the app-local `AppLanguage` enum and the `languageDefaultsKey` persistence.
  - `language` becomes a computed get/set over `settings.language`. The setter saves settings and calls `L10n.setLanguage`.
- Create (shared, testable): `public enum LanguageMigration { public static func migrate(settings: AppSettings, legacyValue: String?) -> AppSettings? }`. It returns updated settings only when the stored JSON lacked `language` and the legacy value is `chinese` or `english`. To detect "lacked", add `public private(set) var languageWasPresent: Bool` to `AppSettings`, excluded from encoding (set in `init(from:)`).
- Test: ManualTests.

- [ ] **Step 1: Failing tests:**
  - (a) `AppSettings` decodes `{"logLevel":"info","openFinderAfterMount":true}` → `language == .system` and `languageWasPresent == false`.
  - (b) Round-trip of each `AppLanguage` case.
  - (c) `LanguageMigration.migrate(settings: decodedWithoutLanguage, legacyValue: "chinese")?.language == .chinese`.
  - (d) The same call with `legacyValue: nil` returns nil.
  - (e) Migration returns nil when `languageWasPresent`.
- [ ] **Step 2: Run** and confirm failure. **Step 3:** Implement. **Step 4:** Run and confirm pass.
- [ ] **Step 5:** `grep -rn "AutoVolume.language\|languageDefaultsKey" Sources` must return only the migration read site in AppDelegate.

---

### Task 3: Keyed alerts and error messages (shared + agent)

**Files:**
- Modify: `AutoVolume/Sources/AutoVolumeShared/AlertStore.swift`: `VolumeAlert` gains `messageKey: String?` and `messageArgs: [String]?` (`decodeIfPresent`). Add `public var localizedMessage: String` (key present → `L10n.t(L10nKey(rawValue: key), args: messageArgs ?? [])`, else `message`). Add `record(volumeID:volumeName:key:args:date:)`, which stores `message = L10n.t(key, args: args, in: .en)`.
- Modify: `AutoVolume/Sources/AutoVolumeShared/ConnectivityTesting.swift`: `ConnectivityCheckResult` gains `messageKey: L10nKey?` and `messageArgs: [String]`. `message` keeps its English rendering for callers and logs. Every hardcoded sentence moves to keys under `error.connectivity.*`.
- Modify: `AutoVolume/Sources/AutoVolumeShared/AgentEngine.swift`: every `.failed(message:)` path carries a key and args. Add `messageKey`/`messageArgs` to the failure case or its result type, whichever is least invasive. The alert recording site uses the keyed `record`.
- Modify: `AutoVolume/Sources/AutoVolumeShared/NTFSAutoMountService.swift`: the three alerts become keys:
  - `alert.ntfs.onboarding` (arg: volume name)
  - `alert.ntfs.installFailed` (arg: volume name)
  - `alert.ntfs.mountFailed` (args: volume name, raw helper message)
- `NTFSHelperClient` technical messages stay English. They are raw detail passed as args.
- Test: ManualTests.

- [ ] **Step 1: Failing tests:**
  - (a) Old alert JSON without key fields decodes, and `localizedMessage == message`.
  - (b) An alert recorded with `.alertNTFSInstallFailed` and args `["MyDisk"]` has a `localizedMessage` containing "MyDisk" in every language (switch via `L10n.setLanguage`, then restore `.system`), and its stored `message` is the English text.
  - (c) `ConnectivityTester().checkResult` for a WebDAV 401 result returns `messageKey == .errorConnectivityWebDAVUnauthorized`. Do the same for 403, 404, and unreachable (exit 124).
  - (d) Existing NTFS/Agent tests are updated to assert keys instead of Chinese/English literals.
- [ ] **Step 2 through Step 4:** RED, implement (add every new key to all 5 tables), GREEN.

---

### Task 4: Convert the app UI to L10n with live switching

**Files:**
- Modify: `AutoVolume/Sources/AutoVolumeApp/AppViewModel.swift`: delete `AppStrings` (both language blocks) and `strings`/`productName`. Every error thrown to the UI (`AppViewModelError.commandFailed` messages, the Finder / -5014 / exit-22 messages, `finderOpenFailureMessage`) uses `L10n.t`. Raw stderr is passed as an arg.
- Modify: `AutoVolume/Sources/AutoVolumeApp/ContentView.swift`:
  - Remove the header language `Picker`.
  - Every string becomes `L10n.t`.
  - Alerts display `alert.localizedMessage`.
  - The NTFS badge is keyed.
- Modify: `AutoVolume/Sources/AutoVolumeApp/VolumeEditorView.swift`: all 33 `strings.*` uses become keys, including help text and pickers.
- Modify: `AutoVolume/Sources/AutoVolumeApp/StatusBarController.swift`:
  - Replace `localized(_:_:)` with `L10n.t`.
  - The menu still rebuilds on each open.
  - Window titles (editor, Settings) are set from keys and updated on `.autoVolumeLanguageChanged`.
- Live re-render: `AppViewModel` gets an observed `languageRevision: Int`, incremented on `.autoVolumeLanguageChanged`. Views read `viewModel.languageRevision` in `body` (for example `let _ = viewModel.languageRevision`), so SwiftUI re-evaluates.
- Keys: `list.*`, `editor.*`, `menu.*`, `status.*`, `error.*` for every string currently in `AppStrings` and the `localized()` calls, with all 5 languages. Port the existing zh/en wording exactly, then translate it to ko/ja/ru.

- [ ] **Step 1:** Add the keys to all tables. The completeness and placeholder tests from Task 1 act as RED/GREEN for the tables.
- [ ] **Step 2:** Convert the views.
- [ ] **Step 3:** `grep -rn "localized(\|AppStrings\|strings\.\|== .chinese" AutoVolume/Sources` must return nothing. Every non-log `"…"` literal in the UI files must be a key, a symbol name, or a URL.
- [ ] **Step 4:** Build. All tests pass with zero warnings.

---

### Task 5: Settings TabView, About tab, menu change

**Files:**
- Modify: `AutoVolume/Sources/AutoVolumeApp/SettingsView.swift`: a `TabView` with about a 480×420 frame:
  - **通用 (General)** (`settings.tab.general`): Language `Picker` over `AppLanguage.allCases` using `displayName`, where `.system` shows `L10n.t(.languageSystem)`. Then the existing log-level and open-in-Finder controls.
  - **NTFS** (`settings.tab.ntfs`): the existing NTFS toggle and its caption.
  - **关于 (About)** (`settings.tab.about`):
    - `NSApp.applicationIconImage` at 64 pt
    - Title: `L10n.t(.aboutProductName)` (zh "智卷 AutoVolume", others "AutoVolume")
    - Version line `L10n.t(.aboutVersion, short, build)`
    - `Link("GitHub", destination: URL(string: "https://github.com/mengyuefeitian/AutoVolume")!)`
    - `Link(L10n.t(.aboutWebsite), destination: URL(string: "https://www.xiaoanhome.xyz/autovolume")!)`
    - Each link also shows its URL as secondary text.
    - Button `L10n.t(.menuCheckForUpdates)` → `updateService.checkForUpdates()`
- `SettingsView` gains an `updateService: UpdateService` parameter. `SettingsWindowController.show` passes it (StatusBarController already holds `updateService`).
- The language picker's `onChange` → `viewModel.language = newValue`, which persists and calls `L10n.setLanguage`.
- Modify `StatusBarController.showContextMenu()`: remove "关于" (About) and `showAbout()`. The order is View Logs, Export Diagnostics…, Settings, Check for Updates…, separator, Quit.
- Keys: `settings.tab.*`, `settings.*` (existing captions), `about.*`, in all 5 languages.

- [ ] **Step 1:** Add the keys. The table tests stay green.
- [ ] **Step 2:** Implement the views and the menu.
- [ ] **Step 3:** Build. All tests pass with zero warnings.

---

### Task 6 (controller): version 0.1.53, build, package

- [ ] Set `Resources/Info.plist` to `0.1.53` / `53`. Run `build_and_run.sh --verify`, then `package_dmg.sh 0.1.53-test`. The package script refuses to reuse a version.
- [ ] Hand off to the user with this manual checklist:
  - Cycle through all 6 languages with the popover, editor, and Settings open.
  - Sparkle's "Check for Updates" window appears in each language.
  - The About links open.
  - An old alert still displays.
