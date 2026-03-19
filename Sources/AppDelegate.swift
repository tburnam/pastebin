import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var database: ClipboardDatabase?
    private var store: ClipboardStore?
    private var monitor: PasteboardMonitor?
    private var panelController: ClipboardPanelController?
    private var statusItem: NSStatusItem?
    private let hotKeyManager = HotKeyManager.shared
    private let appSettings = AppSettings.shared
    private var cancellables: Set<AnyCancellable> = []
    private lazy var settingsWindowController = makeSettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            let database = try ClipboardDatabase(url: try AppPaths.databaseURL())
            let store = ClipboardStore(database: database)
            let panelController = ClipboardPanelController(store: store) { [weak self] item in
                self?.copyToPasteboard(item)
            }

            let monitor = PasteboardMonitor()
            monitor.onCapture = { [weak store] capture in
                store?.insert(captured: capture)
            }

            self.database = database
            self.store = store
            self.panelController = panelController
            self.monitor = monitor

            setupStatusItem()
            panelController.prewarm()

            hotKeyManager.onHotKeyPressed = { [weak self] in
                self?.openClipboardPanel(nil)
            }

            observeRetentionChanges()
            applyRetentionPolicy(resetQuery: true)
            monitor.start()
        } catch {
            presentLaunchFailureAlert(for: error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }

    @objc private func openClipboardPanel(_ sender: Any?) {
        panelController?.toggle()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc private func openSettings(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController.showWindow(sender)
        settingsWindowController.window?.makeKeyAndOrderFront(sender)
    }

    private func makeSettingsWindowController() -> NSWindowController {
        let contentView = PasteBinSettingsView(
            hotKeyManager: hotKeyManager,
            appSettings: appSettings
        )

        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "PasteBin Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 480, height: 360))
        window.center()
        window.isReleasedWhenClosed = false

        return NSWindowController(window: window)
    }

    private func copyToPasteboard(_ item: ClipItem) {
        monitor?.suppressNextCapture()

        guard let content = store?.fetchContentForPaste(itemID: item.id) else {
            // Fallback: write what we have from the snippet
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            _ = pasteboard.setString(item.snippetPreview, forType: .string)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        write(item: item, content: content, to: pasteboard)

        // Promote the selected history item to most-recent without creating duplicates.
        store?.promoteItem(id: item.id)
    }

    private func write(item: ClipItem, content: PasteContent, to pasteboard: NSPasteboard) {
        switch item.contentType {
        case .image:
            if let payloadData = content.payloadData {
                if pasteboard.setData(payloadData, forType: .tiff) {
                    return
                }

                if let image = NSImage(data: payloadData),
                   pasteboard.writeObjects([image]) {
                    return
                }
            }

        case .fileList:
            let urls = item.filePaths.map { URL(fileURLWithPath: $0) }
            if !urls.isEmpty {
                let nsURLs = urls.map { $0 as NSURL }
                if pasteboard.writeObjects(nsURLs) {
                    return
                }
            }

        case .richText:
            var wroteAny = false

            if let rtfData = content.rtfData {
                wroteAny = pasteboard.setData(rtfData, forType: .rtf) || wroteAny
            }

            if let htmlContent = content.htmlContent {
                wroteAny = pasteboard.setString(htmlContent, forType: .html) || wroteAny
            }

            if !content.text.isEmpty {
                wroteAny = pasteboard.setString(content.text, forType: .string) || wroteAny
            }

            if wroteAny {
                return
            }

        case .link:
            if let linkURL = item.linkURL {
                _ = pasteboard.writeObjects([linkURL as NSURL])
                if !content.text.isEmpty {
                    _ = pasteboard.setString(content.text, forType: .string)
                }
                return
            }

        case .code, .structured, .text:
            break
        }

        _ = pasteboard.setString(content.text, forType: .string)
    }

    private func setupStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let iconSideLength: CGFloat = 14

            if let image = StatusBarIconRenderer.makeMenuBarImage(sideLength: iconSideLength)
                ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "PasteBin")
                ?? NSImage(systemSymbolName: "clipboard", accessibilityDescription: "PasteBin") {
                button.image = image
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleProportionallyDown
                button.title = ""
            } else {
                // Keep a visible target in the menu bar even if symbol lookup fails.
                button.title = "PB"
            }
        }

        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open", action: #selector(openClipboardPanel(_:)), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit PasteBin", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        self.statusItem = statusItem
    }

    private func presentLaunchFailureAlert(for error: Error) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "PasteBin couldn’t start."
        alert.informativeText = """
        \(error.localizedDescription)

        Database location:
        \(appSettings.databasePath)
        """
        alert.addButton(withTitle: "Quit")
        alert.runModal()

        NSApp.terminate(nil)
    }

    private func observeRetentionChanges() {
        appSettings.$retentionPeriod
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.applyRetentionPolicy(resetQuery: false)
            }
            .store(in: &cancellables)
    }

    private func applyRetentionPolicy(resetQuery: Bool) {
        guard let database, let store else { return }
        let retentionPeriod = appSettings.retentionPeriod

        DispatchQueue.global(qos: .utility).async {
            do {
                _ = try database.pruneHistory(
                    olderThan: retentionPeriod.cutoffDate(referenceDate: Date())
                )
            } catch {
                print("Failed applying retention policy: \(error)")
            }

            DispatchQueue.main.async {
                store.reloadFromDatabaseAsync(resetQuery: resetQuery)
            }
        }
    }
}
