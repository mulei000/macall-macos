import CoreGraphics
import Darwin
import Foundation
import IOKit

// MARK: - DDC / DisplayServices 显示器控制

/// 外接显示器控制：亮度（DisplayServices，Apple Silicon 上真实可用）+ 音量 / 输入源（DDC-CI over I2C，best-effort）。
///
/// 现代 macOS（尤其 Apple Silicon）上，DisplayServices 私有框架可设置受支持显示器的亮度；
/// 而 DDC-CI 音量 / 输入源需走 I2C（IOI2CInterface 用户客户端）。后者依赖真实外接显示器，
/// 且 `IOI2CRequest` 是 `#pragma pack(4)` + 指针字段的结构，Swift 无法自然对齐，
/// 因此这里手动按偏移构造请求缓冲（详见 SDK 头 `IOI2CInterface.h`）。此路径在真实硬件上才能验证。
enum DDC {

    // MARK: - DisplayServices（亮度，dlsym 运行时探测）

    private static let dsHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    }()

    private typealias DSGetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> CGError
    private typealias DSSetBrightness = @convention(c) (CGDirectDisplayID, Float) -> CGError

    /// 设置显示器亮度（0…1）。返回是否成功（失败通常是显示器不被 DisplayServices 支持）。
    @discardableResult
    static func setBrightness(display: CGDirectDisplayID, level: Float) -> Bool {
        guard let handle = dsHandle,
              let sym = dlsym(handle, "DisplayServicesSetBrightness") else { return false }
        let fn = unsafeBitCast(sym, to: DSSetBrightness.self)
        return fn(display, max(0, min(1, level))).rawValue == 0
    }

    /// 读取显示器亮度（0…1）。
    static func getBrightness(display: CGDirectDisplayID) -> Float? {
        guard let handle = dsHandle,
              let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        let fn = unsafeBitCast(sym, to: DSGetBrightness.self)
        var v: Float = 0
        guard fn(display, &v).rawValue == 0 else { return nil }
        return v
    }

    // MARK: - DDC-CI over I2C（音量 / 输入源，best-effort）

    /// VCP 指令码。
    enum VCP: UInt8 {
        case brightness = 0x10
        case volume = 0x62
        case inputSource = 0x60
    }

    // IOI2CRequest 字段偏移（来自 SDK `IOI2CInterface.h`，#pragma pack(4)，LP64）。
    // 结构总大小 124 字节；sendBuffer @ 68，replyBuffer @ 76（均为 8 字节指针）。
    private static let kStructSize = 124
    private static let kSendBufferOffset = 68
    private static let kReplyBufferOffset = 76

    /// 找到第一个可用的 I2C 接口连接（best-effort）。直接匹配 `IOI2CInterface` 服务并打开用户客户端。
    private static func openI2CConnection() -> io_connect_t? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMasterPortDefault,
                                           IOServiceMatching("IOI2CInterface"), &iter) == KERN_SUCCESS else {
            return nil
        }
        var result: io_connect_t?
        while true {
            let svc = IOIteratorNext(iter)
            if svc == 0 { break }
            var conn: io_connect_t = 0
            if IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS {
                result = conn
                IOObjectRelease(svc)
                break
            }
            IOObjectRelease(svc)
        }
        IOObjectRelease(iter)
        return result
    }

    /// 构造 IOI2CRequest struct（124 字节），并把 send / reply 缓冲**内联**其后，
    /// 指针字段写入内联缓冲的真实地址（避免悬垂指针）。返回整段 Data（含内联缓冲）。
    ///
    /// - `replyCapacity` 为 0 表示纯写（replyTransactionType = 0）；
    ///   大于 0 表示读（调用方应随后把 replyTransactionType 覆盖为 `kIOI2CDDCciReplyTransactionType = 2`）。
    private static func makeRequest(send: [UInt8], replyCapacity: Int) -> Data {
        let sendOffset = kStructSize
        let replyOffset = kStructSize + send.count
        let total = replyOffset + replyCapacity
        var data = Data(count: total)

        // IOI2CRequest 字段
        data.setGeneric(UInt32(3), at: 0)    // sendTransactionType = kIOI2CCombinedTransactionType
        data.setGeneric(UInt32(0), at: 4)    // replyTransactionType（读时覆盖为 2）
        data.setGeneric(UInt32(0x6E), at: 8) // sendAddress  = 0x37 << 1
        data.setGeneric(UInt32(0x6F), at: 12) // replyAddress = 0x37 << 1 | 1
        data.setGeneric(UInt8(0x51), at: 16)  // sendSubAddress = 0x51 (DDC-CI command)
        data.setGeneric(UInt64(0), at: 20)    // minReplyDelay
        data.setGeneric(Int32(0), at: 28)     // result
        data.setGeneric(UInt32(2), at: 32)    // commFlags = kIOI2CUseSubAddressCommFlag
        data.setGeneric(UInt32(send.count), at: 40) // sendBytes
        data.setGeneric(UInt32(replyCapacity), at: 56) // replyBytes
        // 内联 send 缓冲
        data.replaceSubrange(sendOffset..<(sendOffset + send.count), with: send)

        // 指针字段：在唯一一次可变借用内写入内联缓冲的真实地址
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let base = raw.baseAddress!
            raw.storeBytes(of: UInt(bitPattern: base) + UInt(sendOffset),
                           toByteOffset: kSendBufferOffset, as: UInt.self)
            if replyCapacity > 0 {
                raw.storeBytes(of: UInt(bitPattern: base) + UInt(replyOffset),
                               toByteOffset: kReplyBufferOffset, as: UInt.self)
            }
        }
        return data
    }

    /// 发送一条 DDC/CI 写指令（VCP + 16 位值）。
    @discardableResult
    static func sendVCP(_ vcp: VCP, value: UInt16) -> Bool {
        guard let conn = openI2CConnection() else { return false }
        defer { IOServiceClose(conn) }

        // DDC/CI 写消息信封（0x84 + 0x03 + VCP + 0x00 + hi + lo + 0x00 + 0x00 + 校验和）。
        let hi = UInt8((value >> 8) & 0xFF)
        let lo = UInt8(value & 0xFF)
        let header: [UInt8] = [0x84, 0x03, vcp.rawValue, 0x00, hi, lo, 0x00, 0x00]
        let checksum = UInt8(header.reduce(0, +) & 0xFF)
        let message = header + [checksum]

        let req = makeRequest(send: message, replyCapacity: 0)
        let status = req.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> kern_return_t in
            IOConnectCallStructMethod(conn, 0, raw.baseAddress, req.count, nil, nil)
        }
        return status == KERN_SUCCESS
    }

    /// 读取一条 DDC/CI 值（best-effort，返回低字节）。
    static func readVCP(_ vcp: VCP) -> UInt16? {
        guard let conn = openI2CConnection() else { return nil }
        defer { IOServiceClose(conn) }

        let readCmd: [UInt8] = [0x84, 0x03, vcp.rawValue, 0x00]
        let replyCapacity = 12
        var req = makeRequest(send: readCmd, replyCapacity: replyCapacity)
        // 读：replyTransactionType = kIOI2CDDCciReplyTransactionType (2)
        req.setGeneric(UInt32(2), at: 4)

        let status = req.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> kern_return_t in
            IOConnectCallStructMethod(conn, 0, raw.baseAddress, req.count, nil, nil)
        }
        guard status == KERN_SUCCESS else { return nil }

        // 读取内联 reply 缓冲（best-effort 取末两字节作为当前值）
        let replyOffset = kStructSize + readCmd.count
        let reply = req.subdata(in: replyOffset..<(replyOffset + replyCapacity))
        let bytes = [UInt8](reply)
        guard bytes.count >= 2 else { return nil }
        return UInt16(bytes[bytes.count - 2]) | (UInt16(bytes[bytes.count - 1]) << 8)
    }
}

// MARK: - Data 小端写入辅助

private extension Data {
    mutating func setGeneric<T>(_ value: T, at offset: Int) {
        var v = value
        Swift.withUnsafeBytes(of: &v) { src in
            self.replaceSubrange(offset..<(offset + src.count), with: src)
        }
    }
}
