import Foundation

/// SMC 派生指标读取：直接复用 macometer 的 `SMCSensors` / `SMCAdapter` / `SMCBattery`
/// （均基于同一份 vendored SMCKit），公式与 macometer 的 Helper 完全一致：
///   batteryPower = batteryVoltage × batteryCurrent
///   adapterPower = adapterVoltage × adapterCurrent
///   systemPower  = adapterPower − batteryPower   （交由 MenuViewModel 组装）
/// 读取失败（未授权 / 无此机型 SMC 键）时返回 nil，由上层优雅降级为「—」/ 0。
enum SMCReader {
    /// AppleSMC 连接是否可用。不可用时不发起任何读取，避免无谓开销。
    static var isAvailable: Bool { SMCKit.shared.isConnected }

    static func sample() -> (
        cpuTempC: Double?,
        fanRPM: Double?,
        batteryPower: Double?,
        adapterPower: Double?
    ) {
        guard SMCKit.shared.isConnected else {
            return (nil, nil, nil, nil)
        }

        let cpuTempC = SMCSensors.cpuTemperatureC()
        let fanRPM = SMCSensors.fanRPM()

        var batteryPower: Double?
        do {
            let voltage = try SMCBattery.getVoltage()
            let current = try SMCBattery.getCurrent()
            batteryPower = voltage * current
        } catch {
            batteryPower = nil
        }

        var adapterPower: Double?
        do {
            var voltage = try SMCAdapter.getVoltage()
            var current = try SMCAdapter.getCurrent()
            if abs(voltage) < 0.1 { voltage = 0 }
            if abs(current) < 0.1 { current = 0 }
            adapterPower = voltage * current
        } catch {
            adapterPower = nil
        }

        return (cpuTempC, fanRPM, batteryPower, adapterPower)
    }
}
