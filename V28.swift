// 2.8 精致化：统一状态与单位（U04）、电池功率趋势（B03）、能耗采样覆盖（B05）、显示器色彩模式语义（D02）
import SwiftUI
import AppKit

// MARK: - U04 单位与时间（全 App 统一口径）
// 约定：数字与单位之间空一格（12.3 W、980 MB、6500 K），百分号、温度紧贴（54%、46°C）；
// 读不到一律显示「—」并在旁边说明原因，不显示看似精确的 0。
extension Fmt {
    static let dash = "—"
    /// 功率：< 10 W 保留 1 位小数，≥ 10 W 也保留 1 位（功率变化小，整数会掩盖趋势）
    static func watts(_ w: Double?) -> String { w.map { String(format: "%.1f W", $0) } ?? dash }
    static func percent(_ p: Double?, digits: Int = 0) -> String { p.map { String(format: "%.\(digits)f%%", $0) } ?? dash }
    /// 相对时间：用于「更新于」「最新样本」
    static func ago(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "尚未更新" }
        let s = now.timeIntervalSince(d)
        if s < 5 { return "刚刚" }
        if s < 60 { return "\(Int(s)) 秒前" }
        if s < 3600 { return "\(Int(s / 60)) 分钟前" }
        if s < 86400 { return "\(Int(s / 3600)) 小时前" }
        return clock(d, now: now)
    }
    /// 时刻：今天只显示时分，其他日期带月-日
    static func clock(_ d: Date, now: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "HH:mm" : "MM-dd HH:mm"
        return f.string(from: d)
    }
    /// 时长：35 分钟 / 18 小时 40 分 / 2 天 3 小时
    static func span(_ seconds: Double) -> String {
        let m = Int((max(0, seconds) / 60).rounded())
        if m < 60 { return "\(m) 分钟" }
        let h = m / 60, mm = m % 60
        if h < 24 { return mm == 0 ? "\(h) 小时" : "\(h) 小时 \(mm) 分" }
        let d = h / 24, hh = h % 24
        return hh == 0 ? "\(d) 天" : "\(d) 天 \(hh) 小时"
    }
}

// MARK: - U04 统一状态：加载 / 空白 / 未知 / 过期 / 失败 / 完成
enum StateKind: Equatable { case loading, empty, unknown, stale, failed, done
    var symbol: String {
        switch self {
        case .loading: return "hourglass"
        case .empty: return "tray"
        case .unknown: return "questionmark.circle"
        case .stale: return "clock.badge.exclamationmark"
        case .failed: return "exclamationmark.triangle.fill"
        case .done: return "checkmark.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .loading, .empty, .unknown: return .secondary
        case .stale: return warn
        case .failed: return bad
        case .done: return good
        }
    }
    /// 朗读前缀，让屏幕阅读器也能区分状态
    var spoken: String {
        switch self {
        case .loading: return "正在读取"; case .empty: return "暂无内容"; case .unknown: return "未取得"
        case .stale: return "读数已过期"; case .failed: return "失败"; case .done: return "已完成"
        }
    }
}

/// 失败或空白后的下一步：重试、刷新、打开系统设置
struct StateAction: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let run: () -> Void
    static func retry(_ run: @escaping () -> Void) -> StateAction { StateAction(title: "重试", symbol: "arrow.clockwise", run: run) }
    static func refresh(_ run: @escaping () -> Void) -> StateAction { StateAction(title: "刷新", symbol: "arrow.clockwise", run: run) }
    static func openSettings(_ title: String = "打开系统设置", url: String) -> StateAction {
        StateAction(title: title, symbol: "gearshape", run: { if let u = URL(string: url) { NSWorkspace.shared.open(u) } })
    }
}

struct StateLine: View {
    let kind: StateKind
    let text: String
    var detail = ""
    var actions: [StateAction] = []
    var updated: Date? = nil
    var id = ""
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if kind == .loading { ProgressView().controlSize(.small).scaleEffect(0.8) }
                else { Image(systemName: kind.symbol).font(DS.sub(.semibold)).foregroundColor(kind.tint) }
            }.frame(width: 16, height: 16).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(DS.sub(.medium)).foregroundColor(kind == .failed ? DS.text.bad : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty {
                    Text(detail).font(DS.cap(.regular)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let updated { Text("更新于 " + Fmt.ago(updated)).font(DS.cap(.regular)).foregroundColor(DS.text.secondary) }
            }
            Spacer(minLength: 4)
            ForEach(actions) { a in
                Button { a.run() } label: { Label(a.title, systemImage: a.symbol).font(DS.cap(.medium)) }
                    .buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
                    .accessibilityIdentifier(id.isEmpty ? "state.action" : id + ".action")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.spoken + "，" + text + (detail.isEmpty ? "" : "，" + detail))
        .accessibilityIdentifier(id.isEmpty ? "state.line" : id)
    }
}

