// v1.6：一键体检结论、菜单栏快捷操作、接显示器模式（息屏不断网）
import SwiftUI
import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import Darwin
import Combine

// MARK: - 进程归属：属于哪个 App、是不是浏览器标签页
enum ProcKind: Equatable { case app, tab, gpu, helper, system }
struct ProcOwner: Equatable { let name: String; let bundlePath: String?; let kind: ProcKind }

enum ProcDescribe {
    static let shortNames = ["Microsoft Edge": "Edge", "Google Chrome": "Chrome", "Google Chrome Canary": "Chrome Canary", "Microsoft Edge Beta": "Edge Beta"]
    static func short(_ n: String) -> String { shortNames[n] ?? n }
    /// 根据可执行文件路径判断归属。appNames：App 包路径 → 本地化名称（来自正在运行的 App）
    static func owner(path: String, appNames: [String: String] = [:]) -> ProcOwner {
        let exe = (path as NSString).lastPathComponent
        guard let r = path.range(of: ".app/") else {
            // Safari 的网页标签页跑在系统 WebKit 进程里
            if exe.hasPrefix("com.apple.WebKit.WebContent") { return ProcOwner(name: "Safari", bundlePath: nil, kind: .tab) }
            return ProcOwner(name: exe, bundlePath: nil, kind: .system)
        }
        let bundle = String(path[..<r.lowerBound]) + ".app"
        let base = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = short(appNames[bundle] ?? base)
        let rest = String(path[r.upperBound...])
        let kind: ProcKind
        if rest.contains(".app/") || exe.contains("Helper") {
            if exe.contains("(Renderer)") { kind = .tab } else if exe.contains("(GPU)") { kind = .gpu } else { kind = .helper }
        } else { kind = .app }
        return ProcOwner(name: name, bundlePath: bundle, kind: kind)
    }
}

/// 进程可执行文件路径（读不到的是其他用户/系统的进程）
enum PidPath {
    private static var cache: [Int32: String] = [:]
    static func path(_ pid: Int32) -> String {
        if let c = cache[pid] { return c }
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        let s = n > 0 ? String(cString: buf) : ""
        if cache.count > 300 { cache = [:] }
        cache[pid] = s
        return s
    }
}

// MARK: - 一键体检结论
enum Fix: Equatable {
    case none
    case quitApp(pid: Int32, name: String, memMB: Double)
    case closeTab(pid: Int32, owner: String, cpu: Double, memMB: Double)
    case restartSpotlight, quitClaude, displayTips
    var title: String? {
        switch self {
        case .none: return nil
        case .quitApp(_, let n, _): return "退出 \(n)…"
        case .closeTab: return "关闭这个标签页…"
        case .restartSpotlight: return "重启索引"
        case .quitClaude: return "退出 Claude…"
        case .displayTips: return "减轻渲染负担"
        }
    }
    /// 菜单栏面板里的短标签
    var short: String? {
        switch self {
        case .quitApp: return "退出"
        case .closeTab: return "关标签"
        default: return nil
        }
    }
}

struct Verdict: Equatable {
    enum Level: Int { case smooth = 0, slight, heavy }
    var level: Level; var reason: String; var fix: Fix = .none; var note = ""
    var title: String { ["不卡", "有点卡", "很卡"][level.rawValue] }
}

struct DiagProc: Equatable { let pid: Int32; let cpu: Double; let memMB: Double; let path: String }
struct DiagInput {
    var procs: [DiagProc] = []
    var cores = 8.0
    var memPressure = 1          // 1 正常 / 2 偏高 / 4 紧张（系统 kern.memorystatus_vm_pressure_level）
    var memFreePct = 100
    var load = 0.0
    var uptimeDays = 0
    var appNames: [String: String] = [:]   // App 包路径 → 名称
    var appPids: [String: Int32] = [:]     // App 包路径 → 主进程
    var selfPid: Int32 = getpid()
}

enum ProcessCPU {
    static let warning: Double = 30
    static let danger: Double = 80
    static func color(_ percent: Double) -> Color {
        percent >= danger ? bad : (percent >= warning ? warn : .primary)
    }
}

