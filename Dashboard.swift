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

/// 图表数据线：正常时用青蓝，异常时才换成状态色
func levelColor(_ frac: Double, hi: Double = 0.85, mid: Double = 0.6) -> Color { frac >= hi ? bad : (frac >= mid ? warn : accent2) }
/// 图标底色：正常 / 注意 / 危险，只用状态色，不和品牌紫抢眼
func statusTint(_ frac: Double, hi: Double = 0.85, mid: Double = 0.6) -> Color { frac >= hi ? bad : (frac >= mid ? warn : good) }
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
                    .fill(color.opacity(0.10))
                Path { p in p.move(to: pts[0]); pts.dropFirst().forEach { p.addLine(to: $0) } }.stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                if let last = pts.last { Circle().fill(color).frame(width: 4, height: 4).position(last) }
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
            HStack(spacing: 6) {
                IconBadge(symbol: icon, tint: tint, size: 18)
                Text(title).font(DS.sub()).foregroundColor(.secondary)
                Spacer(minLength: 2)
                if !trailing.isEmpty { Text(trailing).font(DS.cap()).foregroundColor(.secondary).lineLimit(1) }
            }
            content
        }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).card()
    }
}

struct BigValue: View {
    let value: String; var unit: String = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value).font(DS.hero())
            if !unit.isEmpty { Text(unit).font(DS.sub(.medium)).foregroundColor(.secondary) }
        }
    }
}

struct Chip: View {
    let icon: String; let text: String
    var body: some View {
        HStack(spacing: 4) { Image(systemName: icon).font(DS.cap()); Text(text).font(DS.cap()).lineLimit(1) }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous).fill(Color.primary.opacity(0.05)))
            .foregroundColor(.secondary)
    }
}

