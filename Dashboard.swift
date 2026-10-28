import SwiftUI
import AppKit
import ServiceManagement
import Combine

// MARK: - 格式化
enum Fmt {
    static func rate(_ bps: Double) -> String {
        if bps >= 1_048_576 { return String(format: "%.1f MB/s", bps / 1_048_576) }
        return String(format: "%.0f KB/s", bps / 1024)
    }
    static func uptime(_ t: TimeInterval) -> String {
        let d = Int(t / 86400), h = Int(t.truncatingRemainder(dividingBy: 86400) / 3600)
        return d > 0 ? "\(d) 天 \(h) 小时" : "\(h) 小时 \(Int(t.truncatingRemainder(dividingBy: 3600) / 60)) 分"
    }
    static func mem(_ mb: Double) -> String { mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb) }
    static func temp(_ t: Double?) -> String { t.map { String(format: "%.0f°C", $0) } ?? "温度不可读" }
    static func pressure(_ p: Int) -> (String, Color) { p >= 4 ? ("紧张", .red) : (p >= 2 ? ("偏高", .orange) : ("正常", good)) }
    static func energy(_ j: Double) -> String { j >= 3600 ? String(format: "%.1f Wh", j / 3600) : (j >= 36 ? String(format: "%.0f mWh", j / 3.6) : String(format: "%.1f mWh", j / 3.6)) }
}

func levelColor(_ frac: Double, hi: Double = 0.85, mid: Double = 0.6) -> Color { frac >= hi ? .red : (frac >= mid ? .orange : accent2) }
func batteryColor(_ p: Int) -> Color { p <= 10 ? .red : (p <= 20 ? .orange : good) }

// MARK: - 小组件
struct Spark: View {
    let values: [Double]; let color: Color; var maxValue: Double? = nil
    var body: some View {
        GeometryReader { g in
            let vs = values.isEmpty ? [0] : values
            let mx = max(maxValue ?? (vs.max() ?? 1), 0.0001)
            let pts = vs.enumerated().map { i, v in CGPoint(x: vs.count == 1 ? g.size.width : g.size.width * CGFloat(i) / CGFloat(vs.count - 1), y: g.size.height * (1 - CGFloat(min(v, mx) / mx))) }
            ZStack {
                Path { p in p.move(to: CGPoint(x: pts[0].x, y: g.size.height)); pts.forEach { p.addLine(to: $0) }; p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height)); p.closeSubpath() }
                    .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Path { p in p.move(to: pts[0]); pts.dropFirst().forEach { p.addLine(to: $0) } }.stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
    }
}

struct Bar: View {
    let frac: Double; let color: Color; var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.14))
                Capsule().fill(color).frame(width: max(height, g.size.width * CGFloat(min(1, max(0, frac)))))
            }
        }.frame(height: height)
    }
}

struct Tile<Content: View>: View {
    let icon: String; let title: String; let tint: Color; var trailing: String = ""
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundColor(tint)
                    .frame(width: 18, height: 18).background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.opacity(0.12)))
                Text(title).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                Spacer(minLength: 2)
                if !trailing.isEmpty { Text(trailing).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1) }
            }
            content
        }.padding(11).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(cardBG)
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2))
    }
}

struct BigValue: View {
    let value: String; var unit: String = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            if !unit.isEmpty { Text(unit).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary) }
        }
    }
}

struct Chip: View {
    let icon: String; let text: String
    var body: some View {
        HStack(spacing: 4) { Image(systemName: icon).font(.system(size: 9)); Text(text).font(.system(size: 10, weight: .medium)).lineLimit(1) }
            .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Color.white.opacity(0.18))).foregroundColor(.white)
    }
}

