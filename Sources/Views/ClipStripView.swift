import AppKit
import SwiftUI
import os.signpost

struct ClipStripBuildContext {
    let iconStore: ClipboardStore
    let linkPreviewStore: LinkPreviewStore
    let filePreviewStore: FilePreviewStore
    let payloadPreviewStore: PayloadPreviewStore
    let onSelect: (Int64) -> Void
    let onActivate: (ClipItem) -> Void
    let onDragChanged: (ClipItem, CGPoint) -> Void
    let onDragEnded: (ClipItem, CGPoint) -> Void
    let onTitleChange: (Int64, String?) -> Void
    let onTitleEditingStateChange: (Bool) -> Void
}

struct ClipStripView: NSViewRepresentable {
    struct ItemConfiguration {
        let item: ClipItem
        let commandNumber: Int?
        let renderMode: SearchRenderMode
        let accentColorHex: String?
        let isTitleEditable: Bool
        let isDraggingSource: Bool

        func contentMatches(_ other: ItemConfiguration) -> Bool {
            item == other.item
                && commandNumber == other.commandNumber
                && visualRenderMode == other.visualRenderMode
                && accentColorHex == other.accentColorHex
                && isTitleEditable == other.isTitleEditable
                && isDraggingSource == other.isDraggingSource
        }

        private var visualRenderMode: SearchRenderMode {
            switch renderMode {
            case .interactiveNavigation:
                return .fullIdle
            case .lightweightTyping, .fullIdle:
                return renderMode
            }
        }
    }

    let items: [ItemConfiguration]
    let selectedItemID: Int64?
    let iconStore: ClipboardStore
    let linkPreviewStore: LinkPreviewStore
    let filePreviewStore: FilePreviewStore
    let payloadPreviewStore: PayloadPreviewStore
    let onSelect: (Int64) -> Void
    let onActivate: (ClipItem) -> Void
    let onDragChanged: (ClipItem, CGPoint) -> Void
    let onDragEnded: (ClipItem, CGPoint) -> Void
    let onTitleChange: (Int64, String?) -> Void
    let onTitleEditingStateChange: (Bool) -> Void

    func makeNSView(context: Context) -> ClipStripContainerView {
        let view = ClipStripContainerView()
        view.apply(
            items: items,
            selectedItemID: selectedItemID,
            iconStore: iconStore,
            linkPreviewStore: linkPreviewStore,
            filePreviewStore: filePreviewStore,
            payloadPreviewStore: payloadPreviewStore,
            onSelect: onSelect,
            onActivate: onActivate,
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded,
            onTitleChange: onTitleChange,
            onTitleEditingStateChange: onTitleEditingStateChange
        )
        return view
    }

    func updateNSView(_ nsView: ClipStripContainerView, context: Context) {
        nsView.apply(
            items: items,
            selectedItemID: selectedItemID,
            iconStore: iconStore,
            linkPreviewStore: linkPreviewStore,
            filePreviewStore: filePreviewStore,
            payloadPreviewStore: payloadPreviewStore,
            onSelect: onSelect,
            onActivate: onActivate,
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded,
            onTitleChange: onTitleChange,
            onTitleEditingStateChange: onTitleEditingStateChange
        )
    }
}

