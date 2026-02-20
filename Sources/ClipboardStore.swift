import AppKit
import Foundation
import os.signpost

final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var buckets: [Bucket] = []
    @Published private(set) var selectedBucketID: Int64?
    @Published var isSearchExpanded = false
    @Published private(set) var isInlineTitleEditorActive = false

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
    @Published private(set) var isBucketScopeLoading = false
    @Published var selectedIndex: Int = 0

    private let database: ClipboardDatabase
    private var scopedBucketItems: [ClipItem] = []
    private var cachedBucketItemsByID: [Int64: [ClipItem]] = [:]
    private var inFlightBucketCacheLoads: Set<Int64> = []
    private var selectedBucketLoadRequestID: UInt64 = 0

    private var iconCache: [String: NSImage] = [:]
    private var missingBundleIDs: Set<String> = []
    private var pendingIconLookups: Set<String> = []

    private let filterQueue = DispatchQueue(label: "pastebin.search.queue", qos: .userInitiated)
    private let bucketLoadQueue = DispatchQueue(label: "pastebin.bucket.load.queue", qos: .userInitiated, attributes: .concurrent)
    private let iconLookupQueue = DispatchQueue(label: "pastebin.icon.lookup.queue", qos: .userInitiated, attributes: .concurrent)
    private var pendingFilterWork: DispatchWorkItem?
    private var filterRequestID: UInt64 = 0
    private let performanceLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "PasteBin",
        category: "ClipboardStorePerformance"
    )

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
        isInlineTitleEditorActive = false
        isBucketScopeLoading = false
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

    func setInlineTitleEditorActive(_ isActive: Bool) {
        guard isInlineTitleEditorActive != isActive else { return }
        isInlineTitleEditorActive = isActive
    }

    // MARK: - Scope and buckets

    func showClipboardScope() {
        guard selectedBucketID != nil else { return }
        selectedBucketLoadRequestID &+= 1
        selectedBucketID = nil
        isBucketScopeLoading = false
        selectedIndex = 0
        os_signpost(.event, log: performanceLog, name: "ScopeChanged", "scope=%{public}@", "clipboard")
        scheduleFiltering(debounce: 0)
    }

    func showBucketScope(bucketID: Int64) {
        guard selectedBucketID != bucketID else { return }
        selectedBucketLoadRequestID &+= 1
        selectedBucketID = bucketID
        selectedIndex = 0

        if let cached = cachedBucketItemsByID[bucketID] {
            scopedBucketItems = cached
            isBucketScopeLoading = false
            os_signpost(
                .event,
                log: performanceLog,
                name: "ScopeChanged",
                "scope=%{public}@ bucket=%{public}lld cache=%{public}@ rows=%{public}d",
                "bucket",
                bucketID,
                "hit",
                cached.count
            )
            scheduleFiltering(debounce: 0)
            return
        }

        scopedBucketItems = []
        isBucketScopeLoading = true
        os_signpost(
            .event,
            log: performanceLog,
            name: "ScopeChanged",
            "scope=%{public}@ bucket=%{public}lld cache=%{public}@",
            "bucket",
            bucketID,
            "miss"
        )
        scheduleFiltering(debounce: 0)

        if inFlightBucketCacheLoads.contains(bucketID) {
            return
        }

        reloadSelectedBucketItems()
    }

    func createBucketAndSelect() {
        let nextName = nextUntitledBucketName()
        let color = nextDefaultColorHex()

        do {
            let created = try database.createBucket(name: nextName, colorHex: color)
            buckets.append(created)
            cachedBucketItemsByID[created.id] = []
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
            cachedBucketItemsByID[bucketID] = nil
            inFlightBucketCacheLoads.remove(bucketID)
            if selectedBucketID == bucketID {
                selectedBucketLoadRequestID &+= 1
                selectedBucketID = nil
                isBucketScopeLoading = false
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
            cachedBucketItemsByID[bucketID] = nil
            inFlightBucketCacheLoads.remove(bucketID)

            if selectedBucketID == bucketID {
                if let addedItem = items.first(where: { $0.id == clipItemID }) {
                    scopedBucketItems.removeAll(where: { $0.id == clipItemID })
                    scopedBucketItems.insert(addedItem, at: 0)
                    if scopedBucketItems.count > Self.defaultLoadLimit {
                        scopedBucketItems.removeLast(scopedBucketItems.count - Self.defaultLoadLimit)
                    }
                    cachedBucketItemsByID[bucketID] = scopedBucketItems
                    scheduleFiltering(debounce: 0)
                }

                isBucketScopeLoading = scopedBucketItems.isEmpty
                reloadSelectedBucketItems()
            } else {
                prewarmBucketCache(bucketID: bucketID)
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
            cachedBucketItemsByID[selectedBucketID] = scopedBucketItems

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

        _ = queueIconLookupIfNeeded(bundleID: bundleID)
        return fallbackIcon()
    }

    private func preloadIcons(for items: [ClipItem]) {
        let signpostID = OSSignpostID(log: performanceLog)
        os_signpost(
            .begin,
            log: performanceLog,
            name: "IconPreloadBatch",
            signpostID: signpostID,
            "items=%{public}d",
            items.count
        )

        var queuedLookups = 0
        for item in items {
            guard let bundleID = item.sourceBundleID else { continue }
            if queueIconLookupIfNeeded(bundleID: bundleID) {
                queuedLookups += 1
            }
        }

        os_signpost(
            .end,
            log: performanceLog,
            name: "IconPreloadBatch",
            signpostID: signpostID,
            "items=%{public}d queued=%{public}d",
            items.count,
            queuedLookups
        )
    }

    @discardableResult
    private func queueIconLookupIfNeeded(bundleID: String) -> Bool {
        guard iconCache[bundleID] == nil else { return false }
        guard !missingBundleIDs.contains(bundleID) else { return false }
        guard !pendingIconLookups.contains(bundleID) else { return false }

        pendingIconLookups.insert(bundleID)
        let signpostID = OSSignpostID(log: performanceLog)
        let performanceLog = performanceLog
        os_signpost(
            .begin,
            log: performanceLog,
            name: "IconLookup",
            signpostID: signpostID,
            "bundle=%{public}@",
            bundleID
        )

        iconLookupQueue.async { [weak self] in
            let resolvedIcon: NSImage?
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                icon.size = NSSize(width: 28, height: 28)
                resolvedIcon = icon
            } else {
                resolvedIcon = nil
            }

            DispatchQueue.main.async { [weak self] in
                os_signpost(
                    .end,
                    log: performanceLog,
                    name: "IconLookup",
                    signpostID: signpostID,
                    "bundle=%{public}@ resolved=%{public}d",
                    bundleID,
                    resolvedIcon == nil ? 0 : 1
                )

                guard let self else { return }

                self.pendingIconLookups.remove(bundleID)

                if let resolvedIcon {
                    let alreadyCached = self.iconCache[bundleID] != nil
                    self.iconCache[bundleID] = resolvedIcon
                    if !alreadyCached {
                        self.objectWillChange.send()
                    }
                } else {
                    self.missingBundleIDs.insert(bundleID)
                }
            }
        }

        return true
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
        isBucketScopeLoading = false

        let validBucketIDs = Set(loadedBuckets.map(\.id))
        cachedBucketItemsByID = cachedBucketItemsByID.filter { validBucketIDs.contains($0.key) }
        inFlightBucketCacheLoads = inFlightBucketCacheLoads.filter { validBucketIDs.contains($0) }

        if let selectedBucketID {
            cachedBucketItemsByID[selectedBucketID] = bucketItems
        }

        preloadIcons(for: Array(loadedItems.prefix(Self.initialIconPreloadCount)))
        if !bucketItems.isEmpty {
            preloadIcons(for: Array(bucketItems.prefix(Self.initialIconPreloadCount)))
        }

        if resetQuery {
            query = ""
            isSearchExpanded = false
        }

        scheduleFiltering(debounce: 0)
        prewarmBucketCaches(excluding: selectedBucketID)
    }

    private func scheduleFiltering(debounce: TimeInterval) {
        pendingFilterWork?.cancel()

        filterRequestID &+= 1
        let requestID = filterRequestID
        let querySnapshot = query
        let itemsSnapshot = selectedBucketID == nil ? items : scopedBucketItems
        let searchLimit = Self.searchResultLimit
        let unfilteredLimit = Self.unfilteredDisplayLimit
        let perfLog = performanceLog
        let filterSignpostID = OSSignpostID(log: perfLog)

        let work = DispatchWorkItem { [weak self] in
            os_signpost(
                .begin,
                log: perfLog,
                name: "FilterCompute",
                signpostID: filterSignpostID,
                "request=%{public}llu query_len=%{public}d items=%{public}d",
                requestID,
                querySnapshot.count,
                itemsSnapshot.count
            )

            let filtered: [ClipItem]
            let normalizedQuery = FuzzyMatcher.normalize(querySnapshot)
            if normalizedQuery.isEmpty {
                filtered = Array(itemsSnapshot.prefix(unfilteredLimit))
            } else {
                filtered = FuzzyMatcher.filter(normalizedQuery: normalizedQuery, in: itemsSnapshot, limit: searchLimit)
            }

            os_signpost(
                .end,
                log: perfLog,
                name: "FilterCompute",
                signpostID: filterSignpostID,
                "request=%{public}llu results=%{public}d",
                requestID,
                filtered.count
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard requestID == self.filterRequestID else {
                    os_signpost(
                        .event,
                        log: perfLog,
                        name: "FilterDiscarded",
                        "request=%{public}llu latest=%{public}llu",
                        requestID,
                        self.filterRequestID
                    )
                    return
                }

                let applySignpostID = OSSignpostID(log: perfLog)
                os_signpost(
                    .begin,
                    log: perfLog,
                    name: "FilterApply",
                    signpostID: applySignpostID,
                    "request=%{public}llu",
                    requestID
                )

                self.filteredItems = filtered
                self.clampSelectedIndex()

                os_signpost(
                    .end,
                    log: perfLog,
                    name: "FilterApply",
                    signpostID: applySignpostID,
                    "request=%{public}llu results=%{public}d",
                    requestID,
                    filtered.count
                )
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
            selectedBucketLoadRequestID &+= 1
            scopedBucketItems = []
            isBucketScopeLoading = false
            scheduleFiltering(debounce: 0)
            return
        }

        selectedBucketLoadRequestID &+= 1
        let requestID = selectedBucketLoadRequestID
        isBucketScopeLoading = true
        inFlightBucketCacheLoads.insert(selectedBucketID)
        let fetchSignpostID = OSSignpostID(log: performanceLog)
        let perfLog = performanceLog
        os_signpost(
            .begin,
            log: perfLog,
            name: "BucketFetchSelected",
            signpostID: fetchSignpostID,
            "bucket=%{public}lld request=%{public}llu",
            selectedBucketID,
            requestID
        )

        fetchBucketItemsAsync(bucketID: selectedBucketID, qos: .userInitiated) { [weak self] result in
            var rowCount = -1
            var applied = 0
            defer {
                os_signpost(
                    .end,
                    log: perfLog,
                    name: "BucketFetchSelected",
                    signpostID: fetchSignpostID,
                    "bucket=%{public}lld request=%{public}llu rows=%{public}d applied=%{public}d",
                    selectedBucketID,
                    requestID,
                    rowCount,
                    applied
                )
            }

            guard let self else { return }
            self.inFlightBucketCacheLoads.remove(selectedBucketID)

            switch result {
            case .success(let bucketItems):
                rowCount = bucketItems.count
                guard self.buckets.contains(where: { $0.id == selectedBucketID }) else {
                    return
                }

                self.cachedBucketItemsByID[selectedBucketID] = bucketItems
                self.preloadIcons(for: Array(bucketItems.prefix(Self.initialIconPreloadCount)))

                guard requestID == self.selectedBucketLoadRequestID,
                      self.selectedBucketID == selectedBucketID else {
                    return
                }

                self.scopedBucketItems = bucketItems
                self.isBucketScopeLoading = false
                self.scheduleFiltering(debounce: 0)
                applied = 1
            case .failure(let error):
                print("Failed loading bucket items: \(error)")

                guard requestID == self.selectedBucketLoadRequestID,
                      self.selectedBucketID == selectedBucketID else {
                    return
                }

                self.scopedBucketItems = []
                self.isBucketScopeLoading = false
                self.scheduleFiltering(debounce: 0)
                applied = 1
            }
        }
    }

    private func fetchBucketItemsAsync(
        bucketID: Int64,
        qos: DispatchQoS.QoSClass,
        completion: @escaping (Result<[ClipItem], Error>) -> Void
    ) {
        bucketLoadQueue.async(qos: DispatchQoS(qosClass: qos, relativePriority: 0)) { [weak self] in
            guard let self else { return }
            let result: Result<[ClipItem], Error> = Result {
                try self.database.fetchItems(inBucket: bucketID, limit: Self.defaultLoadLimit)
            }

            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private func prewarmBucketCaches(excluding selectedBucketID: Int64?) {
        for bucket in buckets {
            guard bucket.id != selectedBucketID else { continue }
            prewarmBucketCache(bucketID: bucket.id)
        }
    }

    private func prewarmBucketCache(bucketID: Int64) {
        guard cachedBucketItemsByID[bucketID] == nil else { return }
        guard !inFlightBucketCacheLoads.contains(bucketID) else { return }
        inFlightBucketCacheLoads.insert(bucketID)
        let prewarmSignpostID = OSSignpostID(log: performanceLog)
        let perfLog = performanceLog
        os_signpost(
            .begin,
            log: perfLog,
            name: "BucketFetchPrewarm",
            signpostID: prewarmSignpostID,
            "bucket=%{public}lld",
            bucketID
        )

        fetchBucketItemsAsync(bucketID: bucketID, qos: .utility) { [weak self] result in
            var rowCount = -1
            var appliedToVisibleScope = 0
            defer {
                os_signpost(
                    .end,
                    log: perfLog,
                    name: "BucketFetchPrewarm",
                    signpostID: prewarmSignpostID,
                    "bucket=%{public}lld rows=%{public}d applied=%{public}d",
                    bucketID,
                    rowCount,
                    appliedToVisibleScope
                )
            }

            guard let self else { return }
            self.inFlightBucketCacheLoads.remove(bucketID)

            guard case .success(let bucketItems) = result else { return }
            guard self.buckets.contains(where: { $0.id == bucketID }) else { return }
            rowCount = bucketItems.count

            self.cachedBucketItemsByID[bucketID] = bucketItems
            self.preloadIcons(for: Array(bucketItems.prefix(Self.initialIconPreloadCount)))

            guard self.selectedBucketID == bucketID, self.isBucketScopeLoading else {
                return
            }

            self.scopedBucketItems = bucketItems
            self.isBucketScopeLoading = false
            self.scheduleFiltering(debounce: 0)
            appliedToVisibleScope = 1
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
