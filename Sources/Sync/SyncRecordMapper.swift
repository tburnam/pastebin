import CloudKit
import Foundation

struct SyncableClipRow {
    let id: Int64
    let content: String
    let copiedAt: Date
    let sourceBundleID: String?
    let sourceAppName: String?
    let contentTypeRaw: String
    let linkURL: String?
    let codeLanguage: String?
    let structuredFormat: String?
    let filePathsJSON: String?
    let imageWidth: Int?
    let imageHeight: Int?
    let payloadData: Data?
    let rtfData: Data?
    let htmlContent: String?
    let dedupeKey: String
    let cloudRecordSystemFields: Data?
}

struct SyncableBucketRow {
    let id: Int64
    let name: String
    let colorHex: String
    let createdAt: Date
    let cloudRecordSystemFields: Data?
}

struct SyncableBucketItemRow {
    let bucketID: Int64
    let clipItemID: Int64
    let customTitle: String?
    let addedAt: Date
    let bucketDedupeKey: String
    let clipDedupeKey: String
    let cloudRecordSystemFields: Data?
}

struct IncomingClipRecord {
    let content: String
    let copiedAt: Date
    let sourceBundleID: String?
    let sourceAppName: String?
    let contentTypeRaw: String
    let linkURL: String?
    let codeLanguage: String?
    let structuredFormat: String?
    let filePathsJSON: String?
    let imageWidth: Int?
    let imageHeight: Int?
    let payloadData: Data?
    let rtfData: Data?
    let htmlContent: String?
    let dedupeKey: String
    let systemFieldsData: Data
}

struct IncomingBucketRecord {
    let name: String
    let colorHex: String
    let createdAt: Date
    let recordName: String
    let systemFieldsData: Data
}

struct IncomingBucketItemRecord {
    let bucketRecordName: String
    let clipRecordName: String
    let customTitle: String?
    let addedAt: Date
    let systemFieldsData: Data
}

enum SyncRecordMapper {

    // MARK: - ClipItem -> CKRecord

    static func record(from row: SyncableClipRow) -> CKRecord {
        let record: CKRecord
        if let systemData = row.cloudRecordSystemFields {
            record = decodeRecord(from: systemData)
                ?? CKRecord(recordType: SyncConstants.clipItemRecordType, recordID: clipRecordID(dedupeKey: row.dedupeKey))
        } else {
            record = CKRecord(recordType: SyncConstants.clipItemRecordType, recordID: clipRecordID(dedupeKey: row.dedupeKey))
        }

        record[SyncConstants.ClipFields.content] = row.content as CKRecordValue
        record[SyncConstants.ClipFields.copiedAt] = row.copiedAt as CKRecordValue
        record[SyncConstants.ClipFields.sourceBundleID] = row.sourceBundleID as CKRecordValue?
        record[SyncConstants.ClipFields.sourceAppName] = row.sourceAppName as CKRecordValue?
        record[SyncConstants.ClipFields.contentType] = row.contentTypeRaw as CKRecordValue
        record[SyncConstants.ClipFields.linkURL] = row.linkURL as CKRecordValue?
        record[SyncConstants.ClipFields.codeLanguage] = row.codeLanguage as CKRecordValue?
        record[SyncConstants.ClipFields.structuredFormat] = row.structuredFormat as CKRecordValue?
        record[SyncConstants.ClipFields.filePathsJSON] = row.filePathsJSON as CKRecordValue?
        record[SyncConstants.ClipFields.imageWidth] = row.imageWidth.map { $0 as NSNumber } as CKRecordValue?
        record[SyncConstants.ClipFields.imageHeight] = row.imageHeight.map { $0 as NSNumber } as CKRecordValue?
        record[SyncConstants.ClipFields.htmlContent] = row.htmlContent as CKRecordValue?
        record[SyncConstants.ClipFields.dedupeKey] = row.dedupeKey as CKRecordValue
        record[SyncConstants.ClipFields.deviceID] = SyncConstants.deviceID as CKRecordValue

        if let payloadData = row.payloadData {
            record[SyncConstants.ClipFields.payloadAsset] = writeAsset(data: payloadData, name: "payload")
        }
        if let rtfData = row.rtfData {
            record[SyncConstants.ClipFields.rtfAsset] = writeAsset(data: rtfData, name: "rtf")
        }

        return record
    }

    // MARK: - CKRecord -> IncomingClipRecord

    static func incomingClip(from record: CKRecord) -> IncomingClipRecord? {
        guard record.recordType == SyncConstants.clipItemRecordType else { return nil }

        let content = record[SyncConstants.ClipFields.content] as? String ?? ""
        let copiedAt = record[SyncConstants.ClipFields.copiedAt] as? Date ?? record.creationDate ?? Date()
        let dedupeKey = record[SyncConstants.ClipFields.dedupeKey] as? String ?? record.recordID.recordName

        var payloadData: Data?
        if let asset = record[SyncConstants.ClipFields.payloadAsset] as? CKAsset, let url = asset.fileURL {
            payloadData = try? Data(contentsOf: url)
        }

        var rtfData: Data?
        if let asset = record[SyncConstants.ClipFields.rtfAsset] as? CKAsset, let url = asset.fileURL {
            rtfData = try? Data(contentsOf: url)
        }

        return IncomingClipRecord(
            content: content,
            copiedAt: copiedAt,
            sourceBundleID: record[SyncConstants.ClipFields.sourceBundleID] as? String,
            sourceAppName: record[SyncConstants.ClipFields.sourceAppName] as? String,
            contentTypeRaw: record[SyncConstants.ClipFields.contentType] as? String ?? "text",
            linkURL: record[SyncConstants.ClipFields.linkURL] as? String,
            codeLanguage: record[SyncConstants.ClipFields.codeLanguage] as? String,
            structuredFormat: record[SyncConstants.ClipFields.structuredFormat] as? String,
            filePathsJSON: record[SyncConstants.ClipFields.filePathsJSON] as? String,
            imageWidth: (record[SyncConstants.ClipFields.imageWidth] as? NSNumber)?.intValue,
            imageHeight: (record[SyncConstants.ClipFields.imageHeight] as? NSNumber)?.intValue,
            payloadData: payloadData,
            rtfData: rtfData,
            htmlContent: record[SyncConstants.ClipFields.htmlContent] as? String,
            dedupeKey: dedupeKey,
            systemFieldsData: encodeSystemFields(of: record)
        )
    }

