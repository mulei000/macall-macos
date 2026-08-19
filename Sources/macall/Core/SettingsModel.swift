import Foundation
import SwiftUI

/// 设置界面的可观察模型。持有配置与注册表，并把改动写回 + 热更新。
/// 注：刻意不加 @MainActor —— 本项目以菜单栏代理方式在主线程度运行，
/// 且 @MainActor ObservableObject 配合 @ObservedObject 在部分 SwiftUI 版本下
/// 会因 actor 隔离在视图渲染期触发运行时陷阱。所有访问本就不离主线程。
final class SettingsModel: ObservableObject {
    @Published var config: Configuration
    let registry: FeatureRegistry

    init(config: Configuration, registry: FeatureRegistry) {
        self.config = config
        self.registry = registry
    }

    /// 保存配置并热更新运行中的功能与快捷键。
    /// 关键：Configuration 是值类型，model.config 与 registry.config 是两副本。
    /// 先把编辑副本同步回 registry.config，再 reloadAll()，否则改了快捷键/布局后
    /// 运行中的 HotkeyManager 仍按陈旧 config 绑定，表现为「设置点了没反应」。
    func save() {
        config.save()
        registry.config = config
        registry.reloadAll()
    }

    /// 设置或重置某个快捷键。
    func setHotkey(_ key: String, _ spec: HotkeySpec) {
        config.hotkeys[key] = spec
        save()
    }

    func resetHotkey(_ key: String) {
        if let defaultSpec = Configuration.defaultHotkeys()[key] {
            config.hotkeys[key] = defaultSpec
        } else {
            config.hotkeys.removeValue(forKey: key)
        }
        save()
    }

    /// 开关某个功能。同时更新 model.config 与 registry.config 两份副本，
    /// 保证任一副本都不会陈旧；否则后续 save() 的整体同步会把旧的开关状态覆盖回去。
    func setFeatureEnabled(_ id: String, _ on: Bool) {
        config.setFeatureEnabled(id, on)
        registry.setEnabled(id, on)
    }

    /// 开关某个子功能（单个快捷键）。仅更新配置并热更新快捷键表，
    /// 不影响功能模块本身的安装/卸载。
    func setHotkeyEnabled(_ key: String, _ on: Bool) {
        config.setHotkeyEnabled(key, on)
        save()
    }

    /// 在用户打开设置 / 授权后重建全局事件监听（输入监控权限此时通常已就绪）。
    func ensureTaps() {
        registry.ensureAllTaps()
    }
}
