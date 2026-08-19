import SwiftUI

// MARK: - 重排控制（加大命中区域，便于点击）

/// 统一的上下重排控件：所有涉及「排序」的设置模块共用这一套设计与命中逻辑。
/// 整颗胶囊（含箭头周围空白）都是命中区，点击任意位置即可上下调动；
/// 控件整体刻意做小、留白少，与状态监控模块的重排风格保持一致。
struct ReorderControl: View {
    let isFirst: Bool
    let isLast: Bool
    let onUp: () -> Void
    let onDown: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Button(action: onUp) {
                Image(systemName: "chevron.up")
            }
            .disabled(isFirst)
            .buttonStyle(ReorderButtonStyle())

            Button(action: onDown) {
                Image(systemName: "chevron.down")
            }
            .disabled(isLast)
            .buttonStyle(ReorderButtonStyle())
        }
        .frame(width: 34)
    }
}

struct ReorderButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .frame(width: 30, height: 22)
            .background(
                Capsule().fill(
                    configuration.isPressed
                        ? Color.accentColor.opacity(0.35)
                        : Color.secondary.opacity(0.16)
                )
            )
            .overlay(
                Capsule().stroke(Color.secondary.opacity(0.28), lineWidth: 0.5)
            )
            .foregroundStyle(
                configuration.isPressed
                    ? Color.accentColor
                    : (isEnabled ? Color.primary : Color.secondary.opacity(0.4))
            )
            // 整颗胶囊（含箭头周围空白）都是命中区，点击任意位置即可上下调动。
            .contentShape(Capsule())
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
