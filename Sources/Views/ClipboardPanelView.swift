import AppKit
import SwiftUI

struct ClipboardPanelView: View {
    @ObservedObject var store: ClipboardStore
    let onActivateItem: (Int) -> Void

    @FocusState private var isSearchFocused: Bool

    private let panelRadius: CGFloat = 22
    private let edgePadding: CGFloat = 14

    var body: some View {
        let filtered = store.filteredItems

        VStack(alignment: .leading, spacing: 12) {
            topBar
                .padding(.top, 4)

            if filtered.isEmpty {
                emptyState
            } else {
                cardsView(filtered: filtered)
            }
        }
        .padding(edgePadding)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
        .shadow(color: .black.opacity(0.30), radius: 28, y: 4)
        .onAppear {
            isSearchFocused = true
        }
        .onChange(of: store.query) {
            store.selectedIndex = 0
        }
    }

    private var topBar: some View {
        HStack {
            Spacer(minLength: 0)
            searchPill
            Spacer(minLength: 0)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 14) {
                hintLabel("\u{2190} \u{2192}", "navigate")
                hintLabel("\u{21a9}", "copy")
                hintLabel("\u{21e7}\u{21a9}", "paste")
                hintLabel("\u{2318}1-9", "jump")
            }
            .offset(y: -2)
            .padding(.trailing, 4)
        }
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.80))

            TextField("", text: $store.query, prompt:
                Text("Search")
                    .foregroundStyle(.white.opacity(0.38))
            )
            .font(.system(size: 13, weight: .regular, design: .rounded))
            .foregroundStyle(.white.opacity(0.88))
            .textFieldStyle(.plain)
            .focused($isSearchFocused)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: 580)
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

    private func cardsView(filtered: [ClipItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                        ClipCardView(
                            item: item,
                            isSelected: store.selectedIndex == index,
                            commandNumber: index < 9 ? index + 1 : nil,
                            icon: store.icon(for: item)
                        )
                        .id(item.id)
                        .overlay {
                            ClickReceiver {
                                store.select(index)
                            } onDoubleClick: {
                                onActivateItem(index)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
            .onChange(of: store.selectedIndex) { _, newValue in
                if filtered.indices.contains(newValue) {
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(filtered[newValue].id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No matches")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            Text("Try a shorter query or clear search with Escape.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.60))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 6)
        .padding(.vertical, 12)
    }
}

// MARK: - Native click handling (bypasses SwiftUI gesture disambiguation)

private struct ClickReceiver: NSViewRepresentable {
    let onClick: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> ClickableNSView {
        let view = ClickableNSView()
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: ClickableNSView, context: Context) {
        nsView.onClick = onClick
        nsView.onDoubleClick = onDoubleClick
    }
}

final class ClickableNSView: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    private var lastClickTimestamp: TimeInterval = 0
    private var lastClickLocation: NSPoint = .zero
    private let doubleClickDistanceThreshold: CGFloat = 4

    override func mouseDown(with event: NSEvent) {
        onClick?()

        if isLikelyDoubleClick(event) {
            onDoubleClick?()
            resetClickTracking()
        } else {
            recordClick(event)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private func isLikelyDoubleClick(_ event: NSEvent) -> Bool {
        guard lastClickTimestamp > 0 else { return false }

        let elapsed = event.timestamp - lastClickTimestamp
        guard elapsed > 0, elapsed <= NSEvent.doubleClickInterval else {
            return false
        }

        let dx = event.locationInWindow.x - lastClickLocation.x
        let dy = event.locationInWindow.y - lastClickLocation.y
        return (dx * dx + dy * dy) <= (doubleClickDistanceThreshold * doubleClickDistanceThreshold)
    }

    private func recordClick(_ event: NSEvent) {
        lastClickTimestamp = event.timestamp
        lastClickLocation = event.locationInWindow
    }

    private func resetClickTracking() {
        lastClickTimestamp = 0
        lastClickLocation = .zero
    }
}
