import XCTest
@testable import AutoVolumeShared

final class CredentialStoreTests: XCTestCase {
    func testInMemoryCredentialStoreSavesReadsAndDeletesPassword() throws {
        let store = InMemoryCredentialStore()
        let id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        try store.savePassword("secret", for: id)
        XCTAssertEqual(try store.password(for: id), "secret")

        try store.deletePassword(for: id)
        XCTAssertNil(try store.password(for: id))
    }
}
