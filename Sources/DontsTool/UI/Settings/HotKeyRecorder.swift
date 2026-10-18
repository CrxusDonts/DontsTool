import AppKit
import DontsToolCore
import SwiftUI

/// 热键录制按钮：按下组合键，或双击 ⌘/⌥/⌃/⇧ 即保存。
struct HotKeyRecorder: View {
    let display: String
    let onRecord: (SettingsStore.HotKeyConfiguration) -> Void
    let onRecordingChanged: (Bool) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggleRecording) {
            Text(isRecording ? "按下组合键或双击修饰键…" : display)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(isRecording ? Theme.onAccent : Theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    isRecording ? Theme.accent : Theme.accentFill,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isRecording ? Theme.accent : Theme.accentBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("点击后按下新的组合键，或双击 ⌘/⌥/⌃/⇧；Esc 取消")
        .accessibilityLabel(isRecording ? "正在录制呼出快捷键，按 Esc 取消" : "呼出快捷键 \(display)")
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
            return
        }
        isRecording = true
        onRecordingChanged(true)
        let doubleTapRecording = DoubleTapRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                let active = Self.modifiers(from: event.modifierFlags)
                if let modifier = doubleTapRecording.update(
                    activeModifiers: active,
                    at: ProcessInfo.processInfo.systemUptime
                ) {
                    onRecord(.doubleTap(modifier))
                    stopRecording()
                }
                return event
            }

            if event.keyCode == 53 { // Esc 取消
                stopRecording()
                return nil
            }
            doubleTapRecording.keyDown()

            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            // 裸键或仅 Shift 会劫持正常输入，全局热键必须带 ⌘/⌥/⌃。
            guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
                return nil
            }
            onRecord(SettingsStore.HotKeyConfiguration(
                keyCode: UInt32(event.keyCode),
                modifiers: SettingsStore.HotKeyConfiguration.carbonModifiers(
                    command: flags.contains(.command),
                    shift: flags.contains(.shift),
                    option: flags.contains(.option),
                    control: flags.contains(.control)
                )
            ))
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        let wasRecording = isRecording
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
        if wasRecording {
            onRecordingChanged(false)
        }
    }

    private static func modifiers(
        from flags: NSEvent.ModifierFlags
    ) -> Set<SettingsStore.HotKeyConfiguration.Modifier> {
        var active: Set<SettingsStore.HotKeyConfiguration.Modifier> = []
        if flags.contains(.command) { active.insert(.command) }
        if flags.contains(.shift) { active.insert(.shift) }
        if flags.contains(.option) { active.insert(.option) }
        if flags.contains(.control) { active.insert(.control) }
        return active
    }
}

/// 录制时同时识别四种修饰键的双击。
private final class DoubleTapRecording {
    private var detectors: [SettingsStore.HotKeyConfiguration.Modifier: ModifierDoubleTapDetector]

    init() {
        detectors = Dictionary(
            uniqueKeysWithValues: SettingsStore.HotKeyConfiguration.Modifier.allCases.map {
                ($0, ModifierDoubleTapDetector(target: $0))
            }
        )
    }

    func update(
        activeModifiers: Set<SettingsStore.HotKeyConfiguration.Modifier>,
        at time: TimeInterval
    ) -> SettingsStore.HotKeyConfiguration.Modifier? {
        for modifier in SettingsStore.HotKeyConfiguration.Modifier.allCases {
            guard var detector = detectors[modifier] else { continue }
            let fired = detector.update(activeModifiers: activeModifiers, at: time)
            detectors[modifier] = detector
            if fired { return modifier }
        }
        return nil
    }

    func keyDown() {
        for modifier in SettingsStore.HotKeyConfiguration.Modifier.allCases {
            guard var detector = detectors[modifier] else { continue }
            detector.keyDown()
            detectors[modifier] = detector
        }
    }
}
