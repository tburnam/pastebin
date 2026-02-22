import Foundation

enum StructuredContentFormat: String, Equatable, Codable {
    case json
    case xml
    case csv

    var label: String {
        rawValue.uppercased()
    }
}

enum ClipContentType: Equatable {
    case text
    case link(URL)
    case code(language: String?)
    case image
    case fileList
    case richText
    case structured(format: StructuredContentFormat)

    var label: String {
        switch self {
        case .text:
            return "Text"
        case .link:
            return "Link"
        case .code:
            return "Code"
        case .image:
            return "Image"
        case .fileList:
            return "File"
        case .richText:
            return "Text"
        case .structured(let format):
            return format.label
        }
    }

    var storageValue: String {
        switch self {
        case .text:
            return "text"
        case .link:
            return "link"
        case .code:
            return "code"
        case .image:
            return "image"
        case .fileList:
            return "file_list"
        case .richText:
            return "rich_text"
        case .structured:
            return "structured"
        }
    }
}

struct ClipItem: Identifiable, Equatable {
    private static let previewCharacterLimit = 420

    let id: Int64
    let content: String
    let copiedAt: Date
    let sourceBundleID: String?
    let sourceAppName: String?
    let customTitle: String?
    let contentType: ClipContentType
    let linkURL: URL?
    let linkDisplayText: String?
    let codeLanguage: String?
    let structuredFormat: StructuredContentFormat?
    let filePaths: [String]
    let imageWidth: Int?
    let imageHeight: Int?
    let payloadData: Data?
    let rtfData: Data?
    let htmlContent: String?
    let dedupeKey: String
    let searchableContent: String
    let characterCount: Int
    let previewText: String

