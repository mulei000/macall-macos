import Foundation
import IOKit
import IOKit.ps
import Darwin

// MARK: - 快照模型

/// 某一时刻的电池快照。百分比/充电状态/剩余时间来自 IOKit 公开 API；
/// 循环次数、设计容量、健康度、电池温度也直接取自同一 IOPowerSource blob（无需特权 Helper）。
struct BatterySnapshot: Equatable {
    var percentage: Int = -1
    var isCharging: Bool = false
    var onACPower: Bool = false
    var timeToEmptyMinutes: Int = -1
    var timeToFullMinutes: Int = -1

    // MARK: - 电池健康深度（取自 maconitor 的 BatteryMetrics）
    /// 循环次数（CycleCount）。0 表示读取失败。
    var cycleCount: Int = 0
    /// 设计容量（mAh），DesignCapacity。
    var designCapacity: Int = 0
    /// 当前满充容量（mAh），AppleRawMaxCapacity。
    var maxCapacity: Int = 0
    /// 健康度百分比（maxCapacity / designCapacity 推算），-1 表示未知。
    var healthPercent: Int = -1

    var isValid: Bool { percentage >= 0 }
}

/// CPU 占用快照（百分比）。
struct CPUSnapshot: Equatable {
    /// 用户态占比
    var user: Double = 0
    /// 系统态占比
    var system: Double = 0
    /// 空闲占比
    var idle: Double = 0
    /// 活跃（用户+系统+低优先级）合计占比
    var active: Double { user + system }

    var isValid: Bool { user + system + idle > 0 }
}

/// 内存快照（字节为单位，外加计算好的占比）。
struct MemorySnapshot: Equatable {
    var totalBytes: UInt64 = 0
    var usedBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0

    var isValid: Bool { totalBytes > 0 }
    var usedPercent: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) * 100 : 0 }
}

/// 磁盘快照（根卷）。
struct DiskSnapshot: Equatable {
    var totalBytes: UInt64 = 0
    var usedBytes: UInt64 = 0
    var freeBytes: UInt64 = 0

    var isValid: Bool { totalBytes > 0 }
    var usedPercent: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) * 100 : 0 }
}

/// 网络吞吐快照（每秒字节数）。
struct NetworkSnapshot: Equatable {
    var inBytesPerSec: Double = 0
    var outBytesPerSec: Double = 0
    var totalInBytes: UInt64 = 0
    var totalOutBytes: UInt64 = 0

    var isValid: Bool { true }
}

/// 聚合的系统快照。
struct SystemSnapshot: Equatable {
    var battery = BatterySnapshot()
    var cpu = CPUSnapshot()
    var memory = MemorySnapshot()
    var disk = DiskSnapshot()
    var network = NetworkSnapshot()

    // MARK: - SMC 派生（温度 / 风扇 / 功率），读取失败为 nil
    var cpuTempC: Double? = nil
    var fanRPM: Double? = nil
    var batteryPower: Double? = nil
    var adapterPower: Double? = nil

    // MARK: - 实时耗电 App（按 CPU 活动聚合），无需权限
    var topEnergyApps: [AppEnergyUsageSnapshot] = []
}

// MARK: - 读取器（全部无需任何权限 / 特权 Helper）

enum MonitorModels {
    // MARK: 电池（IOKit 公开 API，沿用 maconitor 已验证写法）

    static func readBattery() -> BatterySnapshot {
        var result = BatterySnapshot()
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return result }
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as? [CFDictionary] ?? []
        for item in sources {
            guard let dict = item as? [String: Any] else { continue }
            guard let type = dict[kIOPSTypeKey as String] as? String,
                  type == kIOPSInternalBatteryType else { continue }
            let current = Double(dict[kIOPSCurrentCapacityKey as String] as? Int ?? 0)
            let cap = Double(dict[kIOPSMaxCapacityKey as String] as? Int ?? 0)
            if cap > 0 { result.percentage = Int((current / cap) * 100) }
            result.isCharging = (dict[kIOPSIsChargingKey as String] as? Bool) ?? false
            let state = dict[kIOPSPowerSourceStateKey as String] as? String
            result.onACPower = (state == kIOPSACPowerValue)
            if let t = dict[kIOPSTimeToEmptyKey as String] as? Int, t > 0 { result.timeToEmptyMinutes = t }
            if let t = dict[kIOPSTimeToFullChargeKey as String] as? Int, t > 0 { result.timeToFullMinutes = t }
        }

