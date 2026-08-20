import Foundation
import CoreGraphics

/// Dock 图标反转的两种互斥行为：点击已激活 App 的 Dock 图标时是最小化全部窗口，还是隐藏整个 App。
enum DockToggleBehavior: String, Codable {
    case minimize
    case hideApp
}

/// 边缘吸附分屏：左 / 右边缘各自默认的分屏比例（仅当「边缘分屏选择器」关闭时生效）。
enum EdgeSnapSideLayout: String, Codable, Hashable {
    case third      // 1/3
    case half       // 1/2
    case twoThirds  // 2/3
}

/// 触控板左 / 右边缘区域对应的动作。
enum TouchpadEdgeAction: String, Codable, CaseIterable {
    case brightness  // 屏幕亮度（DisplayServices）
    case volume      // 系统音量（CoreAudio）
    case off         // 该边缘不触发
}

/// 全局配置。保存到 `~/.config/macall/config.json`，对新旧字段容错。
struct Configuration: Codable {
    /// 全局总开关（关闭后所有快捷键透传）。
    var enabled: Bool = true
    /// 分屏时相邻窗口之间的间隙（点）。
    var gap: Double = 8
    /// 菜单栏是否显示电池百分比。
    var monitorShowPercentage: Bool = true
    /// 各功能的启用状态（id → 是否启用）。缺省时回退到功能的 `enabledByDefault`。
    var enabledFeatures: [String: Bool] = [:]
    /// 各快捷键（子功能）的启用状态（action key → 是否启用）。缺省时回退到 true（启用）。
    /// 关掉某个子功能后，其快捷键不再绑定，但快捷键组合本身仍保留（可随时重新开启）。
    var enabledHotkeys: [String: Bool] = [:]
    /// 全局快捷键映射（action key → 按键）。
    var hotkeys: [String: HotkeySpec] = Configuration.defaultHotkeys()
    /// 是否启用 Dock 悬停窗口预览（vorssaint 引擎）。
    var previewEnabled: Bool = true
    /// 音量：用户选择的输出设备（设备 UID 列表）。空数组表示「跟随系统默认」。
    /// 长度 1 时设为默认输出设备；长度 >1 时 macall 创建/复用「多输出组合设备」并设为默认。
    var outputDeviceUIDs: [String] = []

    /// 逐 App 音量（bundleID/持久键 → 0…1）。键存在即表示该 App 被「启用逐 App 控制」。
    var perAppVolume: [String: Double] = [:]
    /// 逐 App 静音状态（键 → 是否静音）。
    var perAppMuted: [String: Bool] = [:]
    /// 逐 App 输出设备路由（键 → 设备 UID 列表）。空数组表示「跟随系统默认输出」。
    var perAppDeviceUIDs: [String: [String]] = [:]
    /// 在音量弹窗中被隐藏的 App（persistenceKey 列表）。仅影响展示，不影响检测与音频处理。
    var hiddenAudioApps: [String] = []
    /// 被隐藏 App 的显示名缓存（persistenceKey → 名称），用于「已隐藏的应用」列表在 App 退出后仍可读。
    var hiddenAudioAppNames: [String: String] = [:]
    /// 音量弹窗中输出设备的自定义显示顺序（设备 UID 列表）。
    /// 未出现在此列表中的设备排在末尾，按系统枚举顺序。
    var audioDeviceOrder: [String] = []
    /// 在音量弹窗的输出设备列表中隐藏的设备（设备 UID 列表）。仅影响展示，不影响系统音频路由。
    var hiddenAudioDevices: [String] = []

    /// 设备优先级自动路由：开启后，若无显式 outputDeviceUIDs，则自动把
    /// 当前在线且优先级最高的输出设备设为系统默认输出（插入更优先设备时自动切换）。
    var autoRouteOutput: Bool = false
    /// 输出设备优先级（设备 UID 有序列表，越靠前越优先）。空表示按系统默认顺序。
    var devicePriority: [String] = []

