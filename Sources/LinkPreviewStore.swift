import AppKit
import Foundation
import LinkPresentation

struct LinkPreviewData {
    let title: String?
    let image: NSImage?
}

private final class CachedLinkPreviewData: NSObject {
    let value: LinkPreviewData

    init(_ value: LinkPreviewData) {
        self.value = value
    }
}

@MainActor
final class LinkPreviewStore: ObservableObject {
    private let cachedData: NSCache<NSURL, CachedLinkPreviewData> = {
        let cache = NSCache<NSURL, CachedLinkPreviewData>()
        cache.countLimit = 320
        return cache
    }()
    private var inFlightURLs: Set<URL> = []
    private var activeProviders: [URL: LPMetadataProvider] = [:]
    private let metadataTimeout: TimeInterval = 5
    private var changeObservers: [UUID: (URL) -> Void] = [:]

    func preview(for url: URL) -> LinkPreviewData? {
        cachedData.object(forKey: url as NSURL)?.value
    }

    func loadPreview(for url: URL) {
        guard cachedData.object(forKey: url as NSURL) == nil else { return }
        guard !inFlightURLs.contains(url) else { return }

        inFlightURLs.insert(url)

        let provider = LPMetadataProvider()
        provider.timeout = metadataTimeout
        activeProviders[url] = provider
        provider.startFetchingMetadata(for: url) { [weak self] metadata, _ in
            guard let self else { return }

            guard let metadata else {
                Task { @MainActor [weak self] in
                    self?.complete(url: url, title: nil, image: nil)
                }
                return
            }

            Self.resolveImage(from: metadata) { image in
                let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { @MainActor [weak self] in
                    self?.complete(url: url, title: title, image: image)
                }
            }
        }
    }

    @discardableResult
    func addChangeObserver(_ observer: @escaping (URL) -> Void) -> UUID {
        let token = UUID()
        changeObservers[token] = observer
        return token
    }

    func removeChangeObserver(_ token: UUID) {
        changeObservers[token] = nil
    }

    private func complete(url: URL, title: String?, image: NSImage?) {
        let normalizedTitle = title.flatMap { $0.isEmpty ? nil : $0 }
        cachedData.setObject(
            CachedLinkPreviewData(LinkPreviewData(title: normalizedTitle, image: image)),
            forKey: url as NSURL
        )
        inFlightURLs.remove(url)
        activeProviders[url] = nil
        for observer in changeObservers.values {
            observer(url)
        }
    }

    nonisolated private static func resolveImage(from metadata: LPLinkMetadata, completion: @escaping (NSImage?) -> Void) {
        if let imageProvider = metadata.imageProvider {
            resolveImage(using: imageProvider, completion: completion)
            return
        }

        if let iconProvider = metadata.iconProvider {
            resolveImage(using: iconProvider, completion: completion)
            return
        }

        completion(nil)
    }

    nonisolated private static func resolveImage(using provider: NSItemProvider, completion: @escaping (NSImage?) -> Void) {
        guard provider.canLoadObject(ofClass: NSImage.self) else {
            completion(nil)
            return
        }

        provider.loadObject(ofClass: NSImage.self) { object, _ in
            completion(object as? NSImage)
        }
    }
}
