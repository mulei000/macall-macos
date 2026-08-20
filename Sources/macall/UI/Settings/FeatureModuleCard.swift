import SwiftUI

// MARK: - 功能模块元数据（单一事实来源）

/// 一个功能模块在设置界面里的展示信息。
/// 原先散落在「功能」总览页里的图标 / 说明 / 快捷键前缀集中到这里，
/// 各模块设置页只需引用 id，样式与文案自动一致。
struct FeatureMeta {
    let icon: String
    let colors: [Color]
    let subtitle: String
    /// 该模块下属快捷键的 key 前缀（空数组表示此模块没有快捷键）。
    let hotkeyPrefixes: [String]
}

enum FeatureCatalog {
    static func meta(_ id: String) -> FeatureMeta {
        switch id {
        // —— 系统监控 ——
        case "monitor":
            return FeatureMeta(
                icon: "gauge.with.dots.needle.67percent",
                colors: IadenteTheme.dashboardColors,
                subtitle: IadenteL10n.t(
                    "在菜单栏与弹窗显示电量、CPU、内存、磁盘、网速等状态",
                    "Show battery, CPU, memory, disk and network in the menu bar"),
                hotkeyPrefixes: [])

        // —— 窗口管理 ——
        case "windowSnap":
            return FeatureMeta(
                icon: "rectangle.split.2x2",
                colors: IadenteTheme.generalColors,
                subtitle: IadenteL10n.t(
                    "把窗口吸附到屏幕各区域：左右上下 / 四角 / 三等分 / 最大化 / 居中 / 还原",
                    "Snap windows to halves, quarters, thirds, maximize, center or restore"),
                hotkeyPrefixes: ["snap."])
        case "hideWindows":
            return FeatureMeta(
                icon: "eye.slash.fill",
                colors: IadenteTheme.generalColors,
                subtitle: IadenteL10n.t(
                    "隐藏全部窗口露出桌面、隐藏其他窗口、隐藏当前窗口，以及一键把隐藏的窗口全部还原",
                    "Hide all windows to reveal the desktop, hide others, hide the current window, or restore everything"),
                hotkeyPrefixes: ["hide.", "show."])
        case "displayMove":
            return FeatureMeta(
                icon: "display.2",
                colors: IadenteTheme.generalColors,
                subtitle: IadenteL10n.t(
                    "用快捷键把当前窗口整块搬到上一块 / 下一块显示器",
                    "Move the focused window to the previous / next display"),
                hotkeyPrefixes: ["display."])
        case "alwaysontop":
            return FeatureMeta(
                icon: "pin.fill",
                colors: IadenteTheme.generalColors,
                subtitle: IadenteL10n.t(
                    "把最前台窗口钉在所有窗口之上，再按一次取消",
                    "Pin the frontmost window above all others; press again to unpin"),
                hotkeyPrefixes: ["alwaysontop."])
        case "edgeSnap":
            return FeatureMeta(
                icon: "rectangle.dock",
                colors: IadenteTheme.generalColors,
                subtitle: IadenteL10n.t(
                    "把窗口拖到屏幕边缘时自动吸附（类似 Windows 贴靠），无需快捷键",
                    "Drag a window to a screen edge to snap it automatically"),
                hotkeyPrefixes: [])
        case "dockToggle":
            return FeatureMeta(
                icon: "dock.rectangle.badge.ellipsis",
                colors: IadenteTheme.generalColors,
                subtitle: IadenteL10n.t(
                    "复刻 Windows 任务栏：点已激活 App 的 Dock 图标收起其全部窗口，再点恢复；点未激活的照常唤起",
                    "Windows-taskbar behaviour: click an active app's Dock icon to minimize all its windows, click again to restore"),
                hotkeyPrefixes: [])
        case "switcher":
            return FeatureMeta(
                icon: "macwindow.on.rectangle",
                colors: IadenteTheme.advancedColors,
                subtitle: IadenteL10n.t(
                    "带缩略图预览的窗口切换面板（类 AltTab），触发键可在下方选择",
                    "AltTab-style window switcher with thumbnails; pick a trigger below"),
                hotkeyPrefixes: ["switcher."])
        case "preview":
            return FeatureMeta(
                icon: "dock.rectangle",
                colors: IadenteTheme.generalColors,
                subtitle: IadenteL10n.t(
                    "鼠标悬停在 Dock 图标上时预览该 App 的所有窗口",
                    "Preview an app's windows when hovering its Dock icon"),
                hotkeyPrefixes: [])
        case "windowlayout":
            return FeatureMeta(
                icon: "square.grid.2x2",
                colors: IadenteTheme.generalColors,
                subtitle: IadenteL10n.t(
                    "按场景记住各 App 的窗口位置与大小，一键保存 / 还原",
                    "Remember every app's window frame per scene; save & restore in one press"),
                hotkeyPrefixes: ["layout."])

        // —— 剪贴板 ——
        case "clipboard":
            return FeatureMeta(
                icon: "doc.on.clipboard",
                colors: IadenteTheme.automationColors,
                subtitle: IadenteL10n.t(
                    "后台记录复制过的文本 / 图片 / 文件，唤起面板点击即粘贴",
                    "Records copied text, images and files; click an entry to paste"),
                hotkeyPrefixes: ["clipboard."])
        case "clipboardocr":
            return FeatureMeta(
                icon: "text.viewfinder",
                colors: IadenteTheme.automationColors,
                subtitle: IadenteL10n.t(
                    "识别剪贴板里图片中的文字（本地 Vision，不联网），结果自动回写剪贴板",
                    "Recognize text in the clipboard image with on-device Vision; result copied back"),
                hotkeyPrefixes: ["clipboardocr."])

        // —— 音频 ——
        case "volume":
            return FeatureMeta(
                icon: "speaker.wave.2.fill",
                colors: IadenteTheme.advancedColors,
                subtitle: IadenteL10n.t(
                    "主输出音量与静音切换，并可逐 App 单独调节音量 / 静音 / 均衡器",
                    "Master volume & mute, plus per-app volume, mute and EQ"),
                hotkeyPrefixes: ["volume."])
        case "devicepriority":
            return FeatureMeta(
                icon: "rectangle.connected.to.line.below",
                colors: IadenteTheme.advancedColors,
                subtitle: IadenteL10n.t(
                    "按优先级自动切换输出设备：插入更靠前的设备时自动设为默认输出",
                    "Auto-switch to the highest-priority online output device"),
                hotkeyPrefixes: [])
        case "outputswitcher":
            return FeatureMeta(
                icon: "arrow.left.arrow.right.circle.fill",
                colors: IadenteTheme.advancedColors,
                subtitle: IadenteL10n.t(
                    "按一个快捷键在扬声器、耳机、显示器等输出设备之间循环切换系统默认输出，不用每次进系统设置。",
                    "Press one hotkey to cycle the system default output between speakers, headphones, displays, etc."),
                hotkeyPrefixes: ["outputswitcher."])
        case "miccontrol":
            return FeatureMeta(
                icon: "mic.slash.fill",
                colors: IadenteTheme.advancedColors,
                subtitle: IadenteL10n.t(
                    "一键切换麦克风静音，并可选定默认输入设备",
                    "Toggle mic mute with a hotkey and pick the default input device"),
                hotkeyPrefixes: ["miccontrol."])
        case "inputswitcher":
            return FeatureMeta(
                icon: "waveform",
                colors: IadenteTheme.advancedColors,
                subtitle: IadenteL10n.t(
                    "按快捷键在全部可用输入设备（麦克风）间循环切换系统默认输入",
                    "Cycle the system default input between all available input devices with a hotkey"),
                hotkeyPrefixes: ["inputswitcher."])
        case "hotkeycheatsheet":
            return FeatureMeta(
                icon: "keyboard",
                colors: IadenteTheme.generalColors,
                subtitle: IadenteL10n.t(
                    "按快捷键弹出浮层，按模块列出所有已启用的快捷键",
                    "Pop a floating panel that lists every enabled hotkey, grouped by module"),
                hotkeyPrefixes: ["hotkeycheatsheet."])

        // —— 显示器与取色 ——
        case "ddc":
            return FeatureMeta(
                icon: "display",
                colors: IadenteTheme.dashboardColors,
                subtitle: IadenteL10n.t(
                    "用快捷键调外接显示器的亮度与音量（亮度走 DisplayServices，音量走 DDC-CI）",
                    "Adjust external monitor brightness & volume via DisplayServices / DDC-CI"),
                hotkeyPrefixes: ["ddc."])
        case "magnifier":
            return FeatureMeta(
                icon: "magnifyingglass",
                colors: IadenteTheme.dashboardColors,
                subtitle: IadenteL10n.t(
                    "跟随光标的屏幕放大镜，用于看清小字与像素（需屏幕录制权限）",
                    "A cursor-following screen magnifier (needs Screen Recording)"),
                hotkeyPrefixes: ["magnifier."])
        case "colorpicker":
            return FeatureMeta(
                icon: "eyedropper",
                colors: IadenteTheme.dashboardColors,
                subtitle: IadenteL10n.t(
                    "唤起系统取色放大镜，吸取屏幕任意像素并把 #RRGGBB 复制到剪贴板",
                    "Pick any pixel on screen and copy its #RRGGBB to the clipboard"),
                hotkeyPrefixes: ["colorpicker."])

        // —— 工具箱 ——
        case "snippets":
            return FeatureMeta(
                icon: "text.cursor",
                colors: IadenteTheme.aboutColors,
                subtitle: IadenteL10n.t(
                    "常用文字模板库（邮箱、地址、签名、话术…），唤起面板点一下就替你打出来",
                    "A library of reusable text snippets; click one and it types itself"),
                hotkeyPrefixes: ["snippets."])
        case "qr":
            return FeatureMeta(
                icon: "qrcode",
                colors: IadenteTheme.aboutColors,
                subtitle: IadenteL10n.t(
                    "把文本 / 网址即时生成二维码，可复制图片或保存为文件",
                    "Turn text or a URL into a QR code; copy or save the image"),
                hotkeyPrefixes: ["qr."])
        case "power":
            return FeatureMeta(
                icon: "power",
                colors: IadenteTheme.aboutColors,
                subtitle: IadenteL10n.t(
                    "锁屏 / 系统睡眠 / 只熄屏 / 切换深色模式",
                    "Lock screen, system sleep, display sleep and dark-mode toggle"),
                hotkeyPrefixes: ["power."])

        // —— 工具箱：清洁模式 ——
        case "keyboardclean":
            return FeatureMeta(
                icon: "keyboard.badge.ellipsis.fill",
                colors: IadenteTheme.aboutColors,
                subtitle: IadenteL10n.t(
                    "锁定键盘并熄屏，方便清洁键盘与屏幕；只有鼠标点击或倒计时能解锁（媒体键一并锁死）",
                    "Lock the keyboard and turn off the display for cleaning; only a mouse click or the countdown unlocks it"),
                hotkeyPrefixes: ["keyboardclean."])

        // —— 触控板手势调节 ——
        case "touchpadControl":
            return FeatureMeta(
                icon: "hand.tap.fill",
                colors: IadenteTheme.dashboardColors,
                subtitle: IadenteL10n.t(
                    "手指从触控板最左 / 最右缘滑入并向内拖动锁定，之后上下移动即可调亮度 / 音量；无需快捷键，也不抢鼠标。",
                    "Swipe in from the left/right trackpad edge and drag inward to lock, then move up/down to adjust brightness/volume — no hotkey, no mouse grab."),
                hotkeyPrefixes: [])

        // —— 鼠标优化 ——
        case "mouseOptimize":
            return FeatureMeta(
                icon: "mouse.fill",
                colors: IadenteTheme.dashboardColors,
                subtitle: IadenteL10n.t(
                    "鼠标滚轮独立反转、参数化惯性平滑（最短步长 / 速度增益 / 平滑时长）、侧键绑定 macall 动作、逐 App 三态例外；只改鼠标、绝不碰触控板，默认全关。光标加速度由系统设置控制。",
                    "Invert the wheel, parametrised inertial smoothing (min step / speed gain / duration), bind side buttons to macall actions, and per-app three-state overrides — mouse only, never the trackpad, all off by default. Cursor acceleration is set in System Settings."),
                hotkeyPrefixes: [])

        default:
            return FeatureMeta(
                icon: "circle.fill",
                colors: IadenteTheme.generalColors,
                subtitle: "",
                hotkeyPrefixes: [])
        }
    }
}