    init(
        id: Int64,
        content: String,
        copiedAt: Date,
        sourceBundleID: String?,
        sourceAppName: String?,
        customTitle: String? = nil,
        contentTypeRaw: String? = nil,
        linkURLString: String? = nil,
        codeLanguage: String? = nil,
        structuredFormatRaw: String? = nil,
        filePathsJSON: String? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        payloadData: Data? = nil,
        rtfData: Data? = nil,
        htmlContent: String? = nil,
        dedupeKey: String? = nil
    ) {
        self.id = id
        self.content = content
        self.copiedAt = copiedAt
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.customTitle = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.payloadData = payloadData
        self.rtfData = rtfData
        self.htmlContent = htmlContent

        let normalizedRawType = contentTypeRaw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resolvedStructuredFormat = structuredFormatRaw.flatMap {
            StructuredContentFormat(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        let resolvedCodeLanguage = Self.normalizedCodeLanguage(codeLanguage)

        let decodedFilePaths = Self.decodeFilePaths(from: filePathsJSON)
        if decodedFilePaths.isEmpty {
            self.filePaths = Self.filePathsFromLegacyContent(content, rawType: normalizedRawType)
        } else {
            self.filePaths = decodedFilePaths
        }

        let resolvedLinkURL = Self.resolveLinkURL(linkURLString: linkURLString)
        self.linkURL = resolvedLinkURL
        self.linkDisplayText = resolvedLinkURL.map(Self.linkDisplayText(for:))

        self.codeLanguage = resolvedCodeLanguage
        self.structuredFormat = resolvedStructuredFormat
        self.contentType = Self.resolveContentType(
            rawType: normalizedRawType,
            linkURL: resolvedLinkURL,
            codeLanguage: resolvedCodeLanguage,
            structuredFormat: resolvedStructuredFormat,
            hasFilePaths: !self.filePaths.isEmpty
        )

        let normalizedDedupeKey = dedupeKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dedupeKey = (normalizedDedupeKey?.isEmpty == false) ? normalizedDedupeKey! : content

        self.searchableContent = ([content, self.customTitle].compactMap { $0 })
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        self.characterCount = content.count

        let previewBase = Self.previewBase(
            content: content,
            contentType: self.contentType,
            linkDisplayText: self.linkDisplayText,
            filePaths: self.filePaths,
            imageWidth: self.imageWidth,
            imageHeight: self.imageHeight
        )
        self.previewText = Self.truncatedPreview(previewBase)
    }

    var typeLabel: String {
        contentType.label
    }

    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty {
            return customTitle
        }
        return typeLabel
    }

    var imageDimensionsText: String? {
        guard let imageWidth, let imageHeight else { return nil }
        return "\(imageWidth)x\(imageHeight)"
    }

    var codeLanguageLabel: String? {
        guard let codeLanguage, !codeLanguage.isEmpty else { return nil }
        return codeLanguage.uppercased()
    }

    var structuredFormatLabel: String? {
        structuredFormat?.label
    }

    func withCustomTitle(_ customTitle: String?) -> ClipItem {
        ClipItem(
            id: id,
            content: content,
            copiedAt: copiedAt,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            customTitle: customTitle,
            contentTypeRaw: contentType.storageValue,
            linkURLString: linkURL?.absoluteString,
            codeLanguage: codeLanguage,
            structuredFormatRaw: structuredFormat?.rawValue,
            filePathsJSON: Self.encodeFilePaths(filePaths),
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            payloadData: payloadData,
            rtfData: rtfData,
            htmlContent: htmlContent,
            dedupeKey: dedupeKey
        )
    }

    static func encodeFilePaths(_ filePaths: [String]) -> String? {
        guard !filePaths.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(filePaths) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeFilePaths(from json: String?) -> [String] {
        guard let json, !json.isEmpty else { return [] }
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }

    static func normalizedCodeLanguage(_ rawLanguage: String?) -> String? {
        guard let rawLanguage else { return nil }
        let normalized = rawLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        switch normalized {
        case "js", "javascript":
            return "javascript"
        case "ts", "typescript":
            return "typescript"
        case "py", "python":
            return "python"
        case "sh", "bash", "zsh", "shell":
            return "shell"
        case "swift":
            return "swift"
        case "sql":
            return "sql"
        case "go":
            return "go"
        case "rb", "ruby":
            return "ruby"
        case "java":
            return "java"
        case "c", "cpp", "c++", "objc", "objective-c":
            return "c-family"
        default:
            return normalized
        }
    }

    private static func resolveContentType(
        rawType: String?,
        linkURL: URL?,
        codeLanguage: String?,
        structuredFormat: StructuredContentFormat?,
        hasFilePaths: Bool
    ) -> ClipContentType {
        switch rawType {
        case "link":
            if let linkURL {
                return .link(linkURL)
            }
            return .text

        case "code":
            return .code(language: codeLanguage)

        case "image":
            return .image

        case "file_list":
            return .fileList

        case "rich_text":
            return .richText

        case "structured":
            if let structuredFormat {
                return .structured(format: structuredFormat)
            }
            return .text

        default:
            if let linkURL {
                return .link(linkURL)
            }
            if hasFilePaths {
                return .fileList
            }
            return .text
        }
    }

    private static func resolveLinkURL(linkURLString: String?) -> URL? {
        guard let linkURLString, !linkURLString.isEmpty else { return nil }
        guard let url = URL(string: linkURLString), isWebURL(url) else { return nil }
        return url
    }

    private static func previewBase(
        content: String,
        contentType: ClipContentType,
        linkDisplayText: String?,
        filePaths: [String],
        imageWidth: Int?,
        imageHeight: Int?
    ) -> String {
        let collapsed = compactPreview(content)

        switch contentType {
        case .link:
            return linkDisplayText ?? collapsed

        case .image:
            if let imageWidth, let imageHeight {
                return "Image \(imageWidth)x\(imageHeight)"
            }
            return "Image"

        case .fileList:
            if let first = filePaths.first {
                let fileName = URL(fileURLWithPath: first).lastPathComponent
                if filePaths.count == 1 {
                    return fileName
                }
                return "\(fileName) +\(filePaths.count - 1) more"
            }
            return collapsed

        case .code(let language):
            if let language {
                return "\(language.uppercased()) code"
            }
            return "Code snippet"

        case .richText:
            return collapsed.isEmpty ? "Text content" : collapsed

        case .structured(let format):
            return "\(format.label) content"

        case .text:
            return collapsed
        }
    }

    private static func truncatedPreview(_ value: String) -> String {
        value.count > previewCharacterLimit
            ? String(value.prefix(previewCharacterLimit - 3)) + "..."
            : value
    }

    private static func compactPreview(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func filePathsFromLegacyContent(_ content: String, rawType: String?) -> [String] {
        guard rawType == "file_list" else { return [] }
        return content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static let hostLabelAllowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }

        guard let host = url.host, !host.isEmpty else {
            return false
        }

        return isLikelyWebHost(host)
    }

    private static func isLikelyWebHost(_ host: String) -> Bool {
        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        guard !normalized.isEmpty else { return false }

        if normalized == "localhost" || isIPv4Address(normalized) || normalized.contains(":") {
            return true
        }

        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        guard labels.allSatisfy({ !$0.isEmpty }) else { return false }

        guard let tld = labels.last, tld.count >= 2 else { return false }
        let tldString = String(tld)
        let isValidTLD = tldString.hasPrefix("xn--")
            || tldString.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
        guard isValidTLD else { return false }

        for label in labels {
            guard let first = label.first, let last = label.last else { return false }
            guard first != "-", last != "-" else { return false }
            guard label.unicodeScalars.allSatisfy({ hostLabelAllowedCharacters.contains($0) }) else { return false }
        }

        return true
    }

    private static func isIPv4Address(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }

        for part in parts {
            guard !part.isEmpty, part.count <= 3 else { return false }
            guard part.allSatisfy(\.isNumber) else { return false }
            guard let octet = Int(part), (0...255).contains(octet) else { return false }
        }

        return true
    }

    private static func linkDisplayText(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        components.scheme = nil
        if components.percentEncodedPath.isEmpty {
            components.percentEncodedPath = "/"
        }

        let withoutScheme = components.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? url.absoluteString
        return withoutScheme.isEmpty ? url.absoluteString : withoutScheme
    }
}
