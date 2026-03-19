import Foundation

enum ClipboardContentLimits {
    static let maxStoredTextUTF8Bytes = 1_024 * 1_024
    static let maxSnippetPreviewUTF8Bytes = 4 * 1_024
    static let maxRenderedSnippetUTF8Bytes = 768
    static let maxRenderedSnippetCharacters = 512
    static let maxRenderedRichPreviewCharacters = 2_048
    static let maxSearchableTextUTF8Bytes = 8 * 1_024
    static let maxExtendedSearchUTF8Bytes = 128 * 1_024
    static let maxRichPayloadBytes = 256 * 1_024
    static let maxImagePayloadBytes = 12 * 1_024 * 1_024
    static let maxRichPreviewPayloadBytes = 128 * 1_024
    static let maxJSONPreviewUTF8Bytes = 64 * 1_024
    static let maxDedupeSeedUTF8Bytes = 12 * 1_024

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    static func byteCountLabel(_ byteCount: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(max(0, byteCount)))
    }

    static func cappedText(_ value: String) -> String {
        let originalBytes = value.utf8.count
        guard originalBytes > maxStoredTextUTF8Bytes else { return value }

        let notice = "\n\n[PasteBin truncated this item (\(byteCountLabel(originalBytes)) > \(byteCountLabel(maxStoredTextUTF8Bytes))) to keep history responsive.]"
        let availableBytes = max(0, maxStoredTextUTF8Bytes - notice.utf8.count)
        let prefix = truncateUTF8PreservingScalarBoundaries(value, to: availableBytes)
        return prefix + notice
    }

    static func truncateUTF8PreservingScalarBoundaries(_ value: String, to maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard value.utf8.count > maxBytes else { return value }

        var consumed = 0
        var end = value.startIndex
        while end < value.endIndex {
            let next = value.index(after: end)
            let nextBytes = value[end..<next].utf8.count
            if consumed + nextBytes > maxBytes {
                break
            }
            consumed += nextBytes
            end = next
        }
        return String(value[..<end])
    }

    static func searchProjection(_ value: String, to maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        let byteCount = value.utf8.count
        guard byteCount > maxBytes else { return value }

        let separator = "\n...\n"
        let separatorBytes = separator.utf8.count
        let availableBytes = max(0, maxBytes - separatorBytes)
        guard availableBytes > 0 else {
            return truncateUTF8PreservingScalarBoundaries(value, to: maxBytes)
        }

        let overflowBytes = byteCount - maxBytes
        let maxSuffixBytes = max(0, availableBytes / 4)
        let suffixBytes = min(maxSuffixBytes, overflowBytes)
        let prefixBytes = max(1, availableBytes - suffixBytes)
        let prefix = truncateUTF8PreservingScalarBoundaries(value, to: prefixBytes)
        guard suffixBytes > 0 else { return prefix }

        let suffix = suffixUTF8PreservingScalarBoundaries(value, to: suffixBytes)
        guard !suffix.isEmpty else { return prefix }
        return prefix + separator + suffix
    }

    static func dedupeSeed(forText value: String) -> Data {
        let byteCount = value.utf8.count
        if byteCount <= maxDedupeSeedUTF8Bytes {
            return Data(value.utf8)
        }

        let half = max(1, maxDedupeSeedUTF8Bytes / 2)
        let prefix = truncateUTF8PreservingScalarBoundaries(value, to: half)
        let suffix = suffixUTF8PreservingScalarBoundaries(value, to: half)
        var seed = Data(prefix.utf8)
        seed.append(contentsOf: Data("|...|".utf8))
        seed.append(contentsOf: Data(suffix.utf8))
        seed.append(contentsOf: Data("|bytes:\(byteCount)".utf8))
        return seed
    }

    private static func suffixUTF8PreservingScalarBoundaries(_ value: String, to maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard value.utf8.count > maxBytes else { return value }

        var consumed = 0
        var start = value.endIndex
        while start > value.startIndex {
            let previous = value.index(before: start)
            let nextBytes = value[previous..<start].utf8.count
            if consumed + nextBytes > maxBytes {
                break
            }
            consumed += nextBytes
            start = previous
        }
        return String(value[start...])
    }
}
