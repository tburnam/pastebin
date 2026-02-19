import AppKit
import Foundation

struct CapturedClipboardItem {
    let content: String
    let sourceBundleID: String?
    let sourceAppName: String?
}

final class PasteboardMonitor {
    var onCapture: ((CapturedClipboardItem) -> Void)?

    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int
    private var shouldSuppressNextChange = false
    private var lastDeliveredContent: String?

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

        guard let content = readString(from: pasteboard), !content.isEmpty else {
            return
        }

        guard content != lastDeliveredContent else { return }
        lastDeliveredContent = content

        let sourceApp = NSWorkspace.shared.frontmostApplication

        onCapture?(
            CapturedClipboardItem(
                content: content,
                sourceBundleID: sourceApp?.bundleIdentifier,
                sourceAppName: sourceApp?.localizedName
            )
        )
    }

    private func readString(from pasteboard: NSPasteboard) -> String? {
        if let value = pasteboard.string(forType: .string) {
            return value
        }

        if let values = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [NSString],
           let first = values.first {
            return first as String
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first {
            if first.isFileURL {
                let allPaths = urls.map(\.path)
                return allPaths.joined(separator: "\n")
            }
            return first.absoluteString
        }

        if let image = NSImage(pasteboard: pasteboard) {
            return "[Image \(Int(image.size.width))x\(Int(image.size.height))]"
        }

        if let rtfData = pasteboard.data(forType: .rtf),
           let attributed = try? NSAttributedString(
               data: rtfData,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ) {
            return attributed.string
        }

        if let html = pasteboard.string(forType: .html) {
            return html
        }

        if let availableType = pasteboard.types?.first {
            return "[Clipboard data: \(availableType.rawValue)]"
        }

        return nil
    }
}
