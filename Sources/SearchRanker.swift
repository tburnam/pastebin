import Foundation

enum SearchRanker {
    private struct RankedCandidate {
        let item: ClipItem
        let score: Int
        let indexedOrder: Int
    }

    private struct SearchFields {
        let title: String
        let fileNames: String
        let appName: String
        let urlHost: String
        let url: String
        let typeTerms: String
        let content: String

        init(item: ClipItem) {
            title = SearchRanker.normalized(item.customTitle)
            fileNames = SearchRanker.normalized(
                item.filePaths
                    .map { URL(fileURLWithPath: $0).lastPathComponent }
                    .joined(separator: " ")
            )
            appName = SearchRanker.normalized(item.sourceAppName)
            urlHost = SearchRanker.normalized(item.linkURL?.host)
            url = SearchRanker.normalized(item.linkURL?.absoluteString)
            typeTerms = SearchRanker.normalized(SearchRanker.typeTerms(for: item))
            content = String(decoding: item.searchableContentUTF8, as: UTF8.self)
        }
    }

    private struct FieldWeights {
        let exact: Int
        let prefix: Int
        let wholeWord: Int
        let contains: Int
        let tokenPrefix: Int
        let tokenWholeWord: Int
        let tokenContains: Int
    }

    static func rerank(
        normalizedQuery: String,
        queryTokens: [Substring],
        candidates: [ClipItem],
        indexedOrderByID: [Int64: Int] = [:],
        limit: Int
    ) -> [ClipItem] {
        guard limit > 0 else { return [] }
        guard !candidates.isEmpty else { return [] }
        guard !normalizedQuery.isEmpty else { return Array(candidates.prefix(limit)) }

        let tokenStrings = queryTokens
            .map(String.init)
            .filter { !$0.isEmpty }
        let now = Date()

        let ranked = candidates.map { item -> RankedCandidate in
            let fields = SearchFields(item: item)
            let indexedOrder = indexedOrderByID[item.id] ?? Int.max
            var score = 0

            score += scoreField(
                fields.title,
                normalizedQuery: normalizedQuery,
                tokenStrings: tokenStrings,
                weights: FieldWeights(
                    exact: 2_200,
                    prefix: 1_700,
                    wholeWord: 1_250,
                    contains: 880,
                    tokenPrefix: 260,
                    tokenWholeWord: 180,
                    tokenContains: 90
                )
            )

            score += scoreField(
                fields.fileNames,
                normalizedQuery: normalizedQuery,
                tokenStrings: tokenStrings,
                weights: FieldWeights(
                    exact: 1_950,
                    prefix: 1_500,
                    wholeWord: 1_100,
                    contains: 760,
                    tokenPrefix: 240,
                    tokenWholeWord: 170,
                    tokenContains: 80
                )
            )

            score += scoreField(
                fields.urlHost,
                normalizedQuery: normalizedQuery,
                tokenStrings: tokenStrings,
                weights: FieldWeights(
                    exact: 1_850,
                    prefix: 1_400,
                    wholeWord: 1_050,
                    contains: 700,
                    tokenPrefix: 220,
                    tokenWholeWord: 150,
                    tokenContains: 72
                )
            )

            score += scoreField(
                fields.appName,
                normalizedQuery: normalizedQuery,
                tokenStrings: tokenStrings,
                weights: FieldWeights(
                    exact: 1_600,
                    prefix: 1_240,
                    wholeWord: 920,
                    contains: 620,
                    tokenPrefix: 210,
                    tokenWholeWord: 150,
                    tokenContains: 70
                )
            )

            score += scoreField(
                fields.url,
                normalizedQuery: normalizedQuery,
                tokenStrings: tokenStrings,
                weights: FieldWeights(
                    exact: 1_050,
                    prefix: 820,
                    wholeWord: 620,
                    contains: 420,
                    tokenPrefix: 140,
                    tokenWholeWord: 110,
                    tokenContains: 56
                )
            )

            score += scoreField(
                fields.typeTerms,
                normalizedQuery: normalizedQuery,
                tokenStrings: tokenStrings,
                weights: FieldWeights(
                    exact: 920,
                    prefix: 700,
                    wholeWord: 480,
                    contains: 280,
                    tokenPrefix: 100,
                    tokenWholeWord: 80,
                    tokenContains: 40
                )
            )

            score += scoreField(
                fields.content,
                normalizedQuery: normalizedQuery,
                tokenStrings: tokenStrings,
                weights: FieldWeights(
                    exact: 520,
                    prefix: 360,
                    wholeWord: 260,
                    contains: 180,
                    tokenPrefix: 56,
                    tokenWholeWord: 44,
                    tokenContains: 18
                )
            )

            if indexedOrder != Int.max {
                score += max(0, 560 - indexedOrder * 3)
            }

            score += recencyBoost(for: item.copiedAt, now: now)

            return RankedCandidate(item: item, score: score, indexedOrder: indexedOrder)
        }

        return ranked
            .sorted(by: outranks(_:_:))
            .prefix(limit)
            .map(\.item)
    }

