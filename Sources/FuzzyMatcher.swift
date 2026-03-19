import Foundation

enum FuzzyMatcher {
    private static let delimiterSet = CharacterSet.alphanumerics.inverted
    private struct SearchToken {
        let bytes: ContiguousArray<UInt8>
        let count: Int
        let firstByte: UInt8
        let lastByte: UInt8

        init(bytes: ContiguousArray<UInt8>) {
            self.bytes = bytes
            count = bytes.count
            firstByte = bytes.first ?? 0
            lastByte = bytes.last ?? 0
        }
    }

    static func filter(
        query: String,
        in items: [ClipItem],
        limit: Int = 250,
        shouldContinue: (() -> Bool)? = nil
    ) -> [ClipItem] {
        filter(normalizedQuery: normalize(query), in: items, limit: limit, shouldContinue: shouldContinue)
    }

    static func filter(
        normalizedQuery: String,
        in items: [ClipItem],
        limit: Int = 250,
        shouldContinue: (() -> Bool)? = nil
    ) -> [ClipItem] {
        guard limit > 0 else { return [] }
        guard shouldContinue?() ?? true else { return [] }

        guard !normalizedQuery.isEmpty else {
            return items
        }

        let strict = strictFilter(
            normalizedQuery: normalizedQuery,
            in: items,
            limit: limit,
            shouldContinue: shouldContinue
        )
        if !strict.isEmpty {
            return strict
        }

        return fuzzyFilter(
            normalizedQuery: normalizedQuery,
            in: items,
            limit: limit,
            shouldContinue: shouldContinue
        )
    }

    static func strictFilter(
        normalizedQuery: String,
        in items: [ClipItem],
        limit: Int = 250,
        shouldContinue: (() -> Bool)? = nil
    ) -> [ClipItem] {
        guard limit > 0 else { return [] }
        guard shouldContinue?() ?? true else { return [] }
        guard !normalizedQuery.isEmpty else { return [] }

        // Primary behavior: strict token containment so results visibly narrow while typing.
        // Keeps recency order from `items`.
        let tokens = strictTokens(normalizedQuery: normalizedQuery)
        guard !tokens.isEmpty else {
            return []
        }
        var strictMatches: [ClipItem] = []
        strictMatches.reserveCapacity(min(limit, items.count))

        for (itemIndex, item) in items.enumerated() {
            if shouldAbort(at: itemIndex, shouldContinue: shouldContinue) {
                return []
            }

            guard strictMatch(
                tokens: tokens,
                in: item.searchableContentUTF8,
                fingerprint: item.searchableFingerprint,
                shouldContinue: shouldContinue
            ) else {
                continue
            }

            strictMatches.append(item)
            if strictMatches.count >= limit {
                break
            }
        }

        return strictMatches
    }

