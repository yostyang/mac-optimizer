// v1.6 测试：体检结论、进程归属、处理按钮、菜单栏快捷操作、接显示器模式
import SwiftUI
import AppKit

final class MockAssertion: SleepAssertion {
    var created = 0, released = 0, next: UInt32 = 1
    var live: Bool { created > released }
    func create(_ name: String) -> UInt32? { created += 1; next += 1; return next }
    func release(_ id: UInt32) { released += 1 }
}

extension MOTests {
    static let edge = "/Applications/Microsoft Edge.app"
    static let edgeRenderer = edge + "/Contents/Frameworks/Microsoft Edge Framework.framework/Versions/142.0/Helpers/Microsoft Edge Helper (Renderer).app/Contents/MacOS/Microsoft Edge Helper (Renderer)"
    static let edgeGPU = edge + "/Contents/Frameworks/Microsoft Edge Framework.framework/Versions/142.0/Helpers/Microsoft Edge Helper (GPU).app/Contents/MacOS/Microsoft Edge Helper (GPU)"
    static let chrome = "/Applications/Google Chrome.app"
    static let chromeRenderer = chrome + "/Contents/Frameworks/Google Chrome Framework.framework/Versions/142.0/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
    static let ws = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"

    static func dockFixture(enabled: Bool, external: Bool = true, ac: Bool = true) -> (DockMode, MockAssertion) {
        let d = UserDefaults(suiteName: "mo-dock-test")!; d.removePersistentDomain(forName: "mo-dock-test")
        let m = DockMode(defaults: d); let a = MockAssertion(); m.assertion = a
        m.readExternal = { external }; m.readPower = { ac }
        m.observe = false
        if enabled { m.setEnabled(true) } else { m.evaluate() }
        return (m, a)
    }

