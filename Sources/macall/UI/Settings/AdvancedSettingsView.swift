import SwiftUI

struct AdvancedSettingsView: View {
    @Default(.appLanguage) private var appLanguage
    @Default(.useHardwarePercentage) var useHardwarePercentage

    var body: some View {
        IadenteSettingsPage {
            IadenteCard(
                IadenteL10n.t("电量读取方式", "Battery Reading Method"),
                subtitle: IadenteL10n.t("选择 macall 读取电池电量时采用的数据来源。", "Choose the data source macall uses when reading battery level."),
                icon: "sensor.fill",
                colors: IadenteTheme.advancedColors
            ) {
                IadenteSettingToggle(
                    IadenteL10n.t("使用硬件电量百分比", "Use Hardware Battery Percentage"),
                    subtitle: IadenteL10n.t("直接读取电池管理系统的原始数值，而不是 macOS 校准后的显示值", "Read raw values directly from the battery management system instead of the macOS calibrated display value"),
                    icon: "cpu.fill",
                    colors: IadenteTheme.advancedColors,
                    isOn: $useHardwarePercentage
                )

                IadenteNotice(
                    text: IadenteL10n.t("硬件电量通常会与菜单栏中的 macOS 电量相差几个百分点，属正常现象。", "Hardware percentage usually differs from the macOS menu bar value by a few points; this is normal."),
                    icon: "info.circle.fill",
                    colors: IadenteTheme.generalColors
                )
            }
        }
    }
}