struct ScoreRing: View {
    let score: Int; var size: CGFloat = 54; var light = true
    var body: some View {
        ZStack {
            Circle().stroke((light ? Color.white : accent).opacity(0.22), lineWidth: 5)
            Circle().trim(from: 0, to: CGFloat(score) / 100).stroke(light ? Color.white : accent, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
            Text("\(score)").font(.system(size: size * 0.36, weight: .bold, design: .rounded)).foregroundColor(light ? .white : accent).monospacedDigit()
        }.frame(width: size, height: size)
    }
}

// MARK: - 动作
enum Actions {
    static var confirmQuit: (ProcInfo) -> Bool = { p in
        let a = NSAlert(); a.messageText = "退出「\(p.name)」？"
        a.informativeText = "会像在程序里选「退出」一样正常关闭，未保存的内容可能会提示你保存。不会强制结束。"
        a.addButton(withTitle: "退出"); a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }
    @discardableResult static func quit(_ p: ProcInfo) -> Bool {
        guard p.id != getpid(), confirmQuit(p) else { return false }
        let ok: Bool
        if let app = NSRunningApplication(processIdentifier: p.id) { ok = app.terminate() } else { ok = kill(p.id, SIGTERM) == 0 }
        if ok { CleanStats.shared.addQuit(memMB: p.memMB) }
        Monitor.shared.sampleNow()
        return ok
    }
    static func screenshot() { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"), configuration: .init()) }
    static var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func setLogin(_ on: Bool) { do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { NSLog("login item: \(error)") } }
}

final class UIState: ObservableObject {
    static let shared = UIState()
    @Published var micMuted = Mic.muted
    @Published var login = Actions.loginEnabled
    @Published var menuBar = UserDefaults.standard.object(forKey: "menuBar.enabled") as? Bool ?? true { didSet { UserDefaults.standard.set(menuBar, forKey: "menuBar.enabled"); StatusBar.shared.apply() } }
    var openMain: () -> Void = {}
}

// MARK: - 共享卡片
struct MetricTiles: View {
    @ObservedObject var m: Monitor
    var columns = 2; var sparkH: CGFloat = 26
    var body: some View {
        let s = m.s
        let tiles: [AnyView] = [AnyView(cpuTile(s)), AnyView(gpuTile(s)), AnyView(memTile(s)), AnyView(diskTile(s)), AnyView(netTile(s)), AnyView(fanTile(s))]
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(0..<(tiles.count + columns - 1) / columns, id: \.self) { r in
                GridRow { ForEach(0..<columns, id: \.self) { c in if r * columns + c < tiles.count { tiles[r * columns + c] } } }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
    func cpuTile(_ s: Snapshot) -> some View {
            Tile(icon: "cpu", title: "CPU", tint: levelColor(s.cpu / 100), trailing: Fmt.temp(s.cpuTemp)) {
                BigValue(value: String(format: "%.0f", s.cpu), unit: "%")
                Spark(values: m.cpuHist, color: levelColor(s.cpu / 100), maxValue: 100).frame(height: sparkH)
                Text(String(format: "负载 %.2f / %.2f / %.2f", s.load[0], s.load[1], s.load[2])).font(.system(size: 10)).foregroundColor(.secondary).monospacedDigit()
                Text("\(s.pCores) 性能核 · \(s.eCores) 能效核").font(.system(size: 10)).foregroundColor(.secondary)
            }
    }
    func gpuTile(_ s: Snapshot) -> some View {
            Tile(icon: "square.stack.3d.up", title: "GPU", tint: accent, trailing: Fmt.temp(s.gpuTemp)) {
                if let g = s.gpu { BigValue(value: String(format: "%.0f", g), unit: "%") } else { BigValue(value: "—") }
                Spark(values: m.gpuHist, color: accent, maxValue: 100).frame(height: sparkH)
                Text(s.gpuCores > 0 ? "\(s.gpuCores) 核图形处理器" : "核心数不可读").font(.system(size: 10)).foregroundColor(.secondary)
            }
    }
    func memTile(_ s: Snapshot) -> some View {
            Tile(icon: "memorychip", title: "内存", tint: Fmt.pressure(s.memPressure).1, trailing: String(format: "%.0f GB", s.memTotalGB)) {
                BigValue(value: String(format: "%.0f", s.memFraction * 100), unit: "%")
                Bar(frac: s.memFraction, color: Fmt.pressure(s.memPressure).1)
                Text("压力 \(Fmt.pressure(s.memPressure).0) · 已用 \(String(format: "%.1f", s.memUsedGB)) GB").font(.system(size: 10)).foregroundColor(.secondary)
                Text(String(format: "交换 %.2f GB", s.swapUsedGB)).font(.system(size: 10)).foregroundColor(.secondary)
            }
    }
    func diskTile(_ s: Snapshot) -> some View {
            Tile(icon: "internaldrive", title: "磁盘", tint: levelColor(s.diskUsedFraction, hi: 0.92, mid: 0.85), trailing: String(format: "%.0f GB", s.diskTotalGB)) {
                BigValue(value: String(format: "%.0f", s.diskUsedFraction * 100), unit: "% 已用")
                Bar(frac: s.diskUsedFraction, color: levelColor(s.diskUsedFraction, hi: 0.92, mid: 0.85))
                Text(String(format: "可用 %.0f GB", s.diskFreeGB)).font(.system(size: 10)).foregroundColor(.secondary)
            }
    }
    func netTile(_ s: Snapshot) -> some View {
            Tile(icon: "arrow.up.arrow.down", title: "网络", tint: accent2, trailing: s.netKind) {
                HStack(spacing: 10) {
                    Label(Fmt.rate(s.downBps), systemImage: "arrow.down").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    Label(Fmt.rate(s.upBps), systemImage: "arrow.up").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundColor(accent)
                }.labelStyle(.titleAndIcon)
                ZStack { Spark(values: m.downHist, color: accent2); Spark(values: m.upHist, color: accent) }.frame(height: sparkH)
                Text("代理：\(s.proxy.isEmpty ? "—" : s.proxy)").font(.system(size: 10)).foregroundColor(.secondary)
            }
    }
    func fanTile(_ s: Snapshot) -> some View {
            Tile(icon: "fan", title: "风扇", tint: good, trailing: s.fans.map { "\($0.count) 个" } ?? "") {
                if let f = s.fans {
                    let avg = f.reduce(0, +) / Double(max(1, f.count))
                    BigValue(value: String(format: "%.0f", avg), unit: "RPM")
                    Bar(frac: s.fanMax > 0 ? avg / s.fanMax : 0, color: good)
                    Text(avg < 1 ? "静音（低负载时风扇停转）" : String(format: "负荷 %.0f%% · 上限 %.0f", s.fanMax > 0 ? avg / s.fanMax * 100 : 0, s.fanMax)).font(.system(size: 10)).foregroundColor(.secondary)
                    Text("自动控制（调速需管理员权限，未提供）").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.8))
                } else { BigValue(value: "—"); Text("这台 Mac 没有可读取的风扇").font(.system(size: 10)).foregroundColor(.secondary) }
            }
    }
}

struct BatteryTile: View {
    let s: Snapshot
    var body: some View {
        Tile(icon: s.charging ? "battery.100.bolt" : "battery.75", title: "电池", tint: batteryColor(s.battery ?? 100), trailing: s.batteryHealth.map { "健康度 \($0)%" } ?? "") {
            if let b = s.battery {
                HStack(alignment: .center, spacing: 10) {
                    BigValue(value: "\(b)", unit: "%")
                    Bar(frac: Double(b) / 100, color: batteryColor(b), height: 8)
                }
                Text(stateText).font(.system(size: 10)).foregroundColor(.secondary)
            } else { Text("没有内置电池").font(.system(size: 11)).foregroundColor(.secondary) }
            let devs = BTBattery.shared.withBattery.isEmpty ? s.devices : BTBattery.shared.withBattery.map { DeviceBattery(name: $0.name, percent: $0.percent ?? 0, kind: $0.kind) }
            if !devs.isEmpty {
                HStack(spacing: 10) {
                    ForEach(devs.prefix(4)) { d in
                        HStack(spacing: 3) { Image(systemName: d.kind).font(.system(size: 10)); Text("\(d.percent)%").font(.system(size: 10, weight: .medium)).monospacedDigit() }.foregroundColor(batteryColor(d.percent))
                    }
                }
            }
        }
    }
    var stateText: String {
        var t = s.charging ? "正在充电" : (s.onAC ? "已接电源 · 暂停充电（系统电池保护）" : "使用电池")
        if !s.onAC, let r = s.timeRemaining { t += " · 约剩 \(r / 60) 小时 \(r % 60) 分" }
        if let c = s.cycles { t += " · 循环 \(c) 次" }
        return t
    }
}

enum IconCache {
    private static var c: [Int32: NSImage?] = [:]
    static func icon(_ pid: Int32) -> NSImage? {
        if let v = c[pid] { return v }
        if c.count > 100 { c.removeAll() }
        let i = NSRunningApplication(processIdentifier: pid)?.icon; c[pid] = i; return i
    }
}
struct ProcList: View {
    @ObservedObject var m: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text("高占用进程").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary); Spacer(); Text("CPU · 内存").font(.system(size: 10)).foregroundColor(.secondary) }
            if m.s.top.isEmpty { Text("正在统计…").font(.system(size: 11)).foregroundColor(.secondary) }
            ForEach(m.s.top) { p in
                HStack(spacing: 8) {
                    if let ic = IconCache.icon(p.id) { Image(nsImage: ic).resizable().frame(width: 16, height: 16) }
                    else { Image(systemName: "gearshape").font(.system(size: 11)).foregroundColor(.secondary).frame(width: 16, height: 16) }
                    Text(p.name).font(.system(size: 11)).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.1f%%", p.cpu)).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundColor(levelColor(p.cpu / 100, hi: 0.8, mid: 0.4))
                    Text(Fmt.mem(p.memMB)).font(.system(size: 10)).foregroundColor(.secondary).monospacedDigit().frame(width: 52, alignment: .trailing)
                    Menu { Button("退出「\(p.name)」…") { Actions.quit(p) }.disabled(p.id == getpid()) } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
                }
            }
        }.padding(11).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(cardBG).shadow(color: .black.opacity(0.05), radius: 6, y: 2))
    }
}

