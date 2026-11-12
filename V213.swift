// 2.13 P1 结构与密度：摘要区标记 / 页面骨架、面板偏好（快捷操作可选、进程默认展开）、上下文动作（底栏与分组 ⌘K）、实时监控新结构
import SwiftUI
import AppKit

// MARK: - 摘要区与页面骨架（测试门槛 A：摘要不滚动，详情可局部滚动）
/// 摘要区标记：一个真实的 NSView，铺在摘要区背后。`MOTests.fits` 据此判断摘要在一屏之内、不在滚动区域里，
/// 并且只允许摘要下方的滚动区域超出（详情局部滚动）。不接收点击。
final class SummaryMarkerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityIsIgnored() -> Bool { true }
}
struct SummaryMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> SummaryMarkerView { SummaryMarkerView() }
    func updateNSView(_ v: SummaryMarkerView, context: Context) {}
}
extension View {
    /// 标记为页面摘要（标题、结论、主操作）：放在滚动区域外面
    func pageSummary() -> some View { background(SummaryMarker().allowsHitTesting(false)) }
}

/// 页面骨架：摘要固定在顶部，详情在下方单独滚动（不显示滚动条）
struct PageScaffold<S: View, D: View>: View {
    var spacing: CGFloat = DS.cardGap
    var padding: CGFloat = 16
    @ViewBuilder let summary: S
    @ViewBuilder let details: D
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            summary.pageSummary()
            ScrollView(.vertical, showsIndicators: false) {
                details.frame(maxWidth: .infinity, alignment: .topLeading).padding(.bottom, 4)
            }
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 门槛 A 的判定（纯函数，便于自检）：返回问题描述，空数组表示通过。
/// - 没有摘要标记：沿用旧规则，所有滚动区域都必须放得下。
/// - 有摘要标记：摘要不能在滚动区域里、必须完整在可见范围内；超出的滚动区域必须整个位于摘要下方。
/// - 任何情况下都不允许出现常驻（legacy）滚动条。
enum LayoutGate {
    struct Verdict { var problems: [String]; var summaries: Int; var scrolls: Int; var scrolledDetails: Int }
    static func evaluate(_ root: NSView) -> Verdict {
        var scrolls: [NSScrollView] = [], markers: [NSView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView { scrolls.append(s) }
            if v is SummaryMarkerView { markers.append(v) }
            v.subviews.forEach(walk)
        }
        walk(root)
        func inScroll(_ v: NSView) -> Bool {
            var p = v.superview
            while let x = p, x !== root { if x is NSScrollView { return true }; p = x.superview }
            return false
        }
        /// 统一换成「y 向下」的坐标：top 越小越靠上
        func topDown(_ v: NSView) -> CGRect {
            let r = v.convert(v.bounds, to: root)
            if root.isFlipped { return r }
            return CGRect(x: r.minX, y: root.bounds.height - r.maxY, width: r.width, height: r.height)
        }
        var problems: [String] = [], details = 0
        let screen = root.bounds.insetBy(dx: -1, dy: -1)
        var summaryBottom: CGFloat? = nil
        for m in markers {
            let r = topDown(m)
            if inScroll(m) { problems.append("摘要在滚动区域里") }
            if !screen.contains(r) { problems.append("摘要超出可见范围 \(Int(max(r.maxY - root.bounds.height, -r.minY))) pt") }
            summaryBottom = max(summaryBottom ?? 0, r.maxY)
        }
        for s in scrolls {
            if s.hasVerticalScroller, let sc = s.verticalScroller, !sc.isHidden, sc.alphaValue > 0, s.scrollerStyle == .legacy { problems.append("有滚动条") }
            guard let doc = s.documentView else { continue }
            let over = doc.frame.height - s.contentView.bounds.height
            guard over > 1 else { continue }
            if let bottom = summaryBottom, !inScroll(s), topDown(s).minY >= bottom - 1 { details += 1; continue }
            problems.append("内容超出 \(Int(over)) pt")
        }
        return Verdict(problems: problems, summaries: markers.count, scrolls: scrolls.count, scrolledDetails: details)
    }
}

// MARK: - 菜单栏面板偏好
/// 面板快捷操作（默认 4 个，可在面板「编辑」或设置页增减）与进程列表展开状态
final class PanelPrefs: ObservableObject {
    static let defaultIDs = ["act.mic", "act.awake", "act.charge", "act.dock"]   // 与 known 同序
    static let idsKey = "panel.quickActions", procKey = "panel.procExpanded"
    /// 测试进程不读写用户的真实偏好：用独立的临时域，截图与黄金图始终是默认配置
    static let shared: PanelPrefs = {
        let args = CommandLine.arguments
        if args.contains("--selftest") || args.contains("--uitest") || args.contains("--snapshot") {
            let name = "mo.test.panelprefs.\(getpid())"
            let d = UserDefaults(suiteName: name)!; d.removePersistentDomain(forName: name)
            return PanelPrefs(d)
        }
        return PanelPrefs(.standard)
    }()
    let d: UserDefaults
    @Published private(set) var ids: [String]
    @Published var procExpanded: Bool { didSet { d.set(procExpanded, forKey: Self.procKey) } }
    init(_ d: UserDefaults) {
        self.d = d
        ids = Self.sanitize(d.stringArray(forKey: Self.idsKey))
        // 从未手动操作过时默认展开；用户收起或展开后写入此键并记住
        procExpanded = d.object(forKey: Self.procKey) as? Bool ?? true
    }
    static var known: [String] { ["act.shot", "act.mic", "act.awake", "act.clean", "act.charge", "act.dock"] }
    /// 只保留认识的操作，按固定顺序；读不到或为空时回到默认 4 个
    static func sanitize(_ raw: [String]?) -> [String] {
        guard let raw else { return defaultIDs }
        let picked = known.filter { raw.contains($0) }
        return picked.isEmpty ? defaultIDs : picked
    }
    func contains(_ id: String) -> Bool { ids.contains(id) }
    /// 至少保留 1 个；返回是否生效
    @discardableResult func set(_ id: String, on: Bool) -> Bool {
        var next = Set(ids)
        if on { next.insert(id) } else { next.remove(id) }
        guard !next.isEmpty else { return false }
        ids = Self.known.filter { next.contains($0) }
        d.set(ids, forKey: Self.idsKey)
        return true
    }
    func resetDefaults() { ids = Self.defaultIDs; d.removeObject(forKey: Self.idsKey) }
    func selectedActions() -> [QuickAction] { QuickActionList.all().filter { ids.contains($0.id) } }
}

/// 快捷操作编辑菜单：面板和设置页共用
struct QuickActionEditMenu<L: View>: View {
    @ObservedObject var prefs = PanelPrefs.shared
    @ViewBuilder var label: L
    var body: some View {
        Menu {
            ForEach(QuickActionList.all()) { a in
                Toggle(a.title, isOn: Binding(get: { prefs.contains(a.id) }, set: { prefs.set(a.id, on: $0) }))
            }
            Divider()
            Button("恢复默认 4 项") { prefs.resetDefaults() }
        } label: { label }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("选择面板里显示的快捷操作（至少 1 个）")
    }
}

// MARK: - 上下文动作（底栏按钮 + 分组的 ⌘K 列表）
enum ContextActions {
    static let pageGroup = "当前页面", quickGroup = "快捷操作", goGroup = "前往"

