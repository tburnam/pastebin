import AppKit
import Foundation
import os.signpost

enum SearchRenderMode: String, Equatable {
    case lightweightTyping
    case interactiveNavigation
    case fullIdle
}

private final class CachedExtendedSearchText: NSObject {
    let normalizedUTF8: ContiguousArray<UInt8>
    let fingerprint: SearchFingerprint

    init(normalizedUTF8: ContiguousArray<UInt8>) {
        self.normalizedUTF8 = normalizedUTF8
        fingerprint = SearchFingerprint(bytes: normalizedUTF8)
    }
}

final class PayloadPreviewStore: ObservableObject {
    private struct DecodedPreview {
        let image: NSImage?
        let rtf: NSAttributedString?
        let html: NSAttributedString?

        var hasAnyPayload: Bool {
            image != nil || rtf != nil || html != nil
        }
    }

    private let database: ClipboardDatabase
    private let loadQueue = DispatchQueue(label: "pastebin.payload.preview.queue", qos: .userInitiated, attributes: .concurrent)

    private let imageCache: NSCache<NSNumber, NSImage> = {
        let cache = NSCache<NSNumber, NSImage>()
        cache.countLimit = 320
        return cache
    }()

    private let rtfCache: NSCache<NSNumber, NSAttributedString> = {
        let cache = NSCache<NSNumber, NSAttributedString>()
        cache.countLimit = 320
        return cache
    }()

    private let htmlCache: NSCache<NSNumber, NSAttributedString> = {
        let cache = NSCache<NSNumber, NSAttributedString>()
        cache.countLimit = 320
        return cache
    }()

    private var inFlightLoads: Set<Int64> = []
    private var failedLoads: Set<Int64> = []
    private var changeObservers: [UUID: (Int64) -> Void] = [:]

    init(database: ClipboardDatabase) {
        self.database = database
    }

    func imagePayload(for itemID: Int64) -> NSImage? {
        imageCache.object(forKey: NSNumber(value: itemID))
    }

    func rtfPayload(for itemID: Int64) -> NSAttributedString? {
        rtfCache.object(forKey: NSNumber(value: itemID))
    }

    func htmlPayload(for itemID: Int64) -> NSAttributedString? {
        htmlCache.object(forKey: NSNumber(value: itemID))
    }

    @discardableResult
    func addChangeObserver(_ observer: @escaping (Int64) -> Void) -> UUID {
        let token = UUID()
        changeObservers[token] = observer
        return token
    }

    func removeChangeObserver(_ token: UUID) {
        changeObservers[token] = nil
    }

    func loadIfNeeded(for itemID: Int64) {
        let key = NSNumber(value: itemID)
        guard imageCache.object(forKey: key) == nil
                && rtfCache.object(forKey: key) == nil
                && htmlCache.object(forKey: key) == nil else {
            return
        }
        guard !inFlightLoads.contains(itemID) else { return }
        guard !failedLoads.contains(itemID) else { return }

        inFlightLoads.insert(itemID)

        let database = self.database
        loadQueue.async { [weak self] in
            let preview: PayloadPreview?
            do {
                preview = try database.fetchPayloadPreview(id: itemID)
            } catch {
                preview = nil
            }

            let decodedPreview: DecodedPreview?
            if let preview {
                var image: NSImage?
                var rtf: NSAttributedString?
                var html: NSAttributedString?

                if let payloadData = preview.payloadData {
                    image = PreviewImageDecoder.previewImage(from: payloadData)
                }

                if let rtfData = preview.rtfData,
                   rtfData.count <= ClipboardContentLimits.maxRichPreviewPayloadBytes {
                    if let parsedRTF = try? NSAttributedString(
                        data: rtfData,
                        options: [.documentType: NSAttributedString.DocumentType.rtf],
                        documentAttributes: nil
                    ) {
                        rtf = Self.sanitizedRichPreview(parsedRTF)
                    }
                }

                if let htmlContent = preview.htmlContent,
                   htmlContent.utf8.count <= ClipboardContentLimits.maxRichPreviewPayloadBytes,
                   let htmlData = htmlContent.data(using: .utf8) {
                    if let parsedHTML = try? NSAttributedString(
                        data: htmlData,
                        options: [
                            .documentType: NSAttributedString.DocumentType.html,
                            .characterEncoding: String.Encoding.utf8.rawValue
                        ],
                        documentAttributes: nil
                    ) {
                        html = Self.sanitizedRichPreview(parsedHTML)
                    }
                }

                decodedPreview = DecodedPreview(image: image, rtf: rtf, html: html)
            } else {
                decodedPreview = nil
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlightLoads.remove(itemID)

                guard let decodedPreview else {
                    self.failedLoads.insert(itemID)
                    return
                }

                if let image = decodedPreview.image {
                    self.imageCache.setObject(image, forKey: key)
                }

                if let attributed = decodedPreview.rtf {
                    self.rtfCache.setObject(attributed, forKey: key)
                }

                if let attributed = decodedPreview.html {
                    self.htmlCache.setObject(attributed, forKey: key)
                }

                if !decodedPreview.hasAnyPayload {
                    self.failedLoads.insert(itemID)
                }
                for observer in self.changeObservers.values {
                    observer(itemID)
                }
            }
        }
    }

    private static func sanitizedRichPreview(_ attributed: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: mutable.length)
        var attachmentRanges: [NSRange] = []

        mutable.enumerateAttribute(.attachment, in: fullRange) { value, range, _ in
            if value != nil {
                attachmentRanges.append(range)
            }
        }

        for range in attachmentRanges.reversed() {
            mutable.replaceCharacters(in: range, with: " ")
        }

