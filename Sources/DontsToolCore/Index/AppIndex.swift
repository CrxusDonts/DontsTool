import Combine
import Foundation

@MainActor
public final class AppIndex: ObservableObject {
    @Published public private(set) var apps: [AppEntry] = []
    @Published public private(set) var isScanning = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var isMonitoring = false

    private let scanner: AppScanner
    private var monitor: AppDirectoryMonitor?
    private var refreshTask: Task<Void, Never>?
    private var rescanRequested = false
    private var monitoringGeneration = 0

    public init(scanner: AppScanner = AppScanner()) {
        self.scanner = scanner
    }

    public func scan() async {
        startMonitoring()
        guard !isScanning else { rescanRequested = true; return }
        isScanning = true
        lastError = nil
        let scanner = self.scanner
        repeat {
            rescanRequested = false
            let result = await Task.detached(priority: .utility) {
                scanner.scan()
            }.value

            if !result.entries.isEmpty || result.failedRoots.isEmpty {
                apps = result.entries
            } else {
                lastError = "应用索引扫描失败"
                Log.index.error("所有应用目录均扫描失败，保留旧快照")
            }
        } while rescanRequested
        isScanning = false
    }

    public func stopMonitoring() {
        monitoringGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        monitor = nil
        isMonitoring = false
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        let generation = monitoringGeneration
        monitor = AppDirectoryMonitor(roots: scanner.roots) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.monitoringGeneration, self.monitor != nil else { return }
                self.scheduleRefresh()
            }
        }
        isMonitoring = monitor != nil
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.scan()
        }
    }

    func setAppsForTesting(_ apps: [AppEntry]) {
        self.apps = apps
    }
}
