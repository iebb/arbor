import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Generates Quick Look thumbnails for the larger icon views (photos, videos, PDFs).
final class ThumbnailProvider {
    static let shared = ThumbnailProvider()
    private let cache = NSCache<NSString, NSImage>()

    static func wantsThumbnail(_ item: FileItem) -> Bool {
        guard !item.isFolder, let type = item.contentType else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .pdf)
    }

    private func key(_ url: URL, _ size: CGFloat) -> NSString { "\(url.pathKey)#\(Int(size))" as NSString }

    func cachedThumbnail(for url: URL, size: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, size))
    }

    func requestThumbnail(for url: URL, size: CGFloat, scale: CGFloat, completion: @escaping (NSImage) -> Void) {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: scale,
            representationTypes: .thumbnail
        )
        let cacheKey = key(url, size)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async {
                self?.cache.setObject(image, forKey: cacheKey)
                completion(image)
            }
        }
    }
}
