import AppKit
import SwiftUI

struct AboutSettingsView: View {
    @Default(.appLanguage) private var appLanguage

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.4.0"
    }

    var body: some View {
        IadenteSettingsPage {
            IadenteCard(
                "macall",
                subtitle: IadenteL10n.t("开源(GPL-3.0)的 Mac 多合一效率工具", "Open-source (GPL-3.0) all-in-one Mac utility"),
                icon: "bolt.heart.fill",
                colors: IadenteTheme.aboutColors
            ) {
                IadenteInsetPanel {
                    HStack(spacing: 16) {
                        IadenteIconBadge(
                            icon: "battery.100percent.bolt",
                            colors: [
                                IadenteTheme.jade,
                                IadenteTheme.mint,
                                IadenteTheme.gold,
                            ],
                            size: 64,
                            cornerRadius: 18
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text("macall")
                                .font(.title.bold())
                            Text(IadenteL10n.t("电池监测 · 实时功率 · 系统状态 · 窗口管理"))
                                .foregroundStyle(.secondary)
                            Text(IadenteL10n.t("版本 \(appVersion)", "Version \(appVersion)"))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(IadenteTheme.jade)
                        }

                        Spacer()
                    }
                }
            }

            IadenteCard(
                IadenteL10n.t("安全说明", "Safety"),
                subtitle: IadenteL10n.t("底层控制始终以设备能力检测和明确授权为前提。", "Low-level control always requires capability checks and explicit authorization."),
                icon: "shield.checkered",
                colors: IadenteTheme.generalColors
            ) {
                Text(
                    IadenteL10n.t(
                        "macall 是一款系统监测 + 窗口管理工具：实时读取电量、功率、温度、风扇、网速、内存与磁盘占用，同时提供窗口分屏、Dock 悬停预览等效率功能。窗口管理相关操作依赖辅助功能权限。",
                        "macall is a system monitor + window manager: it reads battery, power, temperature, fan, network, memory and disk usage live, and offers window snapping and Dock-hover preview. Window management needs Accessibility permission."
                    )
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            IadenteCard(
                IadenteL10n.t("开放源代码", "Open Source"),
                subtitle: IadenteL10n.t("许可文本和第三方声明均随应用一同提供。", "License text and third-party notices are included with the app."),
                icon: "chevron.left.forwardslash.chevron.right",
                colors: IadenteTheme.advancedColors
            ) {
                Text(
                    IadenteL10n.t(
                        "macall 基于 Macindow(MIT) 与 maconitor(GPL-3.0) 合并而来，并使用 Defaults 等开源组件。"
                    )
                )
                .foregroundStyle(.secondary)

                Button {
                    guard let url = Bundle.main.url(
                        forResource: "LICENSE",
                        withExtension: "txt"
                    ) else { return }
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(IadenteL10n.t("查看开源许可证"), systemImage: "doc.text.fill")
                }
                .buttonStyle(IadenteActionButtonStyle(colors: IadenteTheme.advancedColors))
            }
        }
    }
}
