import Foundation

public struct AppEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let bundleID: String?
    public let url: URL
    public let modifiedAt: Date?

    public init(id: String, displayName: String, bundleID: String?, url: URL, modifiedAt: Date?) {
        self.id = id
        self.displayName = displayName
        self.bundleID = bundleID
        self.url = url
        self.modifiedAt = modifiedAt
    }
}

public struct AppScanResult: Sendable {
    public let entries: [AppEntry]
    public let failedRoots: [URL]

    public init(entries: [AppEntry], failedRoots: [URL]) {
        self.entries = entries
        self.failedRoots = failedRoots
    }
}

public struct AppScanner: Sendable {
    public let roots: [URL]
    public let preferredLanguages: [String]

    public init(roots: [URL] = AppScanner.defaultRoots, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.roots = roots
        self.preferredLanguages = preferredLanguages
    }

    public static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true)
        ]
    }

    public func scan() -> AppScanResult {
        var entriesByPath: [String: AppEntry] = [:]
        var failedRoots: [URL] = []

        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            do {
                let children = try FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
                for child in children {
                    if child.pathExtension.lowercased() == "app" {
                        if let entry = makeEntry(at: child) {
                            entriesByPath[entry.id] = entry
                        }
                    } else if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        let grandchildren = try FileManager.default.contentsOfDirectory(
                            at: child,
                            includingPropertiesForKeys: [.contentModificationDateKey],
                            options: [.skipsHiddenFiles]
                        )
                        for grandchild in grandchildren where grandchild.pathExtension.lowercased() == "app" {
                            if let entry = makeEntry(at: grandchild) {
                                entriesByPath[entry.id] = entry
                            }
                        }
                    }
                }
            } catch {
                Log.index.error("扫描应用目录失败: \(root.path, privacy: .public), \(error.localizedDescription, privacy: .public)")
                failedRoots.append(root)
            }
        }

        let entries = entriesByPath.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        return AppScanResult(entries: entries, failedRoots: failedRoots)
    }

    private func makeEntry(at url: URL) -> AppEntry? {
        // Bundle.infoDictionary is cached by path for the lifetime of the
        // process, including incomplete bundles encountered during installation.
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
            return nil
        }

        if isTrue(info["LSBackgroundOnly"]) {
            return nil
        }

        let displayName = localizedName(at: url)
            ?? applicationName(in: info)
            ?? url.deletingPathExtension().lastPathComponent
        let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let standardized = url.standardizedFileURL

        return AppEntry(
            id: standardized.path,
            displayName: displayName,
            bundleID: info["CFBundleIdentifier"] as? String,
            url: standardized,
            modifiedAt: modifiedAt
        )
    }

    private func localizedName(at app: URL) -> String? {
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: resources,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let localizations = children.filter {
            $0.pathExtension == "lproj" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let byLanguage = Dictionary(uniqueKeysWithValues: localizations.map {
            ($0.deletingPathExtension().lastPathComponent, $0)
        })
        // Some system applications store their localized names in a shared binary table.
        var table: [String: Any] = [:]
        if let data = try? Data(contentsOf: resources.appendingPathComponent("InfoPlist.loctable")),
           let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            table = info
        }
        let tableLanguages: [String] = table.compactMap { language, value in
            guard let info = value as? [String: Any], applicationName(in: info) != nil else { return nil }
            return language
        }
        let preferred = Bundle.preferredLocalizations(
            from: Set(byLanguage.keys).union(tableLanguages).sorted(),
            forPreferences: preferredLanguages
        )
        for language in preferred {
            if let directory = byLanguage[language],
               let data = try? Data(contentsOf: directory.appendingPathComponent("InfoPlist.strings")),
               let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
               let name = applicationName(in: info) {
                return name
            }
            if let info = table[language] as? [String: Any], let name = applicationName(in: info) {
                return name
            }
        }
        return nil
    }

    private func applicationName(in info: [String: Any]) -> String? {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = info[key] as? String {
                let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { return name }
            }
        }
        return nil
    }

    private func isTrue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let string = value as? String {
            return string == "1" || string.lowercased() == "true"
        }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }
}
