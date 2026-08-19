import AppKit
import Foundation

// MARK: - Feature contract

/// 功能大类，仅用于设置界面的分组展示。
enum FeatureCategory: String, CaseIterable {
    case monitor = "系统监控"
    case window = "窗口管理"
    case system = "系统"
    case other = "其它"

    var order: Int {
        switch self {
        case .monitor: 0
        case .window: 1
        case .system: 2
        case .other: 3
        }
    }
}

/// 一个自包含的能力模块。新增功能 = 新建一个遵守 `Feature` 的文件，
/// 并在 `defaultFeatures()` 里注册一行，其它代码无需改动。
///
/// 协议参考自有项目 Macindow 的 Feature 设计（去热键耦合 + 支持 `handle(action:)` 接收快捷键派发）。
protocol Feature: AnyObject {
    /// 唯一标识，用作配置开关的 key。
    var id: String { get }
    /// 设置界面中展示的名称。
    var title: String { get }
    /// 分组。
    var category: FeatureCategory { get }
    /// 默认是否启用。
    var enabledByDefault: Bool { get }

    /// 启动时（或被开启时）调用一次，用于建立监听 / 定时器。
    func install(context: AppContext)
    /// 退出或被关闭时调用，用于清理资源。
    func uninstall()
    /// 用户修改配置后调用。
    func reload(config: Configuration)
    /// 某个快捷键命中时由注册表派发到这里。
    func handle(action: String)
    /// 可选：向菜单栏下拉菜单贡献若干菜单项。
    func menuItems() -> [NSMenuItem]?

    /// 可选：（重新）建立本功能自己的全局事件监听。
    ///
    /// ⚠️ 这条是 v0.5.0 补的关键钩子。此前只有 HotkeyManager 的键盘 tap 会在
    /// `ensureAllTaps()` 里重建，而 EdgeSnapFeature 的鼠标 tap 只在 `install()` 里建一次：
    /// 冷启动时若辅助功能权限还没就绪，`CGEvent.tapCreate` 返回 nil，之后**永远不会重试**，
    /// 于是「授权后其它功能都活了，唯独边缘分屏一直是死的」。
    func ensureTap()
    /// 可选：休眠唤醒后重新启用监听（macOS 会静默禁用长时间挂起的 tap）。
    func reenable()

    /// 可选：是否可作为「工具箱」面板里的可点击工具。
    var isLaunchableTool: Bool { get }
    /// 可选：点击工具箱内该工具时派发的动作（传给 `handle(action:)`）。nil 表示不可启动。
    var launchAction: String? { get }
}

extension Feature {
    var enabledByDefault: Bool { true }
    func menuItems() -> [NSMenuItem]? { nil }
    func reload(config: Configuration) {}
    func handle(action: String) {}
    func ensureTap() {}
    func reenable() {}
    var isLaunchableTool: Bool { false }
    var launchAction: String? { nil }
}

// MARK: - Shared context

/// 注入给每个 Feature 的共享上下文。
final class AppContext {
    var config: Configuration
    let hotkeys: HotkeyManager
    init(config: Configuration, hotkeys: HotkeyManager) {
        self.config = config
        self.hotkeys = hotkeys
    }
}

// MARK: - Registry

/// 功能注册表：负责 install/uninstall、运行时启停、快捷键派发、菜单聚合、设置枚举。
final class FeatureRegistry {
    /// 注意：Configuration 是值类型（struct）。SettingsModel 持有自己的副本用于
    /// 界面编辑，而注册表持有另一份用于驱动运行中的功能与全局快捷键。任何经由
    /// SettingsModel 修改配置的入口（如 setHotkey）必须在 save() 时把编辑副本
    /// 同步回本属性，否则 reloadAll() 只会读到陈旧的 registry.config，导致快捷键
    /// 等改动「界面变了但功能不生效」。
    var config: Configuration
    let hotkeys = HotkeyManager()
    private var features: [String: Feature] = [:]
    private(set) var installed: Set<String> = []

    init(config: Configuration) {
        self.config = config
    }

    func register(_ f: Feature) {
        features[f.id] = f
    }

    func installAll() {
        let ctx = AppContext(config: config, hotkeys: hotkeys)
        for f in features.values where isEnabled(f) {
            let id = f.id
            // 异常隔离：单个功能的 install() 若抛出 ObjC 异常（Swift 自身无法捕获
            // NSException），只跳过该功能，不再拖垮整个 app 启动——否则 didFinishLaunching
            // 中断，状态栏与设置窗口都不会创建（表现就是「菜单栏没入口、窗口不弹」）。
            let ok = MACatchException {
                f.install(context: ctx)
            }
            if ok {
                installed.insert(id)
                Log.info("[install] 已安装：\(id)")
            } else {
                Log.error("[install] 功能 \(id) 安装抛异常，已跳过，避免拖垮整个启动")
            }
        }
        hotkeys.registry = self
        hotkeys.rebuild(config: config)
        hotkeys.start()
    }

    func dispatch(featureId: String, action: String) {
        features[featureId]?.handle(action: action)
    }

    func isEnabled(_ f: Feature) -> Bool {
        config.isFeatureEnabled(f.id, default: f.enabledByDefault)
    }

    func isEnabled(_ id: String) -> Bool {
        guard let f = features[id] else { return false }
        return isEnabled(f)
    }

    /// 按 id 取回已注册功能（设置界面渲染模块卡片时用于拿标题）。
    func feature(_ id: String) -> Feature? { features[id] }

    /// 运行时开关某个功能。
    func setEnabled(_ id: String, _ on: Bool) {
        config.setFeatureEnabled(id, on)
        config.save()
        guard let f = features[id] else { return }
        if on, !installed.contains(id) {
            f.install(context: AppContext(config: config, hotkeys: hotkeys))
            installed.insert(id)
        } else if !on, installed.contains(id) {
            f.uninstall()
            installed.remove(id)
        }
        hotkeys.rebuild(config: config)
        // 广播总开关变化，供状态栏图标等订阅者即时联动（无需重启）。
        NotificationCenter.default.post(
            name: .featureEnabledChanged,
            object: nil,
            userInfo: ["id": id, "enabled": on])
    }

    func reloadAll() {
        for id in installed { features[id]?.reload(config: config) }
        hotkeys.rebuild(config: config)
    }

    /// 重建全局事件监听（输入监控 / 辅助功能权限就绪后调用，无需重启）。
    ///
    /// 除了 HotkeyManager 的键盘 tap，还必须把每个已安装功能自己的 tap 也带上
    /// （目前是 EdgeSnapFeature 的鼠标 tap）。少了这一步，权限是在启动之后才授予的场景里
    /// 那些功能会一直保持「创建失败」的死状态。
    func ensureAllTaps() {
        let keyboardOk = hotkeys.ensureStarted()
        hotkeys.rebuild(config: config)
        for id in installed { features[id]?.ensureTap() }
        Log.info("ensureAllTaps 完成 — 键盘监听: \(keyboardOk ? "就绪" : "失败")，功能 tap: \(installed.count) 个已巡检")
    }

    func reenableAll() {
        hotkeys.reenable()
        for id in installed { features[id]?.reenable() }
    }

    /// 所有已注册功能，按 类别 → 名称 排序，供设置界面枚举。
    var all: [Feature] {
        features.values.sorted {
            ($0.category.order, $0.title) < ($1.category.order, $1.title)
        }
    }

    /// 聚合所有功能贡献的菜单项。
    func menuItems() -> [NSMenuItem] {
        features.values.flatMap { $0.menuItems() ?? [] }
    }
}
