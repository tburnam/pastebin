import AppKit
import SwiftUI

@MainActor
struct ClipCardView: View {
    let item: ClipItem
    let isSelected: Bool
    let commandNumber: Int?
    let icon: NSImage?
    let accentColorOverride: Color?
    let isTitleEditable: Bool
    let onTitleChange: ((String?) -> Void)?
    let onTitleEditingStateChange: ((Bool) -> Void)?
    @ObservedObject var linkPreviewStore: LinkPreviewStore
    @ObservedObject var filePreviewStore: FilePreviewStore

    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @FocusState private var isTitleFocused: Bool

    private let cardBase = Color(white: 0.11)
    private let selectionColor = Color(red: 0.35, green: 0.55, blue: 1.0)
    private let headerHeight: CGFloat = 64
    private let textPreviewLineLimit = 8
    private let snippetPreviewLineLimit = 8

    // Fast accent lookup: known apps get fixed colors, everything else is off-black.
    private static let offBlackAccent = Color(red: 0.10, green: 0.10, blue: 0.11)
    private static let blueAccent = Color(red: 0.13, green: 0.46, blue: 0.88)
    private static let chromeAccent = Color(red: 66.0 / 255.0, green: 133.0 / 255.0, blue: 244.0 / 255.0) // #4285F4
    private static let greenAccent = Color(red: 0.20, green: 0.67, blue: 0.30)
    private static let purpleAccent = Color(red: 0.43, green: 0.19, blue: 0.53)
    private static let yellowAccent = Color(red: 0.74, green: 0.63, blue: 0.23)
    private static let grayAccent = Color(red: 0.40, green: 0.40, blue: 0.42)
    private static let blackAccent = Color(red: 0.05, green: 0.05, blue: 0.06)
    private static let offWhiteAccent = Color(red: 0.78, green: 0.76, blue: 0.71)
    private static let bundleAccentMap: [String: Color] = [
        "com.tinyspeck.slackmacgap": purpleAccent,
        "com.google.Chrome": chromeAccent,
        "com.apple.finder": blueAccent,
        "com.apple.TextEdit": grayAccent,
        "com.todesktop.230313mzl4w4u92": blackAccent, // Cursor
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
    private static let appNameAccentMap: [String: Color] = [
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
    private static let richTextPreviewCache = NSCache<NSString, NSAttributedString>()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            cardContent
        }
        .frame(width: 244, height: 252, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardBase)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isSelected ? selectionColor.opacity(0.80) : .white.opacity(0.06),
                    lineWidth: isSelected ? 2.5 : 0.5
                )
        }
        .shadow(color: .black.opacity(isSelected ? 0.32 : 0.20), radius: isSelected ? 10 : 6, y: 2)
        .task(id: item.linkURL?.absoluteString) {
            guard let linkURL = item.linkURL else { return }
            linkPreviewStore.loadPreview(for: linkURL)
        }
        .task(id: firstFilePath) {
            guard case .fileList = item.contentType else { return }
            guard let firstFilePath else { return }
            filePreviewStore.loadPreview(for: firstFilePath)
        }
        .onChange(of: item.customTitle) { _, _ in
            guard !isEditingTitle else { return }
            titleDraft = item.customTitle ?? ""
        }
        .onDisappear {
            if isEditingTitle {
                onTitleEditingStateChange?(false)
            }
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        switch item.contentType {
        case .link:
            linkContent
        case .code:
            codeContent
        case .image:
            imageContent
        case .fileList:
            fileListContent
        case .richText:
            richTextContent
        case .structured:
            structuredContent
        case .text:
            textContent
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                titleView
                    .padding(.top, 5)

                Text(relativeCopiedTime)
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .layoutPriority(1)
            .padding(.top, 4)

            Spacer(minLength: 0)

            appIcon
                .padding(.top, 2)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, minHeight: headerHeight, maxHeight: headerHeight, alignment: .topLeading)
        .background(effectiveAccentColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.black.opacity(0.22))
                .frame(height: 0.7)
        }
        .contentShape(Rectangle())
        .highPriorityGesture(
            TapGesture(count: 2).onEnded {
                guard isTitleEditable else { return }
                beginTitleEdit()
            }
        )
    }

    @ViewBuilder
    private var titleView: some View {
        if isEditingTitle {
            TextField("", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .focused($isTitleFocused)
                .onSubmit {
                    commitTitleEdit()
                }
                .onAppear {
                    DispatchQueue.main.async {
                        isTitleFocused = true
                    }
                }
                .onChange(of: isTitleFocused) { _, focused in
                    if !focused {
                        commitTitleEdit()
                    }
                }
        } else {
            Text(item.displayTitle)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.tail)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard isTitleEditable else { return }
                    beginTitleEdit()
                }
        }
    }

    private var textContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.previewText.isEmpty ? "(empty)" : item.previewText)
                .font(.system(size: 13.5, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.74))
                .lineLimit(textPreviewLineLimit)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)

            Spacer(minLength: 0)

            footer(showCharacterCount: true)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var codeContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            snippetPanel(text: codeSnippetText, monospaced: true, lineLimit: snippetPreviewLineLimit)
                .padding(.top, 12)

            Spacer(minLength: 0)

            footer(showCharacterCount: true)
                .padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var structuredContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            snippetPanel(text: structuredSnippetText, monospaced: true, lineLimit: snippetPreviewLineLimit)
                .padding(.top, 12)

            Spacer(minLength: 0)

            footer(showCharacterCount: true)
                .padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var richTextContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            richTextPreview
                .padding(.top, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer(showCharacterCount: true)
                .padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var imageContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            imagePreviewBox
                .padding(.top, 12)

            Spacer(minLength: 0)

            footer(showCharacterCount: false)
                .padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var fileListContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            filePreviewBox
            .padding(.top, 10)

            Text(fileTitle)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

            Text(fileSubtitle)
                .font(.system(size: 9.8, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.46))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)

            Spacer(minLength: 0)

            footer(showCharacterCount: false)
                .padding(.top, 9)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var linkContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            linkPreviewBox
                .padding(.top, 10)

            Text(linkTitle)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

            Text(linkSubtitle)
                .font(.system(size: 9.8, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.46))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)

            Spacer(minLength: 0)

            footer(showCharacterCount: false)
                .padding(.top, 9)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var linkPreviewBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(white: 0.84, opacity: 0.90))

            if let previewImage = linkPreview?.image {
                Image(nsImage: previewImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "link")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.34))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.black.opacity(0.12), lineWidth: 0.7)
        }
    }

    private var imagePreviewBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.06))

            if let imagePreview {
                Image(nsImage: imagePreview)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.38))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 124)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 0.7)
        }
    }

    private var filePreviewBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(white: 0.84, opacity: 0.90))

            if let filePreviewImage {
                Image(nsImage: filePreviewImage)
                    .resizable()
                    .scaledToFill()
            } else if let filePreviewIcon {
                Image(nsImage: filePreviewIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 58, height: 58)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.34))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.black.opacity(0.12), lineWidth: 0.7)
        }
    }

    private func snippetPanel(text: String, monospaced: Bool, lineLimit: Int) -> some View {
        Text(text.isEmpty ? "(empty)" : text)
            .font(.system(size: 11.5, weight: .regular, design: monospaced ? .monospaced : .rounded))
            .foregroundStyle(.white.opacity(0.74))
            .lineLimit(lineLimit)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 0.7)
            )
    }

    @ViewBuilder
    private var richTextPreview: some View {
        if let attributed = richTextAttributedPreview, !attributed.characters.isEmpty {
            Text(attributed)
                .font(.system(size: 13.5, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.74))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(item.previewText.isEmpty ? "(empty)" : item.previewText)
                .font(.system(size: 13.5, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.74))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var richTextAttributedPreview: AttributedString? {
        let cacheKey = item.dedupeKey as NSString
        if let cached = Self.richTextPreviewCache.object(forKey: cacheKey) {
            return AttributedString(cached)
        }

        guard let parsed = parsedRichTextPreview else {
            return nil
        }

        let sanitized = sanitizedRichText(parsed)
        Self.richTextPreviewCache.setObject(sanitized, forKey: cacheKey)
        return AttributedString(sanitized)
    }

    private var parsedRichTextPreview: NSAttributedString? {
        if let rtfData = item.rtfData,
           let attributed = try? NSAttributedString(
               data: rtfData,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ) {
            return attributed
        }

        if let htmlContent = item.htmlContent,
           let htmlData = htmlContent.data(using: .utf8),
           let attributed = try? NSAttributedString(
               data: htmlData,
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue
               ],
               documentAttributes: nil
           ) {
            return attributed
        }

        return nil
    }

    private func sanitizedRichText(_ attributed: NSAttributedString) -> NSAttributedString {
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

        return mutable
    }

    private func footer(showCharacterCount: Bool) -> some View {
        HStack(spacing: 6) {
            if showCharacterCount {
                Text("\(item.characterCount) characters")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.36))
            }

            Spacer(minLength: 0)

            if let commandNumber {
                Text("⌘\(commandNumber)")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.50))
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .background(
                        Capsule()
                            .fill(.white.opacity(0.06))
                    )
            }
        }
    }

    private var imagePreview: NSImage? {
        guard let payloadData = item.payloadData else { return nil }
        return NSImage(data: payloadData)
    }

    private var firstFilePath: String? {
        item.filePaths.first
    }

    private var filePreviewImage: NSImage? {
        guard let firstFilePath else { return nil }
        if let cached = filePreviewStore.preview(for: firstFilePath) {
            return cached
        }
        return NSImage(contentsOfFile: firstFilePath)
    }

    private var filePreviewIcon: NSImage? {
        guard let firstFilePath else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: firstFilePath)
        icon.size = NSSize(width: 58, height: 58)
        return icon
    }

    private var fileTitle: String {
        guard let firstFilePath else { return "Files" }

        let firstName = URL(fileURLWithPath: firstFilePath).lastPathComponent
        let displayName = firstName.isEmpty ? firstFilePath : firstName

        if item.filePaths.count > 1 {
            return "\(displayName) +\(item.filePaths.count - 1) more"
        }

        return displayName
    }

    private var fileSubtitle: String {
        guard let firstFilePath else { return "No path available" }
        return firstFilePath
    }

    private var codeSnippetText: String {
        item.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(6)
            .joined(separator: "\n")
    }

    private var structuredSnippetText: String {
        guard let format = item.structuredFormat else {
            return codeSnippetText
        }

        switch format {
        case .json:
            return prettyPrintedJSONSnippet ?? codeSnippetText
        case .xml, .csv:
            return codeSnippetText
        }
    }

    private var prettyPrintedJSONSnippet: String? {
        guard let data = item.content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              let prettyString = String(data: pretty, encoding: .utf8) else {
            return nil
        }

        return prettyString
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(6)
            .joined(separator: "\n")
    }

    private var linkPreview: LinkPreviewData? {
        guard let linkURL = item.linkURL else { return nil }
        return linkPreviewStore.preview(for: linkURL)
    }

    private var linkTitle: String {
        if let title = linkPreview?.title, !title.isEmpty {
            return title
        }

        if let host = item.linkURL?.host, !host.isEmpty {
            return host
        }

        return "Link"
    }

    private var linkSubtitle: String {
        item.linkDisplayText ?? item.previewText
    }

    private var effectiveAccentColor: Color {
        if let accentColorOverride {
            return accentColorOverride
        }
        return accentColor
    }

    // MARK: - Accent color

    private var accentColor: Color {
        if let bundleID = item.sourceBundleID,
           let mapped = Self.bundleAccentMap[bundleID] {
            return mapped
        }

        if let appName = item.sourceAppName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           let mapped = Self.appNameAccentMap[appName] {
            return mapped
        }

        return Self.offBlackAccent
    }

    private var appIcon: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 46, height: 46)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.black.opacity(0.28))

                    Image(systemName: "app.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.44))
                }
            }
        }
        .frame(width: 54, height: 54)
    }

    private var relativeCopiedTime: String {
        let elapsed = max(0, Int(Date().timeIntervalSince(item.copiedAt)))

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

    private func beginTitleEdit() {
        guard isTitleEditable, !isEditingTitle else { return }
        titleDraft = item.customTitle ?? item.typeLabel
        isEditingTitle = true
        onTitleEditingStateChange?(true)
    }

    private func commitTitleEdit() {
        guard isEditingTitle else { return }

        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty || trimmed == item.typeLabel ? nil : trimmed

        isEditingTitle = false
        isTitleFocused = false
        onTitleEditingStateChange?(false)
        onTitleChange?(normalized)
    }
}
