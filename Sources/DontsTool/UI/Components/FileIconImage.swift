import AppKit

/// 应用与文件图标的缓存读取，供 SwiftUI 图标块使用。
@MainActor
enum FileIconImage {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 32, height: 32)
        cache.setObject(image, forKey: key)
        return image
    }
}
