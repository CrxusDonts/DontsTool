import CoreGraphics

/// 尺寸令牌：design/DESIGN.md 第 4 节与稿件结构。
enum Metrics {
    // 启动器面板
    static let panelSize = CGSize(width: 640, height: 420)
    static let panelCornerRadius: CGFloat = 14
    static let headerHeight: CGFloat = 60
    static let footerHeight: CGFloat = 32
    static let panelHorizontalInset: CGFloat = 16
    static let listHorizontalInset: CGFloat = 8
    static let listVerticalInset: CGFloat = 8
    static let listSpacing: CGFloat = 2

    // 结果行
    static let rowHeight: CGFloat = 50
    static let rowCornerRadius: CGFloat = 8
    static let rowHorizontalInset: CGFloat = 10
    static let rowIconSpacing: CGFloat = 12
    static let iconSize: CGFloat = 32
    static let iconCornerRadius: CGFloat = 8
    static let captionHorizontalInset: CGFloat = 10
    static let captionVerticalInset: CGFloat = 4

    // 控件
    static let keycapCornerRadius: CGFloat = 5
    static let capsuleCornerRadius: CGFloat = 6
    static let gearButtonSize: CGFloat = 28
    static let toastCornerRadius: CGFloat = 10
    static let toastBottomInset: CGFloat = 44

    // 设置窗口
    static let settingsSize = CGSize(width: 820, height: 620)
    static let settingsSidebarWidth: CGFloat = 176
    static let settingsGroupCornerRadius: CGFloat = 10
}