    static func v16Tests() {
        sec("进程归属（v1.6）")
        let names = [edge: "Microsoft Edge", "/Applications/WeChat.app": "微信"]
        check(ProcDescribe.owner(path: edgeRenderer, appNames: names) == ProcOwner(name: "Edge", bundlePath: edge, kind: .tab), "Edge 渲染进程 = 标签页")
        check(ProcDescribe.owner(path: edgeGPU).kind == .gpu, "Edge GPU 进程")
        check(ProcDescribe.owner(path: chrome + "/Contents/MacOS/Google Chrome") == ProcOwner(name: "Chrome", bundlePath: chrome, kind: .app), "Chrome 主程序")
        check(ProcDescribe.owner(path: "/Applications/WeChat.app/Contents/MacOS/WeChat", appNames: names).name == "微信", "用 App 的中文名")
        check(ProcDescribe.owner(path: ws) == ProcOwner(name: "WindowServer", bundlePath: nil, kind: .system), "系统进程")
        check(ProcDescribe.owner(path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent").kind == .tab, "Safari 网页进程 = 标签页")

        sec("体检结论（v1.6）")
        func input(_ ps: [DiagProc], cores: Double = 10, mem: Int = 1, free: Int = 60) -> DiagInput {
            var i = DiagInput(); i.procs = ps; i.cores = cores; i.memPressure = mem; i.memFreePct = free; i.selfPid = 42
            i.appNames = [edge: "Microsoft Edge", chrome: "Google Chrome"]; i.appPids = [edge: 500, chrome: 600]
            return i
        }
        let idle = [DiagProc(pid: 500, cpu: 3, memMB: 400, path: edge + "/Contents/MacOS/Microsoft Edge"), DiagProc(pid: 88, cpu: 8, memMB: 200, path: ws)]
        var v = Diagnosis.make(input(idle))
        check(v.level == .smooth && v.title == "不卡" && v.reason == "CPU 占用 1%，内存压力正常" && v.fix == .none, "空闲：不卡、没有处理按钮", v.reason)
        var i = input(idle); i.uptimeDays = 20
        check(Diagnosis.make(i).note.contains("20 天"), "不卡但很久没重启时只给建议")
        v = Diagnosis.make(input(idle + [DiagProc(pid: 701, cpu: 83.2, memMB: 900, path: edgeRenderer)]))
        check(v.level == .slight && v.reason == "Edge 的一个标签页占 83% CPU" && v.fix == .closeTab(pid: 701, owner: "Edge", cpu: 83.2, memMB: 900), "单个标签页占 83%：指出是哪个浏览器的标签页", v.reason)
        check(v.fix.title == "关闭这个标签页…" && v.fix.short == "关标签", "标签页处理按钮文字")
        v = Diagnosis.make(input([DiagProc(pid: 42, cpu: 190, memMB: 50, path: "/Applications/Mac一键优化.app/Contents/MacOS/MacOptimizer")] + idle))
        check(v.level == .smooth, "不把自己算进去")
        v = Diagnosis.make(input(idle + (0..<6).map { DiagProc(pid: 800 + Int32($0), cpu: 30, memMB: 1100, path: chromeRenderer) }, mem: 4, free: 6))
        check(v.level == .heavy && v.reason.contains("内存不够用了") && v.reason.contains("Chrome（6.4 GB）") && v.fix == .quitApp(pid: 600, name: "Chrome", memMB: 6600), "内存紧张：指出最占内存的 App 并给退出按钮", v.reason)
        v = Diagnosis.make(input(idle + (0..<6).map { DiagProc(pid: 800 + Int32($0), cpu: 30, memMB: 300, path: chromeRenderer) }))
        check(v.level == .slight && v.reason == "Chrome 的多个进程共占 180% CPU" && v.fix.title == "退出 Chrome…", "多个进程加起来很高时按 App 汇总", v.reason)
        v = Diagnosis.make(input([DiagProc(pid: 900, cpu: 195, memMB: 300, path: "/Applications/Xcode.app/Contents/MacOS/Xcode")], cores: 2))
        check(v.level == .heavy && v.reason == "Xcode 占 195% CPU" && v.fix == .none, "CPU 满载 = 很卡；没有主进程号时不给退出按钮", v.reason)
        v = Diagnosis.make(input(idle + [DiagProc(pid: 77, cpu: 55, memMB: 100, path: "/System/Library/Frameworks/CoreSpotlight.framework/corespotlightd")]))
        check(v.fix == .restartSpotlight && v.level == .slight, "Spotlight 卡住给「重启索引」")
        v = Diagnosis.make(input([DiagProc(pid: 88, cpu: 72, memMB: 900, path: ws)]))
        check(v.fix == .displayTips && v.reason.contains("WindowServer 占 72%"), "WindowServer 高：去显示性能页", v.reason)
        v = Diagnosis.make(input(idle, mem: 2, free: 25))
        check(v.level == .slight && v.reason.hasPrefix("内存有点紧张") && v.note == "系统内存压力：偏高", "内存压力偏高 = 有点卡", v.reason)
        v = Diagnosis.make(input([DiagProc(pid: 60, cpu: 120, memMB: 10, path: "kernel_task")]))
        check(v.reason.contains("降温") && v.fix == .none, "kernel_task 高：解释原因、不给按钮", v.reason)

        sec("接显示器模式（v1.6）")
        var (dm, a) = dockFixture(enabled: false)
        check(!dm.enabled && !dm.active && a.created == 0, "默认关闭、不创建断言")
        (dm, a) = dockFixture(enabled: true)
        check(dm.active && a.live, "接屏 + 插电：生效")
        check(UserDefaults(suiteName: "mo-dock-test")!.bool(forKey: DockMode.key), "开关状态会保存")
        dm.readPower = { false }; dm.evaluate(); check(!dm.active && !a.live && dm.status == "等待接电源", "拔电源：立即撤销")
        dm.readPower = { true }; dm.evaluate(); check(dm.active && a.created == 2, "重新插电：再次生效")
        dm.screens(asleep: true); dm.readExternal = { false }; dm.evaluate()
        check(dm.active, "熄屏期间显示器“断开”不撤销（有些显示器熄屏后会断开）")
        dm.screens(asleep: false); check(!dm.active && !a.live && dm.status == "等待接显示器", "亮屏后确实没接显示器：撤销")
        dm.readExternal = { true }; dm.evaluate(); dm.setEnabled(false)
        check(!dm.active && !a.live && dm.created0(a), "关闭开关：撤销，断言成对释放")
        (dm, a) = dockFixture(enabled: true, external: false); check(!dm.active && a.created == 0, "没接显示器：不生效")
        UserDefaults(suiteName: "mo-dock-test")!.removePersistentDomain(forName: "mo-dock-test")
        // 真实系统断言：只阻止空闲睡眠，不阻止屏幕熄灭
        check(IOPMSleepAssertion.type == "PreventUserIdleSystemSleep", "断言类型是「阻止空闲睡眠」，屏幕照常熄灭")
        let real = IOPMSleepAssertion()
        if let id = real.create(DockMode.assertName) {
            check(DockMode.systemSeesAssertion(), "系统能看到断言（pmset -g assertions 可见）")
            real.release(id); check(!DockMode.systemSeesAssertion(), "释放后系统里消失")
        } else { check(false, "创建系统断言") }
        info("当前：外接显示器 \(DockMode.systemHasExternal() ? "有" : "无")，电源 \(DockMode.systemOnAC() ? "插电" : "电池")")
    }

    static func v16UI(_ w: NSWindow) {
        sec("处理按钮（需确认，正常结束）")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["600"]; try! p.run()
        var asked = 0
        FixRunner.confirm = { _, _, _ in asked += 1; return false }
        check(!FixRunner.run(.closeTab(pid: p.processIdentifier, owner: "Edge", cpu: 83, memMB: 10)) && asked == 1 && p.isRunning, "取消确认时不关标签页")
        FixRunner.confirm = { _, _, _ in asked += 1; return true }
        check(FixRunner.run(.closeTab(pid: p.processIdentifier, owner: "Edge", cpu: 83, memMB: 10)) && asked == 2, "确认后关闭")
        check(waitUntil(2) { !p.isRunning } && p.terminationStatus == SIGTERM, "用 SIGTERM 正常结束（未强制）")
        check(!FixRunner.run(.closeTab(pid: getpid(), owner: "x", cpu: 0, memMB: 0)), "不会结束自己")
        check(ProcActions.fix(for: ProcInfo(id: getpid(), name: "self", cpu: 0, memMB: 0)) == .none, "面板里自己没有退出按钮")
        let q = Process(); q.executableURL = URL(fileURLWithPath: "/bin/sleep"); q.arguments = ["5"]; try! q.run()
        check(ProcActions.fix(for: ProcInfo(id: q.processIdentifier, name: "sleep", cpu: 0, memMB: 0)) == .none, "系统程序没有退出按钮"); q.terminate()
        if let fin = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) {
            check(ProcActions.fix(for: ProcInfo(id: fin.processIdentifier, name: "Finder", cpu: 1, memMB: 100)).short == "退出", "普通 App 有「退出」按钮（测试不点击）")
        }

        sec("概览：打开就体检（v1.6）")
        Nav.shared.sel = -2; settle(0.3); Nav.shared.sel = -1
        var title = ""
        let ok = waitUntil(20) { if let r = find1(w.contentView!, id: "verdict.title") { title = axString(r.o, "accessibilityLabel"); if title.isEmpty, let v = r.value as? String { title = v } }; return ["不卡：", "有点卡：", "很卡："].contains { title.hasPrefix($0) } }
        check(ok, "自动给出结论", title)
        check(find(w.contentView!, id: "verdict.rescan") != nil, "有「重新体检」按钮")

        sec("菜单栏快捷操作（v1.6）")
        let realDock = DockMode.shared, realCharge = ChargeClient.shared
        // 测试进程启动时，若用户真实设置里接显示器模式已开启且已接屏插电，
        // 真实 DockMode 会在启动时创建真实系统断言；模拟测试换上 MockAssertion 后，
        // 那个真实断言并不会被模拟开关撤销，最后的“没有留下系统断言”检查就会误报。
        // 这里先停掉测试进程里的真实实例（只影响测试进程，装在本机的 App 不受影响），
        // 模拟断言的成对释放仍由下面 a.live 的检查覆盖。
        realDock.stop()
        let (dm, a) = dockFixture(enabled: false); DockMode.shared = dm
        let fx = chargeFixture(); ChargeClient.shared = fx
        defer { DockMode.shared = realDock; ChargeClient.shared = realCharge }
        Nav.shared.sel = -3; settle(0.3); Nav.shared.sel = -2
        if let b = find(w.contentView!, id: "act.dock") {
            b.press(); check(waitUntil(1) { dm.enabled && dm.active && a.live }, "点「接显示器模式」开启并生效")
            b.press(); check(waitUntil(1) { !dm.enabled && !a.live }, "再点关闭并撤销")
        } else { check(false, "找到「接显示器模式」按钮") }
        if let b = find(w.contentView!, id: "act.charge") {
            b.press(); check(waitUntil(1) { !fx.st.settings.enabled }, "点「充电上限」关闭")
            b.press(); check(waitUntil(1) { fx.st.settings.enabled && fx.st.settings.limit == 80 }, "再点开启，上限保持 80%")
        } else { check(false, "找到「充电上限」按钮") }
        Nav.shared.sel = -4
        if let t = find(w.contentView!, id: "dock.toggle") {
            t.press(); check(waitUntil(1) { dm.enabled && dm.active }, "显示器页开关可开启")
            t.press(); check(waitUntil(1) { !dm.enabled && !dm.active }, "显示器页开关可关闭")
        } else { check(false, "显示器页有「接显示器模式」卡片") }
        check(!DockMode.systemSeesAssertion(), "测试结束没有留下系统断言")
    }

    /// 截图：体检结论卡片、接显示器模式卡片；并把面板换成固定数据（后面的基准图用）
    static func v16Snapshots(_ out: String) {
        let (dm, _) = dockFixture(enabled: true); DockMode.shared = dm
        ProcActions.override = { p in
            switch p.name {
            case "Google Chrome Helper": return .closeTab(pid: p.id, owner: "Chrome", cpu: p.cpu, memMB: p.memMB)
            case "WindowServer": return .none
            default: return .quitApp(pid: p.id, name: p.name, memMB: p.memMB)
            }
        }
        let m = Model()
        m.phase = .done; m.score = 62; m.summary = "开机 3 天 · 负载 4.1 · 内存可用 35%"
        m.verdict = Verdict(level: .slight, reason: "Edge 的一个标签页占 83% CPU", fix: .closeTab(pid: 1, owner: "Edge", cpu: 83, memMB: 900))
        m.issues = [Issue(title: "浏览器：Microsoft Edge", detail: "占用 3.2 GB 内存（同时开着 2 个浏览器）", action: {}, on: false),
                    Issue(title: "浏览器：Google Chrome", detail: "占用 2.1 GB 内存（同时开着 2 个浏览器）", action: {}, on: false),
                    Issue(title: "鹊桥VPN 控制台窗口", detail: "网页窗口持续占用 CPU，关掉不影响 VPN 连接", action: {}, on: true),
                    Issue(title: "系统已连续运行 16 天", detail: "WindowServer 当前占用 35% CPU", action: nil, on: false)]
        let smooth = Model(); smooth.phase = .done; smooth.score = 96; smooth.summary = "开机 3 天 · 负载 2.0 · 内存可用 58%"
        smooth.verdict = Verdict(level: .smooth, reason: "CPU 占用 9%，内存压力正常")
        for (mode, ap) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: ap)
            func shot<V: View>(_ v: V, _ name: String, width: CGFloat) {
                let host = NSHostingView(rootView: v.padding(20).frame(width: width).background(pageBG))
                let size = host.fittingSize; host.frame = NSRect(origin: .zero, size: size)
                let cw = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: size.width, height: size.height), styleMask: [.titled], backing: .buffered, defer: false)
                cw.appearance = NSAppearance(named: ap); cw.contentView = host; cw.orderFrontRegardless(); settle(1.0)
                if let rep = pngRep(host, out + "/\(name)-\(mode).png"), name != "verdict-smooth" { contrast(host, rep, "\(name) \(mode)") }   // 「不卡」卡片只有两段文字，够不上对比度检查的最少段数
                fits(host, name + " " + mode)
                cw.orderOut(nil)
            }
            shot(CheckupCard(m: m), "verdict", width: Layout.minSize.width - 212)
            shot(CheckupCard(m: smooth), "verdict-smooth", width: Layout.minSize.width - 212)
            shot(DockModeCard(), "dock", width: 460)
        }
        NSApp.appearance = NSAppearance(named: .aqua)
    }
}

extension DockMode { func created0(_ a: MockAssertion) -> Bool { a.created == a.released } }
