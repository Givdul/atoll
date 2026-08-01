import Darwin
import Foundation
import Security
import XCTest
@testable import TopsideCore

private let testOrganizationID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let testBenefitID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

final class TopsideEntitlementTests: XCTestCase {
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
        MockLicenseURLProtocol.requests = []
        super.tearDown()
    }

    func testBuildStorageModeChoosesTrialFileForAdHocAndKeychainForDeveloperID() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("TopsideEntitlementMode-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let adHocStore = TopsideEntitlementStore.configured(
            storageMode: TopsideEntitlementStore.trialFileStorageMode,
            homeDirectory: home
        )
        XCTAssertTrue(adHocStore.isTrialFileBacked)
        let trial = try await adHocStore.loadOrCreateTrialBounded(at: start)
        XCTAssertEqual(trial.trialStartedAt, start)

        let developerIDStore = TopsideEntitlementStore.configured(
            storageMode: TopsideEntitlementStore.keychainStorageMode,
            homeDirectory: home
        )
        XCTAssertFalse(developerIDStore.isTrialFileBacked)
    }

    func testTrialFilePersistsImmutableStartWithPrivatePermissions() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("TopsideTrialFile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TopsideEntitlementStore.configured(
            storageMode: TopsideEntitlementStore.trialFileStorageMode,
            homeDirectory: home
        )

        var record = try await store.loadOrCreateTrialBounded(at: start)
        record.observe(start.addingTimeInterval(60 * 60))
        try await store.saveBounded(record)

        let replacementStore = TopsideEntitlementStore.configured(
            storageMode: TopsideEntitlementStore.trialFileStorageMode,
            homeDirectory: home
        )
        let persisted = try await replacementStore.loadOrCreateTrialBounded(
            at: start.addingTimeInterval(2 * 60 * 60)
        )
        XCTAssertEqual(persisted.trialStartedAt, start)
        XCTAssertEqual(persisted.lastSeenAt, start.addingTimeInterval(60 * 60))

        let directory = home.appendingPathComponent(".topside", isDirectory: true)
        let file = directory.appendingPathComponent(TopsideEntitlementStore.trialFileName)
        XCTAssertEqual(try permissions(at: directory), 0o700)
        XCTAssertEqual(try permissions(at: file), 0o600)
    }

    func testTrialFileRefusesLicenseMaterialOnSaveAndLoad() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("TopsideTrialOnly-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home
            .appendingPathComponent(".topside", isDirectory: true)
            .appendingPathComponent(TopsideEntitlementStore.trialFileName)
        let store = TopsideEntitlementStore.configured(
            storageMode: TopsideEntitlementStore.trialFileStorageMode,
            homeDirectory: home
        )
        let licensed = TopsideEntitlementRecord(
            trialStartedAt: start,
            lastSeenAt: start,
            license: TopsideStoredLicense(
                key: "must-not-persist",
                validatedAt: start
            )
        )

        do {
            try await store.saveBounded(licensed)
            XCTFail("Trial-only storage saved license material")
        } catch let error as TopsideEntitlementStore.Error {
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
        } catch let error as TopsideEntitlementStore.Error {
            XCTAssertEqual(error, .licenseNotAllowed)
        }
    }

    func testLegacyLicenseRecordDecodesWithoutValidationAttempt() throws {
        let data = Data("""
        {
          "trialStartedAt": 0,
          "lastSeenAt": 0,
          "license": {
            "key": "legacy-license",
            "validatedAt": 0
          }
        }
        """.utf8)

        let record = try JSONDecoder().decode(TopsideEntitlementRecord.self, from: data)

        XCTAssertNil(record.license?.lastValidationAttemptAt)
    }

    func testAdHocBuildRejectsEveryPolarConfigurationBeforeCompilation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = root.appendingPathComponent("Scripts/build-release.sh")
        let polarVariables = [
            "TOPSIDE_PURCHASE_URL",
            "POLAR_ORGANIZATION_ID",
            "POLAR_BENEFIT_ID"
        ]

        for variable in polarVariables {
            var environment = ProcessInfo.processInfo.environment
            polarVariables.forEach { environment.removeValue(forKey: $0) }
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
                message.contains("Ad-hoc builds cannot contain Polar configuration"),
                "\(variable): \(message)"
            )
            XCTAssertFalse(message.contains("Building for production"), variable)
        }
    }

    func testPolarConfigurationAcceptsOnlyExactCheckoutForms() throws {
        let production = try XCTUnwrap(PolarConfiguration(
            purchaseURL: XCTUnwrap(URL(string: "https://buy.polar.sh/polar_cl_abc123")),
            organizationID: testOrganizationID,
            benefitID: testBenefitID
        ))
        XCTAssertEqual(production.apiBaseURL.absoluteString, "https://api.polar.sh")

        let sandbox = try XCTUnwrap(PolarConfiguration(
            purchaseURL: XCTUnwrap(URL(
                string: "https://sandbox-api.polar.sh/v1/checkout-links/polar_cl_abc123/redirect"
            )),
            organizationID: testOrganizationID,
            benefitID: testBenefitID
        ))
        XCTAssertEqual(sandbox.apiBaseURL.absoluteString, "https://sandbox-api.polar.sh")

        for value in [
            "http://buy.polar.sh/polar_cl_abc123",
            "https://buy.polar.sh/polar_cl_abc123?customer_email=private@example.com",
            "https://buy.polar.sh/checkout/polar_cl_abc123",
            "https://example.com/polar_cl_abc123",
            "https://sandbox-api.polar.sh/v1/checkout-links/polar_cl_abc123"
        ] {
            XCTAssertNil(PolarConfiguration(
                purchaseURL: try XCTUnwrap(URL(string: value)),
                organizationID: testOrganizationID,
                benefitID: testBenefitID
            ), value)
        }
    }

    @MainActor
    func testTrialStartBoundaryRelaunchReinstallUpdateAndClockRollback() async throws {
        let store = makeStore()
        let firstLaunch = TopsideEntitlementController(store: store, configuration: nil)
        let firstStatus = await firstLaunch.start(at: start)
        XCTAssertEqual(
            firstStatus,
            .activeTrial(
                expiresAt: start.addingTimeInterval(72 * 60 * 60),
                currentTime: start
            )
        )

        let relaunch = TopsideEntitlementController(store: store, configuration: nil)
        let relaunchStatus = await relaunch.start(at: start.addingTimeInterval(60 * 60))
        XCTAssertEqual(
            relaunchStatus,
            .activeTrial(
                expiresAt: start.addingTimeInterval(72 * 60 * 60),
                currentTime: start.addingTimeInterval(60 * 60)
            )
        )

        let reinstalledOrUpdated = TopsideEntitlementController(store: store, configuration: nil)
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
        let rolledBackBeforeExpiry = TopsideEntitlementController(
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
        let rolledBackClock = TopsideEntitlementController(store: store, configuration: nil)
        let rolledBackStatus = await rolledBackClock.start(
            at: start.addingTimeInterval(3 * 60 * 60)
        )
        XCTAssertEqual(
            rolledBackStatus,
            .expired
        )
    }

    @MainActor
    func testLicenseEntrySurvivesOfflineLaunchAndDefinitiveRevocation() async throws {
        let store = makeStore()
        let configuration = try XCTUnwrap(configuration())
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockLicenseURLProtocol.self]
        let client = PolarLicenseClient(session: URLSession(configuration: sessionConfiguration))
        let controller = TopsideEntitlementController(
            store: store,
            client: client,
            configuration: configuration
        )
        _ = await controller.start(at: start)

        MockLicenseURLProtocol.mode = .valid
        let licensed = try await controller.enter(key: "topside-test-license", at: start)
        XCTAssertEqual(licensed, .licensed(validatedAt: start))
        let initialRequest = try XCTUnwrap(MockLicenseURLProtocol.requests.last)
        XCTAssertEqual(initialRequest.path, "/v1/customer-portal/license-keys/validate")
        XCTAssertEqual(initialRequest.contentType, "application/json")
        XCTAssertNil(initialRequest.authorization)
        XCTAssertEqual(initialRequest.json, [
            "key": "topside-test-license",
            "organization_id": testOrganizationID.uuidString.lowercased(),
            "benefit_id": testBenefitID.uuidString.lowercased()
        ])

        let afterUpdate = TopsideEntitlementController(
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

        let offlineRelaunch = TopsideEntitlementController(
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

        let revokedRelaunch = TopsideEntitlementController(
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

    func testWrongScopeKeyAndPerpetualTermsAreDefinitive() async throws {
        let configuration = try XCTUnwrap(configuration())
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockLicenseURLProtocol.self]
        let client = PolarLicenseClient(session: URLSession(configuration: sessionConfiguration))

        for mode in [
            MockLicenseURLProtocol.Mode.wrongOrganization,
            .wrongBenefit,
            .wrongKey,
            .expired,
            .activationLimited,
            .usageLimited,
            .disabled,
            .revoked,
            .notFound
        ] {
            MockLicenseURLProtocol.mode = mode
            do {
                _ = try await client.validate(
                    key: "topside-test-license",
                    configuration: configuration,
                    now: start
                )
                XCTFail("\(mode) validation succeeded")
            } catch let error as PolarLicenseClient.Error {
                XCTAssertTrue(error.isDefinitive, "\(mode)")
            }
        }
    }

    func testMalformedResponseIsTemporary() async throws {
        let configuration = try XCTUnwrap(configuration())
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockLicenseURLProtocol.self]
        let client = PolarLicenseClient(session: URLSession(configuration: sessionConfiguration))
        MockLicenseURLProtocol.mode = .malformed
        do {
            _ = try await client.validate(
                key: "topside-test-license",
                configuration: configuration,
                now: start
            )
            XCTFail("Malformed validation succeeded")
        } catch let error as PolarLicenseClient.Error {
            XCTAssertEqual(error, .malformedResponse)
            XCTAssertFalse(error.isDefinitive)
        }
    }

    @MainActor
    func testLicenseEntryRevalidatesSameKeyAndRefusesDifferentKeyWithoutRemoteCall() async throws {
        let configuration = try XCTUnwrap(configuration())
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockLicenseURLProtocol.self]
        let controller = TopsideEntitlementController(
            store: makeStore(),
            client: PolarLicenseClient(
                session: URLSession(configuration: sessionConfiguration)
            ),
            configuration: configuration
        )
        _ = await controller.start(at: start)

        _ = try await controller.enter(key: "topside-first-license", at: start)
        _ = try await controller.enter(
            key: "topside-first-license",
            at: start.addingTimeInterval(1)
        )
        XCTAssertEqual(MockLicenseURLProtocol.requests.count, 2)
        XCTAssertTrue(MockLicenseURLProtocol.requests.allSatisfy {
            $0.path == "/v1/customer-portal/license-keys/validate"
        })

        MockLicenseURLProtocol.requests = []
        do {
            _ = try await controller.enter(
                key: "topside-second-license",
                at: start.addingTimeInterval(2)
            )
            XCTFail("Different key replaced an active license")
        } catch TopsideEntitlementController.LicenseError.differentKey {}
        XCTAssertTrue(MockLicenseURLProtocol.requests.isEmpty)

        MockLicenseURLProtocol.mode = .revoked
        do {
            _ = try await controller.enter(
                key: "topside-first-license",
                at: start.addingTimeInterval(73 * 60 * 60)
            )
            XCTFail("Revoked same-key entry succeeded")
        } catch let error as PolarLicenseClient.Error {
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
    func testLicenseEntryDoesNotPersistWhenLocalSaveFails() async throws {
        let service = "com.givdul.topside.tests.\(UUID().uuidString)"
        keychainServices.append(service)
        let store = TopsideEntitlementStore(
            service: service,
            saveOverride: { _ in
                throw TopsideEntitlementStore.Error.keychain(errSecNotAvailable)
            }
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockLicenseURLProtocol.self]
        let controller = TopsideEntitlementController(
            store: store,
            client: PolarLicenseClient(
                session: URLSession(configuration: sessionConfiguration)
            ),
            configuration: try XCTUnwrap(configuration())
        )
        _ = await controller.start(at: start)
        MockLicenseURLProtocol.requests = []

        do {
            _ = try await controller.enter(key: "topside-test-license", at: start)
            XCTFail("License entry survived a failed local save")
        } catch let error as TopsideEntitlementStore.Error {
            XCTAssertEqual(error, .keychain(errSecNotAvailable))
        }

        XCTAssertEqual(MockLicenseURLProtocol.requests.count, 1)
        let persistedRecord = try await store.loadBounded()
        XCTAssertNil(persistedRecord?.license)
    }

    @MainActor
    func testMaintenanceDeadlineUsesObservationScheduleBeforeTrialExpiry() async {
        let controller = TopsideEntitlementController(
            store: makeStore(),
            configuration: nil
        )
        _ = await controller.start(at: start)

        XCTAssertEqual(
            controller.nextMaintenanceDate(at: start),
            start.addingTimeInterval(60)
        )
    }

    @MainActor
    func testValidationMutationGateRejectsOverlappingLicenseEntry() async throws {
        let configuration = try XCTUnwrap(configuration())
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockLicenseURLProtocol.self]
        let controller = TopsideEntitlementController(
            store: makeStore(),
            client: PolarLicenseClient(
                session: URLSession(configuration: sessionConfiguration)
            ),
            configuration: configuration
        )
        _ = await controller.start(at: start)
        _ = try await controller.enter(key: "topside-test-license", at: start)

        MockLicenseURLProtocol.prepareDelayedResponse()
        let validation = Task { @MainActor in
            await controller.validate(at: start.addingTimeInterval(25 * 60 * 60))
        }
        await MockLicenseURLProtocol.waitForDelayedRequest()
        XCTAssertEqual(MockLicenseURLProtocol.requests.count, 1)

        do {
            _ = try await controller.enter(
                key: "topside-test-license",
                at: start.addingTimeInterval(25 * 60 * 60)
            )
            XCTFail("License entry overlapped automatic validation")
        } catch TopsideEntitlementController.LicenseError.busy {}

        MockLicenseURLProtocol.releaseDelayedResponse()
        let validationStatus = await validation.value
        XCTAssertEqual(
            validationStatus,
            .licensed(validatedAt: start.addingTimeInterval(25 * 60 * 60))
        )
        XCTAssertEqual(MockLicenseURLProtocol.requests.count, 1)
    }

    @MainActor
    func testThrottlingAndTemporaryHTTPResponsesKeepValidatedAccess() async throws {
        let configuration = try XCTUnwrap(configuration())
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockLicenseURLProtocol.self]
        let store = makeStore()
        let controller = TopsideEntitlementController(
            store: store,
            client: PolarLicenseClient(
                session: URLSession(configuration: sessionConfiguration)
            ),
            configuration: configuration
        )
        _ = await controller.start(at: start)
        _ = try await controller.enter(key: "topside-test-license", at: start)

        for mode in [
            MockLicenseURLProtocol.Mode.requestTimeout,
            .tooEarly,
            .unprocessable,
            .throttled,
            .serverError,
            .malformed
        ] {
            MockLicenseURLProtocol.mode = mode
            guard case .recoverableError(_, let allowsUse) = await controller.validate(
                at: start.addingTimeInterval(25 * 60 * 60)
            ) else {
                return XCTFail("Expected temporary validation guidance")
            }
            XCTAssertTrue(allowsUse)
        }

        let relaunched = TopsideEntitlementController(
            store: store,
            client: PolarLicenseClient(
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
    func testTemporaryFailureThrottlesRelaunchUntilNextDay() async throws {
        let service = "com.givdul.topside.tests.\(UUID().uuidString)"
        keychainServices.append(service)
        let configuration = try XCTUnwrap(configuration())
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockLicenseURLProtocol.self]
        let client = PolarLicenseClient(
            session: URLSession(configuration: sessionConfiguration)
        )
        let first = TopsideEntitlementController(
            store: TopsideEntitlementStore(service: service),
            client: client,
            configuration: configuration
        )
        _ = await first.start(at: start)
        _ = try await first.enter(key: "topside-test-license", at: start)

        let attempt = start.addingTimeInterval(25 * 60 * 60)
        MockLicenseURLProtocol.mode = .offline
        _ = await first.validate(at: attempt)
        MockLicenseURLProtocol.requests = []

        let relaunched = TopsideEntitlementController(
            store: TopsideEntitlementStore(service: service),
            client: client,
            configuration: configuration
        )
        _ = await relaunched.start(at: attempt.addingTimeInterval(23 * 60 * 60))
        if relaunched.shouldValidate(at: attempt.addingTimeInterval(23 * 60 * 60)) {
            _ = await relaunched.validate(at: attempt.addingTimeInterval(23 * 60 * 60))
        }
        XCTAssertTrue(MockLicenseURLProtocol.requests.isEmpty)

        MockLicenseURLProtocol.mode = .valid
        let nextDay = attempt.addingTimeInterval(TopsideEntitlementController.validationInterval)
        XCTAssertTrue(relaunched.shouldValidate(at: nextDay))
        _ = await relaunched.validate(at: nextDay)
        XCTAssertEqual(MockLicenseURLProtocol.requests.count, 1)
    }

    @MainActor
    func testMalformedProtectedRecordRecoversThroughLicenseEntryWithoutResettingTrial() async throws {
        let service = "com.givdul.topside.tests.\(UUID().uuidString)"
        keychainServices.append(service)
        let malformed = Data("{".utf8)
        XCTAssertEqual(SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: TopsideEntitlementStore.defaultAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: malformed
        ] as CFDictionary, nil), errSecSuccess)

        let store = TopsideEntitlementStore(service: service)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockLicenseURLProtocol.self]
        let client = PolarLicenseClient(
            session: URLSession(configuration: sessionConfiguration)
        )
        let configuration = try XCTUnwrap(configuration())
        let controller = TopsideEntitlementController(
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
            kSecAttrAccount as String: TopsideEntitlementStore.defaultAccount,
            kSecReturnData as String: true
        ] as CFDictionary, &stored), errSecSuccess)
        XCTAssertEqual(stored as? Data, malformed)

        let licensed = try await controller.enter(
            key: "topside-test-license",
            at: start
        )
        XCTAssertEqual(licensed, .licensed(validatedAt: start))
        MockLicenseURLProtocol.mode = .revoked
        _ = await controller.validate(at: start.addingTimeInterval(73 * 60 * 60))

        let relaunched = TopsideEntitlementController(
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
        let service = "com.givdul.topside.tests.\(UUID().uuidString)"
        keychainServices.append(service)
        let firstStore = TopsideEntitlementStore(service: service)
        let secondStore = TopsideEntitlementStore(service: service)
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
            .appendingPathComponent("TopsideBoundedQueue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let queue = LifecycleEventQueue(homeDirectory: home)

        XCTAssertNotNil(queue.enqueue(
            LifecycleEvent(sessionID: "000", harness: .codex, kind: .started)
        ))
        let queueDirectory = home.appendingPathComponent(".topside/lifecycle-events")
        let firstFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: queueDirectory,
                includingPropertiesForKeys: nil
            ).first
        )
        try FileManager.default.setAttributes(
            [.creationDate: Date.distantPast],
            ofItemAtPath: firstFile.path
        )
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
        let lock = home.appendingPathComponent(".topside/.lifecycle-events.writer.lock")
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
        let lock = home.appendingPathComponent(".topside/.lifecycle-events.writer.lock")
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

    private func makeStore() -> TopsideEntitlementStore {
        let service = "com.givdul.topside.tests.\(UUID().uuidString)"
        keychainServices.append(service)
        return TopsideEntitlementStore(service: service)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    private func fullQueueHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("TopsideFullQueue-\(UUID().uuidString)", isDirectory: true)
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

    private func configuration() -> PolarConfiguration? {
        PolarConfiguration(
            purchaseURL: URL(string: "https://buy.polar.sh/polar_cl_topside")!,
            organizationID: testOrganizationID,
            benefitID: testBenefitID
        )
    }
}