    /// 输出设备快速切换（⌃⌥K）：按下快捷键时在「勾选的设备」间循环切系统默认输出。
    /// 空数组表示「循环全部输出设备」，非空则只循环列表内的设备。
    var outputSwitcherDeviceUIDs: [String] = []

    /// Dock 图标反转行为：点击已激活 App 的 Dock 图标时是最小化全部窗口，还是隐藏整个 App。
    var dockToggleBehavior: DockToggleBehavior = .minimize

    /// 边缘吸附分屏：是否弹出「边缘分屏选择器」让你每次拖到边缘时选 1/3·1/2·2/3。
    /// 关（默认）时，拖到左 / 右边缘直接用下方预设的默认分屏比例。
    var edgeSnapSelectorEnabled: Bool = false
    /// 左边缘默认分屏比例（edgeSnapSelectorEnabled = false 时生效）。
    var edgeSnapLeftLayout: EdgeSnapSideLayout = .half
    /// 右边缘默认分屏比例（edgeSnapSelectorEnabled = false 时生效）。
    var edgeSnapRightLayout: EdgeSnapSideLayout = .half

    /// 模块3 麦克风：用户选定的默认输入设备 UID（空 = 跟随系统默认输入）。
    var defaultInputDeviceUID: String = ""
    /// 系统提示音输出设备 UID（空 = 跟随系统默认系统输出）。
    var systemSoundOutputDeviceUID: String = ""
    /// 耳机拔出（默认输出从「耳机类」切到「非耳机类」）时自动把主音量降到指定值，
    /// 避免外放突然以高音量炸响。autoDuckTargetVolume 范围 0…1，默认 0.25。
    var autoDuckOnHeadphoneUnplug: Bool = false
    var autoDuckTargetVolume: Double = 0.25

    /// 剪贴板历史最多保留多少条（置顶项不占用配额）。
    var clipboardMaxItems: Int = 200
    /// 剪贴板历史保留天数；0 表示永久保留。超期的非置顶条目会在启动与轮询时清理。
    var clipboardRetentionDays: Int = 0
    /// 剪贴板历史是否记录图片（关掉可显著减小历史文件体积）。
    var clipboardKeepImages: Bool = true
    /// 剪贴板历史是否记录「拷贝的文件 / 文件夹」。关掉后复制文件不会进历史。
    var clipboardKeepFiles: Bool = true

    /// 屏幕放大镜的放大倍数（1.5…8）。
    var magnifierZoom: Double = 3
    /// 临时场景最多保留多少个（设置页可选 3…12）；超出时丢弃最旧的临时场景。
    /// 临时场景为纯内存，不落盘，进程退出即删。
    var maxTemporaryScenes: Int = 12

    /// 触控板手势调节：上下拖动的灵敏度（增益）。值越小越不灵敏（需更大位移才调同样多）。
    /// 0.2 = 很钝，1.0 = 偏灵敏，建议 0.4…0.8；默认 0.6。
    var touchpadSensitivity: Double = 0.6
    /// 边缘滑入起手区：手指必须落在最外 N%（0.02=必须贴最外缘，0.15=较宽松）；默认 0.06。
    var touchpadStartZone: Double = 0.06
    /// 边缘滑入向内行程：起手后需向内滑过该距离才锁定调节（0.05=灵敏，0.30=需明显滑动）；默认 0.15。
    var touchpadMinTravel: Double = 0.15
    /// 左边缘区域（触控板最左约 25%）对应的动作。
    var touchpadLeftAction: TouchpadEdgeAction = .brightness
    /// 右边缘区域（触控板最右约 18%）对应的动作。
    var touchpadRightAction: TouchpadEdgeAction = .volume
    /// 调节时是否给出触觉反馈。
    var touchpadHaptic: Bool = true