@MainActor
final class ClipStripContainerView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private static let itemIdentifier = NSUserInterfaceItemIdentifier("ClipStripCollectionItem")
    private static let cardSize = NSSize(width: 244, height: 252)
    private static let sectionInset = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
    private static let cardSpacing: CGFloat = 14
    private static let keepVisiblePadding: CGFloat = 28

    private struct SimpleCollectionUpdate {
        let deletions: Set<IndexPath>
        let insertions: Set<IndexPath>
    }

    private let scrollView: NSScrollView
    private let collectionView: NSCollectionView
    private let flowLayout: NSCollectionViewFlowLayout

    private var items: [ClipStripView.ItemConfiguration] = []
    private var itemIndexByID: [Int64: Int] = [:]
    private var selectedItemID: Int64?
    private var buildContext: ClipStripBuildContext?
    private var hasScheduledKeepVisiblePass = false
    private var pendingKeepVisibleItemID: Int64?
    private var hasScheduledPrefetchPass = false
    private var iconObserverToken: UUID?
    private var linkPreviewObserverToken: UUID?
    private var filePreviewObserverToken: UUID?
    private var payloadPreviewObserverToken: UUID?
    private var boundsObserver: NSObjectProtocol?
    private let performanceLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "PasteBin",
        category: "ClipStripPerformance"
    )

    override init(frame frameRect: NSRect) {
        flowLayout = NSCollectionViewFlowLayout()
        flowLayout.scrollDirection = .horizontal
        flowLayout.itemSize = Self.cardSize
        flowLayout.minimumLineSpacing = Self.cardSpacing
        flowLayout.minimumInteritemSpacing = 0
        flowLayout.sectionInset = Self.sectionInset

        collectionView = NSCollectionView()
        collectionView.collectionViewLayout = flowLayout
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(ClipStripCollectionItem.self, forItemWithIdentifier: Self.itemIdentifier)

        scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = collectionView

        super.init(frame: frameRect)

        collectionView.dataSource = self
        collectionView.delegate = self

        addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.schedulePrefetchPass()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)

        guard newWindow == nil, let buildContext else { return }

        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }

        if let iconObserverToken {
            buildContext.iconStore.removeIconObserver(iconObserverToken)
            self.iconObserverToken = nil
        }
        if let linkPreviewObserverToken {
            buildContext.linkPreviewStore.removeChangeObserver(linkPreviewObserverToken)
            self.linkPreviewObserverToken = nil
        }
        if let filePreviewObserverToken {
            buildContext.filePreviewStore.removeChangeObserver(filePreviewObserverToken)
            self.filePreviewObserverToken = nil
        }
        if let payloadPreviewObserverToken {
            buildContext.payloadPreviewStore.removeChangeObserver(payloadPreviewObserverToken)
            self.payloadPreviewObserverToken = nil
        }
    }

    override func layout() {
        super.layout()
        updateCollectionViewFrame()
        schedulePrefetchPass()
    }

    func apply(
        items: [ClipStripView.ItemConfiguration],
        selectedItemID: Int64?,
        iconStore: ClipboardStore,
        linkPreviewStore: LinkPreviewStore,
        filePreviewStore: FilePreviewStore,
        payloadPreviewStore: PayloadPreviewStore,
        onSelect: @escaping (Int64) -> Void,
        onActivate: @escaping (ClipItem) -> Void,
        onDragChanged: @escaping (ClipItem, CGPoint) -> Void,
        onDragEnded: @escaping (ClipItem, CGPoint) -> Void,
        onTitleChange: @escaping (Int64, String?) -> Void,
        onTitleEditingStateChange: @escaping (Bool) -> Void
    ) {
        let previousItems = self.items
        let previousSelectedItemID = self.selectedItemID
        let previousIDs = previousItems.map(\.item.id)
        let nextIDs = items.map(\.item.id)
        let idsChanged = previousIDs != nextIDs
        let contentChanged = !idsChanged && !itemsContentMatches(previousItems, items)
        let selectionChanged = previousSelectedItemID != selectedItemID

        self.items = items
        self.itemIndexByID = Dictionary(
            uniqueKeysWithValues: items.enumerated().map { (offset, configuration) in
                (configuration.item.id, offset)
            }
        )
        self.selectedItemID = selectedItemID
        buildContext = ClipStripBuildContext(
            iconStore: iconStore,
            linkPreviewStore: linkPreviewStore,
            filePreviewStore: filePreviewStore,
            payloadPreviewStore: payloadPreviewStore,
            onSelect: onSelect,
            onActivate: onActivate,
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded,
            onTitleChange: onTitleChange,
            onTitleEditingStateChange: onTitleEditingStateChange
        )
        attachObserversIfNeeded()

        if idsChanged {
            if let simpleUpdate = simpleCollectionUpdate(from: previousIDs, to: nextIDs) {
                collectionView.performBatchUpdates {
                    if !simpleUpdate.deletions.isEmpty {
                        collectionView.deleteItems(at: simpleUpdate.deletions)
                    }
                    if !simpleUpdate.insertions.isEmpty {
                        collectionView.insertItems(at: simpleUpdate.insertions)
                    }
                } completionHandler: { [weak self] _ in
                    guard let self else { return }
                    self.updateCollectionViewFrame()
                    self.refreshVisibleItems(reason: "idMutation") { _ in true }
                    self.scheduleKeepVisiblePass(for: self.selectedItemID)
                    self.schedulePrefetchPass()
                }
                return
            }

            collectionView.reloadData()
            updateCollectionViewFrame()
            scheduleKeepVisiblePass(for: selectedItemID)
            schedulePrefetchPass()
            return
        }

        if contentChanged {
            refreshVisibleItems(reason: "configuration") { _ in true }
            scheduleKeepVisiblePass(for: selectedItemID)
            schedulePrefetchPass()
            return
        }

        guard selectionChanged else {
            schedulePrefetchPass()
            return
        }
        updateSelection(from: previousSelectedItemID, to: selectedItemID)
        schedulePrefetchPass()
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        1
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: Self.itemIdentifier,
            for: indexPath
        )

        guard let clipItem = item as? ClipStripCollectionItem else {
            return item
        }

        configure(clipItem, at: indexPath)
        return clipItem
    }

    private func itemsContentMatches(
        _ lhs: [ClipStripView.ItemConfiguration],
        _ rhs: [ClipStripView.ItemConfiguration]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }

        for (left, right) in zip(lhs, rhs) {
            if !left.contentMatches(right) {
                return false
            }
        }

        return true
    }

    private func simpleCollectionUpdate(from previousIDs: [Int64], to nextIDs: [Int64]) -> SimpleCollectionUpdate? {
        let diff = nextIDs.difference(from: previousIDs)
        var deletions = Set<IndexPath>()
        var insertions = Set<IndexPath>()

        for change in diff {
            switch change {
            case .remove(let offset, _, let associatedWith):
                guard associatedWith == nil else { return nil }
                deletions.insert(IndexPath(item: offset, section: 0))
            case .insert(let offset, _, let associatedWith):
                guard associatedWith == nil else { return nil }
                insertions.insert(IndexPath(item: offset, section: 0))
            }
        }

        guard !deletions.isEmpty || !insertions.isEmpty else { return nil }
        guard deletions.count <= 1, insertions.count <= 1 else { return nil }
        return SimpleCollectionUpdate(deletions: deletions, insertions: insertions)
    }

    private func updateSelection(from previousID: Int64?, to nextID: Int64?) {
        if let previousID, let previousIndex = indexOfItem(withID: previousID) {
            updateSelectionForVisibleItem(at: previousIndex, isSelected: false)
        }

        if let nextID, let nextIndex = indexOfItem(withID: nextID) {
            updateSelectionForVisibleItem(at: nextIndex, isSelected: true)
        }

        scheduleKeepVisiblePass(for: nextID)
    }

    private func updateSelectionForVisibleItem(at index: Int, isSelected: Bool) {
        guard items.indices.contains(index) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        guard let item = collectionView.item(at: indexPath) as? ClipStripCollectionItem else { return }
        let configuration = items[index]

        if item.supportsSelectionOnlyUpdate(for: configuration) {
            item.updateSelectionState(
                isSelected: isSelected,
                isDraggingSource: configuration.isDraggingSource
            )
        } else {
            configure(item, at: indexPath)
        }
    }

    private func reconfigureItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        guard let item = collectionView.item(at: indexPath) as? ClipStripCollectionItem else { return }
        configure(item, at: indexPath)
    }

    private func configure(_ itemView: ClipStripCollectionItem, at indexPath: IndexPath) {
        guard items.indices.contains(indexPath.item), let buildContext else { return }
        let configuration = items[indexPath.item]
        let linkPreviewData = configuration.item.linkURL.flatMap { buildContext.linkPreviewStore.preview(for: $0) }
        let firstFilePath = configuration.item.filePaths.first
        let filePreviewImage = firstFilePath.flatMap { buildContext.filePreviewStore.preview(for: $0) }
        let imagePreview = buildContext.payloadPreviewStore.imagePayload(for: configuration.item.id)
        let richTextPreviewSource = buildContext.payloadPreviewStore.rtfPayload(for: configuration.item.id)
            ?? buildContext.payloadPreviewStore.htmlPayload(for: configuration.item.id)
        itemView.apply(
            configuration: configuration,
            isSelected: configuration.item.id == selectedItemID,
            icon: buildContext.iconStore.icon(for: configuration.item),
            linkPreviewData: linkPreviewData,
            filePreviewImage: filePreviewImage,
            imagePreview: imagePreview,
            richTextPreviewSource: richTextPreviewSource,
            buildContext: buildContext
        )
    }

    private func indexOfItem(withID id: Int64) -> Int? {
        itemIndexByID[id]
    }

    private func scheduleKeepVisiblePass(for itemID: Int64?) {
        pendingKeepVisibleItemID = itemID
        guard !hasScheduledKeepVisiblePass else { return }
        hasScheduledKeepVisiblePass = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasScheduledKeepVisiblePass = false
            self.flushKeepVisiblePass()
        }
    }

    private func flushKeepVisiblePass() {
        guard let itemID = pendingKeepVisibleItemID else { return }
        pendingKeepVisibleItemID = nil
        updateCollectionViewFrame()
        ensureItemVisible(id: itemID)
    }

    private func ensureItemVisible(id: Int64) {
        guard let index = indexOfItem(withID: id) else { return }
        guard let clipView = scrollView.contentView as NSClipView? else { return }

        let visibleBounds = clipView.bounds
        let itemFrame = frameForItem(at: index)
        let desiredMinX = itemFrame.minX - Self.keepVisiblePadding
        let desiredMaxX = itemFrame.maxX + Self.keepVisiblePadding

        var nextOrigin = visibleBounds.origin
        if desiredMinX < visibleBounds.minX {
            nextOrigin.x = desiredMinX
        } else if desiredMaxX > visibleBounds.maxX {
            nextOrigin.x = desiredMaxX - visibleBounds.width
        } else {
            return
        }

        let documentWidth = max(collectionView.bounds.width, visibleBounds.width)
        let maxOriginX = max(0, documentWidth - visibleBounds.width)
        nextOrigin.x = min(max(0, nextOrigin.x), maxOriginX)
        clipView.scroll(to: nextOrigin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func updateCollectionViewFrame() {
        let viewportSize = scrollView.contentView.bounds.size
        let contentSize = contentSize(for: items.count)
        collectionView.frame = CGRect(
            origin: .zero,
            size: NSSize(
                width: max(viewportSize.width, contentSize.width),
                height: max(viewportSize.height, contentSize.height)
            )
        )
    }

    private func frameForItem(at index: Int) -> CGRect {
        let x = Self.sectionInset.left + CGFloat(index) * (Self.cardSize.width + Self.cardSpacing)
        return CGRect(
            x: x,
            y: Self.sectionInset.top,
            width: Self.cardSize.width,
            height: Self.cardSize.height
        )
    }

    private func contentSize(for itemCount: Int) -> CGSize {
        let contentWidth: CGFloat
        if itemCount > 0 {
            contentWidth = Self.sectionInset.left
                + CGFloat(itemCount) * Self.cardSize.width
                + CGFloat(max(0, itemCount - 1)) * Self.cardSpacing
                + Self.sectionInset.right
        } else {
            contentWidth = Self.sectionInset.left + Self.sectionInset.right
        }

        return CGSize(
            width: contentWidth,
            height: Self.sectionInset.top + Self.cardSize.height + Self.sectionInset.bottom
        )
    }

    private func attachObserversIfNeeded() {
        guard let buildContext else { return }

        if iconObserverToken == nil {
            iconObserverToken = buildContext.iconStore.addIconObserver { [weak self] bundleID in
                self?.refreshVisibleItems(reason: "icon") { configuration in
                    configuration.item.sourceBundleID == bundleID
                }
            }
        }

        if linkPreviewObserverToken == nil {
            linkPreviewObserverToken = buildContext.linkPreviewStore.addChangeObserver { [weak self] url in
                self?.refreshVisibleItems(reason: "linkPreview") { configuration in
                    configuration.item.linkURL == url
                }
            }
        }

        if filePreviewObserverToken == nil {
            filePreviewObserverToken = buildContext.filePreviewStore.addChangeObserver { [weak self] path in
                self?.refreshVisibleItems(reason: "filePreview") { configuration in
                    configuration.item.filePaths.first == path
                }
            }
        }

        if payloadPreviewObserverToken == nil {
            payloadPreviewObserverToken = buildContext.payloadPreviewStore.addChangeObserver { [weak self] itemID in
                self?.refreshVisibleItems(reason: "payloadPreview") { configuration in
                    configuration.item.id == itemID
                }
            }
        }
    }

    private func schedulePrefetchPass() {
        guard !hasScheduledPrefetchPass else { return }
        hasScheduledPrefetchPass = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasScheduledPrefetchPass = false
            self.flushPrefetchPass()
        }
    }

    private func flushPrefetchPass() {
        guard let buildContext else { return }
        let indexes = prefetchIndexes()
        guard !indexes.isEmpty else { return }

        let signpostID = OSSignpostID(log: performanceLog)
        os_signpost(
            .begin,
            log: performanceLog,
            name: "PrefetchNearbyContent",
            signpostID: signpostID,
            "count=%{public}d",
            indexes.count
        )

        for index in indexes {
            let configuration = items[index]
            _ = buildContext.iconStore.icon(for: configuration.item)

            guard configuration.renderMode == .fullIdle else { continue }
            switch configuration.item.contentType {
            case .link:
                if let url = configuration.item.linkURL {
                    buildContext.linkPreviewStore.loadPreview(for: url)
                }
            case .fileList:
                if let path = configuration.item.filePaths.first {
                    buildContext.filePreviewStore.loadPreview(for: path)
                }
            case .image where configuration.item.hasPayloadData:
                buildContext.payloadPreviewStore.loadIfNeeded(for: configuration.item.id)
            case .richText where configuration.item.hasRTFData || configuration.item.hasHTMLContent:
                buildContext.payloadPreviewStore.loadIfNeeded(for: configuration.item.id)
            default:
                break
            }
        }

        os_signpost(
            .end,
            log: performanceLog,
            name: "PrefetchNearbyContent",
            signpostID: signpostID,
            "count=%{public}d",
            indexes.count
        )
    }

    private func prefetchIndexes() -> [Int] {
        guard !items.isEmpty else { return [] }

        let visibleIndexes = collectionView.indexPathsForVisibleItems().map(\.item)
        let lookahead = 6
        var indexes = Set<Int>()

        if let selectedItemID, let selectedIndex = indexOfItem(withID: selectedItemID) {
            let lower = max(0, selectedIndex - lookahead)
            let upper = min(items.count - 1, selectedIndex + lookahead)
            for index in lower...upper {
                indexes.insert(index)
            }
        }

        if let minVisible = visibleIndexes.min(), let maxVisible = visibleIndexes.max() {
            let lower = max(0, minVisible - lookahead)
            let upper = min(items.count - 1, maxVisible + lookahead)
            for index in lower...upper {
                indexes.insert(index)
            }
        }

        return indexes.sorted()
    }

    private func refreshVisibleItems(
        reason: StaticString,
        matching predicate: (ClipStripView.ItemConfiguration) -> Bool
    ) {
        let visibleIndexPaths = collectionView.indexPathsForVisibleItems()
        guard !visibleIndexPaths.isEmpty else { return }

        var refreshedCount = 0
        for indexPath in visibleIndexPaths where items.indices.contains(indexPath.item) {
            guard predicate(items[indexPath.item]) else { continue }
            if let item = collectionView.item(at: indexPath) as? ClipStripCollectionItem {
                configure(item, at: indexPath)
                refreshedCount += 1
            }
        }

        if refreshedCount > 0 {
            os_signpost(.event, log: performanceLog, name: "TargetedVisibleRefresh", "%{public}s count=%{public}d", "\(reason)", refreshedCount)
        }
    }
}

