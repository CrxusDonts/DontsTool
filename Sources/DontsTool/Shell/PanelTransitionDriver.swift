import AppKit
import QuartzCore

/// 仅移动窗口原点和透明度，避免变换 SwiftUI 承载图层造成裁剪。
@MainActor
final class PanelTransitionDriver {
    private struct Transition {
        let origin: NSPoint
        let destination: NSPoint
        let alpha: CGFloat
        let targetAlpha: CGFloat
        let startedAt: CFTimeInterval
        let duration: TimeInterval
        let isDismissing: Bool
        let completion: (@MainActor @Sendable () -> Void)?
    }

    private weak var panel: NSPanel?
    private var restingOrigin: NSPoint?
    private var transition: Transition?
    private(set) var displayLink: CADisplayLink?
    private var generation: UInt = 0
    var isDisplayLinked: Bool { displayLink != nil }

    isolated deinit {
        displayLink?.invalidate()
    }

    @MainActor
    private final class FrameTarget: NSObject {
        weak var owner: PanelTransitionDriver?
        let token: UInt

        init(owner: PanelTransitionDriver, token: UInt) {
            self.owner = owner
            self.token = token
        }

        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.advance(token: token, timestamp: link.targetTimestamp)
        }
    }

    /// 显示窗口；键盘焦点仍由 Controller 同步设置，不等待转场完成。
    func show(panel: NSPanel, at origin: NSPoint) {
        let isReversing = self.panel === panel && transition != nil && panel.isVisible
        stopFrames()
        self.panel = panel
        restingOrigin = origin
        panel.animationBehavior = .none

        if !isReversing {
            panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y - 8))
            panel.alphaValue = 0
        }
        panel.orderFront(nil)
        begin(
            panel: panel,
            destination: origin,
            targetAlpha: 1,
            duration: Motion.panelEnter,
            isDismissing: false
        )
    }

    /// completion 在淡出结束时执行，由 Controller 收起窗口并恢复前台应用。
    func hide(panel: NSPanel, completion: @escaping @MainActor @Sendable () -> Void) {
        let origin = self.panel === panel ? restingOrigin ?? panel.frame.origin : panel.frame.origin
        stopFrames()
        self.panel = panel
        restingOrigin = origin
        begin(
            panel: panel,
            destination: NSPoint(x: origin.x, y: origin.y - 4),
            targetAlpha: 0,
            duration: Motion.panelExit,
            isDismissing: true,
            completion: completion
        )
    }

    /// 同步执行其他窗口操作前取消转场，不触发已取消的隐藏回调。
    func cancel() {
        stopFrames()
        if let panel, let restingOrigin {
            panel.setFrameOrigin(restingOrigin)
            panel.alphaValue = 1
        }
    }

    /// 面板高度自适应调整且顶部边缘固定时，同步平移缓存原点与进行中的转场起止点。
    func adjustOrigin(deltaY: CGFloat) {
        guard deltaY != 0 else { return }
        if var origin = restingOrigin {
            origin.y += deltaY
            restingOrigin = origin
        }
        if let active = transition {
            transition = Transition(
                origin: NSPoint(x: active.origin.x, y: active.origin.y + deltaY),
                destination: NSPoint(x: active.destination.x, y: active.destination.y + deltaY),
                alpha: active.alpha,
                targetAlpha: active.targetAlpha,
                startedAt: active.startedAt,
                duration: active.duration,
                isDismissing: active.isDismissing,
                completion: active.completion
            )
        }
    }

    private func begin(
        panel: NSPanel,
        destination: NSPoint,
        targetAlpha: CGFloat,
        duration: TimeInterval,
        isDismissing: Bool,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        transition = Transition(
            origin: panel.frame.origin,
            destination: destination,
            alpha: panel.alphaValue,
            targetAlpha: targetAlpha,
            startedAt: CACurrentMediaTime(),
            duration: duration,
            isDismissing: isDismissing,
            completion: completion
        )
        let token = generation
        guard !Motion.reduceMotion else {
            finish(token: token)
            return
        }

        let target = FrameTarget(owner: self, token: token)
        let link = panel.displayLink(target: target, selector: #selector(FrameTarget.frame(_:)))
        let maximum = Float(max(1, panel.screen?.maximumFramesPerSecond ?? 60))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    private func advance(token: UInt, timestamp: CFTimeInterval) {
        guard generation == token else { return }
        guard let transition, let panel else {
            stopFrames()
            return
        }
        let progress = min(1, max(0, (timestamp - transition.startedAt) / transition.duration))
        // 系统设置在转场中改变时，下一帧立即到达最终状态。
        guard !Motion.reduceMotion, progress < 1 else {
            finish(token: token)
            return
        }
        let eased = Motion.panelProgress(progress, dismissing: transition.isDismissing)
        let amount = CGFloat(eased)
        panel.setFrameOrigin(NSPoint(
            x: transition.origin.x + (transition.destination.x - transition.origin.x) * amount,
            y: transition.origin.y + (transition.destination.y - transition.origin.y) * amount
        ))
        panel.alphaValue = transition.alpha + (transition.targetAlpha - transition.alpha) * amount
    }

    private func finish(token: UInt) {
        guard generation == token, let transition, let panel else { return }
        displayLink?.invalidate()
        displayLink = nil
        self.transition = nil
        panel.setFrameOrigin(restingOrigin ?? transition.destination)
        panel.alphaValue = transition.targetAlpha
        transition.completion?()
        // completion 可同步重开窗口，不能再覆盖新转场的透明度。
        if generation == token, !panel.isVisible {
            panel.alphaValue = 1
        }
    }

    private func stopFrames() {
        generation &+= 1
        displayLink?.invalidate()
        displayLink = nil
        transition = nil
    }
}
