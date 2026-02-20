import AppKit
import SwiftUI

struct ClipCardView: View {
    let item: ClipItem
    let isSelected: Bool
    let commandNumber: Int?
    let icon: NSImage?

    private let cardBase = Color(white: 0.11)
    private let selectionColor = Color(red: 0.35, green: 0.55, blue: 1.0)

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Text")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))

                    Text(relativeCopiedTime)
                        .font(.system(size: 9, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.46))
                        .lineLimit(1)
                }
                .padding(.top, 4)

                Spacer(minLength: 0)

                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accentColor)

            // Content area
            VStack(alignment: .leading, spacing: 0) {
                Text(item.previewText.isEmpty ? "(empty)" : item.previewText)
                    .font(.system(size: 13.5, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Text("\(item.characterCount) characters")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.36))

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
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(width: 232, height: 240)
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
}
