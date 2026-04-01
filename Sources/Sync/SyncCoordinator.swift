import CloudKit
import Foundation

final class SyncCoordinator: @unchecked Sendable {
    private let database: ClipboardDatabase
    private let onRemoteClipChange: (ClipItem) -> Void
    private let onRemoteClipDelete: (String) -> Void
    private let onRemoteBucketChange: (Bucket) -> Void
    private let onRemoteBucketDelete: (Int64) -> Void
    private let onRemoteBucketItemChange: (Int64) -> Void
    let statusProvider = SyncStatusProvider()

    private var syncEngine: CKSyncEngine?
    private let changeTracker: SyncChangeTracker
    private let syncQueue = DispatchQueue(label: "pastebin.sync.queue", qos: .utility)

    init(
        database: ClipboardDatabase,
        onRemoteClipChange: @escaping (ClipItem) -> Void,
        onRemoteClipDelete: @escaping (String) -> Void,
        onRemoteBucketChange: @escaping (Bucket) -> Void,
        onRemoteBucketDelete: @escaping (Int64) -> Void,
        onRemoteBucketItemChange: @escaping (Int64) -> Void
    ) {
        self.database = database
        self.onRemoteClipChange = onRemoteClipChange
        self.onRemoteClipDelete = onRemoteClipDelete
        self.onRemoteBucketChange = onRemoteBucketChange
        self.onRemoteBucketDelete = onRemoteBucketDelete
        self.onRemoteBucketItemChange = onRemoteBucketItemChange
        self.changeTracker = SyncChangeTracker(database: database)
    }

    // MARK: - Lifecycle

    func start() {
        syncQueue.async { [weak self] in
            guard let self, self.syncEngine == nil else { return }
            self.checkAccountAndStart()
        }
    }

    func stop() {
        syncQueue.async { [weak self] in
            self?.syncEngine = nil
            self?.statusProvider.updateSyncing(false)
        }
    }

    private func checkAccountAndStart() {
        SyncConstants.container.accountStatus { [weak self] status, error in
            guard let self else { return }

            self.statusProvider.updateAccountStatus(status)

            if let error {
                self.statusProvider.updateError("iCloud error: \(error.localizedDescription)")
                return
            }

            guard status == .available else {
                self.statusProvider.updateError("Sign in to iCloud in System Settings to enable sync.")
                return
            }

            self.statusProvider.updateError(nil)
            self.syncQueue.async {
                self.initializeSyncEngine()
            }
        }
    }

    private func initializeSyncEngine() {
        let previousState = changeTracker.loadEngineState()

        if previousState == nil {
            changeTracker.markAllLocalItemsForUpload()
        }

        let pendingChanges = changeTracker.pendingRecordZoneChanges()

        let configuration = CKSyncEngine.Configuration(
            database: SyncConstants.container.privateCloudDatabase,
            stateSerialization: previousState,
            delegate: self
        )

        let engine = CKSyncEngine(configuration)
        self.syncEngine = engine

        if !pendingChanges.isEmpty {
            engine.state.add(pendingRecordZoneChanges: pendingChanges)
        }
    }

    // MARK: - Local Clip Notifications

    func localItemInserted(clipID: Int64) {
        syncQueue.async { [weak self] in
            guard let self, let engine = self.syncEngine else { return }

            self.changeTracker.markInserted(clipID: clipID)

            if let dedupeKey = try? self.database.fetchDedupeKey(forClipID: clipID) {
                let recordID = SyncRecordMapper.clipRecordID(dedupeKey: dedupeKey)
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            }
        }
    }

    func localItemDeleted(clipID: Int64) {
        syncQueue.async { [weak self] in
            guard let self, let engine = self.syncEngine else { return }

            if let dedupeKey = try? self.database.fetchDedupeKey(forClipID: clipID) {
                self.changeTracker.markDeleted(clipID: clipID)
                let recordID = SyncRecordMapper.clipRecordID(dedupeKey: dedupeKey)
                engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
            }
        }
    }

    // MARK: - Local Bucket Notifications