enum Diagnosis {
    static let spotlight = ["corespotlightd", "helpd", "mds_stores"]
    static func gb(_ mb: Double) -> String { mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb) }

    static func make(_ i: DiagInput) -> Verdict {
        let ps = i.procs.filter { $0.pid > 0 && $0.pid != i.selfPid }
        let total = min(100, ps.reduce(0) { $0 + $1.cpu } / max(1, i.cores))
        func own(_ p: DiagProc) -> ProcOwner { ProcDescribe.owner(path: p.path, appNames: i.appNames) }
        func exe(_ p: DiagProc) -> String { (p.path as NSString).lastPathComponent }
        // 按 App 汇总（主进程 + 所有辅助进程）
        var groups: [String: (cpu: Double, mem: Double, name: String)] = [:]
        for p in ps { let o = own(p); guard let b = o.bundlePath else { continue }
            var g = groups[b] ?? (0, 0, o.name); g.cpu += p.cpu; g.mem += p.memMB; groups[b] = g }
        let claudeOn = groups.values.contains { $0.name.hasPrefix("Claude") }
        func appFix(_ bundle: String, _ name: String, _ mem: Double) -> Fix {
            if let pid = i.appPids[bundle] { return .quitApp(pid: pid, name: name, memMB: mem) }
            return .none
        }
        func pct(_ v: Double) -> Int { Int(v.rounded()) }

        func cpuCulprit() -> (String, Fix, String)? {
            guard let top = ps.max(by: { $0.cpu < $1.cpu }) else { return nil }
            // 单个进程不突出，但某个 App 的多个进程加起来很高
            if let e = groups.max(by: { $0.value.cpu < $1.value.cpu }), top.cpu < 50, e.value.cpu >= max(60, top.cpu * 1.5) {
                let b = e.key, g = e.value
                return ("\(g.name) 的多个进程共占 \(pct(g.cpu))% CPU", appFix(b, g.name, g.mem), "")
            }
            let o = own(top), c = pct(top.cpu)
            switch o.kind {
            case .tab: return ("\(o.name) 的一个标签页占 \(c)% CPU", o.bundlePath == nil ? .none : .closeTab(pid: top.pid, owner: o.name, cpu: top.cpu, memMB: top.memMB), o.bundlePath == nil ? "在 Safari 里关掉最近打开的网页试试" : "")
            case .gpu: return ("\(o.name) 的图形进程占 \(c)% CPU", appFix(o.bundlePath!, o.name, groups[o.bundlePath!]?.mem ?? top.memMB), "")
            case .helper: return ("\(o.name) 的后台进程占 \(c)% CPU", appFix(o.bundlePath!, o.name, groups[o.bundlePath!]?.mem ?? top.memMB), "")
            case .app: return ("\(o.name) 占 \(c)% CPU", appFix(o.bundlePath!, o.name, groups[o.bundlePath!]?.mem ?? top.memMB), "")
            case .system:
                let n = exe(top)
                if n == "WindowServer" { return ("画面渲染吃力（WindowServer 占 \(c)% CPU）", .displayTips, "外接大屏和透明效果会加重渲染负担") }
                if spotlight.contains(n) { return ("Spotlight 索引占 \(c)% CPU", .restartSpotlight, "重启索引不会丢任何数据") }
                if n == Sys.vmName { return ("后台虚拟机占 \(c)% CPU", claudeOn ? .quitClaude : .none, "") }
                if n == "kernel_task" { return ("系统在给机身降温（kernel_task 占 \(c)% CPU）", .none, "通常是机器太热，放到通风处会好些") }
                return ("系统进程 \(n) 占 \(c)% CPU", .none, "")
            }
        }
        func memCulprit() -> (String, Fix)? {
            guard let e = groups.max(by: { $0.value.mem < $1.value.mem }) else { return nil }
            let b = e.key, g = e.value
            return ("最占内存的是 \(g.name)（\(gb(g.mem))）", appFix(b, g.name, g.mem))
        }
        func sum(_ names: [String]) -> Double { ps.filter { names.contains(exe($0)) }.reduce(0) { $0 + $1.cpu } }

        // 1. 内存严重不足：最直接的卡顿原因
        if i.memPressure >= 4 {
            let c = memCulprit()
            return Verdict(level: .heavy, reason: "内存不够用了" + (c.map { "，" + $0.0 } ?? ""), fix: c?.1 ?? .none, note: "系统内存压力：紧张")
        }
        // 2. CPU 整体满载
        if total > 85 || i.load > i.cores * 1.5, let c = cpuCulprit() {
            return Verdict(level: .heavy, reason: c.0, fix: c.1, note: c.2.isEmpty ? "CPU 总占用 \(pct(total))%" : c.2)
        }
        // 3. 常见的“查不出原因”的卡顿
        let sp = sum(spotlight)
        if sp > 40 { return Verdict(level: .slight, reason: "Spotlight 索引卡住了，占 \(pct(sp))% CPU", fix: .restartSpotlight, note: "重启索引不会丢任何数据") }
        let vm = sum([Sys.vmName])
        if vm > 50 { return Verdict(level: .slight, reason: "后台虚拟机占 \(pct(vm))% CPU" + (claudeOn ? "（Claude）" : ""), fix: claudeOn ? .quitClaude : .none, note: "没有任务在跑就可以退出") }
        if let top = ps.max(by: { $0.cpu < $1.cpu }), top.cpu >= ProcessCPU.danger, let c = cpuCulprit() {
            return Verdict(level: .slight, reason: c.0, fix: c.1, note: c.2)
        }
        if let e = groups.max(by: { $0.value.cpu < $1.value.cpu }), e.value.cpu >= 150 {
            let b = e.key, g = e.value
            return Verdict(level: .slight, reason: "\(g.name) 的多个进程共占 \(pct(g.cpu))% CPU", fix: appFix(b, g.name, g.mem))
        }
        let ws = sum(["WindowServer"])
        if ws > 60 { return Verdict(level: .slight, reason: "画面渲染吃力（WindowServer 占 \(pct(ws))% CPU）", fix: .displayTips, note: "外接大屏和透明效果会加重渲染负担") }
        if i.memPressure >= 2 {
            let c = memCulprit()
            return Verdict(level: .slight, reason: "内存有点紧张" + (c.map { "，" + $0.0 } ?? ""), fix: c?.1 ?? .none, note: "系统内存压力：偏高")
        }
        // 4. 不卡
        return Verdict(level: .smooth, reason: "CPU 占用 \(pct(total))%，内存压力正常",
                       note: i.uptimeDays >= 14 ? "已经连续运行 \(i.uptimeDays) 天，有空时重启一次会更清爽" : "")
    }

    /// 从 ps 结果和正在运行的 App 组装输入
    static func input(_ ps: [Proc], memFreePct: Int, load: Double) -> DiagInput {
        var x = DiagInput()
        x.procs = ps.map { DiagProc(pid: $0.pid, cpu: $0.cpu, memMB: $0.rss / 1024, path: $0.comm) }
        x.cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        var s = Snapshot(); Readers.memory(into: &s); x.memPressure = s.memPressure
        x.memFreePct = memFreePct; x.load = load
        x.uptimeDays = Int(ProcessInfo.processInfo.systemUptime / 86400)
        for a in NSWorkspace.shared.runningApplications { if let p = a.bundleURL?.path { x.appNames[p] = a.localizedName; x.appPids[p] = a.processIdentifier } }
        return x
    }
}

