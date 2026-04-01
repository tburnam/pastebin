import CloudKit
import Foundation

final class SyncChangeTracker {
    private let database: ClipboardDatabase

    init(database: ClipboardDatabase) {
        self.database = database
    }

    // MARK: - Pending Changes for CKSyncEngine

    func pendingRecordZoneChanges() -> [CKSyncEngine.PendingRecordZoneChange] {
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []

        if let uploadKeys = try? database.fetchPendingSyncClipUploadDedupeKeys() {
            for key in uploadKeys {
                changes.append(.saveRecord(SyncRecordMapper.clipRecordID(dedupeKey: key)))
            }
        }

        if let deleteKeys = try? database.fetchPendingDeleteClipDedupeKeys() {
            for key in deleteKeys {
                changes.append(.deleteRecord(SyncRecordMapper.clipRecordID(dedupeKey: key)))
            }
        }

        if let bucketUploadNames = try? database.fetchPendingSyncBucketRecordNames() {
            for name in bucketUploadNames {
                changes.append(.saveRecord(SyncRecordMapper.bucketRecordID(recordName: name)))
            }
        }

        if let bucketDeleteNames = try? database.fetchPendingDeleteBucketRecordNames() {
            for name in bucketDeleteNames {
                changes.append(.deleteRecord(SyncRecordMapper.bucketRecordID(recordName: name)))
            }
        }

        if let bucketItemKeys = try? database.fetchPendingSyncBucketItemKeys() {
            for key in bucketItemKeys {
                if let row = try? database.fetchBucketItemForSync(bucketID: key.bucketID, clipItemID: key.clipItemID) {
                    let recordName = SyncRecordMapper.bucketItemRecordName(
                        bucketRecordName: row.bucketDedupeKey,
                        clipDedupeKey: row.clipDedupeKey
                    )
                    changes.append(.saveRecord(SyncRecordMapper.bucketItemRecordID(recordName: recordName)))
                }
            }
        }

        return changes
    }

    // MARK: - Clip Changes

    func markInserted(clipID: Int64) {
        try? database.markClipPendingUpload(id: clipID)
    }

    func markDeleted(clipID: Int64) {
        try? database.markClipPendingDelete(id: clipID)
    }

    func markSynced(clipID: Int64, systemFieldsData: Data) {
        try? database.markClipSynced(id: clipID, systemFieldsData: systemFieldsData)
    }

    // MARK: - Bucket Changes

    func markBucketChanged(bucketID: Int64) {
        try? database.markBucketPendingUpload(id: bucketID)
    }

    func markBucketDeleted(bucketID: Int64) {
        try? database.markBucketPendingDelete(id: bucketID)
    }

    func markBucketSynced(bucketID: Int64, systemFieldsData: Data) {
        try? database.markBucketSynced(id: bucketID, systemFieldsData: systemFieldsData)
    }

    // MARK: - BucketItem Changes

    func markBucketItemChanged(bucketID: Int64, clipItemID: Int64) {
        try? database.markBucketItemPendingUpload(bucketID: bucketID, clipItemID: clipItemID)
    }

    func markBucketItemSynced(bucketID: Int64, clipItemID: Int64, systemFieldsData: Data) {
        try? database.markBucketItemSynced(bucketID: bucketID, clipItemID: clipItemID, systemFieldsData: systemFieldsData)
    }

    // MARK: - Initial Sync

    func markAllLocalItemsForUpload() {
        try? database.markAllLocalClipsPendingUpload()
        try? database.markAllLocalBucketsPendingUpload()
    }

    // MARK: - State Persistence

    func persistEngineState(_ serialization: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(serialization) else { return }
        try? database.persistSyncEngineState(data)
    }

    func loadEngineState() -> CKSyncEngine.State.Serialization? {
        guard let data = try? database.loadSyncEngineState() else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    // MARK: - Reset

    func clearAllSyncState() {
        try? database.clearAllSyncMetadata()
    }
}
