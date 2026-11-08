// 2.9.2 测试：充电助手版本核对、升级后自动切换、设置保留
import SwiftUI
import AppKit
import ServiceManagement

/// 模拟一次升级：旧助手在安装前启动；重新注册后（可选）需要授权，或启动新进程
final class MockHelperWorld: HelperProbe, HelperControl {
    var installed: Date? = Date(timeIntervalSince1970: 1_000)
    var procs: [HelperProcess] = []
    var status: SMAppService.Status = .enabled
    var answers = true
    var needsApprovalOnRegister = false
    var startsOnRegister = true
    var selfRestartAfterWaits: Int? = nil   // 原地升级：旧助手自己退出、几次等待后新进程出现
    var registers = 0, unregisters = 0, waits = 0
    func runningHelpers() -> [HelperProcess] { procs }
    func bundledInstalled() -> Date? { installed }
    func register() throws {
        registers += 1
        if needsApprovalOnRegister { status = .requiresApproval; procs = []; return }
        status = .enabled
        if startsOnRegister { procs = [HelperProcess(pid: 200 + Int32(registers), started: Date(timeIntervalSince1970: 2_000))] }
    }
    func unregister() throws { unregisters += 1; status = .notRegistered; procs = [] }
    func ping() -> Bool { answers && !procs.isEmpty }
    func wait(_ s: TimeInterval) {
        waits += 1
        if let n = selfRestartAfterWaits, waits >= n { procs = [HelperProcess(pid: 300, started: Date(timeIntervalSince1970: 2_500))]; selfRestartAfterWaits = nil }
    }
}

enum V292 {
    typealias T = MOTests

