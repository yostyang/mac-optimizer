import SwiftUI
import AppKit
import UserNotifications

/// 可延迟回复的助手，验证 App 等待真实结果，而不修改系统 DNS。
final class PendingDNSHelper: NSObject, ChargeHelperProtocol {
    var current = DNSStatus(services: [DNSServiceState(service: "Wi-Fi", device: "en0", servers: DNSConst.ali)],
                            backup: [DNSServiceState(service: "Wi-Fi", device: "en0", servers: ["8.8.8.8"])])
    var reply: ((Bool, String) -> Void)?
    var holdStatus = false
    var statusReply: ((Data) -> Void)?
    func dnsStatus(_ reply: @escaping (Data) -> Void) {
        if holdStatus { statusReply = reply } else { reply((try? JSONEncoder().encode(current)) ?? Data()) }
    }
    func restoreDNS(_ reply: @escaping (Bool, String) -> Void) { self.reply = reply }
    func setAliDNS(_ reply: @escaping (Bool, String) -> Void) { self.reply = reply }
    func status(_ reply: @escaping (Data) -> Void) { reply(Data()) }
    func setLimit(_ limit: Int, enabled: Bool, reply: @escaping (Bool, String) -> Void) { reply(false, "未使用") }
    func setSailing(_ range: Int, reply: @escaping (Bool, String) -> Void) { reply(false, "未使用") }
    func setAutoDischarge(_ on: Bool, reply: @escaping (Bool, String) -> Void) { reply(false, "未使用") }
    func setTopUp(_ on: Bool, reply: @escaping (Bool, String) -> Void) { reply(false, "未使用") }
    func setLED(_ on: Bool, reply: @escaping (Bool, String) -> Void) { reply(false, "未使用") }
    func resetDefaults(_ reply: @escaping (Bool, String) -> Void) { reply(false, "未使用") }
}

