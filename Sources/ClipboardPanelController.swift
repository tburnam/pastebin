import AppKit
import QuartzCore
import SwiftUI

final class ClipboardPanelController: NSObject, NSWindowDelegate {
    private let store: ClipboardStore
    private let onSelect: (ClipItem) -> Void

    private var panel: FloatingPanel?
    private var keyMonitor: Any?

    private let panelHeight: CGFloat = 360

    init(store: ClipboardStore, onSelect: @escaping (ClipItem) -> Void) {
        self.store = store
        self.onSelect = onSelect
    }

    deinit {
        removeEventMonitors()
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func toggle() {
        if isVisible {
            close()
        } else {
            open()
        }
    }

    func open() {
        let panel = ensurePanel()
        let targetFrame = frameForPanel(on: panel)

        panel.setFrame(targetFrame, display: false)
        panel.alphaValue = 0

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        installEventMonitors()

        store.prepareForPresentation()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        guard let panel, panel.isVisible else {
            return
        }

        removeEventMonitors()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func ensurePanel() -> FloatingPanel {
        if let panel {
            return panel
        }

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: panelHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = false
        panel.delegate = self

        let rootView = ClipboardPanelView(store: store) { [weak self] index in
            self?.activateItem(at: index)
        }

        panel.contentView = NSHostingView(rootView: rootView)

        self.panel = panel
        return panel
    }

    private func frameForPanel(on panel: NSWindow) -> NSRect {
        let screen = panel.screen ?? NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let fullFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let inset: CGFloat = 10
        let width = fullFrame.width - inset * 2
        let x = fullFrame.minX + inset
        let y = fullFrame.minY + inset

        return NSRect(x: x, y: y, width: width, height: panelHeight)
    }

    // MARK: - Key handling (special keys only — TextField owns text input)

    private func installEventMonitors() {
        removeEventMonitors()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard panel?.isVisible == true else { return event }

            if handleKeyDown(event) {
                return nil
            }

            return event
        }
    }

    private func removeEventMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // Cmd+C: copy selected and close
        if event.modifierFlags.contains(.command), event.keyCode == 8 {
            copySelectedItem()
            return true
        }

        // Cmd+1-9: jump to item, copy, and close
        if event.modifierFlags.contains(.command), let index = commandIndex(for: event.keyCode) {
            activateItem(at: index)
            return true
        }

        // Shift+Enter: copy, close, and paste into previous app
        if event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.command),
           (event.keyCode == 36 || event.keyCode == 76) {
            copySelectedItemAndPaste()
            return true
        }

        switch event.keyCode {
        case 123: // Left arrow
            store.moveSelection(delta: -1)
            return true
        case 124: // Right arrow
            store.moveSelection(delta: 1)
            return true
        case 36, 76: // Enter: copy and close
            copySelectedItem()
            return true
        case 53: // Escape
            if store.query.isEmpty {
                close()
            } else {
                store.query = ""
            }
            return true
        default:
            return false
        }
    }

    private func copySelectedItem() {
        guard let item = store.selectedItem() else {
            NSSound.beep()
            return
        }

        onSelect(item)
        close()
    }

    private func copySelectedItemAndPaste() {
        guard let item = store.selectedItem() else {
            NSSound.beep()
            return
        }

        onSelect(item)
        close()

        // After the panel closes and the previous app regains focus, simulate Cmd+V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let source = CGEventSource(stateID: .combinedSessionState)

            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            keyDown?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyUp?.flags = .maskCommand
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    private func activateItem(at index: Int) {
        guard let item = store.item(at: index) else {
            NSSound.beep()
            return
        }

        store.select(index)
        onSelect(item)
        close()
    }

    private func commandIndex(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 0 // 1
        case 19: return 1 // 2
        case 20: return 2 // 3
        case 21: return 3 // 4
        case 23: return 4 // 5
        case 22: return 5 // 6
        case 26: return 6 // 7
        case 28: return 7 // 8
        case 25: return 8 // 9
        default: return nil
        }
    }
}

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