/// 健康分圆环：全 App 唯一保留渐变的地方，呼应图标那道紫→蓝弧线
struct ScoreRing: View {
    let score: Int; var size: CGFloat = 54; var light = true
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.10), lineWidth: 4)
            Circle().trim(from: 0, to: CGFloat(score) / 100)
                .stroke(LinearGradient(colors: [accent2, accent], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)").font(DS.num(size * 0.32, .semibold)).foregroundColor(.primary)
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
        guard p.id > 1, p.id != getpid(), confirmQuit(p) else { return false }
        let ok: Bool
        if let app = NSRunningApplication(processIdentifier: p.id) { ok = app.terminate() } else { ok = kill(p.id, SIGTERM) == 0 }
        if ok { OperationCheck.wait(until: { !OperationCheck.processExists(p.id) }) { verified in if verified { CleanStats.shared.addQuit(memMB: p.memMB) } } }
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
    @State private var showApps = false
    var compact = false
    private var s: Snapshot { m.s }
    private var top: ProcInfo? { s.top.max { $0.cpu < $1.cpu } }

    var body: some View {
        VStack(spacing: DS.cardGap) {
            Grid(horizontalSpacing: DS.cardGap, verticalSpacing: DS.cardGap) {
                GridRow { systemTile; cpuTile; gpuTile }
                if compact {
                    GridRow { memoryTile; networkTile; topTile }
                } else {
                    GridRow { memoryTile; batteryTile; fanTile }
                    GridRow { diskTile; networkTile; topTile }
                }
            }
            if compact {
                HStack(spacing: DS.cardGap) {
                    MetricTile(title: "磁盘", symbol: "internaldrive", tint: DS.metric.disk,
                               value: s.diskTotalGB > 0 ? String(format: "%.0f", s.diskFreeGB) : nil, unit: "GB 可用",
                               stats: [MetricStat("总量", String(format: "%.0f GB", s.diskTotalGB))], compact: true)
                    MetricTile(title: "风扇", symbol: "fan", tint: DS.metric.fan,
                               value: s.fans?.max().map { String(format: "%.0f", $0) }, unit: "RPM",
                               stats: [MetricStat("状态", "仅读取 · 系统自动控制")], compact: true)
                    MetricTile(title: "电池", symbol: "battery.75", tint: DS.metric.battery,
                               value: s.battery.map(String.init), unit: "%",
                               stats: [MetricStat("状态", batteryState)], compact: true)
                }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("monitor.metrics")
    }
    var systemTile: some View {
        MetricTile(title: "系统状态", symbol: "waveform.path.ecg", tint: accentText,
                   value: s.uptime > 0 ? (s.health.status == "一切正常" ? "不卡" : "需关注") : "等待采样", note: s.uptime > 0 ? "健康分 \(s.health.score)" : "尚无读数",
                   stats: [MetricStat("结论", s.health.status), MetricStat("依据", "现有健康分与压力规则")], textValue: true)
    }
    var cpuTile: some View {
        MetricTile(title: "CPU", symbol: "cpu", tint: DS.metric.cpu,
                   value: m.cpuHist.isEmpty ? nil : String(format: "%.0f", s.cpu), unit: "%", note: s.cpuTemp.map { String(format: "均温 %.0f°C", $0) } ?? "温度 —",
                   series: m.cpuHist, maxValue: 100,
                   stats: [MetricStat("1 分钟负载", String(format: "%.2f（非百分比）", s.load.first ?? 0)),
                           MetricStat("核心", "\(s.pCores) 性能核 · \(s.eCores) 能效核")],
                   valueColor: s.cpu >= 85 ? bad : (s.cpu >= 60 ? warn : .primary))
    }
    var gpuTile: some View {
        MetricTile(title: "GPU", symbol: "square.stack.3d.up", tint: DS.metric.gpu,
                   value: s.gpu.map { String(format: "%.0f", $0) }, unit: "%",
                   note: s.gpuTemp.map { String(format: "均温 %.0f°C", $0) } ?? "温度 —",
                   series: s.gpu == nil ? [] : m.gpuHist, maxValue: 100,
                   stats: [MetricStat("核心", s.gpuCores > 0 ? "\(s.gpuCores) 核" : "—"),
                           MetricStat("来源", "驱动报告的设备利用率")], unavailableReason: "显卡驱动未提供利用率")
    }
    var memoryTile: some View {
        MetricTile(title: "内存", symbol: "memorychip", tint: DS.metric.memory,
                   value: s.memTotalGB > 0 ? String(format: "%.1f", s.memFraction * 100) : nil, unit: "%",
                   note: "压力 " + Fmt.pressure(s.memPressure).0, fraction: s.memTotalGB > 0 ? s.memFraction : nil,
                   stats: [MetricStat("已用 / 总量", String(format: "%.1f / %.0f GiB", s.memUsedGB, s.memTotalGB)),
                           MetricStat("交换", String(format: "%.1f GiB", s.swapUsedGB))],
                   valueColor: s.memPressure >= 4 ? bad : (s.memPressure >= 2 ? warn : .primary))
    }
    var batteryState: String {
        s.charging ? "正在充电" : (s.onAC ? (s.batteryFullyCharged ? "已充满" : "接电未充") : "电池供电")
    }
    var batteryTile: some View {
        MetricTile(title: "电池", symbol: s.charging ? "battery.100.bolt" : "battery.75", tint: DS.metric.battery,
                   value: s.battery.map(String.init), unit: "%", note: s.batteryHealth.map { "健康度 \($0)%" } ?? "健康度 —",
                   fraction: s.battery.map { Double($0) / 100 },
                   stats: [MetricStat("状态", s.battery == nil ? "未检测到内置电池" : batteryState),
                           MetricStat("循环 / 温度", (s.cycles.map { "\($0) 次" } ?? "—") + " · " + (s.batteryTemp.map { String(format: "%.0f°C", $0) } ?? "—"))],
                   unavailableReason: "没有内置电池或系统未提供电量")
    }
    var fanTile: some View {
        let fans = s.fans ?? []
        return MetricTile(title: "风扇", symbol: "fan", tint: DS.metric.fan,
                          value: fans.max().map { String(format: "%.0f", $0) }, unit: "RPM", note: "\(fans.count) 个 · 仅读取",
                          fraction: fans.max().flatMap { s.fanMax > 0 ? $0 / s.fanMax : nil },
                          stats: fans.isEmpty ? [MetricStat("说明", "未检测到可读风扇"), MetricStat("控制", "由系统自动调节")]
                            : [MetricStat("各风扇", fans.prefix(2).map { String(format: "%.0f", $0) }.joined(separator: " / ") + " RPM"),
                               MetricStat("主值", "最快风扇 · 系统自动控制")],
                          unavailableReason: "无风扇机型或硬件未提供转速")
    }
    var diskTile: some View {
        MetricTile(title: "磁盘", symbol: "internaldrive", tint: DS.metric.disk,
                   value: s.diskTotalGB > 0 ? String(format: "%.0f", s.diskFreeGB) : nil, unit: "GB 可用", note: "启动盘",
                   fraction: s.diskTotalGB > 0 ? s.diskUsedFraction : nil,
                   stats: [MetricStat("已用 / 总量", String(format: "%.1f / %.1f GB", s.diskTotalGB - s.diskFreeGB, s.diskTotalGB)),
                           MetricStat("已用比例", String(format: "%.1f%%", s.diskUsedFraction * 100))])
    }
    var networkTile: some View {
        let rate = Fmt.rate(s.downBps).split(separator: " ", maxSplits: 1).map(String.init)
        return Button { showApps = true } label: {
            MetricTile(title: "网络", symbol: "arrow.down", tint: DS.metric.network,
                       value: s.netIface.isEmpty ? nil : rate.first, unit: rate.count > 1 ? rate[1] + " ↓" : "", note: s.netKind,
                       series: s.netIface.isEmpty ? [] : m.downHist,
                       stats: [MetricStat("上行", Fmt.rate(s.upBps) + " ↑"),
                               MetricStat("接口 / 代理", s.netIface + " · " + (s.proxy.isEmpty ? "—" : s.proxy))],
                       unavailableReason: "当前没有可用网络接口")
        }.buttonStyle(.plain).help("查看正在联网的应用").accessibilityIdentifier("net.rates")
            .popover(isPresented: $showApps, arrowEdge: .bottom) { AppTrafficPopover() }
    }
    var topTile: some View {
        MetricTile(title: "当前高占用", symbol: "chart.bar", tint: DS.metric.cpu,
                   value: top?.name, note: "当前采样",
                   stats: [MetricStat("CPU 核当量", top.map { String(format: "%.2f 核", $0.cpu / 100) } ?? "—"),
                           MetricStat("当前内存", top.map { String(format: "%.1f GiB", $0.memMB / 1024) } ?? "—")],
                   unavailableReason: "等待首次进程采样", textValue: true)
    }
}

struct BatteryTile: View {
    let s: Snapshot
    var body: some View {
        let flow = PowerFlowCalc.fromSnapshot(s)
        let mins = PowerFlowCalc.minutesToFull(percent: s.battery, fullMah: s.fullMah, voltageV: s.batteryVoltageV, chargeWatts: flow.chargeWatts)
        Tile(icon: s.charging ? "battery.100.bolt" : "battery.75", title: "电池", tint: batteryColor(s.battery ?? 100), trailing: s.batteryHealth.map { "健康度 \($0)%" } ?? "") {
            if let b = s.battery {
                HStack(alignment: .center, spacing: 10) {
                    BigValue(value: "\(b)", unit: "%")
                    Bar(frac: Double(b) / 100, color: batteryColor(b), height: 8)
                }
                Text(stateText).font(.system(size: 10)).foregroundColor(.secondary)
                // 面板紧凑条（单行版，与电池页功率标签同一口径，面板高度检查上限 1000pt，单行更安全）
                HStack(spacing: 8) {
                    if s.charging, let mm = mins { Text("预计 \(fmtMinutes(mm)) 充满（估算）").font(.system(size: 10)).foregroundColor(.secondary) }
                    Text("充电 \(fmtW(flow.chargeWatts))").font(.system(size: 10)).foregroundColor(.secondary)
                    Text("系统 \(fmtW(flow.systemWatts))").font(.system(size: 10)).foregroundColor(.secondary)
                }.accessibilityIdentifier("panel.battery.compact")
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
    /// 进程行只显示 16 pt，缓存固定 2x 小图，避免保留每个应用的整套大尺寸表示。
    static func thumbnail(_ source: NSImage) -> NSImage? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: 16, height: 16)
        let image = NSImage(size: bitmap.size); image.addRepresentation(bitmap); image.isTemplate = source.isTemplate
        return image
    }
    static func icon(_ pid: Int32) -> NSImage? {
        if let v = c[pid] { return v }
        if c.count > 100 { c.removeAll() }
        let image = autoreleasepool { NSRunningApplication(processIdentifier: pid)?.icon.flatMap(thumbnail) }
        c[pid] = image; return image
    }
}
struct ProcList: View {
    static let actionWidth: CGFloat = 44
    @ObservedObject var m: Monitor
    @ObservedObject var feedback = OperationFeedback.shared
    var limit = 5
    var selection: Int? = nil
    var onSelect: ((Int) -> Void)? = nil
    var onMore: ((ProcInfo) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("高占用进程").font(DS.cap(.semibold)).foregroundColor(.secondary)
                Spacer()
                Text("CPU").font(DS.cap()).foregroundColor(.secondary).frame(width: 40, alignment: .trailing)
                Text("内存").font(DS.cap()).foregroundColor(.secondary).frame(width: 54, alignment: .trailing)
                Color.clear.frame(width: ProcList.actionWidth, height: 1)
            }.padding(.horizontal, 6).padding(.top, 2).accessibilityHidden(true)
            if m.s.top.isEmpty { StateLine(kind: .loading, text: "正在统计进程占用", id: "proc.state").padding(4) }
            ForEach(Array(m.s.top.prefix(limit).enumerated()), id: \.element.id) { i, p in
                let on = selection == i
                HStack(spacing: 8) {
                    if let ic = IconCache.icon(p.id) { Image(nsImage: ic).resizable().frame(width: 16, height: 16) }
                    else { IconBadge(symbol: "gearshape", tint: Color(nsColor: .secondaryLabelColor), size: 16, selected: on) }
                    Text(p.name).font(DS.sub()).lineLimit(1).foregroundColor(on ? .white : .primary)
                    Spacer(minLength: 4)
                    Text(String(format: "%.1f%%", p.cpu)).font(DS.num(11, .medium))
                        .foregroundColor(on ? .white : ProcessCPU.color(p.cpu)).frame(width: 40, alignment: .trailing)
                    Text(Fmt.mem(p.memMB)).font(DS.num(11, .regular))
                        .foregroundColor(on ? Color.white.opacity(0.85) : .secondary).frame(width: 54, alignment: .trailing)
                    Group {
                        if let t = ProcActions.fix(for: p).short {
                            Text(t).font(DS.cap()).foregroundColor(on ? .white : .secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous)
                                    .fill(on ? Color.white.opacity(0.18) : Color.primary.opacity(0.05)))
                        } else { Color.clear.frame(height: 1) }
                    }.frame(width: ProcList.actionWidth, alignment: .trailing)
                }
                .padding(.horizontal, 6).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous)
                    .fill(on ? AnyShapeStyle(accent) : AnyShapeStyle(Color.clear)))
                .contentShape(Rectangle())
                .onTapGesture { onSelect?(i) }
                .contextMenu { if onMore != nil { Button("更多操作…") { onMore?(p) } } }
            }
            if !feedback.note.isEmpty { Text(feedback.note).font(DS.cap()).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true).padding(4) }
        }
    }
}

