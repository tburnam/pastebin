import AppKit
import SwiftUI

struct PasteBinSettingsView: View {
    @ObservedObject private var hotKeyManager: HotKeyManager
    @ObservedObject private var appSettings: AppSettings
    @StateObject private var hotKeyModel: SettingsHotKeyViewModel
    @State private var retentionSliderValue: Double
    @State private var dbPathHovered = false
    @Namespace private var retentionNamespace

    private var retentionOptions: [HistoryRetentionPeriod] {
        HistoryRetentionPeriod.allCases
    }

    private var selectedRetentionPeriod: HistoryRetentionPeriod {
        let index = clampedRetentionIndex
        return retentionOptions[index]
    }

    private var clampedRetentionIndex: Int {
        let rounded = Int(retentionSliderValue.rounded())
        return min(max(rounded, 0), retentionOptions.count - 1)
    }

    init(
        hotKeyManager: HotKeyManager = .shared,
        appSettings: AppSettings = .shared
    ) {
        self.hotKeyManager = hotKeyManager
        self.appSettings = appSettings
        _hotKeyModel = StateObject(wrappedValue: SettingsHotKeyViewModel(hotKeyManager: hotKeyManager))
        _retentionSliderValue = State(initialValue: Double(appSettings.retentionPeriod.rawValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
            }
            .padding(.bottom, 20)

            VStack(spacing: 14) {
                hotKeySection
                retentionSection
                databasePathSection
            }

            Text("Built by Tyler Burnam")
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.2))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 480)
        .background(Color(white: 0.11))
        .onChange(of: hotKeyManager.shortcut) { _, _ in
            hotKeyModel.syncFromManager()
        }
        .onChange(of: appSettings.retentionPeriod) { _, period in
            let nextValue = Double(period.rawValue)
            guard retentionSliderValue != nextValue else { return }
            retentionSliderValue = nextValue
        }
    }

    // MARK: - Section container

    private func settingsSection<Content: View>(
        icon: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 0.7)
        )
    }

    // MARK: - Hotkey

    private var hotKeySection: some View {
        settingsSection(icon: "keyboard", title: "GLOBAL SHORTCUT") {
            VStack(alignment: .leading, spacing: 12) {
                // Shortcut display area
                HStack(spacing: 12) {
                    if hotKeyModel.isRecording {
                        // Live recording display
                        HStack(spacing: 6) {
                            Circle()
                                .fill(.red)
                                .frame(width: 7, height: 7)
                                .opacity(hotKeyModel.recordingPulse ? 1.0 : 0.3)

                            let liveText = hotKeyModel.liveModifiers.isEmpty
                                ? "Waiting…"
                                : hotKeyModel.liveModifiers + "…"

                            Text(liveText)
                                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.65))
                                .contentTransition(.numericText())
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(red: 0.35, green: 0.55, blue: 1.0).opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color(red: 0.35, green: 0.55, blue: 1.0).opacity(0.30), lineWidth: 1)
                        )
                    } else {
                        // Current shortcut
                        Text(hotKeyManager.shortcut.displayString)
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(.white.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(.white.opacity(0.10), lineWidth: 0.7)
                            )

                        // Pending draft indicator
                        if hotKeyModel.draftShortcut != hotKeyManager.shortcut {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.3))

                            Text(hotKeyModel.draftShortcut.displayString)
                                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color(red: 0.35, green: 0.55, blue: 1.0))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color(red: 0.35, green: 0.55, blue: 1.0).opacity(0.10))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color(red: 0.35, green: 0.55, blue: 1.0).opacity(0.25), lineWidth: 0.7)
                                )
                        }
                    }

                    Spacer(minLength: 0)
                }
                .animation(.snappy(duration: 0.2), value: hotKeyModel.isRecording)

                // Action buttons
                HStack(spacing: 8) {
                    settingsButton(
                        title: hotKeyModel.isRecording ? "Cancel" : "Record",
                        icon: hotKeyModel.isRecording ? "xmark" : "record.circle",
                        isActive: hotKeyModel.isRecording
                    ) {
                        if hotKeyModel.isRecording {
                            hotKeyModel.stopRecording()
                        } else {
                            hotKeyModel.startRecording()
                        }
                    }

                    if hotKeyModel.canSave && !hotKeyModel.isRecording {
                        settingsButton(title: "Save", icon: "checkmark", accent: true) {
                            hotKeyModel.save()
                        }
                    }

                    Spacer(minLength: 0)

                    if let warning = hotKeyModel.effectiveWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.orange.opacity(0.85))
                    }

                    if let saveMessage = hotKeyModel.saveMessage {
                        Label(saveMessage, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color(red: 0.35, green: 0.93, blue: 0.53).opacity(0.85))
                    }
                }
            }
        }
    }

    // MARK: - Retention

    private var retentionSection: some View {
        settingsSection(icon: "clock.arrow.circlepath", title: "HISTORY RETENTION") {
            VStack(alignment: .leading, spacing: 12) {
                // Segmented picker with sliding highlight
                HStack(spacing: 2) {
                    ForEach(retentionOptions) { option in
                        let isSelected = option == selectedRetentionPeriod

                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                                retentionSliderValue = Double(option.rawValue)
                                appSettings.updateRetentionPeriod(option)
                            }
                        } label: {
                            Text(option.shortLabel)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .medium, design: .rounded))
                                .foregroundStyle(isSelected ? .white.opacity(0.95) : .white.opacity(0.38))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background {
                                    if isSelected {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(.white.opacity(0.13))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                    .stroke(.white.opacity(0.08), lineWidth: 0.7)
                                            )
                                            .matchedGeometryEffect(id: "retention_highlight", in: retentionNamespace)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.white.opacity(0.04))
                )

                Text("Clipboard entries older than \(selectedRetentionPeriod.displayTitle.lowercased()) will be automatically removed.")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.36))
                    .contentTransition(.numericText())
            }
        }
    }

    // MARK: - Database path

    private var databasePathSection: some View {
        settingsSection(icon: "cylinder", title: "DATABASE") {
            HStack(spacing: 10) {
                Text(appSettings.databasePath)
                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                Button {
                    NSWorkspace.shared.selectFile(
                        appSettings.databasePath,
                        inFileViewerRootedAtPath: ""
                    )
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(dbPathHovered ? 0.7 : 0.35))
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.white.opacity(dbPathHovered ? 0.10 : 0.05))
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    dbPathHovered = hovering
                }
                .help("Reveal in Finder")
            }
        }
    }

    // MARK: - Reusable button

    private func settingsButton(
        title: String,
        icon: String,
        isActive: Bool = false,
        accent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
            }
            .foregroundStyle(
                accent
                    ? Color(red: 0.35, green: 0.93, blue: 0.53).opacity(0.9)
                    : isActive
                        ? Color(red: 0.35, green: 0.55, blue: 1.0)
                        : .white.opacity(0.65)
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        accent
                            ? Color(red: 0.35, green: 0.93, blue: 0.53).opacity(0.10)
                            : isActive
                                ? Color(red: 0.35, green: 0.55, blue: 1.0).opacity(0.12)
                                : .white.opacity(0.06)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        accent
                            ? Color(red: 0.35, green: 0.93, blue: 0.53).opacity(0.20)
                            : isActive
                                ? Color(red: 0.35, green: 0.55, blue: 1.0).opacity(0.25)
                                : .white.opacity(0.08),
                        lineWidth: 0.7
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

final class SettingsHotKeyViewModel: ObservableObject {
    @Published var draftShortcut: HotKeyShortcut
    @Published var isRecording = false
    @Published var draftWarning: String?
    @Published var saveMessage: String?
    @Published var liveModifiers: String = ""
    @Published var recordingPulse: Bool = false

    var canSave: Bool {
        guard let hotKeyManager else { return false }
        return draftShortcut != hotKeyManager.shortcut
    }

    var effectiveWarning: String? {
        draftWarning ?? hotKeyManager?.warningMessage
    }

    private weak var hotKeyManager: HotKeyManager?
    private var keyDownMonitor: Any?
    private var flagsMonitor: Any?
    private var resignKeyObserver: Any?
    private var pulseTimer: Timer?

    init(hotKeyManager: HotKeyManager) {
        self.hotKeyManager = hotKeyManager
        self.draftShortcut = hotKeyManager.shortcut
        self.draftWarning = hotKeyManager.warningMessage
    }

    deinit {
        stopRecording()
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
        liveModifiers = ""

        // Pulse animation for recording indicator
        recordingPulse = true
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.5)) {
                    self.recordingPulse.toggle()
                }
            }
        }

        // Monitor modifier key changes to show live feedback
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, self.isRecording else { return event }
            let flags = event.modifierFlags
            var mods = ""
            if flags.contains(.control) { mods += "⌃" }
            if flags.contains(.option) { mods += "⌥" }
            if flags.contains(.shift) { mods += "⇧" }
            if flags.contains(.command) { mods += "⌘" }
            withAnimation(.snappy(duration: 0.12)) {
                self.liveModifiers = mods
            }
            return event
        }

        // Monitor key down to capture the final shortcut
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
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
        liveModifiers = ""

        pulseTimer?.invalidate()
        pulseTimer = nil
        recordingPulse = false

        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }

        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
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
