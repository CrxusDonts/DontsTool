import Combine
import Foundation

@MainActor
public final class AppIndex: ObservableObject {
    @Published public private(set) var apps: [AppEntry] = []
    @Published public private(set) var isScanning = false
    @Published public private(set) var lastError: String?

    private let scanner: AppScanner

    public init(scanner: AppScanner = AppScanner()) {
        self.scanner = scanner
    }

    public func scan() async {
        guard !isScanning else { return }
        isScanning = true
        lastError = nil
        let scanner = self.scanner
        let result = await Task.detached(priority: .utility) {
            scanner.scan()
        }.value

        if !result.entries.isEmpty || result.failedRoots.isEmpty {
            apps = result.entries
        } else {
            lastError = "应用索引扫描失败"
            Log.index.error("所有应用目录均扫描失败，保留旧快照")
        }
        isScanning = false
    }

    func setAppsForTesting(_ apps: [AppEntry]) {
        self.apps = apps
    }
}