/// 快捷操作：列表项 + 开关状态 + 快捷键提示
struct QuickActions: View {
    @ObservedObject var ui = UIState.shared
    @ObservedObject var ka = KeepAwake.shared
    @ObservedObject var st = CleanStats.shared
    @ObservedObject var cc = ChargeClient.shared
    @ObservedObject var dock = DockMode.shared
    var showStats = true
    var body: some View {
        VStack(spacing: 1) {
            ForEach(QuickActionList.all()) { a in
                let hasSwitch = a.id == "act.awake" || a.id == "act.dock" || a.id == "act.charge"
                Button { a.run() } label: {
                    HStack(spacing: 8) {
                        IconBadge(symbol: a.symbol, tint: a.isOn() ? good : accent, size: 18)
                        Text(a.title).font(DS.sub(.medium))
                        Spacer(minLength: 4)
                        if !hasSwitch && !a.stateLabel().isEmpty {
                            Text(a.stateLabel()).font(DS.cap()).foregroundColor(.secondary).lineLimit(1)
                        }
                        if hasSwitch {
                            Capsule().fill(a.isOn() ? good : Color.primary.opacity(0.12))
                                .frame(width: 22, height: 13)
                                .overlay(alignment: a.isOn() ? .trailing : .leading) {
                                    Circle().fill(a.isOn() ? Color.white : Color(nsColor: .tertiaryLabelColor))
                                        .frame(width: 11, height: 11).padding(1)
                                }
                        }
                        Kbd(text: a.hint)
                    }
                    .padding(.horizontal, 6).frame(height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier(a.id)
            }
            if showStats {
                Hairline().padding(.vertical, 4)
                HStack(spacing: 0) {
                    stat("\(st.optimized)", "项已优化"); Divider().frame(height: 18)
                    stat("\(st.quitApps)", "个应用已退出"); Divider().frame(height: 18)
                    stat(Fmt.mem(st.freedMB), "内存已释放")
                }
            }
        }.onAppear { if cc.phase != .ready { cc.refresh() } }   // 只读状态，不会安装助手
    }
    func stat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 0) {
            Text(v).font(DS.num(13, .semibold))
            Text(l).font(DS.cap(.regular)).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

// MARK: - 菜单栏面板
enum PanelHeight {
    /// 面板窗口高度 = 内容高度，上限为屏幕可见高度 -30。
    /// 之前 v2.1 错把窗口高写成可见高度 -30：大屏上内容只有 950 左右，窗口却撑到 1400+，
    /// 底部出现大面积空白；之前写死 940 则内容放不下要滚动。正确做法是按内容定高、按屏幕封顶。
    static func height(contentHeight: CGFloat, visibleHeight: CGFloat) -> CGFloat {
        guard contentHeight > 0 else { return max(600, visibleHeight - 30) }
        return min(contentHeight, max(600, visibleHeight - 30))
    }
}
/// 测量面板内容高度：用 PreferenceKey 把 ScrollView 里内容的真实高度传回 PanelView
struct PanelContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
struct PanelView: View {
    @ObservedObject var m: Monitor
    @State private var contentHeight: CGFloat = 640
    var body: some View {
        let h = PanelHeight.height(contentHeight: contentHeight, visibleHeight: NSScreen.main?.visibleFrame.height ?? 900)
        ScrollView(showsIndicators: false) {
            PanelContent(m: m)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: PanelContentHeightKey.self, value: geo.size.height)
                })
        }
        .frame(width: PanelLayout.width, height: h)
        .onPreferenceChange(PanelContentHeightKey.self) { v in
            if v > 400 && v != contentHeight { contentHeight = v }
        }
    }
}

