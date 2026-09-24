import Foundation
import ObjectiveC
import AutoVolumeShared

/// Method-swizzles `Bundle.localizedString(forKey:value:table:)` process-wide, but only
/// actually redirects the lookup for Sparkle's own framework bundle
/// (`org.sparkle-project.Sparkle`) — every other bundle (including `Bundle.main` and, most
/// importantly, AppKit/Foundation) falls straight through to the original implementation.
///
/// `Bundle`'s own automatic locale resolution — used internally by any `NSLocalizedString`-style
/// lookup, including Sparkle's own update-check alerts — does not honor the standard
/// `AppleLanguages` `UserDefaults` override for a bundle other than `Bundle.main` (this is the
/// standard, documented workaround for making a bundled framework like Sparkle follow an in-app
/// language switch). This app's own UI goes through `L10n.t(_:)`, not `NSLocalizedString`, so it
/// never touches this swizzle at all.
///
/// The redirect MUST be scoped to Sparkle specifically. AppKit and Foundation resolve most of
/// their system strings (including `NSError.localizedDescription` for Cocoa error codes) not
/// out of a leaf `<lang>.lproj/Localizable.strings` file but out of root-level `.loctable`
/// files that a leaf-`.lproj`-only redirect never sees — forcing every bundle through
/// `localizationFolderCandidates` therefore made every `error.localizedDescription` come back
/// as a generic "The operation couldn't be completed. (Cocoa error N.)" on every language,
/// including English on an English system. AppKit ships only `en.lproj` (no `Base.lproj`);
/// Sparkle 2.10 ships only `Base.lproj` (no `en.lproj`) — `localizationFolderCandidates(for:)`
/// gives an ordered list per language so the first candidate present on the Sparkle bundle wins
/// regardless of which of the two it uses for English.
extension Bundle {
    private static let sparkleBundleIdentifier = "org.sparkle-project.Sparkle"

    private static let activateOnce: Void = {
        let originalSelector = #selector(Bundle.localizedString(forKey:value:table:))
        let swizzledSelector = #selector(Bundle.autoVolume_localizedString(forKey:value:table:))
        guard let originalMethod = class_getInstanceMethod(Bundle.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(Bundle.self, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()

    /// Activates the swizzle. Idempotent — safe to call more than once; only the first call
    /// has any effect, via `activateOnce`'s lazy-static, thread-safe one-time initialization.
    static func activateLanguageOverride() {
        _ = activateOnce
    }

    @objc private func autoVolume_localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        guard self.bundleIdentifier == Bundle.sparkleBundleIdentifier else {
            // Not Sparkle's own framework bundle — calling the same selector here invokes the
            // ORIGINAL implementation, since method_exchangeImplementations swapped it in under
            // this selector's name. Covers Bundle.main (this app's own strings, which don't use
            // this path anyway) and every AppKit/Foundation/system bundle.
            return self.autoVolume_localizedString(forKey: key, value: value, table: tableName)
        }
        for folder in localizationFolderCandidates(for: L10n.resolved) {
            if let path = self.path(forResource: folder, ofType: "lproj"),
               let languageBundle = Bundle(path: path) {
                // languageBundle is a leaf .lproj bundle with no bundleIdentifier of its own, so
                // the guard above fails on the recursive call and falls through to the ORIGINAL
                // implementation, run against languageBundle — the actual real lookup. No
                // infinite recursion.
                return languageBundle.autoVolume_localizedString(forKey: key, value: value, table: tableName)
            }
        }
        // No candidate folder exists on the Sparkle bundle for this language — fall through to
        // its own original resolution.
        return self.autoVolume_localizedString(forKey: key, value: value, table: tableName)
    }
}
