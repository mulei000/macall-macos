import Foundation
import AppKit
import MachO

/// 崩溃记录器：捕获未捕获异常与致命信号，把可读的崩溃日志写到
/// ~/Library/Application Support/macall/Crashes/，供后续修复定位。
///
/// - 未捕获异常（NSException）：在主线程安全上下文记录完整调用栈符号。
/// - 致命信号（SIGSEGV/SIGABRT/...）：信号处理器内记录信号名、**出错指令地址**
///   与原始栈地址，随后还原默认处理并重新触发，让系统也生成标准崩溃报告。
///
/// ## 定位崩溃的正确姿势（build 39 起）
///
/// 信号处理器里 `backtrace()` 在 arm64 上**重建的栈帧并不可靠**——build 38 那次
/// SIGTRAP 就因此把排查引到了完全无关的函数上。真正有用的是本文件记录的
/// `imageOffset`（出错指令相对可执行文件加载基址的偏移），它与系统崩溃报告里
/// 的 `imageOffset` 是同一个值，可以直接：
///
/// ```sh
/// otool -arch arm64 -tV -j macall.app/Contents/MacOS/macall \
///   | grep -A2 -B20 '00000001000<offset>'
/// ```
///
/// 权威来源始终是系统生成的 `~/Library/Logs/DiagnosticReports/macall-*.ips`
/// （已符号化）。本记录器只做「立刻可见 + 指路」。
final class CrashReporter {
    static let shared = CrashReporter()

    /// 崩溃日志目录：~/Library/Application Support/macall/Crashes
    let crashDir: URL

