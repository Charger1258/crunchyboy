import UIKit
import ImageIO

actor ArtworkLoader {
    static let shared = ArtworkLoader()
    private let cache = NSCache<NSURL, UIImage>()
    private let http = HTTPClient(timeout: 8)
    init() { cache.totalCostLimit = 32 * 1024 * 1024; cache.countLimit = 48 }
    func image(_ url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        do {
            let (data, _) = try await http.bytes(url, limit: 8_000_000)
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 1000, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
            let image = UIImage(cgImage: cg)
            cache.setObject(image, forKey: url as NSURL, cost: cg.bytesPerRow * cg.height)
            return image
        } catch { return nil }
    }
}
