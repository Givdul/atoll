import Foundation
import Security

public enum TopsideEntitlementStatus: Equatable, Sendable {
    case activeTrial(expiresAt: Date, currentTime: Date)
    case expired
    case licensed(validatedAt: Date)
    case recoverableError(message: String, allowsUse: Bool)

    public var allowsUse: Bool {
        switch self {
        case .activeTrial, .licensed:
            true
        case .expired:
            false
        case .recoverableError(_, let allowsUse):
            allowsUse
        }
    }
}

public struct TopsideStoredLicense: Codable, Equatable, Sendable {
    public let key: String
    public var validatedAt: Date
    public var lastValidationAttemptAt: Date?

    public init(
        key: String,
        validatedAt: Date,
        lastValidationAttemptAt: Date? = nil
    ) {
        self.key = key
        self.validatedAt = validatedAt
        self.lastValidationAttemptAt = lastValidationAttemptAt
    }
}

public struct TopsideEntitlementRecord: Codable, Equatable, Sendable {
    public static let trialDuration: TimeInterval = 72 * 60 * 60

    public let trialStartedAt: Date
    public var lastSeenAt: Date
    public var license: TopsideStoredLicense?

    public init(
        trialStartedAt: Date,
        lastSeenAt: Date,
        license: TopsideStoredLicense? = nil
    ) {
        self.trialStartedAt = trialStartedAt
        self.lastSeenAt = max(lastSeenAt, trialStartedAt)
        self.license = license
    }

    public static func startingTrial(at date: Date) -> Self {
        Self(trialStartedAt: date, lastSeenAt: date)
    }

    public mutating func observe(_ date: Date) {
        lastSeenAt = max(lastSeenAt, date)
    }

    public func status(at date: Date) -> TopsideEntitlementStatus {
        if let license {
            return .licensed(validatedAt: license.validatedAt)
        }

        let expiresAt = trialStartedAt.addingTimeInterval(Self.trialDuration)
        let currentTime = date < lastSeenAt ? expiresAt : date
        return currentTime < expiresAt
            ? .activeTrial(expiresAt: expiresAt, currentTime: currentTime)
            : .expired
    }
}

public final class TopsideEntitlementStore: @unchecked Sendable {
    // LAContext does not suppress legacy Keychain ACL prompts after an ad-hoc
    // signature changes; these are the stable values of Apple's deprecated UI flag.
    private static let authenticationUIKey = "u_AuthUI"
    private static let authenticationUIFail = "u_AuthUIF"

    public enum Error: LocalizedError, Equatable {
        case malformedRecord
        case licenseNotAllowed
        case keychain(OSStatus)
        case timeout

        public var errorDescription: String? {
            switch self {
            case .malformedRecord:
                "Topside's saved entitlement is unreadable. Paste the license key again or contact support."
            case .licenseNotAllowed:
                "This local build cannot read or save license material."
            case .keychain(let status):
                "Topside could not access its protected entitlement in Keychain (error \(status)). Try again after unlocking your Mac."
            case .timeout:
                "Topside's protected entitlement did not respond. Topside will keep working and try again after relaunch."
            }
        }
    }

    // Retained so paid licenses remain discoverable after the bundle-ID rename.
    public static let defaultService = "com.givdul.skerry.entitlement.v2"
    public static let defaultAccount = "device-v2"
    static let storageModeInfoKey = "TopsideEntitlementStorage"
    static let trialFileStorageMode = "trial-file-v1"
    static let keychainStorageMode = "keychain-v2"
    static let trialFileName = "trial-entitlement-v1.json"

    private enum Storage: Sendable {
        case keychain
        case trialFile(URL)
    }

    private let storage: Storage
    private let service: String
    private let account: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let saveOverride: (@Sendable (TopsideEntitlementRecord) throws -> Void)?
    private let operationQueue = DispatchQueue(label: "com.givdul.topside.entitlement-keychain")
    private let operationLock = NSLock()
    private var operationInFlight = false

    public convenience init(
        service: String = TopsideEntitlementStore.defaultService,
        account: String = TopsideEntitlementStore.defaultAccount
    ) {
        self.init(storage: .keychain, service: service, account: account, saveOverride: nil)
    }

