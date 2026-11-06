// 2.8 测试：统一状态与单位、功率趋势、能耗覆盖、色彩模式语义、双列面板
import SwiftUI
import AppKit

enum V28 {
    typealias T = MOTests

    /// 固定的蓝牙外设：一个有电量、一个读不到（例如 Keychron 经典蓝牙只回 0 时按「未取得」处理）
    static func btFixture() -> BTBattery {
        let b = BTBattery(); b.persist = false
        b.devices = [BTDevice(name: "iPhone", address: "aa", kind: "iphone", connected: true, ble: true, percent: 76),
                     BTDevice(name: "AirPods Pro", address: "bb", kind: "airpodspro", connected: true, ble: true, percent: 40),
                     BTDevice(name: "Keychron K3 Pro", address: "cc", kind: "keyboard", connected: true, ble: false, percent: nil,
                              reason: "未取得经典蓝牙电量，可能与型号或固件有关")]
        return b
    }

    static func tests() {
        T.sec("2.8 U04 单位与时间口径")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        T.check(Fmt.watts(12.34) == "12.3 W" && Fmt.watts(nil) == "—", "功率一位小数，读不到显示「—」而不是 0")
        T.check(Fmt.percent(54.4) == "54%" && Fmt.percent(nil) == "—", "百分比整数，读不到显示「—」")
        T.check(Fmt.ago(now.addingTimeInterval(-2), now: now) == "刚刚" && Fmt.ago(now.addingTimeInterval(-42), now: now) == "42 秒前"
                && Fmt.ago(now.addingTimeInterval(-600), now: now) == "10 分钟前" && Fmt.ago(nil, now: now) == "尚未更新", "相对时间统一写法")
        T.check(Fmt.span(35 * 60) == "35 分钟" && Fmt.span(18 * 3600 + 40 * 60) == "18 小时 40 分" && Fmt.span(51 * 3600) == "2 天 3 小时", "时长统一写法")
        T.check(StateKind.failed.tint == bad && StateKind.done.tint == good && StateKind.stale.tint == warn, "状态色只表示状态")
        T.check(StateKind.allSpoken.count == 6 && Set(StateKind.allSpoken).count == 6, "六种状态朗读文字互不相同")

        T.sec("2.8 B03 功率趋势：断档、过期与电源切换")
        let h = PowerHistory()
        let t0 = now.addingTimeInterval(-600)
        for i in 0..<6 { h.add(PowerSample(t: t0.addingTimeInterval(Double(i) * 10), onAC: true, inputW: 30, chargeW: 12, dischargeW: nil), now: now) }
        // 断档 5 分钟（App 未运行），然后拔电
        for i in 0..<4 { h.add(PowerSample(t: t0.addingTimeInterval(400 + Double(i) * 10), onAC: false, inputW: nil, chargeW: nil, dischargeW: 9), now: now) }
        let w = PowerHistory.window(h.samples, seconds: 1800, now: now)
        T.check(w.points.count == 10 && w.gaps == 1 && w.switches.count == 1, "统计断档与电源切换", "\(w.points.count) 点 \(w.gaps) 断档 \(w.switches.count) 切换")
        let input = PowerHistory.segments(w.points) { $0.inputW }, discharge = PowerHistory.segments(w.points) { $0.dischargeW }
        T.check(input.count == 1 && input[0].count == 6 && discharge.count == 1 && discharge[0].count == 4, "输入和放电各自成段，不拼成一条线")
        let h2 = PowerHistory()
        for i in 0..<4 { h2.add(PowerSample(t: t0.addingTimeInterval(Double(i) * 10), onAC: true, inputW: 20, chargeW: i == 2 ? nil : 8, dischargeW: nil), now: now) }
        T.check(PowerHistory.segments(h2.samples) { $0.chargeW }.count == 2, "中间读不到的点留空，前后分段")
        // 记录时的新鲜度判断用真实时钟（PowerFlowCalc 以 Date() 判断 30 秒内的读数）
        let rnow = Date()
        var snap = MOTests.fixture(); snap.battery = 80; snap.onAC = true; snap.batteryVoltageV = 12.5; snap.batteryCurrentA = 1
        snap.batteryInputWatts = 40; snap.batteryPowerUpdated = rnow.addingTimeInterval(-45)
        let h3 = PowerHistory(); h3.record(snap, now: rnow)
        T.check(h3.samples.isEmpty, "超过 30 秒的旧读数不记入趋势")
        snap.batteryPowerUpdated = rnow.addingTimeInterval(-3); h3.record(snap, now: rnow); h3.record(snap, now: rnow)
        T.check(h3.samples.count == 1 && h3.samples[0].inputW == 40 && h3.samples[0].chargeW.map { abs($0 - 12.5) < 0.01 } == true, "同一读数只记一次，充电功率 = 电压 × 电流")
        snap.onAC = false; snap.batteryCurrentA = -0.8; snap.batteryPowerUpdated = rnow.addingTimeInterval(-1); h3.record(snap, now: rnow)
        T.check(h3.samples.last?.inputW == nil && h3.samples.last?.dischargeW.map { abs($0 - 10) < 0.01 } == true, "拔电后不保留输入功率")
        let old = PowerHistory()
        old.add(PowerSample(t: now.addingTimeInterval(-3 * 3600), onAC: true, inputW: 10, chargeW: nil, dischargeW: nil), now: now)
        old.add(PowerSample(t: now, onAC: true, inputW: 10, chargeW: nil, dischargeW: nil), now: now)
        T.check(old.samples.count == 1, "只保留最近 2 小时")

        T.sec("2.8 B05 能耗采样覆盖")
        var es = EnergyStore()
        let base = Date(timeIntervalSince1970: Double(Int(now.timeIntervalSince1970 / 3600)) * 3600)   // 整点
        let n = base.addingTimeInterval(20 * 60)   // 当前 = 整点后 20 分钟
        for m in 0..<30 { es.markSampled(at: base.addingTimeInterval(Double(-5 * 3600 + m * 60))) }   // 5 小时前采了 30 分钟
        for m in 0..<20 { es.markSampled(at: base.addingTimeInterval(Double(m * 60))) }                // 本小时 20 分钟
        es.add("Safari", joules: 3600, at: base.addingTimeInterval(-5 * 3600))
        let c = EnergyCoverage.compute(es, range: .day, now: n)
        T.check(c.coveredMinutes == 50 && !c.estimated, "覆盖分钟数按真实采样累计", "\(c.coveredMinutes) 分钟")
        T.check(c.firstSample == base.addingTimeInterval(-5 * 3600) && c.lastSample == base.addingTimeInterval(19 * 60), "记录首次与最新样本时间")
        T.check(c.gaps == 1, "首次采样之后没采到的连续时段算 1 段缺口", "\(c.gaps)")
        T.check(c.buckets.count == 24 && c.buckets.filter { $0 > 0 }.count == 2, "24 小时按小时分 24 格")
        T.check(c.rangeMinutes == 5 * 60 + 21 && c.fraction > 0.15 && c.fraction < 0.17, "覆盖比例只按首次采样以后的时间算", "\(c.rangeMinutes) 分钟")
        T.check(c.summary(now: n).contains("开始采样") && c.summary(now: n).contains("1 段缺口"), "说明文字含开始时间与缺口", c.summary(now: n))
        var legacy = EnergyStore(); legacy.add("Mail", joules: 100, at: base.addingTimeInterval(-3600))
        let lc = EnergyCoverage.compute(legacy, range: .day, now: n)
        T.check(lc.estimated && lc.summary(now: n).hasPrefix("约从"), "旧记录没有覆盖信息时注明按小时推断")
        T.check(EnergyCoverage.compute(EnergyStore(), range: .week, now: n).summary(now: n) == "还没有应用能耗采样。", "没有数据时不显示 0")
        if let data = try? JSONEncoder().encode(["hours": ["10": ["Mail": 1.0]]]), let decoded = try? JSONDecoder().decode(EnergyStore.self, from: data) {
            T.check(decoded.sampled == nil && decoded.hours[10]?["Mail"] == 1, "旧版 energy.json 仍能读取")
        } else { T.check(false, "旧版 energy.json 仍能读取") }
        var pr = es; pr.prune(now: n.addingTimeInterval(40 * 86400))
        T.check(pr.sampled?.isEmpty == true, "覆盖信息随记录一起过期删除")

        T.sec("2.8 D02 色彩模式语义")
        T.check(DDCCaps.modeName(0x00) == "标准" && DDCCaps.modeName(0x03) == "影片" && DDCCaps.modeName(0x05) == "游戏" && DDCCaps.modeName(0x42) == nil, "0xDC 显示模式按 MCCS 标准命名，未定义值返回空")
        T.check(DDCCaps.presetStandardName(0x05) == "6500 K" && DDCCaps.presetStandardName(0x0B) == "用户预设 1" && DDCCaps.presetStandardName(0x30) == nil, "0x14 色彩预设标准名")
        let d = UserDefaults(suiteName: "mo-v28")!; d.removePersistentDomain(forName: "mo-v28")
        let names = DDCNames(defaults: d)
        T.check(names.label("disp-A", 0xDC, 0x02).0 == "混合" && names.label("disp-A", 0xDC, 0x02).1.contains("MCCS"), "标准值显示标准名并注明来源")
        T.check(names.label("disp-A", 0xDC, 0x42).0 == "模式 0x42", "未定义值保留编号")
        names.set("disp-A", 0xDC, 0x02, "  护眼阅读  ")
        T.check(names.label("disp-A", 0xDC, 0x02).0 == "护眼阅读" && names.label("disp-A", 0xDC, 0x02).1.contains("混合"), "本机命名优先，仍提示标准名")
        T.check(names.label("disp-B", 0xDC, 0x02).0 == "混合", "命名按显示器区分，多屏互不影响")
        T.check(DDCNames(defaults: d).name("disp-A", 0xDC, 0x02) == "护眼阅读", "命名会保存")
        names.set("disp-A", 0xDC, 0x02, "")
        T.check(names.label("disp-A", 0xDC, 0x02).0 == "混合", "留空恢复默认名称")
        d.removePersistentDomain(forName: "mo-v28")
        T.check(DDCFeedback.kind("正在应用并核对…") == .loading && DDCFeedback.kind("已核对显示器读数") == .done
                && DDCFeedback.kind("未确认修改成功，已显示可读取的实际值；可重试或恢复") == .failed
                && DDCFeedback.kind("已发送输入切换，无法回读确认；请在显示器上核对") == .unknown, "显示器操作反馈映射到统一状态")

        T.sec("2.8 U03 双列面板")
        T.check(PanelLayout.width == 400 && PanelLayout.tileHeight >= 96, "面板宽 400，两列指标卡")
        T.check(PanelContent.verdict(90).word == "不卡" && PanelContent.verdict(70).word == "有点卡" && PanelContent.verdict(40).word == "很卡", "结论分三档")
        T.check(PanelContent.tempTint(nil) == .secondary && PanelContent.tempTint(95) == bad && PanelContent.tempTint(80) == warn, "温度标签按状态着色，读不到不着色")
        T.check(PanelHeight.height(contentHeight: 840, visibleHeight: 760) == 730 && PanelHeight.height(contentHeight: 840, visibleHeight: 1200) == 840, "矮屏幕按可见高度封顶，内容可无滚动条滚动")
    }

