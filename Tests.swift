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
    /// 诊断记录：进程、前台、窗口与辅助功能树概况（只读，不改变断言）
    static func diag(_ tag: String, _ w: NSWindow?) {
        let me = ProcessInfo.processInfo.processIdentifier
        let fa = NSWorkspace.shared.frontmostApplication
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let axCount = w.map { axNodes($0) } ?? 0
        let sess = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = (sess?["CGSSessionScreenIsLocked"] as? Bool) ?? false
        let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").map { $0.processIdentifier }.filter { $0 != me }
        info("诊断[\(tag)] pid=\(me) v\(ver) path=\(Bundle.main.bundlePath) active=\(NSApp.isActive) front=\(fa?.localizedName ?? "nil")(\(fa?.processIdentifier ?? 0)) 同 ID 其它进程=\(others) "
             + "win: visible=\(w?.isVisible ?? false) key=\(w?.isKeyWindow ?? false) main=\(w?.isMainWindow ?? false) occl=\(w.map { $0.occlusionState.contains(.visible) } ?? false) host=\(w?.contentView is NSHostingView<RootView>) "
             + "ax节点=\(axCount) trusted=\(AXIsProcessTrusted()) locked=\(locked) displayAsleep=\(asleep)")
    }
    static func axNodes(_ w: NSWindow) -> Int {
        guard let root = w.contentView else { return 0 }
        var n = 0; var stack: [NSObject] = [root]
        while let x = stack.popLast(), n < 5000 { n += 1; stack.append(contentsOf: axChildren(x)) }
        return n
    }
    /// 开始找控件前的前置条件：活动应用、活动窗口、未被遮挡、辅助功能树非空。返回不满足的原因（nil = 就绪）
    static func notReady(_ w: NSWindow) -> String? {
        var r: [String] = []
        if !NSApp.isActive { r.append("测试程序不是活动应用（前台：\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")）") }
        if !w.isKeyWindow { r.append("窗口不是活动窗口") }
        if !w.occlusionState.contains(.visible) { r.append("窗口被遮挡") }
        let n = axNodes(w); if n <= 1 { r.append("辅助功能树为空（\(n) 个节点）") }
        return r.isEmpty ? nil : r.joined(separator: "；")
    }
    // SwiftUI 有时要被真正的外部 AX 客户端查询后才生成树。自身后台线程查询会锁住
    // view graph，因此让同一签名测试包的独立子进程只读查询父进程，不申请新权限。
    static func primeParentAX() -> Int32 {
        guard AXIsProcessTrusted() else { return 2 }
        let parent = AXUIElementCreateApplication(getppid())
        AXUIElementSetMessagingTimeout(parent, 1)
        var count = 0
        func walk(_ node: AXUIElement, _ depth: Int) {
            guard depth < 5, count < 200 else { return }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &value) == .success,
                  let children = value as? [AXUIElement] else { return }
            for child in children { count += 1; walk(child, depth + 1) }
        }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(parent, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement] { windows.forEach { walk($0, 0) } }
        return count > 0 ? 0 : 1
    }
    static func primeAX() {
        let probe = Process()
        probe.executableURL = Bundle.main.executableURL
        probe.arguments = ["--test-prime-parent-ax"]
        probe.standardInput = FileHandle.nullDevice
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do { try probe.run() } catch { info("AX 外部预查询无法启动：\(error.localizedDescription)"); return }
        if !waitUntil(8, { !probe.isRunning }) {
            probe.terminate()
            if !waitUntil(1, { !probe.isRunning }) { kill(probe.processIdentifier, SIGKILL) }
        }
        info("AX 外部只读预查询结束=\(!probe.isRunning) 状态=\(probe.isRunning ? -1 : probe.terminationStatus)")
    }
    /// 可靠窗口准备：激活后等待真正成为前台，没成功就再请求一次（不改断言，只记录）
    static func ensureActive(_ w: NSWindow, _ tag: String) {
        func ready() -> Bool { NSApp.isActive && w.isKeyWindow && w.occlusionState.contains(.visible) }
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if !waitUntil(3, ready) {
            info("诊断[\(tag)] 前台或活动窗口尚未就绪，再请求一次")
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            w.makeKeyAndOrderFront(nil)
            _ = waitUntil(3, ready)
        }
    }
    static func sec(_ s: String) { print("== \(s)  [login=\(SMAppService.mainApp.status.rawValue)]") }

    // MARK: 指标与逻辑自检
    static func selftest() -> Bool {
        active = true
        do { try SafetyCoreTests.run { check($0, $1) } }
        catch { check(false, "安全回归执行失败", error.localizedDescription) }
        sec("2.16 N1 对比度验收（取样与判定）")
        ContrastCheck.selftest { check($0, $1, $2) }
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
        chargeTests()
        v15Tests()
        v16Tests()
        v17Tests()
        v18Tests()
        v19Tests()
        v20Tests()
        v21Tests()
        v22Tests()
        v23Tests()
        v24Tests()
        v241Tests()
        V25.tests()
        V26.tests()
        PhaseZero.tests()
        PhaseOne.tests()
        PhaseTwo.tests()
        V28.tests()
        V292.tests()
        V210.tests()
        V211.tests()
        V212.tests()
        V213.tests()
        PageExperienceTests.tests()
        V216.tests()
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
        while Date() < end { if c() { return true }; pump(0.05) }
        return c()
    }
    static func settle(_ t: TimeInterval) { pump(t) }
    /// 测试整体跑在一个 Timer 回调里，NSApp 的事件循环被挡住：只转 RunLoop 不会分发 AppKit 事件，
    /// 激活 / 成为活动窗口等状态就一直不更新。这里在等待时用 nextEvent + sendEvent 把排队的事件分发掉
    /// （nextEvent 带超时时同样会在 .default 模式下运行 RunLoop，计时器与主队列照常执行）。
    /// 设 MO_TEST_PLAIN_RUNLOOP=1 可回退到旧的纯 RunLoop 等待。
    static let plainRunLoop = ProcessInfo.processInfo.environment["MO_TEST_PLAIN_RUNLOOP"] == "1"
    static func pump(_ t: TimeInterval) {
        let until = Date().addingTimeInterval(t)
        if plainRunLoop || NSApp == nil { RunLoop.main.run(until: until); return }
        while Date() < until {
            guard let e = NSApp.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) else { break }
            NSApp.sendEvent(e)
        }
    }
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
        setbuf(stdout, nil) // 即使界面测试等待，也保留已完成断言供诊断
        // 测试进程必须是常规前台 App：accessory 模式下 NSApp.activate 可能不生效，
        // SwiftUI 就不会生成辅助功能树，界面测试与对比度检查会大面积误报。
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .aqua)
        let snap = args.contains("--snapshot")
        let out = args.firstIndex(of: snap ? "--snapshot" : "--uitest").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } ?? "/tmp/mo-test"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        // 隔离用户设置
        let keys = [BatterySettings.key, "menuBar.enabled", "stats.optimized", "stats.quitApps", "stats.freedMB", DisplayManager.settingsKey, KeepAwake.key]
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
                ContrastCheck.writeReport(out)
                let c = ContrastCheck.counts(ContrastCheck.cases)
                check(c.failed == 0 && c.unverified == 0 && c.passed > 0, "对比度验收汇总", ContrastCheck.summaryLine())
                print(ContrastCheck.summaryLine())
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
    /// 对比度检查（2.16 N1）：文字区域来自 `.contrastTarget` 布局标记，不再读辅助功能树。
    /// 每次调用是一个必测用例，结果为 passed / failed / unverified，汇总写入截图目录的 contrast-report.json；
    /// 未验收（缺必测目标、截图失败、没有测到文字）不算通过。详见 ContrastTests.swift。
    static func contrast(_ v: NSView, _ rep: NSBitmapImageRep?, _ name: String) {
        v.layoutSubtreeIfNeeded()
        let r = ContrastCheck.run(v, rep, caseID: name)
        let measured = r.targets.compactMap { $0.measuredRatio }
        let low = measured.min().map { String(format: "最低 %.2f:1", $0) } ?? "无实测值"
        check(r.status == .passed, "文字对比度 \(name)", "\(r.status.rawValue) · 测到 \(measured.count) 处，\(low)" + (r.reason.isEmpty ? "" : "；" + r.reason))
    }
    /// 布局检查（2.13 门槛 A）：
    /// - 页面标了摘要区（`pageSummary()`）时：摘要必须完整在可见范围内、不在滚动区域里；只有摘要下方的详情区可以局部滚动。
    /// - 没标摘要区时：沿用原规则，所有滚动区域都要放得下。
    /// - 两种情况都不允许出现常驻滚动条。说明文字 ≥ 12 pt 由 `fontlint.sh`（源码）和 `DS.fontSizes` 自检保证。
    static func fits(_ root: NSView, _ name: String) {
        let v = LayoutGate.evaluate(root)
        if v.summaries == 0 {
            check(v.problems.isEmpty, "无需滚动 \(name)", v.problems.isEmpty ? "\(v.scrolls) 个滚动区域都放得下" : v.problems.joined(separator: " "))
        } else {
            check(v.problems.isEmpty, "摘要一屏可见 \(name)", v.problems.isEmpty ? "摘要 \(v.summaries) 处在可见范围内；\(v.scrolls) 个滚动区域，其中 \(v.scrolledDetails) 个详情区局部滚动" : v.problems.joined(separator: " "))
        }
    }
    static func diffRatio(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return 1 }
        var d = 0, n = 0
        for y in stride(from: 0, to: a.pixelsHigh, by: 2) { for x in stride(from: 0, to: a.pixelsWide, by: 2) {
            n += 1
            guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { d += 1; continue }
            // 2x→1x 归一化会在文字边缘留下抗锯齿噪声；只统计肉眼可见的颜色/位置变化
            if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent) + abs(p.blueComponent - q.blueComponent) > 0.45 { d += 1 }
        } }
        return Double(d) / Double(max(1, n))
    }
    /// 屏幕缩放会让离屏窗口有时拍成 2x、有时拍成 1x（同一台机器两次运行就可能不同）。
    /// 统一降采样到 1x 再比对，基准图只保留一套，避免「@2x 基准图没重拍」造成的假失败。
    static func normalized(_ rep: NSBitmapImageRep) -> NSBitmapImageRep {
        let w = Int(rep.size.width), h = Int(rep.size.height)
        guard rep.pixelsWide > w, w > 0, h > 0,
              let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { return rep }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        rep.draw(in: NSRect(x: 0, y: 0, width: rep.size.width, height: rep.size.height))
        NSGraphicsContext.restoreGraphicsState()
        return out
    }
    static func golden(_ rep: NSBitmapImageRep?, _ name: String, _ dir: String?, approve: Bool) {
        guard let rep, let dir else { return }
        let current = normalized(rep)
        let path = dir + "/\(name).png"
        if approve || !FileManager.default.fileExists(atPath: path) {
            try? current.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            info("已更新基准图 \(name)"); return
        }
        guard let g = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()) else { check(false, "基准图 \(name) 可读"); return }
        let r = diffRatio(current, g)
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
        // 本机若开了「合并状态」且面板里显示音量/Wi-Fi，会多出 TrioPanelCard（约 64 pt）。
        // 单独跑 --snapshot 会量到 867，install-local 先跑的界面测试会把 menuIndicator 写成 cpu 并保存，于是正式量到 803。
        // 截图与默认高度门槛固定为不含该卡，结束时恢复用户原设置。
        let keepIndicator = BatteryAlerts.shared.settings.menuIndicator
        BatteryAlerts.shared.settings.menuIndicator = "cpu"
        defer { BatteryAlerts.shared.settings.menuIndicator = keepIndicator }
        CleanStats.shared.addOptimized(12); CleanStats.shared.addQuit(memMB: 2350)
        w.makeKeyAndOrderFront(nil)
        ensureActive(w, "截图窗口")
        primeAX() // 外部只读客户端使本轮离屏视图也生成真实 AX 文字节点
        settle(10)
        check(mon.cpuHist.count >= 3, "已采样", "\(mon.cpuHist.count) 次")
        let modes: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        let realCharge = ChargeClient.shared; ChargeClient.shared = chargeFixture()   // 用最高的「已安装」状态检查布局
        defer { ChargeClient.shared = realCharge }
        let pausedFx = chargeFixture(); pausedFx.st.adapterCut = false; pausedFx.st.externalDisplay = true; pausedFx.st.displayPaused = true
        let dockFx = chargeFixture(); dockFx.st.adapterCut = false; dockFx.st.dockProtected = true; dockFx.st.displayPaused = true
        for (mode, ap) in modes + [("paused-light", .aqua), ("paused-dark", .darkAqua), ("dock-light", .aqua), ("dock-dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: ap)
            let fixture = mode.hasPrefix("paused") ? pausedFx : (mode.hasPrefix("dock") ? dockFx : ChargeClient.shared)
            let host = NSHostingView(rootView: ChargeCard(c: fixture).padding(20).frame(width: 520).background(pageBG))
            let size = host.fittingSize; host.frame = NSRect(origin: .zero, size: size)
            let cw = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: size.width, height: size.height), styleMask: [.titled], backing: .buffered, defer: false)
            cw.appearance = NSAppearance(named: ap); cw.contentView = host; cw.orderFrontRegardless(); settle(1.0)
            contrast(host, pngRep(host, out + "/charge-\(mode).png"), "充电卡片 \(mode)")
            fits(host, "充电卡片 \(mode)")
            cw.orderOut(nil)
        }
        v15Snapshots(out)
        v16Snapshots(out)
        v23Snapshots(out)
        v24Snapshots(out)
        V25.snapshots(out)
        V28.snapshots(out)
        V213.snapshots(out)
        PageExperienceTests.snapshots(out)
        V216.snapshots(out)
        // v1.8 / v1.9 新页截图（只做布局检查，不做黄金图比对）
        // 改动记录用固定样例：不随本机真实记录的多少而变（记录多了页面本来就该滚动）
        let realChanges = ChangeLog.shared.records
        ChangeLog.shared.records = [
            ChangeRecord(kind: .clean, title: "清理到废纸篓：旧安装包.dmg", detail: "~/Downloads/旧安装包.dmg（1.2 GB）", reversible: true, restoreNote: "在「清理预览」的操作记录里点恢复"),
            ChangeRecord(kind: .clean, title: "从废纸篓恢复：旧安装包.dmg", detail: "已恢复到原位置：旧安装包.dmg", reversible: false, restoreNote: "需要的话可重新清理"),
        ]
        defer { ChangeLog.shared.records = realChanges }
        // 2.10：清理记录的三种状态（可恢复 / 已恢复 / 废纸篓里已不在）和自定义分区比例
        let realClean = CleanStore.shared.records
        CleanStore.shared.records = [
            CleanRecord(date: Date(), path: "/Users/me/Downloads/旧安装包.dmg", size: 1_288_490_188, trashed: true, trashPath: "/bin/ls"),
            CleanRecord(date: Date(), path: "/Users/me/Library/Caches/示例缓存", size: 52_428_800, trashed: true, trashPath: "/bin/ls", restored: true),
            CleanRecord(date: Date(), path: "/Users/me/Downloads/录屏.mov", size: 734_003_200, trashed: true, trashPath: "/不存在/录屏.mov"),
        ]
        let sc = SplitController.shared, realPrefs = sc.prefs, realScreens = sc.screens, realDriver = sc.driver
        let splitSuite = "mo.snapshot.split.\(getpid())"
        let splitUD = UserDefaults(suiteName: splitSuite)!; splitUD.removePersistentDomain(forName: splitSuite)
        sc.prefs = SplitPrefs(splitUD); sc.prefs.setCustom([25, 25, 25, 25], for: "S1"); sc.prefs.setRows([1, 2, 2, 1], for: "S1"); sc.driver = FakeDriver()
        sc.screens = FakeScreens([SplitDisplay(uuid: "S1", name: "内建显示器", visible: CGRect(x: 0, y: 0, width: 1728, height: 1079), scale: 2)], 1117)
        defer { CleanStore.shared.records = realClean; sc.prefs = realPrefs; sc.screens = realScreens; sc.driver = realDriver; splitUD.removePersistentDomain(forName: splitSuite) }
        for (mode, ap) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: ap)
            var powerSnapshot = fixture(); powerSnapshot.charging = false; powerSnapshot.onAC = true
            powerSnapshot.batteryVoltageV = 12.8; powerSnapshot.batteryCurrentA = 0
            for (view, name) in [(AnyView(CleanPage()), "clean"), (AnyView(ChangesPage()), "changes"), (AnyView(SplitPage()), "split-custom"), (AnyView(TrioGallery()), "trio-gallery"), (AnyView(TrioSettings().padding(16).frame(width: 640)), "trio-settings"), (AnyView(TrioPanelCard().padding(10).frame(width: PanelLayout.width)), "trio-panel"), (AnyView(BatteryPage(m: mon).powerTab(powerSnapshot)), "power-paused")] {
                let host = NSHostingView(rootView: view.frame(width: Layout.idealSize.width - 212, height: Layout.idealSize.height).background(pageBG))
                let size = host.fittingSize; host.frame = NSRect(origin: .zero, size: size)
                let cw = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: size.width, height: size.height), styleMask: [.titled], backing: .buffered, defer: false)
                cw.appearance = NSAppearance(named: ap); cw.contentView = host; cw.orderFrontRegardless(); settle(1.0)
                _ = pngRep(host, out + "/\(name)-\(mode).png")
                fits(host, "\(name) \(mode)")
                cw.orderOut(nil)
            }
        }
        NSApp.appearance = NSAppearance(named: .aqua)
        let screen = NSScreen.main
        let defaultSize = Layout.defaultSize(for: screen)
        for (mode, ap) in modes {
            NSApp.appearance = NSAppearance(named: ap)
            // 菜单栏面板
            let host = NSHostingView(rootView: PanelContent(m: mon))
            let size = host.fittingSize; host.frame = NSRect(origin: .zero, size: size)
            let pw = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: size.width, height: size.height), styleMask: [.titled], backing: .buffered, defer: false)
            pw.appearance = NSAppearance(named: ap); pw.contentView = host; pw.orderFrontRegardless(); settle(1.0)
            contrast(host, pngRep(host, out + "/panel-\(mode).png"), "面板 \(mode)")
            if mode == "light" { pngRep(host, out + "/panel.png") }
            check(size.width == PanelLayout.width && size.height > 400 && size.height <= 810, "面板尺寸 \(mode)（默认内容 ≤ 810 pt）", "\(Int(size.width))×\(Int(size.height))")
            pw.orderOut(nil)
            // 主窗口：默认尺寸和最小尺寸
            w.appearance = NSAppearance(named: ap)
            for (sz, szName) in [(defaultSize, "default"), (Layout.minSize, "min")] {
                w.setContentSize(sz); w.setFrameOrigin(NSPoint(x: -4000, y: 0)); w.orderFrontRegardless()
                for (sel, name) in [(Page.monitor, "dashboard"), (.battery, "battery"), (.overview, "overview")] {
                    Nav.shared.sel = sel; settle(1.2)
                    let tag = "\(name)-\(szName)-\(mode)"
                    let rep = pngRep(w.contentView!, out + "/\(tag).png")
                    fits(w.contentView!, tag)
                    contrast(w.contentView!, rep, tag)   // 2.16：默认与最小窗口都测
                    if szName == "default", mode == "light" { pngRep(w.contentView!, out + "/\(name).png") }
                }
            }
        }
        check(defaultSize.width >= Layout.minSize.width && defaultSize.height >= Layout.minSize.height, "默认窗口不小于最小尺寸", "\(Int(defaultSize.width))×\(Int(defaultSize.height))")
        // 固定数据的基准图（浅色/深色）：蓝牙外设用固定数据，避免本机连接的设备让基准图不稳定
        let realBT = BTBattery.shared; BTBattery.shared = V28.btFixture()
        defer { BTBattery.shared = realBT }
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
            Nav.shared.sel = .monitor; settle(1.2)
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
        // 2.16 N1：对比度检测不再依赖辅助功能树；状态样例（选中/禁用/错误/低电量）与 AX 不可用探针
        ContrastCheck.snapshots(out)
    }

    static func uiChecks(_ w: NSWindow) {
        let mon = Monitor.shared
        let keepIndicator = BatteryAlerts.shared.settings.menuIndicator
        defer { BatteryAlerts.shared.settings.menuIndicator = keepIndicator }
        let loginBefore = Actions.loginEnabled
        info("测试开始时登录项状态：\(loginBefore ? "已开启（用户设置，保持不动）" : "关闭")")
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
        // 面板是 .transient：数据等待期间窗口失焦会被系统关闭并把内容控制器置空；关掉就重开再核对
        if !StatusBar.shared.popover.isShown, let b = StatusBar.shared.item?.button { StatusBar.shared.show(from: b); settle(0.5) }
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
        check(Actions.loginEnabled == loginBefore && UIState.shared.login == loginBefore, "登录项开关反映真实状态且未被改动")
        StatusBar.shared.popover.performClose(nil)
        check(waitUntil(2) { !StatusBar.shared.popover.isShown && mon.interval == Monitor.lightInterval }, "关闭面板后降回 5 秒")
        check(waitUntil(1) { StatusBar.shared.popover.contentViewController == nil }, "关闭面板后释放面板视图")

        sec("主窗口")
        // 窗口若被系统回收过 contentView，先恢复 SwiftUI 根视图，否则整棵辅助功能树都是空的
        if !(w.contentView is NSHostingView<RootView>) { w.contentView = NSHostingView(rootView: RootView()) }
        // 放在主屏可见区域内（屏幕外窗口不会成为活动窗口，SwiftUI 也不生成辅助功能树）
        if let f = NSScreen.screens.first?.visibleFrame {
            let s = w.frame.size
            w.setFrameOrigin(NSPoint(x: f.midX - s.width / 2, y: max(f.minY, f.midY - s.height / 2)))
        }
        w.orderFrontRegardless()
        diag("主窗口-准备前", w)
        ensureActive(w, "主窗口"); w.makeFirstResponder(w.contentView)
        w.displayIfNeeded()
        settle(2.0)
        primeAX()
        var why = notReady(w)
        if why != nil {
            ensureActive(w, "主窗口-复核")
            _ = waitUntil(6) { Nav.shared.objectWillChange.send(); why = notReady(w); return why == nil }
        }
        diag("主窗口-准备后", w)
        check(why == nil, "测试窗口就绪（活动应用、活动窗口、未遮挡、辅助功能树非空）", why ?? "")
        check(waitUntil(8) { find(w.contentView!, label: "实时监控") != nil }, "侧边栏「实时监控」")
        if let b = find(w.contentView!, label: "实时监控") { b.press() }
        check(waitUntil(2) { Nav.shared.sel == .monitor && mon.dashboardShown }, "侧边栏打开实时监控")
        if find1(w.contentView!, label: "实时监控") == nil { diag("主窗口-失败时", w) }
        sec("快捷操作（已迁至实时监控顶栏）")
        find(w.contentView!, id: "monitor.actions")?.press()
        check(waitUntil(2) { w.attachedSheet?.contentView != nil }, "顶栏快捷操作打开")
        let pv = w.attachedSheet?.contentView ?? w.contentView!
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

        find(pv, id: "monitor.actions.close")?.press()
        check(waitUntil(2) { w.attachedSheet == nil }, "关闭快捷操作")
        mon.mainWindowVisible = { true }; mon.reschedule()
        check(mon.interval == Monitor.detailInterval, "仪表盘可见时 2 秒采样")
        check(find(w.contentView!, id: "dash.login") == nil && find(w.contentView!, id: "dash.menubar") == nil, "监控页不再混入启动或菜单栏设置")
        Nav.shared.sel = .settings; settle(0.3)
        if let t = find(w.contentView!, id: "set.login") { check((t.value as? NSNumber)?.intValue == (loginBefore ? 1 : 0), "设置页登录项开关与系统一致") } else { check(false, "找到设置页登录项开关") }
        Nav.shared.sel = .monitor; settle(0.3)
        mon.mainWindowVisible = { false }; mon.reschedule()
        check(mon.interval == Monitor.lightInterval, "窗口隐藏后降频")
        if let b = find(w.contentView!, label: "电池") { b.press() }
        check(waitUntil(2) { Nav.shared.sel == .battery }, "侧边栏打开电池页")
        if let t = find(w.contentView!, id: "bat.alertsOn") { check((t.value as? NSNumber)?.intValue == 0, "电量提醒默认关闭") } else { check(false, "找到提醒开关") }
        sec("充电控制卡片")
        let daemonBefore = ChargeClient.shared.daemon.status
        if ChargeClient.shared.phase == .notInstalled { check(waitUntil(3) { find(w.contentView!, id: "charge.install") != nil }, "未安装时显示「安装充电助手」（测试不点击）") }
        else { info("充电助手状态：\(ChargeClient.shared.phase)") }
        let realClient = ChargeClient.shared
        let fx = chargeFixture(); ChargeClient.shared = fx
        Nav.shared.sel = .monitor; settle(0.5); Nav.shared.sel = .battery
        check(waitUntil(3) { find(w.contentView!, id: "charge.enabled") != nil && find(w.contentView!, id: "charge.limit") != nil && find(w.contentView!, id: "charge.uninstall") != nil }, "已安装时显示开关、上限滑块、卸载按钮")
        if let t = find(w.contentView!, id: "charge.enabled") { t.press(); check(waitUntil(1) { !fx.st.settings.enabled }, "点开关关闭上限") }
        settle(0.3); if let t = find(w.contentView!, id: "charge.enabled") { t.press(); check(waitUntil(1) { fx.st.settings.enabled }, "再点开启") }
        settle(0.3)
        if let b = find(w.contentView!, id: "charge.topup") { b.press(); check(waitUntil(1) { fx.st.topUp }, "点「充到 100%」进入临时充满") } else { check(false, "找到「充到 100%」") }
        ChargeClient.shared = realClient; Nav.shared.sel = .monitor; settle(0.3); Nav.shared.sel = .battery
        check(ChargeClient.shared.daemon.status == daemonBefore, "测试没有注册/卸载充电助手", "\(daemonBefore.rawValue)")
        check(waitUntil(4) { !EnergyTracker.shared.live.isEmpty }, "耗电实时数据", EnergyTracker.shared.live.prefix(3).map { "\($0.app) \(String(format: "%.2f", $0.watts))W" }.joined(separator: ", "))
        v15UI(w)
        v16UI(w)
        sec("清理与改动页入口（v1.8 / v1.9）")
        if let b = find(w.contentView!, label: "清理预览") { b.press(); check(waitUntil(2) { Nav.shared.sel == .clean }, "侧边栏打开清理预览") } else { check(false, "找到清理预览") }
        check(find(w.contentView!, id: "clean.scan") != nil, "清理页有开始扫描按钮")
        if let b = find(w.contentView!, label: "改动与提醒") { b.press(); check(waitUntil(2) { Nav.shared.sel == .changes }, "侧边栏打开改动与提醒") } else { check(false, "找到改动与提醒") }
        check(find(w.contentView!, id: "v19.alertsOn") != nil, "改动页有提醒开关（默认关闭）")
        sec("网络页双标签（v1.7）")
        if let b = find(w.contentView!, label: "网络诊断") { b.press(); check(waitUntil(2) { Nav.shared.sel == .network }, "侧边栏打开网络诊断") } else { check(false, "找到网络诊断") }
        if let b = find(w.contentView!, id: "net.tab.1") { b.press(); check(waitUntil(2) { Nav.shared.netTab == 1 }, "点「测速」切到第二标签") } else { check(false, "找到测速标签") }
        check(find(w.contentView!, id: "speed.run") != nil, "第二标签有测速")
        if let b = find(w.contentView!, id: "net.tab.2") { b.press(); check(waitUntil(2) { Nav.shared.netTab == 2 }, "点「流量」切到第三标签") } else { check(false, "找到流量标签") }
        check(find(w.contentView!, id: "netcard.refresh") != nil && find(w.contentView!, id: "traffic.range") != nil, "第三标签有按应用流量、历史、网络卡片")
        if let b = find(w.contentView!, id: "net.tab.0") { b.press(); check(waitUntil(2) { Nav.shared.netTab == 0 }, "点「诊断」切回第一标签") } else { check(false, "找到诊断标签") }
        check(find(w.contentView!, id: "net.run") != nil, "第一标签有开始诊断")
        sec("电池页双标签（v2.0）")
        if let b = find(w.contentView!, label: "电池") { b.press(); check(waitUntil(2) { Nav.shared.sel == .battery }, "侧边栏打开电池页") } else { check(false, "找到电池") }
        if let b = find(w.contentView!, id: "bat.tab.1") { b.press(); check(find(w.contentView!, id: "bat.lowpower.settings") != nil, "功率标签有打开系统电源设置") } else { check(false, "找到功率与能耗标签") }
        if let b = find(w.contentView!, id: "bat.tab.0") { b.press(); check(find(w.contentView!, id: "bat.alertsOn") != nil, "切回电池概览有电量提醒开关") } else { check(false, "找到电池概览标签") }
        v22UI(w)
        v23UI(w)
        v24UI(w)
        V25.ui(w); V26.ui(w); V28.ui(w); V292.ui(w); V210.ui(w); V211.ui(w); V213.ui(w); PageExperienceTests.ui(w); V216.ui(w)
        UIState.shared.menuBar = false
        check(StatusBar.shared.item == nil && mon.interval == 0, "关闭菜单栏图标后停止采样")
        check(Actions.loginEnabled == loginBefore, "测试全程没有改动登录项")
        w.orderOut(nil)
    }
}