    /// 系统标准崩溃报告目录：~/Library/Logs/DiagnosticReports
    let systemReportsDir: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)

    private let lastSeenKey = "macall.lastSeenCrashTime"
    private static var handlingSignal = false

    /// 主可执行文件的 ASLR 偏移。运行期地址减去它即得 `imageOffset`。
    private static let imageSlide: UInt = UInt(bitPattern: _dyld_get_image_vmaddr_slide(0))

    private init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        crashDir = support.appendingPathComponent("macall/Crashes", isDirectory: true)
        try? FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)
    }

    // MARK: - 安装

    func install() {
        // 注意：C 函数指针上下文不能捕获变量，故直接用单例转发（不捕获 self）。
        NSSetUncaughtExceptionHandler { exc in
            CrashReporter.shared.recordException(exc)
        }
        // 用 sigaction + SA_SIGINFO 代替 signal()，这样才能拿到 ucontext_t，
        // 从中读出出错时的 PC —— 这是唯一真正可靠的崩溃定位信息。
        var sa = sigaction()
        sa.__sigaction_u.__sa_sigaction = crashSignalHandler
        sa.sa_flags = SA_SIGINFO | SA_ONSTACK
        sigemptyset(&sa.sa_mask)
        for sig in [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            sigaction(sig, &sa, nil)
        }
    }

    // MARK: - 元数据

    private var appVersion: String {
        let b = Bundle.main
        let v = b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let bld = b.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (build \(bld))"
    }

    private var timestamp: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HHmmss"
        return fmt.string(from: Date())
    }

    // MARK: - 异常处理

    private func recordException(_ exc: NSException) {
        let name = exc.name.rawValue
        let reason = exc.reason ?? "(no reason)"
        let stack = exc.callStackSymbols.joined(separator: "\n")
        let body = """
        macall 崩溃记录
        时间: \(Date())
        版本: \(appVersion)
        类型: 未捕获异常 (NSException)
        异常名: \(name)
        原因: \(reason)

        ===== 调用栈 =====
        \(stack)
        """
        writeFile(body, suffix: "exception")
    }

    // MARK: - 信号处理

    private func recordSignal(_ sig: Int32, faultPC: UInt, faultAddr: UInt) {
        let slide = CrashReporter.imageSlide
        var lines = [
            "macall 崩溃记录",
            "时间: \(Date())",
            "版本: \(appVersion)",
            "类型: 致命信号 \(signalName(sig)) (\(sig))",
            "",
            "===== 关键定位信息（看这里就够）=====",
        ]
        if faultPC != 0 {
            lines.append(String(format: "  出错指令 PC      : 0x%016llx", UInt64(faultPC)))
            lines.append(String(format: "  可执行文件 slide : 0x%llx", UInt64(slide)))
            lines.append(String(
                format: "  imageOffset      : 0x%llx   ← 用这个值定位",
                UInt64(faultPC &- slide)
            ))
            lines.append(String(
                format: "  链接地址(反汇编)  : 0x%016llx",
                UInt64(0x1_0000_0000 &+ (faultPC &- slide))
            ))
        } else {
            lines.append("  （本次未能取到 PC，请以系统崩溃报告为准）")
        }
        if faultAddr != 0 {
            lines.append(String(format: "  访问出错地址      : 0x%016llx", UInt64(faultAddr)))
        }
        lines.append(contentsOf: [
            "",
            "===== 权威崩溃报告（已符号化，优先看它）=====",
            "  \(systemReportsDir.path)/macall-*.ips",
            "  在「访达」按 ⇧⌘G 粘贴上面的目录即可打开。",
            "",
            "===== 反汇编定位命令 =====",
            "  otool -arch arm64 -tV -j <可执行文件路径> > /tmp/d.txt",
            "  然后在 /tmp/d.txt 里搜上面的「链接地址」。",
            "",
            "===== 原始调用栈地址（信号处理器内重建，仅供参考，可能不准）=====",
        ])
        var addrs = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let n = backtrace(&addrs, Int32(addrs.count))
        for i in 0..<Int(n) {
            if let a = addrs[i] {
                let addr = UInt(bitPattern: a)
                lines.append(String(
                    format: "  frame %2d: 0x%016llx  (imageOffset 0x%llx)",
                    i, UInt64(addr), UInt64(addr &- slide)
                ))
            }
        }
        writeFile(lines.joined(separator: "\n"), suffix: "signal-\(signalName(sig))")
    }

    private func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGSEGV: return "SIGSEGV"
        case SIGABRT: return "SIGABRT"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGFPE: return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        default: return "SIG\(sig)"
        }
    }

    fileprivate func handleSignal(
        _ sig: Int32,
        _ info: UnsafeMutablePointer<siginfo_t>?,
        _ ucontext: UnsafeMutableRawPointer?
    ) {
        if CrashReporter.handlingSignal { return }
        CrashReporter.handlingSignal = true

        var pc: UInt = 0
        #if arch(arm64)
        if let uc = ucontext?.assumingMemoryBound(to: ucontext_t.self),
           let mc = uc.pointee.uc_mcontext {
            pc = UInt(mc.pointee.__ss.__pc)
        }
        #elseif arch(x86_64)
        if let uc = ucontext?.assumingMemoryBound(to: ucontext_t.self),
           let mc = uc.pointee.uc_mcontext {
            pc = UInt(mc.pointee.__ss.__rip)
        }
        #endif
        var faultAddr: UInt = 0
        if let i = info { faultAddr = UInt(bitPattern: i.pointee.si_addr) }

        recordSignal(sig, faultPC: pc, faultAddr: faultAddr)
        // 还原默认处理并重新触发，让系统也生成标准崩溃报告。
        signal(sig, SIG_DFL)
        raise(sig)
    }

    // MARK: - 文件写入

    private func writeFile(_ content: String, suffix: String) {
        let fn = "crash-\(timestamp)-\(suffix).log"
        let url = crashDir.appendingPathComponent(fn)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 上次崩溃检测

    /// 返回自上次查看以来新产生的崩溃日志；同时更新“已查看”时间戳避免重复提示。
    func checkPreviousCrashes() -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: crashDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        let lastSeen = UserDefaults.standard.double(forKey: lastSeenKey)
        let now = Date().timeIntervalSince1970
        let recent = files
            .filter { $0.pathExtension == "log" }
            .compactMap { url -> (URL, Double)? in
                guard let d = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate else { return nil }
                let t = d.timeIntervalSince1970
                return (t > lastSeen && t <= now) ? (url, t) : nil
            }
            .sorted { $0.1 < $1.1 }
            .map { $0.0 }

        if !recent.isEmpty {
            UserDefaults.standard.set(now, forKey: lastSeenKey)
        }
        return recent
    }

    /// 系统生成的标准崩溃报告（已符号化），按时间倒序。这是定位崩溃的权威来源。
    func systemCrashReports() -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: systemReportsDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        return files
            .filter { $0.lastPathComponent.hasPrefix("macall-") && $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date)? in
                guard let d = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate else { return nil }
                return (url, d)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    /// 在 Finder 中打开崩溃日志目录。
    func openCrashesFolder() {
        NSWorkspace.shared.open(crashDir)
    }

    /// 在 Finder 中选中最新一份系统崩溃报告；没有则打开报告目录。
    func revealLatestSystemReport() {
        if let latest = systemCrashReports().first {
            NSWorkspace.shared.activateFileViewerSelecting([latest])
        } else {
            NSWorkspace.shared.open(systemReportsDir)
        }
    }
}

/// C 调用约定的信号分发器（不能捕获 self，故用全局函数转发到单例）。
fileprivate func crashSignalHandler(
    _ sig: Int32,
    _ info: UnsafeMutablePointer<siginfo_t>?,
    _ ucontext: UnsafeMutableRawPointer?
) {
    CrashReporter.shared.handleSignal(sig, info, ucontext)
}
