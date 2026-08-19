import Foundation
import os.log

/// 轻量日志封装：同时写入系统 `os_log` 与本地文件 `~/Library/Logs/macall/macall.log`，
/// 方便用户在真机复现问题后把日志反馈回来定位。
///
/// 文件日志会自动轮转（超过 2MB 时保留尾部 1MB），避免无限增长。
enum Log {
    private static let subsystem = "com.macall.app"

    private static let infoLog = Logger(subsystem: subsystem, category: "info")
    private static let warnLog = Logger(subsystem: subsystem, category: "warn")
    private static let errorLog = Logger(subsystem: subsystem, category: "error")

    /// 串行队列保证文件写入不互相交错。
    private static let queue = DispatchQueue(label: "com.macall.log")

    private static let maxBytes: UInt64 = 2 * 1024 * 1024
    private static let keepBytes: UInt64 = 1 * 1024 * 1024

    private static var fileURL: URL? {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/macall", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return dir.appendingPathComponent("macall.log")
    }

    /// 日志文件公开路径（供「关于」页或用户查阅）。
    static var logFilePath: String {
        fileURL?.path ?? "~/Library/Logs/macall/macall.log"
    }

    static func info(_ message: String) {
        infoLog.info("\(message, privacy: .public)")
        write(level: "INFO", message)
    }

    static func warning(_ message: String) {
        warnLog.warning("\(message, privacy: .public)")
        write(level: "WARN", message)
    }

    static func error(_ message: String) {
        errorLog.error("\(message, privacy: .public)")
        write(level: "ERROR", message)
    }

    /// 仅在 DEBUG / 首次启动时打印一次日志路径，避免噪音。
    static func startup(_ message: String) {
        info(message)
        if let url = fileURL {
            info("日志文件位置：\(url.path)")
        }
    }

    private static func write(level: String, _ message: String) {
        guard let url = fileURL else { return }
        queue.async {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            let stamp = df.string(from: Date())
            let line = "\(stamp) [\(level)] \(message)\n"

            // 超过上限时做尾部截断轮转。
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64,
                size > maxBytes {
                truncate(url: url, keep: keepBytes)
            }

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func truncate(url: URL, keep: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let total = (try? handle.seekToEnd()) ?? 0
        guard total > keep else { return }
        handle.seek(toFileOffset: total - keep)
        let rest = handle.readDataToEndOfFile()
        try? rest.write(to: url, options: .atomic)
    }
}
