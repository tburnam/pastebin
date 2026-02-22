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
        let seed = Data(filePaths.joined(separator: "|").utf8)

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
        let rtfData = pasteboard.data(forType: .rtf)
        let htmlContent = pasteboard.string(forType: .html)
        let linkURL = firstNonFileURL(from: pasteboard)

        let plainString = plainString(from: pasteboard)
        let richTextPlain = plainTextFromRTF(rtfData) ?? plainTextFromHTML(htmlContent)
        let candidate = plainString ?? richTextPlain

        guard let candidate else {
            if let linkURL {
                return CapturedClipboardItem(
                    content: linkURL.absoluteString,
                    contentTypeRaw: "link",
                    linkURL: linkURL.absoluteString,
                    dedupeKey: dedupeKey(prefix: "link", from: Data(linkURL.absoluteString.utf8))
                )
            }

            if rtfData != nil || htmlContent != nil {
                let fallback = richTextPlain?.trimmingCharacters(in: .whitespacesAndNewlines)
                let content = (fallback?.isEmpty == false) ? fallback! : "Rich text content"
                return CapturedClipboardItem(
                    content: content,
                    contentTypeRaw: "rich_text",
                    rtfData: rtfData,
                    htmlContent: htmlContent,
                    dedupeKey: dedupeKey(prefix: "rich", from: richDedupeSeed(rtfData: rtfData, htmlContent: htmlContent, content: content))
                )
            }
            return nil
        }

        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let linkURL {
            let linkContent = plainString?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedContent = (linkContent?.isEmpty == false) ? linkContent! : linkURL.absoluteString
            return CapturedClipboardItem(
                content: resolvedContent,
                contentTypeRaw: "link",
                linkURL: linkURL.absoluteString,
                dedupeKey: dedupeKey(prefix: "link", from: Data(linkURL.absoluteString.utf8))
            )
        }

        if let structuredFormat = structuredFormat(from: typeIdentifiers) {
            return CapturedClipboardItem(
                content: candidate,
                contentTypeRaw: "structured",
                structuredFormatRaw: structuredFormat.rawValue,
                dedupeKey: dedupeKey(prefix: "structured", from: Data((structuredFormat.rawValue + "|" + candidate).utf8))
            )
        }

        if isSystemSourceCodeType(typeIdentifiers) {
            let codeLanguage = codeLanguage(from: typeIdentifiers)
            return CapturedClipboardItem(
                content: candidate,
                contentTypeRaw: "code",
                codeLanguage: codeLanguage,
                dedupeKey: dedupeKey(prefix: "code", from: Data(((codeLanguage ?? "unknown") + "|" + candidate).utf8))
            )
        }

        if rtfData != nil || htmlContent != nil {
            let richContent = richTextPlain?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? richTextPlain!
                : candidate

            return CapturedClipboardItem(
                content: richContent,
                contentTypeRaw: "rich_text",
                rtfData: rtfData,
                htmlContent: htmlContent,
                dedupeKey: dedupeKey(
                    prefix: "rich",
                    from: richDedupeSeed(rtfData: rtfData, htmlContent: htmlContent, content: richContent)
                )
            )
        }

        return CapturedClipboardItem(
            content: candidate,
            contentTypeRaw: "text",
            dedupeKey: dedupeKey(prefix: "text", from: Data(candidate.utf8))
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

    private func isSystemSourceCodeType(_ typeIdentifiers: [String]) -> Bool {
        typeIdentifiers.contains(
            where: {
                $0 == "public.source-code"
                    || $0 == "public.script"
                    || $0 == "public.swift-source"
                    || $0 == "public.c-source"
                    || $0 == "public.c-plus-plus-source"
                    || $0 == "public.objective-c-source"
                    || $0 == "public.objective-c-plus-plus-source"
                    || $0 == "public.java-source"
                    || $0 == "public.javascript"
                    || $0 == "public.python-script"
                    || $0 == "public.shell-script"
                    || $0 == "public.ruby-script"
            }
        )
    }

    private func codeLanguage(from typeIdentifiers: [String]) -> String? {
        if typeIdentifiers.contains("public.swift-source") {
            return "swift"
        }

        if typeIdentifiers.contains("public.javascript") {
            return "javascript"
        }

        if typeIdentifiers.contains(where: { $0.contains("typescript") }) {
            return "typescript"
        }

        if typeIdentifiers.contains("public.python-script") {
            return "python"
        }

        if typeIdentifiers.contains("public.shell-script") {
            return "shell"
        }

        if typeIdentifiers.contains(where: { $0 == "public.c-source" || $0 == "public.c-plus-plus-source" || $0 == "public.objective-c-source" || $0 == "public.objective-c-plus-plus-source" }) {
            return "c-family"
        }

        if typeIdentifiers.contains("public.java-source") {
            return "java"
        }

        if typeIdentifiers.contains("public.ruby-script") {
            return "ruby"
        }

        return nil
    }

    private func plainTextFromRTF(_ rtfData: Data?) -> String? {
        guard let rtfData else { return nil }
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
        guard let html, let data = html.data(using: .utf8) else { return nil }
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
            seed.append(rtfData)
        }
        if let htmlContent {
            seed.append(Data(htmlContent.utf8))
        }
        if seed.isEmpty {
            seed.append(Data(content.utf8))
        }
        return seed
    }

    private func dedupeKey(prefix: String, from data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(prefix):\(hex)"
    }
}