    /// 鼠标优化 - 滚轮独立反转（只影响鼠标滚轮，不碰触控板）。默认 false。
    var mouseScrollInvert: Bool = false
    /// 鼠标优化 - 平滑滚动（参数化惯性引擎，替代旧版 light/full 二选一）。默认 false。
    var mouseSmoothScroll: Bool = false
    /// 鼠标优化 - 滚动步长（MOS step）：低于该幅度的 tick 归一抬到该值（去抖 + 提速），默认 33.6（与 MOS 一致）。
    var mouseScrollStep: Double = 33.6
    /// 鼠标优化 - 滚动速度倍率（MOS speed）：能量累积的倍率，默认 2.70（与 MOS 一致）。
    var mouseScrollSpeed: Double = 2.70
    /// 鼠标优化 - 滚动时长（MOS duration）：指数缓动参数，越大越顺滑、滑行越久；默认 4.35（与 MOS 一致）。
    var mouseScrollDuration: Double = 4.35

    init() {}

    // MARK: - Defaults

    static func defaultHotkeys() -> [String: HotkeySpec] {
        // 所有绑定统一使用 Control + Option 作为基底，避免与常见应用快捷键冲突。
        // 跨屏移动额外加 Command。
        let base = mask(F_CTRL, F_OPT)
        let baseCmd = mask(F_CTRL, F_OPT, F_CMD)

        func spec(_ code: UInt16, _ flags: UInt32) -> HotkeySpec {
            HotkeySpec(keyCode: code, flags: flags)
        }

        return [
            // WindowSnap
            "snap.leftHalf":    spec(VK.left, base),
            "snap.rightHalf":   spec(VK.right, base),
            "snap.topHalf":     spec(VK.up, base),
            "snap.bottomHalf":  spec(VK.down, base),
            "snap.topLeft":     spec(VK.d1, base),
            "snap.topRight":    spec(VK.d2, base),
            "snap.bottomLeft":  spec(VK.d3, base),
            "snap.bottomRight": spec(VK.d4, base),
            "snap.leftThird":   spec(VK.leftBracket, base),
            "snap.rightThird":  spec(VK.rightBracket, base),
            "snap.centerThird": spec(VK.backslash, base),
            "snap.leftTwoThirds":  spec(VK.u, base),
            "snap.rightTwoThirds": spec(VK.semicolon, base),
            "snap.maximize":    spec(VK.m, base),
            "snap.center":      spec(VK.c, base),
            "snap.restore":     spec(VK.r, base),

            // HideWindows（隐藏全部 / 显示全部是两个独立键，成对使用 ⌃⌥A / ⌃⌥⇧A；隐藏当前窗口 ⌃⌥I）
            "hide.others":      spec(VK.o, base),
            "hide.all":         spec(VK.a, base),
            "hide.current":     spec(VK.i, base),
            "show.all":         spec(VK.a, mask(F_CTRL, F_OPT, F_SHIFT)),

            // DisplayMove
            "display.next":     spec(VK.right, baseCmd),
            "display.prev":     spec(VK.left, baseCmd),

            // AppSwitcher（AltTab 风格窗口切换，带预览）
            // 默认 ⌥Tab：系统 ⌘Tab 是「切 App」，⌥Tab 空着，用来「切窗口」互不打架。
            "switcher.show":    spec(VK.tab, mask(F_OPT)),

            // ClipboardHistory（⌘⇧V 唤起历史面板，点击即粘贴）
            "clipboard.show":   spec(VK.v, mask(F_CMD, F_SHIFT)),

            // WindowLayout（保存/还原窗口布局快照，按场景记忆各 App 窗口位置）
            "layout.save":      spec(VK.s, base),
            "layout.restore":   spec(VK.l, base),
            // WindowLayout 场景选择器：⌃⌥P 弹出一个浮层，键盘 / 点击选场景一键还原。
            "layout.picker":    spec(VK.p, base),

            // Power & Appearance（锁屏 / 睡眠 / 熄屏 / 切换深色模式）
            "power.displaySleep": spec(VK.e, base),
            "power.sleep":       spec(VK.d, base),
            "power.lock":        spec(VK.q, base),
            "power.toggleDark":  spec(VK.t, base),

            // Snippets（文字片段：⌃⌥B 唤起，点击即粘贴常用语）
            "snippets.show":     spec(VK.b, base),

            // QR（二维码：⌃⌥F 唤起，输入即生成，可复制/保存）
            "qr.show":           spec(VK.f, base),

            // ColorPicker（屏幕取色：⌃⌥G 唤起系统取色放大镜，自动复制 Hex）
            "colorpicker.pick":  spec(VK.g, base),

            // Volume（音量：⌃⌥X 切换静音，设置页可调主音量）
            "volume.mute":       spec(VK.x, base),

            // OutputSwitcher（输出设备切换：⌃⌥K 在勾选设备间循环切系统默认输出）
            "outputswitcher.cycle": spec(VK.k, base),

            // MicControl（麦克风静音：⌃⌥J 切换默认输入设备静音）
            "miccontrol.mute": spec(VK.j, base),

            // InputSwitcher（输入设备切换：⌃⌥Y 在全部可用输入设备间循环切系统默认输入）
            "inputswitcher.cycle": spec(VK.y, base),

            // HotkeyCheatSheet（快捷键速查：⌃⌥H 弹出所有已启用快捷键）
            "hotkeycheatsheet.show": spec(VK.h, base),

            // AlwaysOnTop（窗口置顶：⌃⌥W 切换最前台窗口置顶）
            "alwaysontop.toggle": spec(VK.w, base),

            // ClipboardOCR（剪贴板 OCR：⌃⌥N 识别剪贴板图片文字）
            "clipboardocr.run":   spec(VK.n, base),

            // Magnifier（屏幕放大镜：⌃⌥Z 切换跟随光标放大）
            "magnifier.toggle":   spec(VK.z, base),

            // DDC（显示器控制：⌃⌥, 调暗 / ⌃⌥. 调亮 / ⌃⌥/ 音量减 / ⌃⌥' 音量加）
            "ddc.brightnessDown": spec(VK.comma, base),
            "ddc.brightnessUp":   spec(VK.period, base),
            "ddc.volumeDown":     spec(VK.slash, base),
            "ddc.volumeUp":       spec(VK.quote, base),

            // 清洁模式（⌃⌥5 锁定键盘并熄屏，仅鼠标点击或倒计时可解锁；媒体键一并锁死）
            "keyboardclean.toggle": spec(VK.d5, base),
        ]
    }

