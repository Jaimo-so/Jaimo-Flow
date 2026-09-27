import AppKit
import ClipFlowKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ClipboardMonitor {
    enum WriteResult {
        case text(characterCount: Int)
        case image(size: String)
        case failure
    }

    var onCapture: ((CapturedClip) -> Void)?
    var isSourceExcluded: ((String) -> Bool)?

    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int
    private var ignoredChangeCount: Int?

    private struct ImagePayload {
        let data: Data
        let fileExtension: String
        let typeName: String
    }

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func write(_ item: ClipItem) -> WriteResult {
        let didWrite: Bool
        switch item.kind {
        case .image:
            didWrite = item.imagePath.map(writeImage) ?? false
        case .text, .code, .link:
            pasteboard.clearContents()
            didWrite = pasteboard.setString(item.fullText ?? item.title, forType: .string)
        }

        guard didWrite else { return .failure }
        ignoredChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount

        if item.kind == .image {
            let size = item.meta.first(where: { $0.key == "大小" })?.value ?? "图片"
            return .image(size: size)
        }
        return .text(characterCount: (item.fullText ?? item.title).count)
    }

    func write(text: String) -> WriteResult {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return .failure }
        ignoredChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount
        return .text(characterCount: text.count)
    }

    func write(secret: String) -> WriteResult {
        let item = NSPasteboardItem()
        item.setString(secret, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return .failure }
        ignoredChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount
        return .text(characterCount: secret.count)
    }

    private func poll() {
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount

        if ignoredChangeCount == currentChangeCount {
            ignoredChangeCount = nil
            return
        }

        if pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true {
            return
        }

        let application = NSWorkspace.shared.frontmostApplication
        let bundleID = application?.bundleIdentifier ?? "unknown"
        if isSourceExcluded?(bundleID) == true { return }
        let appName = application?.localizedName ?? "未知应用"

        if let imageCapture = captureImage(appName: appName, bundleID: bundleID) {
            onCapture?(imageCapture)
            return
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            onCapture?(captureText(text, appName: appName, bundleID: bundleID))
        }
    }

    private func captureText(_ text: String, appName: String, bundleID: String) -> CapturedClip {
        let classification = ClipClassifier.classify(text: text)
        let meta = classification.kind == .link
            ? ClipClassifier.linkMeta(urlString: text.trimmingCharacters(in: .whitespacesAndNewlines))
            : ClipClassifier.textMeta(text: text, kind: classification.kind)
        return CapturedClip(
            kind: classification.kind,
            category: classification.category,
            sourceAppName: appName,
            sourceBundleID: bundleID,
            title: ClipClassifier.title(for: text),
            fullText: text,
            meta: meta,
            contentHash: ClipClassifier.hash(Data(text.utf8))
        )
    }

    private func captureImage(appName: String, bundleID: String) -> CapturedClip? {
        let payload: ImagePayload
        if let filePayload = imagePayloadFromCopiedFile() {
            payload = filePayload
        } else if let originalPNG = pasteboard.data(forType: .png),
                  let inlinePayload = imagePayload(from: originalPNG, preferredExtension: "png") {
            payload = inlinePayload
        } else if let originalJPEG = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)),
                  let inlinePayload = imagePayload(from: originalJPEG, preferredExtension: "jpg") {
            payload = inlinePayload
        } else if let image = NSImage(pasteboard: pasteboard),
                  let tiff = image.tiffRepresentation,
                  let representation = NSBitmapImageRep(data: tiff),
                  let png = representation.representation(using: .png, properties: [:]) {
            payload = ImagePayload(data: png, fileExtension: "png", typeName: "PNG 图片")
        } else {
            return nil
        }

        guard let dimensions = pixelDimensions(for: payload.data) else { return nil }
        let width = dimensions.width
        let height = dimensions.height
        let dimension = "\(width) × \(height)"
        let byteCount = ClipClassifier.formattedByteCount(payload.data.count)
        let title = "来自 \(appName) 的图片 · \(dimension)"

        return CapturedClip(
            kind: .image,
            category: .image,
            sourceAppName: appName,
            sourceBundleID: bundleID,
            title: title,
            imageData: payload.data,
            imageFileExtension: payload.fileExtension,
            imageAlt: "从 \(appName) 复制的图片，尺寸 \(dimension)",
            meta: [
                MetaEntry("类型", payload.typeName),
                MetaEntry("尺寸", dimension),
                MetaEntry("大小", byteCount)
            ],
            contentHash: ClipClassifier.hash(payload.data)
        )
    }

    private func imagePayloadFromCopiedFile() -> ImagePayload? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let copiedURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        )?.compactMap { object -> URL? in
            if let url = object as? URL { return url }
            return (object as? NSURL)?.absoluteURL
        } ?? []

        for url in copiedURLs where url.isFileURL {
            if let payload = imagePayload(at: url) { return payload }
        }

        if let rawURL = pasteboard.string(forType: .fileURL),
           let url = URL(string: rawURL),
           url.isFileURL,
           let payload = imagePayload(at: url) {
            return payload
        }

        let legacyFilenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: legacyFilenames) as? [String] {
            for path in paths {
                if let payload = imagePayload(at: URL(fileURLWithPath: path)) { return payload }
            }
        }

        return nil
    }

    private func imagePayload(at url: URL) -> ImagePayload? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        return imagePayload(from: data, preferredExtension: url.pathExtension)
    }

    private func imagePayload(from data: Data, preferredExtension: String? = nil) -> ImagePayload? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              let imageType = UTType(typeIdentifier),
              imageType.conforms(to: .image) else {
            return nil
        }

        let fileExtension: String
        let formatName: String
        if imageType.conforms(to: .jpeg) {
            fileExtension = "jpg"
            formatName = "JPEG"
        } else if imageType.conforms(to: .png) {
            fileExtension = "png"
            formatName = "PNG"
        } else if imageType.conforms(to: .gif) {
            fileExtension = "gif"
            formatName = "GIF"
        } else if imageType.conforms(to: .tiff) {
            fileExtension = "tiff"
            formatName = "TIFF"
        } else {
            let normalizedExtension = preferredExtension?
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            fileExtension = imageType.preferredFilenameExtension ?? normalizedExtension ?? "image"
            formatName = fileExtension.uppercased()
        }

        return ImagePayload(
            data: data,
            fileExtension: fileExtension,
            typeName: "\(formatName) 图片"
        )
    }

    private func pixelDimensions(for data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        return (width.intValue, height.intValue)
    }

    private func writeImage(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeIdentifier = CGImageSourceGetType(source) as String? else {
            return false
        }

        pasteboard.clearContents()
        let originalType = NSPasteboard.PasteboardType(typeIdentifier)
        let wroteOriginal = pasteboard.setData(data, forType: originalType)

        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation else {
            return wroteOriginal
        }
        let wroteCompatibilityImage = pasteboard.setData(tiff, forType: .tiff)
        return wroteOriginal || wroteCompatibilityImage
    }
}
