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
    var fullyCharged = false
    var inputNote = ""
    var systemNote = ""
    var supplyText: String {
        guard percent != nil else { return "电池信息不可用" }
        if charging { return "正在充电" }
        if onAC {
            if dischargeWatts != nil { return "已接电源，电池正在放电" }
            return fullyCharged || percent == 100 ? "已充满，已接电源" : "已接电源，未充电"
        }
        return "电池供电"
    }
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
        let fresh = s.batteryPowerUpdated.map { abs(Date().timeIntervalSince($0)) < 30 } ?? true
        let current = fresh ? s.batteryCurrentA : nil
        let charging = s.onAC && (current.map { $0 > 0 } ?? s.charging)
        let charge = chargeWatts(voltageV: s.batteryVoltageV, currentA: current, charging: charging)
        let discharge = dischargeWatts(voltageV: s.batteryVoltageV, currentA: current)
        let input = fresh && s.onAC ? s.batteryInputWatts : nil
        var system: Double?
        if !s.onAC { system = discharge }
        else if let input, let current {
            let estimate = input - (charge ?? 0) + (discharge ?? 0)
            if estimate >= 0 && current.isFinite { system = estimate }
        }
        let inputNote = !fresh ? "读数已过期，等待刷新" : (!s.onAC ? "电池供电，无外接输入" : (input == nil ? (s.batteryInputSource.isEmpty ? "未取得实时电源遥测" : s.batteryInputSource) : (s.batteryInputSource.isEmpty ? "电源遥测 · DC 输入" : s.batteryInputSource)))
        return PowerFlow(
            voltageV: fresh ? s.batteryVoltageV : nil, currentA: current,
            chargeWatts: charge, dischargeWatts: discharge, inputWatts: input,
            systemWatts: system, adapterRatedWatts: s.onAC ? s.batteryAdapterWatts : nil, lowPowerMode: s.lowPowerMode,
            charging: charging, onAC: s.onAC, percent: s.battery, fullMah: s.fullMah,
            fullyCharged: s.batteryFullyCharged, inputNote: inputNote,
            systemNote: system == nil ? "功率数据不足或尚未同步" : "估算 · 按输入与电池功率计算")
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
                Text("电池").font(.system(size: 11, weight: .medium))
                if let p = s.battery { Text("\(p)%").font(.system(size: 13, weight: .semibold)).monospacedDigit() } else { Text("不可读").font(.system(size: 11)).foregroundColor(DS.text.secondary) }
                Spacer()
                if flow.charging, let m = minutes { Text("预计 \(fmtMinutes(m)) 充满（估算，会变）").font(.system(size: 11)).foregroundColor(DS.text.secondary) }
                else if flow.charging { Text("正在充电，充满时间不可读").font(.system(size: 11)).foregroundColor(DS.text.secondary) }
                else { Text(flow.supplyText).font(.system(size: 11)).foregroundColor(DS.text.secondary).accessibilityIdentifier("v22.batterySupply") }
            }
            HStack(spacing: 16) {
                Text("输入 " + (flow.onAC ? fmtW(flow.inputWatts) : "—")).font(.system(size: 11)).foregroundColor(DS.text.secondary)
                Text(flow.charging ? "电池充电 \(fmtW(flow.chargeWatts))" : "电池未充电").font(.system(size: 11)).foregroundColor(DS.text.secondary)
                Text("系统功耗 \(fmtW(flow.systemWatts))").font(.system(size: 11)).foregroundColor(DS.text.secondary)
            }
            Text(flow.inputNote + "；" + flow.systemNote).font(.system(size: 10)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