@MainActor
private final class FastTextClipCardView: NSView {
    private enum BodyStyle {
        case text
        case snippet
    }

    private let headerView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let textContainer = NSView()
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private let commandBadgeBackground = NSView()
    private let commandBadgeLabel = NSTextField(labelWithString: "")

    private static let offBlackAccent = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.11, alpha: 1.0)
    private static let blueAccent = NSColor(calibratedRed: 0.13, green: 0.46, blue: 0.88, alpha: 1.0)
    private static let chromeAccent = NSColor(calibratedRed: 66.0 / 255.0, green: 133.0 / 255.0, blue: 244.0 / 255.0, alpha: 1.0)
    private static let greenAccent = NSColor(calibratedRed: 0.20, green: 0.67, blue: 0.30, alpha: 1.0)
    private static let purpleAccent = NSColor(calibratedRed: 0.43, green: 0.19, blue: 0.53, alpha: 1.0)
    private static let yellowAccent = NSColor(calibratedRed: 0.74, green: 0.63, blue: 0.23, alpha: 1.0)
    private static let grayAccent = NSColor(calibratedRed: 0.40, green: 0.40, blue: 0.42, alpha: 1.0)
    private static let blackAccent = NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.06, alpha: 1.0)
    private static let offWhiteAccent = NSColor(calibratedRed: 0.78, green: 0.76, blue: 0.71, alpha: 1.0)
    private static let bundleAccentMap: [String: NSColor] = [
        "com.tinyspeck.slackmacgap": purpleAccent,
        "com.google.Chrome": chromeAccent,
        "com.apple.finder": blueAccent,
        "com.apple.TextEdit": grayAccent,
        "com.todesktop.230313mzl4w4u92": blackAccent,
        "com.microsoft.VSCode": blackAccent,
        "com.googlecode.iterm2": greenAccent,
        "com.apple.Terminal": greenAccent,
        "com.apple.Safari": blueAccent,
        "com.superhuman.electron": blackAccent,
        "com.apple.MobileSMS": greenAccent,
        "com.apple.Notes": yellowAccent,
        "com.granola.app": offWhiteAccent,
        "md.obsidian": blackAccent
    ]
    private static let appNameAccentMap: [String: NSColor] = [
        "slack": purpleAccent,
        "chrome": chromeAccent,
        "finder": blueAccent,
        "textedit": grayAccent,
        "cursor": blackAccent,
        "visual studio code": blackAccent,
        "vs code": blackAccent,
        "iterm2": greenAccent,
        "iterm": greenAccent,
        "terminal": greenAccent,
        "safari": blueAccent,
        "superhuman": blackAccent,
        "messages": greenAccent,
        "imessage": greenAccent,
        "notes": yellowAccent,
        "granola": offWhiteAccent,
        "obsidian": blackAccent
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 1.0).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.masksToBounds = true

        headerView.wantsLayer = true
        textContainer.wantsLayer = true
        textContainer.layer?.cornerRadius = 8
        textContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        textContainer.layer?.borderWidth = 0.7
        textContainer.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        commandBadgeBackground.wantsLayer = true
        commandBadgeBackground.layer?.cornerRadius = 9
        commandBadgeBackground.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor

        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.88)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        timeLabel.font = .systemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = NSColor.white.withAlphaComponent(0.46)
        timeLabel.lineBreakMode = .byTruncatingTail
        timeLabel.maximumNumberOfLines = 1

        bodyLabel.textColor = NSColor.white.withAlphaComponent(0.74)
        bodyLabel.maximumNumberOfLines = 8
        bodyLabel.lineBreakMode = .byTruncatingTail

        footerLabel.font = .systemFont(ofSize: 9.5, weight: .medium)
        footerLabel.textColor = NSColor.white.withAlphaComponent(0.36)
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.maximumNumberOfLines = 1

        commandBadgeLabel.font = .monospacedSystemFont(ofSize: 9.5, weight: .semibold)
        commandBadgeLabel.textColor = NSColor.white.withAlphaComponent(0.50)
        commandBadgeLabel.alignment = .center

        iconView.imageScaling = .scaleProportionallyUpOrDown

        for subview in [headerView, textContainer, footerLabel, commandBadgeBackground] {
            addSubview(subview)
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        for subview in [titleLabel, timeLabel, iconView] {
            headerView.addSubview(subview)
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        textContainer.addSubview(bodyLabel)
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        commandBadgeBackground.addSubview(commandBadgeLabel)
        commandBadgeLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 64),

            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: iconView.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 9),

            timeLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            timeLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            timeLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),

            iconView.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -8),
            iconView.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 6),
            iconView.widthAnchor.constraint(equalToConstant: 46),
            iconView.heightAnchor.constraint(equalToConstant: 46),

            textContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            textContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            textContainer.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 12),

            bodyLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor, constant: 9),
            bodyLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor, constant: -9),
            bodyLabel.topAnchor.constraint(equalTo: textContainer.topAnchor, constant: 8),
            bodyLabel.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor, constant: -8),

            footerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            footerLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: commandBadgeBackground.leadingAnchor, constant: -8),

            commandBadgeBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            commandBadgeBackground.centerYAnchor.constraint(equalTo: footerLabel.centerYAnchor),
            commandBadgeLabel.leadingAnchor.constraint(equalTo: commandBadgeBackground.leadingAnchor, constant: 6),
            commandBadgeLabel.trailingAnchor.constraint(equalTo: commandBadgeBackground.trailingAnchor, constant: -6),
            commandBadgeLabel.topAnchor.constraint(equalTo: commandBadgeBackground.topAnchor, constant: 2),
            commandBadgeLabel.bottomAnchor.constraint(equalTo: commandBadgeBackground.bottomAnchor, constant: -2)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(
        item: ClipItem,
        commandNumber: Int?,
        icon: NSImage?,
        renderMode: SearchRenderMode,
        accentColorHex: String?,
        isSelected: Bool,
        isDraggingSource: Bool
    ) {
        titleLabel.stringValue = item.displayTitle
        timeLabel.stringValue = Self.relativeCopiedTime(for: item.copiedAt)
        iconView.image = icon
        alphaValue = isDraggingSource ? 0.34 : 1.0

        let bodyStyle: BodyStyle
        let bodyText: String
        let footerText: String?
        switch item.contentType {
        case .text:
            bodyStyle = .text
            bodyText = item.previewText.isEmpty ? "(empty)" : item.previewText
            footerText = "\(item.characterCount) characters"
        case .code:
            bodyStyle = .snippet
            bodyText = item.codeSnippetText.isEmpty ? "(empty)" : item.codeSnippetText
            footerText = "\(item.characterCount) characters"
        case .structured:
            bodyStyle = .snippet
            let structuredText = renderMode == .lightweightTyping ? item.codeSnippetText : item.structuredSnippetText
            bodyText = structuredText.isEmpty ? "(empty)" : structuredText
            footerText = "\(item.characterCount) characters"
        case .richText:
            bodyStyle = .text
            bodyText = item.previewText.isEmpty ? "(empty)" : item.previewText
            footerText = "\(item.characterCount) characters"
        case .link(let url):
            bodyStyle = .text
            bodyText = item.linkDisplayText ?? item.previewText
            footerText = url.host
        case .fileList:
            bodyStyle = .text
            bodyText = item.previewText.isEmpty ? "File" : item.previewText
            footerText = item.filePaths.count == 1 ? "1 file" : "\(item.filePaths.count) files"
        case .image:
            bodyStyle = .text
            bodyText = item.previewText.isEmpty ? "Image" : item.previewText
            footerText = item.imageDimensionsText
        }

        bodyLabel.stringValue = bodyText
        footerLabel.stringValue = footerText ?? ""
        footerLabel.isHidden = (footerText?.isEmpty ?? true)
        switch bodyStyle {
        case .text:
            bodyLabel.font = .systemFont(ofSize: 13.5, weight: .regular)
            textContainer.layer?.backgroundColor = NSColor.clear.cgColor
            textContainer.layer?.borderWidth = 0
        case .snippet:
            bodyLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            textContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            textContainer.layer?.borderWidth = 0.7
            textContainer.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        }

        if let commandNumber {
            commandBadgeLabel.stringValue = "⌘\(commandNumber)"
            commandBadgeBackground.isHidden = false
        } else {
            commandBadgeBackground.isHidden = true
        }

        headerView.layer?.backgroundColor = effectiveAccentColorHex(accentColorHex, item: item).cgColor
        updateSelectionState(isSelected: isSelected, isDraggingSource: isDraggingSource)
    }

    func updateSelectionState(isSelected: Bool, isDraggingSource: Bool) {
        alphaValue = isDraggingSource ? 0.34 : 1.0
        layer?.borderWidth = isSelected ? 2.5 : 0.5
        layer?.borderColor = (isSelected
            ? NSColor(calibratedRed: 0.35, green: 0.55, blue: 1.0, alpha: 0.80)
            : NSColor.white.withAlphaComponent(0.06)).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = isSelected ? 0.32 : 0.20
        layer?.shadowRadius = isSelected ? 10 : 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    private func effectiveAccentColorHex(_ accentColorHex: String?, item: ClipItem) -> NSColor {
        if let accentColorHex {
            return NSColor(hex: accentColorHex)
        }
        if let bundleID = item.sourceBundleID, let color = Self.bundleAccentMap[bundleID] {
            return color
        }
        if let appName = item.sourceAppName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           let color = Self.appNameAccentMap[appName] {
            return color
        }
        return Self.offBlackAccent
    }

    private static func relativeCopiedTime(for date: Date) -> String {
        let elapsed = max(0, Int(Date().timeIntervalSince(date)))

        if elapsed < 60 {
            return "Just now"
        }
        if elapsed < 3_600 {
            let minutes = elapsed / 60
            return "\(minutes) \(minutes == 1 ? "minute" : "minutes") ago"
        }
        if elapsed < 86_400 {
            let hours = elapsed / 3_600
            return "\(hours) \(hours == 1 ? "hour" : "hours") ago"
        }
        if elapsed < 2_592_000 {
            let days = elapsed / 86_400
            return "\(days) \(days == 1 ? "day" : "days") ago"
        }
        if elapsed < 31_536_000 {
            let months = elapsed / 2_592_000
            return "\(months) \(months == 1 ? "month" : "months") ago"
        }

        let years = elapsed / 31_536_000
        return "\(years) \(years == 1 ? "year" : "years") ago"
    }
}

