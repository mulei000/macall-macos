import Foundation

/// 系统硬件传感器读取：CPU 温度与风扇转速。
/// 通过 SMCKit 直接读取 SMC 键值，多个候选键依次尝试以兼容不同机型。
public enum SMCSensors {
    /// CPU 温度（摄氏度）。读取失败或数值异常时返回 nil。
    public static func cpuTemperatureC() -> Double? {
        let candidates: [FourCharCode] = ["Tp0C", "TC0P", "TC0C", "Tc0C", "TC0H", "TC0D"]
        for key in candidates {
            guard let raw: Float = try? SMCKit.shared.read(key) else { continue }
            let celsius = Double(raw)
            if (10...110).contains(celsius) {
                return celsius
            }
        }
        return nil
    }

    /// 风扇实际转速（RPM）。多风扇机型依次尝试，返回首个有效读数。
    public static func fanRPM() -> Double? {
        let candidates: [FourCharCode] = ["F0Ac", "F1Ac", "F2Ac"]
        for key in candidates {
            guard let raw: Float = try? SMCKit.shared.read(key) else { continue }
            let rpm = Double(raw)
            if rpm > 0 {
                return rpm
            }
        }
        return nil
    }
}
