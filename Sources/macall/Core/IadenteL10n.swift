import Foundation

enum IadenteL10n {
    static var isEnglish: Bool {
        switch Defaults[.appLanguage] {
        case .simplifiedChinese:
            return false
        case .english:
            return true
        case .system:
            guard let preferredLanguage = Locale.preferredLanguages.first?
                .lowercased()
            else {
                return true
            }
            return !preferredLanguage.hasPrefix("zh")
        }
    }

    static func t(_ chinese: String) -> String {
        guard isEnglish else { return chinese }
        return english[chinese] ?? chinese
    }

    static func t(_ chinese: String, _ english: String) -> String {
        isEnglish ? english : chinese
    }

    static func controlError(_ text: String) -> String {
        if text.contains("后台控制服务未连接")
            || text.contains("Background control service is not connected")
        {
            return t(
                "后台控制服务未连接。请修复控制服务后重试。",
                "The background control service is not connected. Repair it and try again."
            )
        }
        if text.contains("充电暂停命令未生效")
            || text.contains("pause charging command did not take effect")
        {
            return t(
                "充电暂停命令未生效。请修复控制服务后重试。",
                "The pause charging command did not take effect. Repair the control service and try again."
            )
        }
        if text.contains("适配器控制未生效")
            || text.contains("Adapter control did not take effect")
        {
            return t(
                "适配器控制未生效。请修复控制服务后重试。",
                "Adapter control did not take effect. Repair the control service and try again."
            )
        }
        if text.contains("SMC") {
            return t(
                "SMC 已接受暂停设置，但系统仍报告电池正在充电。请点“修复控制服务”后重试。",
                "SMC accepted the pause setting, but the system still reports charging. Click Repair Control Service and try again."
            )
        }
        return text
    }

