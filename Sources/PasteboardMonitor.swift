import AppKit
import CryptoKit
import Foundation

final class PasteboardMonitor {
    var onCapture: ((CapturedClipboardItem) -> Void)?

    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int
    private var shouldSuppressNextChange = false
    private var lastDeliveredSignature: String?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }

        let pollInterval: TimeInterval = 0.30
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
        timer.tolerance = pollInterval * 0.4

        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func suppressNextCapture() {
        shouldSuppressNextChange = true
    }

    private func pollPasteboard() {
        guard pasteboard.changeCount != lastChangeCount else {
            return
        }

        lastChangeCount = pasteboard.changeCount

        if shouldSuppressNextChange {
            shouldSuppressNextChange = false
            return
        }

        guard let captured = readCapturedItem(from: pasteboard) else {
            return
        }

        guard captured.dedupeKey != lastDeliveredSignature else { return }
        lastDeliveredSignature = captured.dedupeKey

        let sourceApp = NSWorkspace.shared.frontmostApplication
        onCapture?(captured.withSource(bundleID: sourceApp?.bundleIdentifier, appName: sourceApp?.localizedName))
    }

    private func readCapturedItem(from pasteboard: NSPasteboard) -> CapturedClipboardItem? {
        if let fileCapture = captureFileList(from: pasteboard) {
            return fileCapture
        }

        if let imageCapture = captureImage(from: pasteboard) {
            return imageCapture
        }

        if let textCapture = captureTextualContent(from: pasteboard) {
            return textCapture
        }

        if let availableType = pasteboard.types?.first?.rawValue {
            let placeholder = "[Clipboard data: \(availableType)]"
            return CapturedClipboardItem(
                content: placeholder,
                contentTypeRaw: "text",
                dedupeKey: dedupeKey(prefix: "typed", from: Data(availableType.utf8))
            )
        }

        return nil
    }

    private func captureFileList(from pasteboard: NSPasteboard) -> CapturedClipboardItem? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return nil
        }

        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return nil }

        let filePaths = fileURLs.map(\.path)
        let content = filePaths.joined(separator: "\n")
        let seed = ClipboardContentLimits.dedupeSeed(forText: filePaths.joined(separator: "|"))

        return CapturedClipboardItem(
            content: content,
            contentTypeRaw: "file_list",
            filePaths: filePaths,
            dedupeKey: dedupeKey(prefix: "files", from: seed)
        )
    }

    private func captureImage(from pasteboard: NSPasteboard) -> CapturedClipboardItem? {
        guard let image = NSImage(pasteboard: pasteboard) else { return nil }
        guard let payloadData = image.tiffRepresentation ?? pasteboard.data(forType: .tiff) else { return nil }

        let width = max(1, Int(image.size.width.rounded()))
        let height = max(1, Int(image.size.height.rounded()))
        let payloadSize = payloadData.count

        if payloadSize > ClipboardContentLimits.maxImagePayloadBytes {
            let description = "[Large image clip skipped: \(width)x\(height), \(ClipboardContentLimits.byteCountLabel(payloadSize)) exceeds \(ClipboardContentLimits.byteCountLabel(ClipboardContentLimits.maxImagePayloadBytes)) limit]"
            return CapturedClipboardItem(
                content: description,
                contentTypeRaw: "text",
                dedupeKey: dedupeKey(prefix: "image_skipped", from: ClipboardContentLimits.dedupeSeed(forText: description))
            )
        }

        return CapturedClipboardItem(
            content: "[Image \(width)x\(height)]",
            contentTypeRaw: "image",
            imageWidth: width,
            imageHeight: height,
            payloadData: payloadData,
            dedupeKey: dedupeKey(prefix: "image", from: payloadData)
        )
    }

    private func captureTextualContent(from pasteboard: NSPasteboard) -> CapturedClipboardItem? {
        let typeIdentifiers = pasteboardTypeIdentifiers(from: pasteboard)
        let plainString = plainString(from: pasteboard)
        var rtfData: Data?
        var htmlContent: String?
        var didLoadRichPayloads = false
        var oversizedRichPayloads: [String] = []

        func loadRichPayloadsIfNeeded() {
            guard !didLoadRichPayloads else { return }
            if let rawRTFData = pasteboard.data(forType: .rtf) {
                if rawRTFData.count <= ClipboardContentLimits.maxRichPayloadBytes {
                    rtfData = rawRTFData
                } else {
                    oversizedRichPayloads.append("RTF \(ClipboardContentLimits.byteCountLabel(rawRTFData.count))")
                }
            }
            if let rawHTMLContent = pasteboard.string(forType: .html) {
                let htmlByteCount = rawHTMLContent.utf8.count
                if htmlByteCount <= ClipboardContentLimits.maxRichPayloadBytes {
                    htmlContent = rawHTMLContent
                } else {
                    oversizedRichPayloads.append("HTML \(ClipboardContentLimits.byteCountLabel(htmlByteCount))")
                }
            }
            didLoadRichPayloads = true
        }

        var richTextPlainCache: String?
        var didResolveRichTextPlain = false
        func richTextPlain() -> String? {
            if didResolveRichTextPlain {
                return richTextPlainCache
            }

            didResolveRichTextPlain = true
            loadRichPayloadsIfNeeded()
            richTextPlainCache = plainTextFromRTF(rtfData) ?? plainTextFromHTML(htmlContent)
            return richTextPlainCache
        }

        var linkURLCache: URL?
        var didResolveLinkURL = false
        func clipboardLinkURL() -> URL? {
            if didResolveLinkURL {
                return linkURLCache
            }

            didResolveLinkURL = true
            linkURLCache = firstNonFileURL(from: pasteboard)
            return linkURLCache
        }

        let candidate = plainString ?? richTextPlain()

        guard let candidate else {
            if let linkURL = clipboardLinkURL() {
                return CapturedClipboardItem(
                    content: linkURL.absoluteString,
                    contentTypeRaw: "link",
                    linkURL: linkURL.absoluteString,
                    dedupeKey: dedupeKey(
                        prefix: "link",
                        from: ClipboardContentLimits.dedupeSeed(forText: linkURL.absoluteString)
                    )
                )
            }

            loadRichPayloadsIfNeeded()
            if rtfData != nil || htmlContent != nil {
                let fallback = richTextPlain()?.trimmingCharacters(in: .whitespacesAndNewlines)
                let content = (fallback?.isEmpty == false) ? fallback! : "Rich text content"
                return CapturedClipboardItem(
                    content: content,
                    contentTypeRaw: "rich_text",
                    rtfData: rtfData,
                    htmlContent: htmlContent,
                    dedupeKey: dedupeKey(prefix: "rich", from: richDedupeSeed(rtfData: rtfData, htmlContent: htmlContent, content: content))
                )
            }

            if !oversizedRichPayloads.isEmpty {
                let message = "[Large rich text clip skipped: \(oversizedRichPayloads.joined(separator: ", "))]"
                return CapturedClipboardItem(
                    content: message,
                    contentTypeRaw: "text",
                    dedupeKey: dedupeKey(prefix: "rich_skipped", from: ClipboardContentLimits.dedupeSeed(forText: message))
                )
            }
            return nil
        }

        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cappedCandidate = candidate

        let linkURL = clipboardLinkURL()
        let resolvedLinkURL = linkURL ?? standaloneWebURL(from: trimmed)
        if let resolvedLinkURL {
            let resolvedContent: String
            if linkURL != nil {
                let linkContent = plainString?.trimmingCharacters(in: .whitespacesAndNewlines)
                resolvedContent = (linkContent?.isEmpty == false) ? linkContent! : resolvedLinkURL.absoluteString
            } else {
                resolvedContent = resolvedLinkURL.absoluteString
            }

            return CapturedClipboardItem(
                content: resolvedContent,
                contentTypeRaw: "link",
                linkURL: resolvedLinkURL.absoluteString,
                dedupeKey: dedupeKey(
                    prefix: "link",
                    from: ClipboardContentLimits.dedupeSeed(forText: resolvedLinkURL.absoluteString)
                )
            )
        }

        if let structuredFormat = structuredFormat(from: typeIdentifiers) {
            return CapturedClipboardItem(
                content: cappedCandidate,
                contentTypeRaw: "structured",
                structuredFormatRaw: structuredFormat.rawValue,
                dedupeKey: dedupeKey(
                    prefix: "structured",
                    from: ClipboardContentLimits.dedupeSeed(forText: structuredFormat.rawValue + "|" + cappedCandidate)
                )
            )
        }

        loadRichPayloadsIfNeeded()
        if rtfData != nil || htmlContent != nil {
            let resolvedRichText = richTextPlain()
            let richContent = resolvedRichText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? resolvedRichText!
                : candidate
            let cappedRichContent = richContent

            return CapturedClipboardItem(
                content: cappedRichContent,
                contentTypeRaw: "rich_text",
                rtfData: rtfData,
                htmlContent: htmlContent,
                dedupeKey: dedupeKey(
                    prefix: "rich",
                    from: richDedupeSeed(rtfData: rtfData, htmlContent: htmlContent, content: cappedRichContent)
                )
            )
        }

        return CapturedClipboardItem(
            content: cappedCandidate,
            contentTypeRaw: "text",
            dedupeKey: dedupeKey(prefix: "text", from: ClipboardContentLimits.dedupeSeed(forText: cappedCandidate))
        )
    }

    private func plainString(from pasteboard: NSPasteboard) -> String? {
        if let value = pasteboard.string(forType: .string) {
            return value
        }

        if let values = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [NSString],
           let first = values.first {
            return first as String
        }

        return nil
    }

    private func firstNonFileURL(from pasteboard: NSPasteboard) -> URL? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return nil
        }

        return urls.first(where: { !$0.isFileURL })
    }

    private func standaloneWebURL(from value: String) -> URL? {
        for candidate in urlCandidates(from: value) {
            if let url = ClipItem.resolveLinkURL(linkURLString: candidate) {
                return url
            }
        }

        return nil
    }

    private func urlCandidates(from value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let wrappers: [(Character, Character)] = [
            ("\"", "\""),
            ("'", "'"),
            ("<", ">"),
            ("(", ")"),
            ("[", "]"),
            ("{", "}")
        ]

        guard let first = trimmed.first, let last = trimmed.last else { return [trimmed] }
        guard wrappers.contains(where: { $0.0 == first && $0.1 == last }) else { return [trimmed] }

        let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inner.isEmpty else { return [trimmed] }

        return [trimmed, inner]
    }

    private func pasteboardTypeIdentifiers(from pasteboard: NSPasteboard) -> [String] {
        (pasteboard.types ?? []).map { $0.rawValue.lowercased() }
    }

    private func structuredFormat(from typeIdentifiers: [String]) -> StructuredContentFormat? {
        if typeIdentifiers.contains(where: { $0 == "public.json" || $0 == "application/json" }) {
            return .json
        }

        if typeIdentifiers.contains(where: { $0 == "public.xml" || $0 == "text/xml" || $0 == "application/xml" }) {
            return .xml
        }

        if typeIdentifiers.contains(
            where: {
                $0 == "public.comma-separated-values-text"
                    || $0 == "public.tab-separated-values-text"
                    || $0 == "public.delimited-values-text"
                    || $0 == "text/csv"
            }
        ) {
            return .csv
        }

        return nil
    }

    private func plainTextFromRTF(_ rtfData: Data?) -> String? {
        guard let rtfData else { return nil }
        guard rtfData.count <= ClipboardContentLimits.maxRichPayloadBytes else { return nil }
        guard let attributed = try? NSAttributedString(
            data: rtfData,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else {
            return nil
        }
        return attributed.string
    }

    private func plainTextFromHTML(_ html: String?) -> String? {
        guard let html else { return nil }
        guard html.utf8.count <= ClipboardContentLimits.maxRichPayloadBytes else { return nil }
        guard let data = html.data(using: .utf8) else { return nil }
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ) else {
            return nil
        }
        return attributed.string
    }

    private func richDedupeSeed(rtfData: Data?, htmlContent: String?, content: String) -> Data {
        var seed = Data()
        if let rtfData {
            seed.append(rtfData.prefix(ClipboardContentLimits.maxDedupeSeedUTF8Bytes))
            seed.append(contentsOf: Data("|rtf_bytes:\(rtfData.count)".utf8))
        }
        if let htmlContent {
            seed.append(ClipboardContentLimits.dedupeSeed(forText: htmlContent))
        }
        if seed.isEmpty {
            seed.append(ClipboardContentLimits.dedupeSeed(forText: content))
        }
        return seed
    }

    private static let hexLookup: [UInt8] = Array("0123456789abcdef".utf8)

    private func dedupeKey(prefix: String, from data: Data) -> String {
        let digest = SHA256.hash(data: data)
        var result = [UInt8]()
        result.reserveCapacity(prefix.utf8.count + 1 + 64)
        result.append(contentsOf: prefix.utf8)
        result.append(UInt8(ascii: ":"))
        for byte in digest {
            result.append(Self.hexLookup[Int(byte >> 4)])
            result.append(Self.hexLookup[Int(byte & 0x0F)])
        }
        return String(bytes: result, encoding: .utf8)!
    }
}
