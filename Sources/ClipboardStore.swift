import AppKit
import Foundation

final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published var query: String = ""
    @Published var selectedIndex: Int = 0

    private let database: ClipboardDatabase
    private var iconCache: [String: NSImage] = [:]
    private var missingBundleIDs: Set<String> = []

    init(database: ClipboardDatabase) {
        self.database = database
    }

    // MARK: - Derived state

    var filteredItems: [ClipItem] {
        FuzzyMatcher.filter(query: query, in: items)
    }

    // MARK: - Data loading

    func reloadFromDatabase(limit: Int = 1200, resetQuery: Bool = false) {
        do {
            let loaded = try database.fetchRecent(limit: limit)
            items = loaded
            preloadIcons(for: Array(loaded.prefix(30)))

            if resetQuery { query = "" }
            selectedIndex = 0

            if loaded.count > 30 {
                let remaining = Array(loaded.dropFirst(30))
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.preloadIconsBackground(for: remaining)
                }
            }
        } catch {
            print("Failed loading clipboard DB: \(error)")
        }
    }

    func prepareForPresentation() {
        query = ""
        selectedIndex = 0
    }

    func insert(captured: CapturedClipboardItem) {
        do {
            if items.first?.content == captured.content { return }

            items.removeAll { $0.content == captured.content }

            let inserted = try database.insert(
                content: captured.content,
                sourceBundleID: captured.sourceBundleID,
                sourceAppName: captured.sourceAppName
            )

            items.insert(inserted, at: 0)
            preloadIcons(for: [inserted])
        } catch {
            print("Failed inserting clipboard item: \(error)")
        }
    }

    // MARK: - Selection

    func moveSelection(delta: Int) {
        let count = filteredItems.count
        guard count > 0 else { selectedIndex = 0; return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    func select(_ index: Int) {
        let count = filteredItems.count
        guard count > 0 else { selectedIndex = 0; return }
        selectedIndex = min(max(index, 0), count - 1)
    }

    func selectedItem() -> ClipItem? {
        let items = filteredItems
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    func item(at index: Int) -> ClipItem? {
        let items = filteredItems
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    // MARK: - Icons

    func icon(for item: ClipItem) -> NSImage? {
        guard let bundleID = item.sourceBundleID else {
            return fallbackIcon()
        }

        if let cached = iconCache[bundleID] {
            return cached
        }

        if missingBundleIDs.contains(bundleID) {
            return fallbackIcon()
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            missingBundleIDs.insert(bundleID)
            return fallbackIcon()
        }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 28, height: 28)
        iconCache[bundleID] = icon

        return icon
    }

    private func preloadIcons(for items: [ClipItem]) {
        for item in items {
            guard let bundleID = item.sourceBundleID,
                  iconCache[bundleID] == nil,
                  !missingBundleIDs.contains(bundleID) else {
                continue
            }

            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                icon.size = NSSize(width: 28, height: 28)
                iconCache[bundleID] = icon
            } else {
                missingBundleIDs.insert(bundleID)
            }
        }
    }

    private func preloadIconsBackground(for items: [ClipItem]) {
        var newIcons: [String: NSImage] = [:]
        var newMissing: Set<String> = []

        for item in items {
            guard let bundleID = item.sourceBundleID else { continue }

            if iconCache[bundleID] != nil || missingBundleIDs.contains(bundleID) || newIcons[bundleID] != nil || newMissing.contains(bundleID) {
                continue
            }

            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                icon.size = NSSize(width: 28, height: 28)
                newIcons[bundleID] = icon
            } else {
                newMissing.insert(bundleID)
            }
        }

        guard !newIcons.isEmpty || !newMissing.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.iconCache.merge(newIcons) { current, _ in current }
            self.missingBundleIDs.formUnion(newMissing)
        }
    }

    private func fallbackIcon() -> NSImage? {
        NSImage(systemSymbolName: "app.fill", accessibilityDescription: "Unknown app")
    }
}