    private static func scoreField(
        _ field: String,
        normalizedQuery: String,
        tokenStrings: [String],
        weights: FieldWeights
    ) -> Int {
        guard !field.isEmpty else { return 0 }

        var score = 0
        score += scorePhrase(field, query: normalizedQuery, weights: weights)

        for token in tokenStrings where token.count >= 2 {
            if field == token {
                score += weights.tokenPrefix + weights.tokenWholeWord
                continue
            }
            if field.hasPrefix(token) || containsTokenPrefix(field, token: token) {
                score += weights.tokenPrefix
                continue
            }
            if containsWholeWord(field, token: token) {
                score += weights.tokenWholeWord
                continue
            }
            if field.contains(token) {
                score += weights.tokenContains
            }
        }

        return score
    }

    private static func scorePhrase(_ field: String, query: String, weights: FieldWeights) -> Int {
        guard !query.isEmpty else { return 0 }

        if field == query {
            return weights.exact
        }
        if field.hasPrefix(query) {
            return weights.prefix
        }
        if containsWholeWord(field, token: query) {
            return weights.wholeWord
        }
        if field.contains(query) {
            return weights.contains
        }
        return 0
    }

    private static func containsWholeWord(_ text: String, token: String) -> Bool {
        guard !text.isEmpty, !token.isEmpty else { return false }

        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: token, options: [], range: searchRange) {
            let lowerIsBoundary = range.lowerBound == text.startIndex
                || isDelimiter(text[text.index(before: range.lowerBound)])
            let upperIsBoundary = range.upperBound == text.endIndex
                || isDelimiter(text[range.upperBound])
            if lowerIsBoundary && upperIsBoundary {
                return true
            }
            searchRange = range.upperBound..<text.endIndex
        }

        return false
    }

    private static func containsTokenPrefix(_ text: String, token: String) -> Bool {
        guard !text.isEmpty, !token.isEmpty else { return false }

        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: token, options: [], range: searchRange) {
            let lowerIsBoundary = range.lowerBound == text.startIndex
                || isDelimiter(text[text.index(before: range.lowerBound)])
            if lowerIsBoundary {
                return true
            }
            searchRange = range.upperBound..<text.endIndex
        }

        return false
    }

    private static func recencyBoost(for copiedAt: Date, now: Date) -> Int {
        let age = now.timeIntervalSince(copiedAt)
        switch age {
        case ..<3_600:
            return 150
        case ..<86_400:
            return 92
        case ..<604_800:
            return 38
        case ..<2_592_000:
            return 14
        default:
            return 0
        }
    }

    private static func outranks(_ lhs: RankedCandidate, _ rhs: RankedCandidate) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        if lhs.indexedOrder != rhs.indexedOrder {
            return lhs.indexedOrder < rhs.indexedOrder
        }
        if lhs.item.copiedAt != rhs.item.copiedAt {
            return lhs.item.copiedAt > rhs.item.copiedAt
        }
        return lhs.item.id < rhs.item.id
    }

    private static func normalized(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        return FuzzyMatcher.normalize(value)
    }

    private static func typeTerms(for item: ClipItem) -> String {
        var components: [String] = [item.contentType.storageValue.replacingOccurrences(of: "_", with: " ")]
        if let codeLanguage = item.codeLanguage {
            components.append(codeLanguage)
        }
        if let structuredFormat = item.structuredFormat?.rawValue {
            components.append(structuredFormat)
        }
        return components.joined(separator: " ")
    }

    private static func isDelimiter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { !CharacterSet.alphanumerics.contains($0) }
    }
}
