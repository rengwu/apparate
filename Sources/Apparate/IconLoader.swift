import AppKit
import ApparateCore

@MainActor final class IconLoader {
    private let cache = NSCache<NSString, NSImage>()
    private var waiting: [String: [(NSImage?) -> Void]] = [:]
    private(set) var generation = 0
    private let fixtureOnly: Bool
    init(fixtureOnly: Bool = false) { self.fixtureOnly = fixtureOnly; cache.countLimit = 128 }
    func load(_ icon: ItemIcon, completion: @escaping (NSImage?) -> Void) {
        switch icon {
        case .symbol(let name):
            let key = "symbol:" + name
            if let image = cache.object(forKey: key as NSString) { completion(image); return }
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            if let image { cache.setObject(image, forKey: key as NSString) }; completion(image)
        case .file(let path):
            if fixtureOnly { load(.symbol("doc"), completion: completion); return }
            if let image = cache.object(forKey: path as NSString) { completion(image); return }
            if waiting[path] != nil { waiting[path]?.append(completion); return }
            waiting[path] = [completion]
            let generation = generation
            Task { [weak self] in
                // Only PNG bytes cross executors. NSImage creation/decoding never shares a mutable image.
                let data = await Task.detached(priority: .utility) {
                    autoreleasepool { () -> Data? in
                        let image = NSWorkspace.shared.icon(forFile: path)
                        var rect = NSRect(x: 0, y: 0, width: 40, height: 40)
                        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
                              let context = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 160,
                                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                        context.draw(source, in: CGRect(x: 0, y: 0, width: 40, height: 40))
                        guard let raster = context.makeImage() else { return nil }
                        return NSBitmapImageRep(cgImage: raster).representation(using: .png, properties: [:])
                    }
                }.value
                guard let self, self.generation == generation else { return }
                let image = data.flatMap(NSImage.init(data:)); image?.size = NSSize(width: 20, height: 20)
                if let image { self.cache.setObject(image, forKey: path as NSString) }
                let callbacks = self.waiting.removeValue(forKey: path) ?? []
                for callback in callbacks { callback(image) }
            }
        }
    }
    func invalidate() { generation += 1; cache.removeAllObjects(); waiting.removeAll() }
}
