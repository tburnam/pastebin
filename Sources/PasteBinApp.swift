import SwiftUI

@main
struct PasteBinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            PasteBinSettingsView(
                hotKeyManager: HotKeyManager.shared,
                appSettings: AppSettings.shared
            )
        }
    }
}