/// 「更新于 X 秒前」：每 5 秒刷新一次文字，不触发数据采样
struct UpdatedText: View {
    let date: Date?
    var prefix = "更新于 "
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            Text(prefix + Fmt.ago(date, now: ctx.date)).font(DS.cap(.regular)).foregroundColor(DS.text.secondary).monospacedDigit()
        }
    }
}

// MARK: - B03 电池功率趋势（带时间戳；断档、过期和电源切换留空，不补数、不拼线）
struct PowerSample: Equatable {
    let t: Date
    let onAC: Bool
    let inputW: Double?      // 电源遥测 DC 输入，只在接电时有
    let chargeW: Double?     // 充入电池（电压 × 正电流）
    let dischargeW: Double?  // 电池放电（电压 × 负电流）
    var dischargeStatus: String? {
        guard dischargeW == nil else { return nil }
        return onAC ? "未放电" : "未取得"
    }
}

final class PowerHistory: ObservableObject {
    static var shared = PowerHistory()
    /// 两个样本间隔超过这个值视为断档（后台每 30 秒一次，前台每 10 秒一次）
    static let gapSeconds: TimeInterval = 75
    static let keep: TimeInterval = 2 * 3600
    @Published private(set) var samples: [PowerSample] = []
    private(set) var startedAt: Date?
    private var lastStamp: Date?

    /// 从快照记录一次；同一个电池读数时间戳只记一次，读数过期（> 30 秒）不记
    func record(_ s: Snapshot, now: Date = Date()) {
        guard s.battery != nil, let stamp = s.batteryPowerUpdated, stamp != lastStamp, now.timeIntervalSince(stamp) < 30 else { return }
        lastStamp = stamp
        let flow = PowerFlowCalc.fromSnapshot(s)
        add(PowerSample(t: stamp, onAC: flow.onAC, inputW: flow.onAC ? flow.inputWatts : nil,
                        chargeW: flow.chargeWatts, dischargeW: flow.dischargeWatts), now: now)
    }
    func add(_ p: PowerSample, now: Date = Date()) {
        if startedAt == nil { startedAt = p.t }
        samples.append(p)
        let cut = now.addingTimeInterval(-Self.keep)
        if let i = samples.firstIndex(where: { $0.t >= cut }), i > 0 { samples.removeFirst(i) }
        if samples.count > 1500 { samples.removeFirst(samples.count - 1500) }
    }
    func reset() { samples = []; startedAt = nil; lastStamp = nil }

