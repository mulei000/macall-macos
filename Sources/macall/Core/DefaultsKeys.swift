import AppKit
import Foundation
import SwiftUI

enum IadenteRuntime {
    static let isUIPreview = CommandLine.arguments.contains("--ui-preview")
}

enum AppLanguage: String, Defaults.Serializable, CaseIterable, Identifiable {
    case system
    case simplifiedChinese
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: IadenteL10n.t("跟随系统", "System")
        case .simplifiedChinese: IadenteL10n.t("中文", "Chinese")
        case .english: IadenteL10n.t("英文", "English")
        }
    }
}

enum AppearanceMode: String, Defaults.Serializable, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: IadenteL10n.t("日间", "Light")
        case .dark: IadenteL10n.t("夜间", "Dark")
        case .system: IadenteL10n.t("跟随系统", "System")
        }
    }

    var icon: String {
        switch self {
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        case .system: "circle.lefthalf.filled"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }
}

enum PercentageDisplayLocation: String, Defaults.Serializable, CaseIterable, Identifiable {
    case hidden
    case nextToIcon
    case insideIcon

    var id: String { rawValue }
}

/// 弹窗（菜单栏下拉面板）中的可定制模块。
/// 顺序由 `dashboardSectionOrder` 控制，是否显示由 `dashboardHiddenSections` 控制。
enum DashboardSection: String, Defaults.Serializable, CaseIterable, Identifiable {
    case hero
    case batteryOverview
    case powerFlow
    case energyApps
    case quickLinks
    case systemStatus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hero: IadenteL10n.t("电源状态卡片")
        case .batteryOverview: IadenteL10n.t("电池概览")
        case .powerFlow: IadenteL10n.t("实时功率分流")
        case .energyApps: IadenteL10n.t("当前耗电应用")
        case .quickLinks: IadenteL10n.t("快捷入口")
        case .systemStatus: IadenteL10n.t("系统状态")
        }
    }

    var subtitle: String {
        switch self {
        case .hero: IadenteL10n.t("顶部主状态卡片：电源、电池或充电")
        case .batteryOverview: IadenteL10n.t("健康度、循环次数与剩余时间")
        case .powerFlow: IadenteL10n.t("电源、电池与系统之间的能量流向")
        case .energyApps: IadenteL10n.t("按处理器活动估算的耗电排行")
        case .quickLinks: IadenteL10n.t("跳转到设置详情", "Jump to Settings Details")
        case .systemStatus: IadenteL10n.t("内存、磁盘、温度、风扇、网速与 CPU 占用")
        }
    }

    var icon: String {
        switch self {
        case .hero: "powerplug.fill"
        case .batteryOverview: "battery.75percent"
        case .powerFlow: "point.3.connected.trianglepath.dotted"
        case .energyApps: "bolt.horizontal.circle.fill"
        case .quickLinks: "arrow.up.right.square"
        case .systemStatus: "gearshape.2.fill"
        }
    }

    var colors: [Color] {
        switch self {
        case .hero: [IadenteTheme.jade, IadenteTheme.ocean]
        case .batteryOverview: [IadenteTheme.violet, IadenteTheme.pink]
        case .powerFlow: [IadenteTheme.amber, IadenteTheme.gold]
        case .energyApps: [IadenteTheme.ocean, IadenteTheme.sky]
        case .quickLinks: [IadenteTheme.coral, IadenteTheme.amber]
        case .systemStatus: [IadenteTheme.violet, IadenteTheme.pink]
        }
    }
}

