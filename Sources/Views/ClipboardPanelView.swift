import AppKit
import SwiftUI

struct ClipboardPanelView: View {
    @ObservedObject var store: ClipboardStore
    let onActivateItem: (Int) -> Void

    @FocusState private var isSearchFocused: Bool
    @StateObject private var linkPreviewStore = LinkPreviewStore()
    @State private var droppedBucketColorByClipID: [Int64: String] = [:]
    @State private var activeCardDrag: ActiveCardDrag?
    @State private var hoveredBucketID: Int64?
    @State private var dropPulseBucketID: Int64?
    @State private var bucketFrames: [Int64: CGRect] = [:]

    private let panelRadius: CGFloat = 22
    private let edgePadding: CGFloat = 14
    private let topControlHeight: CGFloat = 38
    private let dragCoordinateSpaceName = "clipboard-panel-drag-space"

    var body: some View {
        let filtered = store.filteredItems

        VStack(alignment: .leading, spacing: 12) {
            topBar
                .padding(.top, 4)

            if store.isLoading {
                loadingState
            } else if filtered.isEmpty {
                emptyState
            } else {
                cardsView(filtered: filtered)
            }
        }
        .padding(edgePadding)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
        .shadow(color: .black.opacity(0.30), radius: 28, y: 4)
        .coordinateSpace(name: dragCoordinateSpaceName)
        .overlay(alignment: .topLeading) {
            if let activeCardDrag {
                dragPreview(title: activeCardDrag.title)
                    .position(activeCardDrag.location)
                    .allowsHitTesting(false)
            }
        }
        .onPreferenceChange(BucketChipFramePreferenceKey.self) { frames in
            bucketFrames = frames
        }
        .onAppear {
            isSearchFocused = store.isSearchExpanded
        }
        .onChange(of: store.isSearchExpanded) { _, isExpanded in
            if isExpanded {
                focusSearchFieldAndMoveCursorToEnd()
            }
        }
    }

    private var topBar: some View {
        ZStack(alignment: .trailing) {
            centeredTopControls
            shortcutHints
                .padding(.trailing, 2)
        }
        .padding(.horizontal, 4)
        .animation(.snappy(duration: 0.2), value: store.isSearchExpanded)
    }