    // MARK: 交互
    static func ui(_ w: NSWindow) {
        T.sec("2.8 面板交互与朗读")
        let mon = Monitor.shared
        let realBT = BTBattery.shared; BTBattery.shared = btFixture()
        defer { BTBattery.shared = realBT }
        let host = NSHostingView(rootView: PanelContent(m: mon))
        let size = host.fittingSize; host.frame = NSRect(origin: .zero, size: size)
        let pw = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: size.width, height: size.height), styleMask: [.titled], backing: .buffered, defer: false)
        pw.contentView = host; pw.orderFrontRegardless(); T.settle(1.0)
        for id in ["panel.header", "panel.metrics", "panel.battery", "panel.stats", "panel.open", "act.shot", "act.mic", "act.awake", "act.clean", "act.charge", "act.dock"] {
            T.check(T.find1(host, id: id) != nil, "面板有 \(id)")
        }
        let ring = T.find1(host, id: "panel.device.Keychron K3 Pro").map { T.axString($0.o, "accessibilityLabel") } ?? ""
        T.check(ring == "Keychron K3 Pro，电量未取得", "读不到电量的外设朗读为「未取得」，不说 0%", ring)
        let phone = T.find1(host, id: "panel.device.iPhone").map { T.axString($0.o, "accessibilityLabel") } ?? ""
        T.check(phone == "iPhone，电量 76%", "有电量的外设朗读百分比", phone)
        pw.orderOut(nil)

        T.sec("2.8 电池功率趋势与能耗覆盖")
        Nav.shared.sel = .battery; T.settle(0.8)
        if let b = T.find(w.contentView!, id: "bat.tab.1") {
            b.press(); T.settle(0.6)
            T.check(T.find1(w.contentView!, id: "power.trend.coverage") != nil, "功率标签显示采样起点与断档说明")
            T.check(T.find1(w.contentView!, id: "power.trend") != nil || T.find1(w.contentView!, id: "power.trend.state") != nil, "有趋势图或「正在收集」状态")
        } else { T.check(false, "找到功率与能耗标签") }
        if let b = T.find(w.contentView!, id: "bat.tab.0") {
            b.press(); T.settle(0.6)
            T.check(T.find1(w.contentView!, id: "energy.coverage") != nil && T.find1(w.contentView!, id: "energy.coverage.strip") != nil, "应用耗电显示采样覆盖条与说明")
        }
        Nav.shared.sel = .monitor
    }

    // MARK: 截图
    static func snapshots(_ out: String) {
        let realBT = BTBattery.shared; BTBattery.shared = btFixture()
        let realPH = PowerHistory.shared; let ph = PowerHistory()
        let now = Date()
        // 前 25 分钟接电充电，断档 2 分钟，然后拔电放电
        for i in 0..<150 { let t = now.addingTimeInterval(-1800 + Double(i) * 10); ph.add(PowerSample(t: t, onAC: true, inputW: 38 + 4 * sin(Double(i) / 9), chargeW: 22 + 3 * cos(Double(i) / 7), dischargeW: nil), now: now) }
        for i in 0..<16 { let t = now.addingTimeInterval(-170 + Double(i) * 10); ph.add(PowerSample(t: t, onAC: false, inputW: nil, chargeW: nil, dischargeW: 9 + Double(i % 4)), now: now) }
        PowerHistory.shared = ph
        defer { BTBattery.shared = realBT; PowerHistory.shared = realPH }
        for (mode, ap) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: ap)
            func shot<V: View>(_ v: V, _ name: String, width: CGFloat) {
                let host = NSHostingView(rootView: v.frame(width: width).background(DS.window))
                let size = host.fittingSize; host.frame = NSRect(origin: .zero, size: size)
                let cw = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: size.width, height: size.height), styleMask: [.titled], backing: .buffered, defer: false)
                cw.appearance = NSAppearance(named: ap); cw.contentView = host; cw.orderFrontRegardless(); T.settle(1.0)
                if let rep = T.pngRep(host, out + "/\(name)-\(mode).png") { T.contrast(host, rep, "\(name) \(mode)") }
                T.fits(host, "\(name) \(mode)")
                cw.orderOut(nil)
            }
            shot(PowerTrendCard(now: now).padding(16), "trend28", width: 460)
            shot(VStack(spacing: 10) {
                StateLine(kind: .loading, text: "正在读取显示器")
                StateLine(kind: .empty, text: "这个时间范围没有应用耗电记录", detail: "App 没运行或关闭后台记录的时段不会有数据，不按 0 计。")
                StateLine(kind: .stale, text: "电池读数已超过 30 秒没有更新", actions: [.refresh {}])
                StateLine(kind: .failed, text: "未确认修改成功，已显示可读取的实际值", actions: [.retry {}, StateAction(title: "恢复", symbol: "arrow.uturn.backward") {}])
                StateLine(kind: .done, text: "已核对显示器读数", updated: now.addingTimeInterval(-12))
                StateLine(kind: .unknown, text: "未取得可切换的描述文件", actions: [.openSettings(url: "x-apple.systempreferences:")])
            }.padding(16), "states28", width: 460)
            // 长名称面板：长芯片名、长进程名不截断关键数字
            var long = MOTests.fixture(); long.chip = "Apple M5 Max (16 核 CPU / 40 核 GPU)"; long.proxy = "SOCKS 127.0.0.1:7890"
            long.top = [ProcInfo(id: 999_101, name: "com.apple.WebKit.WebContent (Safari 网页内容进程)", cpu: 99.2, memMB: 1_284),
                        ProcInfo(id: 999_102, name: "Microsoft Edge Helper (Renderer)", cpu: 31.4, memMB: 820)]
            let mon = Monitor.shared
            mon.inject(long, cpu: (0..<40).map { 30 + 10 * sin(Double($0) / 4) }, gpu: (0..<40).map { _ in 8 }, up: (0..<40).map { _ in 20_000 }, down: (0..<40).map { 200_000 + 50_000 * cos(Double($0) / 3) })
            shot(PanelContent(m: mon), "panel28-long", width: PanelLayout.width)
        }
        NSApp.appearance = NSAppearance(named: .aqua)
    }
}

extension StateKind {
    static let all: [StateKind] = [.loading, .empty, .unknown, .stale, .failed, .done]
    static var allSpoken: [String] { all.map(\.spoken) }
}