    init(
        service: String,
        account: String = TopsideEntitlementStore.defaultAccount,
        saveOverride: (@Sendable (TopsideEntitlementRecord) throws -> Void)?
    ) {
        self.storage = .keychain
        self.service = service
        self.account = account
        self.saveOverride = saveOverride
    }

    private init(
        storage: Storage,
        service: String = TopsideEntitlementStore.defaultService,
        account: String = TopsideEntitlementStore.defaultAccount,
        saveOverride: (@Sendable (TopsideEntitlementRecord) throws -> Void)? = nil
    ) {
        self.storage = storage
        self.service = service
        self.account = account
        self.saveOverride = saveOverride
    }

    public static func configured(
        bundle: Bundle = .main,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> TopsideEntitlementStore {
        configured(
            storageMode: bundle.object(forInfoDictionaryKey: storageModeInfoKey) as? String,
            homeDirectory: homeDirectory
        )
    }

    static func configured(
        storageMode: String?,
        homeDirectory: URL
    ) -> TopsideEntitlementStore {
        if storageMode == trialFileStorageMode {
            return TopsideEntitlementStore(
                storage: .trialFile(
                    homeDirectory
                        .appendingPathComponent(".topside", isDirectory: true)
                        .appendingPathComponent(trialFileName)
                )
            )
        }
        return TopsideEntitlementStore()
    }

    var isTrialFileBacked: Bool {
        if case .trialFile = storage {
            return true
        }
        return false
    }

    func load() throws -> TopsideEntitlementRecord? {
        switch storage {
        case .keychain:
            return try loadFromKeychain()
        case .trialFile(let fileURL):
            return try loadFromTrialFile(fileURL)
        }
    }

    private func loadFromKeychain() throws -> TopsideEntitlementRecord? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            Self.authenticationUIKey: Self.authenticationUIFail
        ] as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw Error.keychain(status)
        }
        guard let data = result as? Data,
              let record = try? decoder.decode(TopsideEntitlementRecord.self, from: data) else {
            throw Error.malformedRecord
        }
        return record
    }

    private func save(_ record: TopsideEntitlementRecord) throws {
        switch storage {
        case .keychain:
            try saveToKeychain(record)
        case .trialFile(let fileURL):
            try saveToTrialFile(record, at: fileURL)
        }
    }

    private func saveToKeychain(_ record: TopsideEntitlementRecord) throws {
        if let saveOverride {
            try saveOverride(record)
            return
        }
        let data = try encoder.encode(record)
        let query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            Self.authenticationUIKey: Self.authenticationUIFail
        ] as CFDictionary
        let attributes = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ] as CFDictionary

        let updateStatus = SecItemUpdate(query, attributes)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw Error.keychain(updateStatus)
        }

        let addStatus = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ] as CFDictionary, nil)
        if addStatus == errSecDuplicateItem, SecItemUpdate(query, attributes) == errSecSuccess {
            return
        }
        guard addStatus == errSecSuccess else {
            throw Error.keychain(addStatus)
        }
    }

    private func loadOrCreateTrial(at date: Date) throws -> TopsideEntitlementRecord {
        switch storage {
        case .keychain:
            return try loadOrCreateKeychainTrial(at: date)
        case .trialFile(let fileURL):
            if let record = try loadFromTrialFile(fileURL) {
                return record
            }
            let record = TopsideEntitlementRecord.startingTrial(at: date)
            try saveToTrialFile(record, at: fileURL)
            return record
        }
    }

    private func loadOrCreateKeychainTrial(at date: Date) throws -> TopsideEntitlementRecord {
        let record = TopsideEntitlementRecord.startingTrial(at: date)
        let data = try encoder.encode(record)
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ] as CFDictionary, nil)

        if status == errSecSuccess {
            return record
        }
        guard status == errSecDuplicateItem else {
            throw Error.keychain(status)
        }
        guard let existing = try load() else {
            throw Error.keychain(errSecItemNotFound)
        }
        return existing
    }

    private func loadFromTrialFile(_ fileURL: URL) throws -> TopsideEntitlementRecord? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        guard let record = try? decoder.decode(
            TopsideEntitlementRecord.self,
            from: Data(contentsOf: fileURL)
        ) else {
            throw Error.malformedRecord
        }
        guard record.license == nil else {
            throw Error.licenseNotAllowed
        }
        return record
    }

    private func saveToTrialFile(
        _ record: TopsideEntitlementRecord,
        at fileURL: URL
    ) throws {
        guard record.license == nil else {
            throw Error.licenseNotAllowed
        }
        try PrivateStorage.writeAtomically(
            encoder.encode(record),
            to: fileURL,
            hardenDirectory: true
        )
    }

    func loadBounded() async throws -> TopsideEntitlementRecord? {
        try await bounded { [self] in try load() }
    }

    func loadOrCreateTrialBounded(at date: Date) async throws -> TopsideEntitlementRecord {
        try await bounded { [self] in try loadOrCreateTrial(at: date) }
    }

    func saveBounded(_ record: TopsideEntitlementRecord) async throws {
        try await bounded { [self] in try save(record) }
    }

    private func bounded<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        guard beginOperation() else {
            throw Error.timeout
        }

        let result: Result<T, any Swift.Error> = await withCheckedContinuation { continuation in
            let completion = KeychainOperationCompletion(continuation)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
                completion.resume(.failure(Error.timeout))
            }
            operationQueue.async { [self] in
                let result = Result { try operation() }
                finishOperation()
                completion.resume(result)
            }
        }
        return try result.get()
    }

    private func beginOperation() -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !operationInFlight else { return false }
        operationInFlight = true
        return true
    }

    private func finishOperation() {
        operationLock.lock()
        operationInFlight = false
        operationLock.unlock()
    }
}

