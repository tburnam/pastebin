import CloudKit
import Combine
import Foundation

final class SyncStatusProvider: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var syncError: String?
    @Published private(set) var accountStatus: CKAccountStatus = .couldNotDetermine

    func updateSyncing(_ syncing: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isSyncing = syncing
            if !syncing {
                self?.lastSyncDate = Date()
            }
        }
    }

    func updateError(_ error: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.syncError = error
        }
    }

    func updateAccountStatus(_ status: CKAccountStatus) {
        DispatchQueue.main.async { [weak self] in
            self?.accountStatus = status
        }
    }
}
