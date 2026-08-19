import Foundation
import UserNotifications

/// 阈值通知：当 CPU 温度 / 实时功率 / 运存占用 / 储存内存占用 超过用户设定值时，
/// 发送系统通知。总开关 `disableNotifications` 关闭时全部不发。
/// 每项带冷却时间，避免采样周期内重复打扰。
/// 测试通知结果，供设置页弹窗展示。
enum TestNotificationResult: Identifiable {
    case delivered
    case permissionDenied
    case permissionNotDetermined

    var id: Int { hashValue }
}

@MainActor
final class NotificationService {
    static let shared = NotificationService()

    /// 每个阈值项两次通知之间的最小间隔（秒）。
    private let cooldown: TimeInterval = 300
    private var lastFired: [String: Date] = [:]

    private init() {}

    /// 首次启动时请求通知授权（仅在用户尚未决定时弹出）。
    func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
    }

    /// 根据当前采样值评估是否触发通知。在主线程调用。
    func evaluate(
        cpuTempC: Double,
        systemPower: Double,
        ramPercent: Double,
        storagePercent: Double
    ) {
        guard !Defaults[.disableNotifications] else { return }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .authorized else { return }
            Task { @MainActor in
                self?.evaluateAuthorized(
                    cpuTempC: cpuTempC,
                    systemPower: systemPower,
                    ramPercent: ramPercent,
                    storagePercent: storagePercent
                )
            }
        }
    }

    private func evaluateAuthorized(
        cpuTempC: Double,
        systemPower: Double,
        ramPercent: Double,
        storagePercent: Double
    ) {
        if Defaults[.notifyCpuTempEnabled],
           cpuTempC >= 0,
           cpuTempC >= Defaults[.cpuTempThreshold] {
            fire(
                key: "cpuTemp",
                title: IadenteL10n.t("CPU 温度过高"),
                body: IadenteL10n.t(
                    "当前 \(Int(cpuTempC))°C，超过设定阈值 \(Int(Defaults[.cpuTempThreshold]))°C。",
                    "CPU at \(Int(cpuTempC))°C, above threshold \(Int(Defaults[.cpuTempThreshold]))°C."
                )
            )
        }

        if Defaults[.notifyPowerEnabled],
           systemPower >= 0,
           systemPower >= Defaults[.powerThreshold] {
            fire(
                key: "power",
                title: IadenteL10n.t("实时功率偏高"),
                body: IadenteL10n.t(
                    "当前 \(Int(systemPower)) W，超过设定阈值 \(Int(Defaults[.powerThreshold])) W。",
                    "System power \(Int(systemPower)) W, above threshold \(Int(Defaults[.powerThreshold])) W."
                )
            )
        }

        if Defaults[.notifyRamEnabled],
           ramPercent >= 0,
           ramPercent >= Defaults[.ramThreshold] {
            fire(
                key: "ram",
                title: IadenteL10n.t("运存占用偏高"),
                body: IadenteL10n.t(
                    "运行内存占用 \(Int(ramPercent))%，超过设定阈值 \(Int(Defaults[.ramThreshold]))%。",
                    "RAM usage \(Int(ramPercent))%, above threshold \(Int(Defaults[.ramThreshold]))%."
                )
            )
        }

        if Defaults[.notifyStorageEnabled],
           storagePercent >= 0,
           storagePercent >= Defaults[.storageThreshold] {
            fire(
                key: "storage",
                title: IadenteL10n.t("储存内存占用偏高"),
                body: IadenteL10n.t(
                    "存储空间占用 \(Int(storagePercent))%，超过设定阈值 \(Int(Defaults[.storageThreshold]))%。",
                    "Storage usage \(Int(storagePercent))%, above threshold \(Int(Defaults[.storageThreshold]))%."
                )
            )
        }
    }

    /// 冷却控制：同一项在 cooldown 内最多通知一次。
    private func fire(key: String, title: String, body: String) {
        let now = Date()
        if let last = lastFired[key], now.timeIntervalSince(last) < cooldown {
            return
        }
        lastFired[key] = now

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "macall.\(key)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// 立即发送一条通知（不经过总开关/阈值/冷却），用于操作反馈（如「已复制路径」）。
    /// 未授权通知时静默失败，不影响主功能。
    nonisolated func notifyNow(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "macall.notify.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// 发送一条测试通知，用于端到端验证通知通道是否可用。
    /// - 已授权：立即送达。
    /// - 未决定：先请求授权，授权成功后送达。
    /// - 已拒绝（或 provisional/ephemeral）：无法送达，回调 permissionDenied。
    /// 注意：测试通知绕过总开关与各项阈值/冷却，专供验证。
    func sendTestNotification(completion: @escaping (TestNotificationResult) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized:
                    self.deliverTest()
                    completion(.delivered)
                case .notDetermined:
                    let granted = await withCheckedContinuation { cont in
                        UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert, .sound]) { g, _ in
                                cont.resume(returning: g)
                            }
                    }
                    if granted { self.deliverTest() }
                    completion(granted ? .delivered : .permissionNotDetermined)
                default:
                    completion(.permissionDenied)
                }
            }
        }
    }

    private func deliverTest() {
        let content = UNMutableNotificationContent()
        content.title = IadenteL10n.t("macall 通知测试", "macall Test")
        content.body = IadenteL10n.t(
            "如果你看到了这条通知，说明通知功能正常工作。",
            "If you can see this, notifications are working correctly."
        )
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "macall.test.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
