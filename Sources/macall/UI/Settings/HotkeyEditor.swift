import AppKit
import SwiftUI

/// 统一的「子功能 / 快捷键」行列表（无卡片外壳，供 `FeatureModuleCard` 内嵌）。
///
/// 全 App 的快捷键行只此一种样式，保证「排序方式一样、开关一样」：
/// `[图标] 名称 + 组合键说明 …… [组合键胶囊] [修改] [重置] [子功能开关]`
/// 开关一律放在行尾，与 `IadenteSettingToggle` 的位置约定保持一致。
struct FeatureHotkeyRows: View {
    @ObservedObject var model: SettingsModel
    /// 仅展示这些前缀下的快捷键（如 ["snap.", "hide."]）。
    let keyPrefixes: [String]
    let colors: [Color]
    /// 所属模块是否启用；关闭时整组置灰并禁止操作。
    var moduleEnabled: Bool = true

    @State private var captureTarget: HotkeyCaptureTarget? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let dup = duplicateMessage {
                IadenteNotice(
                    text: dup,
                    icon: "exclamationmark.triangle.fill",
                    colors: [IadenteTheme.coral, IadenteTheme.amber]
                )
            }

            ForEach(Array(visibleEntries.enumerated()), id: \.element.key) { index, entry in
                hotkeyRow(entry)
                if index < visibleEntries.count - 1 {
                    IadenteRowDivider()
                }
            }