    private var centeredTopControls: some View {
        HStack(spacing: 8) {
            if !store.isSearchExpanded {
                searchToggleButton
            }

            if store.isSearchExpanded {
                searchPill
                    .frame(width: 236)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            HStack(spacing: 4) {
                bucketStrip
                    .frame(width: bucketStripWidth)

                addBucketButton
            }
        }
        .frame(height: topControlHeight)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var searchToggleButton: some View {
        Button {
            if store.isSearchExpanded, store.query.isEmpty {
                store.collapseSearchIfPossible()
            } else {
                store.toggleSearchExpanded()
            }
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: topControlHeight, height: topControlHeight)
                .background {
                    Circle()
                        .fill(.white.opacity(0.10))
                }
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.26), lineWidth: 0.8)
                }
        }
        .buttonStyle(.plain)
    }

    private var addBucketButton: some View {
        Button {
            store.createBucketAndSelect()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 22, height: topControlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var bucketStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            bucketChipsRow
        }
    }

    private var bucketChipsRow: some View {
        HStack(spacing: 8) {
            ClipboardBucketChip(isSelected: store.isShowingClipboard) {
                store.showClipboardScope()
            }

            ForEach(store.buckets) { bucket in
                BucketChip(
                    title: bucket.name,
                    color: Color(hex: bucket.colorHex),
                    isSelected: store.selectedBucketID == bucket.id,
                    isDropTargeted: hoveredBucketID == bucket.id,
                    didJustReceiveDrop: dropPulseBucketID == bucket.id,
                    onTap: {
                        store.showBucketScope(bucketID: bucket.id)
                    },
                    onRename: { newName in
                        store.renameBucket(bucketID: bucket.id, newName: newName)
                    },
                    onDelete: {
                        promptDelete(for: bucket)
                    },
                    onRecolor: { newColorHex in
                        store.recolorBucket(bucketID: bucket.id, colorHex: newColorHex)
                    }
                )
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: BucketChipFramePreferenceKey.self,
                            value: [bucket.id: proxy.frame(in: .named(dragCoordinateSpaceName))]
                        )
                    }
                }
            }
        }
    }

    private var bucketStripWidth: CGFloat {
        var estimated: CGFloat = estimatedClipboardChipWidth

        for bucket in store.buckets {
            estimated += 8 + estimatedBucketChipWidth(title: bucket.name)
        }

        return min(max(estimated, 150), 520)
    }

    private var estimatedClipboardChipWidth: CGFloat {
        // icon + spacing + text + horizontal padding + visual buffer
        10 + 6 + 9 * 6.2 + 20 + 3
    }

    private func estimatedBucketChipWidth(title: String) -> CGFloat {
        // dot + spacing + title + horizontal padding + visual buffer
        let clampedChars = min(max(title.count, 4), 24)
        return 9 + 6 + CGFloat(clampedChars) * 6.0 + 20 + 3
    }

    private var shortcutHints: some View {
        HStack(spacing: 14) {
            hintLabel("\u{2190} \u{2192}", "navigate")
            hintLabel("\u{21a9}", "copy")
            hintLabel("\u{2318}1-9", "jump")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func hintLabel(_ symbol: String, _ label: String) -> some View {
        HStack(alignment: .center, spacing: 3) {
            Text(symbol)
                .font(.system(size: 9, weight: .medium))
                .baselineOffset(-1)
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.44))
    }

    private var searchPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.80))

            TextField("", text: $store.query, prompt:
                Text(searchPlaceholder)
                    .foregroundStyle(.white.opacity(0.38))
            )
            .font(.system(size: 12, weight: .regular, design: .rounded))
            .foregroundStyle(.white.opacity(0.88))
            .textFieldStyle(.plain)
            .focused($isSearchFocused)
        }
        .padding(.horizontal, 12)
        .frame(height: topControlHeight)
        .background {
            Capsule()
                .fill(.white.opacity(0.10))
                .background {
                    Capsule()
                        .fill(.ultraThinMaterial.opacity(0.50))
                }
        }
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.28), lineWidth: 0.8)
        }
    }

    private var searchPlaceholder: String {
        if let activeBucket = store.activeBucket {
            return "Search \(activeBucket.name)"
        }
        return "Search clipboard"
    }

    private func focusSearchFieldAndMoveCursorToEnd() {
        isSearchFocused = true
        placeSearchCursorAtEnd()

        DispatchQueue.main.async {
            self.placeSearchCursorAtEnd()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            self.placeSearchCursorAtEnd()
        }
    }

    private func placeSearchCursorAtEnd() {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        let location = editor.string.utf16.count
        editor.setSelectedRange(NSRange(location: location, length: 0))
    }

    private func cardsView(filtered: [ClipItem]) -> some View {
        let enumeratedItems = Array(filtered.enumerated())
        let selectedItemID = store.selectedItem()?.id
        let activeBucketAccentColor = store.activeBucket.map { Color(hex: $0.colorHex) }
        let isBucketScope = !store.isShowingClipboard

        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(enumeratedItems, id: \.element.id) { entry in
                        let index = entry.offset
                        let item = entry.element
                        let clipboardScopeAccentColor = droppedBucketColorByClipID[item.id].map(Color.init(hex:))

                        ClipCardView(
                            item: item,
                            isSelected: selectedItemID == item.id,
                            commandNumber: index < 9 ? index + 1 : nil,
                            icon: store.icon(for: item),
                            accentColorOverride: isBucketScope ? activeBucketAccentColor : clipboardScopeAccentColor,
                            isTitleEditable: isBucketScope,
                            onTitleChange: { title in
                                store.updateTitleOverrideForSelectedBucket(clipItemID: item.id, title: title)
                            },
                            linkPreviewStore: linkPreviewStore
                        )
                        .id(item.id)
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .onTapGesture {
                            store.select(index)
                        }
                        .onTapGesture(count: 2) {
                            onActivateItem(index)
                        }
                        .opacity(activeCardDrag?.clipItemID == item.id ? 0.34 : 1.0)
                        .highPriorityGesture(cardDragGesture(for: item))
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
            .onChange(of: store.selectedIndex) { _, newValue in
                if filtered.indices.contains(newValue) {
                    proxy.scrollTo(filtered[newValue].id)
                }
            }
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Loading history…")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            Text("Preparing your recent clips.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.60))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 6)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(emptyStateTitle)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            Text(emptyStateSubtitle)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.60))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 6)
        .padding(.vertical, 12)
    }

    private var emptyStateTitle: String {
        if FuzzyMatcher.normalize(store.query).isEmpty {
            if let activeBucket = store.activeBucket {
                return "\(activeBucket.name) is empty"
            }
            return "Clipboard is empty"
        }

        return "No matches"
    }

    private var emptyStateSubtitle: String {
        if FuzzyMatcher.normalize(store.query).isEmpty {
            if store.activeBucket != nil {
                return "Drag cards into this bucket to save them."
            }
            return "Copy something to start building your history."
        }

        return "Try a shorter query or clear search with Escape."
    }

    // MARK: - Bucket interactions

    private func handleDrop(clipItemID: Int64, into bucketID: Int64, bucketColorHex: String) -> Bool {
        droppedBucketColorByClipID[clipItemID] = bucketColorHex
        store.addItemToBucket(clipItemID: clipItemID, bucketID: bucketID)
        playBucketDropPulse(bucketID: bucketID)
        return true
    }

    private func cardDragGesture(for item: ClipItem) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(dragCoordinateSpaceName))
            .onChanged { value in
                updateCardDrag(for: item, location: value.location)
            }
            .onEnded { value in
                finishCardDrag(for: item, location: value.location)
            }
    }

    private func updateCardDrag(for item: ClipItem, location: CGPoint) {
        if activeCardDrag?.clipItemID == item.id {
            activeCardDrag?.location = location
        } else {
            activeCardDrag = ActiveCardDrag(
                clipItemID: item.id,
                title: item.displayTitle,
                location: location
            )
        }

        hoveredBucketID = bucketID(at: location)
    }

    private func finishCardDrag(for item: ClipItem, location: CGPoint) {
        guard activeCardDrag?.clipItemID == item.id else {
            activeCardDrag = nil
            hoveredBucketID = nil
            return
        }

        let destinationBucketID = bucketID(at: location)

        activeCardDrag = nil
        hoveredBucketID = nil

        guard let destinationBucketID,
              let bucket = store.buckets.first(where: { $0.id == destinationBucketID }) else {
            return
        }

        _ = handleDrop(
            clipItemID: item.id,
            into: destinationBucketID,
            bucketColorHex: bucket.colorHex
        )
    }

    private func bucketID(at location: CGPoint) -> Int64? {
        for bucket in store.buckets {
            guard let frame = bucketFrames[bucket.id] else { continue }
            if frame.contains(location) {
                return bucket.id
            }
        }
        return nil
    }

    private func playBucketDropPulse(bucketID: Int64) {
        dropPulseBucketID = bucketID

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            if dropPulseBucketID == bucketID {
                dropPulseBucketID = nil
            }
        }
    }

    private func dragPreview(title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))

            Text(title)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.black.opacity(0.74))
        )
        .overlay(
            Capsule()
                .stroke(.white.opacity(0.20), lineWidth: 0.8)
        )
        .frame(maxWidth: 140)
    }

    private func promptDelete(for bucket: Bucket) {
        let alert = NSAlert()
        alert.messageText = "Delete \"\(bucket.name)\"?"
        alert.informativeText = "Items stay in your clipboard history."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        store.deleteBucket(bucketID: bucket.id)
    }
}