    /// 设置界面展示用的中文标签。
    static func label(for key: String) -> String {
        switch key {
        case "snap.leftHalf": return IadenteL10n.t("左半屏", "Left Half")
        case "snap.rightHalf": return IadenteL10n.t("右半屏", "Right Half")
        case "snap.topHalf": return IadenteL10n.t("上半屏", "Top Half")
        case "snap.bottomHalf": return IadenteL10n.t("下半屏", "Bottom Half")
        case "snap.topLeft": return IadenteL10n.t("左上 1/4", "Top Left 1/4")
        case "snap.topRight": return IadenteL10n.t("右上 1/4", "Top Right 1/4")
        case "snap.bottomLeft": return IadenteL10n.t("左下 1/4", "Bottom Left 1/4")
        case "snap.bottomRight": return IadenteL10n.t("右下 1/4", "Bottom Right 1/4")
        case "snap.leftThird": return IadenteL10n.t("左 1/3", "Left 1/3")
        case "snap.rightThird": return IadenteL10n.t("右 1/3", "Right 1/3")
        case "snap.centerThird": return IadenteL10n.t("中 1/3", "Center 1/3")
        case "snap.leftTwoThirds": return IadenteL10n.t("左 2/3 分屏", "Left 2/3 Split")
        case "snap.rightTwoThirds": return IadenteL10n.t("右 2/3 分屏", "Right 2/3 Split")
        case "snap.maximize": return IadenteL10n.t("最大化", "Maximize")
        case "snap.center": return IadenteL10n.t("居中", "Center")
        case "snap.restore": return IadenteL10n.t("还原", "Restore")
        case "hide.others": return IadenteL10n.t("隐藏其他窗口", "Hide Other Windows")
        case "hide.all": return IadenteL10n.t("隐藏全部窗口（显示桌面）", "Hide All Windows (Show Desktop)")
        case "hide.current": return IadenteL10n.t("隐藏当前窗口", "Hide Current Window")
        case "show.all": return IadenteL10n.t("显示全部窗口（恢复）", "Show All Windows (Restore)")
        case "display.next": return IadenteL10n.t("移到下一屏", "Move to Next Display")
        case "display.prev": return IadenteL10n.t("移到上一屏", "Move to Previous Display")
        case "switcher.show": return IadenteL10n.t("窗口切换(AltTab)", "Window Switcher (AltTab)")
        case "layout.save": return IadenteL10n.t("保存布局", "Save Layout")
        case "layout.restore": return IadenteL10n.t("还原布局", "Restore Layout")
        case "layout.picker": return IadenteL10n.t("布局选择器", "Layout Picker")
        case "power.displaySleep": return IadenteL10n.t("熄屏（仅显示器）", "Display Sleep (monitor only)")
        case "power.sleep": return IadenteL10n.t("系统睡眠", "System Sleep")
        case "power.lock": return IadenteL10n.t("锁屏", "Lock Screen")
        case "power.toggleDark": return IadenteL10n.t("切换深色模式", "Toggle Dark Mode")
        case "snippets.show": return IadenteL10n.t("文字片段", "Text Snippets")
        case "qr.show": return IadenteL10n.t("二维码", "QR Code")
        case "colorpicker.pick": return IadenteL10n.t("屏幕取色", "Screen Color Picker")
        case "volume.mute": return IadenteL10n.t("静音切换", "Toggle Mute")
        case "outputswitcher.cycle": return IadenteL10n.t("输出设备轮切", "Cycle Output Device")
        case "miccontrol.mute": return IadenteL10n.t("麦克风静音", "Microphone Mute")
        case "inputswitcher.cycle": return IadenteL10n.t("输入设备轮切", "Cycle Input Device")
        case "hotkeycheatsheet.show": return IadenteL10n.t("快捷键速查", "Hotkey Cheatsheet")
        case "alwaysontop.toggle": return IadenteL10n.t("窗口置顶切换", "Toggle Always on Top")
        case "clipboardocr.run": return IadenteL10n.t("剪贴板 OCR", "Clipboard OCR")
        case "magnifier.toggle": return IadenteL10n.t("屏幕放大镜", "Screen Magnifier")
        case "ddc.brightnessDown": return IadenteL10n.t("显示器调暗", "Monitor Dimmer")
        case "ddc.brightnessUp": return IadenteL10n.t("显示器调亮", "Monitor Brighter")
        case "ddc.volumeDown": return IadenteL10n.t("显示器音量减", "Monitor Volume Down")
        case "ddc.volumeUp": return IadenteL10n.t("显示器音量加", "Monitor Volume Up")
        case "keyboardclean.toggle": return IadenteL10n.t("清洁模式", "Clean Mode")
        default: return key
        }
    }

