import Foundation

@MainActor
public final class TopsideEntitlementController {
    public static let validationInterval: TimeInterval = 24 * 60 * 60
    private static let observationWriteInterval: TimeInterval = 60

    public let configuration: PolarConfiguration?

    private let store: TopsideEntitlementStore
    private let client: PolarLicenseClient
    private var record: TopsideEntitlementRecord?
    private var lastSavedAt: Date?
    private var message: String?
    private var canReplaceMalformedRecord = false
    private var mutationInProgress = false

    public init(
        store: TopsideEntitlementStore = TopsideEntitlementStore.configured(),
        client: PolarLicenseClient = PolarLicenseClient(),
        configuration: PolarConfiguration? = PolarConfiguration()
    ) {
        self.store = store
        self.client = client
        self.configuration = configuration
    }

    public func start(at now: Date = Date()) async -> TopsideEntitlementStatus {
        guard beginMutation() else { return status(at: now) }
        defer { endMutation() }
        do {
            var loaded = try await store.loadOrCreateTrialBounded(at: now)
            let persistedLastSeenAt = loaded.lastSeenAt
            loaded.observe(now)
            record = loaded
            lastSavedAt = persistedLastSeenAt
            message = nil
            canReplaceMalformedRecord = false
            if loaded.lastSeenAt != persistedLastSeenAt {
                do {
                    try await persist(loaded, at: now, message: nil)
                } catch {
                    message = error.localizedDescription
                }
            }
            return status(at: now)
        } catch {
            message = error.localizedDescription
            canReplaceMalformedRecord = error as? TopsideEntitlementStore.Error == .malformedRecord
            return status(at: now)
        }
    }

    public func observe(_ now: Date = Date()) -> TopsideEntitlementStatus {
        guard !mutationInProgress, var record else { return status(at: now) }
        let previous = record.status(at: now)
        record.observe(now)
        self.record = record
        let current = record.status(at: now)
        let shouldSave = lastSavedAt.map {
            now.timeIntervalSince($0) >= Self.observationWriteInterval
        } ?? true
        if shouldSave || previous != current {
            Task { [weak self] in
                await self?.persistObservation(at: now)
            }
        }
        return status(at: now)
    }

    public func shouldValidate(at now: Date = Date()) -> Bool {
        guard !mutationInProgress, let license = record?.license else { return false }
        return now.timeIntervalSince(
            max(license.validatedAt, license.lastValidationAttemptAt ?? .distantPast)
        ) >= Self.validationInterval
    }

    public func nextMaintenanceDate(at now: Date = Date()) -> Date? {
        guard let record else { return nil }
        var deadlines = [
            (lastSavedAt ?? record.lastSeenAt)
                .addingTimeInterval(Self.observationWriteInterval)
        ]
        if let license = record.license {
            deadlines.append(
                max(license.validatedAt, license.lastValidationAttemptAt ?? .distantPast)
                    .addingTimeInterval(Self.validationInterval)
            )
        } else {
            deadlines.append(
                record.trialStartedAt.addingTimeInterval(TopsideEntitlementRecord.trialDuration)
            )
        }
        return deadlines.min().map { max($0, now) }
    }

    public func enter(key: String, at now: Date = Date()) async throws -> TopsideEntitlementStatus {
        guard beginMutation() else { throw LicenseError.busy }
        defer { endMutation() }
        guard let configuration else { throw LicenseError.notConfigured }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var proposed = record ?? (canReplaceMalformedRecord
            ? TopsideEntitlementRecord(
                trialStartedAt: now.addingTimeInterval(-TopsideEntitlementRecord.trialDuration),
                lastSeenAt: now
            )
            : nil) else {
            throw LicenseError.storageUnavailable
        }

        if let existing = proposed.license {
            guard existing.key == key else { throw LicenseError.differentKey }
            do {
                proposed.license = try await client.validate(
                    key: existing.key,
                    configuration: configuration,
                    now: now
                )
            } catch let error as PolarLicenseClient.Error where error.isDefinitive {
                proposed.license = nil
                proposed.observe(now)
                try await persist(proposed, at: now, message: error.localizedDescription)
                throw error
            } catch let error as PolarLicenseClient.Error {
                proposed.license?.lastValidationAttemptAt = now
                try await persist(proposed, at: now, message: error.localizedDescription)
                throw error
            }
        } else {
            proposed.license = try await client.validate(
                key: key,
                configuration: configuration,
                now: now
            )
        }
        proposed.observe(now)
        try await persist(
            proposed,
            at: now,
            message: nil,
            clearsMalformedRecord: true
        )
        return status(at: now)
    }

    public func validate(at now: Date = Date()) async -> TopsideEntitlementStatus {
        guard beginMutation() else { return status(at: now) }
        defer { endMutation() }
        guard let configuration, var proposed = record, let license = proposed.license else {
            if record?.license != nil, configuration == nil {
                message = LicenseError.notConfigured.localizedDescription
            }
            return status(at: now)
        }

        do {
            proposed.license = try await client.validate(
                key: license.key,
                configuration: configuration,
                now: now
            )
            proposed.observe(now)
            try await persist(proposed, at: now, message: nil)
        } catch let error as PolarLicenseClient.Error {
            if error.isDefinitive {
                proposed.license = nil
                proposed.observe(now)
            } else {
                proposed.license?.lastValidationAttemptAt = now
            }
            do {
                try await persist(proposed, at: now, message: error.localizedDescription)
            } catch {
                message = error.localizedDescription
            }
        } catch {
            message = error.localizedDescription
        }
        return status(at: now)
    }

    public func persistObservation(at now: Date = Date()) async {
        guard beginMutation() else { return }
        defer { endMutation() }
        guard var proposed = record else { return }
        proposed.observe(now)
        do {
            try await persist(proposed, at: now, message: message)
        } catch {
            message = error.localizedDescription
        }
    }

    public var guidance: String? {
        message
    }

    private func persist(
        _ proposed: TopsideEntitlementRecord,
        at now: Date,
        message: String?,
        clearsMalformedRecord: Bool = false
    ) async throws {
        try await store.saveBounded(proposed)
        record = proposed
        lastSavedAt = now
        self.message = message
        if clearsMalformedRecord {
            canReplaceMalformedRecord = false
        }
    }

    private func status(at now: Date) -> TopsideEntitlementStatus {
        guard let record else {
            return .recoverableError(
                message: message ?? LicenseError.storageUnavailable.localizedDescription,
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

    public enum LicenseError: LocalizedError {
        case notConfigured
        case storageUnavailable
        case busy
        case differentKey

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                "This build does not contain Topside's Polar checkout and license IDs."
            case .storageUnavailable:
                "Topside cannot save a license until its protected Keychain record is available."
            case .busy:
                "Topside is already updating its license. Try again in a moment."
            case .differentKey:
                "This Mac already has a different active license."
            }
        }
    }
}
