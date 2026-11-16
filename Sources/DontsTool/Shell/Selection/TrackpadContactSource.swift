import AppKit
import Darwin
import DontsToolCore
import IOKit
import os

// Path callbacks give one contact at a time: no dependency on the undocumented frame-array stride.
private enum TrackpadCallbacks {
    typealias PathCallback = @convention(c) (UnsafeMutableRawPointer?, Int, Int, UnsafeRawPointer?) -> Void
    typealias FrameCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32, Double, Int32) -> Int32
    struct Sink: Sendable {
        var contacts: [Int: TrackpadHoldGesture.Contact] = [:]
        let deliver: @Sendable (UInt, [TrackpadHoldGesture.Contact], TimeInterval) -> Void
    }
    static let sinks = OSAllocatedUnfairLock(initialState: [UInt: Sink]())
    static let path: PathCallback = { device, id, stage, touch in
        guard let device else { return }
        let key = UInt(bitPattern: device)
        let contact: TrackpadHoldGesture.Contact?
        if (stage == 3 || stage == 4), let touch {
            let x = touch.loadUnaligned(fromByteOffset: 32, as: Float.self)
            let y = touch.loadUnaligned(fromByteOffset: 36, as: Float.self)
            contact = .init(id: id, x: Double(x), y: Double(y))
        } else { contact = nil }
        sinks.withLock { sinks in
            guard sinks[key] != nil else { return }
            sinks[key]?.contacts[id] = contact
        }
    }
    static let frame: FrameCallback = { device, _, count, _, _ in
        guard let device else { return 0 }
        let key = UInt(bitPattern: device)
        let snapshot = sinks.withLock { sinks -> (Sink, [TrackpadHoldGesture.Contact])? in
            guard var sink = sinks[key] else { return nil }
            if count == 0 { sink.contacts.removeAll(); sinks[key] = sink }
            return (sink, Array(sink.contacts.values))
        }
        if let (sink, contacts) = snapshot {
            sink.deliver(key, contacts, ProcessInfo.processInfo.systemUptime)
        }
        return 0
    }
}

@MainActor
final class TrackpadContactSource {
    typealias Handler = (UInt, TrackpadHoldGesture.Action) -> Void
    private struct API {
        let library: UnsafeMutableRawPointer
        let create: @convention(c) () -> Unmanaged<CFArray>?
        let dimensions: @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
        let family: @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32
        let registerPath: @convention(c) (UnsafeMutableRawPointer, TrackpadCallbacks.PathCallback) -> Bool
        let unregisterPath: @convention(c) (UnsafeMutableRawPointer, TrackpadCallbacks.PathCallback) -> Bool
        let registerFrame: @convention(c) (UnsafeMutableRawPointer, TrackpadCallbacks.FrameCallback) -> Bool
        let unregisterFrame: @convention(c) (UnsafeMutableRawPointer, TrackpadCallbacks.FrameCallback) -> Bool
        let start: @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
        let stop: @convention(c) (UnsafeMutableRawPointer) -> Int32

