import Foundation

struct ClipItem: Identifiable, Equatable {
    let id: Int64
    let content: String
    let copiedAt: Date
    let sourceBundleID: String?
    let sourceAppName: String?
    let searchableContent: String
    let characterCount: Int
    let previewText: String

    init(id: Int64, content: String, copiedAt: Date, sourceBundleID: String?, sourceAppName: String?) {
        self.id = id
        self.content = content
        self.copiedAt = copiedAt
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.searchableContent = content
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        self.characterCount = content.count

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        self.previewText = collapsed.count > 220 ? String(collapsed.prefix(217)) + "..." : collapsed
    }
}
