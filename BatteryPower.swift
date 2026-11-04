// v2.0 电池细化：功率流向、详情、mW 榜、紧凑条（纯计算 + 界面，数据全部来自 Snapshot / EnergyStore）
// 口径说明（界面上也要写清楚，不凑数）：
// - 充电功率 ≈ 电压 × 电流（充电时电流为正才算，电池供电时不算充电功率）
// - 电池供电时系统功耗 = 电池放电功率（电压 × 电流绝对值）
// - 充电时系统功耗 = 充电器输入 − 充入电池；充电器输入读不到时，系统功耗写不可读，
//   绝不用适配器额定功率代替实际输入，也不用显示器等分项去凑总数。
// - 显示器等分项目前没有公开可读接口，已并入系统功耗，不单独列数字。
// - 充满时间 = 剩余容量 ÷ 实际充电功率，是估算，充电功率一变它就变。
import SwiftUI
import AppKit

struct PowerFlow: Equatable {
    var voltageV: Double?
    var currentA: Double?
    var chargeWatts: Double?
    var dischargeWatts: Double?
    var inputWatts: Double?
    var systemWatts: Double?
    var adapterRatedWatts: Double?
    var lowPowerMode: Bool?
    var charging = false
    var onAC = false
    var percent: Int?
    var fullMah = 0
}

enum PowerFlowCalc {
    /// 充电功率：只有充电且电流为正时才有，否则 nil（不把放电功率当充电功率）
    static func chargeWatts(voltageV: Double?, currentA: Double?, charging: Bool) -> Double? {
        guard charging, let v = voltageV, let a = currentA, v > 0, a > 0 else { return nil }
        return v * a
    }
    /// 放电功率：电流为负时取绝对值，否则 nil
    static func dischargeWatts(voltageV: Double?, currentA: Double?) -> Double? {
        guard let v = voltageV, let a = currentA, v > 0, a < 0 else { return nil }
        return v * (-a)
    }
    /// 系统功耗：充电时 = 输入 − 充电（输入读不到则 nil）；电池供电时 = 放电功率
    static func systemWatts(inputWatts: Double?, chargeWatts: Double?, dischargeWatts: Double?, charging: Bool) -> Double? {
        if charging {
            guard let i = inputWatts, let c = chargeWatts else { return nil }
            let s = i - c
            return s >= 0 ? s : nil
        }
        return dischargeWatts
    }
    /// 充满时间（分钟）：剩余容量 mAh × 电压 V ÷ 充电功率 W，再换算；任一值缺失或功率 ≤0 则 nil
    static func minutesToFull(percent: Int?, fullMah: Int, voltageV: Double?, chargeWatts: Double?) -> Double? {
        guard let p = percent, p >= 0, p < 100, fullMah > 0, let v = voltageV, v > 0, let w = chargeWatts, w > 0 else { return nil }
        let remainingWh = Double(fullMah) * Double(100 - p) / 100 / 1000 * v
        return remainingWh / w * 60
    }
    /// 最近一小时平均 mW：上一完整小时焦耳 ÷ 3600 × 1000；上一小时没有数据时，
    /// 用本小时已累计焦耳 ÷ 本小时已过秒数 × 1000（界面注明是本小时累计平均，不是完整小时）
    static func topMW(lastHourJoules: [String: Double], currentHourJoules: [String: Double], secondsIntoHour: Double) -> [(app: String, mw: Double)] {
        let src: [String: Double]
        let seconds: Double
        if !lastHourJoules.isEmpty { src = lastHourJoules; seconds = 3600 }
        else if !currentHourJoules.isEmpty, secondsIntoHour > 0 { src = currentHourJoules; seconds = secondsIntoHour }
        else { return [] }
        return src.map { (app: $0.key, mw: $0.value / seconds * 1000) }.sorted { $0.mw > $1.mw }.prefix(5).map { $0 }
    }
    static func fromSnapshot(_ s: Snapshot) -> PowerFlow {
        let charge = chargeWatts(voltageV: s.batteryVoltageV, currentA: s.batteryCurrentA, charging: s.charging)
        let discharge = dischargeWatts(voltageV: s.batteryVoltageV, currentA: s.batteryCurrentA)
        // 充电器输入目前没有公开可读的实时接口：不编造，留 nil，界面写不可读。
        // 系统功耗在充电时因此也是 nil，在电池供电时等于放电功率。
        return PowerFlow(
            voltageV: s.batteryVoltageV, currentA: s.batteryCurrentA,
            chargeWatts: charge, dischargeWatts: discharge, inputWatts: nil,
            systemWatts: systemWatts(inputWatts: nil, chargeWatts: charge, dischargeWatts: discharge, charging: s.charging),
            adapterRatedWatts: s.batteryAdapterWatts, lowPowerMode: s.lowPowerMode,
            charging: s.charging, onAC: s.onAC, percent: s.battery, fullMah: s.fullMah)
    }
    /// EnergyStore 最近一小时：上一完整小时优先，否则本小时累计
    static func topMW(store: EnergyStore, now: Date) -> [(app: String, mw: Double)] {
        let nowH = Int(now.timeIntervalSince1970 / 3600)
        let last = store.hours[nowH - 1] ?? [:]
        let cur = store.hours[nowH] ?? [:]
        let secInto = now.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600)
        return topMW(lastHourJoules: last, currentHourJoules: cur, secondsIntoHour: secInto)
    }
}

func fmtW(_ w: Double?) -> String { w.map { String(format: "%.1f W", $0) } ?? "不可读" }
func fmtMinutes(_ m: Double?) -> String {
    guard let m, m.isFinite, m > 0 else { return "—" }
    if m < 60 { return "约 \(Int(m.rounded())) 分钟" }
    return "约 \(Int(m / 60)) 小时 \(Int(m.truncatingRemainder(dividingBy: 60).rounded())) 分"
}
func fmtUptime(_ t: TimeInterval) -> String {
    let total = Int(t)
    return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
}

/// 紧凑条：电池百分比 + 预计充满时间 + 输入/充电/系统三数，菜单栏面板与电池页功率标签共用
struct BatteryCompactBar: View {
    let s: Snapshot
    var flow: PowerFlow { PowerFlowCalc.fromSnapshot(s) }
    var minutes: Double? { PowerFlowCalc.minutesToFull(percent: s.battery, fullMah: s.fullMah, voltageV: s.batteryVoltageV, chargeWatts: flow.chargeWatts) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("电池").font(.system(size: 12, weight: .medium))
                if let p = s.battery { Text("\(p)%").font(.system(size: 14, weight: .semibold)).monospacedDigit() } else { Text("不可读").font(.system(size: 12)).foregroundColor(.secondary) }
                Spacer()
                if flow.charging, let m = minutes { Text("预计 \(fmtMinutes(m)) 充满（估算，会变）").font(.system(size: 11)).foregroundColor(.secondary) }
                else if flow.charging { Text("正在充电，充满时间不可读").font(.system(size: 11)).foregroundColor(.secondary) }
                else { Text("电池供电").font(.system(size: 11)).foregroundColor(.secondary) }
            }
            HStack(spacing: 16) {
                Text("充电器输入 \(fmtW(flow.inputWatts))").font(.system(size: 11)).foregroundColor(.secondary)
                Text("电池充电 \(fmtW(flow.chargeWatts))").font(.system(size: 11)).foregroundColor(.secondary)
                Text("系统功耗 \(fmtW(flow.systemWatts))").font(.system(size: 11)).foregroundColor(.secondary)
            }
            Text("充电器输入读不到时写不可读，不用额定功率凑数；电池供电时系统功耗 = 电池放电功率。").font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
