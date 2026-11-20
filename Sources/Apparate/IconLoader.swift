import AppKit
import ApparateCore

enum PanelIconSize: Int, Sendable { case compact = 20, large = 32
    var points: CGFloat { CGFloat(rawValue) }
    var pixels: Int { rawValue * 2 }
}
extension ResultLocation {
    var iconSize: PanelIconSize { self == .below ? .large : .compact }
}

@MainActor final class IconLoader {
    typealias FileRaster = @Sendable (String, Int) async -> Data?
    private let cache = NSCache<NSString, NSImage>()
    private var waiting: [String: [(NSImage?) -> Void]] = [:]
    private(set) var generation = 0
    var pendingFileLoads: Int { waiting.count }
    private let fixtureOnly: Bool
    private let fileRaster: FileRaster
    init(fixtureOnly: Bool = false, fileRaster: FileRaster? = nil) {
        self.fixtureOnly = fixtureOnly; cache.countLimit = 128
        self.fileRaster = fileRaster ?? { path, pixels in
            await Task.detached(priority: .utility) {
                autoreleasepool { Self.rasterize(NSWorkspace.shared.icon(forFile: path), pixels: pixels) }
            }.value
        }
    }
    func resolvedIcon(_ icon: ItemIcon, kind: ItemKind) -> ItemIcon {
        if fixtureOnly, case .file = icon { return .symbol(kind == .folder ? "folder" : "doc") }
        return icon
    }
    func load(_ icon: ItemIcon, kind: ItemKind = .file, size: PanelIconSize = .compact, completion: @escaping (NSImage?) -> Void) {
        switch resolvedIcon(icon, kind: kind) {
        case .symbol(let name):
            let key = "symbol:\(size.rawValue):" + name
            if let image = cache.object(forKey: key as NSString) { completion(image); return }
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            if size == .large { image?.size = NSSize(width: size.points, height: size.points) }
            if let image { cache.setObject(image, forKey: key as NSString) }; completion(image)
        case .file(let path):
            let key = "file:\(size.rawValue):" + path
            if let image = cache.object(forKey: key as NSString) { completion(image); return }
            if waiting[key] != nil { waiting[key]?.append(completion); return }
            waiting[key] = [completion]
            let generation = generation
            Task { [weak self, fileRaster] in
                // Only PNG bytes cross executors. NSImage creation/decoding never shares a mutable image.
                let data = await fileRaster(path, size.pixels)
                guard let self, self.generation == generation else { return }
                let image = data.flatMap(NSImage.init(data:)); image?.size = NSSize(width: size.points, height: size.points)
                if let image { self.cache.setObject(image, forKey: key as NSString) }
                let callbacks = self.waiting.removeValue(forKey: key) ?? []
                for callback in callbacks { callback(image) }
            }
        }
    }
    nonisolated static func rasterize(_ image: NSImage, pixels: Int) -> Data? {
        var rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let raster = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: raster).representation(using: .png, properties: [:])
    }
    func invalidate() { generation += 1; cache.removeAllObjects(); waiting.removeAll() }
}
