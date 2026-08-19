import AppKit
import Foundation

/// 实时耗电（CPU 活动）应用排行。照搬 macometer 的 `AppEnergyUsageService`：
/// 用 `/bin/ps` 读取每个进程的 CPU 占用，按 .app 聚合，无需任何权限 / 特权 Helper。
/// 这对应 maconitor「实时耗电 App」功能，是用户要求补回的部分。
enum AppEnergyService {
    static func readTopApps(limit: Int = 4) -> [AppEnergyUsageSnapshot] {
        let process = Process()
        let output = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-wwaxo", "pid=,%cpu=,comm="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
            let text = String(data: data, encoding: .utf8)
        else {
            return []
        }

        var totals: [String: (name: String, cpuUsage: Double, pids: [pid_t])] = [:]

        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(
                maxSplits: 2,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 3,
                let pid = Int32(fields[0]),
                let cpuUsage = Double(fields[1]),
                cpuUsage > 0,
                let app = appIdentity(from: String(fields[2])),
                app.name.caseInsensitiveCompare("macall") != .orderedSame
            else {
                continue
            }

            var entry = totals[app.bundlePath]
                ?? (name: app.name, cpuUsage: 0, pids: [])
            entry.cpuUsage += cpuUsage
            entry.pids.append(pid)
            totals[app.bundlePath] = entry
        }

        return totals
            .map {
                AppEnergyUsageSnapshot(
                    bundlePath: $0.key,
                    name: $0.value.name,
                    cpuUsage: $0.value.cpuUsage,
                    pids: $0.value.pids
                )
            }
            .sorted {
                if $0.cpuUsage == $1.cpuUsage {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return $0.cpuUsage > $1.cpuUsage
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    private static func appIdentity(from command: String) -> (
        bundlePath: String,
        name: String
    )? {
        guard command.hasPrefix("/Applications/")
                || command.hasPrefix("/System/Applications/"),
            let appSuffix = command.range(of: ".app/")
        else {
            return nil
        }

        let appEnd = command.index(appSuffix.lowerBound, offsetBy: 4)
        let bundlePath = String(command[..<appEnd])
        let name = URL(fileURLWithPath: bundlePath)
            .deletingPathExtension()
            .lastPathComponent

        guard !name.isEmpty else { return nil }
        return (bundlePath, name)
    }

    struct ForceTerminateResult {
        let killed: Int
        let protected: Int
        let failed: [pid_t]
    }

    /// 强制终止某应用的所有进程（SIGKILL）。保护 macall 自身与 Finder 等系统关键应用。
    @MainActor
    static func forceTerminate(_ snapshot: AppEnergyUsageSnapshot) -> ForceTerminateResult {
        var protectedIDs = Set<String>(["com.apple.finder"])
        if let mine = Bundle.main.bundleIdentifier {
            protectedIDs.insert(mine)
        }
        var killed = 0
        var protectedCount = 0
        var failed: [pid_t] = []

        for pid in snapshot.pids {
            let app = NSRunningApplication(processIdentifier: pid)
            if let bundleID = app?.bundleIdentifier, protectedIDs.contains(bundleID) {
                protectedCount += 1
                continue
            }
            let signalResult = kill(pid, SIGKILL)
            if signalResult == 0 {
                killed += 1
            } else {
                failed.append(pid)
            }
        }

        return ForceTerminateResult(killed: killed, protected: protectedCount, failed: failed)
    }
}
