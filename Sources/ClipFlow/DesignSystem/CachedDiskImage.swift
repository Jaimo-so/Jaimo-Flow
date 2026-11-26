import AppKit
import ImageIO
import SwiftUI

private final class DiskImageCache {
    static let shared = DiskImageCache()

    private let cache = NSCache<NSString, NSImage>()
    private let decodeQueue = DispatchQueue(
        label: "com.clipflow.image-decoding",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private init() {
        cache.totalCostLimit = 64 * 1_024 * 1_024
        cache.countLimit = 160
    }

    func load(
        url: URL,
        maxPixelSize: Int,
        completion: @escaping (NSImage?) -> Void
    ) {
        let key = "\(url.path)#\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }

        decodeQueue.async { [cache] in
            let options: [CFString: Any] = [
                kCGImageSourceShouldCache: false
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                thumbnailOptions as CFDictionary
            ) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
            let cost = cgImage.bytesPerRow * cgImage.height
            cache.setObject(image, forKey: key, cost: cost)
            DispatchQueue.main.async { completion(image) }
        }
    }
}

struct CachedDiskImage: View {
    let url: URL
    let maxPixelSize: Int
    let contentMode: ContentMode

    @State private var image: NSImage?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(theme.chip)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        DiskImageCache.shared.load(url: url, maxPixelSize: maxPixelSize) { loaded in
            image = loaded
        }
    }
}