/// 面板内的键盘处理（↑↓ 选进程、↵ 处理、⌘K 更多操作）
final class PanelKeys {
    static let shared = PanelKeys()
    var handler: ((NSEvent) -> Bool)?
}
struct PanelKeyRouter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PanelKeyView() }
    func updateNSView(_ v: NSView, context: Context) {}
}
final class PanelKeyView: NSView {
    private var monitor: Any?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard monitor == nil, let w = window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.window === w, let h = PanelKeys.shared.handler else { return e }
            return h(e) ? nil : e
        }
    }
    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
}

/// 面板里的一行指标：图标、名称、数值、迷你曲线
@MainActor struct PanelMetric: View {
    let symbol: String; let title: String; let value: String; let tint: Color
    var detail = ""
    var series: [Double]? = nil
    var frac: Double? = nil
    var maxValue: Double? = nil
    var valueColor: Color = .primary
    var body: some View {
        HStack(spacing: 8) {
            IconBadge(symbol: symbol, tint: tint, size: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(DS.sub()).foregroundColor(.secondary)
                    Spacer(minLength: 4)
                    Text(value).font(DS.num(12)).foregroundColor(valueColor)
                }
                Text(detail).font(DS.cap()).foregroundColor(.secondary).lineLimit(1)
            }.frame(width: 182)
            Group {
                if let series, !series.isEmpty { Spark(values: series, color: tint, maxValue: maxValue) }
                else if let frac { Bar(frac: frac, color: tint, height: 3).frame(maxHeight: .infinity) }
                else { Color.clear }
            }.frame(maxWidth: .infinity).frame(height: 25).accessibilityHidden(true)
        }.frame(height: 40).padding(.horizontal, 4)
            .accessibilityElement(children: .ignore).accessibilityLabel(title + "，" + value + "，" + detail)
    }
}
// 2.8：菜单栏面板 PanelContent 已移到 V28Panel.swift（双列）