    // MARK: - Feature enable state

    func isFeatureEnabled(_ id: String, default on: Bool) -> Bool {
        enabledFeatures[id] ?? on
    }

    mutating func setFeatureEnabled(_ id: String, _ on: Bool) {
        enabledFeatures[id] = on
    }

    // MARK: - Hotkey (sub-function) enable state

    func isHotkeyEnabled(_ key: String, default on: Bool = true) -> Bool {
        enabledHotkeys[key] ?? on
    }

    mutating func setHotkeyEnabled(_ key: String, _ on: Bool) {
        enabledHotkeys[key] = on
    }

    // MARK: - Persistence

    static var url: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macall")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(self)
            try data.write(to: Configuration.url)
        } catch {
            Log.warning("无法保存配置: \(error)")
        }
    }

    static func load() -> Configuration {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(Configuration.self, from: data) else {
            return Configuration()
        }
        // 合并缺省的快捷键（老配置可能缺少新增的 action key）。
        var merged = cfg
        for (k, v) in defaultHotkeys() where merged.hotkeys[k] == nil {
            merged.hotkeys[k] = v
        }
        // 清理已下线模块遗留的配置（截图/录屏、Dock 反转已移除），
        // 否则老 config.json 里的孤儿键会一直留着。
        // v0.5.0 build 42：快捷启动器实测不稳定，整块移除，连带清掉旧配置里的残留键。
        // 另外清掉 build 43 模块化实验期写进 config 的模块 id（battery / systemstatus /
        // energy / keepawake）和更早的 "hide" 旧键——它们在 build 42 里没有对应 Feature，
        // 留着只会让 enabledFeatures 出现看不懂的 false，日后排查「功能失效」时误导人。
        let deadPrefixes = ["screenshot.", "quicklaunch."]
        let deadFeatures = [
            "screenshot", "quicklaunch",
            "hide", "battery", "systemstatus", "energy", "keepawake",
        ]
        merged.hotkeys = merged.hotkeys.filter { k, _ in
            !deadPrefixes.contains(where: { k.hasPrefix($0) })
        }
        merged.enabledHotkeys = merged.enabledHotkeys.filter { k, _ in
            !deadPrefixes.contains(where: { k.hasPrefix($0) })
        }
        for id in deadFeatures { merged.enabledFeatures.removeValue(forKey: id) }
        return merged
    }

    /// 临时场景上限，夹紧到合法区间 [3, 12]（供存储层直接取用）。
    var maxTemporaryScenesClamped: Int {
        max(3, min(12, maxTemporaryScenes))
    }

    // MARK: - Codable (tolerant of older configs missing new keys)

    private enum CodingKeys: String, CodingKey {
        case enabled, gap, monitorShowPercentage, enabledFeatures, enabledHotkeys, hotkeys, previewEnabled, outputDeviceUIDs, perAppVolume, perAppMuted, perAppDeviceUIDs, autoRouteOutput, devicePriority, outputSwitcherDeviceUIDs, dockToggleBehavior, edgeSnapSelectorEnabled, edgeSnapLeftLayout, edgeSnapRightLayout
        case hiddenAudioApps, hiddenAudioAppNames, audioDeviceOrder, hiddenAudioDevices
        case clipboardMaxItems, clipboardRetentionDays, clipboardKeepImages, clipboardKeepFiles, magnifierZoom, maxTemporaryScenes, defaultInputDeviceUID, systemSoundOutputDeviceUID, autoDuckOnHeadphoneUnplug, autoDuckTargetVolume, touchpadSensitivity, touchpadStartZone, touchpadMinTravel, touchpadLeftAction, touchpadRightAction, touchpadHaptic
        case mouseScrollInvert, mouseSmoothScroll, mouseScrollStep, mouseScrollSpeed, mouseScrollDuration
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? 8
        monitorShowPercentage = try c.decodeIfPresent(Bool.self, forKey: .monitorShowPercentage) ?? true
        enabledFeatures = try c.decodeIfPresent([String: Bool].self, forKey: .enabledFeatures) ?? [:]
        enabledHotkeys = try c.decodeIfPresent([String: Bool].self, forKey: .enabledHotkeys) ?? [:]
        hotkeys = try c.decodeIfPresent([String: HotkeySpec].self, forKey: .hotkeys) ?? Configuration.defaultHotkeys()
        previewEnabled = try c.decodeIfPresent(Bool.self, forKey: .previewEnabled) ?? true
        outputDeviceUIDs = try c.decodeIfPresent([String].self, forKey: .outputDeviceUIDs) ?? []
        perAppVolume = try c.decodeIfPresent([String: Double].self, forKey: .perAppVolume) ?? [:]
        perAppMuted = try c.decodeIfPresent([String: Bool].self, forKey: .perAppMuted) ?? [:]
        perAppDeviceUIDs = try c.decodeIfPresent([String: [String]].self, forKey: .perAppDeviceUIDs) ?? [:]
        hiddenAudioApps = try c.decodeIfPresent([String].self, forKey: .hiddenAudioApps) ?? []
        hiddenAudioAppNames = try c.decodeIfPresent([String: String].self, forKey: .hiddenAudioAppNames) ?? [:]
        audioDeviceOrder = try c.decodeIfPresent([String].self, forKey: .audioDeviceOrder) ?? []
        hiddenAudioDevices = try c.decodeIfPresent([String].self, forKey: .hiddenAudioDevices) ?? []
        autoRouteOutput = try c.decodeIfPresent(Bool.self, forKey: .autoRouteOutput) ?? false
        devicePriority = try c.decodeIfPresent([String].self, forKey: .devicePriority) ?? []
        outputSwitcherDeviceUIDs = try c.decodeIfPresent([String].self, forKey: .outputSwitcherDeviceUIDs) ?? []
        dockToggleBehavior = try c.decodeIfPresent(DockToggleBehavior.self, forKey: .dockToggleBehavior) ?? .minimize
        edgeSnapSelectorEnabled = try c.decodeIfPresent(Bool.self, forKey: .edgeSnapSelectorEnabled) ?? false
        edgeSnapLeftLayout = try c.decodeIfPresent(EdgeSnapSideLayout.self, forKey: .edgeSnapLeftLayout) ?? .half
        edgeSnapRightLayout = try c.decodeIfPresent(EdgeSnapSideLayout.self, forKey: .edgeSnapRightLayout) ?? .half
        defaultInputDeviceUID = try c.decodeIfPresent(String.self, forKey: .defaultInputDeviceUID) ?? ""
        systemSoundOutputDeviceUID = try c.decodeIfPresent(String.self, forKey: .systemSoundOutputDeviceUID) ?? ""
        autoDuckOnHeadphoneUnplug = try c.decodeIfPresent(Bool.self, forKey: .autoDuckOnHeadphoneUnplug) ?? false
        autoDuckTargetVolume = try c.decodeIfPresent(Double.self, forKey: .autoDuckTargetVolume) ?? 0.25
        clipboardMaxItems = try c.decodeIfPresent(Int.self, forKey: .clipboardMaxItems) ?? 200
        clipboardRetentionDays = try c.decodeIfPresent(Int.self, forKey: .clipboardRetentionDays) ?? 0
        clipboardKeepImages = try c.decodeIfPresent(Bool.self, forKey: .clipboardKeepImages) ?? true
        clipboardKeepFiles = try c.decodeIfPresent(Bool.self, forKey: .clipboardKeepFiles) ?? true
        magnifierZoom = try c.decodeIfPresent(Double.self, forKey: .magnifierZoom) ?? 3
        maxTemporaryScenes = try c.decodeIfPresent(Int.self, forKey: .maxTemporaryScenes) ?? 12
        touchpadSensitivity = try c.decodeIfPresent(Double.self, forKey: .touchpadSensitivity) ?? 0.6
        touchpadStartZone = try c.decodeIfPresent(Double.self, forKey: .touchpadStartZone) ?? 0.06
        touchpadMinTravel = try c.decodeIfPresent(Double.self, forKey: .touchpadMinTravel) ?? 0.15
        touchpadLeftAction = try c.decodeIfPresent(TouchpadEdgeAction.self, forKey: .touchpadLeftAction) ?? .brightness
        touchpadRightAction = try c.decodeIfPresent(TouchpadEdgeAction.self, forKey: .touchpadRightAction) ?? .volume
        touchpadHaptic = try c.decodeIfPresent(Bool.self, forKey: .touchpadHaptic) ?? true
        mouseScrollInvert = try c.decodeIfPresent(Bool.self, forKey: .mouseScrollInvert) ?? false
        mouseSmoothScroll = try c.decodeIfPresent(Bool.self, forKey: .mouseSmoothScroll) ?? false
        mouseScrollStep = try c.decodeIfPresent(Double.self, forKey: .mouseScrollStep) ?? 33.6
        mouseScrollSpeed = try c.decodeIfPresent(Double.self, forKey: .mouseScrollSpeed) ?? 2.70
        mouseScrollDuration = try c.decodeIfPresent(Double.self, forKey: .mouseScrollDuration) ?? 4.35
    }

    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(gap, forKey: .gap)
        try c.encode(monitorShowPercentage, forKey: .monitorShowPercentage)
        try c.encode(enabledFeatures, forKey: .enabledFeatures)
        try c.encode(enabledHotkeys, forKey: .enabledHotkeys)
        try c.encode(hotkeys, forKey: .hotkeys)
        try c.encode(previewEnabled, forKey: .previewEnabled)
        try c.encode(outputDeviceUIDs, forKey: .outputDeviceUIDs)
        try c.encode(perAppVolume, forKey: .perAppVolume)
        try c.encode(perAppMuted, forKey: .perAppMuted)
        try c.encode(perAppDeviceUIDs, forKey: .perAppDeviceUIDs)
        try c.encode(hiddenAudioApps, forKey: .hiddenAudioApps)
        try c.encode(hiddenAudioAppNames, forKey: .hiddenAudioAppNames)
        try c.encode(audioDeviceOrder, forKey: .audioDeviceOrder)
        try c.encode(hiddenAudioDevices, forKey: .hiddenAudioDevices)
        try c.encode(autoRouteOutput, forKey: .autoRouteOutput)
        try c.encode(devicePriority, forKey: .devicePriority)
        try c.encode(outputSwitcherDeviceUIDs, forKey: .outputSwitcherDeviceUIDs)
        try c.encode(dockToggleBehavior, forKey: .dockToggleBehavior)
        try c.encode(edgeSnapSelectorEnabled, forKey: .edgeSnapSelectorEnabled)
        try c.encode(edgeSnapLeftLayout, forKey: .edgeSnapLeftLayout)
        try c.encode(edgeSnapRightLayout, forKey: .edgeSnapRightLayout)
        try c.encode(defaultInputDeviceUID, forKey: .defaultInputDeviceUID)
        try c.encode(systemSoundOutputDeviceUID, forKey: .systemSoundOutputDeviceUID)
        try c.encode(autoDuckOnHeadphoneUnplug, forKey: .autoDuckOnHeadphoneUnplug)
        try c.encode(autoDuckTargetVolume, forKey: .autoDuckTargetVolume)
        try c.encode(clipboardMaxItems, forKey: .clipboardMaxItems)
        try c.encode(clipboardRetentionDays, forKey: .clipboardRetentionDays)
        try c.encode(clipboardKeepImages, forKey: .clipboardKeepImages)
        try c.encode(clipboardKeepFiles, forKey: .clipboardKeepFiles)
        try c.encode(magnifierZoom, forKey: .magnifierZoom)
        try c.encode(maxTemporaryScenes, forKey: .maxTemporaryScenes)
        try c.encode(touchpadSensitivity, forKey: .touchpadSensitivity)
        try c.encode(touchpadStartZone, forKey: .touchpadStartZone)
        try c.encode(touchpadMinTravel, forKey: .touchpadMinTravel)
        try c.encode(touchpadLeftAction, forKey: .touchpadLeftAction)
        try c.encode(touchpadRightAction, forKey: .touchpadRightAction)
        try c.encode(touchpadHaptic, forKey: .touchpadHaptic)
        try c.encode(mouseScrollInvert, forKey: .mouseScrollInvert)
        try c.encode(mouseSmoothScroll, forKey: .mouseSmoothScroll)
        try c.encode(mouseScrollStep, forKey: .mouseScrollStep)
        try c.encode(mouseScrollSpeed, forKey: .mouseScrollSpeed)
        try c.encode(mouseScrollDuration, forKey: .mouseScrollDuration)
    }
}
