import Foundation
import Security

public enum SkerryEntitlementStatus: Equatable, Sendable {
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

public struct SkerryStoredLicense: Codable, Equatable, Sendable {
    public let key: String
    public let instanceID: String
    public var validatedAt: Date

    public init(key: String, instanceID: String, validatedAt: Date) {
        self.key = key
        self.instanceID = instanceID
        self.validatedAt = validatedAt
    }
}

public struct SkerryEntitlementRecord: Codable, Equatable, Sendable {
    public static let trialDuration: TimeInterval = 72 * 60 * 60

    public let trialStartedAt: Date
    public var lastSeenAt: Date
    public var license: SkerryStoredLicense?

    public init(
        trialStartedAt: Date,
        lastSeenAt: Date,
        license: SkerryStoredLicense? = nil
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

    public func status(at date: Date) -> SkerryEntitlementStatus {
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

public final class SkerryEntitlementStore: @unchecked Sendable {
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
                "Skerry's saved entitlement is unreadable. Paste the license key again or contact support."
            case .licenseNotAllowed:
                "This local build cannot read or save license material."
            case .keychain(let status):
                "Skerry could not access its protected entitlement in Keychain (error \(status)). Try again after unlocking your Mac."
            case .timeout:
                "Skerry's protected entitlement did not respond. Skerry will keep working and try again after relaunch."
            }
        }
    }

    public static let defaultService = "com.givdul.skerry.entitlement.v2"
    public static let defaultAccount = "device-v2"
    static let storageModeInfoKey = "SkerryEntitlementStorage"
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
    private let saveOverride: (@Sendable (SkerryEntitlementRecord) throws -> Void)?
    private let operationQueue = DispatchQueue(label: "com.givdul.skerry.entitlement-keychain")
    private let operationLock = NSLock()
    private var operationInFlight = false

    public convenience init(
        service: String = SkerryEntitlementStore.defaultService,
        account: String = SkerryEntitlementStore.defaultAccount
    ) {
        self.init(storage: .keychain, service: service, account: account, saveOverride: nil)
    }

    init(
        service: String,
        account: String = SkerryEntitlementStore.defaultAccount,
        saveOverride: (@Sendable (SkerryEntitlementRecord) throws -> Void)?
    ) {
        self.storage = .keychain
        self.service = service
        self.account = account
        self.saveOverride = saveOverride
    }

    private init(
        storage: Storage,
        service: String = SkerryEntitlementStore.defaultService,
        account: String = SkerryEntitlementStore.defaultAccount,
        saveOverride: (@Sendable (SkerryEntitlementRecord) throws -> Void)? = nil
    ) {
        self.storage = storage
        self.service = service
        self.account = account
        self.saveOverride = saveOverride
    }