struct QuickActions: View {
    @ObservedObject var ui = UIState.shared
    @ObservedObject var ka = KeepAwake.shared
    @ObservedObject var st = CleanStats.shared
    func btn(_ id: String, _ icon: String, _ title: String, on: Bool = false, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium)).frame(height: 18)
                Text(title).font(.system(size: 10))
            }.frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? AnyShapeStyle(LinearGradient(colors: [accent2, accent], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(accent.opacity(0.08))))
            .foregroundColor(on ? .white : accent).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                btn("act.shot", "camera.viewfinder", "截图") { Actions.screenshot() }
                btn("act.mic", ui.micMuted ? "mic.slash.fill" : "mic.fill", ui.micMuted ? "麦克风已关" : "麦克风", on: ui.micMuted) { if Mic.setMuted(!Mic.muted) { ui.micMuted = Mic.muted } }
                btn("act.awake", ka.on ? "sun.max.fill" : "sun.max", ka.on ? "常亮中" : "常亮", on: ka.on) { ka.toggle() }
                btn("act.clean", "sparkles.rectangle.stack", "擦屏") { Overlay.cleanScreen() }
            }
            HStack(spacing: 0) {
                stat("\(st.optimized)", "项已优化"); Divider().frame(height: 22)
                stat("\(st.quitApps)", "个应用已退出"); Divider().frame(height: 22)
                stat(Fmt.mem(st.freedMB), "内存已释放")
            }
        }
    }
    func stat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 1) { Text(v).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit(); Text(l).font(.system(size: 9)).foregroundColor(.secondary) }.frame(maxWidth: .infinity)
    }
}

