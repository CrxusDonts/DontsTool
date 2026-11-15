import CoreGraphics

/// 尺寸令牌：design/DESIGN.md 第 4 节与稿件结构。
enum Metrics {
    // 启动器面板
    static let panelSize = CGSize(width: 700, height: 480)
    static let panelCornerRadius: CGFloat = 18
    static let headerHeight: CGFloat = 72
    static let footerHeight: CGFloat = 38
    static let panelHorizontalInset: CGFloat = 22
    static let listHorizontalInset: CGFloat = 10
    static let listVerticalInset: CGFloat = 10
    static let listSpacing: CGFloat = 3

    // 结果行
    static let rowHeight: CGFloat = 54
    static let rowCornerRadius: CGFloat = 10
    static let rowHorizontalInset: CGFloat = 13
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
