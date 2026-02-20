import AppKit
import Foundation

final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var buckets: [Bucket] = []
    @Published private(set) var selectedBucketID: Int64?
    @Published var isSearchExpanded = false

    @Published var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            if !query.isEmpty {
                isSearchExpanded = true
            }
            selectedIndex = 0
            scheduleFiltering(debounce: query.isEmpty ? 0 : Self.searchDebounceInterval)
        }
    }

    @Published private(set) var filteredItems: [ClipItem] = []
    @Published private(set) var hasFinishedInitialLoad = false
    @Published var selectedIndex: Int = 0

    private let database: ClipboardDatabase
    private var scopedBucketItems: [ClipItem] = []

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

    var isShowingClipboard: Bool {
        selectedBucketID == nil
    }

    var activeBucket: Bucket? {
        guard let selectedBucketID else { return nil }
        return buckets.first(where: { $0.id == selectedBucketID })
    }

    // MARK: - Data loading

    func reloadFromDatabase(limit: Int = ClipboardStore.defaultLoadLimit, resetQuery: Bool = false) {
        do {
            let loadedItems = try database.fetchRecent(limit: limit)
            let loadedBuckets = try database.fetchBuckets()
            let nextSelectedBucketID = normalizeSelectedBucketID(
                selectedBucketID,
                within: loadedBuckets
            )
            let bucketItems = try fetchBucketItemsIfNeeded(bucketID: nextSelectedBucketID, limit: limit)

            applyLoadedState(
                loadedItems: loadedItems,
                loadedBuckets: loadedBuckets,
                selectedBucketID: nextSelectedBucketID,
                bucketItems: bucketItems,
                resetQuery: resetQuery
            )
        } catch {
            hasFinishedInitialLoad = true
            print("Failed loading clipboard DB: \(error)")
        }
    }

    func reloadFromDatabaseAsync(limit: Int = ClipboardStore.defaultLoadLimit, resetQuery: Bool = false) {
        let selectedBucketIDSnapshot = selectedBucketID

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            do {
                let loadedItems = try self.database.fetchRecent(limit: limit)
                let loadedBuckets = try self.database.fetchBuckets()
                let nextSelectedBucketID = self.normalizeSelectedBucketID(
                    selectedBucketIDSnapshot,
                    within: loadedBuckets
                )
                let bucketItems = try self.fetchBucketItemsIfNeeded(bucketID: nextSelectedBucketID, limit: limit)

                DispatchQueue.main.async { [weak self] in
                    self?.applyLoadedState(
                        loadedItems: loadedItems,
                        loadedBuckets: loadedBuckets,
                        selectedBucketID: nextSelectedBucketID,
                        bucketItems: bucketItems,
                        resetQuery: resetQuery
                    )
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
        isSearchExpanded = false
        selectedBucketID = nil
        scopedBucketItems = []

        if query.isEmpty {
            scheduleFiltering(debounce: 0)
        } else {
            query = ""
            isSearchExpanded = false
        }
    }

    func insert(captured: CapturedClipboardItem) {
        do {
            let inserted = try database.insert(
                content: captured.content,
                sourceBundleID: captured.sourceBundleID,
                sourceAppName: captured.sourceAppName
            )

            if let duplicateIndex = items.firstIndex(where: { $0.id == inserted.id || $0.content == inserted.content }) {
                items.remove(at: duplicateIndex)
            }

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

    // MARK: - Search

    func toggleSearchExpanded() {
        if isSearchExpanded, query.isEmpty {
            isSearchExpanded = false
        } else {
            isSearchExpanded = true
        }
    }

    func collapseSearchIfPossible() {
        if query.isEmpty {
            isSearchExpanded = false
        }
    }

    func beginSearch(with typedText: String) {
        let sanitized = typedText.trimmingCharacters(in: .newlines)
        guard !sanitized.isEmpty else { return }

        isSearchExpanded = true
        query += sanitized
    }

    // MARK: - Scope and buckets

    func showClipboardScope() {
        guard selectedBucketID != nil else { return }
        selectedBucketID = nil
        filteredItems = []
        selectedIndex = 0
        scheduleFiltering(debounce: 0)
    }

    func showBucketScope(bucketID: Int64) {
        guard selectedBucketID != bucketID else { return }
        selectedBucketID = bucketID
        filteredItems = []
        selectedIndex = 0
        reloadSelectedBucketItems()
    }

    func createBucketAndSelect() {
        let nextName = nextUntitledBucketName()
        let color = nextDefaultColorHex()

        do {
            let created = try database.createBucket(name: nextName, colorHex: color)
            buckets.append(created)
            showBucketScope(bucketID: created.id)
        } catch {
            print("Failed creating bucket: \(error)")
        }
    }

    func renameBucket(bucketID: Int64, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            try database.renameBucket(id: bucketID, name: trimmed)

            if let index = buckets.firstIndex(where: { $0.id == bucketID }) {
                buckets[index] = Bucket(id: bucketID, name: trimmed, colorHex: buckets[index].colorHex)
            }
        } catch {
            print("Failed renaming bucket: \(error)")
        }
    }

    func recolorBucket(bucketID: Int64, colorHex: String) {
        do {
            try database.updateBucketColor(id: bucketID, colorHex: colorHex)

            if let index = buckets.firstIndex(where: { $0.id == bucketID }) {
                buckets[index] = Bucket(id: bucketID, name: buckets[index].name, colorHex: colorHex)
            }
        } catch {
            print("Failed recoloring bucket: \(error)")
        }
    }

    func deleteBucket(bucketID: Int64) {
        do {
            try database.deleteBucket(id: bucketID)

            buckets.removeAll(where: { $0.id == bucketID })
            if selectedBucketID == bucketID {
                selectedBucketID = nil
                scopedBucketItems = []
            }

            scheduleFiltering(debounce: 0)
        } catch {
            print("Failed deleting bucket: \(error)")
        }
    }

    func addItemToBucket(clipItemID: Int64, bucketID: Int64) {
        do {
            try database.addClipToBucket(clipItemID: clipItemID, bucketID: bucketID)

            if selectedBucketID == bucketID {
                reloadSelectedBucketItems()
            }
        } catch {
            print("Failed adding item to bucket: \(error)")
        }
    }

    func updateTitleOverrideForSelectedBucket(clipItemID: Int64, title: String?) {
        guard let selectedBucketID else { return }

        let normalizedTitle = normalizeTitle(title)

        do {
            try database.updateBucketItemTitle(
                bucketID: selectedBucketID,
                clipItemID: clipItemID,
                customTitle: normalizedTitle
            )

            if let index = scopedBucketItems.firstIndex(where: { $0.id == clipItemID }) {
                scopedBucketItems[index] = item(scopedBucketItems[index], replacingCustomTitleWith: normalizedTitle)
            }

            scheduleFiltering(debounce: 0)
        } catch {
            print("Failed updating bucket item title: \(error)")
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

    // MARK: - Internals

    private func applyLoadedState(
        loadedItems: [ClipItem],
        loadedBuckets: [Bucket],
        selectedBucketID: Int64?,
        bucketItems: [ClipItem],
        resetQuery: Bool
    ) {
        items = loadedItems
        buckets = loadedBuckets
        self.selectedBucketID = selectedBucketID
        scopedBucketItems = bucketItems
        selectedIndex = 0
        hasFinishedInitialLoad = true

        preloadIcons(for: Array(loadedItems.prefix(Self.initialIconPreloadCount)))
        if !bucketItems.isEmpty {
            preloadIcons(for: Array(bucketItems.prefix(Self.initialIconPreloadCount)))
        }

        if resetQuery {
            query = ""
            isSearchExpanded = false
        }

        scheduleFiltering(debounce: 0)
    }

    private func scheduleFiltering(debounce: TimeInterval) {
        pendingFilterWork?.cancel()

        filterRequestID &+= 1
        let requestID = filterRequestID
        let querySnapshot = query
        let itemsSnapshot = selectedBucketID == nil ? items : scopedBucketItems
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

    private func reloadSelectedBucketItems() {
        guard let selectedBucketID else {
            scopedBucketItems = []
            scheduleFiltering(debounce: 0)
            return
        }

        do {
            let bucketItems = try database.fetchItems(inBucket: selectedBucketID, limit: Self.defaultLoadLimit)
            scopedBucketItems = bucketItems
            preloadIcons(for: Array(bucketItems.prefix(Self.initialIconPreloadCount)))
            scheduleFiltering(debounce: 0)
        } catch {
            print("Failed loading bucket items: \(error)")
            scopedBucketItems = []
            scheduleFiltering(debounce: 0)
        }
    }

    private func fetchBucketItemsIfNeeded(bucketID: Int64?, limit: Int) throws -> [ClipItem] {
        guard let bucketID else { return [] }
        return try database.fetchItems(inBucket: bucketID, limit: limit)
    }

    private func normalizeSelectedBucketID(_ candidate: Int64?, within availableBuckets: [Bucket]) -> Int64? {
        guard let candidate else { return nil }
        return availableBuckets.contains(where: { $0.id == candidate }) ? candidate : nil
    }

    private func nextUntitledBucketName() -> String {
        let base = BucketDefaults.defaultName
        let normalizedNames = Set(buckets.map { $0.name.lowercased() })

        if !normalizedNames.contains(base.lowercased()) {
            return base
        }

        for index in 2...999 {
            let candidate = "\(base) \(index)"
            if !normalizedNames.contains(candidate.lowercased()) {
                return candidate
            }
        }

        return "\(base) \(UUID().uuidString.prefix(4))"
    }

    private func nextDefaultColorHex() -> String {
        let palette = BucketDefaults.colorPalette
        guard !palette.isEmpty else { return BucketDefaults.defaultColorHex }
        return palette[buckets.count % palette.count].hex
    }

    private func normalizeTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func item(_ item: ClipItem, replacingCustomTitleWith customTitle: String?) -> ClipItem {
        ClipItem(
            id: item.id,
            content: item.content,
            copiedAt: item.copiedAt,
            sourceBundleID: item.sourceBundleID,
            sourceAppName: item.sourceAppName,
            customTitle: customTitle
        )
    }

    private func clampSelectedIndex() {
        guard !filteredItems.isEmpty else {
            selectedIndex = 0
            return
        }

        selectedIndex = min(max(selectedIndex, 0), filteredItems.count - 1)
    }
}
