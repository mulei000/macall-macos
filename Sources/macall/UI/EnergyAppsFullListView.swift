import AppKit
import SwiftUI

/// 耗电应用「查看全部」窗口：列出 CPU 活动 ≥ 0.1% 的所有前台应用。
/// 照搬 macometer 的 `EnergyAppsFullListView`，仅在窗口打开期间轮询，关闭即停止。
struct EnergyAppsFullListView: View {
    @Default(.appLanguage) private var appLanguage
    @Environment(\.colorScheme) private var colorScheme

    @State private var apps: [AppEnergyUsageSnapshot] = []
    @State private var isSampling = true
    @State private var confirmTarget: AppEnergyUsageSnapshot? = nil
    @State private var toast: String? = nil
    @State private var isLocked = false

    private var maxCPU: Double {
        max(apps.map(\.cpuUsage).max() ?? 1, 0.1)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(.primary.opacity(0.11))
                .frame(height: 1)

            if let toast {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(toast)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
            }

            if isLocked {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(IadenteTheme.amber)
                    Text(IadenteL10n.t(
                        "已锁定：列表已冻结，可安全点击关闭",
                        "Locked: list frozen, safe to tap close"
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(IadenteTheme.amber.opacity(0.14))
            }

            ScrollView {
                if isSampling && apps.isEmpty {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(IadenteL10n.t("正在采样当前应用活动…"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                } else if apps.isEmpty {
                    Text(IadenteL10n.t("没有检测到耗电 ≥ 0.1% 的前台应用", "No foreground apps using ≥ 0.1% CPU"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(20)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                            EnergyAppRow(
                                rank: index + 1,
                                app: app,
                                maximumCPUUsage: maxCPU,
                                tint: Self.tint(for: index),
                                onForceClose: { confirmTarget = app }
                            )
                        }
                    }
                    .padding(12)
                }
            }
            .scrollIndicators(.never)
        }
        .frame(width: 360, height: 440)
        .background(IadenteWindowBackdrop())
        .tint(IadenteTheme.jade)
        .task { await pollLoop() }
        .alert(item: $confirmTarget) { app in
            Alert(
                title: Text(IadenteL10n.t("强制关闭 \(app.name)？", "Force close \(app.name)?")),
                message: Text(IadenteL10n.t(
                    "应用将被立即终止，未保存的数据可能丢失。",
                    "The app will be terminated immediately. Unsaved data may be lost."
                )),
                primaryButton: .destructive(Text(IadenteL10n.t("强制关闭", "Force Close"))) {
                    let result = AppEnergyService.forceTerminate(app)
                    if result.killed > 0 {
                        showToast(IadenteL10n.t("已强制关闭 \(app.name)", "Force-closed \(app.name)"))
                    } else if result.protected > 0 {
                        showToast(IadenteL10n.t(
                            "\(app.name) 是系统关键应用，无法关闭",
                            "\(app.name) is a protected system app"
                        ))
                    } else {
                        showToast(IadenteL10n.t(
                            "\(app.name) 已退出或无权限",
                            "\(app.name) already quit or no permission"
                        ))
                    }
                    if !isLocked {
                        Task { await sample() }
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            IadenteIconBadge(
                icon: "bolt.horizontal.circle.fill",
                colors: [IadenteTheme.ocean, IadenteTheme.sky],
                size: 30
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(IadenteL10n.t("耗电应用（全部）", "All Energy Apps"))
                    .font(.system(size: 14, weight: .semibold))
                Text(IadenteL10n.t("按 CPU 活动实时估算，列出 ≥ 0.1% 的应用", "Ranked by live CPU activity, apps ≥ 0.1%"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                isLocked.toggle()
            } label: {
                Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(isLocked ? IadenteTheme.amber : .secondary)
            }
            .buttonStyle(.plain)
            .help(
                isLocked
                    ? IadenteL10n.t("已锁定，点击解锁", "Locked — click to unlock")
                    : IadenteL10n.t("锁定列表，防止误点", "Lock list to prevent mis-taps")
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            if !isLocked {
                await sample()
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func sample() async {
        let result = AppEnergyService.readTopApps(limit: 50)
        await MainActor.run {
            apps = result
            isSampling = false
        }
    }

    private func showToast(_ message: String) {
        toast = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if toast == message {
                toast = nil
            }
        }
    }

    private static func tint(for index: Int) -> Color {
        switch index {
        case 0: IadenteTheme.amber
        case 1: IadenteTheme.ocean
        case 2: IadenteTheme.violet
        default: IadenteTheme.sky
        }
    }
}