        let maxLength = ClipboardContentLimits.maxRenderedRichPreviewCharacters
        if mutable.length > maxLength {
            mutable.deleteCharacters(in: NSRange(location: maxLength, length: mutable.length - maxLength))
        }

        return mutable
    }
}

final class ClipSelectionState: ObservableObject {
    @Published private(set) var selectedItemID: Int64?

    func setSelectedItemID(_ itemID: Int64?) {
        guard selectedItemID != itemID else { return }
        selectedItemID = itemID
    }
}

final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var buckets: [Bucket] = []
    @Published private(set) var selectedBucketID: Int64?
    @Published var isSearchExpanded = false
    @Published private(set) var isInlineTitleEditorActive = false
    @Published private(set) var shouldFocusSearchField = false
    @Published private(set) var searchFieldFocusRevision: UInt64 = 0

    @Published var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            if !query.isEmpty, !isSearchExpanded {
                isSearchExpanded = true
            }
            scheduleFiltering(debounce: query.isEmpty ? 0 : Self.searchDebounceInterval)
        }
    }

    @Published private(set) var searchRenderMode: SearchRenderMode = .fullIdle
    @Published private(set) var isSearchComputationInFlight = false
    @Published private(set) var filteredItems: [ClipItem] = []
    @Published private(set) var hasFinishedInitialLoad = false
    @Published private(set) var isBucketScopeLoading = false
    let selectionState = ClipSelectionState()
    var selectedIndex: Int = 0 {
        didSet {
            guard selectedIndex != oldValue else { return }
            syncSelectionState()
        }
    }

    private let database: ClipboardDatabase
    private(set) lazy var payloadStore = PayloadPreviewStore(database: database)
    private var scopedBucketItems: [ClipItem] = []
    private var cachedBucketItemsByID: [Int64: [ClipItem]] = [:]
    private var partialBucketCacheIDs: Set<Int64> = []
    private var inFlightBucketCacheLoads: Set<Int64> = []
    private var selectedBucketLoadRequestID: UInt64 = 0

    private var iconCache: [String: NSImage] = [:]
    private var iconCacheInsertOrder: [String] = []
    private var missingBundleIDs: Set<String> = []
    private var pendingIconLookups: Set<String> = []
    private var iconObservers: [UUID: (String) -> Void] = [:]
    private let extendedSearchCache: NSCache<NSNumber, CachedExtendedSearchText> = {
        let cache = NSCache<NSNumber, CachedExtendedSearchText>()
        cache.countLimit = 192
        return cache
    }()

    private let filterQueue = DispatchQueue(label: "pastebin.search.queue", qos: .userInitiated)
    private let insertQueue = DispatchQueue(label: "pastebin.capture.insert.queue", qos: .userInitiated)
    private let bucketLoadQueue = DispatchQueue(label: "pastebin.bucket.load.queue", qos: .userInitiated, attributes: .concurrent)
    private let iconLookupQueue = DispatchQueue(label: "pastebin.icon.lookup.queue", qos: .userInitiated, attributes: .concurrent)
    private var pendingFilterWork: DispatchWorkItem?
    private var pendingNavigationRenderIdleWork: DispatchWorkItem?
    private var pendingSelectionRestoreItemID: Int64?
    private var filterRequestID: UInt64 = 0
    private var searchCorpusRevision: UInt64 = 0
    private var searchCache: SearchCache?
    private var visibleNormalizedQuery = ""
    private var hasNavigationRenderActivity = false
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
    private static let prewarmLoadLimit = 50
    private static let initialIconPreloadCount = 24
    private static let unfilteredDisplayLimit = 1_200
    private static let searchResultLimit = 120
    private static let searchDebounceInterval: TimeInterval = 0.05
    private static let fuzzyFallbackIdleDelay: TimeInterval = 0
    private static let fuzzyFallbackPollInterval: TimeInterval = 0.008
    private static let navigationRenderIdleDelay: TimeInterval = 0.18
    private static let indexedDirectResultPoolLimit = 240
    private static let indexedCandidatePoolLimit = 384
    private static let indexedSearchMinimumTokenCharacterCount = 3
    private static let strictRerankCandidateLimit = 240
    private static let maxCachedIcons = 320
    private static let maxMissingBundleIDs = 1_024

    private enum BucketFetchMode {
        case background
        case interaction
    }

    private enum SearchCacheKind {
        case localStrict
        case extendedStrict
        case indexedStrict
    }

    private enum FilterSelectionBehavior {
        case preserveCurrent
        case resetToFirstResult
    }

    private struct SearchScopeKey: Equatable {
        let selectedBucketID: Int64?
        let corpusRevision: UInt64
    }

    private struct SearchCache {
        let scopeKey: SearchScopeKey
        let normalizedQuery: String
        let kind: SearchCacheKind
        let strictMatches: [ClipItem]
    }

    private struct IndexedSearchCandidateSet {
        let items: [ClipItem]
        let orderByID: [Int64: Int]
    }

    init(database: ClipboardDatabase) {
        self.database = database
    }

    deinit {
        pendingFilterWork?.cancel()
        pendingNavigationRenderIdleWork?.cancel()
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
        pendingSelectionRestoreItemID = nil
        pendingNavigationRenderIdleWork?.cancel()
        pendingNavigationRenderIdleWork = nil
        hasNavigationRenderActivity = false
        relinquishSearchFieldFocus()
        setSearchComputationInFlight(false, requestID: filterRequestID)
        setSearchRenderMode(.fullIdle, requestID: filterRequestID)
        bumpSearchCorpusRevision()

        if query.isEmpty {
            scheduleFiltering(debounce: 0)
        } else {
            query = ""
            isSearchExpanded = false
        }
    }

    func insert(captured: CapturedClipboardItem) {
        insertQueue.async { [weak self] in
            guard let self else { return }

            do {
                let inserted = try self.database.insert(captured: captured)

                let prunedCount: Int
                do {
                    prunedCount = try self.pruneHistoryForCurrentRetention(referenceDate: inserted.copiedAt)
                } catch {
                    print("Failed applying retention policy after insert: \(error)")
                    prunedCount = 0
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if prunedCount > 0 {
                        self.reloadFromDatabaseAsync()
                        return
                    }

                    self.applyInsertedItem(inserted)
                }
            } catch {
                print("Failed inserting clipboard item: \(error)")
            }
        }
    }

    func fetchContentForPaste(itemID: Int64) -> PasteContent? {
        try? database.fetchContentForPaste(id: itemID)
    }

    func promoteItem(id: Int64) {
        do {
            try database.promoteItem(id: id)
            let now = Date()

            if let index = items.firstIndex(where: { $0.id == id }) {
                let promoted = items[index].promoted(at: now)
                items.remove(at: index)
                items.insert(promoted, at: 0)
            }

            if query.isEmpty {
                selectedIndex = 0
            }

            bumpSearchCorpusRevision()
            scheduleFiltering(debounce: 0)
        } catch {
            print("Failed promoting clip item: \(error)")
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
        requestSearchFieldFocus()
    }

    func requestSearchFieldFocus() {
        shouldFocusSearchField = true
        searchFieldFocusRevision &+= 1
    }

    func relinquishSearchFieldFocus() {
        shouldFocusSearchField = false
        searchFieldFocusRevision &+= 1
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
        bumpSearchCorpusRevision()
        scheduleFiltering(debounce: 0)
    }

    func showBucketScope(bucketID: Int64) {
        guard selectedBucketID != bucketID else { return }
        selectedBucketLoadRequestID &+= 1
        let requestID = selectedBucketLoadRequestID
        selectedBucketID = bucketID
        selectedIndex = 0

        if let cached = cachedBucketItemsByID[bucketID] {
            let isPartial = partialBucketCacheIDs.contains(bucketID)
            scopedBucketItems = cached
            isBucketScopeLoading = false
            os_signpost(
                .event,
                log: performanceLog,
                name: "ScopeChanged",
                "scope=%{public}@ bucket=%{public}lld cache=%{public}@ rows=%{public}d",
                "bucket",
                bucketID,
                isPartial ? "partial" : "hit",
                cached.count
            )
            bumpSearchCorpusRevision()
            scheduleFiltering(debounce: 0)

            if isPartial {
                loadFullBucketInBackground(bucketID: bucketID)
            }
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
        bumpSearchCorpusRevision()
        scheduleFiltering(debounce: 0)

        let quickFetchSignpostID = OSSignpostID(log: performanceLog)
        let perfLog = performanceLog
        os_signpost(
            .begin,
            log: perfLog,
            name: "BucketFetchQuickPage",
            signpostID: quickFetchSignpostID,
            "bucket=%{public}lld request=%{public}llu",
            bucketID,
            requestID
        )

        fetchBucketItemsAsync(
            bucketID: bucketID,
            qos: .userInitiated,
            limit: Self.prewarmLoadLimit,
            mode: .interaction
        ) { [weak self] result in
            var rowCount = -1
            var applied = 0
            defer {
                os_signpost(
                    .end,
                    log: perfLog,
                    name: "BucketFetchQuickPage",
                    signpostID: quickFetchSignpostID,
                    "bucket=%{public}lld request=%{public}llu rows=%{public}d applied=%{public}d",
                    bucketID,
                    requestID,
                    rowCount,
                    applied
                )
            }

            guard let self else { return }
            guard self.buckets.contains(where: { $0.id == bucketID }) else { return }

            switch result {
            case .success(let quickPage):
                rowCount = quickPage.count
                let isPartial = quickPage.count >= Self.prewarmLoadLimit
                self.cachedBucketItemsByID[bucketID] = quickPage
                if isPartial {
                    self.partialBucketCacheIDs.insert(bucketID)
                } else {
                    self.partialBucketCacheIDs.remove(bucketID)
                }
                self.preloadIcons(for: Array(quickPage.prefix(Self.initialIconPreloadCount)))

                guard requestID == self.selectedBucketLoadRequestID,
                      self.selectedBucketID == bucketID else {
                    return
                }

                self.scopedBucketItems = quickPage
                self.isBucketScopeLoading = false
                self.bumpSearchCorpusRevision()
                self.scheduleFiltering(debounce: 0)
                applied = 1

                if isPartial {
                    self.loadFullBucketInBackground(bucketID: bucketID)
                }
            case .failure(let error):
                print("Failed loading bucket quick page: \(error)")

                guard requestID == self.selectedBucketLoadRequestID,
                      self.selectedBucketID == bucketID else {
                    return
                }

                self.scopedBucketItems = []
                self.isBucketScopeLoading = true
                self.bumpSearchCorpusRevision()
                self.scheduleFiltering(debounce: 0)
                self.reloadSelectedBucketItems()
                applied = 1
            }
        }
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

    func deleteSelectedItem() {
        guard let item = selectedItem() else { return }

        do {
            try database.deleteClipItem(id: item.id)

            items.removeAll(where: { $0.id == item.id })
            scopedBucketItems.removeAll(where: { $0.id == item.id })

            for bucketID in cachedBucketItemsByID.keys {
                cachedBucketItemsByID[bucketID]?.removeAll(where: { $0.id == item.id })
            }

            if let removedFilteredIndex = filteredItems.firstIndex(where: { $0.id == item.id }) {
                pendingSelectionRestoreItemID = Self.preferredSelectionRestoreItemID(
                    afterRemovingItemAt: removedFilteredIndex,
                    from: filteredItems.map(\.id)
                )
                filteredItems.remove(at: removedFilteredIndex)
                if let pendingSelectionRestoreItemID,
                   let restoredIndex = filteredItems.firstIndex(where: { $0.id == pendingSelectionRestoreItemID }) {
                    selectedIndex = restoredIndex
                } else if selectedIndex > removedFilteredIndex {
                    selectedIndex -= 1
                }
                clampSelectedIndex()
            } else {
                let count = filteredItems.count
                if selectedIndex >= count {
                    selectedIndex = max(count - 1, 0)
                }
            }

            bumpSearchCorpusRevision()
            scheduleFiltering(debounce: 0)
        } catch {
            print("Failed deleting clip item: \(error)")
        }
    }

    func deleteBucket(bucketID: Int64) {
        do {
            try database.deleteBucket(id: bucketID)

            buckets.removeAll(where: { $0.id == bucketID })
            cachedBucketItemsByID[bucketID] = nil
            partialBucketCacheIDs.remove(bucketID)
            inFlightBucketCacheLoads.remove(bucketID)
            if selectedBucketID == bucketID {
                selectedBucketLoadRequestID &+= 1
                selectedBucketID = nil
                isBucketScopeLoading = false
                scopedBucketItems = []
            }

            bumpSearchCorpusRevision()
            scheduleFiltering(debounce: 0)
        } catch {
            print("Failed deleting bucket: \(error)")
        }
    }

    func addItemToBucket(clipItemID: Int64, bucketID: Int64) {
        do {
            try database.addClipToBucket(clipItemID: clipItemID, bucketID: bucketID)
            cachedBucketItemsByID[bucketID] = nil
            partialBucketCacheIDs.remove(bucketID)
            inFlightBucketCacheLoads.remove(bucketID)

            if selectedBucketID == bucketID {
                if let addedItem = items.first(where: { $0.id == clipItemID }) {
                    scopedBucketItems.removeAll(where: { $0.id == clipItemID })
                    scopedBucketItems.insert(addedItem, at: 0)
                    if scopedBucketItems.count > Self.defaultLoadLimit {
                        scopedBucketItems.removeLast(scopedBucketItems.count - Self.defaultLoadLimit)
                    }
                    cachedBucketItemsByID[bucketID] = scopedBucketItems
                    bumpSearchCorpusRevision()
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

            bumpSearchCorpusRevision()
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
        let clampedIndex = min(max(nextIndex, 0), count - 1)
        guard clampedIndex != selectedIndex else { return }
        markNavigationRenderActivity()
        selectedIndex = clampedIndex
    }

    func select(_ index: Int) {
        let count = filteredItems.count
        guard count > 0 else {
            selectedIndex = 0
            return
        }

        let clampedIndex = min(max(index, 0), count - 1)
        guard clampedIndex != selectedIndex else { return }
        markNavigationRenderActivity()
        selectedIndex = clampedIndex
    }

    func selectByID(_ id: Int64) {
        guard let index = filteredItems.firstIndex(where: { $0.id == id }) else { return }
        guard index != selectedIndex else { return }
        markNavigationRenderActivity()
        selectedIndex = index
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

    @discardableResult
    func addIconObserver(_ observer: @escaping (String) -> Void) -> UUID {
        let token = UUID()
        iconObservers[token] = observer
        return token
    }

    func removeIconObserver(_ token: UUID) {
        iconObservers[token] = nil
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
                    self.cacheResolvedIcon(resolvedIcon, for: bundleID)
                } else {
                    self.markMissingBundleID(bundleID)
                }
            }
        }

        return true
    }

    private func fallbackIcon() -> NSImage? {
        fallbackIconImage
    }

    private func pruneHistoryForCurrentRetention(referenceDate: Date) throws -> Int {
        let cutoffDate = AppSettings.shared.retentionPeriod.cutoffDate(referenceDate: referenceDate)
        return try database.pruneHistory(olderThan: cutoffDate)
    }

    private func cacheResolvedIcon(_ icon: NSImage, for bundleID: String) {
        guard iconCache[bundleID] == nil else { return }
        iconCache[bundleID] = icon
        iconCacheInsertOrder.append(bundleID)

        if iconCacheInsertOrder.count > Self.maxCachedIcons {
            let overflow = iconCacheInsertOrder.count - Self.maxCachedIcons
            for i in 0..<overflow {
                iconCache[iconCacheInsertOrder[i]] = nil
            }
            iconCacheInsertOrder.removeFirst(overflow)
        }
        for observer in iconObservers.values {
            observer(bundleID)
        }
    }

    private func markMissingBundleID(_ bundleID: String) {
        missingBundleIDs.insert(bundleID)
        if missingBundleIDs.count > Self.maxMissingBundleIDs {
            missingBundleIDs = Set(missingBundleIDs.prefix(Self.maxMissingBundleIDs))
        }
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
        partialBucketCacheIDs = partialBucketCacheIDs.filter { validBucketIDs.contains($0) }
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

        bumpSearchCorpusRevision()
        scheduleFiltering(debounce: 0)
        prewarmBucketCaches(excluding: selectedBucketID)
    }

    private func applyFilteredItems(
        _ newItems: [ClipItem],
        selectionBehavior: FilterSelectionBehavior,
        isFinalApply: Bool
    ) {
        let currentSelectionItemID: Int64?
        switch selectionBehavior {
        case .preserveCurrent:
            currentSelectionItemID = currentSelectedItemID
        case .resetToFirstResult:
            currentSelectionItemID = nil
        }
        let restoreSelectionItemID = pendingSelectionRestoreItemID ?? currentSelectionItemID

        if !filteredItemsMatch(newItems) {
            filteredItems = newItems
        }

        if let restoreSelectionItemID,
           let restoredIndex = newItems.firstIndex(where: { $0.id == restoreSelectionItemID }) {
            if selectedIndex != restoredIndex {
                selectedIndex = restoredIndex
            }
            if pendingSelectionRestoreItemID == restoreSelectionItemID {
                pendingSelectionRestoreItemID = nil
            }
        } else if isFinalApply, pendingSelectionRestoreItemID != nil {
            pendingSelectionRestoreItemID = nil
        }

        if restoreSelectionItemID == nil, selectionBehavior == .resetToFirstResult, selectedIndex != 0 {
            selectedIndex = 0
        }

        clampSelectedIndex()
    }

    private func provisionalFilteredItems(
        normalizedQuery: String,
        queryTokens: [Substring],
        items: [ClipItem],
        queryChanged: Bool,
        previousCache: SearchCache?,
        searchScopeKey: SearchScopeKey,
        searchLimit: Int,
        unfilteredLimit: Int
    ) -> [ClipItem] {
        if !queryChanged {
            let itemIDs = Set(items.map(\.id))
            return filteredItems.filter { itemIDs.contains($0.id) }
        }

        guard !normalizedQuery.isEmpty else {
            return Array(items.prefix(unfilteredLimit))
        }

        let strictSearchPool = reusableLocalStrictSearchPool(
            previousCache: previousCache,
            for: searchScopeKey,
            normalizedQuery: normalizedQuery
        ) ?? items

        let strictMatches = FuzzyMatcher.strictFilter(
            normalizedQuery: normalizedQuery,
            in: strictSearchPool,
            limit: Self.strictRerankCandidateLimit
        )

        guard !strictMatches.isEmpty else {
            return []
        }

        return SearchRanker.rerank(
            normalizedQuery: normalizedQuery,
            queryTokens: queryTokens,
            candidates: strictMatches,
            limit: searchLimit
        )
    }

    static func preferredSelectionRestoreItemID(
        afterRemovingItemAt removedIndex: Int,
        from itemIDs: [Int64]
    ) -> Int64? {
        guard itemIDs.indices.contains(removedIndex) else { return nil }

        let nextIndex = removedIndex + 1
        if itemIDs.indices.contains(nextIndex) {
            return itemIDs[nextIndex]
        }

        let previousIndex = removedIndex - 1
        if itemIDs.indices.contains(previousIndex) {
            return itemIDs[previousIndex]
        }

        return nil
    }

    private func syncSelectionState() {
        selectionState.setSelectedItemID(currentSelectedItemID)
    }

    private func bumpSearchCorpusRevision() {
        searchCorpusRevision &+= 1
        searchCache = nil
        extendedSearchCache.removeAllObjects()
    }

    private func cachedExtendedSearchContent(
        for item: ClipItem,
        database: ClipboardDatabase,
        shouldContinue: @escaping () -> Bool
    ) -> CachedExtendedSearchText? {
        let cacheKey = NSNumber(value: item.id)
        if let cached = extendedSearchCache.object(forKey: cacheKey) {
            return cached
        }

        guard let fullText = database.fetchExtendedSearchText(id: item.id) else {
            return nil
        }
        guard shouldContinue() else { return nil }

        let searchableSource = ([fullText, item.customTitle].compactMap { $0 })
            .joined(separator: " ")
        let boundedSearchable = ClipboardContentLimits.searchProjection(
            searchableSource,
            to: ClipboardContentLimits.maxExtendedSearchUTF8Bytes
        )
        let normalizedUTF8 = ContiguousArray(FuzzyMatcher.normalize(boundedSearchable).utf8)
        let cached = CachedExtendedSearchText(normalizedUTF8: normalizedUTF8)
        extendedSearchCache.setObject(cached, forKey: cacheKey)
        return cached
    }

    private func reusableLocalStrictSearchPool(
        previousCache: SearchCache?,
        for scopeKey: SearchScopeKey,
        normalizedQuery: String
    ) -> [ClipItem]? {
        guard let previousCache else { return nil }
        guard previousCache.kind == .localStrict || previousCache.kind == .extendedStrict else { return nil }
        guard previousCache.scopeKey == scopeKey else { return nil }
        guard !previousCache.strictMatches.isEmpty else { return nil }
        guard normalizedQuery.count > previousCache.normalizedQuery.count else { return nil }
        guard normalizedQuery.hasPrefix(previousCache.normalizedQuery) else { return nil }
        return previousCache.strictMatches
    }

    private func beginSearchComputation(requestID: UInt64, shouldShowSearchComputationState: Bool) {
        if shouldShowSearchComputationState {
            setSearchComputationInFlight(true, requestID: requestID)
        } else {
            setSearchComputationInFlight(false, requestID: requestID)
        }
        refreshRenderMode(requestID: requestID)
    }

    private func endSearchComputation(requestID: UInt64) {
        guard requestID == filterRequestID else { return }
        setSearchComputationInFlight(false, requestID: requestID)
        refreshRenderMode(requestID: requestID)
    }

    private func setSearchRenderMode(_ mode: SearchRenderMode, requestID: UInt64) {
        guard searchRenderMode != mode else { return }
        searchRenderMode = mode
        os_signpost(
            .event,
            log: performanceLog,
            name: "SearchRenderModeChanged",
            "request=%{public}llu mode=%{public}@",
            requestID,
            mode.rawValue as NSString
        )
    }

    private func setSearchComputationInFlight(_ isInFlight: Bool, requestID: UInt64) {
        guard isSearchComputationInFlight != isInFlight else { return }
        isSearchComputationInFlight = isInFlight
        os_signpost(
            .event,
            log: performanceLog,
            name: "SearchComputationStateChanged",
            "request=%{public}llu in_flight=%{public}d",
            requestID,
            isInFlight ? 1 : 0
        )
    }

    private func refreshRenderMode(requestID: UInt64) {
        let mode: SearchRenderMode
        if isSearchComputationInFlight {
            mode = .lightweightTyping
        } else if hasNavigationRenderActivity {
            mode = .interactiveNavigation
        } else {
            mode = .fullIdle
        }
        setSearchRenderMode(mode, requestID: requestID)
    }

    private func markNavigationRenderActivity() {
        pendingNavigationRenderIdleWork?.cancel()
        pendingNavigationRenderIdleWork = nil

        if !hasNavigationRenderActivity {
            hasNavigationRenderActivity = true
            refreshRenderMode(requestID: filterRequestID)
        }

        let requestID = filterRequestID
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingNavigationRenderIdleWork = nil
            guard self.hasNavigationRenderActivity else { return }
            self.hasNavigationRenderActivity = false
            self.refreshRenderMode(requestID: requestID)
        }

        pendingNavigationRenderIdleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.navigationRenderIdleDelay, execute: work)
    }

    private func scheduleFiltering(debounce: TimeInterval) {
        pendingFilterWork?.cancel()

        filterRequestID &+= 1
        let requestID = filterRequestID
        let querySnapshot = query
        let normalizedQuerySnapshot = FuzzyMatcher.normalize(querySnapshot)
        let queryChanged = normalizedQuerySnapshot != visibleNormalizedQuery
        let hasSearchQuery = !normalizedQuerySnapshot.isEmpty
        let itemsSnapshot = selectedBucketID == nil ? items : scopedBucketItems
        let selectedBucketIDSnapshot = selectedBucketID
        let searchScopeKey = SearchScopeKey(
            selectedBucketID: selectedBucketIDSnapshot,
            corpusRevision: searchCorpusRevision
        )
        let previousSearchCache = searchCache
        let database = self.database
        let searchLimit = Self.searchResultLimit
        let unfilteredLimit = Self.unfilteredDisplayLimit
        let perfLog = performanceLog
        let filterSignpostID = OSSignpostID(log: perfLog)
        let strictTokens = FuzzyMatcher.strictQueryTokens(normalizedQuery: normalizedQuerySnapshot)
        let indexEligibleTokens = strictTokens.filter {
            $0.count >= Self.indexedSearchMinimumTokenCharacterCount
                && String($0).canBeConverted(to: .ascii)
        }
        let canUseDirectIndexedSearch = selectedBucketIDSnapshot == nil
            && !strictTokens.isEmpty
            && indexEligibleTokens.count == strictTokens.count
        let itemsByID = Dictionary(uniqueKeysWithValues: itemsSnapshot.map { ($0.id, $0) })
        beginSearchComputation(
            requestID: requestID,
            shouldShowSearchComputationState: hasSearchQuery && queryChanged
        )
        let reusedLocalStrictPool = reusableLocalStrictSearchPool(
            previousCache: previousSearchCache,
            for: searchScopeKey,
            normalizedQuery: normalizedQuerySnapshot
        )
        let rerankMatches: (_ candidates: [ClipItem], _ indexedOrderByID: [Int64: Int]) -> [ClipItem] = { candidates, indexedOrderByID in
            SearchRanker.rerank(
                normalizedQuery: normalizedQuerySnapshot,
                queryTokens: strictTokens,
                candidates: candidates,
                indexedOrderByID: indexedOrderByID,
                limit: searchLimit
            )
        }
        let fetchIndexedSearchCandidates: (_ limit: Int, _ shouldContinue: @escaping () -> Bool) -> IndexedSearchCandidateSet? = { limit, shouldContinue in
            guard limit > 0 else {
                return IndexedSearchCandidateSet(items: [], orderByID: [:])
            }
            guard shouldContinue() else {
                return IndexedSearchCandidateSet(items: [], orderByID: [:])
            }

            guard let indexedMatches = database.fetchIndexedClipItemMatches(
                containingAllNormalizedTokens: indexEligibleTokens,
                limit: limit
            ) else {
                return nil
            }
            guard shouldContinue() else {
                return IndexedSearchCandidateSet(items: [], orderByID: [:])
            }

            var candidates: [ClipItem] = []
            candidates.reserveCapacity(min(limit, indexedMatches.count))
            var orderByID: [Int64: Int] = [:]
            orderByID.reserveCapacity(indexedMatches.count)

            for match in indexedMatches {
                guard let item = itemsByID[match.id] else { continue }
                orderByID[item.id] = candidates.count
                candidates.append(item)
            }

            return IndexedSearchCandidateSet(items: candidates, orderByID: orderByID)
        }
        let directIndexedStrictMatches: (_ shouldContinue: @escaping () -> Bool) -> IndexedSearchCandidateSet? = { shouldContinue in
            guard canUseDirectIndexedSearch else { return nil }
            return fetchIndexedSearchCandidates(
                min(itemsSnapshot.count, Self.indexedDirectResultPoolLimit),
                shouldContinue
            )
        }
        let indexedStrictSearchCandidates: (_ shouldContinue: @escaping () -> Bool) -> IndexedSearchCandidateSet? = { shouldContinue in
            guard selectedBucketIDSnapshot == nil else { return nil }
            guard !indexEligibleTokens.isEmpty else {
                return nil
            }
            return fetchIndexedSearchCandidates(
                min(itemsSnapshot.count, Self.indexedCandidatePoolLimit),
                shouldContinue
            )
        }
        let extendedStrictMatches: (_ excludingIDs: Set<Int64>, _ limit: Int, _ shouldContinue: @escaping () -> Bool) -> [ClipItem] = { excludingIDs, limit, shouldContinue in
            guard limit > 0 else { return [] }
            guard !normalizedQuerySnapshot.isEmpty else { return [] }

            let overflowCandidates = itemsSnapshot.filter {
                $0.hasSearchableOverflow && !excludingIDs.contains($0.id)
            }
            guard !overflowCandidates.isEmpty else { return [] }

            var matches: [ClipItem] = []
            matches.reserveCapacity(min(limit, overflowCandidates.count))

            for (itemIndex, item) in overflowCandidates.enumerated() {
                if itemIndex & 3 == 0, !shouldContinue() {
                    return []
                }

                guard let cachedContent = self.cachedExtendedSearchContent(
                    for: item,
                    database: database,
                    shouldContinue: shouldContinue
                ) else {
                    continue
                }

                guard FuzzyMatcher.strictMatch(
                    normalizedQuery: normalizedQuerySnapshot,
                    in: cachedContent.normalizedUTF8,
                    fingerprint: cachedContent.fingerprint,
                    shouldContinue: shouldContinue
                ) else {
                    continue
                }

                matches.append(item)
                if matches.count >= limit {
                    break
                }
            }

            return matches
        }
        let awaitFuzzyFallbackIdleWindow: (_ shouldContinue: @escaping () -> Bool) -> Bool = { shouldContinue in
            guard Self.fuzzyFallbackIdleDelay > 0 else {
                return shouldContinue()
            }

            let deadline = DispatchTime.now().uptimeNanoseconds
                + UInt64(Self.fuzzyFallbackIdleDelay * 1_000_000_000)
            while DispatchTime.now().uptimeNanoseconds < deadline {
                guard shouldContinue() else { return false }
                Thread.sleep(forTimeInterval: Self.fuzzyFallbackPollInterval)
            }

            return shouldContinue()
        }
        let shouldApplyProvisionalResults = !queryChanged
        let provisionalFiltered = shouldApplyProvisionalResults
            ? provisionalFilteredItems(
                normalizedQuery: normalizedQuerySnapshot,
                queryTokens: strictTokens,
                items: itemsSnapshot,
                queryChanged: queryChanged,
                previousCache: previousSearchCache,
                searchScopeKey: searchScopeKey,
                searchLimit: searchLimit,
                unfilteredLimit: unfilteredLimit
            )
            : nil
        let computeFiltered: (_ shouldContinue: @escaping () -> Bool) -> (filtered: [ClipItem], cache: SearchCache?) = { shouldContinue in
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
            let nextSearchCache: SearchCache?
            if normalizedQuerySnapshot.isEmpty {
                filtered = Array(itemsSnapshot.prefix(unfilteredLimit))
                nextSearchCache = nil
            } else if let directMatches = directIndexedStrictMatches(shouldContinue) {
                var combinedMatches = rerankMatches(directMatches.items, directMatches.orderByID)
                let overflowMatches = extendedStrictMatches(
                    Set(combinedMatches.map(\.id)),
                    max(0, searchLimit - combinedMatches.count),
                    shouldContinue
                )
                if !overflowMatches.isEmpty {
                    combinedMatches.append(contentsOf: overflowMatches)
                }

                if !combinedMatches.isEmpty {
                    filtered = combinedMatches
                    nextSearchCache = SearchCache(
                        scopeKey: searchScopeKey,
                        normalizedQuery: normalizedQuerySnapshot,
                        kind: overflowMatches.isEmpty ? .indexedStrict : .extendedStrict,
                        strictMatches: combinedMatches
                    )
                } else if awaitFuzzyFallbackIdleWindow(shouldContinue) {
                    filtered = FuzzyMatcher.fuzzyFilter(
                        normalizedQuery: normalizedQuerySnapshot,
                        in: itemsSnapshot,
                        limit: searchLimit,
                        shouldContinue: shouldContinue
                    )
                    nextSearchCache = nil
                } else {
                    filtered = []
                    nextSearchCache = nil
                }
            } else {
                let indexedCandidates = indexedStrictSearchCandidates(shouldContinue)
                let strictSearchPool = reusedLocalStrictPool
                    ?? indexedCandidates?.items
                    ?? itemsSnapshot
                let strictMatches = FuzzyMatcher.strictFilter(
                    normalizedQuery: normalizedQuerySnapshot,
                    in: strictSearchPool,
                    limit: Self.strictRerankCandidateLimit,
                    shouldContinue: shouldContinue
                )

                var combinedMatches = rerankMatches(strictMatches, indexedCandidates?.orderByID ?? [:])
                let overflowMatches = extendedStrictMatches(
                    Set(combinedMatches.map(\.id)),
                    max(0, searchLimit - combinedMatches.count),
                    shouldContinue
                )
                if !overflowMatches.isEmpty {
                    combinedMatches.append(contentsOf: overflowMatches)
                }

                if !combinedMatches.isEmpty {
                    filtered = combinedMatches
                    nextSearchCache = SearchCache(
                        scopeKey: searchScopeKey,
                        normalizedQuery: normalizedQuerySnapshot,
                        kind: overflowMatches.isEmpty ? .localStrict : .extendedStrict,
                        strictMatches: combinedMatches
                    )
                } else if awaitFuzzyFallbackIdleWindow(shouldContinue) {
                    filtered = FuzzyMatcher.fuzzyFilter(
                        normalizedQuery: normalizedQuerySnapshot,
                        in: itemsSnapshot,
                        limit: searchLimit,
                        shouldContinue: shouldContinue
                    )
                    nextSearchCache = nil
                } else {
                    filtered = []
                    nextSearchCache = nil
                }
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

            return (filtered, nextSearchCache)
        }

        if let provisionalFiltered {
            applyFilteredItems(
                provisionalFiltered,
                selectionBehavior: .preserveCurrent,
                isFinalApply: false
            )
        }
        visibleNormalizedQuery = normalizedQuerySnapshot

        var workItem: DispatchWorkItem?
        let shouldContinue: () -> Bool = {
            !(workItem?.isCancelled ?? false)
        }

        let work = DispatchWorkItem { [weak self] in
            let computed = computeFiltered(shouldContinue)

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

                self.searchCache = computed.cache
                self.applyFilteredItems(
                    computed.filtered,
                    selectionBehavior: queryChanged ? .resetToFirstResult : .preserveCurrent,
                    isFinalApply: true
                )
                self.visibleNormalizedQuery = normalizedQuerySnapshot
                self.endSearchComputation(requestID: requestID)

                os_signpost(
                    .end,
                    log: perfLog,
                    name: "FilterApply",
                    signpostID: applySignpostID,
                    "request=%{public}llu results=%{public}d",
                    requestID,
                    computed.filtered.count
                )
            }
        }
        workItem = work

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
            bumpSearchCorpusRevision()
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
                self.bumpSearchCorpusRevision()
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
                self.bumpSearchCorpusRevision()
                self.scheduleFiltering(debounce: 0)
                applied = 1
            }
        }
    }

    private func fetchBucketItemsAsync(
        bucketID: Int64,
        qos: DispatchQoS.QoSClass,
        limit: Int = defaultLoadLimit,
        mode: BucketFetchMode = .background,
        completion: @escaping (Result<[ClipItem], Error>) -> Void
    ) {
        bucketLoadQueue.async(qos: DispatchQoS(qosClass: qos, relativePriority: 0)) { [weak self] in
            guard let self else { return }
            let result: Result<[ClipItem], Error> = Result {
                switch mode {
                case .background:
                    return try self.database.fetchItems(inBucket: bucketID, limit: limit)
                case .interaction:
                    return try self.database.fetchItemsForInteraction(inBucket: bucketID, limit: limit)
                }
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

        fetchBucketItemsAsync(bucketID: bucketID, qos: .utility, limit: Self.prewarmLoadLimit) { [weak self] result in
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
            if bucketItems.count >= Self.prewarmLoadLimit {
                self.partialBucketCacheIDs.insert(bucketID)
            }
            self.preloadIcons(for: Array(bucketItems.prefix(Self.initialIconPreloadCount)))

            guard self.selectedBucketID == bucketID, self.isBucketScopeLoading else {
                return
            }

            self.scopedBucketItems = bucketItems
            self.isBucketScopeLoading = false
            self.bumpSearchCorpusRevision()
            self.scheduleFiltering(debounce: 0)
            appliedToVisibleScope = 1

            if self.partialBucketCacheIDs.contains(bucketID) {
                self.loadFullBucketInBackground(bucketID: bucketID)
            }
        }
    }

    private func loadFullBucketInBackground(bucketID: Int64) {
        guard !inFlightBucketCacheLoads.contains(bucketID) else { return }
        inFlightBucketCacheLoads.insert(bucketID)
        let perfLog = performanceLog
        let signpostID = OSSignpostID(log: perfLog)
        os_signpost(
            .begin,
            log: perfLog,
            name: "BucketFetchFullUpgrade",
            signpostID: signpostID,
            "bucket=%{public}lld",
            bucketID
        )

        fetchBucketItemsAsync(bucketID: bucketID, qos: .utility) { [weak self] result in
            var rowCount = -1
            defer {
                os_signpost(
                    .end,
                    log: perfLog,
                    name: "BucketFetchFullUpgrade",
                    signpostID: signpostID,
                    "bucket=%{public}lld rows=%{public}d",
                    bucketID,
                    rowCount
                )
            }

            guard let self else { return }
            self.inFlightBucketCacheLoads.remove(bucketID)

            guard case .success(let bucketItems) = result else { return }
            guard self.buckets.contains(where: { $0.id == bucketID }) else { return }
            rowCount = bucketItems.count

            self.cachedBucketItemsByID[bucketID] = bucketItems
            self.partialBucketCacheIDs.remove(bucketID)
            self.preloadIcons(for: Array(bucketItems.prefix(Self.initialIconPreloadCount)))

            guard self.selectedBucketID == bucketID else { return }
            self.scopedBucketItems = bucketItems
            self.bumpSearchCorpusRevision()
            self.scheduleFiltering(debounce: 0)
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
        item.withCustomTitle(customTitle)
    }

    private func applyInsertedItem(_ inserted: ClipItem) {
        if let duplicateIndex = items.firstIndex(where: { $0.id == inserted.id }) {
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

        bumpSearchCorpusRevision()
        scheduleFiltering(debounce: 0)
    }

    private func filteredItemsMatch(_ newItems: [ClipItem]) -> Bool {
        let current = filteredItems
        guard current.count == newItems.count else { return false }
        for i in current.indices {
            if current[i].id != newItems[i].id
                || current[i].copiedAt != newItems[i].copiedAt
                || current[i].customTitle != newItems[i].customTitle {
                return false
            }
        }
        return true
    }

    private func clampSelectedIndex() {
        guard !filteredItems.isEmpty else {
            if selectedIndex != 0 { selectedIndex = 0 }
            syncSelectionState()
            return
        }

        let clamped = min(max(selectedIndex, 0), filteredItems.count - 1)
        if selectedIndex != clamped { selectedIndex = clamped }
        syncSelectionState()
    }

    private var currentSelectedItemID: Int64? {
        guard filteredItems.indices.contains(selectedIndex) else { return nil }
        return filteredItems[selectedIndex].id
    }
}
