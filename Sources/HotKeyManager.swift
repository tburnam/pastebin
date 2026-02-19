import AppKit
import Carbon.HIToolbox
import Foundation

struct HotKeyShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let defaultValue = HotKeyShortcut(
        keyCode: 9, // v
        modifiers: UInt32(cmdKey | shiftKey)
    )

    private static let requiredModifierMask = UInt32(cmdKey | optionKey | controlKey)
    private static let modifierOnlyKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    var displayString: String {
        var output = ""

        if modifiers & UInt32(controlKey) != 0 { output += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { output += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { output += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { output += "⌘" }

        output += Self.displayKey(for: keyCode)
        return output
    }

    static func from(event: NSEvent) -> HotKeyShortcut? {
        guard !event.isARepeat else { return nil }
        guard !modifierOnlyKeyCodes.contains(event.keyCode) else { return nil }

        let modifiers = carbonModifiers(from: event.modifierFlags)
        guard modifiers & requiredModifierMask != 0 else { return nil }

        return HotKeyShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    func matches(keyCode expectedKeyCode: UInt32, modifiers expectedModifiers: UInt32) -> Bool {
        keyCode == expectedKeyCode && modifiers == expectedModifiers
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0

        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }

        return result
    }

    private static func displayKey(for keyCode: UInt32) -> String {
        if let named = keyNameMap[keyCode] {
            return named
        }

        return "?"
    }

    private static let keyNameMap: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
        50: "`", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}

final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()

    @Published private(set) var shortcut: HotKeyShortcut
    @Published private(set) var warningMessage: String?

    var onHotKeyPressed: (() -> Void)?

    private let defaultsKey = "pastebin.global_hotkey.shortcut"
    private let hotKeySignature: OSType = 0x5042484B // PBHK
    private let hotKeyIDValue: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private init() {
        shortcut = Self.loadShortcut(defaultsKey: defaultsKey) ?? .defaultValue
        installEventHandler()
        registerShortcut()
    }

    deinit {
        unregisterShortcut()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func save(shortcut newShortcut: HotKeyShortcut) {
        shortcut = newShortcut
        persistShortcut()
        registerShortcut()
    }

    static func collisionWarning(for shortcut: HotKeyShortcut) -> String? {
        let cmd = UInt32(cmdKey)
        let opt = UInt32(optionKey)

        if shortcut.matches(keyCode: 49, modifiers: cmd) || shortcut.matches(keyCode: 49, modifiers: opt) {
            return "Likely conflicts with Spotlight."
        }

        if shortcut.matches(keyCode: 48, modifiers: cmd) {
            return "Likely conflicts with app switching (Cmd+Tab)."
        }

        if shortcut.matches(keyCode: 12, modifiers: cmd) {
            return "Likely conflicts with quit (Cmd+Q)."
        }

        if shortcut.matches(keyCode: 4, modifiers: cmd) {
            return "Likely conflicts with hide app (Cmd+H)."
        }

        if shortcut.matches(keyCode: 50, modifiers: cmd) {
            return "Likely conflicts with window cycling (Cmd+`)."
        }

        return nil
    }

    private func installEventHandler() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyEventHandler,
            1,
            &eventSpec,
            userData,
            &eventHandlerRef
        )

        if status != noErr {
            print("Failed installing hotkey event handler: \(status)")
        }
    }

    private func registerShortcut() {
        unregisterShortcut()

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: hotKeyIDValue)
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            self.hotKeyRef = hotKeyRef
            warningMessage = Self.collisionWarning(for: shortcut)
            return
        }

        if status == OSStatus(eventHotKeyExistsErr) {
            warningMessage = "This shortcut is already in use by another app or macOS."
            return
        }

        warningMessage = "Unable to register shortcut (code \(status))."
    }

    private func unregisterShortcut() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func persistShortcut() {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static func loadShortcut(defaultsKey: String) -> HotKeyShortcut? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return nil
        }

        return try? JSONDecoder().decode(HotKeyShortcut.self, from: data)
    }

    private static let hotKeyEventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return noErr }

        var eventHotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &eventHotKeyID
        )

        guard status == noErr else { return status }

        let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
        guard eventHotKeyID.signature == manager.hotKeySignature,
              eventHotKeyID.id == manager.hotKeyIDValue else {
            return noErr
        }

        DispatchQueue.main.async {
            manager.onHotKeyPressed?()
        }

        return noErr
    }
}
