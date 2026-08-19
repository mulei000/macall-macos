import AppKit
import SwiftUI

/// 状态栏电池图标（传统样式）：电池外壳描边，内部按电量百分比填充色条，
/// 未填充部分留空。开启「用颜色显示电池状态」后，色条底色随电量与状态连续变化：
/// 放电=深灰→浅灰、充电=暗绿→亮绿、接电未充=暗蓝→亮蓝、低电量(≤20%)强制红系。
/// 数字与符号颜色根据色条相对亮度自动选黑/白，保证与底色及留空部分都清晰可读。
/// 状态符号：充电=闪电⚡；接电未充=插头🔌（满电 100 显示✅）；放电低电量=⚠。
struct BatteryIndicatorView: View {
    let batteryLevel: Int
    let chargingMode: ChargingMode
    var isLowPowerModeEnabled: Bool = false
    var percentageDisplayLocation: PercentageDisplayLocation = .hidden
    var showState: Bool = false

    private var shouldShowInsidePercentage: Bool {
        percentageDisplayLocation == .insideIcon
    }

    private var shouldShowOutsidePercentage: Bool {
        percentageDisplayLocation == .nextToIcon
    }

    /// 低电量：开启状态着色且电量 ≤20。
    private var isCritical: Bool {
        showState && batteryLevel <= 20
    }

    private var outlineColor: Color { .primary }