            if visibleEntries.count > 1 {
                HStack {
                    Spacer()
                    Button(IadenteL10n.t("全部恢复默认", "Reset All")) { resetAll() }
                        .font(.caption)
                        .controlSize(.small)
                        .buttonStyle(IadenteActionButtonStyle(colors: colors))
                }
                .padding(.top, 2)
            }
        }
        .opacity(moduleEnabled ? 1 : 0.4)
        .disabled(!moduleEnabled)
        .sheet(item: $captureTarget, onDismiss: {
            model.registry.hotkeys.resume()
        }) { target in
            HotkeyCaptureSheet(
                target: target,
                existing: currentAssignments,
                onCommit: { spec in
                    model.setHotkey(target.id, spec)
                    captureTarget = nil
                },
                onCancel: { captureTarget = nil }
            )
        }
    }

    // MARK: - 行

    private func hotkeyRow(_ entry: EditableHotkey) -> some View {
        let on = model.config.enabledHotkeys[entry.key] ?? true
        return HStack(spacing: 10) {
            IadenteIconBadge(icon: entry.icon, colors: colors, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label)
                    .font(.system(size: 13, weight: .medium))
                // 这行以前写的是「基础修饰键：⌃⌥」——把组合键拆一半重复播报一次，
                // 既没信息量又和右边的胶囊打架。用户只需要知道「这条有快捷键、能改」，
                // 具体键位看右侧胶囊即可。
                Text(model.config.hotkeys[entry.key] == nil
                     ? IadenteL10n.t("未设置快捷键（可自定义）", "No hotkey (customizable)")
                     : IadenteL10n.t("有快捷键（可自定义）", "Has a hotkey (customizable)"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .opacity(on ? 1 : 0.45)

            Spacer(minLength: 8)

            if let spec = model.config.hotkeys[entry.key] {
                let clashing = conflictPartners(for: entry.key, spec: spec)
                Text(describeHotkey(spec))
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(clashing.isEmpty ? Color.primary : Color.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(
                            clashing.isEmpty
                                ? AnyShapeStyle(Color.secondary.opacity(0.22))
                                : AnyShapeStyle(IadenteTheme.coral)))
                    .opacity(on ? 1 : 0.45)
                    .help(clashing.isEmpty
                          ? ""
                          : IadenteL10n.t("与「\(clashing.joined(separator: "、"))」冲突",
                                          "Conflicts with \(clashing.joined(separator: ", "))"))
            } else {
                Text(IadenteL10n.t("已禁用", "Disabled"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button(IadenteL10n.t("修改", "Edit")) { beginCapture(entry) }
                .controlSize(.small)
            Button(IadenteL10n.t("重置", "Reset")) { model.resetHotkey(entry.key) }
                .controlSize(.small)
                .font(.caption2)

            Toggle("", isOn: hotkeyEnabledBinding(entry.key))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(colors.first ?? IadenteTheme.jade)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity)
    }

    private func hotkeyEnabledBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { model.config.enabledHotkeys[key] ?? true },
            set: { model.setHotkeyEnabled(key, $0) }
        )
    }

    private func beginCapture(_ entry: EditableHotkey) {
        model.registry.hotkeys.suspend()
        captureTarget = HotkeyCaptureTarget(id: entry.key, label: entry.label)
    }

    private func resetAll() {
        for entry in visibleEntries { model.resetHotkey(entry.key) }
    }

    // MARK: - 数据

    /// 全 App 的快捷键键名（默认键 + 用户自定义键），已按语义顺序排好。
    ///
    /// 冲突检测必须扫描**全部**键而不是本卡片的键，否则「窗口吸附」和「显示器控制」
    /// 撞同一个组合时两张卡片都以为自己没问题。
    private func allHotkeyKeys() -> [String] {
        let defaults = Configuration.defaultHotkeys()
        let custom = model.config.hotkeys.keys.filter { defaults[$0] == nil }
        return orderedHotkeyKeys(custom: Array(custom))
    }

    private var visibleEntries: [EditableHotkey] {
        allHotkeyKeys()
            .filter { key in keyPrefixes.contains(where: { key.hasPrefix($0) }) }
            .map { key in
                EditableHotkey(
                    key: key,
                    label: Configuration.label(for: key),
                    icon: hotkeyIcon(for: key)
                )
            }
    }

    /// 录制表单要拿到 **全 App** 的占用情况，否则跨模块撞键时录得进去却互相打架。
    private var currentAssignments: [(key: String, label: String, spec: HotkeySpec)] {
        allHotkeyKeys().compactMap { key in
            guard let spec = model.config.hotkeys[key] else { return nil }
            return (key: key, label: Configuration.label(for: key), spec: spec)
        }
    }

    /// 与 `key` 撞同一组合的其他功能名（**跨模块**扫描，不局限于当前卡片）。
    private func conflictPartners(for key: String, spec: HotkeySpec) -> [String] {
        let combo = spec.toCombo()
        return allHotkeyKeys().compactMap { other in
            guard other != key,
                  let otherSpec = model.config.hotkeys[other],
                  otherSpec.toCombo() == combo
            else { return nil }
            return Configuration.label(for: other)
        }
    }

    /// 本卡片内任何一行与全 App 其他快捷键撞车时给出的横幅提示。
    private var duplicateMessage: String? {
        var lines: [String] = []
        for entry in visibleEntries {
            guard let spec = model.config.hotkeys[entry.key] else { continue }
            let partners = conflictPartners(for: entry.key, spec: spec)
            guard !partners.isEmpty else { continue }
            lines.append(IadenteL10n.t(
                "\(describeHotkey(spec))：「\(entry.label)」与「\(partners.joined(separator: "、"))」重复",
                "\(describeHotkey(spec)): \(entry.label) clashes with \(partners.joined(separator: ", "))"))
        }
        guard !lines.isEmpty else { return nil }
        return IadenteL10n.t("快捷键冲突，后注册的那个不会生效：\n", "Hotkey conflict — the later one won't fire:\n")
            + lines.joined(separator: "\n")
    }

    private struct EditableHotkey: Identifiable {
        let key: String
        let label: String
        let icon: String
        var id: String { key }
    }
}

// MARK: - 快捷键录制表单（移植自 HotkeysSettingsView）

private struct HotkeyCaptureTarget: Identifiable {
    let id: String
    let label: String
}

private struct HotkeyCaptureSheet: View {
    let target: HotkeyCaptureTarget
    let existing: [(key: String, label: String, spec: HotkeySpec)]
    let onCommit: (HotkeySpec) -> Void
    let onCancel: () -> Void

    @State private var liveFlags: UInt32 = 0
    @State private var message: String = ""
    @State private var isError: Bool = false
    @State private var keyMonitor: Any?
    @State private var flagMonitor: Any?

    var body: some View {
        VStack(spacing: 12) {
            Text(IadenteL10n.t("设置快捷键", "Set Hotkey")).font(.headline)
            Text(target.label).font(.subheadline).foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.controlBackgroundColor))
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isError ? Color.orange : Color.accentColor.opacity(0.55), lineWidth: 1.5)
                if liveFlags == 0 {
                    Text(IadenteL10n.t("请按下新的快捷键组合…", "Press the new shortcut combination…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Text(modifierSymbols(liveFlags))
                            .font(.system(size: 26, weight: .medium))
                        Text("+ ?")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 300, height: 56)

            Text(message.isEmpty
                 ? IadenteL10n.t("先按住修饰键（⌃ ⌥ ⇧ ⌘），再按字母/数字/方向键", "Hold a modifier (⌃ ⌥ ⇧ ⌘) first, then a letter/number/arrow key")
                 : message)
                .font(.caption)
                .foregroundStyle(isError ? .orange : .secondary)
                .multilineTextAlignment(.center)
                .frame(width: 300, height: 30)

            Button(IadenteL10n.t("取消（Esc）", "Cancel (Esc)")) { onCancel() }
                .controlSize(.small)
        }
        .padding(24)
        .frame(width: 360, height: 250)
        .onAppear(perform: installMonitors)
        .onDisappear(perform: removeMonitors)
    }

    private func installMonitors() {
        flagMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            liveFlags = UInt32(event.modifierFlags.rawValue) & RELEVANT_MODS
            if liveFlags != 0 { isError = false; message = "" }
            return event
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                onCancel()
                return nil
            }
            let flags = UInt32(event.modifierFlags.rawValue) & RELEVANT_MODS
            liveFlags = flags

            guard flags != 0 else {
                isError = true
                message = IadenteL10n.t("至少要包含一个修饰键（⌃ ⌥ ⇧ ⌘）", "Must include at least one modifier (⌃ ⌥ ⇧ ⌘)")
                return nil
            }
            let spec = HotkeySpec(keyCode: event.keyCode, flags: flags)

            if let clash = existing.first(where: {
                $0.key != target.id && $0.spec == spec
            }) {
                isError = true
                message = IadenteL10n.t("\(describeHotkey(spec)) 已被「\(clash.label)」占用，请换一个组合", "\(describeHotkey(spec)) is taken by \"\(clash.label)\"; pick another combo")
                return nil
            }

            onCommit(spec)
            return nil
        }
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = flagMonitor { NSEvent.removeMonitor(m); flagMonitor = nil }
    }
}

