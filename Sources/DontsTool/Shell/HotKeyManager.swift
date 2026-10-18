import Carbon
import DontsToolCore
import Foundation

@MainActor
final class HotKeyManager {
    enum HotKeyError: LocalizedError {
        case installHandlerFailed(OSStatus)
        case registerFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .installHandlerFailed(let status): "无法安装热键处理器（\(status)）"
            case .registerFailed(let status): "热键注册失败（\(status)），可能已被其他应用占用"
            }
        }
    }

    var onHotKey: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handlerInstalled = false

    // HotKeyManager 与 App 同生命周期；不实现 deinit，避免在非隔离析构中访问 Carbon 句柄。

    func register(_ configuration: SettingsStore.HotKeyConfiguration) throws {
        unregister()

        if !handlerInstalled {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, userData in
                    guard let event, let userData else { return noErr }
                    var identifier = EventHotKeyID()
                    let result = GetEventParameter(
                        event,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &identifier
                    )
                    guard result == noErr else { return result }
                    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                    Task { @MainActor in
                        manager.onHotKey?()
                    }
                    return noErr
                },
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandlerRef
            )
            guard status == noErr else {
                throw HotKeyError.installHandlerFailed(status)
            }
            handlerInstalled = true
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4454_4F4C), id: 1)
        let status = RegisterEventHotKey(
            configuration.keyCode,
            configuration.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            hotKeyRef = nil
            throw HotKeyError.registerFailed(status)
        }
    }

    /// 录制新快捷键期间临时注销，避免旧组合被 Carbon 拦截而无法输入。
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}
