import os

public enum Log {
    private static let subsystem = "com.donts.DontsTool"
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let search = Logger(subsystem: subsystem, category: "search")
    public static let provider = Logger(subsystem: subsystem, category: "provider")
    public static let translation = Logger(subsystem: subsystem, category: "translation")
    public static let ai = Logger(subsystem: subsystem, category: "ai")
    public static let index = Logger(subsystem: subsystem, category: "index")
    public static let plugin = Logger(subsystem: subsystem, category: "plugin")
}
