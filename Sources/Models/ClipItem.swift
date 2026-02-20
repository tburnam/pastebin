import Foundation

enum ClipContentType: Equatable {
    case text
    case link(URL)

    var label: String {
        switch self {
        case .text:
            return "Text"
        case .link:
            return "Link"
        }
    }
}

struct ClipItem: Identifiable, Equatable {
    let id: Int64
    let content: String
    let copiedAt: Date
    let sourceBundleID: String?
    let sourceAppName: String?
    let customTitle: String?
    let contentType: ClipContentType
    let linkURL: URL?
    let linkDisplayText: String?
    let searchableContent: String
    let characterCount: Int
    let previewText: String

    init(
        id: Int64,
        content: String,
        copiedAt: Date,
        sourceBundleID: String?,
        sourceAppName: String?,
        customTitle: String? = nil
    ) {
        self.id = id
        self.content = content
        self.copiedAt = copiedAt
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.customTitle = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedLink = Self.detectLinkURL(from: trimmed)
        self.contentType = detectedLink.map { .link($0) } ?? .text
        self.linkURL = detectedLink
        self.linkDisplayText = detectedLink.map(Self.linkDisplayText(for:))

        self.searchableContent = ([content, self.customTitle].compactMap { $0 })
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        self.characterCount = content.count

        let collapsed = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let previewBase = linkDisplayText ?? collapsed
        self.previewText = previewBase.count > 220 ? String(previewBase.prefix(217)) + "..." : previewBase
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

    private static let surroundingPunctuation = CharacterSet(charactersIn: "<>[](){}\"'`.,;:!?")

    private static func detectLinkURL(from text: String) -> URL? {
        guard !text.isEmpty else { return nil }

        let candidate = text.trimmingCharacters(in: surroundingPunctuation)
        guard !candidate.isEmpty else { return nil }
        guard candidate.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }

        if let detected = dataDetectedURL(in: candidate) {
            return detected
        }

        guard !candidate.contains("://") else {
            return nil
        }

        // Treat plain `foo@bar.com`-style values as text, not links.
        guard !candidate.contains("@"),
              let prefixed = URL(string: "https://\(candidate)") else {
            return nil
        }

        return isWebURL(prefixed) ? prefixed : nil
    }

    private static func dataDetectedURL(in candidate: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }

        let range = NSRange(location: 0, length: candidate.utf16.count)
        guard let match = detector.firstMatch(in: candidate, options: [], range: range),
              match.range.location == range.location,
              match.range.length == range.length,
              let url = match.url,
              isWebURL(url) else {
            return nil
        }

        return url
    }

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

    private static let hostLabelAllowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))

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