// MARK: - 菜单栏面板
struct PanelView: View {
    @ObservedObject var m: Monitor
    var body: some View {
        let h = min(940, (NSScreen.main?.visibleFrame.height ?? 900) - 30)
        ScrollView(showsIndicators: false) { PanelContent(m: m) }.frame(width: 380, height: h).background(pageBG)
    }
}
struct PanelContent: View {
    @ObservedObject var m: Monitor
    @ObservedObject var ui = UIState.shared
    @ObservedObject var alerts = BatteryAlerts.shared
    @ObservedObject var dm = DisplayManager.shared
    var body: some View {
        let s = m.s; let h = s.health
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ScoreRing(score: h.score)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("健康分").font(.system(size: 11)).opacity(0.8)
                        Text(h.status).font(.system(size: 15, weight: .semibold))
                    }
                    Spacer()
                    Button { ui.openMain() } label: { Image(systemName: "macwindow").font(.system(size: 13)) }.buttonStyle(.plain).help("打开主窗口").accessibilityIdentifier("panel.open")
                    Menu {
                        Picker("菜单栏显示", selection: $alerts.settings.menuIndicator) { Text("CPU 占用").tag("cpu"); Text("健康分").tag("score"); Text("电池图标").tag("battery") }
                        Toggle("登录时启动", isOn: Binding(get: { ui.login }, set: { Actions.setLogin($0); ui.login = Actions.loginEnabled }))
                        Divider()
                        Button("隐藏菜单栏图标") { ui.menuBar = false }
                        Button("退出 Mac一键优化") { NSApp.terminate(nil) }
                    } label: { Image(systemName: "gearshape").font(.system(size: 13)) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
                }.foregroundColor(.white)
                HStack(spacing: 5) {
                    Chip(icon: "cpu", text: s.chip.isEmpty ? "—" : s.chip)
                    Chip(icon: "memorychip", text: "\(s.ramGB) GB")
                    Chip(icon: "apple.logo", text: s.osVersion)
                }
                HStack(spacing: 5) {
                    Chip(icon: "clock", text: "已开机 " + Fmt.uptime(s.uptime))
                    Chip(icon: "network", text: s.proxy.isEmpty ? "—" : s.proxy)
                    if let d = dm.displays.first(where: { !$0.builtin }) ?? dm.displays.first { Chip(icon: "display", text: "\(d.current.label) · \(d.current.refreshLabel)") }
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(LinearGradient(colors: [accent2, accent, Color(red: 0.36, green: 0.22, blue: 0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            MetricTiles(m: m)
            BatteryTile(s: s)
            ProcList(m: m)
            QuickActions()
        }.padding(12).frame(width: 380).background(pageBG)
    }
}

// MARK: - 主窗口：实时监控
struct DashboardView: View {
    @ObservedObject var m: Monitor
    @ObservedObject var ui = UIState.shared
    var body: some View {
        let s = m.s; let h = s.health
        PageScroll {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    ScoreRing(score: h.score, size: 64, light: false)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("实时监控").font(.system(size: 24, weight: .bold))
                        Text("\(h.status) · 窗口可见时每 2 秒刷新，关闭后自动降频").font(.system(size: 12)).foregroundColor(.secondary)
                        HStack(spacing: 6) {
                            ForEach([s.chip, "\(s.ramGB) GB 内存", s.osVersion, "已开机 " + Fmt.uptime(s.uptime), "网络 " + (s.proxy.isEmpty ? "—" : s.proxy)], id: \.self) {
                                Text($0).font(.system(size: 10, weight: .medium)).foregroundColor(accent).padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(accent.opacity(0.09)))
                            }
                        }
                    }
                    Spacer()
                }
                MetricTiles(m: m, columns: 3, sparkH: 40)
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 8) { BatteryTile(s: s); ProcList(m: m) }
                    VStack(spacing: 8) {
                        QuickActions().padding(11).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(cardBG).shadow(color: .black.opacity(0.05), radius: 6, y: 2))
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("在菜单栏显示实时指标", isOn: $ui.menuBar).accessibilityIdentifier("dash.menubar")
                            Toggle("登录时自动启动（默认关闭）", isOn: Binding(get: { ui.login }, set: { Actions.setLogin($0); ui.login = Actions.loginEnabled })).accessibilityIdentifier("dash.login")
                        }.toggleStyle(.switch).controlSize(.small).font(.system(size: 12)).padding(11).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(cardBG).shadow(color: .black.opacity(0.05), radius: 6, y: 2))
                    }
                }
            }.padding(28)
        }
        .onAppear { m.dashboardShown = true } .onDisappear { m.dashboardShown = false }
    }
}