// MARK: - 处理按钮（都要用户点击；退出走正常退出并先确认）
enum FixRunner {
    static var confirm: (_ title: String, _ info: String, _ button: String) -> Bool = { t, i, b in
        let a = NSAlert(); a.messageText = t; a.informativeText = i
        a.addButton(withTitle: b); a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }
    @discardableResult static func run(_ f: Fix) -> Bool {
        switch f {
        case .none: return false
        case let .quitApp(pid, name, mem):
            return Actions.quit(ProcInfo(id: pid, name: name, cpu: 0, memMB: mem))
        case let .closeTab(pid, owner, cpu, mem):
            guard pid > 1, pid != getpid(), confirm("关闭 \(owner) 里这个占 \(Int(cpu.rounded()))% CPU 的标签页？",
                                          "只结束这一个标签页：它会显示「页面已崩溃」，点刷新就能重新打开。\(owner) 本身和其他标签页不受影响。", "关闭标签页") else { return false }
            let ok = kill(pid, SIGTERM) == 0
            if ok { OperationCheck.wait(until: { !OperationCheck.processExists(pid) }) { verified in if verified { CleanStats.shared.addOptimized(1) } }; _ = mem }
            Monitor.shared.sampleNow()
            return ok
        case .restartSpotlight:
            DispatchQueue.global().async { Sys.restartSpotlight() }
            return true
        case .quitClaude:
            guard confirm("退出 Claude？", "会像在 Claude 里选「退出」一样正常关闭，后台虚拟机随之停止。", "退出") else { return false }
            DispatchQueue.global().async { Sys.quitClaude() }
            return true
        case .displayTips:
            Nav.shared.sel = .tool(.displayPerformance); UIState.shared.openMain(); return true
        }
    }
}