/// 面板里的 ⌘K 更多操作
struct PanelMore: View {
    let p: ProcInfo
    @ObservedObject var m: Monitor
    var close: () -> Void
    var body: some View {
        let f = ProcActions.fix(for: p)
        ZStack {
            Color.black.opacity(0.14).onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    IconBadge(symbol: "bolt", size: 16)
                    Text(p.name).font(DS.sub(.medium)).lineLimit(1)
                    Spacer()
                    Kbd(text: "esc")
                }.padding(8)
                Hairline()
                VStack(spacing: 1) {
                    if let t = f.title {
                        actionRow(t, "↵", destructive: true) { close(); DispatchQueue.main.async { FixRunner.perform(f) } }
                    }
                    actionRow("复制进程名", nil) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(p.name, forType: .string); close()
                    }
                    actionRow("复制 PID \(p.id)", nil) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(p.id)", forType: .string); close()
                    }
                    actionRow("刷新列表", nil) { close(); m.sampleNow() }
                }.padding(4)
            }
            .frame(width: 280)
            .background(RoundedRectangle(cornerRadius: DS.r.card, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: DS.r.card, style: .continuous).strokeBorder(DS.borderStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        }
    }
    func actionRow(_ t: String, _ k: String?, destructive: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack {
                Text(t).font(DS.body()).foregroundColor(destructive ? bad : .primary)
                Spacer()
                if let k { Kbd(text: k) }
            }.padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// MARK: - 主窗口：实时监控
struct DashboardView: View {
    @ObservedObject var m: Monitor
    var body: some View {
        GeometryReader { geometry in
            PageScroll {
                VStack(alignment: .leading, spacing: DS.cardGap) {
                    HStack(alignment: .center) {
                        PageHeader(title: "实时监控", sub: "系统读数 · 当前状态与来源")
                        Spacer(minLength: 8)
                        ActiveStatusPills()
                    }
                    KPIStrip(items: [MetricStat("芯片", m.s.chip + " · \(m.s.ramGB) GiB"),
                                     MetricStat("系统", m.s.osVersion), MetricStat("开机", Fmt.uptime(m.s.uptime)),
                                     MetricStat("网络", m.s.netKind + " · " + m.s.proxy)])
                    MetricTiles(m: m, compact: geometry.size.height < 690)
                    Footnote(text: "前台每 \(Int(Monitor.detailInterval)) 秒刷新，后台每 \(Int(Monitor.lightInterval)) 秒采样；磁盘为十进制 GB，内存为二进制 GiB。温度为已识别传感器均温；高占用为当前采样，不代表历史峰值。")
                }.padding(16)
            }
        }
        .onAppear { m.dashboardShown = true }.onDisappear { m.dashboardShown = false }
    }
}

struct ActiveStatusPills: View {
    @ObservedObject var ka = KeepAwake.shared
    @ObservedObject var dock = DockMode.shared
    @ObservedObject var charge = ChargeClient.shared
    @State private var showActions = false
    var body: some View {
        HStack(spacing: 6) {
            if charge.phase == .ready && charge.st.settings.enabled {
                Button { Nav.shared.sel = .battery } label: { StatusPill(title: "充电上限 \(charge.st.settings.limit)%", tint: DS.metric.battery) }
                    .buttonStyle(.plain).help("打开电池设置")
            }
            if dock.enabled {
                Button { Nav.shared.sel = .settings } label: { StatusPill(title: dock.active ? "接显示器 · 生效" : "接显示器 · 待机") }
                    .buttonStyle(.plain).help("查看常驻模式设置")
            }
            if ka.on {
                Button { Nav.shared.sel = .settings } label: { StatusPill(title: "常亮") }
                    .buttonStyle(.plain).help("查看常亮设置")
            }
            Button { showActions = true } label: { Image(systemName: "ellipsis.circle") }
                .buttonStyle(.plain).foregroundColor(.secondary).help("快捷操作")
                .accessibilityLabel("快捷操作").accessibilityIdentifier("monitor.actions")
        }
        .sheet(isPresented: $showActions) {
            VStack(alignment: .leading, spacing: 12) {
                Text("快捷操作").font(DS.title())
                QuickActions(showStats: false)
                Button("完成") { showActions = false }.buttonStyle(PillButton(filled: false))
                    .accessibilityIdentifier("monitor.actions.close")
            }.padding(16).frame(width: 360)
        }
    }
}

// MARK: - 擦屏 / 低电量全屏提醒
final class OverlayWindow: NSWindow { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { true } }
final class SwallowView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { if e.keyCode == Key.escape { Overlay.close() } }
    override func mouseDown(with e: NSEvent) {}; override func rightMouseDown(with e: NSEvent) {}; override func otherMouseDown(with e: NSEvent) {}
    override func scrollWheel(with e: NSEvent) {}
    override func performKeyEquivalent(with e: NSEvent) -> Bool { if e.keyCode == Key.escape { Overlay.close() }; return true }
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
            Text("擦屏模式 · 按 Esc 退出 · \(seconds) 秒后自动结束").font(.system(size: 13, weight: .medium)).foregroundColor(.white.opacity(0.55)).opacity(shown ? 1 : 0)
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
                Image(systemName: "battery.0").font(.system(size: 17)).foregroundColor(.red)
                Text("电量仅剩 \(level)%").font(.system(size: 17, weight: .bold))
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
        if mode == "net" {
            if lastMode != mode { let img = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil); img?.isTemplate = true; b.image = img; b.imagePosition = .imageLeading }
            let str = " ↓" + StatusBar.short(s.downBps) + " ↑" + StatusBar.short(s.upBps)
            if b.title != str || lastMode != mode { b.attributedTitle = NSAttributedString(string: str, attributes: [.font: font]) }
        } else if mode == "battery", let p = s.battery {
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
    static func short(_ bps: Double) -> String {
        if bps >= 1_048_576 { return String(format: "%.1fM", bps / 1_048_576) }
        return String(format: "%.0fK", bps / 1024)
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