    static func tests() {
        T.sec("2.9.2 助手版本核对")
        let inst = Date(timeIntervalSince1970: 1_000)
        T.check(HelperCheck.judge([], installed: inst) == .notRunning, "没有助手进程")
        T.check(HelperCheck.judge([HelperProcess(pid: 1, started: inst.addingTimeInterval(-600))], installed: inst) == .stale, "安装前就在运行的助手判为旧版")
        T.check(HelperCheck.judge([HelperProcess(pid: 1, started: inst.addingTimeInterval(30))], installed: inst) == .current, "安装后启动的助手判为新版")
        T.check(HelperCheck.judge([HelperProcess(pid: 1, started: inst.addingTimeInterval(-1))], installed: inst) == .current, "2 秒内的时间误差不算旧版")
        T.check(HelperCheck.judge([HelperProcess(pid: 1, started: inst)], installed: nil) == .unknown("读不到包内助手的安装时间"), "读不到安装时间时不做判断")

        T.sec("2.9.2 升级后自动切换")
        func world(_ f: (MockHelperWorld) -> Void) -> MockHelperWorld { let w = MockHelperWorld(); f(w); return w }
        // 1. 本来就是新版：什么都不做
        var w = world { $0.procs = [HelperProcess(pid: 9, started: Date(timeIntervalSince1970: 1_500))] }
        T.check(HelperCheck.run(probe: w, control: w, wait: w.wait) == .ok && w.registers == 0 && w.unregisters == 0, "新版正在运行：不重新注册")
        // 2. 拖拽替换升级：旧助手一直在运行 → 重新注册 → 新进程起来
        w = world { $0.procs = [HelperProcess(pid: 9, started: Date(timeIntervalSince1970: 500))] }
        T.check(HelperCheck.run(probe: w, control: w, wait: w.wait) == .repaired && w.unregisters == 1 && w.registers == 1, "旧助手仍在运行：注销再注册，切到新版", "注销 \(w.unregisters) 注册 \(w.registers)")
        T.check(w.waits >= Int(HelperCheck.graceSeconds / 1.5), "先等旧助手自己退出，再动手")
        // 3. 原地升级：旧助手几秒后自己退出、launchd 拉起新版 → 不需要重新注册
        w = world { $0.procs = [HelperProcess(pid: 9, started: Date(timeIntervalSince1970: 500))]; $0.selfRestartAfterWaits = 3 }
        T.check(HelperCheck.run(probe: w, control: w, wait: w.wait) == .ok && w.registers == 0, "原地升级：等旧助手自己重启，不重复注册")
        // 4. 助手代码有变化：重新注册后需要授权
        w = world { $0.procs = [HelperProcess(pid: 9, started: Date(timeIntervalSince1970: 500))]; $0.needsApprovalOnRegister = true }
        T.check(HelperCheck.run(probe: w, control: w, wait: w.wait) == .needsApproval && w.registers == 1, "新助手需要授权：停下并提示，不反复注册")
        // 5. 替换 App 后助手没在运行（launchd 找不到旧路径）
        w = world { $0.procs = [] }
        T.check(HelperCheck.run(probe: w, control: w, wait: w.wait) == .repaired, "助手没在运行：重新注册后恢复")
        // 6. 怎么都起不来：给出失败原因，最多尝试两轮
        w = world { $0.procs = [HelperProcess(pid: 9, started: Date(timeIntervalSince1970: 500))]; $0.startsOnRegister = false }
        let r6 = HelperCheck.run(probe: w, control: w, wait: w.wait)
        T.check(r6 == .failed("旧版充电助手仍在运行，切换没有成功") && w.registers == 2, "切换失败：最多两轮，给出原因", "\(r6)")
        // 7. 未安装 / 等待授权：不动
        w = world { $0.status = .notRegistered }
        T.check(HelperCheck.run(probe: w, control: w, wait: w.wait) == .skipped("充电助手未安装") && w.registers == 0, "未安装助手：不做任何操作")
        w = world { $0.status = .requiresApproval }
        T.check(HelperCheck.run(probe: w, control: w, wait: w.wait) == .needsApproval && w.registers == 0, "已在等待授权：只提示")
        // 8. 新版在运行但不响应
        w = world { $0.procs = [HelperProcess(pid: 9, started: Date(timeIntervalSince1970: 1_500))]; $0.answers = false }
        T.check(HelperCheck.run(probe: w, control: w, wait: w.wait) == .failed("充电助手在运行但没有响应") && w.registers == 0, "新版不响应：报告失败，不盲目重装")

        T.sec("2.9.2 设置保留")
        var custom = ChargeSettings(); custom.enabled = true; custom.limit = 75; custom.sail = 3
        T.check(ChargeSettingsBackup.restoreNeeded(current: ChargeSettings(), backup: custom) == custom, "新助手读到默认设置时，按备份补写")
        T.check(ChargeSettingsBackup.restoreNeeded(current: custom, backup: custom) == nil, "设置一致时不补写")
        var other = custom; other.limit = 90
        T.check(ChargeSettingsBackup.restoreNeeded(current: other, backup: custom) == nil, "用户改过的非默认设置不被备份覆盖")
        T.check(ChargeSettingsBackup.restoreNeeded(current: ChargeSettings(), backup: ChargeSettings()) == nil && ChargeSettingsBackup.restoreNeeded(current: ChargeSettings(), backup: nil) == nil, "没有备份或备份就是默认时不补写")
        var dock = ChargeSettings(); dock.dockProtected = true
        T.check(ChargeSettingsBackup.restoreNeeded(current: dock, backup: custom) == custom, "扩展坞保护标记不影响判断，也不从备份恢复")
        let d = UserDefaults(suiteName: "mo-v292")!; d.removePersistentDomain(forName: "mo-v292")
        ChargeSettingsBackup.save(custom, defaults: d)
        T.check(ChargeSettingsBackup.load(defaults: d) == custom, "备份可保存读取")
        ChargeSettingsBackup.clear(defaults: d)
        T.check(ChargeSettingsBackup.load(defaults: d) == nil, "主动卸载时清除备份")
        d.removePersistentDomain(forName: "mo-v292")

        T.sec("2.9.2 本机读数（只读）")
        let probe = SystemHelperProbe()
        let procs = probe.runningHelpers()
        T.check(procs.allSatisfy { $0.started < Date() && $0.pid > 0 }, "能列出充电助手进程（不需要管理员权限）", procs.isEmpty ? "本机没有运行助手" : "\(procs.count) 个，启动于 \(Fmt.clock(procs[0].started))")
        let own = SystemHelperProbe(bundledPath: Bundle.main.executablePath ?? "")
        T.check(own.bundledInstalled().map { $0 <= Date().addingTimeInterval(1) } == true, "能读到包内文件的安装时间（ctime）")
        T.check(SystemHelperProbe(bundledPath: "/不存在/MacOptimizerChargeHelper").bundledInstalled() == nil, "文件不存在时返回空")
    }

    static func ui(_ w: NSWindow) {
        T.sec("2.9.2 充电卡升级提示")
        let real = ChargeClient.shared
        let c = ChargeClient(caps: ChargeCaps(inhibit: .chte, adapter: true, led: true)); c.offline = true; c.phase = .ready
        ChargeClient.shared = c
        defer { ChargeClient.shared = real; Nav.shared.sel = .monitor }
        Nav.shared.sel = .monitor; T.settle(0.4); Nav.shared.sel = .battery; T.settle(0.6)
        if let b = T.find(w.contentView!, id: "bat.tab.0") { b.press(); T.settle(0.6) }
        c.upgrade = .repaired; T.settle(0.5)
        T.check(T.find1(w.contentView!, id: "charge.upgrade") != nil, "切换成功后显示「已切换到新版」")
        c.upgrade = .failed("旧版充电助手仍在运行，切换没有成功"); T.settle(0.5)
        T.check(T.find1(w.contentView!, id: "charge.upgrade.action") != nil, "切换失败时给出重试和登录项设置")
        c.upgrade = .needsApproval; c.phase = .needsApproval; T.settle(0.5)
        T.check(T.find1(w.contentView!, id: "charge.upgrade.approval") != nil, "需要授权时说明这是升级后的新版、设置会保留")
    }
}
