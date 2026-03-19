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
    static func == (lhs: ClipItem, rhs: ClipItem) -> Bool {
        lhs.id == rhs.id && lhs.copiedAt == rhs.copiedAt && lhs.customTitle == rhs.customTitle
    }

    private static let previewCharacterLimit = 420
    private static let compactPreviewInputLimit = 2_048
    private static let snippetLineLimit = 6

    let id: Int64
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
    let dedupeKey: String
    let searchableContentUTF8: ContiguousArray<UInt8>
    let searchableFingerprint: SearchFingerprint
    let hasSearchableOverflow: Bool
    let characterCount: Int
    let previewText: String
    let snippetPreview: String
    let codeSnippetText: String
    let structuredSnippetText: String
    let hasPayloadData: Bool
    let hasRTFData: Bool
    let hasHTMLContent: Bool

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
        hasPayloadData: Bool = false,
        hasRTFData: Bool = false,
        hasHTMLContent: Bool = false,
        dedupeKey: String? = nil,
        characterCount: Int? = nil
    ) {
        self.id = id
        self.copiedAt = copiedAt
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.customTitle = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.hasPayloadData = hasPayloadData
        self.hasRTFData = hasRTFData
        self.hasHTMLContent = hasHTMLContent

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

        // Snippet preview: bounded prefix for code/JSON card display.
        let snippetPreview = ClipboardContentLimits.truncateUTF8PreservingScalarBoundaries(
            content,
            to: ClipboardContentLimits.maxSnippetPreviewUTF8Bytes
        )
        self.snippetPreview = snippetPreview
        let codeSnippetText = Self.boundedSnippet(from: snippetPreview, maxLines: Self.snippetLineLimit)
        self.codeSnippetText = codeSnippetText
        self.structuredSnippetText = Self.structuredSnippet(
            from: snippetPreview,
            format: resolvedStructuredFormat,
            fallback: codeSnippetText
        )

        let normalizedDedupeKey = dedupeKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dedupeKey = (normalizedDedupeKey?.isEmpty == false) ? normalizedDedupeKey! : self.snippetPreview

        let searchableSource = ([content, self.customTitle].compactMap { $0 })
            .joined(separator: " ")
        let searchInput = ClipboardContentLimits.truncateUTF8PreservingScalarBoundaries(
            searchableSource,
            to: ClipboardContentLimits.maxSearchableTextUTF8Bytes
        )
        let searchable = searchInput
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        self.searchableContentUTF8 = ContiguousArray(searchable.utf8)
        self.searchableFingerprint = SearchFingerprint(bytes: self.searchableContentUTF8)
        self.characterCount = characterCount ?? content.count
        self.hasSearchableOverflow = searchableSource.utf8.count > ClipboardContentLimits.maxSearchableTextUTF8Bytes
            || self.characterCount > searchInput.count

        // Truncate input before running compactPreview to avoid O(n) on huge strings
        let previewInput = ClipboardContentLimits.truncateUTF8PreservingScalarBoundaries(
            content,
            to: Self.compactPreviewInputLimit
        )
        let previewBase = Self.previewBase(
            content: previewInput,
            contentType: self.contentType,
            linkDisplayText: self.linkDisplayText,
            filePaths: self.filePaths,
            imageWidth: self.imageWidth,
            imageHeight: self.imageHeight
        )
        self.previewText = Self.truncatedPreview(previewBase)
    }

    /// Clone helper: create a promoted copy with a new copiedAt date.
    /// Copies all pre-computed fields directly without re-processing content.
    func promoted(at date: Date) -> ClipItem {
        ClipItem(
            id: id,
            copiedAt: date,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            customTitle: customTitle,
            contentType: contentType,
            linkURL: linkURL,
            linkDisplayText: linkDisplayText,
            codeLanguage: codeLanguage,
            structuredFormat: structuredFormat,
            filePaths: filePaths,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            dedupeKey: dedupeKey,
            searchableContentUTF8: searchableContentUTF8,
            searchableFingerprint: searchableFingerprint,
            hasSearchableOverflow: hasSearchableOverflow,
            characterCount: characterCount,
            previewText: previewText,
            snippetPreview: snippetPreview,
            codeSnippetText: codeSnippetText,
            structuredSnippetText: structuredSnippetText,
            hasPayloadData: hasPayloadData,
            hasRTFData: hasRTFData,
            hasHTMLContent: hasHTMLContent
        )
    }

    /// Clone helper: create a copy with a different custom title.
    /// Copies all pre-computed fields directly without re-processing content.
    func withCustomTitle(_ customTitle: String?) -> ClipItem {
        let normalized = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClipItem(
            id: id,
            copiedAt: copiedAt,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            customTitle: normalized,
            contentType: contentType,
            linkURL: linkURL,
            linkDisplayText: linkDisplayText,
            codeLanguage: codeLanguage,
            structuredFormat: structuredFormat,
            filePaths: filePaths,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            dedupeKey: dedupeKey,
            searchableContentUTF8: searchableContentUTF8,
            searchableFingerprint: searchableFingerprint,
            hasSearchableOverflow: hasSearchableOverflow,
            characterCount: characterCount,
            previewText: previewText,
            snippetPreview: snippetPreview,
            codeSnippetText: codeSnippetText,
            structuredSnippetText: structuredSnippetText,
            hasPayloadData: hasPayloadData,
            hasRTFData: hasRTFData,
            hasHTMLContent: hasHTMLContent
        )
    }

    /// Private memberwise init for clone helpers — avoids re-deriving everything.
    private init(
        id: Int64,
        copiedAt: Date,
        sourceBundleID: String?,
        sourceAppName: String?,
        customTitle: String?,
        contentType: ClipContentType,
        linkURL: URL?,
        linkDisplayText: String?,
        codeLanguage: String?,
        structuredFormat: StructuredContentFormat?,
        filePaths: [String],
        imageWidth: Int?,
        imageHeight: Int?,
        dedupeKey: String,
        searchableContentUTF8: ContiguousArray<UInt8>,
        searchableFingerprint: SearchFingerprint,
        hasSearchableOverflow: Bool,
        characterCount: Int,
        previewText: String,
        snippetPreview: String,
        codeSnippetText: String,
        structuredSnippetText: String,
        hasPayloadData: Bool,
        hasRTFData: Bool,
        hasHTMLContent: Bool
    ) {
        self.id = id
        self.copiedAt = copiedAt
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.customTitle = customTitle
        self.contentType = contentType
        self.linkURL = linkURL
        self.linkDisplayText = linkDisplayText
        self.codeLanguage = codeLanguage
        self.structuredFormat = structuredFormat
        self.filePaths = filePaths
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.dedupeKey = dedupeKey
        self.searchableContentUTF8 = searchableContentUTF8
        self.searchableFingerprint = searchableFingerprint
        self.hasSearchableOverflow = hasSearchableOverflow
        self.characterCount = characterCount
        self.previewText = previewText
        self.snippetPreview = snippetPreview
        self.codeSnippetText = codeSnippetText
        self.structuredSnippetText = structuredSnippetText
        self.hasPayloadData = hasPayloadData
        self.hasRTFData = hasRTFData
        self.hasHTMLContent = hasHTMLContent
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

    static func resolveLinkURL(linkURLString: String?) -> URL? {
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
        // O(1) fast path: UTF8 byte count is an upper bound on character count
        if value.utf8.count <= previewCharacterLimit {
            return value
        }
        // O(k) check instead of O(n) count for long strings
        guard let _ = value.index(value.startIndex, offsetBy: previewCharacterLimit, limitedBy: value.endIndex) else {
            return value
        }
        return String(value.prefix(previewCharacterLimit - 3)) + "..."
    }

    private static func compactPreview(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var collapsed = String()
        collapsed.reserveCapacity(min(trimmed.count, previewCharacterLimit + 10))

        var lastWasWhitespace = false
        var outputCount = 0
        for scalar in trimmed.unicodeScalars {
            if outputCount > previewCharacterLimit {
                break
            }

            let v = scalar.value
            // ASCII fast path avoids CharacterSet lookup for the common case
            let isWS: Bool
            if v <= 0x20 {
                isWS = v == 0x20 || (v >= 0x09 && v <= 0x0D)
            } else if v < 0x80 {
                isWS = false
            } else {
                isWS = CharacterSet.whitespacesAndNewlines.contains(scalar)
            }
            if isWS {
                if !lastWasWhitespace {
                    collapsed.append(" ")
                    outputCount += 1
                    lastWasWhitespace = true
                }
                continue
            }

            collapsed.unicodeScalars.append(scalar)
            outputCount += 1
            lastWasWhitespace = false
        }

        return collapsed
    }

    private static func structuredSnippet(
        from snippetPreview: String,
        format: StructuredContentFormat?,
        fallback: String
    ) -> String {
        guard let format else { return fallback }

        switch format {
        case .json:
            guard snippetPreview.utf8.count <= ClipboardContentLimits.maxJSONPreviewUTF8Bytes,
                  let data = snippetPreview.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: []),
                  let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
                  let prettyString = String(data: pretty, encoding: .utf8) else {
                return fallback
            }
            return boundedSnippet(from: prettyString, maxLines: snippetLineLimit)

        case .xml, .csv:
            return fallback
        }
    }

    private static func boundedSnippet(from value: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }

        let limitedInput = ClipboardContentLimits
            .truncateUTF8PreservingScalarBoundaries(value, to: ClipboardContentLimits.maxRenderedSnippetUTF8Bytes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limitedInput.isEmpty else { return "" }

        var snippet = String()
        snippet.reserveCapacity(min(limitedInput.count, ClipboardContentLimits.maxRenderedSnippetCharacters))
        var lineCount = 1
        var characterCount = 0

        for character in limitedInput {
            if lineCount > maxLines {
                break
            }

            if characterCount >= ClipboardContentLimits.maxRenderedSnippetCharacters {
                break
            }

            snippet.append(character)
            characterCount += 1

            if character == "\n" {
                lineCount += 1
                if lineCount > maxLines {
                    break
                }
            }
        }

        return snippet.trimmingCharacters(in: .whitespacesAndNewlines)
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
