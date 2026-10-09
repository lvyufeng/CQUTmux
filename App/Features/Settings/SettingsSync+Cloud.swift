import Foundation
import CloudKit

/// The iCloud half of settings sync: moving a `SyncPayload` to and from the
/// user's private database, and reading the live stores into one.
///
/// A private CloudKit database, not the key-value store, and the difference is
/// worth stating: `NSUbiquitousKeyValueStore` is capped at 1 MB and is built
/// for small preferences, while an imported theme list will not stay small
/// forever. The private database has the room and keeps the payload on the
/// user's own account, which is where a host list belongs.
@Observable
final class SettingsSyncCoordinator {
    enum Status: Equatable {
        case off
        case idle
        case syncing
        case synced(Date)
        case failed(String)

        var label: String {
            switch self {
            case .off: "Off"
            case .idle: "On"
            case .syncing: "Syncing…"
            case .synced: "Synced"
            case .failed(let message): message
            }
        }
    }

    private static let recordType = "CQUTSettings"
    private static let recordName = "settings"
    private static let field = "payload"

    private(set) var status: Status = .off
    let sync: SettingsSync

    private let container: CKContainer
    private let database: CKDatabase

    init(sync: SettingsSync, container: CKContainer = .default()) {
        self.sync = sync
        self.container = container
        self.database = container.privateCloudDatabase
        status = sync.isEnabled ? .idle : .off
    }

    /// Whether this device can sync at all. A missing iCloud account is the
    /// ordinary reason it cannot, and the settings screen says so rather than
    /// presenting a switch that quietly does nothing.
    func accountAvailable() async -> Bool {
        (try? await container.accountStatus()) == .available
    }

    func setEnabled(_ enabled: Bool) async {
        sync.isEnabled = enabled
        status = enabled ? .idle : .off
        guard enabled else { return }
        await run(stores: nil)
    }

    /// One exchange: read the cloud, decide, and either write, read, or merge.
    ///
    /// `stores` is nil when there is nothing live to read or write — the
    /// enable path — in which case this only fetches, so the first real sync
    /// has a baseline to compare against.
    func run(stores: SyncStores?) async {
        guard sync.isEnabled else { status = .off; return }
        status = .syncing
        do {
            let remote = try await fetch()
            let local = stores.map { SyncPayload.capture(from: $0) }

            guard let local else {
                if let remote { sync.accept(remote) }
                status = .idle
                return
            }

            switch sync.decide(local: local, remote: remote) {
            case .identical:
                sync.accept(local)
            case .pushLocal:
                try await push(local)
                sync.accept(local)
            case .pullRemote:
                let pulled = remote!
                pulled.apply(to: stores!)
                sync.accept(pulled)
            case .merge:
                let merged = sync.merge(local: local, remote: remote!)
                merged.apply(to: stores!)
                try await push(merged)
                sync.accept(merged)
            }
            status = .synced(Date())
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Transport

    private func fetch() async throws -> SyncPayload? {
        let id = CKRecord.ID(recordName: Self.recordName)
        do {
            let record = try await database.record(for: id)
            guard let data = record[Self.field] as? Data else { return nil }
            return try JSONDecoder().decode(SyncPayload.self, from: data)
        } catch let error as CKError where error.code == .unknownItem {
            // No record yet is the state of every account before the first
            // push, not a failure.
            return nil
        }
    }

    private func push(_ payload: SyncPayload) async throws {
        let id = CKRecord.ID(recordName: Self.recordName)
        let record: CKRecord
        do {
            record = try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: Self.recordType, recordID: id)
        }
        record[Self.field] = try JSONEncoder().encode(payload)
        _ = try await database.save(record)
    }
}