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
        pasteboard.setString(item.content, forType: .string)

        // Promote the selected history item to most-recent without creating duplicates.
        store?.insert(
            captured: CapturedClipboardItem(
                content: item.content,
                sourceBundleID: item.sourceBundleID,
                sourceAppName: item.sourceAppName
            )
        )
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