/// 「系统状态」模块内的单项指标。是否显示由 `systemStatusHiddenMetrics` 控制。
enum SystemStatusMetric: String, Defaults.Serializable, CaseIterable, Identifiable {
    case memory
    case disk
    case cpuTemp
    case fan
    case network
    case cpu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .memory: IadenteL10n.t("内存占用")
        case .disk: IadenteL10n.t("磁盘空间")
        case .cpuTemp: IadenteL10n.t("CPU 温度")
        case .fan: IadenteL10n.t("风扇转速")
        case .network: IadenteL10n.t("网络速度")
        case .cpu: IadenteL10n.t("CPU 占用")
        }
    }

    var subtitle: String {
        switch self {
        case .memory: IadenteL10n.t("已用 / 总量（GB）")
        case .disk: IadenteL10n.t("剩余 / 总量（GB）")
        case .cpuTemp: IadenteL10n.t("通过 SMC 读取（°C）")
        case .fan: IadenteL10n.t("通过 SMC 读取（RPM）")
        case .network: IadenteL10n.t("上行 / 下行（MB/s）")
        case .cpu: IadenteL10n.t("处理器活跃度（%）")
        }
    }

    /// 紧凑卡片（小框）使用的简短标签。仅英文模式用缩写，中文保持原样，
    /// 避免 "Memory Usage" 等长词在小框里被压缩换行。
    var shortTitle: String {
        guard IadenteL10n.isEnglish else { return title }
        switch self {
        case .memory: return "MEM"
        case .disk: return "DISK"
        case .cpuTemp: return "TEMP"
        case .fan: return "FAN"
        case .network: return "NET"
        case .cpu: return "CPU"
        }
    }

    var icon: String {
        switch self {
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .cpuTemp: "thermometer.medium"
        case .fan: "fan.fill"
        case .network: "network"
        case .cpu: "cpu"
        }
    }

    var colors: [Color] {
        switch self {
        case .memory: [IadenteTheme.violet, IadenteTheme.pink]
        case .disk: [IadenteTheme.ocean, IadenteTheme.sky]
        case .cpuTemp: [IadenteTheme.amber, IadenteTheme.gold]
        case .fan: [IadenteTheme.mint, IadenteTheme.jade]
        case .network: [IadenteTheme.pink, IadenteTheme.coral]
        case .cpu: [IadenteTheme.coral, IadenteTheme.amber]
        }
    }

    var tint: Color { colors.first ?? IadenteTheme.jade }
}

enum StatusBarModule: String, Defaults.Serializable, CaseIterable, Identifiable {
    case batteryIcon
    case batteryPercentage
    case systemPower
    case cpuTemp
    case cpu
    case memory
    case disk
    case fan
    case network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .batteryIcon: IadenteL10n.t("电池图标")
        case .batteryPercentage: IadenteL10n.t("实时电量")
        case .systemPower: IadenteL10n.t("实时功率")
        case .cpuTemp: IadenteL10n.t("CPU 温度")
        case .cpu: IadenteL10n.t("CPU 占用")
        case .memory: IadenteL10n.t("内存占用")
        case .disk: IadenteL10n.t("磁盘空间")
        case .fan: IadenteL10n.t("风扇转速")
        case .network: IadenteL10n.t("网络速度")
        }
    }

    var icon: String {
        switch self {
        case .batteryIcon: "battery.75percent"
        case .batteryPercentage: "percent"
        case .systemPower: "bolt.fill"
        case .cpuTemp: "thermometer.medium"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .fan: "fan.fill"
        case .network: "network"
        }
    }

    var subtitle: String {
        switch self {
        case .batteryIcon: IadenteL10n.t("菜单栏主图标")
        case .batteryPercentage: IadenteL10n.t("百分比数字")
        case .systemPower: IadenteL10n.t("系统实时功耗")
        case .cpuTemp: IadenteL10n.t("状态栏显示 CPU 温度")
        case .cpu: IadenteL10n.t("状态栏显示 CPU 使用率")
        case .memory: IadenteL10n.t("状态栏显示已用内存")
        case .disk: IadenteL10n.t("状态栏显示剩余磁盘空间")
        case .fan: IadenteL10n.t("状态栏显示风扇转速")
        case .network: IadenteL10n.t("状态栏显示实时网速")
        }
    }
}

/// 音量状态栏弹窗内各模块的枚举。
/// 顺序由 `volumeModuleOrder` 控制，是否显示由 `volumeHiddenModules` 控制。
/// `master`（主音量）为强制常驻模块，不可隐藏（见 `canHide`）。
enum VolumeModule: String, Defaults.Serializable, CaseIterable, Identifiable {
    case master      // 主音量（不可隐藏）
    case input       // 输入设备（麦克风）
    case output      // 输出设备切换
    case app         // App 音量

    var id: String { rawValue }

    var title: String {
        switch self {
        case .master: IadenteL10n.t("主音量")
        case .input:  IadenteL10n.t("输入设备")
        case .output: IadenteL10n.t("输出设备")
        case .app:    IadenteL10n.t("App 音量")
        }
    }

    var icon: String {
        switch self {
        case .master: "speaker.wave.2.fill"
        case .input:  "mic.fill"
        case .output: "airplayaudio"
        case .app:    "app.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .master: IadenteL10n.t("整体音量、静音与设备概览")
        case .input:  IadenteL10n.t("麦克风输入与默认设备")
        case .output: IadenteL10n.t("切换系统输出设备")
        case .app:    IadenteL10n.t("逐应用音量调节")
        }
    }

