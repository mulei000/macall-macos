import AppKit
import SwiftUI

// MARK: - 音频设置页
//
// 三个模块，各自带右上角总开关，样式与其他设置页完全一致：
//   1. volume         主输出音量 / 静音 / 输出设备 / 逐 App 音量
//   2. devicepriority 输出设备优先级与自动路由
//   3. outputswitcher 输出设备快捷键轮切
//   4. miccontrol     默认输入设备 / 麦克风静音

/// 把配置里当前绑定的快捷键（或默认值）转成可读的 ⌃⌥X 形式，
/// 避免设置页写死默认组合，用户自定义后界面仍同步。
private func configuredShortcutText(for key: String, model: SettingsModel) -> String {
    let spec = model.config.hotkeys[key] ?? Configuration.defaultHotkeys()[key]
    guard let spec = spec else { return "" }
    return hotkeyDisplayString(spec)
}

struct VolumeSettingsView: View {
    @ObservedObject var model: SettingsModel

    @Default(.volumeModuleOrder) var volumeModuleOrder
    @Default(.volumeHiddenModules) var volumeHiddenModules

    var body: some View {
        IadenteSettingsPage {
            FeatureModuleCard(model: model, featureID: "volume") {
                MasterVolumePanel(model: model)
                OutputDevicePanel(model: model)
                SystemSoundOutputPanel(model: model)
                AutoDuckPanel(model: model)
                PerAppVolumePanel(model: model)
            }

            // 「弹窗模块」管理：顺序 + 显隐。参考系统监控的「状态栏模块」卡片。
            IadenteCard(
                IadenteL10n.t("弹窗模块", "Popover Modules"),
                subtitle: IadenteL10n.t(
                    "勾选控制各模块是否在音量弹窗中显示，点击 ↑↓ 调整上下顺序；弹窗高度随显示内容自动伸缩。主音量常驻，不可隐藏。",
                    "Toggle to show or hide each module in the volume popover; use ↑↓ to reorder. The popover height auto-fits the enabled modules. Master volume is always shown."
                ),
                icon: "slider.vertical.3",
                colors: IadenteTheme.advancedColors
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(volumeModuleOrder.enumerated()), id: \.element) { index, module in
                        VolumeModuleRow(
                            module: module,
                            isHidden: volumeHiddenModules.contains(module),
                            isFirst: index == 0,
                            isLast: index == volumeModuleOrder.count - 1,
                            onToggle: { toggleVolumeModule(module) },
                            onMoveUp: { moveVolumeModule(module, .up) },
                            onMoveDown: { moveVolumeModule(module, .down) }
                        )

                        if index < volumeModuleOrder.count - 1 {
                            IadenteRowDivider()
                        }
                    }

                    IadenteRowDivider()

                    Button {
                        resetVolumeLayout()
                    } label: {
                        Label(
                            IadenteL10n.t("恢复默认布局", "Reset Default Layout"),
                            systemImage: "arrow.counterclockwise"
                        )
                        .font(.system(size: 12.5, weight: .semibold))
                    }
                    .buttonStyle(IadenteActionButtonStyle(colors: IadenteTheme.advancedColors))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            FeatureModuleCard(
                model: model,
                featureID: "devicepriority",
                masterBinding: Binding(
                    get: { model.registry.isEnabled("devicepriority") && model.config.autoRouteOutput },
                    set: { on in
                        // 「自动路由」既要装功能，也要写配置项——两者必须同时切，
                        // 否则用户看到开关是开的、实际 reconcile() 被 autoRouteOutput 挡住。
                        model.config.autoRouteOutput = on
                        model.setFeatureEnabled("devicepriority", on)
                    }
                )
            ) {
                DevicePriorityPanel(model: model)
            }

            FeatureModuleCard(model: model, featureID: "outputswitcher") {
                OutputSwitcherPanel(model: model)
            }

            FeatureModuleCard(model: model, featureID: "miccontrol") {
                InputDevicePanel(model: model)
            }
        }
    }
}

// MARK: - 音量弹窗模块管理（顺序 + 显隐）

private enum VolumeModuleMoveDirection {
    case up
    case down
}

