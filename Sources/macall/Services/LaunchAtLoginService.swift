import Foundation
import ServiceManagement
import os.log

class LaunchAtLoginService {
    static let shared = LaunchAtLoginService()

    private let logger = Logger(
        subsystem: "com.macall.app",
        category: "LaunchAtLoginService"
    )

    private init() {}

    /// 尝试设置登录启动。返回是否实际设置成功（注册/注销是否生效）。
    /// 失败时仅记录日志并返回 false，由调用方决定如何提示用户。
    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return SMAppService.mainApp.status == (enabled ? .enabled : .notRegistered)
        } catch {
            logger.error(
                "Failed to \(enabled ? "enable" : "disable") launch at login: \(error)"
            )
            return false
        }
    }

    var isEnabled: Bool {
        return SMAppService.mainApp.status == .enabled
    }
}
