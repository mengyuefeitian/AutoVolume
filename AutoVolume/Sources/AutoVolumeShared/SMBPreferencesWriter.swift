import Foundation

public struct SMBPreferencesWriter {
    private let fileURL: URL

    public init(fileURL: URL = SMBPreferencesWriter.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/nsmb.conf")
    }

    public func apply(options: SMBOptions) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let unmanaged = removeManagedBlock(from: existing)
        let managed = """

        # BEGIN AutoVolume managed SMB options
        [default]
        protocol_vers_map=\(options.dialect.protocolVersionMap)
        mc_on=\(options.isMultichannelEnabled ? "yes" : "no")
        dir_cache_async_cnt=\(max(1, options.asyncDirectoryQueryCount))
        # END AutoVolume managed SMB options

        """
        try (unmanaged.trimmingCharacters(in: .whitespacesAndNewlines) + managed)
            .write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func removeManagedBlock(from text: String) -> String {
        let pattern = #"(?s)\n?# BEGIN AutoVolume managed SMB options.*?# END AutoVolume managed SMB options\n?"#
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
}