    struct Window: Equatable {
        let start: Date, end: Date
        let points: [PowerSample]
        let gaps: Int            // 断档段数
        let switches: [Date]     // 接电 / 拔电的时刻
        var latest: PowerSample? { points.last }
    }
    /// 取最近 `seconds` 秒的数据，同时统计断档与电源切换
    static func window(_ all: [PowerSample], seconds: TimeInterval, now: Date) -> Window {
        let start = now.addingTimeInterval(-seconds)
        let pts = all.filter { $0.t >= start && $0.t <= now }
        var gaps = 0, switches: [Date] = []
        for (a, b) in zip(pts, pts.dropFirst()) {
            if b.t.timeIntervalSince(a.t) > gapSeconds { gaps += 1 }
            if a.onAC != b.onAC { switches.append(b.t) }
        }
        return Window(start: start, end: now, points: pts, gaps: gaps, switches: switches)
    }
    /// 把某一条曲线切成「连续段」：断档或电源切换处断开；该段读不到值的点留空
    static func segments(_ pts: [PowerSample], _ value: (PowerSample) -> Double?) -> [[(Date, Double)]] {
        var out: [[(Date, Double)]] = [], cur: [(Date, Double)] = []
        var prev: PowerSample?
        for p in pts {
            let broken = prev.map { p.t.timeIntervalSince($0.t) > gapSeconds || $0.onAC != p.onAC } ?? false
            if broken, !cur.isEmpty { out.append(cur); cur = [] }
            if let v = value(p) { cur.append((p.t, v)) } else if !cur.isEmpty { out.append(cur); cur = [] }
            prev = p
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

/// 多条折线：按时间定位；每条线只连同一段内的点，段与段之间留空
struct PowerTrendChart: View {
    let window: PowerHistory.Window
    var body: some View {
        let lines: [(Color, [[(Date, Double)]])] = [
            (DS.metric.network, PowerHistory.segments(window.points) { $0.inputW }),
            (good, PowerHistory.segments(window.points) { $0.chargeW }),
            (warn, PowerHistory.segments(window.points) { $0.dischargeW })
        ]
        let mx = max(window.points.flatMap { [$0.inputW, $0.chargeW, $0.dischargeW].compactMap { $0 } }.max() ?? 1, 1) * 1.1
        GeometryReader { g in
            let span = max(window.end.timeIntervalSince(window.start), 1)
            let x: (Date) -> CGFloat = { t in g.size.width * CGFloat(t.timeIntervalSince(window.start) / span) }
            let y: (Double) -> CGFloat = { v in g.size.height * (1 - CGFloat(min(v, mx) / mx)) }
            ZStack(alignment: .topLeading) {
                ForEach([0.25, 0.5, 0.75], id: \.self) { f in
                    Path { p in p.move(to: CGPoint(x: 0, y: g.size.height * f)); p.addLine(to: CGPoint(x: g.size.width, y: g.size.height * f)) }
                        .stroke(DS.separator, lineWidth: 1)
                }
                ForEach(Array(window.switches.enumerated()), id: \.offset) { _, t in
                    Path { p in p.move(to: CGPoint(x: x(t), y: 0)); p.addLine(to: CGPoint(x: x(t), y: g.size.height)) }
                        .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Path { p in
                        for seg in line.1 {
                            guard let first = seg.first else { continue }
                            p.move(to: CGPoint(x: x(first.0), y: y(first.1)))
                            if seg.count == 1 { p.addEllipse(in: CGRect(x: x(first.0) - 1.5, y: y(first.1) - 1.5, width: 3, height: 3)) }
                            for q in seg.dropFirst() { p.addLine(to: CGPoint(x: x(q.0), y: y(q.1))) }
                        }
                    }.stroke(line.0, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
                Text(String(format: "%.0f W", mx)).font(DS.cap(.regular)).foregroundColor(DS.text.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("功率趋势，\(window.points.count) 个样本，\(window.gaps) 段断档，\(window.switches.count) 次电源切换")
    }
}

struct PowerTrendCard: View {
    @ObservedObject var h: PowerHistory
    @State private var minutes = 30
    var now: Date? = nil   // 截图时固定时间
    init(history: PowerHistory = .shared, now: Date? = nil) {
        _h = ObservedObject(wrappedValue: history)
        self.now = now
    }
    var body: some View {
        let t = now ?? Date()
        let w = PowerHistory.window(h.samples, seconds: Double(minutes * 60), now: t)
        return Card(title: "功率趋势", icon: "chart.xyaxis.line") {
            HStack {
                legend("输入", DS.metric.network, w.latest?.inputW, w.latest.map { !$0.onAC } ?? false ? "未接电" : nil)
                legend("充入电池", good, w.latest?.chargeW, w.latest.map { $0.chargeW == nil } ?? false ? "未充电" : nil)
                legend("电池放电", warn, w.latest?.dischargeW, w.latest?.dischargeStatus)
                Spacer(minLength: 6)
                InlineSegment(items: [("30 分钟", 30), ("2 小时", 120)], selection: $minutes).fixedSize()
            }
            if w.points.count < 2 {
                StateLine(kind: h.samples.isEmpty ? .loading : .empty,
                          text: h.samples.isEmpty ? "正在收集功率样本" : "这段时间只有 \(w.points.count) 个样本",
                          detail: "打开面板或电池页时每 10 秒记一次，后台每 30 秒一次；App 没运行的时段留空。",
                          id: "power.trend.state")
            } else {
                PowerTrendChart(window: w).frame(height: 84).accessibilityIdentifier("power.trend")
                HStack {
                    Text(Fmt.clock(w.start, now: t)).font(DS.cap(.regular)).foregroundColor(DS.text.secondary)
                    Spacer()
                    Text("现在").font(DS.cap(.regular)).foregroundColor(DS.text.secondary)
                }
            }
            Text(coverage(w, now: t)).font(DS.cap(.regular)).foregroundColor(DS.text.secondary)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("power.trend.coverage")
            Footnote(text: "三条线来源不同，分开画、不相加：输入来自电源遥测，充入/放电由电池电压 × 电流计算。系统功耗是估算值，不画进曲线。虚线为接电或拔电时刻，空白处没有样本。")
        }
    }
    func legend(_ name: String, _ c: Color, _ v: Double?, _ reason: String?) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(c).frame(width: 10, height: 3).accessibilityHidden(true)
            Text(name).font(DS.cap(.regular)).foregroundColor(DS.text.secondary)
            Text(reason ?? Fmt.watts(v)).font(DS.num(12)).foregroundColor(reason == nil ? .primary : DS.text.secondary)
        }.accessibilityElement(children: .combine)
    }
    func coverage(_ w: PowerHistory.Window, now: Date) -> String {
        guard let start = h.startedAt else { return "本次运行还没有功率样本。" }
        var parts = ["从 " + Fmt.clock(start, now: now) + " 开始记录（本次运行）"]
        if let last = h.samples.last { parts.append("最新样本 " + Fmt.ago(last.t, now: now)) }
        parts.append(w.gaps == 0 ? "无断档" : "\(w.gaps) 段断档")
        if !w.switches.isEmpty { parts.append("\(w.switches.count) 次接电/拔电") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - B05 应用能耗采样覆盖
struct EnergyCoverage: Equatable {
    let firstSample: Date?        // 最早一次有效采样
    let lastSample: Date?         // 最新一次写入
    let estimated: Bool           // 旧记录没有逐分钟覆盖信息，只能按小时推断
    let coveredMinutes: Int       // 本范围内有采样的分钟数
    let rangeMinutes: Int         // 本范围可覆盖的分钟数（从首次采样起算，不早于范围起点）
    let buckets: [Double]         // 每个桶的覆盖比例 0…1（24 小时按小时、7/30 天按天）
    let gaps: Int                 // 覆盖 < 10% 的连续桶段数（首次采样之后）

    var fraction: Double { rangeMinutes > 0 ? min(1, Double(coveredMinutes) / Double(rangeMinutes)) : 0 }

    static func compute(_ store: EnergyStore, range: EnergyStore.Range, now: Date) -> EnergyCoverage {
        let nowH = Int(now.timeIntervalSince1970 / 3600)
        let (count, size): (Int, Int) = range == .day ? (24, 1) : (range == .week ? 7 : 30, 24)
        let startH = nowH - count * size + 1
        let legacyFirst = store.hours.keys.min().map { Date(timeIntervalSince1970: Double($0) * 3600) }
        let first = store.firstSample.map(Date.init(timeIntervalSince1970:)) ?? legacyFirst
        let last = store.lastSample.map(Date.init(timeIntervalSince1970:))
        let estimated = store.sampled == nil
        // 每小时有采样的分钟数；旧记录只知道该小时有没有数据，按 60 分钟估计并标注
        func minutes(_ h: Int) -> Int {
            if let s = store.sampled { return min(60, s[h] ?? 0) }
            return store.hours[h] == nil ? 0 : 60
        }
        var buckets: [Double] = [], covered = 0
        for b in 0..<count {
            var m = 0
            for h in (startH + b * size)..<(startH + (b + 1) * size) where h <= nowH { m += minutes(h) }
            covered += m
            buckets.append(Double(m) / Double(60 * size))
        }
        let firstH = first.map { Int($0.timeIntervalSince1970 / 3600) } ?? (nowH + 1)
        let fromH = max(startH, firstH)
        let possible = fromH > nowH ? 0 : (nowH - fromH) * 60 + Int(now.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600) / 60) + 1
        var gaps = 0, inGap = false
        for (b, f) in buckets.enumerated() {
            let bucketStartH = startH + b * size
            guard bucketStartH + size - 1 >= firstH, bucketStartH <= nowH else { inGap = false; continue }
            if f < 0.1 { if !inGap { gaps += 1 }; inGap = true } else { inGap = false }
        }
        // 正在进行的这一小时刚开始时覆盖必然很低，不算缺口
        if inGap, let lastF = buckets.last, lastF < 0.1, range == .day, let last, now.timeIntervalSince(last) < 180 { gaps = max(0, gaps - 1) }
        return EnergyCoverage(firstSample: first, lastSample: last, estimated: estimated,
                              coveredMinutes: covered, rangeMinutes: max(possible, 0), buckets: buckets, gaps: gaps)
    }

    func summary(now: Date) -> String {
        guard let first = firstSample else { return "还没有应用能耗采样。" }
        var parts: [String] = []
        parts.append((estimated ? "约从 " : "从 ") + Fmt.clock(first, now: now) + " 开始采样")
        parts.append("本范围覆盖 " + Fmt.span(Double(coveredMinutes) * 60) + (rangeMinutes > 0 ? String(format: "（%.0f%%）", fraction * 100) : ""))
        if let lastSample { parts.append("最新样本 " + Fmt.ago(lastSample, now: now)) }
        if gaps > 0 { parts.append("\(gaps) 段缺口") }
        return parts.joined(separator: " · ") + (estimated ? "。旧记录没有逐分钟覆盖信息，按小时推断。" : "")
    }
}

/// 覆盖条：每格一个时间桶，越满越实；空格表示没有采样（App 没运行或关闭了后台记录）
struct CoverageStrip: View {
    let buckets: [Double]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(buckets.enumerated()), id: \.offset) { _, f in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(f < 0.1 ? AnyShapeStyle(Color.primary.opacity(0.07)) : AnyShapeStyle(accent.opacity(0.25 + 0.6 * min(1, f))))
                    .frame(height: 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("采样覆盖：\(buckets.filter { $0 >= 0.1 }.count) / \(buckets.count) 个时间段有数据")
    }
}

// MARK: - D02 显示器色彩模式语义
extension DDCCaps {
    /// VCP 0xDC 显示模式（MCCS 2.2 标准含义）。厂商可能用作别的场景，界面注明「按标准」并允许按 OSD 改名。
    static func modeName(_ v: UInt8) -> String? {
        switch v {
        case 0x00: return "标准"; case 0x01: return "办公"; case 0x02: return "混合"; case 0x03: return "影片"
        case 0x04: return "用户自定义"; case 0x05: return "游戏"; case 0x06: return "运动"
        case 0x07: return "专业（关闭画面处理）"; case 0x08: return "标准（中等功耗）"; case 0x09: return "标准（低功耗）"
        case 0x0A: return "演示"; case 0xF0: return "动态对比度"
        default: return nil
        }
    }
    /// VCP 0x14 色彩预设的标准名称；读不到标准含义返回 nil
    static func presetStandardName(_ v: UInt8) -> String? {
        let n = colorName(v)
        return n.hasPrefix("预设 0x") ? nil : n
    }
}

/// 用户按显示器菜单（OSD）给硬件模式起的本机名称，按显示器身份 + VCP 码 + 值保存
final class DDCNames: ObservableObject {
    static var shared = DDCNames()
    let defaults: UserDefaults
    @Published private(set) var names: [String: String]
    static let key = "ddc.localNames"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        names = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }
    static func id(_ display: String, _ code: UInt8, _ value: UInt8) -> String { String(format: "%@|%02X|%02X", display, code, value) }
    func name(_ display: String, _ code: UInt8, _ value: UInt8) -> String? { names[Self.id(display, code, value)] }
    func set(_ display: String, _ code: UInt8, _ value: UInt8, _ name: String?) {
        let k = Self.id(display, code, value)
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { names.removeValue(forKey: k) } else { names[k] = String(trimmed.prefix(24)) }
        defaults.set(names, forKey: Self.key)
    }
    /// 显示名称：本机名称 > 标准名称 > 编号。返回（主名称，副说明）
    func label(_ display: String, _ code: UInt8, _ value: UInt8) -> (String, String) {
        let hex = String(format: "0x%02X", value)
        let standard = code == VCP.displayMode.rawValue ? DDCCaps.modeName(value) : DDCCaps.presetStandardName(value)
        if let local = name(display, code, value) { return (local, "本机命名 · " + (standard.map { "标准为「\($0)」 · " } ?? "") + hex) }
        if let standard { return (standard, "按 MCCS 标准 · " + hex) }
        return ("模式 " + hex, "标准未定义，可按显示器菜单命名")
    }
    /// 弹窗输入本机名称（空白 = 恢复默认）
    static var prompt: (_ title: String, _ current: String) -> String? = { title, current in
        let a = NSAlert(); a.messageText = title
        a.informativeText = "按显示器菜单（OSD）里看到的名称填写，只保存在这台 Mac 上。留空恢复默认名称。"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); f.stringValue = current; a.accessoryView = f
        a.addButton(withTitle: "保存"); a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
    }
}

/// 显示器操作反馈：从「正在应用并核对」等文字推出统一状态
enum DDCFeedback {
    static func kind(_ note: String) -> StateKind {
        if note.hasPrefix("正在") { return .loading }
        if note.hasPrefix("已核对") { return .done }
        if note.hasPrefix("已发送") { return .unknown }
        if note.hasPrefix("未") { return .failed }
        return .unknown
    }
}
