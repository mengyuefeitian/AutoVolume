import XCTest
@testable import AutoVolumeShared

final class AutoVolumeLoggerTests: XCTestCase {
    private func makeLogger(directory: URL, settings: AppSettings) throws -> AutoVolumeLogger {
        let settingsStore = JSONAppSettingsStore(directory: directory)
        try settingsStore.save(settings)
        return AutoVolumeLogger(directory: directory, settingsStore: settingsStore)
    }

    private func loggedLines(directory: URL) -> [String] {
        let fileURL = directory.appendingPathComponent("AutoVolume.log")
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    func testDefaultLevelWritesAllSeverities() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let logger = try makeLogger(directory: directory, settings: AppSettings(logLevel: .info))

        logger.info("info message")
        logger.warning("warning message")
        logger.error("error message")

        let lines = loggedLines(directory: directory)
        XCTAssertEqual(lines.count, 3)
    }

    func testWarningLevelSuppressesInfoMessages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let logger = try makeLogger(directory: directory, settings: AppSettings(logLevel: .warning))

        logger.info("info message")
        logger.warning("warning message")
        logger.error("error message")

        let lines = loggedLines(directory: directory)
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines.contains { $0.contains("info message") })
    }

    func testWriteUsesLocalTimeZoneNotUTC() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let logger = try makeLogger(directory: directory, settings: AppSettings())
        let localFormatter = ISO8601DateFormatter()
        localFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        localFormatter.timeZone = .current
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        logger.write(level: "INFO", message: "tz check", date: date)

        let lines = loggedLines(directory: directory)
        let expectedPrefix = localFormatter.string(from: date)
        XCTAssertTrue(lines[0].hasPrefix(expectedPrefix), "Expected line to start with local time \(expectedPrefix), got \(lines[0])")
    }

    func testErrorLevelOnlyWritesErrors() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let logger = try makeLogger(directory: directory, settings: AppSettings(logLevel: .error))

        logger.info("info message")
        logger.warning("warning message")
        logger.error("error message")

        let lines = loggedLines(directory: directory)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("error message"))
    }
}
