import Foundation

public enum SelectionHoldDelay: Int, CaseIterable, Identifiable, Sendable {
    case milliseconds300 = 300, milliseconds500 = 500, second1 = 1000, seconds2 = 2000
    public var id: Int { rawValue }
    public var seconds: TimeInterval { Double(rawValue) / 1000 }
    public var label: String { rawValue < 1000 ? "\(rawValue) ms" : "\(rawValue / 1000) 秒" }
}
