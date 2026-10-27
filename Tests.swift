import SwiftUI
import AppKit
import ServiceManagement

enum MOTests {
    static var active = false
    static var pass = 0, fail = 0
    static func check(_ c: Bool, _ name: String, _ detail: String = "") {
        if c { pass += 1; print("  ✓ \(name)" + (detail.isEmpty ? "" : "  [\(detail)]")) } else { fail += 1; print("  ✗ \(name)" + (detail.isEmpty ? "" : "  [\(detail)]")) }
    }
    static func info(_ s: String) { print("  · \(s)") }
    static func sec(_ s: String) { print("== \(s)  [login=\(SMAppService.mainApp.status.rawValue)]") }

    // MARK: 指标与逻辑自检
    static func selftest() -> Bool {
        active = true
        sec("指标读取")
        var s = Snapshot(); Readers.staticInfo(into: &s)
        check(!s.chip.isEmpty, "芯片型号", s.chip); check(s.ramGB > 0, "内存容量", "\(s.ramGB) GB"); check(s.pCores > 0, "核心数", "\(s.pCores)P+\(s.eCores)E")
        check(s.osVersion.hasPrefix("macOS"), "系统版本", s.osVersion)
        _ = Readers.cpuUsage(); var x = 0.0; for i in 0..<3_000_000 { x += Double(i % 7) }; Thread.sleep(forTimeInterval: 0.5)
        let cpu = Readers.cpuUsage(); check(cpu > 0 && cpu <= 100, "CPU 占用", String(format: "%.1f%% (%.0f)", cpu, x.truncatingRemainder(dividingBy: 1)))
        let l = Readers.loadAvg(); check(l.count == 3 && l.allSatisfy { $0 >= 0 && $0 < 500 }, "负载", "\(l)")
        let up = Readers.uptime(); check(up > 0 && up < 400 * 86400, "开机时长", Fmt.uptime(up))
        Readers.memory(into: &s); check(s.memUsedGB > 0.5 && s.memUsedGB <= s.memTotalGB, "内存已用", String(format: "%.1f / %.0f GB", s.memUsedGB, s.memTotalGB))
        check([1, 2, 4].contains(s.memPressure), "内存压力级别", "\(s.memPressure)"); check(s.swapUsedGB >= 0, "交换", String(format: "%.2f GB", s.swapUsedGB))
        Readers.disk(into: &s); check(s.diskTotalGB > 10 && s.diskFreeGB > 0 && s.diskFreeGB < s.diskTotalGB, "磁盘", String(format: "可用 %.0f / %.0f GB", s.diskFreeGB, s.diskTotalGB))
        Readers.network(into: &s); Thread.sleep(forTimeInterval: 1); Readers.network(into: &s)
        check(s.downBps >= 0 && s.upBps >= 0 && s.downBps < 5e9, "网络速率", "\(s.netKind) ↓\(Fmt.rate(s.downBps)) ↑\(Fmt.rate(s.upBps)) 代理 \(s.proxy)")
        let g = Readers.gpuInfo()
        if let u = g.util { check(u >= 0 && u <= 100, "GPU 占用", "\(u)%") } else { info("GPU 占用不可读（降级显示）") }
        if let c = g.cores { check(c > 0 && c < 200, "GPU 核心", "\(c)") }
        SMC.shared.enumerate()
        let ct = SMC.shared.avgTemp(SMC.shared.cpuKeys) ?? HIDTemp.cpuDie()
        if let t = ct { check(t > 10 && t < 115, "CPU 温度", String(format: "%.1f°C（%d 个传感器）", t, SMC.shared.cpuKeys.count)) } else { info("CPU 温度不可读（降级显示）") }
        if let t = SMC.shared.avgTemp(SMC.shared.gpuKeys) { check(t > 15 && t < 115, "GPU 温度", String(format: "%.1f°C", t)) } else { info("GPU 温度不可读（降级显示）") }
        if let f = SMC.shared.fans() { check(f.rpm.allSatisfy { $0 >= 0 && $0 < 10000 } && f.max >= f.min, "风扇", "\(f.rpm.map { Int($0) }) RPM, \(Int(f.min))–\(Int(f.max))") } else { info("无风扇或不可读") }
        Readers.battery(into: &s)
        if let b = s.battery {
            check(b >= 0 && b <= 100, "电池电量", "\(b)%")
            check((s.batteryHealth ?? 50) > 20 && (s.batteryHealth ?? 50) <= 100, "电池健康", "\(s.batteryHealth.map(String.init) ?? "nil")% \(s.fullMah)/\(s.designMah) mAh")
            check((s.cycles ?? 0) >= 0, "循环次数", "\(s.cycles ?? -1)")
            if let t = s.batteryTemp { check(t > 5 && t < 70, "电池温度", String(format: "%.1f°C", t)) } else { info("电池温度不可读") }
            check(!s.batteryCondition.isEmpty, "电池状况", s.batteryCondition)
        } else { info("没有内置电池") }
        let ds = Readers.devices(); check(ds.allSatisfy { $0.percent >= 0 && $0.percent <= 100 }, "外设电量", ds.isEmpty ? "无公开电量的设备" : ds.map { "\($0.name) \($0.percent)%" }.joined(separator: ", "))
        _ = Readers.topProcesses(); Thread.sleep(forTimeInterval: 1); let top = Readers.topProcesses()
        check(!top.isEmpty && top.allSatisfy { $0.cpu >= 0 && $0.memMB >= 0 }, "高占用进程", top.map { "\($0.name) \(String(format: "%.1f", $0.cpu))%" }.joined(separator: ", "))
        let me = Readers.selfUsage(); check(me.rssMB > 1 && me.rssMB < 2000, "自身内存", String(format: "%.1f MB", me.rssMB))
        var ri = rusage_info_v6()
        let rr = withUnsafeMutablePointer(to: &ri) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) } }
        check(rr == 0 && ri.ri_energy_nj > 0, "进程能耗读取", "\(ri.ri_energy_nj) nJ")

        sec("常亮")
        KeepAwake.shared.startAssertion(); check(KeepAwake.shared.on && KeepAwake.systemSeesAssertion(), "常亮断言已生效")
        KeepAwake.shared.stop(); check(!KeepAwake.shared.on && !KeepAwake.systemSeesAssertion(), "常亮断言已释放")
        info("麦克风静音可控：\(Mic.available)")

        sec("健康分")
        var hs = Snapshot(); hs.diskTotalGB = 1000; hs.diskFreeGB = 500
        check(hs.health.score == 100 && hs.health.status == "一切正常", "空闲时满分")
        hs.cpuTemp = 82; check(hs.health.status == "CPU 温度偏高" && hs.health.score == 95, "温度偏高扣分", "\(hs.health)")
        hs.memPressure = 4; check(hs.health.status == "内存非常紧张", "最严重问题优先显示")
        check(Fmt.rate(2048) == "2 KB/s" && Fmt.rate(3 * 1_048_576) == "3.0 MB/s", "网速格式")

        sec("电量提醒逻辑")
        alertTests()
        sec("耗电记录")
        energyTests()
        sec("持久化")
        let d = UserDefaults(suiteName: "mo-selftest")!; d.removePersistentDomain(forName: "mo-selftest")
        var bs = BatterySettings(); bs.alertsOn = true; bs.lowThresholds = [3, 20, 80]; bs.sounds["low"] = "Funk"; bs.save(d)
        check(BatterySettings.load(d) == bs, "提醒设置可保存读取")
        check(BatterySettings().alertsOn == false && BatterySettings().criticalGlow == false && BatterySettings().deviceAlertsOn == false && BatterySettings().drainAlertsOn == false, "打扰型功能默认关闭")
        let cs = CleanStats(defaults: d); cs.addOptimized(3); cs.addQuit(memMB: 512)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let cs2 = CleanStats(defaults: d); check(cs2.optimized == 3 && cs2.quitApps == 1 && cs2.freedMB == 512, "清理统计持久化")
        d.removePersistentDomain(forName: "mo-selftest")
        check(UserDefaults.standard.object(forKey: "launchAtLogin") == nil, "未写入任何登录项设置")
        print("selftest: \(pass) 通过, \(fail) 失败")
        return fail == 0
    }

    static func alertTests() {
        var s = BatterySettings(); s.alertsOn = true; s.lowThresholds = [3, 10, 20]; s.upper = 80
        var e = AlertEngine()
        func run(_ seq: [(Int, Bool)]) -> [AlertEvent] { seq.flatMap { e.update(level: $0.0, onAC: $0.1, settings: s) } }
        check(run([(25, false), (21, false)]).isEmpty, "高于阈值不提醒")
        check(run([(20, false)]) == [.low(20, critical: false)], "跌到 20% 提醒一次")
        check(run([(19, false), (20, false), (21, false), (20, false), (22, false), (20, false)]).isEmpty, "阈值附近抖动不重复提醒（回差 3%）")
        check(run([(23, false), (20, false)]) == [.low(20, critical: false)], "回升 3% 后重新提醒")
        e = AlertEngine(); _ = run([(25, false)])
        check(run([(9, false)]) == [.low(10, critical: false)], "一次跌过多个阈值只提醒最低的")
        check(run([(3, false)]) == [.low(3, critical: false)], "继续下降到 3% 再提醒")
        s.criticalGlow = true
        e = AlertEngine(); _ = run([(6, false)])
        check(run([(3, false)]) == [.low(3, critical: true)], "严重低电量标记全屏发光")
        e = AlertEngine(); check(run([(15, false)]).isEmpty, "启动时已低于阈值不刷屏")
        check(run([(15, true)]) == [.plugged], "接通电源"); check(run([(16, false)]) == [.unplugged, .low(20, critical: false)], "断开电源（低于阈值时同时提醒低电量）")
        e = AlertEngine(); _ = run([(70, true)])
        check(run([(78, true), (79, true), (80, true)]) == [.upper(80)], "充到上限提醒")
        check(run([(81, true), (85, true), (79, true), (80, true)]).isEmpty, "上限不重复提醒")
        check(run([(77, true), (80, true)]) == [.upper(80)], "回落 3% 后再次提醒上限")
        check(run([(99, true), (100, true)]) == [.full], "充满提醒")
        check(run([(100, true), (99, true), (100, true)]).isEmpty, "充满不重复")
        check(run([(95, false)]) == [.unplugged] && run([(95, true), (100, true)]) == [.plugged, .full], "回落到 95% 后再次提醒充满")
        s.plugOn = false; s.unplugOn = false
        check(run([(100, false), (100, true)]).isEmpty, "关闭接电/断电提醒后不提醒")
        // 外设
        s.deviceLow = 15; e = AlertEngine()
        func dev(_ p: Int) -> [AlertEvent] { e.devices([DeviceBattery(name: "Magic Mouse", percent: p, kind: "computermouse")], settings: s) }
        check(dev(50).isEmpty && dev(15) == [.deviceLow("Magic Mouse", 15)], "外设低电量提醒")
        check(dev(14).isEmpty && dev(17).isEmpty && dev(15).isEmpty, "外设低电量不重复")
        check(dev(20).isEmpty && dev(15) == [.deviceLow("Magic Mouse", 15)], "外设回升 5% 后重新提醒")
        check(dev(100) == [.deviceFull("Magic Mouse")] && dev(100).isEmpty, "外设充满提醒一次")
        // 发送通道（不弹真实通知）
        let al = BatteryAlerts(); var got: [AlertEvent] = []; al.sink = { got.append($0) }
        var sn = Snapshot(); sn.battery = 50; sn.onAC = false
        al.handle(sn); check(got.isEmpty, "提醒总开关关闭时不发送")
        al.engine = AlertEngine(); al.settings.alertsOn = true
        al.settings.lowThresholds = [20]; al.handle(sn); sn.battery = 19; al.handle(sn); al.handle(sn)
        check(got == [.low(20, critical: false)], "开启后按阈值发送一次")
        al.settings.drainAlertsOn = true; al.drain("Chrome", 5); al.drain("Chrome", 5)
        check(got.last == .drain("Chrome", 5) && got.count == 2, "耗电异常 6 小时内只提醒一次")
        BatterySettings().save()   // 恢复默认（BatteryAlerts 的 didSet 会写入标准设置）
        UserDefaults.standard.removeObject(forKey: BatterySettings.key)
    }

    static func energyTests() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var st = EnergyStore()
        for h in 0..<(40 * 24) { st.add("Safari", joules: 100, at: now.addingTimeInterval(-Double(h) * 3600)) }
        st.add("Chrome", joules: 7200, at: now)
        st.add("Chrome", joules: 3600, at: now.addingTimeInterval(-3 * 86400))
        st.prune(now: now)
        check(st.hours.count <= EnergyStore.keepHours, "超过 31 天的数据被清理", "\(st.hours.count) 小时")
        let d = st.summary(.day, now: now)
        check(d.first?.app == "Chrome" && d.first?.series.count == 24 && d.first?.joules == 7200, "24 小时按小时汇总")
        check(d.first(where: { $0.app == "Safari" })?.joules == 2400, "24 小时总量正确")
        let w = st.summary(.week, now: now)
        check(w.first(where: { $0.app == "Chrome" })?.joules == 10800 && w[0].series.count == 7, "7 天按天汇总")
        check(st.summary(.month, now: now).first(where: { $0.app == "Safari" })?.series.count == 30, "30 天按天汇总")
        check(Fmt.energy(7200) == "2.0 Wh" && Fmt.energy(36) == "10 mWh", "能耗格式")
        var ab = EnergyStore()
        for h in 2..<100 { ab.add("Zoom", joules: 300, at: now.addingTimeInterval(-Double(h) * 3600)) }
        ab.add("Zoom", joules: 9000, at: now.addingTimeInterval(-3600))
        ab.add("Notes", joules: 9000, at: now.addingTimeInterval(-3600))
        let found = ab.abnormal(now: now).map(\.0)
        check(found == ["Zoom"], "异常耗电识别（有历史基线才判断）", "\(found)")
        let data = try! JSONEncoder().encode(st)
        check((try? JSONDecoder().decode(EnergyStore.self, from: data)) == st, "耗电记录存盘往返", "\(data.count / 1024) KB")
    }

    // MARK: 界面测试与截图
    static func waitUntil(_ t: TimeInterval = 3, _ c: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(t)
        while Date() < end { if c() { return true }; RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return c()
    }
    static func settle(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }
    static func axChildren(_ o: NSObject) -> [NSObject] {
        if let e = o as? NSAccessibilityProtocol { return (e.accessibilityChildren() ?? []).compactMap { $0 as? NSObject } }
        let sel = NSSelectorFromString("accessibilityChildren")
        guard o.responds(to: sel) else { return [] }
        return (o.perform(sel)?.takeUnretainedValue() as? [Any] ?? []).compactMap { $0 as? NSObject }
    }
    static func axString(_ o: NSObject, _ name: String) -> String {
        let sel = NSSelectorFromString(name)
        guard o.responds(to: sel) else { return "" }
        return o.perform(sel)?.takeUnretainedValue() as? String ?? ""
    }
    final class AXRef { let o: NSObject; init(_ o: NSObject) { self.o = o }
        func press() { let s = NSSelectorFromString("accessibilityPerformPress"); if o.responds(to: s) { _ = o.perform(s) } }
        var value: Any? { let s = NSSelectorFromString("accessibilityValue"); return o.responds(to: s) ? o.perform(s)?.takeUnretainedValue() : nil }
    }
    static func find(_ root: NSObject, id: String? = nil, label: String? = nil) -> AXRef? {
        var r: AXRef?; _ = waitUntil(10) { r = find1(root, id: id, label: label); if r == nil { Nav.shared.objectWillChange.send(); UIState.shared.objectWillChange.send() }; return r != nil }; return r
    }
    static func find1(_ root: NSObject, id: String? = nil, label: String? = nil) -> AXRef? {
        var stack: [NSObject] = [root]; var n = 0
        while let x = stack.popLast(), n < 20000 {
            n += 1
            if let id, axString(x, "accessibilityIdentifier") == id { return AXRef(x) }
            if let label, axString(x, "accessibilityLabel") == label, axString(x, "accessibilityRole") == "AXButton" { return AXRef(x) }
            if ProcessInfo.processInfo.environment["AXDUMP"] != nil { print("AX", type(of: x), axString(x, "accessibilityRole"), axString(x, "accessibilityIdentifier"), axString(x, "accessibilityLabel")) }
            stack.append(contentsOf: axChildren(x))
        }
        if ProcessInfo.processInfo.environment["AXN"] != nil { print("AXN", n, label ?? id ?? "", Nav.shared.sel) }
        return nil
    }
    static func png(_ v: NSView, _ path: String) {
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func runUI(args: [String], window w: NSWindow) {
        active = true
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)
        let snap = args.contains("--snapshot")
        let out = args.firstIndex(of: snap ? "--snapshot" : "--uitest").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } ?? "/tmp/mo-test"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        // 隔离用户设置
        let keys = [BatterySettings.key, "menuBar.enabled", "stats.optimized", "stats.quitApps", "stats.freedMB"]
        let backup = keys.map { UserDefaults.standard.object(forKey: $0) }
        let suite = UserDefaults(suiteName: "mo-uitest")!; suite.removePersistentDomain(forName: "mo-uitest")
        CleanStats.shared = CleanStats(defaults: suite)
        EnergyTracker.fileURL = URL(fileURLWithPath: out).appendingPathComponent("energy-test.json")
        try? FileManager.default.removeItem(at: EnergyTracker.fileURL)
        BatteryAlerts.shared.sink = { print("  · 提醒（测试通道）：\($0.text.0)") }
        // 用 Timer（而不是主队列 block）启动，嵌套 RunLoop 才能继续处理主队列上的采样回调
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
            let mon = Monitor.shared
            mon.start()
            EnergyTracker.shared.start(interval: 1)
            if snap {
                let gi = args.firstIndex(of: "--goldens"); let gd = gi.flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
                if let gd { try? FileManager.default.createDirectory(atPath: gd, withIntermediateDirectories: true) }
                snapshots(out, w, goldens: gd, approve: args.contains("--approve"))
            } else { uiChecks(w) }
            EnergyTracker.shared.stop()
            for (k, v) in zip(keys, backup) { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
            suite.removePersistentDomain(forName: "mo-uitest")
            print((snap ? "snapshot" : "uitest") + ": \(pass) 通过, \(fail) 失败")
            exit(fail == 0 ? 0 : 1)
        }
    }

    // MARK: 截图、外观（浅色/深色）、对比度、布局适配
    @discardableResult static func pngRep(_ v: NSView, _ path: String) -> NSBitmapImageRep? {
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        return rep
    }
    static func lum(_ c: NSColor) -> Double {
        guard let c = c.usingColorSpace(.sRGB) else { return 0 }
        func ch(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(c.redComponent) + 0.7152 * ch(c.greenComponent) + 0.0722 * ch(c.blueComponent)
    }
    /// 对比度检查：用辅助功能树找到每一段文字的位置，在截图里取样，文字区域内最亮和最暗像素的对比度必须够大
    /// （白字落在浅色卡片上这类问题对比度≈1，会直接失败）
    static func contrast(_ v: NSView, _ rep: NSBitmapImageRep, _ name: String) {
        var texts: [(String, NSRect)] = []
        var stack: [NSObject] = [v]; var n = 0
        while let x = stack.popLast(), n < 30000 {
            n += 1
            if axString(x, "accessibilityRole") == "AXStaticText", x.responds(to: NSSelectorFromString("accessibilityFrame")),
               let fr = (x.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue, fr.width > 6, fr.height > 6 {
                texts.append((axString(x, "accessibilityLabel"), fr))
            }
            stack.append(contentsOf: axChildren(x))
        }
        guard let win = v.window else { return }
        let sx = CGFloat(rep.pixelsWide) / v.bounds.width, sy = CGFloat(rep.pixelsHigh) / v.bounds.height
        var bad: [String] = []; var minR = 99.0; var checked = 0
        for (label, fr) in texts {
            var r = v.convert(win.convertFromScreen(fr), from: nil).intersection(v.bounds)
            guard r.width > 4, r.height > 4 else { continue }
            if !v.isFlipped { r.origin.y = v.bounds.height - r.maxY }
            var lo = 1.0, hi = 0.0
            let x0 = Int(r.minX * sx), x1 = Int(r.maxX * sx), y0 = Int(r.minY * sy), y1 = Int(r.maxY * sy)
            for y in stride(from: max(0, y0), to: min(rep.pixelsHigh, y1), by: 1) {
                for x in stride(from: max(0, x0), to: min(rep.pixelsWide, x1), by: 1) {
                    if let c = rep.colorAt(x: x, y: y) { let l = lum(c); lo = min(lo, l); hi = max(hi, l) }
                }
            }
            let ratio = (hi + 0.05) / (lo + 0.05); checked += 1
            minR = min(minR, ratio)
            if ratio < 1.5 { bad.append("\(label)(\(String(format: "%.2f", ratio)))") }
        }
        check(checked >= 5 && bad.isEmpty, "文字对比度 \(name)", "检查 \(checked) 段文字，最低 \(String(format: "%.2f", minR))" + (bad.isEmpty ? "" : "；看不清：" + bad.prefix(6).joined(separator: "、")))
    }
    /// 布局检查：页面内容完全放得下，不需要滚动，也没有可见滚动条
    static func fits(_ root: NSView, _ name: String) {
        var scrolls: [NSScrollView] = []
        func walk(_ v: NSView) { if let s = v as? NSScrollView { scrolls.append(s) }; v.subviews.forEach(walk) }
        walk(root)
        var worst = ""
        for s in scrolls {
            guard let doc = s.documentView else { continue }
            let over = doc.frame.height - s.contentView.bounds.height
            if over > 1 { worst = "内容超出 \(Int(over)) pt" }
            if s.hasVerticalScroller, let sc = s.verticalScroller, !sc.isHidden, sc.alphaValue > 0, s.scrollerStyle == .legacy { worst += " 有滚动条" }
        }
        check(worst.isEmpty, "无需滚动 \(name)", worst.isEmpty ? "\(scrolls.count) 个滚动区域都放得下" : worst)
    }
    static func diffRatio(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return 1 }
        var d = 0, n = 0
        for y in stride(from: 0, to: a.pixelsHigh, by: 2) { for x in stride(from: 0, to: a.pixelsWide, by: 2) {
            n += 1
            guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { d += 1; continue }
            if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent) + abs(p.blueComponent - q.blueComponent) > 0.25 { d += 1 }
        } }
        return Double(d) / Double(max(1, n))
    }
    static func golden(_ rep: NSBitmapImageRep?, _ name: String, _ dir: String?, approve: Bool) {
        guard let rep, let dir else { return }
        let path = dir + "/\(name).png"
        if approve || !FileManager.default.fileExists(atPath: path) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            info("已更新基准图 \(name)"); return
        }
        guard let g = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()) else { check(false, "基准图 \(name) 可读"); return }
        let r = diffRatio(rep, g)
        check(r < 0.02, "与基准图一致 \(name)", String(format: "差异 %.2f%%", r * 100))
    }
    static func fixture() -> Snapshot {
        var s = Snapshot()
        s.chip = "M1 Max"; s.ramGB = 64; s.osVersion = "macOS 27"; s.pCores = 8; s.eCores = 2; s.gpuCores = 24
        s.uptime = 3 * 86400 + 5 * 3600; s.cpu = 23; s.load = [3.1, 2.8, 2.5]; s.cpuTemp = 46; s.gpu = 12; s.gpuTemp = 41
        s.memUsedGB = 38.5; s.memTotalGB = 64; s.memPressure = 1; s.swapUsedGB = 0.4
        s.diskTotalGB = 995; s.diskFreeGB = 310; s.netIface = "en0"; s.netKind = "Wi-Fi"; s.downBps = 420_000; s.upBps = 36_000; s.proxy = "SOCKS"
        s.fans = [1820, 1790]; s.fanMin = 1500; s.fanMax = 5348
        s.battery = 76; s.batteryHealth = 86; s.charging = true; s.onAC = true; s.cycles = 156; s.batteryTemp = 31; s.batteryCondition = "正常"; s.designMah = 8694; s.fullMah = 7467
        s.devices = [DeviceBattery(name: "Magic Mouse", percent: 18, kind: "computermouse"), DeviceBattery(name: "AirPods Pro", percent: 64, kind: "airpodspro")]
        s.top = [ProcInfo(id: 999_991, name: "Google Chrome Helper", cpu: 38.2, memMB: 1450), ProcInfo(id: 999_992, name: "WindowServer", cpu: 12.4, memMB: 820),
                 ProcInfo(id: 999_993, name: "Xcode", cpu: 6.1, memMB: 2900), ProcInfo(id: 999_994, name: "微信", cpu: 2.3, memMB: 560), ProcInfo(id: 999_995, name: "Music", cpu: 0.8, memMB: 210)]
        return s
    }

    static func snapshots(_ out: String, _ w: NSWindow, goldens: String?, approve: Bool) {
        let mon = Monitor.shared
        mon.panelOpen = true
        CleanStats.shared.addOptimized(12); CleanStats.shared.addQuit(memMB: 2350)
        NSApp.activate(ignoringOtherApps: true)   // 让 SwiftUI 生成辅助功能树（用于对比度检查）
        settle(7)
        check(mon.cpuHist.count >= 3, "已采样", "\(mon.cpuHist.count) 次")
        let modes: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        let screen = NSScreen.main
        let defaultSize = Layout.defaultSize(for: screen)
        for (mode, ap) in modes {
            NSApp.appearance = NSAppearance(named: ap)
            // 菜单栏面板
            let host = NSHostingView(rootView: PanelContent(m: mon))
            let size = host.fittingSize; host.frame = NSRect(origin: .zero, size: size)
            let pw = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: size.width, height: size.height), styleMask: [.titled], backing: .buffered, defer: false)
            pw.appearance = NSAppearance(named: ap); pw.contentView = host; pw.orderFrontRegardless(); settle(1.0)
            if let rep = pngRep(host, out + "/panel-\(mode).png") { contrast(host, rep, "面板 \(mode)") }
            if mode == "light" { pngRep(host, out + "/panel.png") }
            check(size.width == 380 && size.height > 600 && size.height < 1000, "面板尺寸 \(mode)", "\(Int(size.width))×\(Int(size.height))")
            pw.orderOut(nil)
            // 主窗口：默认尺寸和最小尺寸
            w.appearance = NSAppearance(named: ap)
            for (sz, szName) in [(defaultSize, "default"), (Layout.minSize, "min")] {
                w.setContentSize(sz); w.setFrameOrigin(NSPoint(x: -4000, y: 0)); w.orderFrontRegardless()
                for (sel, name) in [(-2, "dashboard"), (-3, "battery"), (-1, "overview")] {
                    Nav.shared.sel = sel; settle(1.2)
                    let tag = "\(name)-\(szName)-\(mode)"
                    let rep = pngRep(w.contentView!, out + "/\(tag).png")
                    fits(w.contentView!, tag)
                    if szName == "default", let rep { contrast(w.contentView!, rep, tag) }
                    if szName == "default", mode == "light" { pngRep(w.contentView!, out + "/\(name).png") }
                }
            }
        }
        check(defaultSize.width >= Layout.minSize.width && defaultSize.height >= Layout.minSize.height, "默认窗口不小于最小尺寸", "\(Int(defaultSize.width))×\(Int(defaultSize.height))")
        // 固定数据的基准图（浅色/深色）
        mon.panelOpen = false; mon.menuBarEnabled = false; mon.mainWindowVisible = { false }; mon.reschedule()
        settle(2.5)
        let fx = fixture()
        mon.inject(fx, cpu: (0..<40).map { 20 + 15 * sin(Double($0) / 4) }, gpu: (0..<40).map { 10 + 5 * cos(Double($0) / 5) }, up: (0..<40).map { 30_000 + 8_000 * sin(Double($0) / 3) }, down: (0..<40).map { 400_000 + 90_000 * cos(Double($0) / 3) })
        for (mode, ap) in modes {
            NSApp.appearance = NSAppearance(named: ap)
            let host = NSHostingView(rootView: PanelContent(m: mon))
            let size = host.fittingSize; host.frame = NSRect(origin: .zero, size: size)
            let pw = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: size.width, height: size.height), styleMask: [.titled], backing: .buffered, defer: false)
            pw.appearance = NSAppearance(named: ap); pw.contentView = host; pw.orderFrontRegardless(); settle(1.0)
            golden(pngRep(host, out + "/golden-panel-\(mode).png"), "panel-\(mode)", goldens, approve: approve)
            pw.orderOut(nil)
            w.appearance = NSAppearance(named: ap); w.setContentSize(Layout.idealSize); w.orderFrontRegardless()
            Nav.shared.sel = -2; settle(1.2)
            golden(pngRep(w.contentView!, out + "/golden-dashboard-\(mode).png"), "dashboard-\(mode)", goldens, approve: approve)
        }
        NSApp.appearance = NSAppearance(named: .aqua)
        // 菜单栏电池图标
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 56, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 120, height: 56).fill()
            StatusBar.batteryIcon(84, charging: false).draw(in: NSRect(x: 0, y: 28, width: 60, height: 28))
            StatusBar.batteryIcon(15, charging: false).draw(in: NSRect(x: 60, y: 28, width: 60, height: 28))
            StatusBar.batteryIcon(6, charging: false).draw(in: NSRect(x: 0, y: 0, width: 60, height: 28))
            StatusBar.batteryIcon(55, charging: true).draw(in: NSRect(x: 60, y: 0, width: 60, height: 28))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "/menubar-battery.png"))
        }
    }

    static func uiChecks(_ w: NSWindow) {
        let mon = Monitor.shared
        let loginBefore = Actions.loginEnabled
        check(!loginBefore, "测试开始时没有登录项")
        sec("菜单栏与采样频率")
        UIState.shared.menuBar = true
        StatusBar.shared.setup()
        check(StatusBar.shared.item != nil, "菜单栏图标已创建")
        check(waitUntil(3) { mon.interval == Monitor.lightInterval }, "未打开面板时 5 秒采样", "\(mon.interval)")
        check(waitUntil(7) { StatusBar.shared.item?.button?.title.hasSuffix("%") == true }, "菜单栏显示 CPU 百分比", StatusBar.shared.item?.button?.title ?? "")
        BatteryAlerts.shared.settings.menuIndicator = "battery"; settle(0.3)
        if mon.s.battery != nil { check(StatusBar.shared.item?.button?.image != nil && StatusBar.shared.item?.button?.title == "", "切换为电池图标") }
        BatteryAlerts.shared.settings.menuIndicator = "score"; settle(0.3)
        check(Int(StatusBar.shared.item?.button?.title.trimmingCharacters(in: .whitespaces) ?? "") != nil, "切换为健康分", StatusBar.shared.item?.button?.title ?? "")
        BatteryAlerts.shared.settings.menuIndicator = "cpu"
        StatusBar.shared.item?.button?.performClick(nil)
        check(waitUntil(2) { StatusBar.shared.popover.isShown }, "点击菜单栏图标打开面板")
        check(waitUntil(2) { mon.interval == Monitor.detailInterval }, "面板打开后 2 秒采样", "\(mon.interval)")
        check(waitUntil(6) { !mon.s.top.isEmpty && mon.s.diskTotalGB > 0 }, "面板数据已填充")
        check(StatusBar.shared.popover.contentViewController?.view is NSHostingView<PanelView>, "面板内容为实时面板")
        sec("退出进程（需确认，正常退出）")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["600"]; try! p.run()
        let pi = ProcInfo(id: p.processIdentifier, name: "sleep", cpu: 0, memMB: 1)
        var asked = 0
        Actions.confirmQuit = { _ in asked += 1; return false }
        check(!Actions.quit(pi) && asked == 1 && p.isRunning, "取消确认时不退出")
        Actions.confirmQuit = { _ in asked += 1; return true }
        check(Actions.quit(pi) && asked == 2, "确认后发送正常退出信号")
        check(waitUntil(2) { !p.isRunning } && p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGTERM, "进程以 SIGTERM 正常结束（未强制）", "status \(p.terminationStatus)")
        check(!Actions.quit(ProcInfo(id: getpid(), name: "self", cpu: 0, memMB: 0)), "不能退出自己")
        check(waitUntil(1) { CleanStats.shared.quitApps == 1 }, "退出计入清理统计")

        sec("登录项（默认关闭）")
        check(!Actions.loginEnabled && !UIState.shared.login, "登录时启动默认关闭")
        StatusBar.shared.popover.performClose(nil)
        check(waitUntil(2) { !StatusBar.shared.popover.isShown && mon.interval == Monitor.lightInterval }, "关闭面板后降回 5 秒")
        check(waitUntil(1) { StatusBar.shared.popover.contentViewController == nil }, "关闭面板后释放面板视图")

        sec("主窗口")
        w.setFrameOrigin(NSPoint(x: -4000, y: 0)); w.orderFrontRegardless(); NSApp.activate(ignoringOtherApps: true); w.makeKey()
        if let b = find(w.contentView!, label: "实时监控") { b.press() } else { check(false, "侧边栏「实时监控」") }
        check(waitUntil(2) { Nav.shared.sel == -2 && mon.dashboardShown }, "侧边栏打开实时监控")
        sec("快捷操作")
        let pv = w.contentView!
        check(waitUntil(5) { find(pv, id: "act.awake") != nil }, "找到快捷按钮（与菜单栏面板同一组件）")
        if let b = find(pv, id: "act.awake") {
            b.press(); check(waitUntil(1) { KeepAwake.shared.on } && KeepAwake.systemSeesAssertion(), "点「常亮」开启断言")
            b.press(); check(waitUntil(1) { !KeepAwake.shared.on } && !KeepAwake.systemSeesAssertion(), "再点一次关闭")
        } else { check(false, "找到「常亮」按钮") }
        if let b = find(pv, id: "act.clean") {
            b.press()
            check(waitUntil(2) { Overlay.isShowing && Overlay.mode == "clean" }, "点「擦屏」进入黑屏", "\(Overlay.windows.count) 个屏幕")
            let win = Overlay.windows.first!
            check(win.level == .screenSaver && win.frame == NSScreen.screens.first!.frame && win.backgroundColor == .black, "黑屏覆盖整个屏幕")
            let click = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 100), modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            win.sendEvent(click); let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
            win.sendEvent(key); check(Overlay.isShowing, "点击和普通按键被忽略")
            let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            win.sendEvent(esc); check(waitUntil(1) { !Overlay.isShowing }, "按 Esc 退出擦屏")
        } else { check(false, "找到「擦屏」按钮") }
        Overlay.cleanScreen(seconds: 1); check(Overlay.isShowing, "定时擦屏开始"); check(waitUntil(2.5) { !Overlay.isShowing }, "到时间自动结束")
        Overlay.showGlow(level: 5, seconds: 30); check(Overlay.mode == "glow" && !Overlay.windows.isEmpty, "低电量全屏发光提醒")
        let gw = Overlay.windows.first!
        gw.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: gw.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
        check(waitUntil(1) { !Overlay.isShowing }, "Esc 关闭发光提醒")
        check(find(pv, id: "act.mic") != nil && find(pv, id: "act.shot") != nil, "截图/麦克风按钮存在")

        mon.mainWindowVisible = { true }; mon.reschedule()
        check(mon.interval == Monitor.detailInterval, "仪表盘可见时 2 秒采样")
        if let t = find(w.contentView!, id: "dash.login") { check((t.value as? NSNumber)?.intValue == 0, "仪表盘登录项开关为关") } else { check(false, "找到登录项开关") }
        mon.mainWindowVisible = { false }; mon.reschedule()
        check(mon.interval == Monitor.lightInterval, "窗口隐藏后降频")
        if let b = find(w.contentView!, label: "电池") { b.press() }
        check(waitUntil(2) { Nav.shared.sel == -3 }, "侧边栏打开电池页")
        if let t = find(w.contentView!, id: "bat.alertsOn") { check((t.value as? NSNumber)?.intValue == 0, "电量提醒默认关闭") } else { check(false, "找到提醒开关") }
        check(waitUntil(4) { !EnergyTracker.shared.live.isEmpty }, "耗电实时数据", EnergyTracker.shared.live.prefix(3).map { "\($0.app) \(String(format: "%.2f", $0.watts))W" }.joined(separator: ", "))
        UIState.shared.menuBar = false
        check(StatusBar.shared.item == nil && mon.interval == 0, "关闭菜单栏图标后停止采样")
        check(Actions.loginEnabled == loginBefore, "测试全程没有改动登录项")
        w.orderOut(nil)
    }
}