    // MARK: - Bucket -> CKRecord

    static func record(from bucket: SyncableBucketRow) -> CKRecord {
        let rn = bucketRecordName(name: bucket.name, createdAt: bucket.createdAt)
        let recordID = bucketRecordID(recordName: rn)
        let record: CKRecord
        if let systemData = bucket.cloudRecordSystemFields {
            record = decodeRecord(from: systemData) ?? CKRecord(recordType: SyncConstants.bucketRecordType, recordID: recordID)
        } else {
            record = CKRecord(recordType: SyncConstants.bucketRecordType, recordID: recordID)
        }

        record[SyncConstants.BucketFields.name] = bucket.name as CKRecordValue
        record[SyncConstants.BucketFields.colorHex] = bucket.colorHex as CKRecordValue
        record[SyncConstants.BucketFields.createdAt] = bucket.createdAt as CKRecordValue

        return record
    }

    // MARK: - CKRecord -> IncomingBucketRecord

    static func incomingBucket(from record: CKRecord) -> IncomingBucketRecord? {
        guard record.recordType == SyncConstants.bucketRecordType else { return nil }

        return IncomingBucketRecord(
            name: record[SyncConstants.BucketFields.name] as? String ?? "Untitled",
            colorHex: record[SyncConstants.BucketFields.colorHex] as? String ?? BucketDefaults.defaultColorHex,
            createdAt: record[SyncConstants.BucketFields.createdAt] as? Date ?? record.creationDate ?? Date(),
            recordName: record.recordID.recordName,
            systemFieldsData: encodeSystemFields(of: record)
        )
    }

    // MARK: - BucketItem -> CKRecord

    static func record(from item: SyncableBucketItemRow) -> CKRecord {
        let recordName = "\(item.bucketDedupeKey)_\(item.clipDedupeKey)"
        let recordID = CKRecord.ID(recordName: recordName, zoneID: SyncConstants.zoneID)
        let record: CKRecord
        if let systemData = item.cloudRecordSystemFields {
            record = decodeRecord(from: systemData) ?? CKRecord(recordType: SyncConstants.bucketItemRecordType, recordID: recordID)
        } else {
            record = CKRecord(recordType: SyncConstants.bucketItemRecordType, recordID: recordID)
        }

        record[SyncConstants.BucketItemFields.bucketRecordName] = item.bucketDedupeKey as CKRecordValue
        record[SyncConstants.BucketItemFields.clipRecordName] = item.clipDedupeKey as CKRecordValue
        record[SyncConstants.BucketItemFields.customTitle] = item.customTitle as CKRecordValue?
        record[SyncConstants.BucketItemFields.addedAt] = item.addedAt as CKRecordValue

        return record
    }

    // MARK: - CKRecord -> IncomingBucketItemRecord

    static func incomingBucketItem(from record: CKRecord) -> IncomingBucketItemRecord? {
        guard record.recordType == SyncConstants.bucketItemRecordType else { return nil }

        return IncomingBucketItemRecord(
            bucketRecordName: record[SyncConstants.BucketItemFields.bucketRecordName] as? String ?? "",
            clipRecordName: record[SyncConstants.BucketItemFields.clipRecordName] as? String ?? "",
            customTitle: record[SyncConstants.BucketItemFields.customTitle] as? String,
            addedAt: record[SyncConstants.BucketItemFields.addedAt] as? Date ?? Date(),
            systemFieldsData: encodeSystemFields(of: record)
        )
    }

    // MARK: - Record IDs

    static func clipRecordID(dedupeKey: String) -> CKRecord.ID {
        CKRecord.ID(recordName: dedupeKey, zoneID: SyncConstants.zoneID)
    }

    static func bucketRecordName(name: String, createdAt: Date) -> String {
        "bucket_\(name)_\(Int(createdAt.timeIntervalSince1970))"
    }

    static func bucketRecordID(recordName: String) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: SyncConstants.zoneID)
    }

    static func bucketItemRecordName(bucketRecordName: String, clipDedupeKey: String) -> String {
        "\(bucketRecordName)_\(clipDedupeKey)"
    }

    static func bucketItemRecordID(recordName: String) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: SyncConstants.zoneID)
    }

    // MARK: - System Fields Encoding

    static func encodeSystemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func decodeRecord(from data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        let record = CKRecord(coder: coder)
        coder.finishDecoding()
        return record
    }

    // MARK: - Asset Helpers

    private static func writeAsset(data: Data, name: String) -> CKAsset {
        let fileName = "\(name)_\(UUID().uuidString)"
        let fileURL = SyncConstants.assetTempDirectory.appendingPathComponent(fileName)
        try? data.write(to: fileURL)
        return CKAsset(fileURL: fileURL)
    }

    static func cleanupTempAssets() {
        let dir = SyncConstants.assetTempDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in contents {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