/// 菜单栏面板「高占用进程」每一行的处理方式
enum ProcActions {
    static var override: ((ProcInfo) -> Fix)?   // 截图用
    static func fix(for p: ProcInfo) -> Fix {
        if let o = override { return o(p) }
        guard p.id != getpid() else { return .none }
        let path = PidPath.path(p.id)
        guard !path.isEmpty else { return .none }   // 读不到路径的是系统/其他用户的进程，不提供退出
        let o = ProcDescribe.owner(path: path)
        switch o.kind {
        case .system: return .none
        case .tab: return o.bundlePath == nil ? .none : .closeTab(pid: p.id, owner: o.name, cpu: p.cpu, memMB: p.memMB)
        case .app, .gpu, .helper:
            if let a = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == o.bundlePath }) {
                return .quitApp(pid: a.processIdentifier, name: ProcDescribe.short(a.localizedName ?? o.name), memMB: p.memMB)
            }
            return .quitApp(pid: p.id, name: p.name, memMB: p.memMB)
        }
    }
}

// MARK: - 接显示器模式：插电 + 接外接屏时，屏幕照常熄灭，但整机不睡眠（网络、VPN 不断）
protocol SleepAssertion { func create(_ name: String) -> UInt32?; func release(_ id: UInt32) }
struct IOPMSleepAssertion: SleepAssertion {
    /// 只阻止「空闲时整机睡眠」，不阻止屏幕熄灭；App 退出或崩溃时系统自动撤销，不改任何系统设置
    static let type = kIOPMAssertionTypePreventUserIdleSystemSleep as String
    func create(_ name: String) -> UInt32? {
        var id: IOPMAssertionID = 0
        return IOPMAssertionCreateWithName(Self.type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id) == kIOReturnSuccess ? id : nil
    }
    func release(_ id: UInt32) { IOPMAssertionRelease(id) }
}

