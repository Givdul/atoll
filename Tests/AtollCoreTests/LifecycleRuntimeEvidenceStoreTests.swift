import XCTest
@testable import AtollCore

final class LifecycleRuntimeEvidenceStoreTests: XCTestCase {
    func testStoresOnlyProviderAndLatestLocalReceiptTime() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = LifecycleRuntimeEvidenceStore(homeDirectory: home)
        let earlier = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)

        XCTAssertTrue(store.record(provider: .codex, receivedAt: later))
        XCTAssertTrue(store.record(provider: .codex, receivedAt: earlier))
        XCTAssertEqual(store.lastValidEvent(for: .codex), later)
        XCTAssertNil(store.lastValidEvent(for: .claude))

        let file = home.appendingPathComponent(".atoll/lifecycle-runtime-evidence.json")
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["codex"])
        XCTAssertFalse(String(data: try Data(contentsOf: file), encoding: .utf8)?.contains("session") == true)
        XCTAssertEqual(try permissions(of: file), 0o600)
        XCTAssertEqual(try permissions(of: file.deletingLastPathComponent()), 0o700)

        let reloaded = LifecycleRuntimeEvidenceStore(homeDirectory: home)
        XCTAssertEqual(reloaded.lastValidEvent(for: .codex), later)
    }

    func testRejectsInternalPresentationHarness() {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = LifecycleRuntimeEvidenceStore(homeDirectory: home)

        XCTAssertFalse(store.record(provider: .atoll, receivedAt: Date()))
        XCTAssertNil(store.lastValidEvent(for: .atoll))
    }

    func testInvalidatesOnlyRequestedProvider() {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = LifecycleRuntimeEvidenceStore(homeDirectory: home)
        let date = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(store.record(provider: .codex, receivedAt: date))
        XCTAssertTrue(store.record(provider: .claude, receivedAt: date))

        XCTAssertTrue(store.invalidate(providers: [.codex, .atoll]))
        XCTAssertNil(store.lastValidEvent(for: .codex))
        XCTAssertEqual(store.lastValidEvent(for: .claude), date)
        XCTAssertNil(LifecycleRuntimeEvidenceStore(homeDirectory: home).lastValidEvent(for: .codex))
    }

    func testHardensExistingStorageOnLoadWithoutRewritingContents() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".atoll", isDirectory: true)
        let file = root.appendingPathComponent("lifecycle-runtime-evidence.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let contents = try JSONEncoder().encode(["codex": Date(timeIntervalSince1970: 100)])
        try contents.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        _ = LifecycleRuntimeEvidenceStore(homeDirectory: home)

        XCTAssertEqual(try permissions(of: root), 0o700)
        XCTAssertEqual(try permissions(of: file), 0o600)
        XCTAssertEqual(try Data(contentsOf: file), contents)
    }

    private func temporaryHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AtollRuntimeEvidenceTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