private final class KeychainOperationCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<Value, any Swift.Error>, Never>?

    init(_ continuation: CheckedContinuation<Result<Value, any Swift.Error>, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Value, any Swift.Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

public struct PolarConfiguration: Equatable, Sendable {
    public let purchaseURL: URL
    public let organizationID: UUID
    public let benefitID: UUID
    let apiBaseURL: URL

    public init?(
        purchaseURL: URL,
        organizationID: UUID,
        benefitID: UUID
    ) {
        guard purchaseURL.scheme?.lowercased() == "https",
              purchaseURL.user == nil,
              purchaseURL.password == nil,
              purchaseURL.port == nil,
              purchaseURL.query == nil,
              purchaseURL.fragment == nil,
              let host = purchaseURL.host?.lowercased() else {
            return nil
        }
        let segments = purchaseURL.path.split(separator: "/", omittingEmptySubsequences: true)
        let apiBaseURL: URL?
        if host == "buy.polar.sh",
           segments.count == 1,
           Self.isCheckoutLinkID(segments[0]) {
            apiBaseURL = URL(string: "https://api.polar.sh")
        } else if host == "sandbox-api.polar.sh",
                  segments.count == 4,
                  segments[0] == "v1",
                  segments[1] == "checkout-links",
                  Self.isCheckoutLinkID(segments[2]),
                  segments[3] == "redirect" {
            apiBaseURL = URL(string: "https://sandbox-api.polar.sh")
        } else {
            apiBaseURL = nil
        }
        guard let apiBaseURL else { return nil }
        self.purchaseURL = purchaseURL
        self.organizationID = organizationID
        self.benefitID = benefitID
        self.apiBaseURL = apiBaseURL
    }

    public init?(bundle: Bundle = .main) {
        guard let urlString = bundle.object(forInfoDictionaryKey: "TopsidePurchaseURL") as? String,
              let purchaseURL = URL(string: urlString),
              let organizationIDString = bundle.object(
                  forInfoDictionaryKey: "TopsidePolarOrganizationID"
              ) as? String,
              let organizationID = UUID(uuidString: organizationIDString),
              let benefitIDString = bundle.object(
                  forInfoDictionaryKey: "TopsidePolarBenefitID"
              ) as? String,
              let benefitID = UUID(uuidString: benefitIDString) else {
            return nil
        }
        self.init(
            purchaseURL: purchaseURL,
            organizationID: organizationID,
            benefitID: benefitID
        )
    }

    private static func isCheckoutLinkID(_ segment: Substring) -> Bool {
        guard segment.hasPrefix("polar_cl_") else { return false }
        let token = segment.dropFirst("polar_cl_".count)
        return !token.isEmpty
            && token.allSatisfy { $0.isLetter || $0.isNumber }
    }
}

public struct PolarLicenseClient: Sendable {
    public enum Error: LocalizedError, Equatable {
        case invalidKey
        case rejected(String)
        case wrongProduct
        case temporaryFailure
        case malformedResponse

        public var isDefinitive: Bool {
            switch self {
            case .invalidKey, .rejected, .wrongProduct:
                true
            case .temporaryFailure, .malformedResponse:
                false
            }
        }

        public var errorDescription: String? {
            switch self {
            case .invalidKey:
                "Enter the license key from your Polar purchase."
            case .rejected(let message):
                message.isEmpty ? "Polar did not accept this license." : message
            case .wrongProduct:
                "This license belongs to a different product."
            case .temporaryFailure:
                "Polar could not be reached. Topside will try again later."
            case .malformedResponse:
                "Polar returned an unexpected response. Topside will try again later."
            }
        }
    }

    private struct Response: Decodable {
        let organizationID: UUID
        let benefitID: UUID
        let key: String
        let status: String
        let limitActivations: Int?
        let limitUsage: Int?
        let expiresAt: String?

        private enum CodingKeys: String, CodingKey {
            case organizationID = "organization_id"
            case benefitID = "benefit_id"
            case key
            case status
            case limitActivations = "limit_activations"
            case limitUsage = "limit_usage"
            case expiresAt = "expires_at"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.limitActivations),
                  container.contains(.limitUsage),
                  container.contains(.expiresAt) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Missing limits")
                )
            }
            organizationID = try container.decode(UUID.self, forKey: .organizationID)
            benefitID = try container.decode(UUID.self, forKey: .benefitID)
            key = try container.decode(String.self, forKey: .key)
            status = try container.decode(String.self, forKey: .status)
            limitActivations = try container.decodeIfPresent(Int.self, forKey: .limitActivations)
            limitUsage = try container.decodeIfPresent(Int.self, forKey: .limitUsage)
            expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        }
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func validate(
        key rawKey: String,
        configuration: PolarConfiguration,
        now: Date = Date()
    ) async throws -> TopsideStoredLicense {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...255).contains(key.utf8.count) else {
            throw Error.invalidKey
        }
        let response = try await request(
            key: key,
            configuration: configuration
        )
        guard response.organizationID == configuration.organizationID,
              response.benefitID == configuration.benefitID,
              response.key == key else {
            throw Error.wrongProduct
        }
        guard response.expiresAt == nil,
              response.limitActivations == nil,
              response.limitUsage == nil else {
            throw Error.rejected("This license is not the perpetual Topside license.")
        }
        guard response.status == "granted" else {
            throw Error.rejected("This license is \(response.status). Paste an active Topside license.")
        }
        return TopsideStoredLicense(
            key: key,
            validatedAt: now,
            lastValidationAttemptAt: now
        )
    }

    private func request(
        key: String,
        configuration: PolarConfiguration
    ) async throws -> Response {
        let url = configuration.apiBaseURL
            .appendingPathComponent("v1/customer-portal/license-keys/validate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "key": key,
            "organization_id": configuration.organizationID.uuidString.lowercased(),
            "benefit_id": configuration.benefitID.uuidString.lowercased()
        ]) else {
            throw Error.malformedResponse
        }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Error.temporaryFailure
        }
        guard let http = response as? HTTPURLResponse else {
            throw Error.temporaryFailure
        }
        if http.statusCode == 408
            || http.statusCode == 425
            || http.statusCode == 422
            || http.statusCode == 429
            || (500...599).contains(http.statusCode) {
            throw Error.temporaryFailure
        }
        guard (200...299).contains(http.statusCode) else {
            throw Error.rejected(http.statusCode == 404 ? "This license was not found." : "")
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw Error.malformedResponse
        }
        return decoded
    }
}
