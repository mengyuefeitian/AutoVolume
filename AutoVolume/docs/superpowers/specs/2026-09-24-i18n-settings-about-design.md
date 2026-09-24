# Design: Multi-language UI (System / 中文 / English / 한국어 / 日本語 / Русский), Settings tabs, About page

Date: 2026-09-24 · Status: approved in chat ("ok"), pending spec review

## Objective

Everything a user sees in AutoVolume follows one language choice in Settings. That covers the menu-bar popover, the volume editor, Settings, the right-click menu, alerts and error messages, and Sparkle's update prompts, download, install and relaunch flow. The choice takes effect immediately, with no restart. The About page moves into Settings and shows GitHub and website links.

Triggering complaint: the Sparkle "检查更新…" (Check for Updates) flow shows only English. Root cause: the app bundle declares no localizations, so `Bundle` resolution for `Sparkle.framework` falls back to `en` even on a Chinese system. InceptLaunch hit the same issue and confirmed that the `AppleLanguages` override does not fix it for a non-main bundle.

## Decisions (user-confirmed)

- Languages: System default, 中文 (zh-Hans), English, 한국어, 日本語, Русский.
- Alerts store a **message key + args** and are translated when displayed, so switching language re-translates existing alerts.
- "关于" (About) is removed from the right-click menu. About becomes a Settings tab.
- Approach: an in-code key → string table in `AutoVolumeShared`, following the InceptLaunch `Localizer` pattern. It is shared by the app and the agent. `.strings`/`.lproj` files are not used because they can't switch live and the agent can't easily share them. String Catalogs are not used because they need Xcode.

## Components

### 1. `AutoVolumeShared/Localization.swift` (new)
- `public enum AppLanguage: String, Codable, CaseIterable { case system, chinese, english, korean, japanese, russian }`, with `displayName` always shown in its own language: "跟随系统 / System", "中文", "English", "한국어", "日本語", "Русский". The `system` row is itself localized.
- `public enum ResolvedLanguage { case zh, en, ko, ja, ru }`, plus `static func resolve(_ language: AppLanguage, systemLanguageCode: String) -> ResolvedLanguage`. `zh`, `ko`, `ja` and `ru` map to themselves; anything else maps to `en`.
- `public final class L10n` (thread-safe; the current language is kept behind a lock):
  - `static func t(_ key: L10nKey, _ args: String...) -> String`
  - `static func setLanguage(_:)`, which posts `Notification.Name.autoVolumeLanguageChanged`
  - Lookup order: resolved language table, then English table, then the raw key.
  - Args use positional `%1$@` substitution.
- `L10nKey`: a `String`-backed enum or constants, grouped by area (`menu.*`, `list.*`, `editor.*`, `settings.*`, `about.*`, `alert.*`, `error.*`, `update.*`).
- Tables: five `[String: String]` dictionaries. They can go in one file per language (`Localization+zh.swift`, and so on) to keep files under 800 lines.

### 2. Language persistence
- `AppSettings` gains `language: AppLanguage`. Decoding uses `decodeIfPresent`, defaulting to `.system`.
- One-time migration: if `settings.json` has no `language` and `UserDefaults` key `AutoVolume.language` is `chinese` or `english`, map it across and save.
- The app calls `L10n.setLanguage` at launch before creating `UpdateService`, and again whenever the setting changes.

### 3. Sparkle localization
- Port InceptLaunch's `BundleLocalizationOverride.swift`, which swizzles `Bundle.localizedString(forKey:value:table:)` with a thread-safe override language. Map to Sparkle's `.lproj` folders: zh → `zh_CN`, ja → `ja`, ko → `ko`, ru → `ru`, en → nil (default). First verify the folder names against the embedded Sparkle 2.10.0 framework.
- Activate it in `applicationDidFinishLaunching` before `UpdateService()`.

### 4. Alerts
- `VolumeAlert` gains optional `messageKey: String?` and `messageArgs: [String]?`, decoded with `decodeIfPresent` so older `alerts.json` files still load.
- `AlertStore.record(...)` gains an overload that takes a key and args. It also stores the English rendering in `message`, as a fallback and for logs.
- Display: `alert.messageKey.map { L10n.t(key, args) } ?? alert.message`.
- All agent and NTFS alert call sites (`AgentEngine`, `NTFSAutoMountService`) move to keys.

### 5. Errors
- `ConnectivityTester.checkResult` messages, the `AppViewModel` error strings, the Finder, -5014 and exit-22 messages, and the NTFS helper client failure messages all become keys plus args.
- Raw subprocess stderr is not translated. It is appended after a localized label, for example `L10n.t(.errorMountFailedDetail, stderr)`.

### 6. UI
- Remove `AppStrings`, every `localized(_:_:)` helper, and the header language `Picker` in `ContentView`.
- Every visible string becomes `L10n.t(...)`. Views re-render on `.autoVolumeLanguageChanged` (for example `@State var languageTick` toggled in `onReceive`, or an `@Observable` language holder on `AppViewModel`).
- Window titles (editor, Settings) update on change.
- The right-click menu is rebuilt on each open, as it is today, so it is always current.
- Settings window becomes a `TabView`, about 480×420:
  - **通用 (General):** Language picker (6 options); log level; open in Finder after mount.
  - **NTFS:** the read-write toggle and its explanation.
  - **关于 (About):**
    - App icon and "智卷 AutoVolume"
    - Version `CFBundleShortVersionString (CFBundleVersion)`
    - GitHub link `https://github.com/mengyuefeitian/AutoVolume`
    - Website link `https://www.xiaoanhome.xyz/autovolume`, opened with `NSWorkspace.shared.open`
    - "检查更新…" (Check for Updates) button that calls `UpdateService.checkForUpdates()`
- Right-click menu: 查看日志 (View Logs), 导出诊断信息… (Export Diagnostics), 设置 (Settings), 检查更新… (Check for Updates), separator, 退出 (Quit). "关于" and `showAbout()` are removed.

## Out of scope
- Log file contents stay English (for diagnosis).
- The diagnostics zip contents are not translated.
- The DMG background image is not changed.
- Raw system error text is shown as-is.

## Testing (ManualTests, shared lib)
- Every `L10nKey` has a non-empty entry in all 5 tables.
- Every table's format placeholders match English for each key (same count of `%n$@`).
- `ResolvedLanguage.resolve` covers system codes zh/ja/ko/ru/de/en and each explicit choice.
- `L10n.t` falls back to English, then to the key.
- `AppSettings` decodes without `language` (defaults to `.system`) and round-trips each case.
- `VolumeAlert` decodes old JSON without the key fields. A keyed alert renders in each language.
- `ConnectivityTester.checkResult` returns keyed messages for 401/403/404/unreachable.
- Manual (user): switch through all 6 languages live; the Sparkle check-for-updates window appears in the chosen language; About links open in the browser.

## Constraints
- Build prefix `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0`; min macOS 14.0; binary-compat gate must pass.
- HARD RULE: new version for this build, **0.1.53 (53)**. Never repackage an existing version.
- Korean, Japanese and Russian translations are machine-authored and should be reviewed by a native speaker. Keep product name "AutoVolume" untranslated. The Chinese name "智卷" is used only in zh.
- No commits unless the user asks.
