import Foundation
import Observation

// MARK: - 逐 App 音频引擎

/// 统一管理逐 App 音量：监视发声 App，并按「受控配置」为对应 App 创建进程拦截器
/// （ProcessTapController），在用户调整音量 / 静音 / 路由（写配置并保存）后即时改写对应 tap。
///
/// 与 SettingsModel 解耦：引擎只接收 `applyControlledMap(...)`（受控 App → 音量/静音/路由），
/// 由 VolumeFeature 在 install/reload 时依据 Configuration 计算并下发；UI 仅改配置 + 保存，
/// 保存触发的 reload 自然完成 reconcile，无需 UI 直接调用引擎。
///
/// 安全策略（默认 opt-in）：App 只有在配置中存在 `perAppVolume[key]` 时才会被拦截，
/// 未启用的 App 完全不受影响（系统音频原样输出）。
@Observable
final class PerAppAudioEngine {

    static let shared = PerAppAudioEngine()

    private let monitor = AudioProcessMonitor()
    private var taps: [String: ProcessTapController] = [:]
    private(set) var activeApps: [AudioApp] = []

    /// 最近一次下发的受控配置；进程列表变化时据此重新协调（异步就绪后补建 tap）。
    private var lastControlledMap: [String: PerAppState] = [:]

    private init() {
        monitor.onAppsChanged = { [weak self] apps in
            self?.handleAppsChanged(apps)
        }
    }

    // MARK: - 生命周期

    func start() {
        monitor.start()
        reconcile()
    }

    func stop() {
        monitor.stop()
        for tap in taps.values { tap.invalidate() }
        taps.removeAll()
        lastControlledMap.removeAll()
    }

    /// 主动重新枚举一次当前发声进程（弹窗打开时调用，确保列表是最新的）。
    func refreshNow() {
        monitor.refresh()
    }

    // MARK: - 受控配置下发

    /// 依据 Configuration 计算受控映射并应用。install / reload 时调用。
    func applyControlledMap(_ map: [String: PerAppState]) {
        lastControlledMap = map
        // 把用户已在配置中受控的 App 的持久键（bundleID）告诉监视器：
        // 即便媒体分类漏判，这些 App 也始终出现在列表里。
        monitor.alwaysIncludeBundleIDs = Set(map.keys)
        reconcile()
    }

    /// 协调：为「受控且当前发声」的 App 建/更新 tap；移除不再受控或已停止发声的 tap。
    private func reconcile() {
        let map = lastControlledMap

        for (key, state) in map {
            guard let app = activeApps.first(where: { $0.persistenceKey == key }) else { continue }
            let resolved = resolveDeviceUIDs(state.devices)
            guard !resolved.isEmpty else { continue }

            if let tap = taps[key] {
                tap.volume = Float(state.volume)
                tap.isMuted = state.muted
                if resolved != tap.currentDeviceUIDs {
                    try? tap.updateDevices(to: resolved)
                }
            } else {
                let tap = ProcessTapController(app: app, targetDeviceUIDs: resolved)
                tap.volume = Float(state.volume)
                tap.isMuted = state.muted
                do { try tap.activate(); taps[key] = tap }
                catch { Log.error("[perapp] 为 \(app.name) 创建 tap 失败: \(error.localizedDescription)"); continue }
            }
        }

        for key in taps.keys where map[key] == nil {
            taps.removeValue(forKey: key)?.invalidate()
        }
    }

    private func handleAppsChanged(_ apps: [AudioApp]) {
        activeApps = apps
        NotificationCenter.default.post(name: NSNotification.Name("perAppAppsChanged"), object: nil)
        reconcile()
    }

    // MARK: - 内部

    /// 解析某个受控 App 的目标设备 UID：配置为空 → 跟随当前系统默认输出；否则过滤掉离线设备。
    private func resolveDeviceUIDs(_ devices: [String]) -> [String] {
        if devices.isEmpty {
            if let def = CoreAudioHelpers.defaultOutputDeviceUID() { return [def] }
            return []
        }
        return devices.filter { VolumeCore.deviceWithUID($0) != nil }
    }
}

// MARK: - 受控状态

struct PerAppState {
    let volume: Double
    let muted: Bool
    /// 路由设备 UID 列表；空数组表示「跟随系统默认输出」。
    let devices: [String]
}