    /// 当前页面的动作；底栏常驻显示前 2 个
    static func page(_ p: Page) -> [CmdAction] {
        switch p {
        case .overview:
            return [CmdAction(title: "一键体检", short: "体检", group: pageGroup, run: { Shell.shared.model?.scan() })]
        case .monitor:
            return [CmdAction(title: "刷新读数", short: "刷新", group: pageGroup, run: { Monitor.shared.sampleNow() })]
        case .battery:
            let cc = ChargeClient.shared
            guard cc.phase == .ready else { return [] }
            let on = cc.st.settings.enabled
            return [CmdAction(title: on ? "关闭充电上限" : "开启充电上限 \(cc.st.settings.limit)%", short: on ? "关闭上限" : "开启上限",
                              group: pageGroup, run: { cc.setLimit(cc.st.settings.limit, enabled: !on) })]
        case .network:
            return [CmdAction(title: "重新诊断网络", short: "重新诊断", group: pageGroup, run: { NetDiag.shared.run() })]
        case .clean:
            return [CmdAction(title: "重新扫描", short: "扫描", group: pageGroup, run: { CleanStore.shared.scan() })]
        case .split:
            return SplitController.commands("分区").flatMap { $0.actions }.map { a in
                CmdAction(title: a.title, short: a.short, hint: a.hint, destructive: a.destructive, group: "分区", run: a.run)
            }
        default:
            return []
        }
    }
    /// 空搜索时 ⌘K 打开的分组列表：当前页面 → 快捷操作 → 前往
    static func item(_ p: Page) -> CmdItem {
        var acts = page(p)
        for a in QuickActionList.all() {
            let st = a.stateLabel()
            acts.append(CmdAction(title: a.title + (st.isEmpty ? "" : "（\(st)）"), short: a.title, group: quickGroup, run: a.run))
        }
        if p != .overview {
            acts.append(CmdAction(title: "一键体检", group: quickGroup, run: {
                Nav.shared.sel = .overview; UIState.shared.openMain()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Shell.shared.model?.scan() }
            }))
        }
        for g in navGroups where g != "设置" {
            guard let first = navPages.first(where: { $0.group == g && $0.id != p }) else { continue }
            acts.append(CmdAction(title: "打开「\(first.title)」", short: g, group: goGroup, run: { CmdIndex.open(first.id) }))
        }
        if p != .settings { acts.append(CmdAction(title: "打开「设置」", group: goGroup, run: { CmdIndex.open(.settings) })) }
        let np = navPages.first { $0.id == p }
        return CmdItem(id: p == .split ? "ctx.split" : "ctx.\(p.storageKey)", kind: .action, title: np?.title ?? "操作",
                       subtitle: "当前页面的操作", symbol: np?.icon ?? "bolt", actions: acts)
    }
}