    static func fuzzyFilter(
        normalizedQuery: String,
        in items: [ClipItem],
        limit: Int = 250,
        shouldContinue: (() -> Bool)? = nil
    ) -> [ClipItem] {
        guard limit > 0 else { return [] }
        guard shouldContinue?() ?? true else { return [] }
        guard !normalizedQuery.isEmpty else { return [] }

        // Fallback: fuzzy subsequence matching for typo tolerance when strict search returns nothing.
        let queryUTF8 = ContiguousArray(normalizedQuery.utf8)
        var topMatches: [(item: ClipItem, score: Int)] = []
        topMatches.reserveCapacity(min(items.count, limit))

        for (itemIndex, item) in items.enumerated() {
            if shouldAbort(at: itemIndex, shouldContinue: shouldContinue) {
                return []
            }
            if !item.searchableFingerprint.containsAllBytes(queryUTF8) {
                continue
            }
            if let score = score(
                queryUTF8: queryUTF8,
                in: item.searchableContentUTF8,
                shouldContinue: shouldContinue
            ) {
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

    static func strictMatch(
        normalizedQuery: String,
        in normalizedCandidateUTF8: ContiguousArray<UInt8>,
        fingerprint: SearchFingerprint? = nil,
        shouldContinue: (() -> Bool)? = nil
    ) -> Bool {
        guard shouldContinue?() ?? true else { return false }
        let tokens = strictTokens(normalizedQuery: normalizedQuery)
        guard !tokens.isEmpty else { return false }

        let resolvedFingerprint = fingerprint ?? SearchFingerprint(bytes: normalizedCandidateUTF8)
        return strictMatch(
            tokens: tokens,
            in: normalizedCandidateUTF8,
            fingerprint: resolvedFingerprint,
            shouldContinue: shouldContinue
        )
    }

    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    static func strictQueryTokens(normalizedQuery: String) -> [Substring] {
        normalizedQuery
            .split(whereSeparator: { $0.unicodeScalars.allSatisfy { delimiterSet.contains($0) } })
    }

    private static func strictTokens(normalizedQuery: String) -> [SearchToken] {
        let queryTokens = strictQueryTokens(normalizedQuery: normalizedQuery)
        guard !queryTokens.isEmpty else { return [] }

        var tokens = queryTokens.map { SearchToken(bytes: ContiguousArray($0.utf8)) }
        tokens.sort { $0.count > $1.count }
        return tokens
    }

    private static func strictMatch(
        tokens: [SearchToken],
        in candidateUTF8: ContiguousArray<UInt8>,
        fingerprint: SearchFingerprint,
        shouldContinue: (() -> Bool)?
    ) -> Bool {
        for (tokenIndex, token) in tokens.enumerated() {
            if tokenIndex & 1 == 0, !(shouldContinue?() ?? true) {
                return false
            }
            if !fingerprint.containsAllBytes(token.bytes) {
                return false
            }
            if token.count == 1 {
                continue
            }
            if !containsBytes(candidateUTF8, token, shouldContinue: shouldContinue) {
                return false
            }
        }

        return true
    }

    // MARK: - Byte-level substring containment (Boyer-Moore-Horspool for longer tokens)

    private static func containsBytes(
        _ haystack: ContiguousArray<UInt8>,
        _ token: SearchToken,
        shouldContinue: (() -> Bool)?
    ) -> Bool {
        let needleCount = token.count
        guard needleCount > 0 else { return true }
        guard haystack.count >= needleCount else { return false }
        guard shouldContinue?() ?? true else { return false }

        return haystack.withUnsafeBufferPointer { haystackBuf in
            guard let haystackBase = haystackBuf.baseAddress else {
                return false
            }

            switch needleCount {
            case 1:
                return memchr(
                    haystackBase,
                    Int32(token.firstByte),
                    haystackBuf.count
                ) != nil

            case 2:
                return token.bytes.withUnsafeBufferPointer { needleBuf in
                    guard let needleBase = needleBuf.baseAddress else {
                        return false
                    }
                    return memmem(haystackBase, haystackBuf.count, needleBase, needleCount) != nil
                }

            default:
                return token.bytes.withUnsafeBufferPointer { needleBuf in
                    guard let needleBase = needleBuf.baseAddress else {
                        return false
                    }

                    // libc memmem is heavily optimized on Darwin and outperforms Swift-level loops
                    // for larger haystacks/needles.
                    return memmem(haystackBase, haystackBuf.count, needleBase, needleCount) != nil
                }
            }
        }
    }

    // MARK: - Byte-level fuzzy scoring

    private static func score(
        queryUTF8: ContiguousArray<UInt8>,
        in candidate: ContiguousArray<UInt8>,
        shouldContinue: (() -> Bool)?
    ) -> Int? {
        guard !queryUTF8.isEmpty else {
            return 0
        }
        guard shouldContinue?() ?? true else {
            return nil
        }

        let candidateCount = candidate.count
        guard candidateCount >= queryUTF8.count else {
            return nil
        }

        return candidate.withUnsafeBufferPointer { candidateBuf in
            guard let candidateBase = candidateBuf.baseAddress else { return nil }

            var searchStartIndex = 0
            var lastMatchIndex = -2
            var score = 0
            let queryCount = queryUTF8.count

            for queryIndex in 0..<queryCount {
                if queryIndex & 3 == 0, !(shouldContinue?() ?? true) {
                    return nil
                }

                let remainingCount = candidateCount - searchStartIndex
                guard remainingCount > 0 else { return nil }

                let queryByte = queryUTF8[queryIndex]
                guard let matchPointer = memchr(
                    candidateBase + searchStartIndex,
                    Int32(queryByte),
                    remainingCount
                )?.assumingMemoryBound(to: UInt8.self) else {
                    return nil
                }

                let candidateIndex = candidateBase.distance(to: matchPointer)
                score += 10

                if candidateIndex == lastMatchIndex + 1 {
                    score += 18
                }

                if candidateIndex == 0 || isDelimiterByte(candidate[candidateIndex - 1]) {
                    score += 12
                }

                score += max(0, 18 - candidateIndex)
                lastMatchIndex = candidateIndex
                searchStartIndex = candidateIndex + 1

                if queryIndex == queryCount - 1 {
                    score += max(0, 30 - (candidateCount - candidateIndex))
                    return score
                }
            }

            return nil
        }
    }

    @inline(__always)
    private static func shouldAbort(
        at itemIndex: Int,
        shouldContinue: (() -> Bool)?
    ) -> Bool {
        guard itemIndex & 15 == 0 else { return false }
        return !(shouldContinue?() ?? true)
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
