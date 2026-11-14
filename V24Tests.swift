import Foundation
import SwiftUI
import AppKit

extension MOTests {
    static func v24Tests() {
        sec("2.4 nettop 解析与按应用字节")
        let csv = ",bytes_in,bytes_out,\nLetsVPN.69734,114764642,38897036,\nMicrosoft Edge .43049,13820645,253980,\nweird.name.with.dots.77,10,20,\nbad line\nnoPid,1,2,\n"
        let p = NetTop.parse(csv)
        check(p.count == 3 && p[69734]?.name == "LetsVPN" && p[43049]?.name == "Microsoft Edge " && p[77]?.name == "weird.name.with.dots", "解析进程名.pid 与收发字节，跳过表头与坏行")
        check(p[69734]?.inB == 114764642 && p[69734]?.outB == 38897036, "字节数按原值读取")
        let t0 = Date(timeIntervalSince1970: 1_000_000), t1 = t0.addingTimeInterval(60)
        func raw(_ phys: [Int32: ProcBytes], _ tun: [Int32: ProcBytes] = [:], if ifc: (UInt64, UInt64)? = nil, tunOn: Bool = false, at: Date) -> RawSample { RawSample(phys: phys, tun: tun, ifPhys: ifc, tunOn: tunOn, at: at) }
        let a0 = raw([1: ProcBytes(name: "Edge", pid: 1, inB: 1000, outB: 100), 2: ProcBytes(name: "Old", pid: 2, inB: 500, outB: 0), 3: ProcBytes(name: "Reused", pid: 3, inB: 9000, outB: 9000)], if: (10_000, 2_000), at: t0)
        let a1 = raw([1: ProcBytes(name: "Edge", pid: 1, inB: 4000, outB: 300), 4: ProcBytes(name: "New", pid: 4, inB: 700, outB: 70), 5: ProcBytes(name: "Unknown", pid: 5, inB: 99, outB: 9), 3: ProcBytes(name: "Reused", pid: 3, inB: 10, outB: 10)], if: (13_500, 2_300), at: t1)
        let d = TrafficDiff.diff(prev: a0, cur: a1, startTime: { $0 == 4 ? t0.addingTimeInterval(5) : t0.addingTimeInterval(-100) }, name: { $1 })
        let by = Dictionary(uniqueKeysWithValues: d.procs.map { ($0.name, $0) })
        check(by["Edge"]?.inB == 3000 && by["Edge"]?.outB == 200, "同一进程两次读数相减得到真实字节")
        check(by["New"]?.inB == 700, "上次采样后才启动的进程，全部计数归入本段")
        check(by["Unknown"] == nil, "起点不明的新进程不猜，跳过")
        check(by["Reused"] == nil, "计数变小（pid 复用）跳过，不出负数")
        check(d.totalIn == 3500 && d.totalOut == 300 && abs(d.seconds - 60) < 0.001, "总量来自物理网卡计数差")
        let r0 = raw([:], if: (5_000, 5_000), at: t0), r1 = raw([:], if: (100, 100), at: t1)
        let dr = TrafficDiff.diff(prev: r0, cur: r1, startTime: { _ in nil }, name: { $1 })
        check(dr.totalIn == nil && dr.totalOut == nil, "网卡计数归零（重启/网卡重建）这一段记为未知，不补数")
        check(IfCounters.delta(UInt64(1) << 40, (UInt64(1) << 40) - 5) == 5, "64 位计数器差值")
        check(IfCounters.isPhysical("en0") && !IfCounters.isPhysical("utun6") && !IfCounters.isPhysical("bridge0") && !IfCounters.isPhysical("lo0"), "物理网卡口径只含 en*")
        let real = IfCounters.read()
        check(!real.isEmpty && real["lo0"] != nil, "真实读取接口 64 位计数器", "\(real.count) 个接口")

        sec("2.4 TUN 检测与去重")
        check(!TunDetect.active(addrs: [("en0", "192.168.0.2"), ("lo0", "127.0.0.1")], primary: "en0"), "系统自带 utun（只有 IPv6 链路地址）不算 TUN")
        check(TunDetect.active(addrs: [("en0", "192.168.0.2"), ("utun6", "26.26.26.1")], primary: "en0"), "utun 上有 IPv4（鹊桥 TUN 26.26.26.1）判为 TUN")
        check(TunDetect.active(addrs: [], primary: "utun4"), "默认路由走 utun 判为 TUN")
        check(!TunDetect.active(addrs: [("utun3", "169.254.1.2")], primary: "en0"), "链路本地 IPv4 不算")
        let ds = [ProcDelta(key: "Edge.1", name: "Edge", tunIn: 8_000_000, tunOut: 200_000),
                  ProcDelta(key: "Music.2", name: "Music", tunIn: 2_000_000, tunOut: 0),
                  ProcDelta(key: "LetsVPN.9", name: "LetsVPN", physIn: 10_400_000, physOut: 260_000),
                  ProcDelta(key: "mDNS.5", name: "mDNSResponder", physIn: 3_000, physOut: 1_000)]
        let dd = TrafficDedup.apps(ds, tun: true)
        check(dd.forwarder?.name == "LetsVPN", "TUN 时识别 VPN 转发进程")
        check(dd.apps.reduce(0) { $0 + $1.inB } == 10_003_000 && !dd.apps.contains { $0.name == "LetsVPN" }, "转发进程不计入应用合计，同一份流量不算两遍")
        let nd = TrafficDedup.apps(ds, tun: false)
        check(nd.forwarder == nil && nd.apps.count == 4, "没开 TUN 时不剔除任何进程")
        let unnamed = [ProcDelta(key: "A.1", name: "A", tunIn: 1000), ProcDelta(key: "X.7", name: "SomeTunnel", physIn: 1100)]
        check(TrafficDedup.forwarder(unnamed, tun: true) == "X.7", "不认识名字的转发进程按字节特征识别")
        let smallVPN = [ProcDelta(key: "A.1", name: "nsurlsessiond", tunIn: 30_000, tunOut: 228_000), ProcDelta(key: "L.9", name: "LetsVPN", physIn: 31_000, physOut: 55_000)]
        check(TrafficDedup.forwarder(smallVPN, tun: true) == "L.9", "已知 VPN 客户端（鹊桥 LetsVPN）在 TUN 下直接按转发处理")
        check(TrafficDedup.forwarder(smallVPN, tun: false) == nil, "没开 TUN 时 VPN 客户端按普通应用计")
        let merge = TrafficDedup.apps([ProcDelta(key: "a.1", name: "Edge", physIn: 10), ProcDelta(key: "b.2", name: "Edge", physIn: 5)], tun: false)
        check(merge.apps.count == 1 && merge.apps[0].inB == 15, "同一应用的多个进程（Helper）合并")

        sec("2.4 流量历史")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mo-v24-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = TrafficHistory(dir: dir)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        h.add(totalIn: 6000, totalOut: 600, apps: [AppBytes(name: "Edge", inB: 5000, outB: 500)], tun: false, at: now.addingTimeInterval(-120))
        h.add(totalIn: 1200, totalOut: 120, apps: [AppBytes(name: "Edge", inB: 1000, outB: 100), AppBytes(name: "微信", inB: 100, outB: 10)], tun: true, at: now)
        h.add(totalIn: 1200, totalOut: 120, apps: [AppBytes(name: "Edge", inB: 1000, outB: 100)], tun: false, at: now)
        let s1 = h.series(.hour1, now: now)
        check(s1.count == 60 && s1.last?.down == 40 && s1[57].down == 100 && s1[58].down == nil, "1 小时：每分钟平均速率，没有记录的分钟为空档", "\(s1.last?.down ?? -1)")
        check(h.totals(.hour1, now: now).inB == 8400 && h.totals(.hour1, now: now).coveredMinutes == 2, "1 小时合计与有记录时长")
        check(h.totals(.minute1, now: now).inB == 2400, "1 分钟合计")
        check(h.apps(.hour1, now: now).first?.name == "Edge" && h.apps(.hour1, now: now).first?.inB == 7000, "按应用历史合计")
        check(h.apps(.day30, now: now).first?.inB == 7000 && h.series(.day30, now: now).count == 720, "30 天按小时汇总")
        check(h.series(.day1, now: now).count == 144 && h.series(.day7, now: now).count == 168, "24 小时 10 分钟一点，7 天每小时一点")
        check(h.minutes.last?.tun == true, "记录这一分钟是否开着 TUN")
        h.save()
        let h2 = TrafficHistory(dir: dir)
        check(h2.minutes == h.minutes && h2.hours == h.hours && h2.minuteApps == h.minuteApps, "写盘后重新读取一致（重启后记录还在）")
        let blocked = dir.appendingPathComponent("blocked")
        FileManager.default.createFile(atPath: blocked.path, contents: Data())
        h.dir = blocked.appendingPathComponent("history")
        h.dirty = true; h.save()
        check(h.dirty && !h.saveError.isEmpty, "流量历史写盘失败保留待保存状态并显示原因")
        h.dir = dir; h.save()
        check(!h.dirty && h.saveError.isEmpty, "流量历史重试保存后清除错误")
        h2.add(totalIn: 1, totalOut: 1, apps: [], tun: false, at: now.addingTimeInterval(31 * 86400))
        check(h2.hours.count == 1 && h2.minutes.count == 1 && h2.minuteApps.count == 1, "30 天外小时记录、24 小时外分钟记录自动删除")
        var many: [String: [UInt64]] = [:]; for i in 0..<40 { many["app\(i)"] = [UInt64(i), 0] }
        let trimmed = TrafficHistory.trim(many, max: 30)
        check(trimmed.count == 31 && trimmed["其他"]?[0] == (0..<10).reduce(0) { $0 + UInt64($1) }, "小应用合并为「其他」，字节不丢")
        let big = TrafficHistory(dir: dir.appendingPathComponent("big"))
        for m in 0..<1440 { big.add(totalIn: 1_000_000, totalOut: 100_000, apps: (0..<12).map { AppBytes(name: "app\($0)", inB: 1000, outB: 100) }, tun: false, at: now.addingTimeInterval(Double(m - 1439) * 60)) }
        for hr in 1...720 { big.add(totalIn: 1, totalOut: 1, apps: (0..<30).map { AppBytes(name: "app\($0)", inB: 1, outB: 1) }, tun: false, at: now.addingTimeInterval(Double(-hr) * 3600 - 86400)) }
        big.save()
        let sz = ((try? FileManager.default.attributesOfItem(atPath: big.recentURL.path)[.size] as? Int) ?? 0) + ((try? FileManager.default.attributesOfItem(atPath: big.hoursURL.path)[.size] as? Int) ?? 0)
        check(sz > 0 && sz < 1_500_000, "满 30 天的最大记录文件大小", "\(sz / 1024) KB")

        sec("2.4 采样器")
        let at = AppTraffic()
        var reads = [a0, a1]
        at.reader = { reads.removeFirst() }
        let oldH = TrafficHistory.shared; TrafficHistory.shared = TrafficHistory(dir: dir.appendingPathComponent("sampler"))
        defer { TrafficHistory.shared = oldH }
        at.tick(); check(at.sampleCount == 0, "第一次只建立基线")
        at.tick(); settle(0.2)
        check(at.sampleCount == 1 && TrafficHistory.shared.totals(.day1, now: t1).inB == 3500, "第二次得到增量并记入历史")
        let tStart = Date(); for _ in 0..<5 { _ = AppTraffic.systemRead() }
        let per = Date().timeIntervalSince(tStart) / 5
        check(per < 1.0, "真实采样一次耗时", String(format: "%.0f ms", per * 1000))

        sec("2.4 测速结果解析")
        let ok = """
        {"dl_throughput": 356000000, "ul_throughput": 141000000, "base_rtt": 16.2, "il_h2_req_resp": [15, 18, 16, 20],
         "lud_foreign_dl_h2_req_resp": [40, 60, 50], "ul_responsiveness": 1000, "test_endpoint": "hkhkg1-edge.aaplimg.com", "interface_name": "en0"}
        """
        let r = NQParse.parse(Data(ok.utf8))
        check(r.downMbps == 356 && r.upMbps == 141 && r.idleMs == 16.2, "下载/上传/空闲延迟按测速工具原值换算")
        check(r.downMs == 50 && r.upMs == 60, "下载时延迟用实测样本中位数，上传时用 RPM 换算")
        check(abs((r.jitterMs ?? 0) - 3) < 0.001 && r.jitterSamples == 4 && r.error == nil, "抖动 = 相邻空闲延迟差值平均")
        let bad = NQParse.parse(Data(#"{"base_rtt": 461.8, "error_code": 1003, "il_h2_req_resp": [328.6]}"#.utf8))
        check(bad.downMbps == nil && bad.error?.contains("1003") == true && bad.jitterMs == nil, "测速失败时不给速度，抖动样本不足为未知")
        check(NQParse.parse(Data("garbage".utf8)).error != nil, "输出不可读时明确报错")
        let tierText = NQParse.tier(down: 356, up: 141)
        check(tierText.hasPrefix("300 Mbps–1 Gbps") && tierText.contains("上传 141 Mbps") && !tierText.contains("超过") && !tierText.contains("%"), "带宽档位按实测值描述用途，不排名", tierText)
        check(NQParse.tier(down: nil, up: nil) == "没有测出下载速度", "没有速度不编档位")
        check(FileManager.default.isExecutableFile(atPath: "/usr/bin/networkQuality"), "系统自带测速工具存在")

        sec("2.4 网络卡片")
        check(ReachClassify.classify(status: 403, error: nil, ms: 120) == .ok(code: 403, ms: 120), "ChatGPT 返回 403（人机验证）也说明能连上")
        check(ReachClassify.classify(status: nil, error: URLError(.timedOut), ms: 8000) == .fail("超时"), "超时算连不上并写原因")
        check(ReachClassify.classify(status: nil, error: URLError(.secureConnectionFailed), ms: 900).text.contains("TLS"), "TLS 失败写原因")
        check(ReachClassify.validIP("54.200.56.225") && ReachClassify.validIP("2001:db8::1") && !ReachClassify.validIP("<html>"), "公网 IP 只接受合法地址，网页错误不当成 IP")
        check(WiFiRead.signalText(nil) == "未知" && WiFiRead.signalText(-50).contains("很好") && WiFiRead.signalText(-80).contains("较弱"), "信号读不到写未知")
        let w = WiFiRead.system()
        info("Wi-Fi：" + (w.connected ? "已连接 \(w.rssi ?? 0) dBm · \(w.txRate ?? 0) Mbps" : "未连接"))
        check(!w.connected || w.rssi != nil, "真实读取 Wi-Fi 信号（CoreWLAN）")

        sec("2.4 卸载应用（临时目录）")
        let home = dir.appendingPathComponent("home").path, apps = dir.appendingPathComponent("Applications").path, trash = dir.appendingPathComponent("Trash").path
        let fm = FileManager.default
        let bid = "com.example.demoapp"
        let paths = [apps + "/DemoApp.app/Contents/Info.plist", home + "/Library/Application Support/\(bid)/data.db", home + "/Library/Caches/\(bid)/c.bin",
                     home + "/Library/Preferences/\(bid).plist", home + "/Library/Preferences/ByHost/\(bid).ABCD.plist", home + "/Library/Containers/\(bid)/x",
                     home + "/Library/Application Support/DemoApp/y", home + "/Library/Caches/com.example.demoapp2/z", home + "/Library/Group Containers/group.\(bid)/g"]
        for f in paths { try? fm.createDirectory(atPath: (f as NSString).deletingLastPathComponent, withIntermediateDirectories: true); fm.createFile(atPath: f, contents: Data(repeating: 1, count: 1000)) }
        try? fm.createDirectory(atPath: trash, withIntermediateDirectories: true)
        check(UninstallLogic.blockReason(bundleID: "com.apple.Safari", path: "/Applications/Safari.app", whitelist: []) != nil, "系统应用不能卸载")
        check(UninstallLogic.blockReason(bundleID: "com.yost.macoptimizer", path: "/Applications/Mac一键优化.app", whitelist: []) != nil, "不能卸载本应用")
        check(UninstallLogic.blockReason(bundleID: bid, path: apps + "/DemoApp.app", whitelist: [apps + "/DemoApp.app"]) != nil, "白名单里的应用不能卸载")
        check(UninstallLogic.blockReason(bundleID: "", path: apps + "/DemoApp.app", whitelist: []) != nil, "读不到 Bundle ID 不处理")
        let items = UninstallLogic.scan(appPath: apps + "/DemoApp.app", bundleID: bid, name: "DemoApp", home: home, whitelist: [home + "/Library/Containers/\(bid)"])
        let ip = Set(items.map(\.path))
        check(items.first?.kind == "应用本体" && items.count == 6, "列出应用本体与 5 处残留", "\(items.count)")
        check(!ip.contains { $0.contains("demoapp2") } && !ip.contains { $0.contains("Group Containers") }, "相似 Bundle ID、共享 Group Containers 不误列")
        check(!ip.contains(home + "/Library/Containers/\(bid)"), "白名单路径不列入")
        check(items.allSatisfy { $0.size > 0 }, "预览显示每项大小")
        let u = Uninstaller(); u.home = home; u.whitelist = { [] }; u.logURL = dir.appendingPathComponent("ulog.json"); u.records = []   // 用干净的临时日志，不受本机真实卸载记录影响
        u.moveToTrash = { url in let dst = URL(fileURLWithPath: trash).appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent); try fm.moveItem(at: url, to: dst); return dst }
        var running = true; u.isRunning = { _ in running }
        u.appPath = apps + "/DemoApp.app"; u.appName = "DemoApp"; u.bundleID = bid; u.items = items
        u.trashSelected(); settle(0.2)
        check(fm.fileExists(atPath: apps + "/DemoApp.app") && u.note.contains("先自己退出"), "应用在运行时不处理，也不强制退出")
        running = false
        u.items[2].selected = false
        var done = false; u.trashSelected { done = true }
        check(waitUntil(3) { done }, "移到废纸篓完成")
        check(!fm.fileExists(atPath: apps + "/DemoApp.app") && fm.fileExists(atPath: items[2].path), "勾选项移走，未勾选项保留")
        check(u.records.count == 1 && u.records[0].entries.count == 5 && u.records[0].entries.allSatisfy { $0.trashed != nil }, "操作记录写下原位置和废纸篓位置")
        let validLog = u.logURL
        u.logURL = blocked.appendingPathComponent("uninstall-log.json"); u.saveLog(force: true)
        check(!u.saveError.isEmpty, "卸载记录写盘失败显示原因")
        u.logURL = validLog; u.saveLog(force: true)
        let restoredLog = (try? Data(contentsOf: validLog)).flatMap { try? JSONDecoder().decode([UninstallRecord].self, from: $0) }
        check(u.saveError.isEmpty && restoredLog?.count == 1, "卸载记录重试成功且重读一致")
        check(((try? fm.contentsOfDirectory(atPath: trash)) ?? []).count == 5, "全部进（模拟）废纸篓，没有直接删除")
        fm.createFile(atPath: items[3].path, contents: Data("new".utf8))
        let res = u.restore(u.records[0])
        check(res.ok == 4 && res.skipped == 1 && fm.fileExists(atPath: apps + "/DemoApp.app/Contents/Info.plist"), "一键恢复放回原位，原位置已有同名文件不覆盖")
        check((try? String(contentsOfFile: items[3].path, encoding: .utf8)) == "new", "已有文件保持不变")

        sec("2.4 息屏不断网自动核对（不触发熄屏/睡眠）")
        let before = ProcessRunner.run("/usr/bin/pmset", ["-g", "custom"]).out
        let suite = "mo-v24-dock-" + UUID().uuidString
        let dock = DockMode(defaults: UserDefaults(suiteName: suite)!); dock.observe = false
        dock.readPower = { true }; dock.readExternal = { true }
        dock.setEnabled(true)
        check(dock.active && DockMode.systemSeesAssertion(), "开启后系统里有「阻止空闲睡眠」断言")
        let pa = ProcessRunner.run("/usr/bin/pmset", ["-g", "assertions"]).out
        check(pa.components(separatedBy: "\n").contains { $0.contains("pid \(getpid())(") && $0.contains("PreventUserIdleSystemSleep") }, "pmset -g assertions 能看到本进程的阻止空闲睡眠断言")
        dock.screens(asleep: true); dock.readExternal = { false }; dock.evaluate()
        check(dock.active, "熄屏期间外接屏“断开”不撤销断言")
        dock.screens(asleep: false); dock.evaluate()
        check(!dock.active && !DockMode.systemSeesAssertion(), "亮屏后确认已拔显示器才撤销")
        dock.readExternal = { true }; dock.evaluate(); check(dock.active, "重新接上恢复")
        dock.readPower = { false }; dock.evaluate(); check(!dock.active, "拔电后撤销，不在电池下阻止睡眠")
        dock.readPower = { true }; dock.evaluate(); dock.setEnabled(false)
        check(!dock.active && !DockMode.systemSeesAssertion() && !ProcessRunner.run("/usr/bin/pmset", ["-g", "assertions"]).out.components(separatedBy: "\n").contains { $0.contains("pid \(getpid())(") && $0.contains("PreventUserIdleSystemSleep") }, "关闭后断言完全释放")
        check(ProcessRunner.run("/usr/bin/pmset", ["-g", "custom"]).out == before, "全程没有改动 pmset 睡眠设置（只用断言，关掉即恢复）")
        UserDefaults().removePersistentDomain(forName: suite)
    }

    static func v24Fixtures() {
        let liveApps: [AppBytes] = [AppBytes(name: "Microsoft Edge", inB: 2_400_000, outB: 52_000), AppBytes(name: "微信", inB: 310_000, outB: 41_000),
                                    AppBytes(name: "NeteaseMusic", inB: 180_000, outB: 2_000), AppBytes(name: "Claude", inB: 22_000, outB: 9_000)]
        var liveSeries: [(Double, Double)] = []
        for i in 0..<30 { let dn: Double = 1_000_000 + Double(i % 7) * 300_000; let upv: Double = 50_000 + Double(i % 5) * 20_000; liveSeries.append((dn, upv)) }
        AppTraffic.shared.injectLive(liveApps, forwarder: AppBytes(name: "LetsVPN", inB: 2_950_000, outB: 120_000), total: (3_000_000, 110_000), tun: true, series: liveSeries)
        let now = Date()
        let m: Int64 = Int64(now.timeIntervalSince1970 / 60)
        var mins: [TMinute] = [], ma: [TMinuteApps] = [], hrs: [THour] = []
        for i in 0..<60 {
            let t: Int64 = m - Int64(59 - i)
            if i % 17 != 5 { let iv: UInt64 = 60_000_000 + UInt64(i % 9) * 9_000_000; let ov: UInt64 = 4_000_000 + UInt64(i % 4) * 1_000_000; mins.append(TMinute(t: t, i: iv, o: ov, tun: true)) }
            let apps: [String: [UInt64]] = ["Microsoft Edge": [40_000_000, 1_000_000], "微信": [6_000_000, 900_000], "NeteaseMusic": [3_000_000, 10_000]]
            ma.append(TMinuteApps(t: t, apps: apps))
        }
        for i in 0..<720 where i % 30 != 3 {
            let t: Int64 = m / 60 - Int64(719 - i)
            let iv: UInt64 = 2_000_000_000 + UInt64(i % 24) * 100_000_000
            let apps: [String: [UInt64]] = ["Microsoft Edge": [1_500_000_000, 50_000_000], "微信": [300_000_000, 60_000_000]]
            hrs.append(THour(t: t, i: iv, o: 200_000_000, apps: apps))
        }
        TrafficHistory.shared.inject(minutes: mins, minuteApps: ma, hours: hrs)
        SpeedTest24.shared.inject(NQResult(downMbps: 356.2, upMbps: 141.3, idleMs: 16, downMs: 48, upMs: 61, jitterMs: 2.4, jitterSamples: 6, endpoint: "hkhkg1-edge-fx-022.aaplimg.com", iface: "en0"),
                                  down: (0..<30).map { (i: Int) -> Double in 300 + Double((i * 37) % 90) }, up: (0..<30).map { (i: Int) -> Double in 110 + Double((i * 23) % 50) }, phase: .done)
        NetCard.shared.wifi = WiFiState(connected: true, ssid: nil, rssi: -52, noise: -92, txRate: 864, channel: 149, band: "5 GHz", iface: "en0")
        NetCard.shared.publicIP = "54.200.56.225"; NetCard.shared.chatGPT = .ok(code: 403, ms: 230); NetCard.shared.updated = Date()
        let u = Uninstaller.shared
        u.appName = "DemoApp"; u.bundleID = "com.example.demoapp"; u.appPath = "/Applications/DemoApp.app"; u.note = "找到 4 处残留，确认后连同应用一起移到废纸篓"
        u.items = [UninstallItem(path: "/Applications/DemoApp.app", kind: "应用本体", size: 182_000_000), UninstallItem(path: NSHomeDirectory() + "/Library/Application Support/com.example.demoapp", kind: "应用数据", size: 24_000_000),
                   UninstallItem(path: NSHomeDirectory() + "/Library/Caches/com.example.demoapp", kind: "缓存", size: 96_000_000), UninstallItem(path: NSHomeDirectory() + "/Library/Preferences/com.example.demoapp.plist", kind: "偏好设置", size: 4_000),
                   UninstallItem(path: NSHomeDirectory() + "/Library/Saved Application State/com.example.demoapp.savedState", kind: "窗口状态", size: 12_000)]
        u.records = [UninstallRecord(date: Date().addingTimeInterval(-3600), app: "OldTool", bundleID: "com.example.old", entries: [UninstallEntry(original: "/Applications/OldTool.app", trashed: nil)])]
    }

    static func v24UI(_ w: NSWindow) {
        sec("2.4 网络三标签与新页面")
        v24Fixtures()
        Nav.shared.sel = .network; settle(0.5)
        if let b = find(w.contentView!, id: "net.tab.1") { b.press(); check(waitUntil(2) { Nav.shared.netTab == 1 }, "切到测速标签") } else { check(false, "找到测速标签") }
        check(find(w.contentView!, id: "speed.down") != nil && find(w.contentView!, id: "speed.up") != nil && find(w.contentView!, id: "speed.run") != nil, "测速页有下载/上传大数字与重新测速")
        check(SpeedTest24.shared.phase != .running, "测试中不自动发起真实测速")
        fits(w.contentView!, "测速页默认窗口")
        if let b = find(w.contentView!, id: "net.tab.2") { b.press(); check(waitUntil(2) { Nav.shared.netTab == 2 }, "切到流量标签") } else { check(false, "找到流量标签") }
        check(find(w.contentView!, id: "traffic.range") != nil && find(w.contentView!, id: "traffic.chart") != nil && find(w.contentView!, id: "netcard.chatgpt") != nil, "流量页有范围选择、趋势图、网络卡片")
        check(find(w.contentView!, id: "apptraffic.row") != nil, "流量页列出按应用速率")
        fits(w.contentView!, "流量页默认窗口")
        let old = w.frame
        w.setContentSize(Layout.minSize); settle(0.6)
        fits(w.contentView!, "流量页最小窗口")
        if let b = find(w.contentView!, id: "net.tab.1") { b.press(); settle(0.4) }
        fits(w.contentView!, "测速页最小窗口")
        w.setFrame(old, display: true); settle(0.3)
        if let b = find(w.contentView!, id: "net.tab.0") { b.press(); _ = waitUntil(2) { Nav.shared.netTab == 0 } }

        sec("2.4 清理页卸载标签")
        Nav.shared.sel = .clean; settle(0.5)
        if let b = find(w.contentView!, id: "clean.tab.1") { b.press(); check(find(w.contentView!, id: "uninstall.choose") != nil && find(w.contentView!, id: "uninstall.trash") != nil, "卸载标签有选择应用与移到废纸篓") } else { check(false, "找到卸载应用标签") }
        check(find(w.contentView!, id: "uninstall.restore") != nil, "卸载记录有恢复按钮")
        fits(w.contentView!, "卸载页默认窗口")
        if let b = find(w.contentView!, id: "clean.tab.0") { b.press(); check(find(w.contentView!, id: "clean.scan") != nil, "切回清理标签") }

        sec("2.4 菜单栏网速与按应用面板")
        let oldMode = BatteryAlerts.shared.settings.menuIndicator
        BatteryAlerts.shared.settings.menuIndicator = "net"; settle(0.3); StatusBar.shared.render()
        let title = StatusBar.shared.item?.button?.title ?? ""
        check(title.contains("↓") && title.contains("↑"), "菜单栏显示上下行网速", title)
        BatteryAlerts.shared.settings.menuIndicator = oldMode
        check(StatusBar.short(2_500_000) == "2.4M" && StatusBar.short(30_000) == "29K", "菜单栏网速短格式")
        let host = NSHostingView(rootView: AppTrafficPopover())
        let pw = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 360, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        pw.contentView = host; pw.orderFrontRegardless(); settle(0.5)
        check(find(host, id: "apptraffic.history") != nil && find(host, id: "apptraffic.row") != nil, "按应用面板列出应用并可跳到历史")
        pw.orderOut(nil); settle(0.2)
        if let b = find(host, id: "apptraffic.history") { _ = b }
        NetPageLink.openTraffic(); check(Nav.shared.sel == .network && Nav.shared.netTab == 2, "从面板跳到流量历史")
        Nav.shared.netTab = 0
    }

    static func v24Snapshots(_ out: String) {
        v24Fixtures()
        for (name, ap) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: ap)
            let views: [(AnyView, String, CGFloat)] = [
                (AnyView(SpeedTab24().padding(28)), "speed24", Layout.minSize.width - 212),
                (AnyView(TrafficTab24().padding(28)), "traffic24", Layout.minSize.width - 212),
                (AnyView(UninstallTab().padding(28)), "uninstall24", Layout.minSize.width - 212),
                (AnyView(AppTrafficPopover()), "apptraffic24", 360),
                (AnyView(MetricTiles(m: Monitor.shared).padding(12)), "tiles24", Layout.minSize.width - 208)
            ]
            for (view, tag, width) in views {
                let host = NSHostingView(rootView: view.frame(width: width).background(pageBG))
                let size = host.fittingSize; host.frame = NSRect(origin: .zero, size: size)
                let win = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: size.width, height: size.height), styleMask: [.titled], backing: .buffered, defer: false)
                win.appearance = NSAppearance(named: ap); win.contentView = host; win.orderFrontRegardless(); settle(0.6)
                contrast(host, pngRep(host, out + "/" + tag + "-" + name + ".png"), tag + " " + name)
                fits(host, tag + " " + name)
                if tag != "apptraffic24" && tag != "tiles24" { check(size.height <= Layout.minSize.height - 100, "最小窗口高度放得下 \(tag) \(name)", "\(Int(size.height)) pt") }
                win.orderOut(nil)
            }
        }
        NSApp.appearance = NSAppearance(named: .aqua)
    }
}
