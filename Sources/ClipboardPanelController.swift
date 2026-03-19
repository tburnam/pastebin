import AppKit
import QuartzCore
import SwiftUI

final class ClipboardPanelController: NSObject, NSWindowDelegate {
    private let store: ClipboardStore
    private let onSelect: (ClipItem) -> Void

    private var panel: FloatingPanel?
    private var keyMonitor: Any?
    private var didPrewarmPanel = false
    private var appToReactivateOnClose: NSRunningApplication?

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
        prewarm()

        let panel = ensurePanel()
        let targetFrame = frameForPanel(on: panel)

        // Start below the bottom screen edge
        var startFrame = targetFrame
        startFrame.origin.y -= panelHeight + 20

        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0

        captureFrontmostAppForFocusRestore()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.contentView?.layoutSubtreeIfNeeded()

        installEventMonitors()

        store.prepareForPresentation()

        // Snappy spring-like slide up
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func prewarm() {
        guard !didPrewarmPanel else { return }

        let panel = ensurePanel()
        panel.setFrame(frameForPanel(on: panel), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        didPrewarmPanel = true
    }

    func close(restorePreviousAppFocus: Bool = true) {
        guard let panel, panel.isVisible else {
            return
        }

        removeEventMonitors()

        // Slide down below screen edge
        var offscreenFrame = panel.frame
        offscreenFrame.origin.y -= panelHeight + 20

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(offscreenFrame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            panel.orderOut(nil)
            panel.alphaValue = 1

            if restorePreviousAppFocus {
                self?.restorePreviousAppFocusIfNeeded()
            } else {
                self?.appToReactivateOnClose = nil
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        close(restorePreviousAppFocus: false)
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

        let rootView = ClipboardPanelView(store: store) { [weak self] item in
            self?.activateItem(item)
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
        if store.isInlineTitleEditorActive {
            return false
        }

        // When search is collapsed and an inline text field (card/bucket rename) is active,
        // let the field own all keyboard input.
        if isCollapsedSearchInlineEditorActive() {
            return false
        }

        // Cmd+C: copy selected and close
        if event.modifierFlags.contains(.command), event.keyCode == 8 {
            copySelectedItem()
            return true
        }

        // Cmd+1-9: jump to item, copy, and close
        if event.modifierFlags.contains(.command), let index = commandIndex(for: event.keyCode) {
            guard let item = store.item(at: index) else {
                NSSound.beep()
                return true
            }
            activateItem(item)
            return true
        }

        // Typeahead when the search field is collapsed.
        if !store.isSearchExpanded, let typed = typeaheadCharacters(from: event) {
            store.beginSearch(with: typed)
            return true
        }

        // If search is visible but no text input owns focus yet, keep feeding
        // typeahead characters directly so fast typing is not dropped.
        if store.isSearchExpanded, !isTextInputFocused(), let typed = typeaheadCharacters(from: event) {
            store.beginSearch(with: typed)
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
        case 51, 117: // Delete/Backspace, Forward Delete
            // When the search field is focused, delete keys should edit query text.
            if store.isSearchExpanded, isTextInputFocused() {
                return false
            }
            store.deleteSelectedItem()
            return true
        case 53: // Escape
            if !store.query.isEmpty {
                store.query = ""
                store.collapseSearchIfPossible()
                return true
            }

            if store.isSearchExpanded {
                store.collapseSearchIfPossible()
                return true
            }

            if store.isShowingClipboard {
                close()
            } else {
                store.showClipboardScope()
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

    private func activateItem(_ item: ClipItem) {
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

    private func typeaheadCharacters(from event: NSEvent) -> String? {
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .function]
        guard event.modifierFlags.intersection(disallowedModifiers).isEmpty else {
            return nil
        }

        switch event.keyCode {
        case 36, 76, 48, 51, 53, 123, 124, 125, 126:
            return nil
        default:
            break
        }

        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return nil
        }

        guard characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }

        return characters
    }

    private func isCollapsedSearchInlineEditorActive() -> Bool {
        guard !store.isSearchExpanded else { return false }
        return isTextInputFocused()
    }

    private func isTextInputFocused() -> Bool {
        guard let panel else { return false }
        guard let firstResponder = panel.firstResponder else { return false }

        return firstResponder is NSTextView || firstResponder is NSTextField
    }

    private func captureFrontmostAppForFocusRestore() {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            appToReactivateOnClose = nil
            return
        }

        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        guard frontmostApp.processIdentifier != currentProcessID else {
            appToReactivateOnClose = nil
            return
        }

        appToReactivateOnClose = frontmostApp
    }

    private func restorePreviousAppFocusIfNeeded() {
        defer { appToReactivateOnClose = nil }

        guard let appToReactivateOnClose else { return }

        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == currentProcessID else {
            return
        }

        guard !appToReactivateOnClose.isTerminated else { return }
        _ = appToReactivateOnClose.activate(options: [])
    }
}

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