    /// 是否允许用户隐藏。主音量必须常驻，返回 false；其余模块可隐藏。
    var canHide: Bool {
        switch self {
        case .master: return false
        case .input, .output, .app: return true
        }
    }
}

/// 工具箱（常驻状态栏图标）面板里可点击启动的小工具。
/// 顺序由 `toolboxOrder` 控制，是否显示由 `toolboxHidden` 控制。
enum ToolboxTool: String, Defaults.Serializable, CaseIterable, Identifiable {
    case magnifier
    case colorpicker
    case snippets
    case qr
    case keyboardclean
    case clipboardocr
    case hotkeycheatsheet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .magnifier:    IadenteL10n.t("屏幕放大镜", "Screen Magnifier")
        case .colorpicker:  IadenteL10n.t("屏幕取色", "Color Picker")
        case .snippets:     IadenteL10n.t("文字片段", "Snippets")
        case .qr:           IadenteL10n.t("二维码", "QR Code")
        case .keyboardclean: IadenteL10n.t("清洁模式", "Clean Mode")
        case .clipboardocr: IadenteL10n.t("剪贴板 OCR", "Clipboard OCR")
        case .hotkeycheatsheet: IadenteL10n.t("快捷键速览", "Hotkey Cheatsheet")
        }
    }

    var icon: String {
        switch self {
        case .magnifier:    "magnifyingglass"
        case .colorpicker:  "eyedropper"
        case .snippets:     "text.cursor"
        case .qr:           "qrcode"
        case .keyboardclean: "keyboard.badge.ellipsis.fill"
        case .clipboardocr: "text.viewfinder"
        case .hotkeycheatsheet: "keyboard"
        }
    }

    var subtitle: String {
        switch self {
        case .magnifier:    IadenteL10n.t("跟随光标放大屏幕局部", "Magnify a region that follows the cursor")
        case .colorpicker:  IadenteL10n.t("吸取屏幕任意像素颜色", "Pick any pixel color on screen")
        case .snippets:     IadenteL10n.t("一键打出常用文字模板", "Type canned text snippets instantly")
        case .qr:           IadenteL10n.t("把文本 / 网址生成二维码", "Generate a QR code from text or a URL")
        case .keyboardclean: IadenteL10n.t("锁定键盘方便擦灰", "Lock the keyboard to wipe it")
        case .clipboardocr: IadenteL10n.t("识别剪贴板里图片中的文字并回写", "Recognize text in a clipboard image and copy it back")
        case .hotkeycheatsheet: IadenteL10n.t("弹出浮层查看所有已启用快捷键", "Pop a panel listing every enabled hotkey")
        }
    }

    /// 点击该工具时在 FeatureRegistry 上派发的动作（对应各功能的 `handle(action:)`）。
    var launchAction: String {
        switch self {
        case .magnifier:    "toggle"
        case .colorpicker:  "pick"
        case .snippets:     "show"
        case .qr:           "show"
        case .keyboardclean: "toggle"
        case .clipboardocr: "run"
        case .hotkeycheatsheet: "show"
        }
    }
}

enum InterfaceMaterialStyle: String, Defaults.Serializable, CaseIterable, Identifiable {
    case solid
    case glass
    case frosted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solid: IadenteL10n.t("清晰实体")
        case .glass: IadenteL10n.t("毛玻璃")
        case .frosted: IadenteL10n.t("高斯柔化")
        }
    }

    var subtitle: String {
        switch self {
        case .solid: IadenteL10n.t("最高文字对比度")
        case .glass: IadenteL10n.t("平衡透明度与清晰度")
        case .frosted: IadenteL10n.t("更明显的背景虚化")
        }
    }

    var icon: String {
        switch self {
        case .solid: "rectangle.fill"
        case .glass: "square.on.square"
        case .frosted: "aqi.medium"
        }
    }
}

/// 状态栏弹窗（菜单栏下拉面板）的尺寸档位。
/// 仅影响**高度（长度）**，宽度固定为 320；底部「设置 / 刷新」栏始终固定显示。
enum PopoverSize: String, Defaults.Serializable, CaseIterable, Identifiable {
    case small
    case medium
    case auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: IadenteL10n.t("小", "Small")
        case .medium: IadenteL10n.t("中", "Medium")
        // rawValue 仍是 "auto"（改了会让老用户的偏好失效），但语义已明确为「大」：
        // 完整显示所有已开启的状态模块，只在触到 Dock 上缘时才封顶并转为滚动。
        case .auto: IadenteL10n.t("大", "Large")
        }
    }

    /// 内容区（不含固定底部栏）的最大高度。
    /// 「大」档不在这里封顶——真正的上限是运行时算出的「状态栏到 Dock 上缘」的可用高度，
    /// 由 StatusBarManager 通过 `maxContentHeight` 传入 DashboardPopoverView。
    var contentRegionMaxHeight: CGFloat {
        switch self {
        case .small: return 300
        case .medium: return 480
        case .auto: return .infinity
        }
    }
}

