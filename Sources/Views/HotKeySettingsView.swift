import AppKit
import SwiftUI

struct HotKeySettingsView: View {
    @ObservedObject var hotKeyManager: HotKeyManager
    @StateObject private var model: HotKeySettingsViewModel

    private let panelRadius: CGFloat = 18

    init(hotKeyManager: HotKeyManager) {
        self.hotKeyManager = hotKeyManager
        _model = StateObject(wrappedValue: HotKeySettingsViewModel(hotKeyManager: hotKeyManager))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Global Hotkey")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            Text("Record a shortcut to open PasteBin from anywhere.")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.50))

            HStack(spacing: 10) {
                shortcutDisplay
                Spacer(minLength: 0)
                recordButton
                saveButton
            }

            statusMessages

            Text("Current: \(hotKeyManager.shortcut.displayString)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.38))
        }
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
        .shadow(color: .black.opacity(0.30), radius: 28, y: 4)
        .onChange(of: hotKeyManager.shortcut) { _, _ in
            model.syncFromManager()
        }
    }

    // MARK: - Subviews

    private var shortcutDisplay: some View {
        Text(model.draftShortcut.displayString)
            .font(.system(size: 17, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.95))
            .frame(minWidth: 90)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(model.isRecording ? 0.12 : 0.07))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        model.isRecording ? Color.accentColor.opacity(0.55) : .white.opacity(0.14),
                        lineWidth: model.isRecording ? 1.2 : 0.8
                    )
            }
    }

    private var recordButton: some View {
        Button {
            if model.isRecording {
                model.stopRecording()
            } else {
                model.startRecording()
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(model.isRecording ? Color.red : Color.red.opacity(0.65))
                    .frame(width: 7, height: 7)

                Text(model.isRecording ? "Press keys\u{2026}" : "Record")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background {
                Capsule().fill(.white.opacity(model.isRecording ? 0.14 : 0.10))
            }
            .overlay {
                Capsule().stroke(.white.opacity(0.18), lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }

    private var saveButton: some View {
        Button { model.save() } label: {
            Text("Save")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(model.canSave ? 0.95 : 0.30))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background {
                    Capsule().fill(model.canSave ? Color.accentColor.opacity(0.55) : .white.opacity(0.05))
                }
                .overlay {
                    Capsule().stroke(
                        model.canSave ? Color.accentColor.opacity(0.35) : .white.opacity(0.08),
                        lineWidth: 0.8
                    )
                }
        }
        .buttonStyle(.plain)
        .disabled(!model.canSave)
    }

    @ViewBuilder
    private var statusMessages: some View {
        if let warning = model.effectiveWarning {
            Text(warning)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.orange.opacity(0.85))
        }

        if let saveMessage = model.saveMessage {
            Text(saveMessage)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.green.opacity(0.85))
        }
    }
}

// MARK: - View Model

final class HotKeySettingsViewModel: ObservableObject {
    @Published var draftShortcut: HotKeyShortcut
    @Published var isRecording = false
    @Published var draftWarning: String?
    @Published var saveMessage: String?

    var canSave: Bool {
        guard let hotKeyManager else { return false }
        return draftShortcut != hotKeyManager.shortcut
    }

    var effectiveWarning: String? {
        draftWarning ?? hotKeyManager?.warningMessage
    }

    private weak var hotKeyManager: HotKeyManager?
    private var localMonitor: Any?
    private var resignKeyObserver: Any?

    init(hotKeyManager: HotKeyManager) {
        self.hotKeyManager = hotKeyManager
        self.draftShortcut = hotKeyManager.shortcut
        self.draftWarning = hotKeyManager.warningMessage
    }

    func syncFromManager() {
        guard let hotKeyManager, !isRecording else { return }
        draftShortcut = hotKeyManager.shortcut
        draftWarning = hotKeyManager.warningMessage
    }

    func startRecording() {
        guard !isRecording else { return }

        isRecording = true
        saveMessage = nil
        draftWarning = nil

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.isRecording else { return event }

            if event.keyCode == 53 { // Escape cancels recording.
                self.stopRecording()
                return nil
            }

            guard let shortcut = HotKeyShortcut.from(event: event) else {
                NSSound.beep()
                return nil
            }

            self.draftShortcut = shortcut
            self.draftWarning = HotKeyManager.collisionWarning(for: shortcut)
            self.stopRecording()
            return nil
        }

        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopRecording()
        }
    }

    func stopRecording() {
        isRecording = false

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
    }

    func save() {
        guard let hotKeyManager else { return }

        hotKeyManager.save(shortcut: draftShortcut)
        draftWarning = hotKeyManager.warningMessage
        saveMessage = "Saved"

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.saveMessage = nil
        }
    }
}