// MARK: - 统一的功能模块卡片

/// 每个功能模块在设置页里的标准外壳：
/// 卡片标题栏 = 图标 + 模块名 + 一句话说明 + **模块总开关**（右上角，全 App 同一位置）；
/// 卡片内容 = 该模块的子功能 / 快捷键行（统一样式）+ 模块专属设置。
///
/// 这样就不再需要一个集中罗列所有模块的「功能」页：开关就在它所属的模块旁边。
struct FeatureModuleCard<Content: View>: View {
    @ObservedObject var model: SettingsModel
    let featureID: String
    /// 覆盖默认标题（不传则取 Feature.title）。
    var title: String? = nil
    /// 覆盖默认说明。
    var subtitle: String? = nil
    /// 是否渲染该模块的快捷键行（无快捷键的模块自动跳过）。
    var showsHotkeys: Bool = true
    /// 覆盖右上角总开关的绑定。少数模块的「开启」不仅是安装功能，
    /// 还要同时写一个配置项（如设备优先级的自动路由），此时传入组合绑定。
    var masterBinding: Binding<Bool>? = nil
    @ViewBuilder var content: Content

    /// 只有总开关 + 快捷键行，没有模块专属设置。
    init(
        model: SettingsModel,
        featureID: String,
        title: String? = nil,
        subtitle: String? = nil,
        showsHotkeys: Bool = true,
        masterBinding: Binding<Bool>? = nil
    ) where Content == EmptyView {
        self.model = model
        self.featureID = featureID
        self.title = title
        self.subtitle = subtitle
        self.showsHotkeys = showsHotkeys
        self.masterBinding = masterBinding
        self.content = EmptyView()
    }

