import Foundation

enum FuzzyMatcher {
    private static let delimiterSet = CharacterSet.alphanumerics.inverted

    static func filter(query: String, in items: [ClipItem], limit: Int = 250) -> [ClipItem] {
        let normalizedQuery = normalize(query)

        guard !normalizedQuery.isEmpty else {
            return items
        }

        // Primary behavior: strict token containment so results visibly narrow while typing.
        // Keeps recency order from `items`.
        let queryTokens = normalizedQuery
            .split(whereSeparator: { $0.unicodeScalars.allSatisfy { delimiterSet.contains($0) } })
            .map(String.init)

        let strictMatches = items.filter { item in
            queryTokens.allSatisfy { token in
                item.searchableContent.contains(token)
            }
        }

        if !strictMatches.isEmpty {
            return Array(strictMatches.prefix(limit))
        }

        // Fallback: fuzzy subsequence matching for typo tolerance when strict search returns nothing.
        let queryCharacters = Array(normalizedQuery)
        var matches: [(item: ClipItem, score: Int)] = []
        matches.reserveCapacity(min(items.count, limit * 2))

        for item in items {
            if let score = score(query: queryCharacters, in: item.searchableContent) {
                matches.append((item: item, score: score))
            }
        }

        matches.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }

            return lhs.item.copiedAt > rhs.item.copiedAt
        }

        return matches.prefix(limit).map(\.item)
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

    private static func isDelimiter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { delimiterSet.contains($0) }
    }
}
