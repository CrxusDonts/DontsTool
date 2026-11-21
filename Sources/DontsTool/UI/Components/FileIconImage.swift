import AppKit

/// 应用、文件与插件图标的缓存读取，供 SwiftUI 图标块使用。
@MainActor
enum FileIconImage {
    private static let cache = NSCache<NSString, NSImage>()
    private static let pluginCache = NSCache<NSString, NSImage>()

    static func image(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 32, height: 32)
        cache.setObject(image, forKey: key)
        return image
    }

    static func pluginImage(for path: String) -> NSImage? {
        let key = path as NSString
        if let cached = pluginCache.object(forKey: key) { return cached }
        guard FileManager.default.fileExists(atPath: path),
              let image = NSImage(contentsOfFile: path) else {
            return nil
        }
        image.size = NSSize(width: 32, height: 32)
        pluginCache.setObject(image, forKey: key)
        return image
    }
}
