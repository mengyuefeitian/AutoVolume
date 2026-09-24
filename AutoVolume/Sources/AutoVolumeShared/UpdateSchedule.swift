import Foundation

/// Sparkle update-check policy shared between the app (configuring the
/// updater) and Info.plist (`SUEnableAutomaticChecks` / `SUScheduledCheckInterval`,
/// set by `script/build_and_run.sh`). Keep these two sources in sync.
public enum UpdateSchedule {
    public static let automaticallyChecks = true
    public static let checkInterval: TimeInterval = 86400
}