// MARK: - 排序 / 图标 / 修饰键 / 描述

/// 快捷键行的**语义顺序**。
///
/// 以前这里直接 `keys.sorted()` 按字母排，于是窗口吸附卡片里变成
/// 「下半屏 / 左下 / 右下 / 居中 / 中1/3 / 左半屏 / 左1/3 / 最大化 / 还原 / 右半屏 …」
/// 这种毫无逻辑的顺序，而卡片下方的布局缩略图又是按「半屏→四角→三分→整屏」排的，
/// 两边对不上，看起来就是乱的。这张表把顺序钉死成人脑预期的那一种。
/// 表里没有的键（用户自定义 / 新增未登记）排在最后，仍按字母序保证稳定。
private let hotkeyDisplayOrder: [String] = [
    // 吸附：半屏 → 四角 → 三分 → 整屏 / 居中 / 还原
    "snap.leftHalf", "snap.rightHalf", "snap.topHalf", "snap.bottomHalf",
    "snap.topLeft", "snap.topRight", "snap.bottomLeft", "snap.bottomRight",
    "snap.leftThird", "snap.centerThird", "snap.rightThird",
    "snap.leftTwoThirds", "snap.rightTwoThirds",
    "snap.maximize", "snap.center", "snap.restore",
    // 隐藏 / 显示
    "hide.all", "show.all", "hide.others",
    // 跨屏
    "display.prev", "display.next",
    // 布局场景
    "layout.save", "layout.restore",
    // 电源与外观
    "power.lock", "power.sleep", "power.displaySleep", "power.toggleDark",
    // 显示器控制
    "ddc.brightnessUp", "ddc.brightnessDown", "ddc.volumeUp", "ddc.volumeDown",
    "keyboardclean.toggle",
]

