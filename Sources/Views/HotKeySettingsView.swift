import AppKit
import SwiftUI

struct HotKeySettingsView: View {
    @ObservedObject var hotKeyManager: HotKeyManager
    @StateObject private var model: HotKeySettingsViewModel

    init(hotKeyManager: HotKeyManager) {
        self.hotKeyManager = hotKeyManager
        _model = StateObject(wrappedValue: HotKeySettingsViewModel(hotKeyManager: hotKeyManager))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Global Hotkey")
                .font(.system(size: 18, weight: .semibold, design: .rounded))

            Text("Record a shortcut to open PasteBin from anywhere.")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button(model.isRecording ? "Press keys…" : "Record Shortcut") {
                    if model.isRecording {
                        model.stopRecording()
                    } else {
                        model.startRecording()
                    }
                }
                .buttonStyle(.bordered)

                Text(model.draftShortcut.displayString)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .frame(minWidth: 120, alignment: .leading)

                Spacer(minLength: 0)

                Button("Save") {
                    model.save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave)
            }

            if let warning = model.effectiveWarning {
                Text(warning)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.orange)
            }

            if let saveMessage = model.saveMessage {
                Text(saveMessage)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.green)
            }

            Divider()

            Text("Current: \(hotKeyManager.shortcut.displayString)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 430)
        .onChange(of: hotKeyManager.shortcut) { _, _ in
            model.syncFromManager()
        }
        .onDisappear {
            model.stopRecording()
        }
    }
}

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
    }

    func stopRecording() {
        isRecording = false
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
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