/// 切换模块显隐；主音量（不可隐藏）直接忽略，开关在 UI 上也是禁用态。
private func toggleVolumeModule(_ module: VolumeModule) {
    guard module.canHide else { return }
    var hidden = Defaults[.volumeHiddenModules]
    if hidden.contains(module) {
        hidden.removeAll { $0 == module }
    } else {
        hidden.append(module)
    }
    Defaults[.volumeHiddenModules] = hidden
}

private func moveVolumeModule(_ module: VolumeModule, _ direction: VolumeModuleMoveDirection) {
    var order = Defaults[.volumeModuleOrder]
    guard let index = order.firstIndex(of: module) else { return }
    let target = direction == .up ? index - 1 : index + 1
    guard order.indices.contains(target) else { return }
    order.swapAt(index, target)
    Defaults[.volumeModuleOrder] = order
}

private func resetVolumeLayout() {
    Defaults[.volumeModuleOrder] = VolumeModule.allCases
    Defaults[.volumeHiddenModules] = []
}

private struct VolumeModuleRow: View {
    let module: VolumeModule
    let isHidden: Bool
    let isFirst: Bool
    let isLast: Bool
    let onToggle: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ReorderControl(isFirst: isFirst, isLast: isLast, onUp: onMoveUp, onDown: onMoveDown)