private final class MockLicenseURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode {
        case valid
        case offline
        case revoked
        case disabled
        case notFound
        case wrongOrganization
        case wrongBenefit
        case wrongKey
        case expired
        case activationLimited
        case usageLimited
        case malformed
        case requestTimeout
        case tooEarly
        case unprocessable
        case throttled
        case serverError
        case delayedValid
    }

    struct CapturedRequest {
        let path: String
        let json: [String: String]
        let authorization: String?
        let contentType: String?
    }

    nonisolated(unsafe) static var mode = Mode.valid
    nonisolated(unsafe) static var requests: [CapturedRequest] = []
    private static let delayedRequestLock = NSLock()
    nonisolated(unsafe) private static var delayedRequestArrived = false
    nonisolated(unsafe) private static var delayedRequestContinuation: CheckedContinuation<Void, Never>?
    nonisolated(unsafe) private static var delayedResponseRelease = DispatchSemaphore(value: 0)

    static func prepareDelayedResponse() {
        mode = .delayedValid
        requests = []
        delayedRequestLock.lock()
        delayedRequestArrived = false
        delayedRequestContinuation = nil
        delayedRequestLock.unlock()
        delayedResponseRelease = DispatchSemaphore(value: 0)
    }

    static func waitForDelayedRequest() async {
        await withCheckedContinuation { continuation in
            delayedRequestLock.lock()
            if delayedRequestArrived {
                delayedRequestLock.unlock()
                continuation.resume()
            } else {
                delayedRequestContinuation = continuation
                delayedRequestLock.unlock()
            }
        }
    }

    static func releaseDelayedResponse() {
        delayedResponseRelease.signal()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.polar.sh" || request.url?.host == "sandbox-api.polar.sh"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let json = Self.json(from: Self.bodyData(from: request))
        Self.requests.append(CapturedRequest(
            path: request.url?.path ?? "",
            json: json,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            contentType: request.value(forHTTPHeaderField: "Content-Type")
        ))
        if Self.mode == .delayedValid {
            Self.delayedRequestLock.lock()
            Self.delayedRequestArrived = true
            let continuation = Self.delayedRequestContinuation
            Self.delayedRequestContinuation = nil
            Self.delayedRequestLock.unlock()
            continuation?.resume()
            Self.delayedResponseRelease.wait()
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
            data = Self.response(key: json["key"] ?? "")
        case .revoked:
            status = 200
            data = Self.response(licenseStatus: "revoked")
        case .disabled:
            status = 200
            data = Self.response(licenseStatus: "disabled")
        case .notFound:
            status = 404
            data = Data(#"{"detail":"Not Found"}"#.utf8)
        case .wrongOrganization:
            status = 200
            data = Self.response(organizationID: UUID())
        case .wrongBenefit:
            status = 200
            data = Self.response(benefitID: UUID())
        case .wrongKey:
            status = 200
            data = Self.response(key: "another-license-key")
        case .expired:
            status = 200
            data = Self.response(expiresAt: "2027-01-01T00:00:00Z")
        case .activationLimited:
            status = 200
            data = Self.response(limitActivations: 1)
        case .usageLimited:
            status = 200
            data = Self.response(limitUsage: 100)
        case .malformed:
            status = 200
            data = Data(#"{"status":"granted"}"#.utf8)
        case .requestTimeout:
            status = 408
            data = Data()
        case .tooEarly:
            status = 425
            data = Data()
        case .unprocessable:
            status = 422
            data = Data(#"{"detail":"Validation error"}"#.utf8)
        case .throttled:
            status = 429
            data = Data(#"{"detail":"Too many requests."}"#.utf8)
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
        organizationID: UUID = testOrganizationID,
        benefitID: UUID = testBenefitID,
        key: String = "topside-test-license",
        licenseStatus: String = "granted",
        limitActivations: Int? = nil,
        limitUsage: Int? = nil,
        expiresAt: String? = nil
    ) -> Data {
        Data("""
        {
          "id": "33333333-3333-4333-8333-333333333333",
          "organization_id": "\(organizationID.uuidString.lowercased())",
          "benefit_id": "\(benefitID.uuidString.lowercased())",
          "key": "\(key)",
          "status": "\(licenseStatus)",
          "limit_activations": \(limitActivations.map(String.init) ?? "null"),
          "usage": 0,
          "limit_usage": \(limitUsage.map(String.init) ?? "null"),
          "validations": 1,
          "last_validated_at": null,
          "expires_at": \(expiresAt.map { "\"\($0)\"" } ?? "null")
        }
        """.utf8)
    }

    private static func json(from data: Data?) -> [String: String] {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return Dictionary(
            uniqueKeysWithValues: object.compactMap {
                guard let value = $0.value as? String else { return nil }
                return ($0.key, value)
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
