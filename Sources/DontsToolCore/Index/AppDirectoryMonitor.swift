import CoreServices
import Foundation

/// Watches bundle contents as well as directory entries, so a staged install
/// can be indexed when Info.plist arrives after the .app directory.
final class AppDirectoryMonitor {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.donts.DontsTool.app-directories", qos: .utility)

    init?(roots: [URL], onChange: @escaping @Sendable () -> Void) {
        let roots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        guard !roots.isEmpty else { return nil }
        let callback = Callback(roots: roots.map(\.path), onChange: onChange)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Callback>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                if let pointer { Unmanaged<Callback>.fromOpaque(pointer).release() }
            }, copyDescription: nil
        )
        // Also detect creation of a previously missing ~/Applications directory.
        let paths = Array(Set(roots.map { root -> String in
            var path = root
            while !FileManager.default.fileExists(atPath: path.path), path.path != "/" {
                path.deleteLastPathComponent()
            }
            return path.path
        }))
        let options = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
            let changedPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let needsRescan = (0..<count).contains { index in
                flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagRootChanged) != 0
            }
            if needsRescan || changedPaths.contains(where: callback.includes) { callback.onChange() }
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, options) else {
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private final class Callback: Sendable {
        let roots: [String]
        let onChange: @Sendable () -> Void

        init(roots: [String], onChange: @escaping @Sendable () -> Void) {
            self.roots = roots
            self.onChange = onChange
        }

        func includes(_ path: String) -> Bool {
            roots.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }
}