private struct ClipboardBucketChip: View {
    let isSelected: Bool
    let onTap: () -> Void
    private let chipHeight: CGFloat = 27

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.78))

                Text("Clipboard")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.80))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: chipHeight)
            .background {
                Capsule()
                    .fill(isSelected ? .white.opacity(0.18) : .white.opacity(0.08))
            }
            .overlay {
                Capsule()
                    .stroke(isSelected ? .white.opacity(0.42) : .white.opacity(0.24), lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct BucketChip: View {
    let title: String
    let color: Color
    let isSelected: Bool
    let isDropTargeted: Bool
    let didJustReceiveDrop: Bool
    let onTap: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onRecolor: (String) -> Void

    @State private var isRenaming = false
    @State private var renameDraft = ""
    @FocusState private var isRenameFocused: Bool
    private let chipHeight: CGFloat = 29
    private let hitTargetHeight: CGFloat = 32

    var body: some View {
        Group {
            if isRenaming {
                HStack(spacing: 6) {
                    Circle()
                        .fill(color)
                        .frame(width: 9, height: 9)

                    TextField("", text: $renameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.96))
                        .focused($isRenameFocused)
                        .onSubmit {
                            commitRename()
                        }
                        .onAppear {
                            DispatchQueue.main.async {
                                isRenameFocused = true
                            }
                        }
                        .onChange(of: isRenameFocused) { _, focused in
                            if !focused {
                                commitRename()
                            }
                        }
                }
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(color)
                        .frame(width: 9, height: 9)

                    Text(title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(isSelected ? 0.96 : 0.82))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onTap()
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: chipHeight)
        .background {
            Capsule()
                .fill(backgroundFill)
        }
        .overlay {
            Capsule()
                .stroke(
                    strokeColor,
                    lineWidth: isDropTargeted || didJustReceiveDrop ? 1.6 : 0.8
                )
        }
        .overlay(alignment: .topTrailing) {
            if isDropTargeted {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(red: 0.35, green: 0.93, blue: 0.53))
                    .offset(x: 4, y: -4)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .scaleEffect(isDropTargeted ? 1.04 : (didJustReceiveDrop ? 1.07 : 1.0))
        .shadow(color: glowColor, radius: isDropTargeted ? 12 : (didJustReceiveDrop ? 10 : 0), y: 0)
        .animation(.spring(response: 0.25, dampingFraction: 0.78), value: isDropTargeted)
        .animation(.spring(response: 0.26, dampingFraction: 0.62), value: didJustReceiveDrop)
        .frame(height: hitTargetHeight)
        .contentShape(Rectangle())
        .onChange(of: title) { _, _ in
            if !isRenaming {
                renameDraft = title
            }
        }
        .onExitCommand {
            if isRenaming {
                cancelRename()
            }
        }
        .contextMenu {
            Button("Rename") {
                beginRename()
            }

            Menu("Color") {
                ForEach(BucketDefaults.colorPalette) { option in
                    Button {
                        onRecolor(option.hex)
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(hex: option.hex))
                                .frame(width: 10, height: 10)
                            Text(option.name)
                        }
                    }
                }
            }

            Button("Delete...", role: .destructive) {
                onDelete()
            }
        }
    }

    private func beginRename() {
        renameDraft = title
        isRenaming = true
    }

    private func cancelRename() {
        isRenaming = false
        isRenameFocused = false
        renameDraft = title
    }

    private func commitRename() {
        guard isRenaming else { return }

        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != title {
            onRename(trimmed)
        } else {
            renameDraft = title
        }

        isRenaming = false
        isRenameFocused = false
    }

    private var backgroundFill: Color {
        if didJustReceiveDrop {
            return color.opacity(0.30)
        }
        if isDropTargeted {
            return color.opacity(0.24)
        }
        return isSelected ? .white.opacity(0.18) : .white.opacity(0.08)
    }

    private var strokeColor: Color {
        if isDropTargeted || didJustReceiveDrop {
            return color.opacity(0.95)
        }
        return isSelected ? .white.opacity(0.42) : .white.opacity(0.24)
    }

    private var glowColor: Color {
        if isDropTargeted || didJustReceiveDrop {
            return color.opacity(0.42)
        }
        return .clear
    }
}

private struct ActiveCardDrag {
    let clipItemID: Int64
    let title: String
    var location: CGPoint
}

private struct BucketChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int64: CGRect] = [:]

    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private extension Color {
    init(hex: String) {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        var hexString = normalized

        if hexString.hasPrefix("#") {
            hexString.removeFirst()
        }

        guard hexString.count == 6,
              let value = UInt32(hexString, radix: 16) else {
            self = Color(red: 1.0, green: 0.278, blue: 0.278)
            return
        }

        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0

        self = Color(red: red, green: green, blue: blue)
    }
}
