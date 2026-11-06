// v2.0 测试：电池功率口径、充满时间、mW 榜、界面令牌（Mock 数据，不依赖真实硬件/网络）
import SwiftUI
import AppKit

extension MOTests {
    static func v20Tests() {
        sec("电池功率口径")
        check(PowerFlowCalc.chargeWatts(voltageV: 12.81, currentA: 3.57, charging: true) == 12.81 * 3.57, "充电功率 = 电压 × 电流")
        check(PowerFlowCalc.chargeWatts(voltageV: 12.81, currentA: -3.57, charging: true) == nil, "放电电流不算充电功率")
        check(PowerFlowCalc.chargeWatts(voltageV: 12.81, currentA: 3.57, charging: false) == nil, "没充电时不算充电功率")
        let dis = PowerFlowCalc.dischargeWatts(voltageV: 12.81, currentA: -2.0) ?? -1
        check(abs(dis - 25.62) < 0.01, "放电功率取电流绝对值", "\(dis)")
        check(PowerFlowCalc.systemWatts(inputWatts: 88.61, chargeWatts: 45.77, dischargeWatts: nil, charging: true) != nil, "充电时系统 = 输入 − 充电")
        let sys = PowerFlowCalc.systemWatts(inputWatts: 88.61, chargeWatts: 45.77, dischargeWatts: nil, charging: true)!
        check(abs(sys - 42.84) < 0.01, "系统功耗算式正确", "\(sys)")
        check(PowerFlowCalc.systemWatts(inputWatts: nil, chargeWatts: 45.77, dischargeWatts: nil, charging: true) == nil, "输入读不到时系统功耗写不可读，不凑数")
        check(PowerFlowCalc.systemWatts(inputWatts: nil, chargeWatts: nil, dischargeWatts: 30.0, charging: false) == 30.0, "电池供电时系统 = 放电功率")
        sec("充满时间估算")
        let mins = PowerFlowCalc.minutesToFull(percent: 84, fullMah: 7467, voltageV: 12.81, chargeWatts: 47.4)
        check(mins != nil && mins! > 0 && mins! < 120, "84%、47.4W 时充满时间在合理区间", "\(mins ?? -1)")
        check(PowerFlowCalc.minutesToFull(percent: 100, fullMah: 7467, voltageV: 12.81, chargeWatts: 47.4) == nil, "已充满不估算")
        check(PowerFlowCalc.minutesToFull(percent: 84, fullMah: 7467, voltageV: 12.81, chargeWatts: nil) == nil, "充电功率读不到不估算")
        check(PowerFlowCalc.minutesToFull(percent: 84, fullMah: 0, voltageV: 12.81, chargeWatts: 47.4) == nil, "容量读不到不估算")
        check(fmtUptime(22 * 3600 + 50 * 60 + 53) == "22:50:53", "运行时间格式")
        sec("mW 榜")
        let top = PowerFlowCalc.topMW(lastHourJoules: ["A": 3600, "B": 1800, "C": 900], currentHourJoules: [:], secondsIntoHour: 1800)
        check(top.count == 3 && top[0].app == "A" && abs(top[0].mw - 1000) < 0.01, "上一小时焦耳 ÷ 3600 × 1000 = mW")
        check(PowerFlowCalc.topMW(lastHourJoules: [:], currentHourJoules: ["A": 1800], secondsIntoHour: 1800).first?.mw == 1000, "没有上一小时时用本小时累计平均")
        check(PowerFlowCalc.topMW(lastHourJoules: [:], currentHourJoules: [:], secondsIntoHour: 1800).isEmpty, "没有采样不编榜")
        var store = EnergyStore()
        store.hours[Int(Date().timeIntervalSince1970 / 3600) - 1] = ["X": 3600]
        check(PowerFlowCalc.topMW(store: store, now: Date()).first?.app == "X", "EnergyStore 最近一小时取上一完整小时")
        sec("界面令牌")
        check(CDS.radiusCard == 12 && CDS.radiusPanel == 12 && CDS.radiusButton == 6, "圆角收成 3 种（v2.5）：卡片 12、控件 6、胶囊全圆")
        check(CDS.motionMicro == 0.07 && CDS.motionSettle == 0.12 && CDS.motionPanel == 0.30, "动效时长：70ms/120ms/300ms")
        check(CDS.pressScale == 0.98 && CDS.breathe == 2.4 && CDS.pulse == 1.2, "按下 0.98、呼吸 2.4s、脉冲 1.2s")
        check(CDS.titleWeight(dark: false) == .semibold && CDS.titleWeight(dark: true) == .medium, "深色标题字重减细")
        check(CDS.shouldFade(contentHeight: 1000, viewportHeight: 780), "内容超高才渐隐")
        check(!CDS.shouldFade(contentHeight: 700, viewportHeight: 780), "放得下的页不渐隐")
        check(!CDS.shouldFade(contentHeight: 780, viewportHeight: 780), "刚好放下不渐隐")
        sec("功率流向快照口径")
        var snap = Snapshot()
        snap.battery = 84; snap.charging = true; snap.onAC = true; snap.fullMah = 7467
        snap.batteryVoltageV = 12.81; snap.batteryCurrentA = 3.57; snap.batteryAdapterWatts = 140
        let flow = PowerFlowCalc.fromSnapshot(snap)
        check(flow.chargeWatts != nil && flow.adapterRatedWatts == 140, "快照转功率流向保留电压电流与额定功率")
        check(flow.inputWatts == nil && flow.systemWatts == nil, "充电器实时输入没有公开接口时不编造")
    }
}
