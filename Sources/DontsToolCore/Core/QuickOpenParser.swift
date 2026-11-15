import Foundation

public enum QuickOpenTarget: Equatable, Sendable {
    case url(URL)
    case file(URL)
}

public enum QuickOpenParser {
    public static func parse(
        _ raw: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> QuickOpenTarget? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()

        if lowered.hasPrefix("file://") {
            guard let url = URL(string: trimmed), url.isFileURL else { return nil }
            let fileURL = url.standardizedFileURL
            return fileExists(fileURL.path) ? .file(fileURL) : nil
        }

        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return webURL(trimmed)
        }

        if lowered.hasPrefix("www.") {
            return webURL("https://" + trimmed)
        }

        if trimmed.hasPrefix("~") || trimmed.hasPrefix("/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            guard fileExists(expanded) else { return nil }
            return .file(URL(fileURLWithPath: expanded).standardizedFileURL)
        }

        return nil
    }

    private static func webURL(_ string: String) -> QuickOpenTarget? {
        guard let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              let url = components.url else { return nil }
        return .url(url)
    }
}
