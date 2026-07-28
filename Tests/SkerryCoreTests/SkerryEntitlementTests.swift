import Darwin
import Foundation
import Security
import XCTest
@testable import SkerryCore

final class SkerryEntitlementTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000_000_000)
    private var keychainServices: [String] = []

    override func tearDown() {
        for service in keychainServices {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ] as CFDictionary)
        }
        keychainServices = []
        MockLicenseURLProtocol.mode = .valid
        MockLicenseURLProtocol.requestedEndpoints = []
        super.tearDown()
    }

    func testBuildStorageModeChoosesTrialFileForAdHocAndKeychainForDeveloperID() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkerryEntitlementMode-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let adHocStore = SkerryEntitlementStore.configured(
            storageMode: SkerryEntitlementStore.trialFileStorageMode,
            homeDirectory: home
        )
        XCTAssertTrue(adHocStore.isTrialFileBacked)
        let trial = try await adHocStore.loadOrCreateTrialBounded(at: start)
        XCTAssertEqual(trial.trialStartedAt, start)

        let developerIDStore = SkerryEntitlementStore.configured(
            storageMode: SkerryEntitlementStore.keychainStorageMode,
            homeDirectory: home
        )
        XCTAssertFalse(developerIDStore.isTrialFileBacked)
    }

    func testTrialFilePersistsImmutableStartWithPrivatePermissions() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkerryTrialFile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SkerryEntitlementStore.configured(
            storageMode: SkerryEntitlementStore.trialFileStorageMode,
            homeDirectory: home
        )

        var record = try await store.loadOrCreateTrialBounded(at: start)
        record.observe(start.addingTimeInterval(60 * 60))
        try await store.saveBounded(record)

        let replacementStore = SkerryEntitlementStore.configured(
            storageMode: SkerryEntitlementStore.trialFileStorageMode,
            homeDirectory: home
        )
        let persisted = try await replacementStore.loadOrCreateTrialBounded(
            at: start.addingTimeInterval(2 * 60 * 60)
        )
        XCTAssertEqual(persisted.trialStartedAt, start)
        XCTAssertEqual(persisted.lastSeenAt, start.addingTimeInterval(60 * 60))

        let directory = home.appendingPathComponent(".skerry", isDirectory: true)
        let file = directory.appendingPathComponent(SkerryEntitlementStore.trialFileName)
        XCTAssertEqual(try permissions(at: directory), 0o700)
        XCTAssertEqual(try permissions(at: file), 0o600)
    }

    func testTrialFileRefusesLicenseMaterialOnSaveAndLoad() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkerryTrialOnly-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home
            .appendingPathComponent(".skerry", isDirectory: true)
            .appendingPathComponent(SkerryEntitlementStore.trialFileName)
        let store = SkerryEntitlementStore.configured(
            storageMode: SkerryEntitlementStore.trialFileStorageMode,
            homeDirectory: home
        )
        let licensed = SkerryEntitlementRecord(
            trialStartedAt: start,
            lastSeenAt: start,
            license: SkerryStoredLicense(
                key: "must-not-persist",
                instanceID: "instance-1",
                validatedAt: start
            )
        )

        do {
            try await store.saveBounded(licensed)
            XCTFail("Trial-only storage saved license material")
        } catch let error as SkerryEntitlementStore.Error {
            XCTAssertEqual(error, .licenseNotAllowed)
        }

        try PrivateStorage.writeAtomically(
            JSONEncoder().encode(licensed),
            to: file,
            hardenDirectory: true
        )
        do {
            _ = try await store.loadBounded()
            XCTFail("Trial-only storage loaded license material")
        } catch let error as SkerryEntitlementStore.Error {
            XCTAssertEqual(error, .licenseNotAllowed)
        }
    }

    func testAdHocBuildRejectsEveryLemonConfigurationBeforeCompilation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = root.appendingPathComponent("Scripts/build-release.sh")
        let lemonVariables = [
            "SKERRY_PURCHASE_URL",
            "LEMON_SQUEEZY_STORE_ID",
            "LEMON_SQUEEZY_PRODUCT_ID",
            "LEMON_SQUEEZY_VARIANT_ID"
        ]

        for variable in lemonVariables {
            var environment = ProcessInfo.processInfo.environment
            lemonVariables.forEach { environment.removeValue(forKey: $0) }
            environment["SIGN_IDENTITY"] = "-"
            environment[variable] = "configured"

            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path]
            process.environment = environment
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()

            let message = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTAssertNotEqual(process.terminationStatus, 0, variable)
            XCTAssertTrue(
                message.contains("Ad-hoc builds cannot contain Lemon Squeezy configuration"),
                "\(variable): \(message)"
            )
            XCTAssertFalse(message.contains("Building for production"), variable)
        }
    }

    @MainActor
    func testTrialStartBoundaryRelaunchReinstallUpdateAndClockRollback() async throws {
        let store = makeStore()
        let firstLaunch = SkerryEntitlementController(store: store, configuration: nil)
        let firstStatus = await firstLaunch.start(at: start)
        XCTAssertEqual(
            firstStatus,
            .activeTrial(
                expiresAt: start.addingTimeInterval(72 * 60 * 60),
                currentTime: start
            )
        )

        let relaunch = SkerryEntitlementController(store: store, configuration: nil)
        let relaunchStatus = await relaunch.start(at: start.addingTimeInterval(60 * 60))
        XCTAssertEqual(
            relaunchStatus,
            .activeTrial(
                expiresAt: start.addingTimeInterval(72 * 60 * 60),
                currentTime: start.addingTimeInterval(60 * 60)
            )
        )

        let reinstalledOrUpdated = SkerryEntitlementController(store: store, configuration: nil)
        let reinstalledStatus = await reinstalledOrUpdated.start(
            at: start.addingTimeInterval(2 * 60 * 60)
        )
        XCTAssertEqual(
            reinstalledStatus,
            .activeTrial(
                expiresAt: start.addingTimeInterval(72 * 60 * 60),
                currentTime: start.addingTimeInterval(2 * 60 * 60)
            )
        )

        await reinstalledOrUpdated.persistObservation(
            at: start.addingTimeInterval(71 * 60 * 60)
        )
        let rolledBackBeforeExpiry = SkerryEntitlementController(
            store: store,
            configuration: nil
        )
        let rolledBackBeforeExpiryStatus = await rolledBackBeforeExpiry.start(
            at: start.addingTimeInterval(3 * 60 * 60)
        )
        XCTAssertEqual(rolledBackBeforeExpiryStatus, .expired)

        await rolledBackBeforeExpiry.persistObservation(
            at: start.addingTimeInterval(80 * 60 * 60)
        )
        let rolledBackClock = SkerryEntitlementController(store: store, configuration: nil)
        let rolledBackStatus = await rolledBackClock.start(
            at: start.addingTimeInterval(3 * 60 * 60)
        )
        XCTAssertEqual(
            rolledBackStatus,
            .expired
        )
    }

    @MainActor
    func testActivationSurvivesOfflineLaunchAndDefinitiveRevocation() async throws {
        let store = makeStore()
        let configuration = try XCTUnwrap(configuration())
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockLicenseURLProtocol.self]
        let client = LemonSqueezyLicenseClient(session: URLSession(configuration: sessionConfiguration))
        let controller = SkerryEntitlementController(
            store: store,
            client: client,
            configuration: configuration
        )
        _ = await controller.start(at: start)

        MockLicenseURLProtocol.mode = .valid
        let activated = try await controller.activate(key: "skerry-test-license", at: start)
        XCTAssertEqual(activated, .licensed(validatedAt: start))
        XCTAssertEqual(
            MockLicenseURLProtocol.lastForm["instance_name"],
            "Skerry on Mac"
        )

        let afterUpdate = SkerryEntitlementController(
            store: store,
            client: client,
            configuration: configuration
        )
        let afterUpdateStatus = await afterUpdate.start(
            at: start.addingTimeInterval(25 * 60 * 60)
        )
        XCTAssertEqual(
            afterUpdateStatus,
            .licensed(validatedAt: start)
        )

        MockLicenseURLProtocol.mode = .offline
        let offline = await afterUpdate.validate(at: start.addingTimeInterval(25 * 60 * 60))
        guard case .recoverableError(_, let allowsUse) = offline else {
            return XCTFail("Expected a recoverable offline validation error")
        }
        XCTAssertTrue(allowsUse)

        let offlineRelaunch = SkerryEntitlementController(
            store: store,
            client: client,
            configuration: configuration
        )
        let offlineRelaunchStatus = await offlineRelaunch.start(
            at: start.addingTimeInterval(73 * 60 * 60)
        )
        XCTAssertEqual(
            offlineRelaunchStatus,
            .licensed(validatedAt: start)
        )

        MockLicenseURLProtocol.mode = .revoked
        let revoked = await offlineRelaunch.validate(at: start.addingTimeInterval(73 * 60 * 60))
        guard case .recoverableError(_, let revokedAllowsUse) = revoked else {
            return XCTFail("Expected revoked guidance")
        }
        XCTAssertFalse(revokedAllowsUse)

        let revokedRelaunch = SkerryEntitlementController(
            store: store,
            client: client,
            configuration: configuration
        )
        let revokedRelaunchStatus = await revokedRelaunch.start(
            at: start.addingTimeInterval(73 * 60 * 60)
        )
        XCTAssertEqual(
            revokedRelaunchStatus,
            .expired
        )
    }

    func testWrongProductMalformedAndCheckoutConfigurationFailSafely() async throws {
        XCTAssertNil(LemonSqueezyConfiguration(
            purchaseURL: try XCTUnwrap(URL(string: "http://skerry.lemonsqueezy.com/checkout/buy/30")),
            storeID: 10,
            productID: 20,
            variantID: 30
        ))
        XCTAssertNil(LemonSqueezyConfiguration(
            purchaseURL: try XCTUnwrap(URL(string: "https://example.com/checkout/buy/30")),
            storeID: 10,
            productID: 20,
            variantID: 30
        ))

        let configuration = try XCTUnwrap(configuration())
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockLicenseURLProtocol.self]
        let client = LemonSqueezyLicenseClient(session: URLSession(configuration: sessionConfiguration))

        MockLicenseURLProtocol.mode = .wrongProduct
        do {
            _ = try await client.activate(
                key: "skerry-test-license",
                configuration: configuration,
                now: start
            )
            XCTFail("Wrong-product activation succeeded")
        } catch let error as LemonSqueezyLicenseClient.Error {
            XCTAssertEqual(error, .wrongProduct)
            XCTAssertTrue(error.isDefinitive)
        }

        MockLicenseURLProtocol.mode = .malformed
        do {
            _ = try await client.validate(
                SkerryStoredLicense(
                    key: "skerry-test-license",
                    instanceID: "instance-1",
                    validatedAt: start
                ),
                configuration: configuration,
                now: start
            )
            XCTFail("Malformed validation succeeded")
        } catch let error as LemonSqueezyLicenseClient.Error {
            XCTAssertEqual(error, .malformedResponse)
            XCTAssertFalse(error.isDefinitive)
        }
    }

    @MainActor
    func testActivationReusesInstanceAndRefusesDifferentKeyWithoutRemoteCall() async throws {
        let configuration = try XCTUnwrap(configuration())
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockLicenseURLProtocol.self]
        let controller = SkerryEntitlementController(
            store: makeStore(),
            client: LemonSqueezyLicenseClient(
                session: URLSession(configuration: sessionConfiguration)
            ),
            configuration: configuration
        )
        _ = await controller.start(at: start)

        _ = try await controller.activate(key: "skerry-first-license", at: start)
        _ = try await controller.activate(
            key: "skerry-first-license",
            at: start.addingTimeInterval(1)
        )
        XCTAssertEqual(MockLicenseURLProtocol.requestedEndpoints, ["activate", "validate"])
        XCTAssertEqual(MockLicenseURLProtocol.lastForm["instance_id"], "instance-1")

        MockLicenseURLProtocol.requestedEndpoints = []
        do {
            _ = try await controller.activate(
                key: "skerry-second-license",
                at: start.addingTimeInterval(2)
            )
            XCTFail("Different key replaced an active license")
        } catch SkerryEntitlementController.ActivationError.differentKey {}
        XCTAssertTrue(MockLicenseURLProtocol.requestedEndpoints.isEmpty)

        MockLicenseURLProtocol.mode = .revoked
        do {
            _ = try await controller.activate(
                key: "skerry-first-license",
                at: start.addingTimeInterval(73 * 60 * 60)
            )
            XCTFail("Revoked same-key activation succeeded")
        } catch let error as LemonSqueezyLicenseClient.Error {
            XCTAssertTrue(error.isDefinitive)
        }
        guard case .recoverableError(_, let allowsUse) = controller.observe(
            start.addingTimeInterval(73 * 60 * 60)
        ) else {
            return XCTFail("Expected revoked same-key guidance")
        }
        XCTAssertFalse(allowsUse)
    }

    @MainActor
    func testActivationCompensatesRemoteInstanceWhenLocalSaveFails() async throws {
        let service = "com.givdul.skerry.tests.\(UUID().uuidString)"
        keychainServices.append(service)
        let store = SkerryEntitlementStore(
            service: service,
            saveOverride: { _ in
                throw SkerryEntitlementStore.Error.keychain(errSecNotAvailable)
            }
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockLicenseURLProtocol.self]
        let controller = SkerryEntitlementController(
            store: store,
            client: LemonSqueezyLicenseClient(
                session: URLSession(configuration: sessionConfiguration)
            ),
            configuration: try XCTUnwrap(configuration())
        )
        _ = await controller.start(at: start)
        MockLicenseURLProtocol.requestedEndpoints = []

        do {
            _ = try await controller.activate(key: "skerry-test-license", at: start)
            XCTFail("Activation survived a failed local save")
        } catch let error as SkerryEntitlementStore.Error {
            XCTAssertEqual(error, .keychain(errSecNotAvailable))
        }

        XCTAssertEqual(MockLicenseURLProtocol.requestedEndpoints, ["activate", "deactivate"])
        let persistedRecord = try await store.loadBounded()
        XCTAssertNil(persistedRecord?.license)
    }

    @MainActor
    func testValidationMutationGateRejectsOverlappingActivation() async throws {
        let configuration = try XCTUnwrap(configuration())
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockLicenseURLProtocol.self]
        let controller = SkerryEntitlementController(
            store: makeStore(),
            client: LemonSqueezyLicenseClient(
                session: URLSession(configuration: sessionConfiguration)
            ),
            configuration: configuration
        )
        _ = await controller.start(at: start)
        _ = try await controller.activate(key: "skerry-test-license", at: start)

        MockLicenseURLProtocol.mode = .delayedValid
        MockLicenseURLProtocol.requestedEndpoints = []
        let validation = Task { @MainActor in
            await controller.validate(at: start.addingTimeInterval(25 * 60 * 60))
        }
        for _ in 0..<100 where MockLicenseURLProtocol.requestedEndpoints.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(MockLicenseURLProtocol.requestedEndpoints, ["validate"])

        do {
            _ = try await controller.activate(
                key: "skerry-test-license",
                at: start.addingTimeInterval(25 * 60 * 60)
            )
            XCTFail("Activation overlapped automatic validation")
        } catch SkerryEntitlementController.ActivationError.busy {}

        let validationStatus = await validation.value
        XCTAssertEqual(
            validationStatus,
            .licensed(validatedAt: start.addingTimeInterval(25 * 60 * 60))
        )
        XCTAssertEqual(MockLicenseURLProtocol.requestedEndpoints, ["validate"])
    }

    @MainActor
    func testThrottlingAndTemporaryHTTPResponsesKeepValidatedAccess() async throws {
        let configuration = try XCTUnwrap(configuration())
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockLicenseURLProtocol.self]
        let store = makeStore()
        let controller = SkerryEntitlementController(
            store: store,
            client: LemonSqueezyLicenseClient(
                session: URLSession(configuration: sessionConfiguration)
            ),
            configuration: configuration
        )
        _ = await controller.start(at: start)
        _ = try await controller.activate(key: "skerry-test-license", at: start)

        for mode in [MockLicenseURLProtocol.Mode.throttled, .serverError] {
            MockLicenseURLProtocol.mode = mode
            guard case .recoverableError(_, let allowsUse) = await controller.validate(
                at: start.addingTimeInterval(25 * 60 * 60)
            ) else {
                return XCTFail("Expected temporary validation guidance")
            }
            XCTAssertTrue(allowsUse)
        }

        let relaunched = SkerryEntitlementController(
            store: store,
            client: LemonSqueezyLicenseClient(
                session: URLSession(configuration: sessionConfiguration)
            ),
            configuration: configuration
        )
        let relaunchedStatus = await relaunched.start(
            at: start.addingTimeInterval(73 * 60 * 60)
        )
        XCTAssertEqual(relaunchedStatus, .licensed(validatedAt: start))
    }

    @MainActor
    func testMalformedProtectedRecordRecoversThroughActivationWithoutResettingTrial() async throws {
        let service = "com.givdul.skerry.tests.\(UUID().uuidString)"
        keychainServices.append(service)
        let malformed = Data("{".utf8)
        XCTAssertEqual(SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: SkerryEntitlementStore.defaultAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: malformed
        ] as CFDictionary, nil), errSecSuccess)

        let store = SkerryEntitlementStore(service: service)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockLicenseURLProtocol.self]
        let client = LemonSqueezyLicenseClient(
            session: URLSession(configuration: sessionConfiguration)
        )
        let configuration = try XCTUnwrap(configuration())
        let controller = SkerryEntitlementController(
            store: store,
            client: client,
            configuration: configuration
        )
        guard case .recoverableError(_, let allowsUse) = await controller.start(at: start) else {
            return XCTFail("Expected malformed-record recovery guidance")
        }
        XCTAssertFalse(allowsUse)

        var stored: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: SkerryEntitlementStore.defaultAccount,
            kSecReturnData as String: true
        ] as CFDictionary, &stored), errSecSuccess)
        XCTAssertEqual(stored as? Data, malformed)

        let activated = try await controller.activate(
            key: "skerry-test-license",
            at: start
        )
        XCTAssertEqual(activated, .licensed(validatedAt: start))
        MockLicenseURLProtocol.mode = .revoked
        _ = await controller.validate(at: start.addingTimeInterval(73 * 60 * 60))

        let relaunched = SkerryEntitlementController(
            store: store,
            client: client,
            configuration: configuration
        )
        let relaunchedStatus = await relaunched.start(
            at: start.addingTimeInterval(73 * 60 * 60)
        )
        XCTAssertEqual(relaunchedStatus, .expired)
    }

    func testConcurrentFirstLaunchKeepsOneImmutableTrialStart() async throws {
        let service = "com.givdul.skerry.tests.\(UUID().uuidString)"
        keychainServices.append(service)
        let firstStore = SkerryEntitlementStore(service: service)
        let secondStore = SkerryEntitlementStore(service: service)
        let trialStart = start

        async let first = firstStore.loadOrCreateTrialBounded(at: trialStart)
        async let second = secondStore.loadOrCreateTrialBounded(
            at: trialStart.addingTimeInterval(60)
        )
        let records = try await [first, second]

        XCTAssertEqual(Set(records.map(\.trialStartedAt)).count, 1)
        let persisted = try await firstStore.loadBounded()
        XCTAssertEqual(persisted?.trialStartedAt, records.first?.trialStartedAt)
    }

    func testLifecycleQueueDropsOldestBeyondBound() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkerryBoundedQueue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let queue = LifecycleEventQueue(homeDirectory: home)

        XCTAssertNotNil(queue.enqueue(
            LifecycleEvent(sessionID: "000", harness: .codex, kind: .started)
        ))
        Thread.sleep(forTimeInterval: 0.01)
        for index in 1...LifecycleEventQueue.maximumPendingEvents {
            XCTAssertNotNil(queue.enqueue(
                LifecycleEvent(
                    sessionID: String(format: "%03d", index),
                    harness: .codex,
                    kind: .started
                )
            ))
        }

        let identifiers = queue.pendingEvents().map(\.event.sessionID)
        XCTAssertEqual(identifiers.count, LifecycleEventQueue.maximumPendingEvents)
        XCTAssertFalse(identifiers.contains("000"))
        XCTAssertTrue(identifiers.contains(
            String(format: "%03d", LifecycleEventQueue.maximumPendingEvents)
        ))
    }

    func testQueueOverflowFailureRemovesNewEventAndReturnsNoReceipt() throws {
        let home = try fullQueueHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let queue = LifecycleEventQueue(homeDirectory: home)
        let lock = home.appendingPathComponent(".skerry/.lifecycle-events.writer.lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)

        XCTAssertNil(queue.enqueue(
            LifecycleEvent(sessionID: "rejected", harness: .codex, kind: .started)
        ))
        XCTAssertEqual(queue.pendingEvents().count, LifecycleEventQueue.maximumPendingEvents)
        XCTAssertFalse(queue.pendingEvents().contains { $0.event.sessionID == "rejected" })
    }

    func testHeldOverflowLockReturnsBelowHookDeadlineWithoutGrowingQueue() throws {
        let home = try fullQueueHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let lock = home.appendingPathComponent(".skerry/.lifecycle-events.writer.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        defer { flock(descriptor, LOCK_UN) }

        let queue = LifecycleEventQueue(homeDirectory: home)
        let startedAt = ContinuousClock.now
        XCTAssertNil(queue.enqueue(
            LifecycleEvent(sessionID: "timed-out", harness: .codex, kind: .started)
        ))
        XCTAssertLessThan(startedAt.duration(to: .now), .milliseconds(900))
        XCTAssertEqual(queue.pendingEvents().count, LifecycleEventQueue.maximumPendingEvents)
    }

    private func makeStore() -> SkerryEntitlementStore {
        let service = "com.givdul.skerry.tests.\(UUID().uuidString)"
        keychainServices.append(service)
        return SkerryEntitlementStore(service: service)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    private func fullQueueHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkerryFullQueue-\(UUID().uuidString)", isDirectory: true)
        let queue = LifecycleEventQueue(homeDirectory: home)
        for index in 0..<LifecycleEventQueue.maximumPendingEvents {
            XCTAssertNotNil(queue.enqueue(
                LifecycleEvent(
                    sessionID: "\(index)",
                    harness: .codex,
                    kind: .started
                )
            ))
        }
        return home
    }

    private func configuration() -> LemonSqueezyConfiguration? {
        LemonSqueezyConfiguration(
            purchaseURL: URL(string: "https://skerry.lemonsqueezy.com/checkout/buy/30")!,
            storeID: 10,
            productID: 20,
            variantID: 30
        )
    }
}

private final class MockLicenseURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode {
        case valid
        case offline
        case revoked
        case wrongProduct
        case malformed
        case throttled
        case serverError
        case delayedValid
    }

    nonisolated(unsafe) static var mode = Mode.valid
    nonisolated(unsafe) static var lastForm: [String: String] = [:]
    nonisolated(unsafe) static var requestedEndpoints: [String] = []

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.lemonsqueezy.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lastForm = Self.form(from: Self.bodyData(from: request))
        Self.requestedEndpoints.append(request.url?.lastPathComponent ?? "")
        if Self.mode == .delayedValid {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if Self.mode == .offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        let status: Int
        let data: Data
        switch Self.mode {
        case .valid, .delayedValid:
            status = 200
            let endpoint = request.url?.lastPathComponent
            let resultField = switch endpoint {
            case "activate": #""activated":true"#
            case "deactivate": #""deactivated":true"#
            default: #""valid":true"#
            }
            data = Self.response(
                resultField: resultField,
                productID: 20,
                licenseStatus: endpoint == "deactivate" ? "inactive" : "active",
                instanceID: endpoint == "deactivate" ? nil : "instance-1"
            )
        case .revoked:
            status = 404
            data = Self.response(
                resultField: #""valid":false"#,
                productID: 20,
                licenseStatus: "disabled",
                error: "This license key has been disabled."
            )
        case .wrongProduct:
            status = 200
            data = Self.response(
                resultField: #""activated":true"#,
                productID: 999,
                licenseStatus: "active"
            )
        case .malformed:
            status = 200
            data = Data(#"{"valid":true}"#.utf8)
        case .throttled:
            status = 429
            data = Data(#"{"error":"Too many requests."}"#.utf8)
        case .serverError:
            status = 503
            data = Data("temporarily unavailable".utf8)
        case .offline:
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func response(
        resultField: String,
        productID: Int,
        licenseStatus: String,
        error: String? = nil,
        instanceID: String? = "instance-1"
    ) -> Data {
        Data("""
        {
          \(resultField),
          "error": \(error.map { "\"\($0)\"" } ?? "null"),
          "license_key": {
            "status": "\(licenseStatus)",
            "expires_at": null
          },
          "instance": \(instanceID.map { #"{"id":"\#($0)"}"# } ?? "null"),
          "meta": {
            "store_id": 10,
            "product_id": \(productID),
            "variant_id": 30
          }
        }
        """.utf8)
    }

    private static func form(from data: Data?) -> [String: String] {
        guard let data,
              let text = String(data: data, encoding: .utf8) else {
            return [:]
        }
        var components = URLComponents()
        components.percentEncodedQuery = text
        return Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
                guard let value = $0.value else { return nil }
                return ($0.name, value)
            }
        )
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