/// 窗口切换（Tab 预览）的触发键预设。
///
/// 只保留三个选项：
/// - `optionTab`：Option+Tab，不与系统冲突。
/// - `commandTab`：接管 macOS 系统原生的 ⌘Tab 应用切换器。
/// - `custom`：用户在设置里手动录制的其它组合键（落到 `switcher.show` 的自定义值）。
enum SwitcherTriggerPreset: String, Defaults.Serializable, CaseIterable, Identifiable {
    case optionTab
    case commandTab        // 接管系统原生 ⌘Tab
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optionTab: IadenteL10n.t("Option+Tab", "Option+Tab")
        case .commandTab: IadenteL10n.t("接管 ⌘Tab（系统原生）", "Take over ⌘Tab (native)")
        case .custom: IadenteL10n.t("自定义", "Custom")
        }
    }

    /// 对应快捷键组合；custom 无预设，返回 nil（改用 `switcher.show` 的自定义值）。
    var combo: HotkeyCombo? {
        switch self {
        case .optionTab:
            return HotkeyCombo(keyCode: VK.tab, flags: UInt32(F_OPT.rawValue))
        case .commandTab:
            return HotkeyCombo(keyCode: VK.tab, flags: UInt32(F_CMD.rawValue))
        case .custom:
            return nil
        }
    }
}

extension Defaults.Keys {
    // General
    static let appLanguage = Key<AppLanguage>("appLanguage", default: .system)
    static let appearanceMode = Key<AppearanceMode>("appearanceMode", default: .system)
    static let launchAtLogin = Key<Bool>("launchAtLogin", default: false)

    /// 是否在 Dock 中显示 macall 图标。
    ///
    /// Info.plist 里 `LSUIElement=true` 只是**启动时**的初值（保证冷启动不闪 Dock 图标），
    /// 真正生效的是运行时的 `NSApp.setActivationPolicy(.regular/.accessory)`。
    /// 默认开启：纯菜单栏应用找不到「设置在哪打开」是最常见的上手障碍。
    static let showDockIcon = Key<Bool>("showDockIcon", default: true)
    static let interfaceMaterialStyle = Key<InterfaceMaterialStyle>(
        "interfaceMaterialStyle", default: .solid)

    // Status bar popup size (height only; width is fixed). Footer always pinned.
    static let popoverSize = Key<PopoverSize>("popoverSize", default: .auto)

    // Status Icon
    static let batteryPercentageDisplayLocation = Key<PercentageDisplayLocation>(
        "batteryPercentageDisplayLocation", default: .insideIcon)
    static let showBatteryStateInStatusIcon = Key<Bool>(
        "showBatteryStateInStatusIcon", default: true)

    // Status Bar Modules
    // SMC 已接入：vendored SMCKit 通过 IOKit 直连 AppleSMC（无需特权 Helper），
    // 实时功率与 CPU 温度读数与 macometer 一致。风扇在无风扇机型上无读数，
    // 默认隐藏以免状态栏出现常驻「—」；其余 SMC 模块默认显示。
    static let statusBarModuleOrder = Key<[StatusBarModule]>(
        "statusBarModuleOrder",
        default: [.batteryIcon, .batteryPercentage, .systemPower,
                  .cpuTemp, .cpu, .memory, .disk, .fan, .network])
    static let statusBarHiddenModules = Key<[StatusBarModule]>(
        "statusBarHiddenModules",
        default: [.fan])

    // 独立音量菜单栏图标（喇叭形）：与系统监控模块解耦，由自身开关控制显隐。
    static let showVolumeStatusBarIcon = Key<Bool>(
        "showVolumeStatusBarIcon", default: true)

    // 音量状态栏弹窗模块（顺序 + 显隐）
    // `master`（主音量）为常驻模块，永远不进入 hiddenModules。
    static let volumeModuleOrder = Key<[VolumeModule]>(
        "volumeModuleOrder",
        default: [.master, .input, .output, .app])
    static let volumeHiddenModules = Key<[VolumeModule]>(
        "volumeHiddenModules",
        default: [])

