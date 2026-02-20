import AppKit
import Foundation

final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            selectedIndex = 0
            scheduleFiltering(debounce: query.isEmpty ? 0 : Self.searchDebounceInterval)
        }
    }
    @Published private(set) var filteredItems: [ClipItem] = []
    @Published private(set) var hasFinishedInitialLoad = false
    @Published var selectedIndex: Int = 0

    private let database: ClipboardDatabase
    private var iconCache: [String: NSImage] = [:]
    private var missingBundleIDs: Set<String> = []

    private let filterQueue = DispatchQueue(label: "pastebin.search.queue", qos: .userInitiated)
    private var pendingFilterWork: DispatchWorkItem?
    private var filterRequestID: UInt64 = 0

    private lazy var fallbackIconImage: NSImage? = {
        let image = NSImage(systemSymbolName: "app.fill", accessibilityDescription: "Unknown app")
        image?.size = NSSize(width: 28, height: 28)
        return image
    }()

    private static let defaultLoadLimit = 4_000
    private static let initialIconPreloadCount = 24
    private static let unfilteredDisplayLimit = 1_200
    private static let searchResultLimit = 250
    private static let searchDebounceInterval: TimeInterval = 0.04

    init(database: ClipboardDatabase) {
        self.database = database
    }

    deinit {
        pendingFilterWork?.cancel()
    }

    // MARK: - Derived state

    var isLoading: Bool {
        !hasFinishedInitialLoad
    }

    // MARK: - Data loading

    func reloadFromDatabase(limit: Int = ClipboardStore.defaultLoadLimit, resetQuery: Bool = false) {
        do {
            let loaded = try database.fetchRecent(limit: limit)
            applyLoadedItems(loaded, resetQuery: resetQuery)
        } catch {
            hasFinishedInitialLoad = true
            print("Failed loading clipboard DB: \(error)")
        }
    }

    func reloadFromDatabaseAsync(limit: Int = ClipboardStore.defaultLoadLimit, resetQuery: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            do {
                let loaded = try self.database.fetchRecent(limit: limit)
                DispatchQueue.main.async { [weak self] in
                    self?.applyLoadedItems(loaded, resetQuery: resetQuery)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.hasFinishedInitialLoad = true
                }
                print("Failed loading clipboard DB: \(error)")
            }
        }
    }

    func prepareForPresentation() {
        selectedIndex = 0

        if query.isEmpty {
            scheduleFiltering(debounce: 0)
        } else {
            query = ""
        }
    }

    func insert(captured: CapturedClipboardItem) {
        do {
            if items.first?.content == captured.content { return }

            if let duplicateIndex = items.firstIndex(where: { $0.content == captured.content }) {
                items.remove(at: duplicateIndex)
            }

            let inserted = try database.insert(
                content: captured.content,
                sourceBundleID: captured.sourceBundleID,
                sourceAppName: captured.sourceAppName
            )

            items.insert(inserted, at: 0)

            if items.count > Self.defaultLoadLimit {
                items.removeLast(items.count - Self.defaultLoadLimit)
            }

            preloadIcons(for: [inserted])

            if query.isEmpty {
                selectedIndex = 0
            }

            scheduleFiltering(debounce: 0)
        } catch {
            print("Failed inserting clipboard item: \(error)")
        }
    }

    // MARK: - Selection

    func moveSelection(delta: Int) {
        let count = filteredItems.count
        guard count > 0 else {
            selectedIndex = 0
            return
        }

        let nextIndex = selectedIndex + delta
        selectedIndex = min(max(nextIndex, 0), count - 1)
    }

    func select(_ index: Int) {
        let count = filteredItems.count
        guard count > 0 else {
            selectedIndex = 0
            return
        }

        selectedIndex = min(max(index, 0), count - 1)
    }

    func selectedItem() -> ClipItem? {
        guard filteredItems.indices.contains(selectedIndex) else { return nil }
        return filteredItems[selectedIndex]
    }

    func item(at index: Int) -> ClipItem? {
        guard filteredItems.indices.contains(index) else { return nil }
        return filteredItems[index]
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

    private func fallbackIcon() -> NSImage? {
        fallbackIconImage
    }

    private func applyLoadedItems(_ loaded: [ClipItem], resetQuery: Bool) {
        items = loaded
        selectedIndex = 0
        hasFinishedInitialLoad = true

        preloadIcons(for: Array(loaded.prefix(Self.initialIconPreloadCount)))

        if resetQuery {
            query = ""
        }

        scheduleFiltering(debounce: 0)
    }

    private func scheduleFiltering(debounce: TimeInterval) {
        pendingFilterWork?.cancel()

        filterRequestID &+= 1
        let requestID = filterRequestID
        let querySnapshot = query
        let itemsSnapshot = items
        let searchLimit = Self.searchResultLimit
        let unfilteredLimit = Self.unfilteredDisplayLimit

        let work = DispatchWorkItem { [weak self] in
            let filtered: [ClipItem]
            if FuzzyMatcher.normalize(querySnapshot).isEmpty {
                filtered = Array(itemsSnapshot.prefix(unfilteredLimit))
            } else {
                filtered = FuzzyMatcher.filter(query: querySnapshot, in: itemsSnapshot, limit: searchLimit)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard requestID == self.filterRequestID else { return }

                self.filteredItems = filtered
                self.clampSelectedIndex()
            }
        }

        pendingFilterWork = work

        if debounce <= 0 {
            filterQueue.async(execute: work)
        } else {
            filterQueue.asyncAfter(deadline: .now() + debounce, execute: work)
        }
    }

    private func clampSelectedIndex() {
        guard !filteredItems.isEmpty else {
            selectedIndex = 0
            return
        }

        selectedIndex = min(max(selectedIndex, 0), filteredItems.count - 1)
    }
}
