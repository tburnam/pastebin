import CloudKit
import Foundation

enum SyncConstants {
    static let containerIdentifier = "iCloud.io.github.tylerburnam.pastebin"
    static let zoneName = "PasteBinSync"

    static let clipItemRecordType = "ClipItem"
    static let bucketRecordType = "Bucket"
    static let bucketItemRecordType = "BucketItem"

    static let container = CKContainer(identifier: containerIdentifier)

    static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

    static var assetTempDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PasteBinSyncAssets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var deviceID: String {
        let key = "pastebin.sync.device_id"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    enum ClipFields {
        static let content = "content"
        static let copiedAt = "copiedAt"
        static let sourceBundleID = "sourceBundleID"
        static let sourceAppName = "sourceAppName"
        static let contentType = "contentType"
        static let linkURL = "linkURL"
        static let codeLanguage = "codeLanguage"
        static let structuredFormat = "structuredFormat"
        static let filePathsJSON = "filePathsJSON"
        static let imageWidth = "imageWidth"
        static let imageHeight = "imageHeight"
        static let payloadAsset = "payloadAsset"
        static let rtfAsset = "rtfAsset"
        static let htmlContent = "htmlContent"
        static let dedupeKey = "dedupeKey"
        static let deviceID = "deviceID"
    }

    enum BucketFields {
        static let name = "name"
        static let colorHex = "colorHex"
        static let createdAt = "createdAt"
    }

    enum BucketItemFields {
        static let bucketRecordName = "bucketRecordName"
        static let clipRecordName = "clipRecordName"
        static let customTitle = "customTitle"
        static let addedAt = "addedAt"
    }
}