        init?() {
            guard let library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW | RTLD_LOCAL) else { return nil }
            func symbol<T>(_ name: String, _: T.Type) -> T? {
                dlsym(library, name).map { unsafeBitCast($0, to: T.self) }
            }
            guard let create = symbol("MTDeviceCreateList", (@convention(c) () -> Unmanaged<CFArray>?).self),
                  let dimensions = symbol("MTDeviceGetSensorDimensions", (@convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32).self),
                  let family = symbol("MTDeviceGetFamilyID", (@convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32).self),
                  let registerPath = symbol("MTRegisterPathCallback", (@convention(c) (UnsafeMutableRawPointer, TrackpadCallbacks.PathCallback) -> Bool).self),
                  let unregisterPath = symbol("MTUnregisterPathCallback", (@convention(c) (UnsafeMutableRawPointer, TrackpadCallbacks.PathCallback) -> Bool).self),
                  let registerFrame = symbol("MTRegisterContactFrameCallback", (@convention(c) (UnsafeMutableRawPointer, TrackpadCallbacks.FrameCallback) -> Bool).self),
                  let unregisterFrame = symbol("MTUnregisterContactFrameCallback", (@convention(c) (UnsafeMutableRawPointer, TrackpadCallbacks.FrameCallback) -> Bool).self),
                  let start = symbol("MTDeviceStart", (@convention(c) (UnsafeMutableRawPointer, Int32) -> Int32).self),
                  let stop = symbol("MTDeviceStop", (@convention(c) (UnsafeMutableRawPointer) -> Int32).self) else { dlclose(library); return nil }
            self.library = library; self.create = create; self.dimensions = dimensions; self.family = family
            self.registerPath = registerPath; self.unregisterPath = unregisterPath
            self.registerFrame = registerFrame; self.unregisterFrame = unregisterFrame
            self.start = start; self.stop = stop
        }
    }
    private static let sharedAPI = API()
    private var api: API? { Self.sharedAPI }
    private var devices: [UnsafeMutableRawPointer] = []
    private var deviceList: CFArray?
    var holdDuration: TimeInterval = 2
    private var gestures: [UInt: TrackpadHoldGesture] = [:]
    private var generation = UUID()
    private var handler: Handler?
    private var observers: [NSObjectProtocol] = []
    private var notificationPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var reloadTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.donts.DontsTool", category: "selection-translation")
    var onReset: (() -> Void)?
    var deviceCount: Int { devices.count }

    func start(_ handler: @escaping Handler) {
        guard self.handler == nil else { return }
        self.handler = handler
        reloadDevices()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseDevices(); self?.onReset?() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        })
        if let port = IONotificationPortCreate(kIOMainPortDefault) {
            notificationPort = port
            IONotificationPortSetDispatchQueue(port, .main)
            for name in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                let result = IOServiceAddMatchingNotification(port, name, IOServiceMatching("AppleMultitouchDevice"), { context, iterator in
                    while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
                    guard let context else { return }
                    MainActor.assumeIsolated {
                        Unmanaged<TrackpadContactSource>.fromOpaque(context).takeUnretainedValue().scheduleReload()
                    }
                }, Unmanaged.passUnretained(self).toOpaque(), &iterator)
                if result == KERN_SUCCESS {
                    iterators.append(iterator)
                    while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
                }
            }
        }
    }

    func cancel() { for key in gestures.keys { gestures[key]?.cancel() } }

    func stop() {
        reloadTask?.cancel(); reloadTask = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        for iterator in iterators { IOObjectRelease(iterator) }; iterators.removeAll()
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
        notificationPort = nil
        releaseDevices(); handler = nil
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.reloadDevices()
        }
    }

    private func reloadDevices() {
        releaseDevices(); onReset?()
        guard handler != nil, let api, let list = api.create()?.takeRetainedValue() else { return }
        deviceList = list
        let generation = generation
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            var rows: Int32 = 0, columns: Int32 = 0, family: Int32 = 0
            guard api.dimensions(device, &rows, &columns) == 0, rows >= 10, columns >= 10,
                  api.family(device, &family) == 0, family != 112, family != 113 else { continue }
            let key = UInt(bitPattern: device)
            TrackpadCallbacks.sinks.withLock { sinks in
                sinks[key] = .init(deliver: { [weak self] device, contacts, receivedAt in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == generation, self.handler != nil else { return }
                        let point = CGEvent(source: nil)?.location ?? .zero
                        if ProcessInfo.processInfo.systemUptime - receivedAt > 0.3 { self.cancel(); return }
                        let action = self.gestures[device, default: TrackpadHoldGesture(holdDuration: self.holdDuration)].update(contacts, at: receivedAt, cursor: point)
                        if action != .none { self.handler?(device, action) }
                    }
                })
            }
            let pathOK = api.registerPath(device, TrackpadCallbacks.path)
            let frameOK = api.registerFrame(device, TrackpadCallbacks.frame)
            if pathOK, frameOK, api.start(device, 0) == 0 { devices.append(device) }
            else {
                _ = api.unregisterPath(device, TrackpadCallbacks.path)
                _ = api.unregisterFrame(device, TrackpadCallbacks.frame)
                TrackpadCallbacks.sinks.withLock { $0[key] = nil }
            }
        }
        logger.notice("双指触点监听已启动，触控板数量：\(self.devices.count, privacy: .public)")
    }

    private func releaseDevices() {
        generation = UUID(); gestures.removeAll()
        if let api {
            for device in devices {
                let key = UInt(bitPattern: device)
                TrackpadCallbacks.sinks.withLock { $0[key] = nil }
                _ = api.unregisterPath(device, TrackpadCallbacks.path)
                _ = api.unregisterFrame(device, TrackpadCallbacks.frame)
                _ = api.stop(device)
            }
        }
        devices.removeAll(); deviceList = nil
    }
}
