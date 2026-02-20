import Foundation

enum FuzzyMatcher {
    private static let delimiterSet = CharacterSet.alphanumerics.inverted

    static func filter(query: String, in items: [ClipItem], limit: Int = 250) -> [ClipItem] {
        guard limit > 0 else { return [] }

        let normalizedQuery = normalize(query)

        guard !normalizedQuery.isEmpty else {
            return items
        }

        // Primary behavior: strict token containment so results visibly narrow while typing.
        // Keeps recency order from `items`.
        let queryTokens = normalizedQuery
            .split(whereSeparator: { $0.unicodeScalars.allSatisfy { delimiterSet.contains($0) } })
            .map(String.init)

        if !queryTokens.isEmpty {
            var strictMatches: [ClipItem] = []
            strictMatches.reserveCapacity(min(limit, items.count))

            for item in items {
                if queryTokens.allSatisfy({ token in
                    item.searchableContent.contains(token)
                }) {
                    strictMatches.append(item)
                    if strictMatches.count >= limit {
                        break
                    }
                }
            }

            if !strictMatches.isEmpty {
                return strictMatches
            }
        }

        // Fallback: fuzzy subsequence matching for typo tolerance when strict search returns nothing.
        let queryCharacters = Array(normalizedQuery)
        var topMatches: [(item: ClipItem, score: Int)] = []
        topMatches.reserveCapacity(min(items.count, limit))

        for item in items {
            if let score = score(query: queryCharacters, in: item.searchableContent) {
                let candidate = (item: item, score: score)

                if topMatches.count < limit {
                    insertSorted(candidate, into: &topMatches)
                    continue
                }

                if let weakestMatch = topMatches.last, outranks(candidate, than: weakestMatch) {
                    insertSorted(candidate, into: &topMatches)
                    if topMatches.count > limit {
                        topMatches.removeLast()
                    }
                }
            }
        }

        return topMatches.map(\.item)
    }

    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func score(query: [Character], in candidate: String) -> Int? {
        guard !query.isEmpty else {
            return 0
        }

        let candidateCharacters = Array(candidate)
        guard candidateCharacters.count >= query.count else {
            return nil
        }

        var queryIndex = 0
        var lastMatchIndex = -2
        var score = 0

        for candidateIndex in candidateCharacters.indices {
            if queryIndex >= query.count {
                break
            }

            guard candidateCharacters[candidateIndex] == query[queryIndex] else {
                continue
            }

            score += 10

            if candidateIndex == lastMatchIndex + 1 {
                score += 18
            }

            if candidateIndex == 0 || isDelimiter(candidateCharacters[candidateIndex - 1]) {
                score += 12
            }

            score += max(0, 18 - candidateIndex)

            queryIndex += 1
            lastMatchIndex = candidateIndex

            if queryIndex == query.count {
                score += max(0, 30 - (candidateCharacters.count - candidateIndex))
                return score
            }
        }

        return nil
    }

    private static func insertSorted(
        _ candidate: (item: ClipItem, score: Int),
        into matches: inout [(item: ClipItem, score: Int)]
    ) {
        var insertionIndex = matches.count

        while insertionIndex > 0 && outranks(candidate, than: matches[insertionIndex - 1]) {
            insertionIndex -= 1
        }

        matches.insert(candidate, at: insertionIndex)
    }

    private static func outranks(
        _ lhs: (item: ClipItem, score: Int),
        than rhs: (item: ClipItem, score: Int)
    ) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }

        return lhs.item.copiedAt > rhs.item.copiedAt
    }

    private static func isDelimiter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { delimiterSet.contains($0) }
    }
}
