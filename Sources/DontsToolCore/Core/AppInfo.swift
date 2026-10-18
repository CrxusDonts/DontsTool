import Foundation

public enum AppInfo {
    public static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    public static let bundleIdentifier = "com.donts.DontsTool"
    public static let displayName = "DontsTool"
}
