import Foundation

struct CapturedClipboardItem {
    let content: String
    let contentTypeRaw: String
    let linkURL: String?
    let codeLanguage: String?
    let structuredFormatRaw: String?
    let filePaths: [String]
    let imageWidth: Int?
    let imageHeight: Int?
    let payloadData: Data?
    let rtfData: Data?
    let htmlContent: String?
    let dedupeKey: String
    let sourceBundleID: String?
    let sourceAppName: String?

    init(
        content: String,
        contentTypeRaw: String,
        linkURL: String? = nil,
        codeLanguage: String? = nil,
        structuredFormatRaw: String? = nil,
        filePaths: [String] = [],
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        payloadData: Data? = nil,
        rtfData: Data? = nil,
        htmlContent: String? = nil,
        dedupeKey: String,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil
    ) {
        self.content = content
        self.contentTypeRaw = contentTypeRaw
        self.linkURL = linkURL
        self.codeLanguage = codeLanguage
        self.structuredFormatRaw = structuredFormatRaw
        self.filePaths = filePaths
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.payloadData = payloadData
        self.rtfData = rtfData
        self.htmlContent = htmlContent
        self.dedupeKey = dedupeKey
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
    }

    func withSource(bundleID: String?, appName: String?) -> CapturedClipboardItem {
        CapturedClipboardItem(
            content: content,
            contentTypeRaw: contentTypeRaw,
            linkURL: linkURL,
            codeLanguage: codeLanguage,
            structuredFormatRaw: structuredFormatRaw,
            filePaths: filePaths,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            payloadData: payloadData,
            rtfData: rtfData,
            htmlContent: htmlContent,
            dedupeKey: dedupeKey,
            sourceBundleID: bundleID,
            sourceAppName: appName
        )
    }
}
