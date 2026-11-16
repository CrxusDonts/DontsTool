import CoreGraphics

/// 尺寸令牌：Raycast × Linear 原生紧凑比例。
enum Metrics {
    // 启动器面板
    static let panelSize = CGSize(width: 660, height: 420)
    static let panelCornerRadius: CGFloat = 14
    static let headerHeight: CGFloat = 52
    static let footerHeight: CGFloat = 30
    static let panelHorizontalInset: CGFloat = 14
    static let listHorizontalInset: CGFloat = 8
    static let listVerticalInset: CGFloat = 6
    static let listSpacing: CGFloat = 2

    // 结果行
    static let rowHeight: CGFloat = 38
    static let rowCornerRadius: CGFloat = 7
    static let rowHorizontalInset: CGFloat = 10
    static let rowIconSpacing: CGFloat = 10
    static let iconSize: CGFloat = 20
    static let iconCornerRadius: CGFloat = 5
    static let captionHorizontalInset: CGFloat = 10
    static let captionVerticalInset: CGFloat = 3

    // 控件
    static let keycapCornerRadius: CGFloat = 4
    static let capsuleCornerRadius: CGFloat = 5
    static let gearButtonSize: CGFloat = 24
    static let toastCornerRadius: CGFloat = 8
    static let toastBottomInset: CGFloat = 38

    // 设置窗口
    static let settingsSize = CGSize(width: 800, height: 560)
    static let settingsSidebarWidth: CGFloat = 180
    static let settingsGroupCornerRadius: CGFloat = 8
}