// MARK: - 擦屏 / 低电量全屏提醒
final class OverlayWindow: NSWindow { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { true } }
final class SwallowView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { Overlay.close() } }
    override func mouseDown(with e: NSEvent) {}; override func rightMouseDown(with e: NSEvent) {}; override func otherMouseDown(with e: NSEvent) {}
    override func scrollWheel(with e: NSEvent) {}
    override func performKeyEquivalent(with e: NSEvent) -> Bool { if e.keyCode == 53 { Overlay.close() }; return true }
}
enum Overlay {
    private(set) static var windows: [NSWindow] = []
    private static var timer: Timer?
    private(set) static var mode = ""
    static var isShowing: Bool { !windows.isEmpty }
    static func cleanScreen(seconds: TimeInterval = 60) {
        close(); mode = "clean"
        for sc in NSScreen.screens {
            let w = make(sc); w.backgroundColor = .black
            let host = NSHostingView(rootView: CleanHint(seconds: Int(seconds)))
            host.frame = w.contentView!.bounds; host.autoresizingMask = [.width, .height]
            w.contentView!.addSubview(host)
            windows.append(w)
        }
        present(seconds); NSCursor.hide()
    }
    static func showGlow(level: Int, seconds: TimeInterval = 30) {
        close(); mode = "glow"
        for sc in NSScreen.screens {
            let w = make(sc); w.backgroundColor = .clear; w.isOpaque = false
            let host = NSHostingView(rootView: GlowAlert(level: level))
            host.frame = w.contentView!.bounds; host.autoresizingMask = [.width, .height]
            w.contentView!.addSubview(host); windows.append(w)
        }
        present(seconds)
    }
    private static func make(_ sc: NSScreen) -> NSWindow {
        let w = OverlayWindow(contentRect: sc.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver; w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.isReleasedWhenClosed = false
        let v = SwallowView(frame: NSRect(origin: .zero, size: sc.frame.size)); v.autoresizingMask = [.width, .height]
        w.contentView = v
        return w
    }
    private static func present(_ seconds: TimeInterval) {
        NSApp.activate(ignoringOtherApps: true)
        for w in windows { w.orderFrontRegardless() }
        windows.first?.makeKeyAndOrderFront(nil); windows.first?.makeFirstResponder(windows.first?.contentView)
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in close() }
    }
    static func close() {
        timer?.invalidate(); timer = nil
        if mode == "clean" && !windows.isEmpty { NSCursor.unhide() }
        windows.forEach { $0.orderOut(nil) }; windows = []; mode = ""
    }
}
struct CleanHint: View {
    let seconds: Int
    @State private var shown = true
    var body: some View {
        ZStack {
            Color.black
            Text("擦屏模式 · 按 Esc 退出 · \(seconds) 秒后自动结束").font(.system(size: 15, weight: .medium)).foregroundColor(.white.opacity(0.55)).opacity(shown ? 1 : 0)
        }.onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { withAnimation(.easeOut(duration: 0.8)) { shown = false } } }
    }
}
struct GlowAlert: View {
    let level: Int
    @State private var pulse = false
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 0).strokeBorder(LinearGradient(colors: [.red, .orange, .red], startPoint: .top, endPoint: .bottom), lineWidth: pulse ? 34 : 16)
                .blur(radius: 22).opacity(pulse ? 0.95 : 0.55)
            VStack(spacing: 10) {
                Image(systemName: "battery.0").font(.system(size: 40)).foregroundColor(.red)
                Text("电量仅剩 \(level)%").font(.system(size: 26, weight: .bold))
                Text("请尽快接上电源 · 按 Esc 关闭").font(.system(size: 13)).foregroundColor(.secondary)
                Button("知道了") { Overlay.close() }.buttonStyle(PillButton())
            }.padding(28).background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial))
        }.onAppear { withAnimation(.easeInOut(duration: 1).repeatForever()) { pulse = true } }
    }
}