extension MOTests {
    static func v22Tests() {
        sec("2.2 异常提醒：采样到事件、冷却、恢复")
        var engine = SystemAlertEngine(), sample = Snapshot()
        sample.cpu = 95; sample.diskTotalGB = 1000; sample.diskFreeGB = 500; sample.batteryHealth = 85
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var events: [SystemAlertEvent] = []
        for i in 0..<5 { events += engine.update(sample, enabled: true, threshold: 90, now: now.addingTimeInterval(Double(i * 5))) }
        check(events == [.cpu], "五次实际采样后只产生一次 CPU 事件")
        check(engine.update(sample, enabled: true, threshold: 90, now: now.addingTimeInterval(60)).isEmpty, "持续高占用时冷却，不反复提醒")
        check(engine.update(sample, enabled: true, threshold: 90, now: now.addingTimeInterval(3700)) == [.cpu], "冷却结束后仍持续异常可再次提醒")
        _ = engine.update(sample, enabled: false, threshold: 90, now: now.addingTimeInterval(8000))
        check(engine.cpuSamples.isEmpty, "关闭提醒清除旧 CPU 连续样本")
        sample.cpu = 5; sample.diskFreeGB = 90
        events = []
        for i in 0..<3 { events += engine.update(sample, enabled: true, threshold: 90, now: now.addingTimeInterval(Double(8100 + i))) }
        check(events == [.disk], "磁盘连续三次不足后提醒")
        sample.diskFreeGB = 101
        _ = engine.update(sample, enabled: true, threshold: 90, now: now.addingTimeInterval(8200))
        sample.diskFreeGB = 99
        check(engine.update(sample, enabled: true, threshold: 90, now: now.addingTimeInterval(12000)).isEmpty, "阈值附近波动不重新触发磁盘提醒")
        sample.diskFreeGB = 200
        _ = engine.update(sample, enabled: true, threshold: 90, now: now.addingTimeInterval(12100))
        sample.diskFreeGB = 80; events = []
        for i in 0..<3 { events += engine.update(sample, enabled: true, threshold: 90, now: now.addingTimeInterval(Double(12200 + i))) }
        check(events == [.disk], "空间恢复后再次不足可提醒")
        sample.diskFreeGB = 500; sample.batteryHealth = 79
        check(engine.update(sample, enabled: true, threshold: 90, now: now.addingTimeInterval(12300)) == [.battery], "健康度跨过阈值产生真实事件")
        sample.batteryHealth = nil
        check(engine.update(sample, enabled: true, threshold: 90, now: now.addingTimeInterval(12400)).isEmpty && engine.batteryHealth == 79, "读不到电池时保留已知值，不凭空报警")

        sec("2.2 DNS：延迟、失败、状态不符、超时和迟到回包")
        let log = ChangeLog(); log.records = []
        let helper = PendingDNSHelper(), dns = DNSClient(); dns.direct = helper; dns.status = nil
        func addRecord() -> ChangeRecord {
            log.add(kind: .dns, title: "测试 DNS 记录", detail: "模拟助手", reversible: true, restoreNote: "恢复")
            return log.records.last!
        }
        let record = addRecord(); var result: Bool?
        log.restore(record, dns: dns) { ok, _ in result = ok }
        check(dns.busy && result == nil && log.records.contains { $0.id == record.id }, "未访问网络页也会读取最新备份，操作待回包时保留原记录")
        helper.reply?(false, "模拟恢复失败")
        check(waitUntil(1) { result != nil } && result == false && !dns.busy && log.records.contains { $0.id == record.id }, "恢复失败保留记录，允许重试")
        result = nil
        log.restore(record, dns: dns) { ok, _ in result = ok }
        helper.reply?(true, "")
        check(waitUntil(1) { result != nil } && result == false && log.records.contains { $0.id == record.id }, "助手报告成功但 DNS 不匹配，不能提前删除记录")
        result = nil
        log.restore(record, dns: dns) { ok, _ in result = ok }
        helper.current.services[0].servers = ["8.8.8.8"]; helper.current.backup = nil
        helper.reply?(true, "")
        check(waitUntil(1) { result != nil } && result == true && !log.records.contains { $0.id == record.id }, "读取并核对原 DNS 后才完成并移除待恢复记录")
        helper.current = PendingDNSHelper().current; dns.status = helper.current; dns.requestTimeout = 0.05
        let timed = addRecord(); result = nil; var callbacks = 0
        log.restore(timed, dns: dns) { ok, _ in callbacks += 1; result = ok }
        let lateReply = helper.reply
        check(waitUntil(1) { result != nil } && result == false && !dns.busy, "助手无回包会超时，不永久卡住")
        let timeoutNote = dns.note
        helper.current.services[0].servers = ["8.8.8.8"]; helper.current.backup = nil
        lateReply?(true, ""); settle(0.1)
        check(callbacks == 1 && dns.note == timeoutNote && log.records.contains { $0.id == timed.id }, "迟到回包不覆盖超时结果或删除记录")
        let oldStatus = (try? JSONEncoder().encode(PendingDNSHelper().current)) ?? Data()
        helper.current = PendingDNSHelper().current; dns.status = helper.current; dns.requestTimeout = 1
        helper.holdStatus = true; dns.refresh(); let lateStatus = helper.statusReply
        helper.holdStatus = false; result = nil
        dns.restore { ok, _ in result = ok }
        helper.current.services[0].servers = ["8.8.8.8"]; helper.current.backup = nil
        helper.reply?(true, "")
        check(waitUntil(1) { result != nil } && result == true, "操作后的状态核对成功")
        lateStatus?(oldStatus); settle(0.1)
        check(dns.status?.services.first?.servers == ["8.8.8.8"] && dns.status?.backup == nil, "操作前的迟到刷新不能覆盖已核验的新状态")
        let disconnected = DNSClient(); disconnected.offline = true; var rejected: Bool?
        disconnected.setAli { ok, _ in rejected = ok }
        check(rejected == false && !disconnected.busy, "未连接助手立即给出可处理的结果")

        sec("2.2 清理：真实临时文件、部分失败、重试、执行前保护")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mo-v22-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = tmp.appendingPathComponent("a"), b = tmp.appendingPathComponent("b")
        try! Data([1]).write(to: a); try! Data([2]).write(to: b)
        let store = CleanStore(); store.items = [CleanItem(category: "缓存", path: a.path, size: 1, selected: true), CleanItem(category: "缓存", path: b.path, size: 1, selected: true)]
        store.records = []; store.whitelist = []
        var failB = true
        store.moveToTrash = { url in
            if url == b && failB { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "模拟权限错误"]) }
            let target = tmp.appendingPathComponent("moved-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target); return target
        }
        store.trashSelected()
        check(waitUntil(2) { !store.trashing } && store.items.map(\.path) == [b.path] && store.items[0].selected, "部分成功只移除成功项，失败项仍选中")
        check(store.failures[b.path] == "模拟权限错误" && store.note.contains("未完成") && FileManager.default.fileExists(atPath: b.path), "保留原错误和实际未移动文件")
        check(store.records.count == 1 && store.records[0].trashPath != nil, "只为成功项记录真实目标位置")
        failB = false; store.trashSelected()
        check(waitUntil(2) { !store.trashing } && store.items.isEmpty && store.records.count == 2 && store.failures.isEmpty, "重试只处理剩余项，不重复移动成功文件")
        store.items = [CleanItem(category: "缓存", path: tmp.appendingPathComponent("protected").path, size: 1, selected: true)]
        store.whitelist = [store.items[0].path]; var moved = false
        store.moveToTrash = { _ in moved = true; return nil }
        store.trashSelected()
        check(waitUntil(1) { !store.trashing } && !moved && store.items.count == 1, "扫描后添加白名单，执行前仍会拦住")
        check(CleanLogic.isProtected(NSHomeDirectory() + "/Pictures") && CleanLogic.isProtected(NSHomeDirectory() + "/Library/../Documents/private"), "保护目录本身和含父路径的写法")
        let old = "[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"date\":0,\"path\":\"/tmp/test\",\"size\":1,\"trashed\":true}]"
        check((try? JSONDecoder().decode([CleanRecord].self, from: Data(old.utf8)))?.first?.trashPath == nil, "旧版清理记录可读取")
        let blockedMeta = tmp.appendingPathComponent("blocked-meta")
        try! Data().write(to: blockedMeta)
        store.whitelistURL = blockedMeta.appendingPathComponent("whitelist.json")
        store.recordsURL = blockedMeta.appendingPathComponent("records.json")
        check(!store.saveMeta(force: true) && !store.saveError.isEmpty, "清理记录保存失败时显示错误")
        store.whitelistURL = tmp.appendingPathComponent("whitelist.json")
        store.recordsURL = tmp.appendingPathComponent("records.json")
        check(store.saveMeta(force: true) && store.saveError.isEmpty && FileManager.default.fileExists(atPath: store.recordsURL.path), "清理记录重试后写入并清除错误")