    // 工具箱（常驻状态栏图标）面板内容管理
    static let showToolboxIcon = Key<Bool>("showToolboxIcon", default: true)
    static let toolboxOrder = Key<[ToolboxTool]>(
        "toolboxOrder", default: ToolboxTool.allCases)
    static let toolboxHidden = Key<[ToolboxTool]>(
        "toolboxHidden", default: [])
    // 键盘清洁：自动退出倒计时（秒）
    static let cleanCountdownSeconds = Key<Int>("cleanCountdownSeconds", default: 60)
    // 清洁模式：进入时是否自动熄屏（黑屏看灰尘），默认开
    static let cleanAutoDisplaySleep = Key<Bool>("cleanAutoDisplaySleep", default: true)

    // 菜单栏图标显示偏好（次级开关）：仅在「系统监控」总开关开启时生效。
    // 实际显隐 = monitor 启用 且 此键为 true；monitor 关闭时图标强制隐藏。
    static let statusBarIconVisible = Key<Bool>(
        "statusBarIconVisible", default: true)

    // System Status metrics (order inside the 系统状态 module)
    static let systemStatusMetricOrder = Key<[SystemStatusMetric]>(
        "systemStatusMetricOrder", default: SystemStatusMetric.allCases)

    // Notifications
    static let disableNotifications = Key<Bool>("disableNotifications", default: false)

    // Threshold-based notifications
    static let notifyCpuTempEnabled = Key<Bool>("notifyCpuTempEnabled", default: false)
    static let cpuTempThreshold = Key<Double>("cpuTempThreshold", default: 80)

    static let notifyPowerEnabled = Key<Bool>("notifyPowerEnabled", default: false)
    static let powerThreshold = Key<Double>("powerThreshold", default: 60)

    static let notifyRamEnabled = Key<Bool>("notifyRamEnabled", default: false)
    static let ramThreshold = Key<Double>("ramThreshold", default: 85)

    static let notifyStorageEnabled = Key<Bool>("notifyStorageEnabled", default: false)
    static let storageThreshold = Key<Double>("storageThreshold", default: 90)

    // Menu Dashboard
    static let dashboardSectionOrder = Key<[DashboardSection]>(
        "dashboardSectionOrder",
        default: DashboardSection.allCases
    )
    // 实时功率分流 / 耗电 App 排行 现已可用：功率来自 SMC 直连，耗电排行来自
    // 无特权的 CPU 活动聚合，均不再依赖特权 Helper，默认全部显示。
    static let dashboardHiddenSections = Key<[DashboardSection]>(
        "dashboardHiddenSections",
        default: []
    )
    // CPU 温度现已由 SMC 直连读出；风扇在无风扇机型无读数，默认隐藏避免「—」。
    static let systemStatusHiddenMetrics = Key<[SystemStatusMetric]>(
        "systemStatusHiddenMetrics",
        default: [.fan]
    )
    static let showTimeTillDischarge = Key<Bool>("showTimeTillDischarge", default: true)
    static let showBatteryCycleCount = Key<Bool>("showBatteryCycleCount", default: true)
    static let showBatteryHealth = Key<Bool>("showBatteryHealth", default: true)
    static let showBatteryTemperature = Key<Bool>("showBatteryTemperature", default: false)
    static let showPowerSource = Key<Bool>("showPowerSource", default: false)
    static let showUptime = Key<Bool>("showUptime", default: true)
    static let showBatteryMode = Key<Bool>("showBatteryMode", default: true)
    static let showInternalPower = Key<Bool>("showInternalPower", default: true)
    static let showExternalPower = Key<Bool>("showExternalPower", default: true)
    static let showPowerDistribution = Key<Bool>("showPowerDistribution", default: false)

    // Advanced
    static let useHardwarePercentage = Key<Bool>("useHardwarePercentage", default: false)

    // Screenshot / Screen Recording (ScreenCaptureKit)
    static let screenshotSaveDirectory = Key<String>(
        "screenshotSaveDirectory",
        default: (NSHomeDirectory() as NSString).appendingPathComponent("Desktop"))
    static let screenshotImageFormat = Key<String>("screenshotImageFormat", default: "png") // png | jpeg | heic
    static let screenshotIncludeCursor = Key<Bool>("screenshotIncludeCursor", default: true)
    static let screenshotShowThumbnail = Key<Bool>("screenshotShowThumbnail", default: true)
    static let screenshotRecordingFormat = Key<String>("screenshotRecordingFormat", default: "mov") // mov | mp4
    static let screenshotRecordingQuality = Key<String>("screenshotRecordingQuality", default: "high") // low | medium | high
}