    // MARK: - 色条端点（sRGB 空间，便于插值与亮度计算）
    private static let dischargeLow = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.16, alpha: 1)
    private static let dischargeFull = NSColor(srgbRed: 0.66, green: 0.66, blue: 0.66, alpha: 1)
    private static let chargeLow = NSColor(srgbRed: 0.10, green: 0.45, blue: 0.22, alpha: 1)
    private static let chargeFull = NSColor(srgbRed: 0.30, green: 0.76, blue: 0.42, alpha: 1)
    private static let pluggedLow = NSColor(srgbRed: 0.12, green: 0.30, blue: 0.70, alpha: 1)
    private static let pluggedFull = NSColor(srgbRed: 0.34, green: 0.60, blue: 1.00, alpha: 1)
    private static let criticalLow = NSColor(srgbRed: 0.70, green: 0.10, blue: 0.10, alpha: 1)
    private static let criticalFull = NSColor(srgbRed: 0.96, green: 0.28, blue: 0.28, alpha: 1)

    /// 色条填充色（NSColor，便于计算亮度）。
    private var fillNSColor: NSColor {
        if !showState { return NSColor.quaternaryLabelColor }
        if isCritical {
            return BatteryIndicatorView.lerp(Self.criticalLow, Self.criticalFull, t: Double(batteryLevel) / 20.0)
        }
        switch chargingMode {
        case .charging:
            return BatteryIndicatorView.lerp(Self.chargeLow, Self.chargeFull, t: Double(batteryLevel) / 100.0)
        case .pluggedIn:
            return BatteryIndicatorView.lerp(Self.pluggedLow, Self.pluggedFull, t: Double(batteryLevel) / 100.0)
        case .discharging:
            return BatteryIndicatorView.lerp(Self.dischargeLow, Self.dischargeFull, t: Double(batteryLevel) / 100.0)
        }
    }

    /// 色条填充色（SwiftUI Color）。
    private var fillColor: Color { Color(nsColor: fillNSColor) }

    /// 未填充（留空）区域底色。
    private var emptyFill: Color { Color(nsColor: NSColor.tertiaryLabelColor) }

    /// 数字与符号颜色：色条相对亮度 ≥0.5 用黑字，否则白字；关闭状态着色时自适应。
    private var foregroundColor: Color {
        if !showState { return .primary }
        return BatteryIndicatorView.relativeLuminance(fillNSColor) >= 0.5 ? .black : .white
    }

    /// 数字/符号描边阴影：与前景相反色，提升跨填充/留空边界时的可读性。
    private var contrastShadow: Color {
        foregroundColor == .white ? Color.black.opacity(0.4) : Color.white.opacity(0.4)
    }

    private static func lerp(_ a: NSColor, _ b: NSColor, t: Double) -> NSColor {
        let t = min(max(t, 0), 1)
        return NSColor(
            srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
            alpha: 1
        )
    }

    private static func relativeLuminance(_ c: NSColor) -> Double {
        let srgb = c.usingColorSpace(.sRGB) ?? c
        let r = srgb.redComponent, g = srgb.greenComponent, b = srgb.blueComponent
        let linear = { (v: Double) -> Double in
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private enum Layout {
        static let batteryHeight: CGFloat = 11
        static let batteryWidth: CGFloat = 21
        static let insideBatteryHeight: CGFloat = 13
        static let insideBatteryWidth: CGFloat = 25
        static let terminalWidth: CGFloat = 1.8
        static let terminalHeight: CGFloat = 4.5
        static let insideTerminalWidth: CGFloat = 2.2
        static let insideTerminalHeight: CGFloat = 5.5
        static let cornerRadius: CGFloat = 3
        static let insideCornerRadius: CGFloat = 3.5
        static let strokeWidth: CGFloat = 1
        static let fillInset: CGFloat = 1.5
        static let outlineOpacity: CGFloat = 0.6
        static let digitFont = Font.custom("Times New Roman", size: 10).bold()
        static let glyphFont = Font.system(size: 8, weight: .bold)
    }

    var body: some View {
        HStack(spacing: 3) {
            if shouldShowOutsidePercentage {
                Text("\(batteryLevel)%")
                    .font(Layout.digitFont)
            }

            HStack(spacing: 0) {
                batteryBody
                if shouldShowInsidePercentage {
                    BatteryTerminal(
                        width: Layout.insideTerminalWidth,
                        height: Layout.insideTerminalHeight,
                        cornerRadius: 1.5
                    )
                } else {
                    BatteryTerminal(
                        width: Layout.terminalWidth,
                        height: Layout.terminalHeight,
                        cornerRadius: 1.25
                    )
                }
            }
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = [
            IadenteL10n.t(
                "电池电量 \(batteryLevel)%",
                "Battery level \(batteryLevel)%"
            )
        ]
        switch chargingMode {
        case .charging: parts.append(IadenteL10n.t("正在充电"))
        case .pluggedIn: parts.append(IadenteL10n.t("已接通电源", "Plugged In"))
        case .discharging: break
        }
        if isLowPowerModeEnabled {
            parts.append(IadenteL10n.t("低电量模式", "Low Power Mode"))
        }
        return parts.joined(separator: "，")
    }

    private var batteryBody: some View {
        let w = shouldShowInsidePercentage ? Layout.insideBatteryWidth : Layout.batteryWidth
        let h = shouldShowInsidePercentage ? Layout.insideBatteryHeight : Layout.batteryHeight
        let r = shouldShowInsidePercentage ? Layout.insideCornerRadius : Layout.cornerRadius
        let inset = Layout.fillInset
        let available = w - 2 * inset
        let fillW = max(available * CGFloat(batteryLevel) / 100.0, batteryLevel > 0 ? 3 : 0)

        return ZStack {
            // 留空区域底色
            RoundedRectangle(cornerRadius: r)
                .fill(emptyFill)

            // 电量色条（左对齐，按电量宽度）
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: max(r - inset, 1))
                    .fill(fillColor)
                    .frame(width: fillW)
                Spacer(minLength: 0)
            }
            .padding(inset)

            // 外壳描边
            RoundedRectangle(cornerRadius: r)
                .stroke(outlineColor, lineWidth: Layout.strokeWidth)
                .opacity(Layout.outlineOpacity)

            if shouldShowInsidePercentage {
                insideContent
            } else {
                chargingOverlayGlyph
            }
        }
        .frame(width: w, height: h)
    }

    private var insideContent: some View {
        HStack(spacing: 1) {
            Text(verbatim: "\(batteryLevel)")
                .font(Layout.digitFont)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(foregroundColor)
                .shadow(color: contrastShadow, radius: 0.6)

            if let glyph = statusGlyphImage() {
                glyph
                    .font(Layout.glyphFont)
                    .foregroundStyle(foregroundColor)
                    .shadow(color: contrastShadow, radius: 0.6)
                    .rotationEffect(glyphRotated ? .degrees(-90) : .zero)
                    .frame(width: 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var chargingOverlayGlyph: some View {
        if let glyph = statusGlyphImage() {
            glyph
                .font(Layout.glyphFont)
                .foregroundStyle(foregroundColor)
                .shadow(color: contrastShadow, radius: 0.6)
                .rotationEffect(glyphRotated ? .degrees(-90) : .zero)
        }
    }

    /// 状态符号：充电=闪电；接电未充=插头（满电 100 显示对勾）；放电低电量=⚠；
    /// 低电量且正在充电时仍显示闪电（按推荐，状态优先）。
    private func statusGlyphImage() -> Image? {
        switch chargingMode {
        case .charging:
            return Image(systemName: "bolt.fill")
        case .pluggedIn:
            if batteryLevel >= 100 {
                return Image(systemName: "checkmark.circle.fill")
            }
            return Image(systemName: "powerplug.fill")
        case .discharging:
            if isCritical {
                return Image(systemName: "exclamationmark.triangle.fill")
            }
            return nil
        }
    }

    /// 仅插头需要竖放。
    private var glyphRotated: Bool {
        chargingMode == .pluggedIn && batteryLevel < 100
    }
}

struct BatteryTerminal: View {
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: cornerRadius,
            topTrailingRadius: cornerRadius
        )
        .fill(.primary)
        .frame(width: width, height: height)
        .opacity(0.55)
        .offset(x: 1)
    }
}
