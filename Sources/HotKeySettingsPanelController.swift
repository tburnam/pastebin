import AppKit
import QuartzCore
import SwiftUI

final class HotKeySettingsPanelController: NSObject, NSWindowDelegate {
    private let hotKeyManager: HotKeyManager
    private var panel: NSPanel?

    init(hotKeyManager: HotKeyManager) {
        self.hotKeyManager = hotKeyManager
    }

    func open() {
        let panel = ensurePanel()
        centerPanel(panel)

        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        guard let panel, panel.isVisible else { return }

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

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        let rootView = HotKeySettingsView(hotKeyManager: hotKeyManager)
        panel.contentView = NSHostingView(rootView: rootView)

        self.panel = panel
        return panel
    }

    private func centerPanel(_ panel: NSPanel) {
        guard let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }

        let x = screenFrame.midX - panel.frame.width / 2
        let y = screenFrame.midY - panel.frame.height / 2 + 60
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