    private static let english: [String: String] = [
        "边缘吸附分屏": "Edge Snap",
        "窗口分屏": "Window Snap",
        "场景布局": "Scene Layout",
        "文字片段": "Text Snippets",
        "剪贴板 OCR": "Clipboard OCR",
        "隐藏窗口": "Hide Windows",
        "中文": "Chinese",
        "跟随系统": "System",
        "语言": "Language",
        "切换菜单栏和设置界面的显示语言。": "Follow macOS or choose the language used in the menu bar and settings.",
        "通用": "General",
        "仪表盘": "Dashboard",
        "高级": "Advanced",
        "关于": "About",
        "设置页面": "Settings Page",
        "界面材质": "Interface Material",
        "选择菜单浮层和设置窗口的透明与虚化程度。": "Choose the transparency and blur used by the menu panel and settings window.",
        "英文": "English",
        "状态栏模块": "Status Bar Modules",
        "弹窗模块布局": "Popover Layout",
        "选择 Maconitor 使用日间、夜间或跟随系统外观。": "Choose whether Maconitor uses light, dark, or system appearance.",
        "让 Maconitor 在登录后自动开始工作。": "Launch Maconitor automatically after you log in.",
        "勾选控制显示/隐藏，点击 ↑↓ 调整显示顺序；下方为每个模块的具体设置。": "Toggle to show or hide each module; use ↑↓ to reorder. Module-specific settings are below.",
        "选择弹窗「系统状态」模块显示哪些项目，点击 ↑↓ 调整顺序。": "Choose which items appear in the popover's System Status module; use ↑↓ to reorder.",
        "自定义菜单栏弹窗中显示哪些模块，以及它们的上下顺序。隐藏模块后弹窗会自动缩小，全部显示时自动变大。": "Customize which modules appear in the menu-bar popover and their order. Hiding modules shrinks the popover; showing all expands it.",
        "跳转到设置详情": "Jump to Settings Details",
        "清晰实体": "Solid",
        "毛玻璃": "Glass",
        "高斯柔化": "Frosted",
        "最高文字对比度": "Maximum text contrast",
        "平衡透明度与清晰度": "Balanced transparency and clarity",
        "更明显的背景虚化": "Stronger background blur",
        "启动": "Startup",
        "登录时启动 Maconitor": "Launch Maconitor at Login",
        "登录当前账户后自动显示菜单栏图标": "Show the menu bar icon after signing in",
        "实时电量": "Battery Level",
        "实时功率": "Live Power",
        "电量数字位置": "Battery Number Position",
        "不显示": "Hidden",
        "图标旁": "Next to Icon",
        "图标内": "Inside Icon",
        "用颜色显示电池状态": "Use Color for Battery State",
        "充电、接通电源、低电量使用不同颜色": "Use different colors for charging, plugged in, and low battery",
        "通知": "Notifications",
        "关闭全部通知": "Disable All Notifications",
        "电池健康": "Battery Health",
        "循环次数": "Cycle Count",
        "重复": "Repeat",
        "电量读取方式": "Battery Level Source",
        "使用硬件电量百分比": "Use Hardware Battery Percentage",
        "直接读取电池管理系统的原始数值，而不是 macOS 校准后的显示值": "Read the raw battery management value instead of the macOS-calibrated percentage",
        "为 Apple 芯片 MacBook 打造的独立电池养护工具": "An independent battery care utility for Apple silicon MacBooks",
        "安全说明": "Safety",
        "底层控制始终以设备能力检测和明确授权为前提。": "Low-level control always requires capability checks and explicit authorization.",
        "开放源代码": "Open Source",
        "许可文本和第三方声明均随应用一同提供。": "License text and third-party notices are included with the app.",
        "Maconitor 是基于开源 Stasis 项目修改的 GPL-3.0 软件，并使用 SMCKit 与 Defaults 开源组件。": "Maconitor is GPL-3.0 software based on the open-source Stasis project and uses SMCKit and Defaults.",
        "查看开源许可证": "View Open-Source Licenses",
        "商标声明": "Trademark Notice",
        "独立开发，不包含其他商业软件的代码或授权机制。": "Independently developed without code or licensing mechanisms from other commercial software.",
        "Maconitor 是独立项目，与 AppHouseKitchen 不存在隶属、授权或分发关系。AlDente 是其各自权利人的商标。": "Maconitor is an independent project and is not affiliated with, authorized by, or distributed by AppHouseKitchen. AlDente is a trademark of its respective owner.",
        "正在充电": "Charging",
        "电池": "Battery",
        "电源适配器": "Power Adapter",
        "电池与电源适配器": "Battery & Power Adapter",
        "未在充电": "Not Charging",
        "正在估算…": "Estimating…",
        "已接通电源（未充电）": "Plugged In (Not Charging)",
        "正在使用电池": "On Battery",
        "未知": "Unknown",
        "电源已连接": "Power Connected",
        "实时功率分流": "Live Power Flow",
        "当前耗电 App": "Top Energy Apps",
        "按处理器活动实时估算": "Estimated live from processor activity",
        "正在采样当前应用活动…": "Sampling current app activity…",
        "当前没有检测到明显耗电的前台应用": "No significant foreground app activity detected",
        "设置详情": "Settings Details",
        "上限": "Limit",
        "适配器": "Adapter",
        "电池充入": "Battery Input",
        "系统使用": "System Use",
        "电池输出": "Battery Output",
        "开启": "On",
        "关闭": "Off",
        "开": "On",
        "关": "Off",
        "绿色": "Green",
        "剩余时间": "Time Remaining",
        "CPU 占用": "CPU Usage",
        "CPU 温度": "CPU Temperature",
        "CPU 温度过高": "High CPU Temperature",
        "上行 / 下行（MB/s）": "Up / Down (MB/s)",
        "健康度、循环次数与剩余时间": "Health, cycle count, and remaining time",
        "储存内存占用偏高": "High Storage Usage",
        "内存、磁盘、温度、风扇、网速与 CPU 占用": "Memory, disk, temperature, fan, network, and CPU usage",
        "内存占用": "Memory Usage",
        "剩余 / 总量（GB）": "Free / Total (GB)",
        "已用 / 总量（GB）": "Used / Total (GB)",
        "处理器活跃度（%）": "CPU Activity (%)",
        "外观": "Appearance",
        "实时功率偏高": "High Live Power",
        "实时电脑检测": "Live Computer Monitoring",
        "实时硬件监测": "Live Hardware Monitoring",
        "已隐藏全部项目，可在「设置 → 仪表盘」中开启": "All items hidden; enable them in Settings → Dashboard",
        "当前耗电应用": "Top Energy Apps",
        "快捷入口": "Quick Links",
        "恢复默认布局": "Restore Default Layout",
        "按处理器活动估算的耗电排行": "Power ranking estimated from processor activity",
        "查看全部耗电应用": "View All Energy Apps",
        "电池图标": "Battery Icon",
        "电池概览": "Battery Overview",
        "电池监测 · 实时功率 · 系统状态": "Battery Monitor · Live Power · System Status",
        "电池监测控制台": "Battery Monitor Console",
        "电源、电池与系统之间的能量流向": "Energy flow between adapter, battery, and system",
        "电源状态卡片": "Power State Card",
        "百分比数字": "Percentage Number",
        "磁盘空间": "Disk Space",
        "系统实时功耗": "Live System Power",
        "系统状态": "System Status",
        "网络速度": "Network Speed",
        "菜单栏主图标": "Main Menu Bar Icon",
        "运存占用偏高": "High RAM Usage",
        "通过 SMC 读取（RPM）": "Read via SMC (RPM)",
        "通过 SMC 读取（°C）": "Read via SMC (°C)",
        "顶部主状态卡片：电源、电池或充电": "Top status card: power, battery, or charging",
        "风扇转速": "Fan Speed",
        "状态栏显示 CPU 温度": "Show CPU temperature in the status bar",
        "状态栏显示 CPU 使用率": "Show CPU usage in the status bar",
        "状态栏显示已用内存": "Show memory usage in the status bar",
        "状态栏显示剩余磁盘空间": "Show free disk space in the status bar",
        "状态栏显示风扇转速": "Show fan speed in the status bar",
        "状态栏显示实时网速": "Show live network speed in the status bar",
        "主输出": "Master Output",
        "App 音量": "App Volume",
        "输出设备": "Output Device",
        "输入设备": "Input Device",
        "忽略此 App": "Ignore this app",
        "点击图标可激活此 App": "Tap the icon to activate this app",
        "逐 App 音量需要「屏幕录制」权限（macOS 用它授权音频拦截）。": "Per-app volume needs Screen Recording permission (macOS uses it to authorize audio interception).",
        "打开音量设置": "Open Volume Settings",
        "当前没有 App 在播放声音。开始播放后这里会出现可控制的 App。": "No apps are playing audio right now. Playing something lists it here.",
        "未枚举到输出设备。": "No output devices enumerated.",
        "隐藏": "Hide",
        "恢复": "Restore",
        "麦克风": "Microphone",
        "已隐藏的应用": "Hidden Apps",
        "全部恢复": "Restore All",
        "输出设备音量": "Output Device Volume",
        "同时选择多个设备可一起出声": "Select multiple devices to play on all of them",
        "此设备不支持软件音量调节": "This device does not support software volume control",
        "麦克风不可控": "Microphone not controllable",
        "折叠": "Collapse",
        "展开": "Expand",
        "未检测到音频设备": "No audio devices",
        "当前主播放设备不支持软件音量调节": "The current master output device does not support software volume control",
        "主音量": "Master Volume",
        "无输入设备": "No input device",
        "上移": "Move Up",
        "下移": "Move Down",
        "重置顺序": "Reset Order",
        "内容超出屏幕，可继续滚动": "Content exceeds the screen — scroll for more",
        "同时选择多个设备可一起出声，右侧箭头可调整显示顺序": "Select multiple devices to play on all of them; arrows reorder the list",
        "整体音量、静音与设备概览": "Master Volume, Mute & Device Overview",
        "麦克风输入与默认设备": "Microphone Input & Default Device",
        "切换系统输出设备": "Switch System Output Device",
        "逐应用音量调节": "Per-App Volume Control",
        "多合一效率工具": "All-in-One Efficiency Tool",
        "电池监测 · 实时功率 · 系统状态 · 窗口管理": "Battery Monitor · Live Power · System Status · Window Management",
        "macall 基于 Macindow(MIT) 与 maconitor(GPL-3.0) 合并而来，并使用 Defaults 等开源组件。": "macall merges Macindow (MIT) and maconitor (GPL-3.0), and uses open-source components such as Defaults.",
    ]
}
