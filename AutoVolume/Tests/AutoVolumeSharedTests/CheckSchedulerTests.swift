import XCTest
@testable import AutoVolumeShared

final class CheckSchedulerTests: XCTestCase {
    func testVolumeWithoutPreviousCheckIsDue() {
        let id = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        var scheduler = CheckScheduler()

        XCTAssertTrue(scheduler.isDue(volumeID: id, interval: 300, now: Date(timeIntervalSince1970: 1_000)))
    }

    func testVolumeIsNotDueBeforeIntervalElapsed() {
        let id = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        var scheduler = CheckScheduler()
        scheduler.markChecked(volumeID: id, at: Date(timeIntervalSince1970: 1_000))

        XCTAssertFalse(scheduler.isDue(volumeID: id, interval: 300, now: Date(timeIntervalSince1970: 1_299)))
    }

    func testVolumeIsDueWhenIntervalElapsed() {
        let id = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        var scheduler = CheckScheduler()
        scheduler.markChecked(volumeID: id, at: Date(timeIntervalSince1970: 1_000))

        XCTAssertTrue(scheduler.isDue(volumeID: id, interval: 300, now: Date(timeIntervalSince1970: 1_300)))
    }
}