    func localBucketChanged(bucketID: Int64) {
        syncQueue.async { [weak self] in
            guard let self, let engine = self.syncEngine else { return }

            self.changeTracker.markBucketChanged(bucketID: bucketID)

            if let recordName = try? self.database.fetchBucketRecordName(id: bucketID) {
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(SyncRecordMapper.bucketRecordID(recordName: recordName))])
            }
        }
    }

    func localBucketDeleted(bucketID: Int64) {
        syncQueue.async { [weak self] in
            guard let self, let engine = self.syncEngine else { return }

            self.changeTracker.markBucketDeleted(bucketID: bucketID)

            if let recordName = try? self.database.fetchBucketRecordName(id: bucketID) {
                engine.state.add(pendingRecordZoneChanges: [.deleteRecord(SyncRecordMapper.bucketRecordID(recordName: recordName))])
            }
        }
    }

    func localBucketItemChanged(bucketID: Int64, clipItemID: Int64) {
        syncQueue.async { [weak self] in
            guard let self, let engine = self.syncEngine else { return }

            self.changeTracker.markBucketItemChanged(bucketID: bucketID, clipItemID: clipItemID)

            if let row = try? self.database.fetchBucketItemForSync(bucketID: bucketID, clipItemID: clipItemID) {
                let recordName = SyncRecordMapper.bucketItemRecordName(
                    bucketRecordName: row.bucketDedupeKey,
                    clipDedupeKey: row.clipDedupeKey
                )
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(SyncRecordMapper.bucketItemRecordID(recordName: recordName))])
            }
        }
    }
}

// MARK: - CKSyncEngineDelegate