        sec("2.2 操作结果：请求、确认、未完成")
        var verified: Bool?
        OperationCheck.wait(timeout: 0.01, until: { false }) { verified = $0 }
        check(waitUntil(1) { verified != nil } && verified == false, "等待超时不能伪装为已完成")
        let previousConfirm = FixRunner.confirm, stats = CleanStats.shared
        let suiteName = "mo-v22-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!; CleanStats.shared = CleanStats(defaults: defaults)
        defer { FixRunner.confirm = previousConfirm; CleanStats.shared = stats; defaults.removePersistentDomain(forName: suiteName) }
        FixRunner.confirm = { _, _, _ in true }
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]; try! child.run()
        var done: Bool?
        let started = FixRunner.perform(.closeTab(pid: child.processIdentifier, owner: "测试进程", cpu: 90, memMB: 0)) { ok, _ in done = ok }
        check(started && waitUntil(3) { done != nil } && done == true && !child.isRunning, "处理入口等待自己启动的进程退出后才确认完成")
        if child.isRunning { child.terminate() }
        check(!FixRunner.run(.closeTab(pid: 0, owner: "invalid", cpu: 0, memMB: 0)), "无效进程号不会变成进程组信号")
        let model = Model(); model.verificationTimeout = 0.01
        var requested = 0
        model.issues = [Issue(title: "成功项", detail: "测试", action: { requested += 1 }, on: true, verify: { true }),
                        Issue(title: "未完成项", detail: "测试", action: { requested += 1 }, on: true, verify: { false })]
        model.fix()
        check(waitUntil(2) { model.log.count == 2 } && requested == 2 && model.log[0].hasPrefix("已确认完成") && model.log[1].hasPrefix("尚未确认完成"), "批量处理逐项核验，不用固定等待冒充全部成功")

        check(waitUntil(1) { CleanStats.shared.optimized == 2 }, "完成统计只包含已退出的子进程和成功项，不含未确认项")

        sec("2.2 供电状态")
        var flow = PowerFlow(); flow.percent = 80; flow.onAC = true
        check(flow.supplyText == "已接电源，未充电", "接电停充不显示电池供电")
        flow.percent = 100; check(flow.supplyText == "已充满，已接电源", "充满与普通停充区分")
        flow.dischargeWatts = 12; check(flow.supplyText == "已接电源，电池正在放电", "接电但主动放电独立显示")
        flow.onAC = false; check(flow.supplyText == "电池供电", "拔电源显示电池供电")
        flow.charging = true; check(flow.supplyText == "正在充电", "充电状态优先")
    }

    static func v22UI(_ w: NSWindow) {
        sec("2.2 真实采样入口和界面状态")
        let store = V19Store.shared, monitor = Monitor.shared
        let settings = store.settings, engine = store.engine, oldText = store.lastAlertText
        let sink = store.sink, enabled = monitor.alertsEnabled
        defer { store.settings = settings; store.engine = engine; store.sink = sink; store.lastAlertText = oldText; monitor.alertsEnabled = enabled }
        var events: [SystemAlertEvent] = []
        store.engine = SystemAlertEngine(); store.sink = { events.append($0) }; store.settings.alertsOn = true
        var s = Snapshot(); s.cpu = 99; s.diskTotalGB = 1000; s.diskFreeGB = 500
        for _ in 0..<5 { monitor.onSample?(s) }
        check(events == [.cpu], "App 实际 onSample 回调接通异常提醒服务")
        Nav.shared.sel = .changes; settle(0.4)
        if let toggle = find(w.contentView!, id: "v19.alertsOn") {
            toggle.press(); check(waitUntil(1) { !store.settings.alertsOn && !monitor.alertsEnabled }, "提醒开关实际关闭服务与后台采样需求")
            toggle.press(); check(waitUntil(1) { store.settings.alertsOn && monitor.alertsEnabled }, "提醒开关实际接通服务与后台采样需求")
        } else { check(false, "找到异常提醒开关") }
        monitor.alertsEnabled = true; UIState.shared.menuBar = false; w.orderOut(nil); monitor.reschedule()
        check(waitUntil(1) { monitor.interval == Monitor.lightInterval }, "关闭窗口与菜单栏后，已开启提醒仍保留低频监测")
        monitor.alertsEnabled = false
        check(waitUntil(1) { monitor.interval == 0 }, "提醒也关闭时停止后台采样")
        UIState.shared.menuBar = true; w.orderFrontRegardless(); Nav.shared.sel = .changes; settle(0.4)
        check(find(w.contentView!, id: "v22.notificationPermission") != nil && find(w.contentView!, id: "v19.autoTrash") == nil, "权限状态可见，未接通的自动整理开关已收起")
    }
}
