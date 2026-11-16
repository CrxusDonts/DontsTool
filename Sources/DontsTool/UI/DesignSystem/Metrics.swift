import CoreGraphics

/// 尺寸令牌：极简紧凑的 macOS Liquid Glass 比例。
enum Metrics {
    // 启动器面板
    static let panelSize = CGSize(width: 660, height: 440)
    static let panelCornerRadius: CGFloat = 18
    static let headerHeight: CGFloat = 54
    static let footerHeight: CGFloat = 32
    static let panelHorizontalInset: CGFloat = 16
    static let listHorizontalInset: CGFloat = 8
    static let listVerticalInset: CGFloat = 6
    static let listSpacing: CGFloat = 2

    // 结果行
    static let rowHeight: CGFloat = 44
    static let rowCornerRadius: CGFloat = 9
    static let rowHorizontalInset: CGFloat = 10
    static let rowIconSpacing: CGFloat = 10
    static let iconSize: CGFloat = 26
    static let iconCornerRadius: CGFloat = 7
    static let captionHorizontalInset: CGFloat = 10
    static let captionVerticalInset: CGFloat = 3

    // 控件
    static let keycapCornerRadius: CGFloat = 5
    static let capsuleCornerRadius: CGFloat = 6
    static let gearButtonSize: CGFloat = 26
    static let toastCornerRadius: CGFloat = 10
    static let toastBottomInset: CGFloat = 40

    // 设置窗口
    static let settingsSize = CGSize(width: 820, height: 580)
    static let settingsSidebarWidth: CGFloat = 184
    static let settingsGroupCornerRadius: CGFloat = 11
}
