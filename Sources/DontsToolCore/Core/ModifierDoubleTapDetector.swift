import Foundation

/// 识别修饰键双击：两次短按、期间没有其他按键或修饰键、间隔在阈值内。
public struct ModifierDoubleTapDetector: Sendable {
    public typealias Modifier = SettingsStore.HotKeyConfiguration.Modifier

    private let target: Modifier
    private let interval: TimeInterval
    private let maxTapDuration: TimeInterval
    private let cooldown: TimeInterval

    private var previousActive: Set<Modifier> = []
    private var pressStartedAt: TimeInterval?
    private var pendingReleaseAt: TimeInterval?
    private var currentTapInvalid = false
    private var isSecondTap = false
    private var previousKeyDownCount: UInt32?
    private var lastFireAt = -TimeInterval.infinity

    public init(
        target: Modifier,
        interval: TimeInterval = 0.3,
        maxTapDuration: TimeInterval = 0.3,
        cooldown: TimeInterval = 0.5
    ) {
        self.target = target
        self.interval = interval
        self.maxTapDuration = maxTapDuration
        self.cooldown = cooldown
    }

    /// 仅在第二次短按松开时触发。计数变化用于打断序列，无需监听普通按键。
    public mutating func update(
        activeModifiers: Set<Modifier>,
        at time: TimeInterval,
        keyDownCount: UInt32? = nil,
        latestKeyDownAt: TimeInterval? = nil
    ) -> Bool {
        // 回调可能排队；当前计数会包含“事件发生之后”的普通输入。
        // 对无法按事件时序确认的序列保守取消，且不让随后松开重新建立第一击。
        if let latestKeyDownAt, latestKeyDownAt >= time {
            previousActive = activeModifiers
            previousKeyDownCount = keyDownCount
            pressStartedAt = nil
            pendingReleaseAt = nil
            currentTapInvalid = true
            isSecondTap = false
            return false
        }
        if let keyDownCount {
            if let previousKeyDownCount, previousKeyDownCount != keyDownCount {
                keyDown()
            }
            previousKeyDownCount = keyDownCount
        }
        let wasDown = previousActive.contains(target)
        let isDown = activeModifiers.contains(target)
        defer { previousActive = activeModifiers }

        if activeModifiers.contains(where: { $0 != target }) {
            currentTapInvalid = true
            pendingReleaseAt = nil
            isSecondTap = false
        }
        guard isDown != wasDown else { return false }

        if isDown {
            guard activeModifiers == [target] else {
                currentTapInvalid = true
                pendingReleaseAt = nil
                pressStartedAt = nil
                return false
            }

            if let pendingReleaseAt, let latestKeyDownAt, latestKeyDownAt >= pendingReleaseAt {
                self.pendingReleaseAt = nil
            }
            isSecondTap = pendingReleaseAt.map { time - $0 <= interval } ?? false
            if !isSecondTap { pendingReleaseAt = nil }
            pressStartedAt = time
            currentTapInvalid = false
        } else {
            defer {
                pressStartedAt = nil
                currentTapInvalid = false
                isSecondTap = false
            }
            guard !currentTapInvalid,
                  let pressStartedAt,
                  time - pressStartedAt <= maxTapDuration,
                  latestKeyDownAt.map({ $0 < pressStartedAt }) ?? true,
                  activeModifiers.isEmpty else {
                pendingReleaseAt = nil
                return false
            }
            if isSecondTap {
                pendingReleaseAt = nil
                guard time - lastFireAt > cooldown else { return false }
                lastFireAt = time
                return true
            }
            pendingReleaseAt = time
        }

        return false
    }

    /// 普通按键会打断双击序列。
    public mutating func keyDown() {
        pendingReleaseAt = nil
        isSecondTap = false
        if previousActive.contains(target) {
            currentTapInvalid = true
        }
    }
}