// MARK: - 菜单栏
final class StatusBar: NSObject, NSPopoverDelegate {
    static let shared = StatusBar()
    private(set) var item: NSStatusItem?
    let popover = NSPopover()
    private var subs: Set<AnyCancellable> = []
    private var lastMode = ""
    func setup() {
        popover.behavior = .transient; popover.animates = false; popover.delegate = self
        Monitor.shared.$s.receive(on: RunLoop.main).sink { [weak self] _ in self?.render() }.store(in: &subs)
        BatteryAlerts.shared.$settings.receive(on: RunLoop.main).sink { [weak self] _ in DispatchQueue.main.async { self?.render() } }.store(in: &subs)
        apply()
    }
    func apply() {
        let on = UIState.shared.menuBar
        Monitor.shared.menuBarEnabled = on
        if on, item == nil {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item?.button?.target = self; item?.button?.action = #selector(toggle)
            item?.button?.setAccessibilityIdentifier("statusItem")
            render()
        } else if !on, let i = item { popover.performClose(nil); NSStatusBar.system.removeStatusItem(i); item = nil }
    }
    func render() {
        guard let b = item?.button else { return }
        let s = Monitor.shared.s
        let mode = BatteryAlerts.shared.settings.menuIndicator
        defer { lastMode = mode }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        if mode == "battery", let p = s.battery {
            b.image = StatusBar.batteryIcon(p, charging: s.charging || s.onAC); b.title = ""; b.imagePosition = .imageOnly; lastMode = ""
        } else {
            let score = mode == "score"
            let img = NSImage(systemSymbolName: score ? "heart.text.square" : "cpu", accessibilityDescription: nil)
            img?.isTemplate = true
            if lastMode != mode { b.image = img; b.imagePosition = .imageLeading }
            let str = score ? " \(s.health.score)" : String(format: " %.0f%%", s.cpu)
            if b.title != str || lastMode != mode { b.attributedTitle = NSAttributedString(string: str, attributes: [.font: font]) }
        }
    }
    static func batteryIcon(_ p: Int, charging: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 30, height: 14), flipped: false) { r in
            let body = NSRect(x: 0.5, y: 1.5, width: 26, height: 11)
            NSColor.labelColor.withAlphaComponent(0.55).setStroke()
            let bp = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3); bp.lineWidth = 1; bp.stroke()
            NSBezierPath(roundedRect: NSRect(x: 27.5, y: 5, width: 2, height: 4), xRadius: 1, yRadius: 1).fill()
            let c: NSColor = p <= 10 ? .systemRed : (p <= 20 ? .systemOrange : (charging ? .systemGreen : NSColor(red: 0.18, green: 0.70, blue: 0.96, alpha: 1)))
            c.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 3, width: max(2, 23 * CGFloat(p) / 100), height: 8), xRadius: 1.5, yRadius: 1.5).fill()
            let t = NSAttributedString(string: "\(p)", attributes: [.font: NSFont.systemFont(ofSize: 8.5, weight: .bold), .foregroundColor: NSColor.white, .strokeColor: NSColor.black.withAlphaComponent(0.35), .strokeWidth: -2])
            let sz = t.size(); t.draw(at: NSPoint(x: body.midX - sz.width / 2, y: body.midY - sz.height / 2))
            return true
        }
        img.isTemplate = false; return img
    }
    @objc func toggle() {
        guard let b = item?.button else { return }
        if popover.isShown { popover.performClose(nil) } else { show(from: b) }
    }
    func show(from b: NSView) {
        if popover.contentViewController == nil { popover.contentViewController = NSHostingController(rootView: PanelView(m: Monitor.shared)) }
        Monitor.shared.panelOpen = true; Monitor.shared.sampleNow()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    func popoverDidClose(_ n: Notification) {
        Monitor.shared.panelOpen = false
        DispatchQueue.main.async { if !self.popover.isShown { self.popover.contentViewController = nil } }   // 关闭后释放面板视图
    }
}