@MainActor
private final class ClipStripInteractionOverlayView: NSView {
    var onSelect: (() -> Void)?
    var onActivate: (() -> Void)?
    var onDragChanged: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?

    private var mouseDownLocation: CGPoint?
    private var hasStartedDrag = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        hasStartedDrag = false
        onSelect?()

        if event.clickCount == 2 {
            onActivate?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownLocation else { return }
        let location = event.locationInWindow
        let deltaX = location.x - mouseDownLocation.x
        let deltaY = location.y - mouseDownLocation.y

        if !hasStartedDrag {
            guard hypot(deltaX, deltaY) >= 2 else { return }
            hasStartedDrag = true
        }

        onDragChanged?(location)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocation = nil
            hasStartedDrag = false
        }

        guard hasStartedDrag else { return }
        onDragEnded?(event.locationInWindow)
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        var hexString = normalized

        if hexString.hasPrefix("#") {
            hexString.removeFirst()
        }

        guard hexString.count == 6,
              let value = UInt32(hexString, radix: 16) else {
            self.init(calibratedRed: 1.0, green: 0.278, blue: 0.278, alpha: 1.0)
            return
        }

        self.init(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

@MainActor
final class ClipStripCollectionItem: NSCollectionViewItem {
    private var hostingView: NSHostingView<AnyView>?
    private var fastTextView: FastTextClipCardView?
    private var interactionOverlayView: ClipStripInteractionOverlayView?

    override func loadView() {
        let view = NSView()
        view.wantsLayer = true
        self.view = view
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hostingView?.rootView = AnyView(EmptyView())
        fastTextView?.removeFromSuperview()
        fastTextView = nil
        interactionOverlayView?.removeFromSuperview()
        interactionOverlayView = nil
    }

    func apply(
        configuration: ClipStripView.ItemConfiguration,
        isSelected: Bool,
        icon: NSImage?,
        linkPreviewData: LinkPreviewData?,
        filePreviewImage: NSImage?,
        imagePreview: NSImage?,
        richTextPreviewSource: NSAttributedString?,
        buildContext: ClipStripBuildContext
    ) {
        if usesFastTextPath(configuration) {
            hostingView?.removeFromSuperview()
            hostingView = nil

            let fastTextView = ensureFastTextView()
            fastTextView.apply(
                item: configuration.item,
                commandNumber: configuration.commandNumber,
                icon: icon,
                renderMode: configuration.renderMode,
                accentColorHex: configuration.accentColorHex,
                isSelected: isSelected,
                isDraggingSource: configuration.isDraggingSource
            )
            ensureInteractionOverlay(configuration: configuration, buildContext: buildContext)
            return
        }

        fastTextView?.removeFromSuperview()
        fastTextView = nil

        let baseCardView = ClipCardView(
            item: configuration.item,
            isSelected: isSelected,
            commandNumber: configuration.commandNumber,
            icon: icon,
            renderMode: configuration.renderMode,
            accentColorOverride: configuration.accentColorHex.map(Color.init(hex:)),
            isTitleEditable: configuration.isTitleEditable,
            onTitleChange: { title in
                buildContext.onTitleChange(configuration.item.id, title)
            },
            onTitleEditingStateChange: buildContext.onTitleEditingStateChange,
            linkPreviewData: linkPreviewData,
            resolvedFilePreviewImage: filePreviewImage,
            resolvedImagePreview: imagePreview,
            richTextPreviewSource: richTextPreviewSource
        )
        .opacity(configuration.isDraggingSource ? 0.34 : 1.0)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

        let rootView: AnyView
        if configuration.isTitleEditable {
            rootView = AnyView(
                baseCardView
                    .onLongPressGesture(
                        minimumDuration: 0,
                        maximumDistance: 20,
                        pressing: { isPressing in
                            guard isPressing else { return }
                            buildContext.onSelect(configuration.item.id)
                        },
                        perform: {}
                    )
                    .onTapGesture(count: 2) {
                        buildContext.onActivate(configuration.item)
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .global)
                            .onChanged { value in
                                buildContext.onDragChanged(configuration.item, value.location)
                            }
                            .onEnded { value in
                                buildContext.onDragEnded(configuration.item, value.location)
                            }
                    )
            )
        } else {
            rootView = AnyView(baseCardView)
        }

        if let hostingView {
            hostingView.rootView = rootView
        } else {
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: view.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            self.hostingView = hostingView
        }

        if configuration.isTitleEditable {
            interactionOverlayView?.removeFromSuperview()
            interactionOverlayView = nil
        } else {
            ensureInteractionOverlay(configuration: configuration, buildContext: buildContext)
        }
    }

    func supportsSelectionOnlyUpdate(for configuration: ClipStripView.ItemConfiguration) -> Bool {
        usesFastTextPath(configuration)
    }

    func updateSelectionState(isSelected: Bool, isDraggingSource: Bool) {
        fastTextView?.updateSelectionState(isSelected: isSelected, isDraggingSource: isDraggingSource)
    }

    private func usesFastTextPath(_ configuration: ClipStripView.ItemConfiguration) -> Bool {
        guard !configuration.isTitleEditable else { return false }

        switch configuration.item.contentType {
        case .text, .code, .structured:
            return true
        default:
            return false
        }
    }

    private func ensureFastTextView() -> FastTextClipCardView {
        if let fastTextView {
            return fastTextView
        }

        let fastTextView = FastTextClipCardView()
        fastTextView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fastTextView)
        NSLayoutConstraint.activate([
            fastTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fastTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fastTextView.topAnchor.constraint(equalTo: view.topAnchor),
            fastTextView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        self.fastTextView = fastTextView
        return fastTextView
    }

    private func ensureInteractionOverlay(
        configuration: ClipStripView.ItemConfiguration,
        buildContext: ClipStripBuildContext
    ) {
        let overlay: ClipStripInteractionOverlayView
        if let interactionOverlayView {
            overlay = interactionOverlayView
        } else {
            let interactionOverlayView = ClipStripInteractionOverlayView()
            interactionOverlayView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(interactionOverlayView)
            NSLayoutConstraint.activate([
                interactionOverlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                interactionOverlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                interactionOverlayView.topAnchor.constraint(equalTo: view.topAnchor),
                interactionOverlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            self.interactionOverlayView = interactionOverlayView
            overlay = interactionOverlayView
        }

        view.addSubview(overlay, positioned: .above, relativeTo: fastTextView ?? hostingView)
        overlay.onSelect = {
            buildContext.onSelect(configuration.item.id)
        }
        overlay.onActivate = {
            buildContext.onActivate(configuration.item)
        }
        overlay.onDragChanged = { location in
            buildContext.onDragChanged(configuration.item, location)
        }
        overlay.onDragEnded = { location in
            buildContext.onDragEnded(configuration.item, location)
        }
    }
}
