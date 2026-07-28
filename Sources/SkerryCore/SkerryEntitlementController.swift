import Foundation

@MainActor
public final class SkerryEntitlementController {
    public static let validationInterval: TimeInterval = 24 * 60 * 60
    private static let observationWriteInterval: TimeInterval = 60

    public let configuration: LemonSqueezyConfiguration?

    private let store: SkerryEntitlementStore
    private let client: LemonSqueezyLicenseClient
    private var record: SkerryEntitlementRecord?
    private var lastSavedAt: Date?
    private var lastValidationAttemptAt: Date?
    private var message: String?
    private var canReplaceMalformedRecord = false
    private var mutationInProgress = false

    public init(
        store: SkerryEntitlementStore = SkerryEntitlementStore.configured(),
        client: LemonSqueezyLicenseClient = LemonSqueezyLicenseClient(),
        configuration: LemonSqueezyConfiguration? = LemonSqueezyConfiguration()
    ) {
        self.store = store
        self.client = client
        self.configuration = configuration
    }

    public func start(at now: Date = Date()) async -> SkerryEntitlementStatus {
        guard beginMutation() else { return status(at: now) }
        defer { endMutation() }
        do {
            var loaded = try await store.loadOrCreateTrialBounded(at: now)
            let previousLastSeenAt = loaded.lastSeenAt
            loaded.observe(now)
            record = loaded
            lastSavedAt = loaded.lastSeenAt
            message = nil
            canReplaceMalformedRecord = false
            if loaded.lastSeenAt != previousLastSeenAt {
                do {
                    try await store.saveBounded(loaded)
                } catch {
                    message = error.localizedDescription
                }
            }
            return status(at: now)
        } catch {
            message = error.localizedDescription
            canReplaceMalformedRecord = error as? SkerryEntitlementStore.Error == .malformedRecord
            return status(at: now)
        }
    }

    public func observe(_ now: Date = Date()) -> SkerryEntitlementStatus {
        guard !mutationInProgress else { return status(at: now) }
        guard var record else {
            return status(at: now)
        }

        let previous = record.status(at: now)
        record.observe(now)
        self.record = record
        let current = record.status(at: now)
        let shouldSave = lastSavedAt.map {
            now.timeIntervalSince($0) >= Self.observationWriteInterval
        } ?? true

        if shouldSave || previous != current {
            lastSavedAt = now
            Task { [weak self] in
                await self?.persistObservation(at: now)
            }
        }
        return status(at: now)
    }

    public func shouldValidate(at now: Date = Date()) -> Bool {
        guard !mutationInProgress,
              let validatedAt = record?.license?.validatedAt else { return false }
        return now.timeIntervalSince(max(validatedAt, lastValidationAttemptAt ?? .distantPast))
            >= Self.validationInterval
    }

    public func activate(key: String, at now: Date = Date()) async throws -> SkerryEntitlementStatus {
        guard beginMutation() else {
            throw ActivationError.busy
        }
        defer { endMutation() }
        guard let configuration else {
            throw ActivationError.notConfigured
        }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var record = record ?? (canReplaceMalformedRecord
            ? SkerryEntitlementRecord(
                trialStartedAt: now.addingTimeInterval(-SkerryEntitlementRecord.trialDuration),
                lastSeenAt: now
            )
            : nil) else {
            throw ActivationError.storageUnavailable
        }

        let license: SkerryStoredLicense
        let createdInstance: Bool
        if let existing = record.license {
            guard existing.key == key else {
                throw ActivationError.differentKey
            }
            do {
                license = try await client.validate(
                    existing,
                    configuration: configuration,
                    now: now
                )
            } catch let error as LemonSqueezyLicenseClient.Error where error.isDefinitive {
                record.license = nil
                record.observe(now)
                try await store.saveBounded(record)
                self.record = record
                lastSavedAt = now
                message = error.localizedDescription
                throw error
            }
            createdInstance = false
        } else {
            license = try await client.activate(
                key: key,
                configuration: configuration,
                now: now
            )
            createdInstance = true
        }
        record.license = license
        record.observe(now)
        do {
            try await store.saveBounded(record)
        } catch let saveError {
            if createdInstance {
                do {
                    try await client.deactivate(license, configuration: configuration)
                } catch {
                    throw ActivationError.cleanupFailed
                }
            }
            throw saveError
        }
        self.record = record
        lastSavedAt = now
        message = nil
        canReplaceMalformedRecord = false
        return status(at: now)
    }

    public func validate(at now: Date = Date()) async -> SkerryEntitlementStatus {
        guard beginMutation() else { return status(at: now) }
        defer { endMutation() }
        lastValidationAttemptAt = now
        guard let configuration, var record, let license = record.license else {
            if record?.license != nil, configuration == nil {
                message = ActivationError.notConfigured.localizedDescription
            }
            return status(at: now)
        }

        do {
            record.license = try await client.validate(
                license,
                configuration: configuration,
                now: now
            )
            record.observe(now)
            try await store.saveBounded(record)
            self.record = record
            lastSavedAt = now
            message = nil
        } catch let error as LemonSqueezyLicenseClient.Error {
            if error.isDefinitive {
                record.license = nil
                record.observe(now)
                do {
                    try await store.saveBounded(record)
                    self.record = record
                    lastSavedAt = now
                } catch {
                    message = error.localizedDescription
                    return status(at: now)
                }
            }
            message = error.localizedDescription
        } catch {
            message = error.localizedDescription
        }
        return status(at: now)
    }

    public func persistObservation(at now: Date = Date()) async {
        guard beginMutation() else { return }
        defer { endMutation() }
        guard var record else { return }
        record.observe(now)
        self.record = record
        do {
            try await store.saveBounded(record)
        } catch {
            message = error.localizedDescription
        }
    }

    public var guidance: String? {
        message
    }

    private func status(at now: Date) -> SkerryEntitlementStatus {
        guard let record else {
            return .recoverableError(
                message: message ?? ActivationError.storageUnavailable.localizedDescription,
                allowsUse: !canReplaceMalformedRecord
            )
        }
        let base = record.status(at: now)
        guard let message else { return base }
        return .recoverableError(message: message, allowsUse: base.allowsUse)
    }

    private func beginMutation() -> Bool {
        guard !mutationInProgress else { return false }
        mutationInProgress = true
        return true
    }

    private func endMutation() {
        mutationInProgress = false
    }

    public enum ActivationError: LocalizedError {
        case notConfigured
        case storageUnavailable
        case busy
        case differentKey
        case cleanupFailed

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                "This build does not contain Skerry's Lemon Squeezy checkout and product IDs."
            case .storageUnavailable:
                "Skerry cannot save a license until its protected Keychain record is available."
            case .busy:
                "Skerry is already updating its license. Try again in a moment."
            case .differentKey:
                "This Mac already has a different active license. Skerry did not consume another activation."
            case .cleanupFailed:
                "Skerry could not save or deactivate the new license instance. Contact support before trying another activation."
            }
        }
    }
}