        // 电池健康深度：循环次数 / 设计容量 / 当前满充容量。
        // IOPowerSource blob 在现代 macOS（Apple Silicon / Ventura+）大多不再暴露这些字段，
        // 可靠来源是 `ioreg -rn AppleSmartBattery`。这些值在单次开机内基本不变，
        // 故缓存一次（见 readBatteryHealth），避免每 2 秒 spawn 进程。
        let health = MonitorModels.readBatteryHealth()
        result.cycleCount = health.cycleCount
        result.designCapacity = health.designCapacity
        result.maxCapacity = health.maxCapacity
        if health.designCapacity > 0, health.maxCapacity > 0 {
            result.healthPercent = min(
                100,
                Int((Double(health.maxCapacity) / Double(health.designCapacity) * 100).rounded())
            )
        }
        return result
    }

    // MARK: 电池健康深度（循环次数 / 设计容量 / 当前满充容量）

    /// 单次开机内不变的电池健康读数，缓存避免每 2 秒 spawn `ioreg`。
    private static var cachedBatteryHealth: (
        cycleCount: Int, designCapacity: Int, maxCapacity: Int
    )?

    /// 从 `ioreg -rn AppleSmartBattery` 解析循环次数、设计容量与当前满充容量。
    /// 这些值在 IOPowerSource blob 中往往缺失（尤其 Apple Silicon / 新系统），
    /// 而 ioreg 始终可靠暴露 `CycleCount` / `DesignCapacity` / `AppleRawMaxCapacity`。
    /// 全程无需特权 Helper。
    static func readBatteryHealth() -> (
        cycleCount: Int, designCapacity: Int, maxCapacity: Int
    ) {
        if let cached = cachedBatteryHealth { return cached }

        var cycleCount = 0
        var designCapacity = 0
        var maxCapacity = 0

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-rn", "AppleSmartBattery"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else {
                cachedBatteryHealth = (0, 0, 0)
                return (0, 0, 0)
            }
            // ioreg 每行形如 `"CycleCount" = 26` / `"DesignCapacity" = 4629` /
            // `"AppleRawMaxCapacity" = 4563`，用正则抓取首个整数值即可。
            cycleCount = intAfterKey("CycleCount", in: text)
            designCapacity = intAfterKey("DesignCapacity", in: text)
            maxCapacity = intAfterKey("AppleRawMaxCapacity", in: text)
        } catch {
            cachedBatteryHealth = (0, 0, 0)
            return (0, 0, 0)
        }

        cachedBatteryHealth = (cycleCount, designCapacity, maxCapacity)
        return (cycleCount, designCapacity, maxCapacity)
    }

    /// 抓取 `"<key>" = <int>` 形式的值（取该行等号后的首个整数）。
    private static func intAfterKey(_ key: String, in text: String) -> Int {
        let pattern = "\"\(key)\"\\s*=\\s*(-?\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: text, range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range(at: 1), in: text),
              let value = Int(text[range])
        else { return 0 }
        return value
    }


    // MARK: CPU（host_statistics，HOST_CPU_LOAD_INFO）

    /// 返回 (user, system, idle, nice) 四个 tick 计数，失败返回 nil。
    static func readCPUTicks() -> (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)? {
        let ptr = UnsafeMutablePointer<host_cpu_load_info>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size
        )
        let kr = ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = ptr.pointee.cpu_ticks
        return (UInt64(t.0), UInt64(t.1), UInt64(t.2), UInt64(t.3))
    }

    // MARK: 内存（host_statistics64，HOST_VM_INFO64 + sysctl hw.memsize）

    static func readMemory() -> MemorySnapshot {
        var s = MemorySnapshot()
        var psz = vm_size_t(0)
        host_page_size(mach_host_self(), &psz)
        let page = UInt64(psz)

        var memsize: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memsize, &len, nil, 0)
        s.totalBytes = memsize

        let ptr = UnsafeMutablePointer<vm_statistics64>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )
        let kr = ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
        }
        guard kr == KERN_SUCCESS else { return s }

        let st = ptr.pointee
        let free = UInt64(st.free_count) * page
        let active = UInt64(st.active_count)
        let wire = UInt64(st.wire_count)
        s.freeBytes = free
        s.wiredBytes = wire * page
        // 「已用」对齐 Activity Monitor 的 Memory Used = App(活跃) + 联动内存；
        // 非活跃内存属可回收缓存，不计入已用，避免仪表盘数值虚高。
        s.usedBytes = (active + wire) * page
        return s
    }

    // MARK: 磁盘（statfs，根卷）

    static func readDisk() -> DiskSnapshot {
        var s = DiskSnapshot()
        let ptr = UnsafeMutablePointer<statfs>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        guard statfs("/", ptr) == 0 else { return s }
        let fs = ptr.pointee
        let bsize = UInt64(fs.f_bsize)
        s.totalBytes = UInt64(fs.f_blocks) * bsize
        s.freeBytes = UInt64(fs.f_bfree) * bsize
        // 防御性：APFS 容器共享空间时 f_bfree 理论上可能瞬时大于 f_blocks，
        // 直接相减会让 UInt64 下溢并触发 Swift 运行时陷阱（SIGTRAP）。
        s.usedBytes = s.totalBytes >= s.freeBytes ? s.totalBytes - s.freeBytes : 0
        return s
    }

    // MARK: 网络（getifaddrs，累计字节数；速率由 SystemMonitor 按时间差计算）

    static func readNetworkTotals() -> (in: UInt64, out: UInt64) {
        var inTotal: UInt64 = 0
        var outTotal: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let head = ifaddr else { return (0, 0) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = head
        while let p = ptr {
            let info = p.pointee
            let name = String(cString: info.ifa_name)
            // Skip loopback (lo0) and any interface that is down or
            // point-to-point (awdl/llw: Wi-Fi Aware / Bluetooth PAN). Counting
            // those produced spurious 0.0 / inflated throughput readings.
            let flags = Int32(info.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isP2P = (flags & IFF_POINTOPOINT) != 0
            if name != "lo0", isUp, !isP2P, let data = info.ifa_data {
                let stats = data.assumingMemoryBound(to: if_data.self).pointee
                inTotal += UInt64(stats.ifi_ibytes)
                outTotal += UInt64(stats.ifi_obytes)
            }
            ptr = info.ifa_next
        }
        freeifaddrs(ifaddr)
        return (inTotal, outTotal)
    }

    // MARK: 工具

    /// 把字节数格式化为友好单位（B / KB / MB / GB / TB）。
    static func formatBytes(_ bytes: Double) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        fmt.countStyle = .file
        fmt.includesUnit = true
        fmt.zeroPadsFractionDigits = false
        return fmt.string(fromByteCount: Int64(bytes))
    }

    /// 把「每秒字节数」格式化为友好单位，带方向箭头。
    static func formatThroughput(_ bytesPerSec: Double) -> String {
        guard bytesPerSec > 0 else { return "0 KB/s" }
        return formatBytes(bytesPerSec) + "/s"
    }
}