    public static func configured(
        bundle: Bundle = .main,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> SkerryEntitlementStore {
        configured(
            storageMode: bundle.object(forInfoDictionaryKey: storageModeInfoKey) as? String,
            homeDirectory: homeDirectory
        )
    }

    static func configured(
        storageMode: String?,
        homeDirectory: URL
    ) -> SkerryEntitlementStore {
        if storageMode == trialFileStorageMode {
            return SkerryEntitlementStore(
                storage: .trialFile(
                    homeDirectory
                        .appendingPathComponent(".skerry", isDirectory: true)
                        .appendingPathComponent(trialFileName)
                )
            )
        }
        return SkerryEntitlementStore()
    }

    var isTrialFileBacked: Bool {
        if case .trialFile = storage {
            return true
        }
        return false
    }

    func load() throws -> SkerryEntitlementRecord? {
        switch storage {
        case .keychain:
            return try loadFromKeychain()
        case .trialFile(let fileURL):
            return try loadFromTrialFile(fileURL)
        }
    }

    private func loadFromKeychain() throws -> SkerryEntitlementRecord? {
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
              let record = try? decoder.decode(SkerryEntitlementRecord.self, from: data) else {
            throw Error.malformedRecord
        }
        return record
    }

    private func save(_ record: SkerryEntitlementRecord) throws {
        switch storage {
        case .keychain:
            try saveToKeychain(record)
        case .trialFile(let fileURL):
            try saveToTrialFile(record, at: fileURL)
        }
    }

    private func saveToKeychain(_ record: SkerryEntitlementRecord) throws {
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

    private func loadOrCreateTrial(at date: Date) throws -> SkerryEntitlementRecord {
        switch storage {
        case .keychain:
            return try loadOrCreateKeychainTrial(at: date)
        case .trialFile(let fileURL):
            if let record = try loadFromTrialFile(fileURL) {
                return record
            }
            let record = SkerryEntitlementRecord.startingTrial(at: date)
            try saveToTrialFile(record, at: fileURL)
            return record
        }
    }

    private func loadOrCreateKeychainTrial(at date: Date) throws -> SkerryEntitlementRecord {
        let record = SkerryEntitlementRecord.startingTrial(at: date)
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

    private func loadFromTrialFile(_ fileURL: URL) throws -> SkerryEntitlementRecord? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        guard let record = try? decoder.decode(
            SkerryEntitlementRecord.self,
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
        _ record: SkerryEntitlementRecord,
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

    func loadBounded() async throws -> SkerryEntitlementRecord? {
        try await bounded { [self] in try load() }
    }

    func loadOrCreateTrialBounded(at date: Date) async throws -> SkerryEntitlementRecord {
        try await bounded { [self] in try loadOrCreateTrial(at: date) }
    }

    func saveBounded(_ record: SkerryEntitlementRecord) async throws {
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

public struct LemonSqueezyConfiguration: Equatable, Sendable {
    public let purchaseURL: URL
    public let storeID: Int
    public let productID: Int
    public let variantID: Int

    public init?(
        purchaseURL: URL,
        storeID: Int,
        productID: Int,
        variantID: Int
    ) {
        guard purchaseURL.scheme?.lowercased() == "https",
              purchaseURL.user == nil,
              purchaseURL.password == nil,
              let host = purchaseURL.host?.lowercased(),
              host.hasSuffix(".lemonsqueezy.com"),
              purchaseURL.path.hasPrefix("/checkout/buy/"),
              storeID > 0,
              productID > 0,
              variantID > 0 else {
            return nil
        }
        self.purchaseURL = purchaseURL
        self.storeID = storeID
        self.productID = productID
        self.variantID = variantID
    }

    public init?(bundle: Bundle = .main) {
        guard let urlString = bundle.object(forInfoDictionaryKey: "SkerryPurchaseURL") as? String,
              let purchaseURL = URL(string: urlString),
              let storeID = Self.integer(bundle.object(forInfoDictionaryKey: "SkerryLemonSqueezyStoreID")),
              let productID = Self.integer(bundle.object(forInfoDictionaryKey: "SkerryLemonSqueezyProductID")),
              let variantID = Self.integer(bundle.object(forInfoDictionaryKey: "SkerryLemonSqueezyVariantID")) else {
            return nil
        }
        self.init(
            purchaseURL: purchaseURL,
            storeID: storeID,
            productID: productID,
            variantID: variantID
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }
}

public struct LemonSqueezyLicenseClient: Sendable {
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
                "Enter the license key from your Lemon Squeezy receipt."
            case .rejected(let message):
                message.isEmpty ? "Lemon Squeezy did not accept this license." : message
            case .wrongProduct:
                "This license belongs to a different product."
            case .temporaryFailure:
                "Lemon Squeezy could not be reached. Skerry will try again later."
            case .malformedResponse:
                "Lemon Squeezy returned an unexpected response. Skerry will try again later."
            }
        }
    }

    private struct Response: Decodable {
        struct LicenseKey: Decodable {
            let status: String
            let expiresAt: String?

            private enum CodingKeys: String, CodingKey {
                case status
                case expiresAt = "expires_at"
            }
        }

        struct Instance: Decodable {
            let id: String
        }

        struct Meta: Decodable {
            let storeID: Int
            let productID: Int
            let variantID: Int

            private enum CodingKeys: String, CodingKey {
                case storeID = "store_id"
                case productID = "product_id"
                case variantID = "variant_id"
            }
        }

        let activated: Bool?
        let deactivated: Bool?
        let valid: Bool?
        let error: String?
        let licenseKey: LicenseKey?
        let instance: Instance?
        let meta: Meta?

        private enum CodingKeys: String, CodingKey {
            case activated
            case deactivated
            case valid
            case error
            case licenseKey = "license_key"
            case instance
            case meta
        }
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func activate(
        key rawKey: String,
        configuration: LemonSqueezyConfiguration,
        now: Date = Date()
    ) async throws -> SkerryStoredLicense {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...255).contains(key.utf8.count) else {
            throw Error.invalidKey
        }
        let response = try await request(
            endpoint: "activate",
            fields: [
                URLQueryItem(name: "license_key", value: key),
                URLQueryItem(name: "instance_name", value: "Skerry on Mac")
            ]
        )
        guard response.activated == true else {
            throw Error.rejected(response.error ?? "")
        }
        let instanceID = try validate(response, configuration: configuration)
        return SkerryStoredLicense(key: key, instanceID: instanceID, validatedAt: now)
    }

    public func validate(
        _ license: SkerryStoredLicense,
        configuration: LemonSqueezyConfiguration,
        now: Date = Date()
    ) async throws -> SkerryStoredLicense {
        let response = try await request(
            endpoint: "validate",
            fields: [
                URLQueryItem(name: "license_key", value: license.key),
                URLQueryItem(name: "instance_id", value: license.instanceID)
            ]
        )
        guard response.valid == true else {
            throw Error.rejected(response.error ?? "")
        }
        let instanceID = try validate(response, configuration: configuration)
        guard instanceID == license.instanceID else {
            throw Error.rejected("Lemon Squeezy did not validate this Mac's license activation.")
        }
        return SkerryStoredLicense(
            key: license.key,
            instanceID: license.instanceID,
            validatedAt: now
        )
    }

    public func deactivate(
        _ license: SkerryStoredLicense,
        configuration: LemonSqueezyConfiguration
    ) async throws {
        let response = try await request(
            endpoint: "deactivate",
            fields: [
                URLQueryItem(name: "license_key", value: license.key),
                URLQueryItem(name: "instance_id", value: license.instanceID)
            ]
        )
        guard response.deactivated == true else {
            throw Error.rejected(response.error ?? "")
        }
        let licenseKey = try validateProduct(response, configuration: configuration)
        guard licenseKey.status == "active" || licenseKey.status == "inactive" else {
            throw Error.rejected("This license is \(licenseKey.status).")
        }
    }

    private func validate(
        _ response: Response,
        configuration: LemonSqueezyConfiguration
    ) throws -> String {
        let licenseKey = try validateProduct(response, configuration: configuration)
        guard let instanceID = response.instance?.id, !instanceID.isEmpty else {
            throw Error.malformedResponse
        }
        guard licenseKey.status == "active" else {
            throw Error.rejected("This license is \(licenseKey.status). Paste an active Skerry license.")
        }
        return instanceID
    }

    private func validateProduct(
        _ response: Response,
        configuration: LemonSqueezyConfiguration
    ) throws -> Response.LicenseKey {
        guard let meta = response.meta, let licenseKey = response.licenseKey else {
            throw Error.malformedResponse
        }
        guard meta.storeID == configuration.storeID,
              meta.productID == configuration.productID,
              meta.variantID == configuration.variantID else {
            throw Error.wrongProduct
        }
        guard licenseKey.expiresAt == nil else {
            throw Error.rejected("This license is not the perpetual Skerry license.")
        }
        return licenseKey
    }

    private func request(endpoint: String, fields: [URLQueryItem]) async throws -> Response {
        guard let url = URL(string: "https://api.lemonsqueezy.com/v1/licenses/\(endpoint)") else {
            throw Error.malformedResponse
        }
        var components = URLComponents()
        components.queryItems = fields
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

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
            || http.statusCode == 429
            || (500...599).contains(http.statusCode) {
            throw Error.temporaryFailure
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw Error.malformedResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw Error.rejected(decoded.error ?? "")
        }
        return decoded
    }
}
