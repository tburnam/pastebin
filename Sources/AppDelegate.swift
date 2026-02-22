import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var database: ClipboardDatabase?
    private var store: ClipboardStore?
    private var monitor: PasteboardMonitor?
    private var panelController: ClipboardPanelController?
    private var statusItem: NSStatusItem?
    private var settingsPanelController: HotKeySettingsPanelController?
    private let hotKeyManager = HotKeyManager.shared

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

            settingsPanelController = HotKeySettingsPanelController(hotKeyManager: hotKeyManager)

            setupStatusItem()
            panelController.prewarm()

            hotKeyManager.onHotKeyPressed = { [weak self] in
                self?.openClipboardPanel(nil)
            }

            // Defer initial DB load off the launch critical path.
            store.reloadFromDatabaseAsync(resetQuery: true)
            monitor.start()
        } catch {
            assertionFailure("Failed to start PasteBin: \(error)")
            NSApp.terminate(nil)
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
        settingsPanelController?.open()
    }

    private func copyToPasteboard(_ item: ClipItem) {
        monitor?.suppressNextCapture()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        write(item: item, to: pasteboard)

        // Promote the selected history item to most-recent without creating duplicates.
        store?.insert(captured: CapturedClipboardItem(item: item))
    }

    private func write(item: ClipItem, to pasteboard: NSPasteboard) {
        switch item.contentType {
        case .image:
            if let payloadData = item.payloadData {
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

            if let rtfData = item.rtfData {
                wroteAny = pasteboard.setData(rtfData, forType: .rtf) || wroteAny
            }

            if let htmlContent = item.htmlContent {
                wroteAny = pasteboard.setString(htmlContent, forType: .html) || wroteAny
            }

            if !item.content.isEmpty {
                wroteAny = pasteboard.setString(item.content, forType: .string) || wroteAny
            }

            if wroteAny {
                return
            }

        case .link:
            if let linkURL = item.linkURL {
                _ = pasteboard.writeObjects([linkURL as NSURL])
                if !item.content.isEmpty {
                    _ = pasteboard.setString(item.content, forType: .string)
                }
                return
            }

        case .code, .structured, .text:
            break
        }

        _ = pasteboard.setString(item.content, forType: .string)
    }

    private func setupStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "PasteBin")
                ?? NSImage(systemSymbolName: "clipboard", accessibilityDescription: "PasteBin") {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageOnly
            } else {
                // Keep a visible target in the menu bar even if symbol lookup fails.
                button.title = "PB"
            }
        }

        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open", action: #selector(openClipboardPanel(_:)), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(title: "Hotkey Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
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
}
