import Foundation

enum FuzzyMatcher {
    private static let delimiterSet = CharacterSet.alphanumerics.inverted

    static func filter(query: String, in items: [ClipItem], limit: Int = 250) -> [ClipItem] {
        filter(normalizedQuery: normalize(query), in: items, limit: limit)
    }

    static func filter(normalizedQuery: String, in items: [ClipItem], limit: Int = 250) -> [ClipItem] {
        guard limit > 0 else { return [] }

        guard !normalizedQuery.isEmpty else {
            return items
        }

        // Primary behavior: strict token containment so results visibly narrow while typing.
        // Keeps recency order from `items`.
        let queryTokens = normalizedQuery
            .split(whereSeparator: { $0.unicodeScalars.allSatisfy { delimiterSet.contains($0) } })

        if !queryTokens.isEmpty {
            let tokenByteArrays = queryTokens.map { ContiguousArray(String($0).utf8) }
            var strictMatches: [ClipItem] = []
            strictMatches.reserveCapacity(min(limit, items.count))

            for item in items {
                if tokenByteArrays.allSatisfy({ tokenBytes in
                    containsBytes(item.searchableContentUTF8, tokenBytes)
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
        let queryUTF8 = ContiguousArray(normalizedQuery.utf8)
        var topMatches: [(item: ClipItem, score: Int)] = []
        topMatches.reserveCapacity(min(items.count, limit))

        for item in items {
            if let score = score(queryUTF8: queryUTF8, in: item.searchableContentUTF8) {
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

    // MARK: - Byte-level substring containment (uses memcmp for SIMD-accelerated comparison)

    private static func containsBytes(
        _ haystack: ContiguousArray<UInt8>,
        _ needle: ContiguousArray<UInt8>
    ) -> Bool {
        let needleCount = needle.count
        guard needleCount > 0 else { return true }
        guard haystack.count >= needleCount else { return false }

        return haystack.withUnsafeBufferPointer { haystackBuf in
            needle.withUnsafeBufferPointer { needleBuf in
                let searchLimit = haystackBuf.count - needleBuf.count
                let firstByte = needleBuf[0]

                for i in 0...searchLimit {
                    if haystackBuf[i] == firstByte {
                        if needleCount == 1 {
                            return true
                        }
                        if memcmp(
                            haystackBuf.baseAddress! + i + 1,
                            needleBuf.baseAddress! + 1,
                            needleCount - 1
                        ) == 0 {
                            return true
                        }
                    }
                }
                return false
            }
        }
    }

    // MARK: - Byte-level fuzzy scoring

    private static func score(
        queryUTF8: ContiguousArray<UInt8>,
        in candidate: ContiguousArray<UInt8>
    ) -> Int? {
        guard !queryUTF8.isEmpty else {
            return 0
        }

        let candidateCount = candidate.count
        guard candidateCount >= queryUTF8.count else {
            return nil
        }

        var queryIndex = 0
        var lastMatchIndex = -2
        var score = 0
        let queryCount = queryUTF8.count

        for candidateIndex in 0..<candidateCount {
            if queryIndex >= queryCount {
                break
            }

            let byte = candidate[candidateIndex]
            guard byte == queryUTF8[queryIndex] else {
                continue
            }

            score += 10

            if candidateIndex == lastMatchIndex + 1 {
                score += 18
            }

            if candidateIndex == 0 || isDelimiterByte(candidate[candidateIndex - 1]) {
                score += 12
            }

            score += max(0, 18 - candidateIndex)

            queryIndex += 1
            lastMatchIndex = candidateIndex

            if queryIndex == queryCount {
                score += max(0, 30 - (candidateCount - candidateIndex))
                return score
            }
        }

        return nil
    }

    @inline(__always)
    private static func isDelimiterByte(_ byte: UInt8) -> Bool {
        if byte >= 0x61 && byte <= 0x7A { return false } // a-z
        if byte >= 0x30 && byte <= 0x39 { return false } // 0-9
        if byte >= 0x80 { return false } // multi-byte UTF8 (content character, not delimiter)
        return true
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
}