extension SyncCoordinator: CKSyncEngineDelegate {

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        switch event {
        case .stateUpdate(let stateUpdate):
            changeTracker.persistEngineState(stateUpdate.stateSerialization)

        case .accountChange(let accountChange):
            handleAccountChange(accountChange)

        case .fetchedDatabaseChanges:
            break

        case .fetchedRecordZoneChanges(let fetchedChanges):
            handleFetchedRecordZoneChanges(fetchedChanges)

        case .sentRecordZoneChanges(let sentChanges):
            handleSentRecordZoneChanges(sentChanges)

        case .sentDatabaseChanges:
            break

        case .willFetchChanges:
            statusProvider.updateSyncing(true)

        case .didFetchChanges:
            statusProvider.updateSyncing(false)
            SyncRecordMapper.cleanupTempAssets()

        case .willSendChanges:
            statusProvider.updateSyncing(true)

        case .didSendChanges:
            statusProvider.updateSyncing(false)
            SyncRecordMapper.cleanupTempAssets()

        case .willFetchRecordZoneChanges:
            break

        case .didFetchRecordZoneChanges:
            break

        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pendingChanges = syncEngine.state.pendingRecordZoneChanges

        guard !pendingChanges.isEmpty else { return nil }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pendingChanges) { [weak self] recordID in
            guard let self else { return nil }
            return self.recordForUpload(recordID: recordID)
        }
    }

    // MARK: - Event Handlers

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        statusProvider.updateAccountStatus(.available)

        switch change.changeType {
        case .signIn:
            statusProvider.updateError(nil)
        case .switchAccounts:
            changeTracker.clearAllSyncState()
            statusProvider.updateError(nil)
            syncQueue.async { [weak self] in
                self?.syncEngine = nil
                self?.initializeSyncEngine()
            }
        case .signOut:
            statusProvider.updateAccountStatus(.noAccount)
            statusProvider.updateError("Sign in to iCloud in System Settings to enable sync.")
            syncQueue.async { [weak self] in
                self?.syncEngine = nil
            }
        @unknown default:
            break
        }
    }

    private func handleFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        for modification in changes.modifications {
            let record = modification.record

            switch record.recordType {
            case SyncConstants.clipItemRecordType:
                guard let incoming = SyncRecordMapper.incomingClip(from: record) else { continue }
                do {
                    let item = try database.insertOrMergeRemoteClip(incoming)
                    DispatchQueue.main.async { [weak self] in
                        self?.onRemoteClipChange(item)
                    }
                } catch {
                    print("Failed to merge remote clip: \(error)")
                }

            case SyncConstants.bucketRecordType:
                guard let incoming = SyncRecordMapper.incomingBucket(from: record) else { continue }
                do {
                    let bucket = try database.insertOrMergeRemoteBucket(incoming)
                    DispatchQueue.main.async { [weak self] in
                        self?.onRemoteBucketChange(bucket)
                    }
                } catch {
                    print("Failed to merge remote bucket: \(error)")
                }

            case SyncConstants.bucketItemRecordType:
                guard let incoming = SyncRecordMapper.incomingBucketItem(from: record) else { continue }
                do {
                    try database.insertOrMergeRemoteBucketItem(incoming)
                    if let bucketID = try? database.fetchBucketIDByRecordName(incoming.bucketRecordName) {
                        DispatchQueue.main.async { [weak self] in
                            self?.onRemoteBucketItemChange(bucketID)
                        }
                    }
                } catch {
                    print("Failed to merge remote bucket item: \(error)")
                }

            default:
                break
            }
        }

        for deletion in changes.deletions {
            let recordID = deletion.recordID

            switch deletion.recordType {
            case SyncConstants.clipItemRecordType:
                let dedupeKey = recordID.recordName
                try? database.deleteClipBySyncRemoval(dedupeKey: dedupeKey)
                DispatchQueue.main.async { [weak self] in
                    self?.onRemoteClipDelete(dedupeKey)
                }

            case SyncConstants.bucketRecordType:
                let recordName = recordID.recordName
                if let bucketID = try? database.fetchBucketIDByRecordName(recordName) {
                    try? database.deleteBucketBySyncRemoval(recordName: recordName)
                    DispatchQueue.main.async { [weak self] in
                        self?.onRemoteBucketDelete(bucketID)
                    }
                }

            default:
                break
            }
        }
    }

    private func handleSentRecordZoneChanges(_ sentChanges: CKSyncEngine.Event.SentRecordZoneChanges) {
        for savedRecord in sentChanges.savedRecords {
            let systemData = SyncRecordMapper.encodeSystemFields(of: savedRecord)

            switch savedRecord.recordType {
            case SyncConstants.clipItemRecordType:
                let dedupeKey = savedRecord.recordID.recordName
                if let existing = try? database.fetchClipIDByDedupeKey(dedupeKey) {
                    changeTracker.markSynced(clipID: existing.id, systemFieldsData: systemData)
                }

            case SyncConstants.bucketRecordType:
                let recordName = savedRecord.recordID.recordName
                if let bucketID = try? database.fetchBucketIDByRecordName(recordName) {
                    changeTracker.markBucketSynced(bucketID: bucketID, systemFieldsData: systemData)
                }

            case SyncConstants.bucketItemRecordType:
                if let bucketRN = savedRecord[SyncConstants.BucketItemFields.bucketRecordName] as? String,
                   let clipRN = savedRecord[SyncConstants.BucketItemFields.clipRecordName] as? String,
                   let bucketID = try? database.fetchBucketIDByRecordName(bucketRN),
                   let clipResult = try? database.fetchClipIDByDedupeKey(clipRN) {
                    changeTracker.markBucketItemSynced(bucketID: bucketID, clipItemID: clipResult.id, systemFieldsData: systemData)
                }

            default:
                break
            }
        }

        for failedSave in sentChanges.failedRecordSaves {
            let error = failedSave.error

            switch error.code {
            case .serverRecordChanged:
                if let serverRecord = error.serverRecord {
                    resolveConflict(serverRecord: serverRecord)
                }

            case .zoneNotFound:
                break

            case .quotaExceeded:
                statusProvider.updateError("iCloud storage is full. Free up space to continue syncing.")

            default:
                print("Sync save failed for \(failedSave.record.recordID): \(error)")
            }
        }
    }

    private func resolveConflict(serverRecord: CKRecord) {
        switch serverRecord.recordType {
        case SyncConstants.clipItemRecordType:
            if let incoming = SyncRecordMapper.incomingClip(from: serverRecord),
               let item = try? database.insertOrMergeRemoteClip(incoming) {
                DispatchQueue.main.async { [weak self] in
                    self?.onRemoteClipChange(item)
                }
            }

        case SyncConstants.bucketRecordType:
            if let incoming = SyncRecordMapper.incomingBucket(from: serverRecord),
               let bucket = try? database.insertOrMergeRemoteBucket(incoming) {
                DispatchQueue.main.async { [weak self] in
                    self?.onRemoteBucketChange(bucket)
                }
            }

        default:
            break
        }
    }

    // MARK: - Record Building

    private func recordForUpload(recordID: CKRecord.ID) -> CKRecord? {
        let recordName = recordID.recordName

        // Clip items use dedupe_key as record name
        if let existing = try? database.fetchClipIDByDedupeKey(recordName),
           let row = try? database.fetchFullClipRow(id: existing.id) {
            return SyncRecordMapper.record(from: row)
        }

        // Bucket records
        if let bucketID = try? database.fetchBucketIDByRecordName(recordName),
           let row = try? database.fetchFullBucketRow(id: bucketID) {
            return SyncRecordMapper.record(from: row)
        }

        // BucketItem records — parse composite record name
        // Format: "bucketRecordName_clipDedupeKey"
        // We need to look up the bucket_item by resolving both parts
        if let bucketItemKeys = try? database.fetchPendingSyncBucketItemKeys() {
            for key in bucketItemKeys {
                if let row = try? database.fetchBucketItemForSync(bucketID: key.bucketID, clipItemID: key.clipItemID) {
                    let expectedName = SyncRecordMapper.bucketItemRecordName(
                        bucketRecordName: row.bucketDedupeKey,
                        clipDedupeKey: row.clipDedupeKey
                    )
                    if expectedName == recordName {
                        return SyncRecordMapper.record(from: row)
                    }
                }
            }
        }

        return nil
    }
}
