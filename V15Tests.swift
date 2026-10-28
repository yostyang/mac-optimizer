// v1.5 测试：显示器、网络诊断、DNS 修复（模拟 networksetup）、蓝牙电量（模拟数据源）
import SwiftUI
import AppKit

final class MockRunner: CommandRunner {
    var dns: [String: [String]] = ["Wi-Fi": [], "AX88772D": ["192.168.0.1"], "Thunderbolt Bridge": []]
    var ips: [String: String] = ["en0": "192.168.0.8"]
    var calls: [[String]] = []
    var failSet = false
    func run(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
        calls.append([path] + args)
        switch (path, args.first ?? "") {
        case ("/usr/sbin/networksetup", "-listnetworkserviceorder"):
            return (0, "An asterisk (*) denotes that a network service is disabled.\n(1) AX88772D\n(Hardware Port: AX88772D, Device: en7)\n\n(2) Thunderbolt Bridge\n(Hardware Port: Thunderbolt Bridge, Device: bridge0)\n\n(3) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)\n\n(*) Old VPN\n(Hardware Port: VPN, Device: )\n")
        case ("/usr/sbin/ipconfig", _): return (0, ips[args.last ?? ""] ?? "")
        case ("/usr/sbin/networksetup", "-getdnsservers"):
            let v = dns[args[1]] ?? []; return (0, v.isEmpty ? "There aren't any DNS Servers set on \(args[1]).\n" : v.joined(separator: "\n") + "\n")
        case ("/usr/sbin/networksetup", "-setdnsservers"):
            if failSet { return (1, "") }
            let rest = Array(args.dropFirst(2)); dns[args[1]] = rest == ["Empty"] ? [] : rest; return (0, "")
        default: return (0, "")
        }
    }
}
final class MockDisplays: DisplaySystem {
    var list: [DisplayInfo]
    var applied: [DMode] = []
    init() {
        let modes: [DMode] = [
            DMode(width: 5120, height: 2160, pixelWidth: 5120, pixelHeight: 2160, refresh: 75), DMode(width: 5120, height: 2160, pixelWidth: 5120, pixelHeight: 2160, refresh: 60),
            DMode(width: 3840, height: 1620, pixelWidth: 3840, pixelHeight: 1620, refresh: 75), DMode(width: 3440, height: 1440, pixelWidth: 3440, pixelHeight: 1440, refresh: 60),
            DMode(width: 2560, height: 1080, pixelWidth: 5120, pixelHeight: 2160, refresh: 75), DMode(width: 2560, height: 1080, pixelWidth: 5120, pixelHeight: 2160, refresh: 60),
            DMode(width: 1920, height: 810, pixelWidth: 3840, pixelHeight: 1620, refresh: 75)]
        list = [DisplayInfo(id: 3, name: "Kuycon P40W", builtin: false, current: modes[0], modes: modes)]
    }
    func displays() -> [DisplayInfo] { list }
    func apply(_ m: DMode, to id: CGDirectDisplayID) -> Bool { applied.append(m); list[0].current = m; return true }
}
final class MockGamma: GammaSystem {
    var last: (Double, Double, Double)?; var restored = 0
    func set(_ id: CGDirectDisplayID, r: Double, g: Double, b: Double) -> Bool { last = (r, g, b); return true }
    func restore() { restored += 1; last = nil }
}
final class MockDDC: DDCChannel {
    var vals: [UInt8: Int] = [0x10: 80, 0x12: 50, 0x60: 0x0F]
    var writes: [(UInt8, Int)] = []
    func read(_ code: UInt8) -> (value: Int, max: Int)? { vals[code].map { ($0, 100) } }
    func write(_ code: UInt8, _ value: Int) -> Bool { writes.append((code, value)); vals[code] = value; return true }
    func capabilities() -> String { "(prot(monitor)type(lcd)MStarcmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14(05 08 0B 0C) 16 18 1A 52 60( 11 0F 10) AA(01 02) AC AE B2 B6 C6 C8 C9 D6(01 04 05) DC(00 02 03 05 ) DF FD)mccs_ver(2.1)mswhql(1))" }
}
final class MockNet: NetProbe {
    func ping(_ host: String) -> PingResult { host == "github.com" ? PingResult(avgMs: 210, loss: 20, sent: 5) : PingResult(avgMs: host.hasPrefix("192") ? 3 : 28, loss: 0, sent: 5) }
    func gateway() -> String? { "192.168.0.1" }
    func resolve(_ host: String) -> (ms: Double?, addrs: [String]) { host.hasSuffix("-check.com") ? (12, []) : (host == "github.com" ? (18, ["198.18.0.42"]) : (22, ["110.242.68.66"])) }
    func effectiveDNS() -> [String] { ["26.26.26.53"] }
    func serviceDNS() -> [DNSServiceState] { [DNSServiceState(service: "Wi-Fi", device: "en0", servers: [])] }
    func vpnApps() -> [String] { ["LetsVPN"] }
}
final class MockBT: BTSource {
    var gattCalls = 0
    func paired() -> [BTDevice] {
        BTParse.profiler(Data(#"{"SPBluetoothDataType":[{"device_connected":[{"MX Master 2S":{"device_address":"D3:F0","device_minorType":"Mouse","device_services":"0x400020 < HID BLE >"}},{"Young AirPods Pro":{"device_address":"5C:52","device_minorType":"Headphones","device_batteryLevelLeft":"85%","device_batteryLevelRight":"80%","device_batteryLevelCase":"40%"}},{"Keychron K3 Pro":{"device_address":"6C:93","device_minorType":"Keyboard","device_services":"0x80020 < HID ACL >"}},{"小米蓝牙语音遥控器":{"device_address":"C0:5D","device_services":"0x400020 < HID BLE >"}}],"device_not_connected":[{"MX KEYS S":{"device_address":"D8:58","device_minorType":"Keyboard"}},{"yost的iPhone":{"device_address":"E8:78"}}]}]}"#.utf8))
    }
    func ioreg() -> [String: Int] { ["Magic Trackpad": 64] }
    func gatt(_ done: @escaping ([String: Int], String?) -> Void) { gattCalls += 1; done(["MX Master 2S": 90, "小米蓝牙语音遥控器": 15], nil) }
}

extension MOTests {
    static func v15Tests() {
        sec("显示器：模式、DDC 能力、色温、场景、亮屏时间")
        let md = MockDisplays(), d = md.list[0]
        let r = d.resolutions(hidpi: false); check(r.first?.label == "5120×2160" && r.count == 3 && !r.contains { $0.hidpi }, "非 HiDPI 分辨率去重排序", r.map(\.label).joined(separator: ","))
        check(d.resolutions(hidpi: true).map(\.label) == ["2560×1080", "1920×810"], "HiDPI 分辨率")
        check(d.refreshRates(for: d.current) == [75, 60] && d.hasHiDPIChoice, "刷新率列表")
        let caps = DDCCaps.parse(MockDDC().capabilities())
        check(caps.vcps.contains(0x10) && caps.vcps.contains(0x12) && !caps.vcps.contains(0x62), "P40W 能力：亮度/对比度，无音量")
        check(caps.inputs == [0x11, 0x0F, 0x10], "P40W 输入源 HDMI1/DP1/DP2", caps.inputs.map { String(format: "%02X", $0) }.joined(separator: " "))
        let w = ColorTemp.rgb(6500), n = ColorTemp.rgb(3400)
        check(abs(w.0 - 1) < 0.02 && abs(w.1 - 1) < 0.02 && abs(w.2 - 1) < 0.02, "6500K = 原色")
        check(n.0 > 0.95 && n.2 < 0.7 && n.1 < n.0, "3400K 偏暖（蓝色减弱）", String(format: "%.2f %.2f %.2f", n.0, n.1, n.2))
        var ds = DisplaySettings(); check(!ds.gammaOn && !ds.autoSwitch, "软件调光/定时默认关闭（避免与 MonitorBar 冲突）")
        check(ds.scheduled(minute: 8 * 60) == "day" && ds.scheduled(minute: 23 * 60) == "night" && ds.scheduled(minute: 3 * 60) == "night", "按时间判断日间/夜间")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let t2130 = cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 21, minute: 30))!
        check(abs(ds.secondsToNextSwitch(from: t2130, cal: cal) - 1800) < 1, "下一个切换点只定时一次（30 分钟后）")
        ds.dayStart = 22 * 60; ds.nightStart = 6 * 60
        check(ds.scheduled(minute: 23 * 60) == "day" && ds.scheduled(minute: 12 * 60) == "night", "跨午夜的时段")
        let gm = MockGamma(), dm = DisplayManager(sys: md, gamma: gm); dm.offline = true
        let ddc = MockDDC(); dm.channels = { _ in ddc }
        dm.refresh(); dm.conflict = ""
        let done = DispatchSemaphore(value: 0); var probed = false
        dm.probeDDC { probed = true; done.signal() }
        _ = waitUntil(3) { probed }
        let st = dm.ddc[3]; check(st?.available == true && st?.brightness == 80 && st?.contrast == 50 && st?.volume == nil && st?.input == 0x0F, "DDC 读取（模拟 P40W）", "\(String(describing: st))")
        dm.setDDC(3, .brightness, 40); dm.setDDC(3, .brightness, 45); _ = waitUntil(1) { !ddc.writes.isEmpty }
        settle(0.3); check(ddc.writes.count == 1 && ddc.writes[0] == (0x10, 45), "拖动滑块合并写入（只写最后一个值）", "\(ddc.writes)")
        dm.setGamma(on: true); check(gm.last.map { abs($0.0 - 1) < 0.02 } == true, "开启软件调光")
        dm.apply(scene: DScene.all[3]); check(dm.settings.scene == "night" && (gm.last?.2 ?? 1) < 0.6, "夜间场景：调暗+暖色")
        _ = waitUntil(1) { ddc.writes.count >= 2 }; check(ddc.writes.last.map { $0.0 == 0x10 && $0.1 == 30 } == true, "场景同时调硬件亮度")
        dm.setGamma(on: false); check(gm.restored >= 1 && gm.last == nil, "关闭即恢复系统原色")
        let gm2 = MockGamma(), dm2 = DisplayManager(sys: md, gamma: gm2); dm2.offline = true; dm2.conflict = "MonitorBar"
        dm2.apply(scene: DScene.all[1]); check(!dm2.settings.gammaOn && gm2.last == nil, "检测到 MonitorBar 时场景不动 Gamma")
        dm.switchMode(3, to: d.modes[2]); check(md.applied.last == d.modes[2] && dm.pending != nil, "切换分辨率并等待确认")
        dm.revert(); check(md.list[0].current == d.modes[0] && dm.pending == nil, "还原到原分辨率")
        dm.switchMode(3, to: d.modes[1]); dm.keep(); check(dm.pending == nil && md.list[0].current == d.modes[1], "确认保留")
        var us = UsageStore()
        let a = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 23, minute: 30))!
        us.add(from: a, to: a.addingTimeInterval(3600), cal: cal)
        check(us.days["2026-10-27"] == 1800 && us.days["2026-10-28"] == 1800, "亮屏时间跨午夜拆分")
        check(us.last7(now: t2130, cal: cal).count == 7 && us.last7(now: t2130, cal: cal).last?.0 == "今天", "7 天柱状图数据")
        us.days["2026-09-01"] = 99; us.prune(now: t2130, cal: cal); check(us.days["2026-09-01"] == nil, "只保留 14 天")

        sec("网络诊断：解析与判断")
        let pr = NetParse.ping("5 packets transmitted, 4 packets received, 20.0% packet loss\nround-trip min/avg/max/stddev = 10.1/12.5/15.0/1.2 ms")
        check(pr.sent == 5 && pr.loss == 20 && pr.avgMs == 12.5, "ping 输出解析")
        check(NetParse.ping("5 packets transmitted, 0 packets received, 100.0% packet loss").avgMs == nil, "全部超时")
        check(NetParse.gateway("   route to: default\n    gateway: 192.168.0.1\n  interface: en0") == "192.168.0.1", "网关解析")
        check(NetParse.effectiveDNS("DNS configuration\n\nresolver #1\n  nameserver[0] : 26.26.26.53\n  nameserver[1] : 223.5.5.5\n\nresolver #2\n  nameserver[0] : 1.1.1.1") == ["26.26.26.53", "223.5.5.5"], "系统实际 DNS")
        check(NetParse.verdict(host: "x", ms: 10, addrs: ["1.2.3.4"], expectNX: true) == .suspicious, "不存在的域名被解析 → 劫持")
        check(NetParse.verdict(host: "x", ms: 10, addrs: ["198.18.0.5"], expectNX: true) == .vpnFake, "VPN 虚拟地址不算劫持")
        check(NetParse.verdict(host: "x", ms: 10, addrs: ["10.0.0.1"], expectNX: false) == .suspicious && NetParse.verdict(host: "x", ms: nil, addrs: [], expectNX: false) == .failed, "内网地址/解析失败")
        let nd = NetDiag(); nd.probe = MockNet(); var fin = false; nd.run { fin = true }
        check(waitUntil(5) { fin } && nd.targets.count == 6 && nd.targets[0].name.hasPrefix("路由器") && nd.resolves.count == 5, "按需诊断完成（模拟）")
        check(nd.summary.0.contains("丢包"), "汇总：部分网站丢包", nd.summary.0)

        sec("DNS 一键修复（模拟 networksetup，不改真实 DNS）")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mo-dns-\(getpid()).json"); try? FileManager.default.removeItem(at: tmp)
        let mr = MockRunner(), fx = DNSFixer(runner: mr, backupURL: tmp)
        check(fx.services().map(\.name) == ["AX88772D", "Thunderbolt Bridge", "Wi-Fi"], "列出启用的网络服务（跳过已停用）")
        check(fx.activeServices().map(\.name) == ["Wi-Fi"], "只改正在使用的网络")
        mr.dns["Wi-Fi"] = ["8.8.8.8"]
        var res = fx.setAli(); check(res.0 && mr.dns["Wi-Fi"] == DNSConst.ali && mr.dns["AX88772D"] == ["192.168.0.1"], "设为 223.5.5.5 / 223.6.6.6")
        check(mr.calls.contains { $0 == ["/usr/bin/dscacheutil", "-flushcache"] } && mr.calls.contains { $0 == ["/usr/bin/killall", "-HUP", "mDNSResponder"] }, "清除 DNS 缓存")
        check(fx.loadBackup() == [DNSServiceState(service: "Wi-Fi", device: "en0", servers: ["8.8.8.8"])], "改之前保存原值")
        _ = fx.setAli(); check(fx.loadBackup()?.first?.servers == ["8.8.8.8"], "再点一次不覆盖最初的备份")
        res = fx.restore(); check(res.0 && mr.dns["Wi-Fi"] == ["8.8.8.8"] && fx.loadBackup() == nil, "恢复原 DNS 并删除备份")
        mr.dns["Wi-Fi"] = []; _ = fx.setAli(); _ = fx.restore()
        check(mr.calls.last(where: { $0.count > 1 && $0[1] == "-setdnsservers" }) == ["/usr/sbin/networksetup", "-setdnsservers", "Wi-Fi", "Empty"], "原来是自动（DHCP）→ 恢复为 Empty")
        check(!fx.restore().0, "没有备份时不能恢复")
        mr.failSet = true; res = fx.setAli(); check(!res.0 && res.1.contains("Wi-Fi"), "设置失败时报告", res.1); mr.failSet = false; _ = fx.restore()
        mr.ips = [:]; check(!fx.setAli().0, "没有联网的服务时不改")
        check(mr.calls.allSatisfy { ["/usr/sbin/networksetup", "/usr/sbin/ipconfig", "/usr/bin/dscacheutil", "/usr/bin/killall"].contains($0[0]) }, "只调用固定的系统命令")
        // XPC 白名单
        let names = Set((0..<64).compactMap { _ in nil as String? })
        _ = names
        var count: UInt32 = 0
        let ml = protocol_copyMethodDescriptionList(ChargeHelperProtocol.self, true, true, &count)
        let sels = Set((0..<Int(count)).map { NSStringFromSelector(ml![$0].name!) }); free(ml)
        check(sels == ChargeValidate.allowedSelectors && sels.contains("setAliDNS:") && sels.contains("restoreDNS:") && sels.count == 10, "XPC 协议只有白名单里的 10 个方法", sels.sorted().joined(separator: " "))
        let svc = ChargeService(ctl: ChargeController(io: MockSMC.tahoe27(), settings: ChargeSettings()), reader: { (80, true, false) }, persist: { _ in })
        mr.ips = ["en0": "1.2.3.4"]; mr.dns["Wi-Fi"] = []
        var got: (Bool, String)?; svc.setAliDNS { got = ($0, $1) }; check(got?.0 == false, "助手未配置 DNS 时拒绝")
        svc.dns = fx; svc.setAliDNS { got = ($0, $1) }; check(got?.0 == true && mr.dns["Wi-Fi"] == DNSConst.ali, "助手 setAliDNS（模拟）")
        var sd = Data(); svc.dnsStatus { sd = $0 }; let ss = try? JSONDecoder().decode(DNSStatus.self, from: sd)
        check(ss?.backup?.first?.servers == [] && ss?.services.first?.servers == DNSConst.ali, "助手 dnsStatus 返回当前值和备份")
        svc.restoreDNS { got = ($0, $1) }; check(got?.0 == true && mr.dns["Wi-Fi"] == [], "助手 restoreDNS（模拟）")
        check(svc.requirement == ChargeConst.clientRequirement, "DNS 方法与充电共用同一签名校验")
        try? FileManager.default.removeItem(at: tmp)

        sec("蓝牙设备电量（模拟数据源）")
        let pl = MockBT().paired()
        check(pl.count == 5 && !pl.contains { $0.name.contains("iPhone") }, "解析已配对设备（排除手机）", pl.map(\.name).joined(separator: ","))
        let ap = pl.first { $0.name.contains("AirPods") }; check(ap?.percent == 80 && ap?.parts["盒"] == 40, "AirPods 左右耳和充电盒")
        let mg = BTParse.merge(paired: pl, ioreg: ["Magic Trackpad": 64], gatt: ["MX Master 2S": 90], gattIssue: nil)
        check(mg.first { $0.name == "MX Master 2S" }?.percent == 90 && mg.first { $0.name == "MX Master 2S" }?.source == "蓝牙标准电量服务", "罗技 BLE 设备：读标准电量服务")
        check(mg.first { $0.name.hasPrefix("Keychron") }?.reason == "经典蓝牙设备，macOS 不公开电量", "经典蓝牙：写明原因")
        check(mg.first { $0.name == "小米蓝牙语音遥控器" }?.reason == "设备没有提供标准电量服务", "BLE 无电量服务：写明原因")
        check(mg.first { $0.name == "MX KEYS S" }?.reason == "未连接" && mg.first { $0.name == "Magic Trackpad" }?.percent == 64, "未连接 / IORegistry 设备")
        check(BTParse.merge(paired: pl, ioreg: [:], gatt: [:], gattIssue: "没有蓝牙权限").first { $0.name == "MX Master 2S" }?.reason == "没有蓝牙权限", "没有权限时提示")
        let bt = BTBattery(); bt.persist = false; bt.settings = BTSettings(); bt.source = MockBT(); var notes: [String] = []; bt.notify = { t, _ in notes.append(t) }
        var ok = false; bt.refresh { ok = true }; check(waitUntil(3) { ok } && bt.withBattery.count == 4, "刷新合并", bt.withBattery.map { "\($0.name) \($0.percent!)%" }.joined(separator: ", "))
        check(notes.isEmpty && !BTSettings().lowAlert && BTSettings().threshold == 20, "低电量通知默认关闭")
        bt.settings.lowAlert = true; bt.checkAlerts(); bt.checkAlerts(); check(notes == ["小米蓝牙语音遥控器 电量低"], "开启后低于 20% 只通知一次", "\(notes)")
        check(BTBattery.interval >= 300, "每 5 分钟刷新，不持续扫描")
        check(Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil, "Info.plist 有蓝牙用途说明")
        info("本机已配对：" + RealBTSource().paired().map { "\($0.name)\($0.connected ? "（已连接）" : "")" }.joined(separator: "、"))
    }

    // MARK: 界面
    static func v15Fixtures() -> (DisplayManager, NetDiag, DNSClient, BTBattery) {
        let gm = MockGamma(), dm = DisplayManager(sys: MockDisplays(), gamma: gm); dm.offline = true
        let ddc = MockDDC(); dm.channels = { _ in ddc }; dm.refresh(); dm.conflict = "MonitorBar"
        dm.ddc = [3: DDCState(available: true, caps: DDCCaps.parse(ddc.capabilities()), brightness: 80, contrast: 50, input: 0x0F)]
        let nd = NetDiag(); nd.probe = MockNet()
        let mr = MockRunner(); mr.dns["Wi-Fi"] = []
        let svc = ChargeService(ctl: ChargeController(io: MockSMC.tahoe27(), settings: ChargeSettings()), reader: { (80, true, false) }, persist: { _ in })
        svc.dns = DNSFixer(runner: mr, backupURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mo-dns-ui-\(getpid()).json"))
        let dc = DNSClient(); dc.direct = svc; dc.offline = true
        let bt = BTBattery(); bt.persist = false; bt.settings = BTSettings(); bt.source = MockBT(); bt.userAsked = true
        return (dm, nd, dc, bt)
    }
    static func screenTimeFixture() {
        var cal = Calendar.current; cal.timeZone = .current
        let now = Date(); var us = UsageStore()
        for (i, h) in [5.2, 7.8, 6.1, 8.4, 3.0, 9.1, 4.6].enumerated() {
            let day = cal.startOfDay(for: cal.date(byAdding: .day, value: i - 6, to: now)!)
            us.days[UsageStore.dayKey(day)] = h * 3600
        }
        ScreenTime.shared.inject(us, now: now)
    }
    static func v15UI(_ w: NSWindow) {
        sec("显示器 / 网络 / 蓝牙 界面（模拟数据）")
        let real = (DisplayManager.shared, NetDiag.shared, DNSClient.shared, BTBattery.shared)
        let (dm, nd, dc, bt) = v15Fixtures()
        DisplayManager.shared = dm; NetDiag.shared = nd; DNSClient.shared = dc; BTBattery.shared = bt
        defer { DisplayManager.shared = real.0; NetDiag.shared = real.1; DNSClient.shared = real.2; BTBattery.shared = real.3 }
        let md = dm.sys as! MockDisplays
        if let b = find(w.contentView!, label: "显示器") { b.press() }
        check(waitUntil(2) { Nav.shared.sel == -4 }, "侧边栏打开显示器页")
        check(find(w.contentView!, id: "ddc.brightness") != nil && find(w.contentView!, id: "ddc.contrast") != nil, "显示亮度/对比度滑块")
        check(find1(w.contentView!, id: "ddc.volume") == nil, "不支持的音量已隐藏")
        if let b = find(w.contentView!, id: "scene.night") { b.press(); check(waitUntil(1) { dm.settings.scene == "night" }, "点「夜间」场景") } else { check(false, "找到夜间场景") }
        check(!dm.settings.gammaOn, "有 MonitorBar 时不自动开软件调光")
        if let b = find(w.contentView!, label: "3840×1620") { b.press(); check(waitUntil(1) { dm.pending != nil && md.applied.last?.width == 3840 }, "点分辨率切换（模拟）") } else { check(false, "找到分辨率按钮") }
        if let b = find(w.contentView!, id: "disp.revert") { b.press(); check(waitUntil(1) { dm.pending == nil && md.list[0].current.width == 5120 }, "点「还原」") } else { check(false, "找到还原按钮") }
        if let b = find(w.contentView!, label: "网络诊断") { b.press() }
        check(waitUntil(2) { Nav.shared.sel == -5 }, "侧边栏打开网络诊断")
        if let b = find(w.contentView!, id: "net.run") { b.press(); check(waitUntil(5) { nd.lastRun != nil && !nd.targets.isEmpty }, "点「开始诊断」") } else { check(false, "找到开始诊断") }
        if let b = find(w.contentView!, id: "dns.ali") { b.press(); check(waitUntil(3) { dc.isAli && dc.status?.backup != nil }, "点「一键设为阿里 DNS」（模拟助手）") } else { check(false, "找到 DNS 按钮") }
        if let b = find(w.contentView!, id: "dns.restore") { b.press(); check(waitUntil(3) { !dc.isAli && dc.status?.backup == nil }, "点「恢复原 DNS」") } else { check(false, "找到恢复按钮") }
        if let b = find(w.contentView!, label: "电池") { b.press() }
        if let b = find(w.contentView!, id: "bt.refresh") { b.press() }
        check(waitUntil(4) { bt.withBattery.count == 4 }, "电池页点刷新加载蓝牙电量")
        check(find(w.contentView!, id: "bt.lowAlert") != nil, "低电量通知开关")
        Nav.shared.sel = -2
    }
    static func v15Snapshots(_ out: String) {
        let real = (DisplayManager.shared, NetDiag.shared, DNSClient.shared, BTBattery.shared)
        let (dm, nd, dc, bt) = v15Fixtures()
        DisplayManager.shared = dm; NetDiag.shared = nd; DNSClient.shared = dc; BTBattery.shared = bt
        defer { DisplayManager.shared = real.0; NetDiag.shared = real.1; DNSClient.shared = real.2 }   // 蓝牙保留模拟数据：后面的电池页截图用它检查最满时的布局
        screenTimeFixture()
        var ok = false; nd.run { ok = true }; _ = waitUntil(5) { ok }
        dc.refresh(); _ = waitUntil(2) { dc.status != nil }
        ok = false; bt.refresh { ok = true }; _ = waitUntil(3) { ok }
        for (mode, ap) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: ap)
            func shot<V: View>(_ v: V, _ name: String, width: CGFloat? = nil, height: CGFloat? = nil) {
                let host = NSHostingView(rootView: v.frame(width: width, height: height).background(pageBG))
                let size = host.fittingSize; host.frame = NSRect(origin: .zero, size: size)
                let cw = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: size.width, height: size.height), styleMask: [.titled], backing: .buffered, defer: false)
                cw.appearance = NSAppearance(named: ap); cw.contentView = host; cw.orderFrontRegardless(); settle(1.2)
                if let rep = pngRep(host, out + "/\(name)-\(mode).png") { contrast(host, rep, "\(name) \(mode)") }
                fits(host, "\(name) \(mode)")
                cw.orderOut(nil)
            }
            for (sz, tag) in [(Layout.idealSize, ""), (NSSize(width: Layout.minSize.width - 212, height: Layout.minSize.height), "-min")] {
                shot(DisplayPage(), "display" + tag, width: tag.isEmpty ? sz.width - 212 : sz.width, height: sz.height)
                shot(NetworkPage(), "network" + tag, width: tag.isEmpty ? sz.width - 212 : sz.width, height: sz.height)
            }
            shot(BTCard(macLevel: 84).padding(20), "bt", width: 480)
        }
        NSApp.appearance = NSAppearance(named: .aqua)
        ScreenTime.shared.now = Date.init
    }
}
