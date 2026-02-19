import SwiftUI

@main
struct PasteBinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var hotKeyManager = HotKeyManager.shared

    var body: some Scene {
        Settings {
            HotKeySettingsView(hotKeyManager: hotKeyManager)
        }
    }
}