    /// 带模块专属设置。
    init(
        model: SettingsModel,
        featureID: String,
        title: String? = nil,
        subtitle: String? = nil,
        showsHotkeys: Bool = true,
        masterBinding: Binding<Bool>? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.model = model
        self.featureID = featureID
        self.title = title
        self.subtitle = subtitle
        self.showsHotkeys = showsHotkeys
        self.masterBinding = masterBinding
        self.content = content()
    }

    private var meta: FeatureMeta { FeatureCatalog.meta(featureID) }

    private var resolvedTitle: String {
        title ?? model.registry.feature(featureID)?.title ?? featureID
    }

    private var enabled: Bool {
        masterBinding?.wrappedValue ?? model.registry.isEnabled(featureID)
    }

    private var enabledBinding: Binding<Bool> {
        masterBinding ?? Binding(
            get: { model.registry.isEnabled(featureID) },
            set: { model.setFeatureEnabled(featureID, $0) }
        )
    }

    private var prefixes: [String] {
        showsHotkeys ? meta.hotkeyPrefixes : []
    }

    var body: some View {
        IadenteCard(
            resolvedTitle,
            subtitle: subtitle ?? meta.subtitle,
            icon: meta.icon,
            colors: meta.colors,
            trailing: {
                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(meta.colors.first ?? IadenteTheme.jade)
            },
            content: {
                if !prefixes.isEmpty {
                    FeatureHotkeyRows(
                        model: model,
                        keyPrefixes: prefixes,
                        colors: meta.colors,
                        moduleEnabled: enabled
                    )
                }

                content
                    .opacity(enabled ? 1 : 0.4)
                    .disabled(!enabled)
            }
        )
    }
}