/// 启动时恢复用户保存的常亮与接显示器模式（含 --background 启动）
enum LaunchRestore {
    static func run(keepAwake: KeepAwake, dock: DockMode) {
        keepAwake.restore()
        if dock.enabled && dock.observe { dock.start() }
        dock.evaluate()
    }
}
final class DockMode: ObservableObject {
    static var shared = DockMode()
    static let key = "dockMode.enabled"
    static let assertName = "Mac一键优化：接显示器模式（息屏不断网）"
    @Published private(set) var enabled: Bool
    @Published private(set) var external = false
    @Published private(set) var onAC = false
    @Published private(set) var active = false
    var defaults: UserDefaults
    var assertion: SleepAssertion = IOPMSleepAssertion()
    var readPower: () -> Bool = DockMode.systemOnAC
    var readExternal: () -> Bool = DockMode.systemHasExternal
    var observe = true                     // 测试实例不挂系统通知
    private(set) var screensAsleep = false
    private var id: UInt32 = 0
    private var obs: [NSObjectProtocol] = []
    private var psSource: CFRunLoopSource?
    private var chargeSub: AnyCancellable?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults; enabled = defaults.bool(forKey: Self.key) }

    func setEnabled(_ on: Bool) {
        enabled = on; defaults.set(on, forKey: Self.key)
        if on { if observe { start() } } else { stop() }
        evaluate()
    }
    /// 只在开启时监听显示器/电源变化，关闭状态不占资源
    func start() {
        guard obs.isEmpty else { return }
        obs.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.evaluate() })
        let wc = NSWorkspace.shared.notificationCenter
        obs.append(wc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.screens(asleep: true) })
        obs.append(wc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.screens(asleep: false) })
        obs.append(wc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.evaluate() })
        // 充电上限用「断开电源」实现时，要靠充电助手的状态判断是否插着电
        chargeSub = ChargeClient.shared.$st.receive(on: RunLoop.main).sink { [weak self] _ in DispatchQueue.main.async { self?.evaluate() } }
        ChargeClient.shared.refresh()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ c in
            guard let c else { return }
            let me = Unmanaged<DockMode>.fromOpaque(c).takeUnretainedValue()
            DispatchQueue.main.async { me.evaluate() }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes); psSource = src
        }
    }
    func stop() {
        release()
        for o in obs { NotificationCenter.default.removeObserver(o); NSWorkspace.shared.notificationCenter.removeObserver(o) }
        obs = []; chargeSub = nil
        if let s = psSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes); psSource = nil }
    }
    /// 有的显示器熄屏后会“断开”，熄屏期间不因此撤销，亮屏后再按实际情况判断
    func screens(asleep: Bool) { screensAsleep = asleep; evaluate() }
    func evaluate() {
        external = readExternal() || (active && screensAsleep)
        onAC = readPower()
        let want = enabled && external && onAC
        if want && !active, let i = assertion.create(Self.assertName) { id = i; active = true }
        else if !want && active { release() }
    }
    private func release() { if active { assertion.release(id); active = false } }

    var status: String {
        if !enabled { return "接屏插电时息屏不断网" }
        if active { return "生效中 · 息屏不睡眠" }
        if !external { return "等待接显示器" }
        return "等待接电源"
    }

    static func systemOnAC() -> Bool {
        // 充电上限用「断开电源」实现时，系统会显示在用电池，但其实插着电
        let c = ChargeClient.shared.st
        if c.adapterCut && c.plugged { return true }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        guard let cf = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        let t = cf as String
        return t == kIOPMACPowerKey || t == kIOPMUPSPowerKey
    }
    static func systemHasExternal() -> Bool {
        // 「在线」包含熄屏中的显示器；再用 NSScreen 兜底
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
        if CGGetOnlineDisplayList(16, &ids, &n) == .success, ids.prefix(Int(n)).contains(where: { CGDisplayIsBuiltin($0) == 0 }) { return true }
        return NSScreen.screens.contains { s in
            guard let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
            return CGDisplayIsBuiltin(id) == 0
        }
    }
    /// 系统里是否能看到本 App 的「阻止空闲睡眠」断言（用于自检）
    static func systemSeesAssertion() -> Bool {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess, let d = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        return ((d[NSNumber(value: getpid())] ?? nil) ?? []).contains { ($0["AssertType"] as? String) == IOPMSleepAssertion.type && ($0["AssertName"] as? String) == assertName }
    }
}

struct DockModeCard: View {
    @ObservedObject var d = DockMode.shared
    func chip(_ ok: Bool, _ text: String) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 11)).foregroundColor(ok ? good : .secondary)
    }
    var body: some View {
        Card(title: "接显示器模式", icon: "powerplug") {
            HStack {
                Text("息屏不断网").font(.system(size: 11, weight: .medium))
                Spacer()
                Toggle("", isOn: Binding(get: { d.enabled }, set: { d.setEnabled($0) })).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(accent).accessibilityIdentifier("dock.toggle")
            }
            Text("接着显示器又插着电时：屏幕照常按系统设置熄灭，但 Mac 不睡眠，VPN、下载、远程连接都不断。拔掉电源或显示器就恢复系统默认，不改任何系统设置。")
                .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                chip(d.external, "外接显示器")
                chip(d.onAC, "电源")
                chip(d.active, d.active ? "生效中" : "未生效").accessibilityIdentifier("dock.state")
            }
        }.onAppear { d.evaluate() }   // 关闭状态下不监听变化，打开页面时刷新一次
    }
}