// MARK: - 实时监控（结论 → 四项核心读数 → 高占用进程；GPU / 温度 / 风扇在详情）
struct MonitorVerdict: View {
    let s: Snapshot
    static func reason(_ s: Snapshot) -> String {
        guard s.uptime > 0 else { return "首次读数约 2 秒" }
        var parts: [String] = []
        if let top = s.top.max(by: { $0.cpu < $1.cpu }), top.cpu >= 50 { parts.append("主要占用：\(top.name) \(String(format: "%.0f%%", top.cpu))") }
        if s.memPressure >= 2 { parts.append("内存压力" + Fmt.pressure(s.memPressure).0) }
        if s.diskTotalGB > 0, s.diskUsedFraction >= 0.9 { parts.append(String(format: "磁盘仅剩 %.0f GB", s.diskFreeGB)) }
        if parts.isEmpty { parts.append(String(format: "CPU %.0f%% · 内存压力", s.cpu) + Fmt.pressure(s.memPressure).0) }
        return parts.joined(separator: " · ")
    }
    var body: some View {
        let sampled = s.uptime > 0, v = PanelContent.verdict(s.health.score)
        HStack(spacing: 10) {
            Image(systemName: sampled ? v.symbol : "hourglass").font(.system(size: 20, weight: .semibold))
                .foregroundColor(sampled ? v.tint : DS.text.secondary).frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(sampled ? v.word : "等待采样").font(DS.title()).foregroundColor(sampled ? DS.text.tone(v.tint) : DS.text.secondary)
                    Text(sampled ? s.health.status : "").font(DS.body(.medium)).lineLimit(1)
                }
                Text(Self.reason(s)).font(DS.sub()).foregroundColor(DS.text.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if sampled { Text("健康分 \(s.health.score)").font(DS.sub(.medium)).foregroundColor(DS.text.secondary) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).card()
        .accessibilityElement(children: .contain).accessibilityIdentifier("monitor.verdict")
    }
}

struct CoreReadings: View {
    @ObservedObject var m: Monitor
    @State private var showApps = false
    var compact = false
    var body: some View {
        let t = MetricTiles(m: m), s = m.s
        let rate = Fmt.rate(s.downBps).split(separator: " ", maxSplits: 1).map(String.init)
        HStack(spacing: DS.cardGap) {
            t.cpuTile
            t.memoryTile
            t.diskTile
            Button { showApps = true } label: {
                MetricTile(title: "网络", symbol: "arrow.down", tint: DS.metric.network,
                           value: s.netIface.isEmpty ? nil : rate.first, unit: rate.count > 1 ? rate[1] + " ↓" : "", note: s.netKind,
                           series: s.netIface.isEmpty ? [] : m.downHist,
                           stats: [MetricStat("上行", Fmt.rate(s.upBps) + " ↑"),
                                   MetricStat("接口 / 代理", s.netIface + " · " + (s.proxy.isEmpty ? "—" : s.proxy))],
                           unavailableReason: "当前没有可用网络接口")
            }.buttonStyle(.plain).help("查看正在联网的应用").accessibilityIdentifier("net.rates")
                .popover(isPresented: $showApps, arrowEdge: .bottom) { AppTrafficPopover() }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("monitor.metrics")
    }
}

struct MonitorDetails: View {
    @ObservedObject var m: Monitor
    var body: some View {
        let t = MetricTiles(m: m), s = m.s
        VStack(alignment: .leading, spacing: DS.cardGap) {
            Text("详情").font(DS.sub(.semibold)).foregroundColor(DS.text.secondary).padding(.top, 4)
            Grid(horizontalSpacing: DS.cardGap, verticalSpacing: DS.cardGap) {
                GridRow {
                    t.gpuTile
                    MetricTile(title: "温度", symbol: "thermometer.medium", tint: DS.metric.cpu,
                               value: s.cpuTemp.map { String(format: "%.0f", $0) }, unit: "°C", note: "CPU 均温",
                               stats: [MetricStat("GPU 均温", s.gpuTemp.map { String(format: "%.0f°C", $0) } ?? Fmt.dash),
                                       MetricStat("电池", s.batteryTemp.map { String(format: "%.0f°C", $0) } ?? Fmt.dash)],
                               unavailableReason: "未识别到温度传感器",
                               valueColor: (s.cpuTemp ?? 0) >= 90 ? bad : ((s.cpuTemp ?? 0) >= 75 ? warn : .primary))
                    t.fanTile
                }
                GridRow { t.batteryTile; t.systemTile; t.topTile }
            }
            KPIStrip(items: [MetricStat("芯片", s.chip + " · \(s.ramGB) GiB"),
                             MetricStat("系统", s.osVersion), MetricStat("开机", Fmt.uptime(s.uptime)),
                             MetricStat("网络", s.netKind + " · " + s.proxy)])
            Footnote(text: "前台每 \(Int(Monitor.detailInterval)) 秒刷新，后台每 \(Int(Monitor.lightInterval)) 秒采样；磁盘为十进制 GB，内存为二进制 GiB。温度为已识别传感器均温；高占用为当前采样，不代表历史峰值。")
        }.accessibilityElement(children: .contain).accessibilityIdentifier("monitor.details")
    }
}

struct MonitorProcesses: View {
    @ObservedObject var m: Monitor
    var body: some View {
        ProcList(m: m, limit: 8).padding(8).frame(maxWidth: .infinity, alignment: .leading).card()
            .accessibilityElement(children: .contain).accessibilityIdentifier("monitor.procs")
    }
}

// MARK: - 底栏上下文动作按钮
struct BarButton: View {
    let title: String
    var kbd: String? = nil
    var id: String
    let run: () -> Void
    var body: some View {
        Button(action: run) {
            HStack(spacing: 5) {
                Text(title).font(DS.sub(.medium)).foregroundColor(.primary).lineLimit(1)
                if let kbd { Kbd(text: kbd) }
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(id).accessibilityLabel(title)
    }
}