/// 全 App 的快捷键键名，按语义顺序排好（默认键 + 用户自定义键）。
private func orderedHotkeyKeys(custom: [String]) -> [String] {
    let defaults = Configuration.defaultHotkeys()
    let all = Set(defaults.keys).union(custom)
    let ranked = hotkeyDisplayOrder.enumerated().reduce(into: [String: Int]()) { $0[$1.element] = $1.offset }
    return all.sorted { a, b in
        switch (ranked[a], ranked[b]) {
        case let (ra?, rb?): return ra < rb
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a < b
        }
    }
}

private func hotkeyIcon(for key: String) -> String {
    switch key {
    case "snap.leftHalf": return "rectangle.lefthalf.inset.fill"
    case "snap.rightHalf": return "rectangle.righthalf.inset.fill"
    case "snap.topHalf": return "rectangle.tophalf.inset.fill"
    case "snap.bottomHalf": return "rectangle.bottomhalf.inset.fill"
    case "snap.topLeft": return "rectangle.inset.topleft.filled"
    case "snap.topRight": return "rectangle.inset.topright.filled"
    case "snap.bottomLeft": return "rectangle.inset.bottomleft.filled"
    case "snap.bottomRight": return "rectangle.inset.bottomright.filled"
    case "snap.leftThird", "snap.centerThird", "snap.rightThird",
         "snap.leftTwoThirds", "snap.rightTwoThirds": return "rectangle.split.3x1"
    case "snap.maximize": return "arrow.up.left.and.arrow.down.right"
    case "snap.center": return "square.dashed"
    case "snap.restore": return "arrow.uturn.backward"
    case "hide.others": return "eye.slash"
    case "hide.all": return "eye.slash.fill"
    case "show.all": return "eye.fill"
    case "display.next", "display.prev": return "display.2"
    case "switcher.show": return "macwindow.on.rectangle"
    case "clipboard.show": return "doc.on.clipboard"
    case "clipboardocr.run": return "text.viewfinder"
    case "layout.save": return "square.and.arrow.down"
    case "layout.restore": return "arrow.clockwise"
    case "layout.picker": return "square.stack.3d.up"
    case "power.lock": return "lock.fill"
    case "power.sleep": return "moon.zzz.fill"
    case "power.displaySleep": return "display.trianglebadge.exclamationmark"
    case "power.toggleDark": return "circle.lefthalf.filled"
    case "snippets.show": return "text.cursor"
    case "qr.show": return "qrcode"
    case "colorpicker.pick": return "eyedropper"
    case "volume.mute": return "speaker.slash.fill"
    case "inputswitcher.cycle": return "waveform"
    case "alwaysontop.toggle": return "pin.fill"
    case "magnifier.toggle": return "magnifyingglass"
    case "keyboardclean.toggle": return "keyboard.badge.ellipsis.fill"
    case "hide.current": return "eye.slash.fill"
    case "ddc.brightnessUp": return "sun.max.fill"
    case "ddc.brightnessDown": return "sun.min.fill"
    case "ddc.volumeUp": return "speaker.wave.2.fill"
    case "ddc.volumeDown": return "speaker.wave.1.fill"
    default: return "command"
    }
}

private func describeHotkey(_ spec: HotkeySpec) -> String {
    modifierSymbols(spec.flags) + KeyNames.display(for: spec.keyCode)
}