            Image(systemName: module.icon)
                .frame(width: 20)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title)
                    .font(.system(size: 13, weight: .medium))
                Text(module.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { !isHidden },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(IadenteTheme.jade)
            .disabled(!module.canHide)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 输出设备切换（轮切范围）

/// 勾选「按下 ⌃⌥K 时循环切换」的设备集合；什么都不勾 = 循环全部输出设备。
/// 持久化到 Configuration.outputSwitcherDeviceUIDs（空数组即全部）。
private struct OutputSwitcherPanel: View {
    @ObservedObject var model: SettingsModel
    @State private var deviceRefresh = 0

    private var devices: [AudioDeviceInfo] { _ = deviceRefresh; return VolumeCore.outputDevices() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IadenteRowDivider()

            let shortcut = configuredShortcutText(for: "outputswitcher.cycle", model: model)
            Text(IadenteL10n.t(
                "按下 \(shortcut) 时，在下方勾选的设备间循环切换系统默认输出；什么都不勾则循环全部设备。",
                "Press \(shortcut) to cycle the system output among the checked devices; check none to cycle all."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if devices.isEmpty {
                Text(IadenteL10n.t("未枚举到输出设备。", "No output devices enumerated."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                deviceRow(uid: "", name: IadenteL10n.t("循环全部设备", "Cycle all devices"),
                          selected: model.config.outputSwitcherDeviceUIDs.isEmpty)
                ForEach(devices) { dev in
                    deviceRow(uid: dev.uid, name: dev.displayName,
                              selected: model.config.outputSwitcherDeviceUIDs.contains(dev.uid))
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .audioDevicesChanged)) { _ in deviceRefresh += 1 }
    }

    private func deviceRow(uid: String, name: String, selected: Bool) -> some View {
        Button {
            toggle(uid)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? IadenteTheme.jade : .secondary)
                Text(name)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .padding(.leading, 4)
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ uid: String) {
        if uid.isEmpty {
            // 「循环全部」= 清空勾选列表
            model.config.outputSwitcherDeviceUIDs = []
        } else {
            var set = model.config.outputSwitcherDeviceUIDs
            if set.contains(uid) {
                set.removeAll { $0 == uid }
            } else {
                set.append(uid)
            }
            model.config.outputSwitcherDeviceUIDs = set
        }
        model.save()
    }
}

// MARK: - 主音量

/// 与系统实时双向同步：控制中心 / 键盘音量键改动会立刻反映到这里。
private struct MasterVolumePanel: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var sys = SystemVolumeObserver.shared
    @Default(.showVolumeStatusBarIcon) private var showIcon

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IadenteRowDivider()

            IadenteControlRow(
                IadenteL10n.t("主输出音量", "Master volume"),
                subtitle: IadenteL10n.t(
                    "当前输出：\(sys.deviceName)。与控制中心、键盘音量键实时同步。",
                    "Current output: \(sys.deviceName). Stays in sync with Control Center and the volume keys."),
                icon: "speaker.wave.2.fill",
                colors: IadenteTheme.advancedColors
            ) {
                Text(sys.volumeControllable ? "\(Int(sys.volume * 100))%" : "—")
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            Slider(value: $sys.volume, in: 0...1)
                .tint(IadenteTheme.jade)
                .disabled(!sys.volumeControllable)

            if !sys.volumeControllable {
                IadenteNotice(
                    text: IadenteL10n.t(
                        "当前输出设备不暴露主音量通道（常见于 HDMI / 部分聚合设备），只能在设备自身或逐 App 处调节。",
                        "The current output device exposes no master volume channel (common for HDMI / aggregate devices)."),
                    icon: "info.circle.fill",
                    colors: IadenteTheme.advancedColors)
            }

            let muteShortcut = configuredShortcutText(for: "volume.mute", model: model)
            IadenteControlRow(
                IadenteL10n.t("静音", "Mute"),
                subtitle: IadenteL10n.t("等同于按 \(muteShortcut)。", "Same as pressing \(muteShortcut)."),
                icon: sys.muted ? "speaker.slash.fill" : "speaker.wave.1.fill",
                colors: IadenteTheme.advancedColors
            ) {
                Toggle("", isOn: $sys.muted)
                    .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(IadenteTheme.advancedColors.first ?? IadenteTheme.jade)
            }

            IadenteRowDivider()

            IadenteControlRow(
                IadenteL10n.t("菜单栏音量图标", "Menu-bar volume icon"),
                subtitle: IadenteL10n.t(
                    "在菜单栏显示独立喇叭图标，点击可快速调节音量（与系统监控互不影响）。",
                    "Show a standalone speaker icon in the menu bar for quick volume control, independent of system monitoring."),
                icon: "speaker.wave.2.fill",
                colors: IadenteTheme.advancedColors
            ) {
                Toggle("", isOn: $showIcon)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(IadenteTheme.advancedColors.first ?? IadenteTheme.jade)
            }
        }
        .onAppear { sys.refreshFromSystem() }
    }
}

// MARK: - 输出设备

/// 单选切换系统默认输出设备；「跟随系统」恢复由 macOS 控制。
/// 持久化仍走 Configuration.outputDeviceUIDs：空＝跟随系统，单个＝选中设备。
private struct OutputDevicePanel: View {
    @ObservedObject var model: SettingsModel
    @State private var selectedUID: String? = nil

    private var devices: [AudioDeviceInfo] { VolumeCore.outputDevices() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IadenteRowDivider()

            IadenteControlRow(
                IadenteL10n.t("输出设备切换", "Output device"),
                subtitle: IadenteL10n.t(
                    "点选设备即设为系统默认输出；选「跟随系统」恢复由 macOS 控制。",
                    "Pick a device to make it the system default; choose System default to let macOS decide."),
                icon: "speaker.wave.3.fill",
                colors: IadenteTheme.advancedColors
            ) { EmptyView() }

            if devices.isEmpty {
                Text(IadenteL10n.t("未枚举到输出设备。", "No output devices enumerated."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                deviceRow(uid: "", name: IadenteL10n.t("跟随系统", "System default"), selected: selectedUID == nil)
                ForEach(devices) { dev in
                    deviceRow(uid: dev.uid, name: dev.displayName, selected: selectedUID == dev.uid)
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .audioDevicesChanged)) { _ in reload() }
    }

    /// 旧版可能持久化了多个 UID（多设备输出，已废弃）；回落到「跟随系统」。
    private func reload() {
        let uids = model.config.outputDeviceUIDs
        if uids.isEmpty {
            selectedUID = nil
        } else if uids.count == 1 {
            selectedUID = uids[0]
        } else {
            selectedUID = nil
            model.config.outputDeviceUIDs = []
            model.save()
        }
    }

    private func deviceRow(uid: String, name: String, selected: Bool) -> some View {
        Button {
            select(uid)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? IadenteTheme.jade : .secondary)
                Text(name)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .padding(.leading, 4)
        }
        .buttonStyle(.plain)
    }

    private func select(_ uid: String) {
        selectedUID = uid.isEmpty ? nil : uid
        model.config.outputDeviceUIDs = uid.isEmpty ? [] : [uid]
        model.save()
        // 立即切换系统默认输出（单设备）；「跟随系统」不强制，交由 macOS。
        if let dev = (uid.isEmpty ? nil : VolumeCore.deviceWithUID(uid)) {
            VolumeCore.setDefaultOutputDevice(dev)
        }
    }
}

// MARK: - 设备优先级

private struct DevicePriorityPanel: View {
    @ObservedObject var model: SettingsModel
    @State private var order: [String] = []

    private var devices: [AudioDeviceInfo] { VolumeCore.outputDevices() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            IadenteRowDivider()

            Text(IadenteL10n.t(
                "开启后，当「输出设备」为「跟随系统」时，macall 会自动把当前在线且排序最靠前的设备设为默认输出；插入更靠前的设备时自动切换。越靠上优先级越高。",
                "When enabled and Output Device is set to System default, macall routes audio to the highest-priority online device."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if devices.isEmpty {
                Text(IadenteL10n.t("未枚举到输出设备。", "No output devices enumerated."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(order.enumerated()), id: \.element) { index, uid in
                    if let dev = devices.first(where: { $0.uid == uid }) {
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(dev.displayName)
                                .font(.system(size: 12.5))
                            Spacer(minLength: 8)
                            ReorderControl(
                                isFirst: index == 0,
                                isLast: index == order.count - 1,
                                onUp: { move(index, -1) },
                                onDown: { move(index, 1) })
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .audioDevicesChanged)) { _ in reload() }
    }

    private func reload() {
        let devs = devices.map { $0.uid }
        let saved = model.config.devicePriority.filter { devs.contains($0) }
        order = saved + devs.filter { !saved.contains($0) }
    }

    private func move(_ index: Int, _ delta: Int) {
        let target = index + delta
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        model.config.devicePriority = order
        model.save()
    }
}

// MARK: - 逐 App 音量

private struct PerAppVolumePanel: View {
    @ObservedObject var model: SettingsModel
    private var engine: PerAppAudioEngine { PerAppAudioEngine.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IadenteRowDivider()

            IadenteControlRow(
                IadenteL10n.t("逐 App 音量", "Per-app volume"),
                subtitle: IadenteL10n.t(
                    "开启某个 App 后 macall 接管它的音频（CoreAudio 进程 tap），可单独调音量 / 静音 / 路由。",
                    "Enable an app to intercept its audio and control volume, mute and routing."),
                icon: "speaker.wave.2.bubble.left.fill",
                colors: IadenteTheme.advancedColors
            ) {
                Text(Permissions.isScreenRecordingTrusted()
                     ? IadenteL10n.t("权限就绪", "Ready")
                     : IadenteL10n.t("需屏幕录制", "Needs permission"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Permissions.isScreenRecordingTrusted() ? IadenteTheme.jade : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.primary.opacity(0.08)))
            }

            if !Permissions.isScreenRecordingTrusted() {
                HStack(spacing: 10) {
                    IadenteNotice(
                        text: IadenteL10n.t(
                            "逐 App 音量需要「屏幕录制」权限（macOS 用它授权音频拦截）。",
                            "Per-app volume requires Screen Recording permission."),
                        icon: "exclamationmark.triangle.fill",
                        colors: [IadenteTheme.amber, IadenteTheme.gold])
                    Button(IadenteL10n.t("去开启", "Open")) {
                        Permissions.requestScreenRecording()
                        Permissions.openScreenRecordingSettings()
                    }
                    .controlSize(.small)
                    .buttonStyle(IadenteActionButtonStyle(colors: IadenteTheme.advancedColors))
                }
            }

            if engine.activeApps.isEmpty {
                Text(IadenteL10n.t(
                    "当前没有 App 在播放声音。开始播放后这里会出现可控制的 App。",
                    "No apps are playing audio right now."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(engine.activeApps) { app in
                    PerAppAudioRow(app: app, model: model)
                }
            }
        }
    }
}

// MARK: - 逐 App 行

private struct PerAppAudioRow: View {
    let app: AudioApp
    @ObservedObject var model: SettingsModel

    private var key: String { app.persistenceKey }
    private var controlled: Bool { model.config.perAppVolume[key] != nil }

    @State private var vol: Double = 1.0
    @State private var muted: Bool = false

    init(app: AudioApp, model: SettingsModel) {
        self.app = app
        self.model = model
        let key = app.persistenceKey
        _vol = State(initialValue: model.config.perAppVolume[key] ?? 1.0)
        _muted = State(initialValue: model.config.perAppMuted[key] ?? false)
    }

    private var devices: [AudioDeviceInfo] { VolumeCore.outputDevices() }
    private var routeLabel: String {
        let uids = model.config.perAppDeviceUIDs[key] ?? []
        guard uids.isEmpty else {
            return devices.first { $0.uid == uids[0] }?.displayName ?? uids[0]
        }
        return IadenteL10n.t("跟随系统", "System default")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            IadenteRowDivider()

            HStack(spacing: 10) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 22, height: 22)
                        .cornerRadius(5)
                }
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(get: { controlled }, set: { on in
                    if on {
                        model.config.perAppVolume[key] = 1.0
                        model.config.perAppMuted[key] = false
                    } else {
                        model.config.perAppVolume.removeValue(forKey: key)
                        model.config.perAppMuted.removeValue(forKey: key)
                        model.config.perAppDeviceUIDs.removeValue(forKey: key)
                    }
                    model.save()
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(IadenteTheme.advancedColors.first ?? IadenteTheme.jade)
            }
            .frame(maxWidth: .infinity)

            if controlled {
                HStack(spacing: 8) {
                    Button {
                        muted.toggle()
                        model.config.perAppMuted[key] = muted
                        model.save()
                    } label: {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                            .foregroundStyle(muted ? IadenteTheme.coral : .secondary)
                            .frame(width: 18)
                    }
                    .buttonStyle(.plain)

                    Slider(value: $vol, in: 0...2)
                        .onChange(of: vol) { _, newValue in
                            model.config.perAppVolume[key] = newValue
                            model.save()
                        }
                        .tint(IadenteTheme.jade)

                    Text("\(Int(vol * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }

                HStack(spacing: 10) {
                    Menu {
                        Button(IadenteL10n.t("跟随系统", "System default")) {
                            model.config.perAppDeviceUIDs[key] = []
                            model.save()
                        }
                        ForEach(devices) { dev in
                            Button(dev.displayName) {
                                model.config.perAppDeviceUIDs[key] = [dev.uid]
                                model.save()
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(IadenteL10n.t("输出：\(routeLabel)", "Out: \(routeLabel)"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.08)))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 输入设备（麦克风）

/// 选定系统默认输入设备（麦克风）；「按 ⌃⌥J」可切换麦克风静音。
/// 持久化到 Configuration.defaultInputDeviceUID；点选即设为系统默认输入并写入配置。
private struct InputDevicePanel: View {
    @ObservedObject var model: SettingsModel
    @State private var selectedUID: String? = nil

    private var devices: [AudioDeviceInfo] { VolumeCore.inputDevices() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IadenteRowDivider()

            let micShortcut = configuredShortcutText(for: "miccontrol.mute", model: model)
            IadenteControlRow(
                IadenteL10n.t("输入设备（麦克风）", "Input device (mic)"),
                subtitle: IadenteL10n.t(
                    "点选设备即设为系统默认输入；也可按 \(micShortcut) 切换麦克风静音。",
                    "Pick a device to make it the default input; press \(micShortcut) to mute the mic."),
                icon: "mic.fill",
                colors: IadenteTheme.advancedColors
            ) { EmptyView() }

            if devices.isEmpty {
                Text(IadenteL10n.t("未枚举到输入设备。", "No input devices enumerated."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(devices) { dev in
                    deviceRow(uid: dev.uid, name: dev.displayName, selected: selectedUID == dev.uid)
                }
            }

            IadenteRowDivider()

            // 输入设备循环切换快捷键：直接在此卡片内录制 / 重置 / 开关，复用 App 统一行样式。
            FeatureHotkeyRows(
                model: model,
                keyPrefixes: ["inputswitcher."],
                colors: IadenteTheme.advancedColors
            )
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .audioDevicesChanged)) { _ in reload() }
    }

    private func reload() {
        let def = CoreAudioHelpers.defaultInputDeviceUID() ?? ""
        selectedUID = def.isEmpty ? nil : def
    }

    private func deviceRow(uid: String, name: String, selected: Bool) -> some View {
        Button {
            select(uid)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? IadenteTheme.jade : .secondary)
                Text(name)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .padding(.leading, 4)
        }
        .buttonStyle(.plain)
    }

    private func select(_ uid: String) {
        selectedUID = uid
        model.config.defaultInputDeviceUID = uid
        model.save()
        if let dev = VolumeCore.inputDeviceWithUID(uid) {
            VolumeCore.setDefaultInputDevice(dev)
        }
    }
}

// MARK: - 系统提示音输出设备

/// 选择系统提示音（「叮咚」等）从哪个设备播出；「跟随系统」恢复由 macOS 决定。
/// 持久化到 Configuration.systemSoundOutputDeviceUID。
private struct SystemSoundOutputPanel: View {
    @ObservedObject var model: SettingsModel
    @State private var selectedUID: String? = nil

    private var devices: [AudioDeviceInfo] { VolumeCore.systemSoundOutputDevices() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IadenteRowDivider()

            IadenteControlRow(
                IadenteL10n.t("系统提示音输出", "System alert sound"),
                subtitle: IadenteL10n.t(
                    "「叮咚」等系统提示音从哪个设备播出；选「跟随系统」由 macOS 决定。",
                    "Which device plays system alert sounds; choose System default to let macOS decide."),
                icon: "bell.fill",
                colors: IadenteTheme.advancedColors
            ) { EmptyView() }

            if devices.isEmpty {
                Text(IadenteL10n.t("未枚举到可用设备。", "No eligible devices enumerated."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                deviceRow(uid: "", name: IadenteL10n.t("跟随系统", "System default"),
                          selected: selectedUID == nil)
                ForEach(devices) { dev in
                    deviceRow(uid: dev.uid, name: dev.displayName, selected: selectedUID == dev.uid)
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .audioDevicesChanged)) { _ in reload() }
    }

    private func reload() {
        let uid = model.config.systemSoundOutputDeviceUID
        selectedUID = uid.isEmpty ? nil : uid
    }

    private func deviceRow(uid: String, name: String, selected: Bool) -> some View {
        Button {
            select(uid)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? IadenteTheme.jade : .secondary)
                Text(name)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .padding(.leading, 4)
        }
        .buttonStyle(.plain)
    }

    private func select(_ uid: String) {
        selectedUID = uid.isEmpty ? nil : uid
        model.config.systemSoundOutputDeviceUID = uid
        model.save()
        if let dev = (uid.isEmpty ? nil : VolumeCore.systemSoundDeviceWithUID(uid)) {
            VolumeCore.setSystemSoundOutputDevice(dev)
        }
    }
}

// MARK: - 耳机拔出自动降音量

/// 总开关：当系统默认输出从「耳机类」切到「非耳机类」时，自动把主音量降到指定值，
/// 避免外放突然以高音量炸响。由 Configuration.autoDuckOnHeadphoneUnplug / autoDuckTargetVolume 持久化。
private struct AutoDuckPanel: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IadenteRowDivider()

            IadenteControlRow(
                IadenteL10n.t("耳机拔出自动降音量", "Duck volume on headphone unplug"),
                subtitle: IadenteL10n.t(
                    "当系统默认输出从耳机类设备切到扬声器时，自动把主音量降到下方设定值，避免外放突然炸响。",
                    "When the default output switches from headphones to speakers, auto-lower master volume to the level below."),
                icon: "headphones",
                colors: IadenteTheme.advancedColors
            ) {
                Toggle("", isOn: Binding(
                    get: { model.config.autoDuckOnHeadphoneUnplug },
                    set: { on in
                        model.config.autoDuckOnHeadphoneUnplug = on
                        model.save()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(IadenteTheme.advancedColors.first ?? IadenteTheme.jade)
            }

            if model.config.autoDuckOnHeadphoneUnplug {
                HStack(spacing: 10) {
                    Text(IadenteL10n.t("目标音量", "Target volume"))
                        .font(.system(size: 12))
                    Slider(value: Binding(
                        get: { model.config.autoDuckTargetVolume },
                        set: { v in
                            model.config.autoDuckTargetVolume = v
                            model.save()
                        }
                    ), in: 0...1)
                    .tint(IadenteTheme.advancedColors.first ?? IadenteTheme.jade)
                    Text("\(Int(round(model.config.autoDuckTargetVolume * 100)))%")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }
}
