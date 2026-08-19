import Foundation

/// 版本信息。**单一事实来源是 `build.sh` 顶部的 `APP_VERSION_NUM` / `APP_BUILD`**，
/// 由构建脚本注入 Info.plist；这里直接从 Bundle 读，永不硬编码，
/// 避免出现「日志显示 build 15、实际跑的是 build 42」这种误导。
/// 常量兜底值仅用于脱离 .app 包直接跑二进制的场景。
enum AppVersion {
    static let bundleID = "com.macall.app"

    static let display: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"

    static let build: String =
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
}
