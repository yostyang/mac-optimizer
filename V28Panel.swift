// 2.8 U03：双列菜单栏面板
// 结构：结论头 → 系统芯片行 → 2 列指标卡（右上角是状态标签）→ 电池宽卡（含外设电量圆环）→ 高占用进程（带列头）→ 快捷操作与优化记录
// 只用设计令牌（DS）：中性底 + 品牌紫；指标色只用于图标与曲线，状态色只表示正常/注意/危险。
import SwiftUI
import AppKit

enum PanelLayout {
    static let width: CGFloat = 400
    static let gap: CGFloat = 8
    /// 2.13：104 → 72（标题行 + 数值与曲线同一行 + 一行说明）
    static let tileHeight: CGFloat = 72
}

/// 指标卡：标题 + 状态标签 / 主值 / 曲线或进度 / 一行说明
struct PanelTile<Viz: View>: View {
    let symbol: String
    let title: String
    let tint: Color
    var badge: String? = nil
    var badgeTint: Color = DS.text.secondary
    let value: String?
    var unit = ""
    var valueColor: Color = .primary
    var footer = ""
    var unavailable = "当前系统没有提供此读数"
    @ViewBuilder var viz: Viz
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(DS.cap(.semibold)).foregroundColor(tint).accessibilityHidden(true)
                Text(title).font(DS.sub(.semibold)).foregroundColor(tint).contrastTarget("panel.tile.title")
                Spacer(minLength: 2)
                if let badge {
                    Text(badge).font(DS.num(12, .semibold)).foregroundColor(DS.text.tone(badgeTint)).lineLimit(1)
                        .padding(.horizontal, 5).padding(.vertical, 0.5)
                        .background(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous).fill(badgeTint.opacity(0.13)))
                }
            }
            HStack(alignment: .center, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    if let value {
                        Text(value).font(DS.num(20, .semibold)).foregroundColor(valueColor).lineLimit(1).minimumScaleFactor(0.7).contrastTarget("panel.tile.value", .largeText)
                    } else {
                        Unavailable(reason: unavailable).font(DS.num(20, .semibold))
                    }
                    if !unit.isEmpty { Text(unit).font(DS.sub(.medium)).foregroundColor(DS.text.secondary).lineLimit(1) }
                }.layoutPriority(1)
                viz.frame(maxWidth: .infinity).frame(height: 16).accessibilityHidden(true)
            }
            Text(footer).font(DS.sub()).foregroundColor(DS.text.secondary).lineLimit(1).minimumScaleFactor(0.85).contrastTarget("panel.tile.footer")
        }
        .padding(.horizontal, DS.tilePadding).padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: PanelLayout.tileHeight, maxHeight: PanelLayout.tileHeight, alignment: .topLeading)
        .card()
        .clipShape(RoundedRectangle(cornerRadius: DS.r.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, value.map { $0 + unit } ?? "暂不可用，" + unavailable, badge ?? "", footer].filter { !$0.isEmpty }.joined(separator: "，"))
    }
}

/// 外设电量圆环：读不到或已过期时画虚线环，绝不显示成 0%；低电量在环右上角加警示图标（不只靠颜色）
struct DeviceRing: View {
    let symbol: String
    let name: String
    let percent: Int?
    var reason = ""
    var freshness: ReadingFreshness = .fresh
    var size: CGFloat = 40

    /// 只有读到新鲜或缓存的读数才显示数值；过期与未取得都画虚线环，绝不显示成 0%。
    private var shown: Int? { (freshness == .fresh || freshness == .cached) ? percent : nil }

    var body: some View {
        ZStack {
            dial
            Image(systemName: symbol)
                .font(.system(size: size * 0.32, weight: .medium))   // 图标
                .foregroundColor(shown == nil ? DS.text.secondary : .primary)   // 图标
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) { lowMark }
        .help(hint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BatterySpeech.label(name: name, percent: percent, freshness: freshness, reason: reason))
        .accessibilityIdentifier("panel.device." + name)
    }

    @ViewBuilder private var dial: some View {
        if let p = shown {
            let lv = BatteryLevel.of(p)
            Circle().stroke(lv.graphic.opacity(0.18), lineWidth: 3.5)
            Circle().trim(from: 0, to: CGFloat(max(0, min(100, p))) / 100)
                .stroke(lv.graphic, style: StrokeStyle(lineWidth: 3.5, lineCap: .round)).rotationEffect(.degrees(-90))
        } else {
            Circle().stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        }
    }

    @ViewBuilder private var lowMark: some View {
        if let p = shown, BatteryLevel.of(p) != .normal {
            LowBatteryMark(level: BatteryLevel.of(p), showText: false)
                .background(Circle().fill(DS.card).padding(-1)).offset(x: 4, y: -3)
        }
    }

    /// 悬停提示：能读到就说百分比、状态与来源；读不到就说清是过期还是未取得，并带上原因。
    private var hint: String {
        if let p = shown {
            var s = "\(p)%"
            if let l = BatteryLevel.of(p).label { s += "，" + l }
            if freshness == .cached { s += "（缓存）" }
            return name + "：" + s
        }
        if freshness == .expired { return name + "：读数已过期" }
        return reason.isEmpty ? name + "：未取得" : name + "：未取得（\(reason)）"
    }
}

struct PanelContent: View {
    @ObservedObject var m: Monitor
    @ObservedObject var ui = UIState.shared
    @ObservedObject var alerts = BatteryAlerts.shared
    @ObservedObject var bt = BTBattery.shared
    @ObservedObject var st = CleanStats.shared
    @ObservedObject var ka = KeepAwake.shared
    @ObservedObject var cc = ChargeClient.shared
    @ObservedObject var dock = DockMode.shared
    @ObservedObject var trio = TrioModel.shared
    @ObservedObject var prefs = PanelPrefs.shared
    @State private var sel = 0
    @State private var more: ProcInfo?
    @State private var showApps = false

    var body: some View {
        let s = m.s
        VStack(spacing: PanelLayout.gap) {
            header(s)
            chips(s)
            Grid(horizontalSpacing: PanelLayout.gap, verticalSpacing: PanelLayout.gap) {
                GridRow { cpuTile(s); gpuTile(s) }
                GridRow { memoryTile(s); diskTile(s) }
                GridRow { networkTile(s); fanTile(s) }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("panel.metrics")
            if s.battery != nil || !peripherals.isEmpty { batteryCard(s) }
            if alerts.settings.menuIndicator == "trio" && trio.config.panel { TrioPanelCard() }
            processCard
            actionsCard
        }
        .padding(10)
        .frame(width: PanelLayout.width)
        .background(Vibrancy(material: .popover, solid: DS.window))
        .overlay { if let p = more { PanelMore(p: p, m: m) { more = nil } } }
        .background(PanelKeyRouter())
        .onAppear {
            if cc.phase != .ready { cc.refresh() }   // 只读状态，不会安装助手
            PanelKeys.shared.handler = { e in
                let count = min(4, m.s.top.count)
                if more != nil { return false }
                // 进程默认展开；若已收起，↓ 先展开，其余按键交给系统
                if !prefs.procExpanded {
                    if e.keyCode == Key.down { prefs.procExpanded = true; sel = 0; return true }
                    return false
                }
                switch e.keyCode {
                case Key.down: sel = min(sel + 1, max(0, count - 1)); return true
                case Key.up: sel = max(0, sel - 1); return true
                case Key.enter, Key.keypadEnter:
                    guard m.s.top.indices.contains(sel) else { return false }
                    let f = ProcActions.fix(for: m.s.top[sel])
                    DispatchQueue.main.async { FixRunner.perform(f) }
                    return true
                default:
                    if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "k" {
                        if m.s.top.indices.contains(sel) { more = m.s.top[sel] }
                        return true
                    }
                    return false
                }
            }
        }
        .onDisappear { PanelKeys.shared.handler = nil }
    }

    // MARK: 结论头
    static func verdict(_ score: Int) -> (word: String, symbol: String, tint: Color) {
        score >= 85 ? ("不卡", "checkmark.seal.fill", good) : (score >= 60 ? ("有点卡", "exclamationmark.triangle.fill", warn) : ("很卡", "flame.fill", bad))
    }
    func header(_ s: Snapshot) -> some View {
        let h = s.health, v = Self.verdict(h.score)
        let sampled = s.uptime > 0
        return HStack(spacing: 8) {
            Image(systemName: sampled ? v.symbol : "hourglass").font(.system(size: 20, weight: .semibold))   // 图标
                .foregroundColor(sampled ? v.tint : DS.text.secondary).frame(width: 24).accessibilityHidden(true)
            Text(sampled ? "\(h.score)" : Fmt.dash).font(DS.num(28, .bold)).foregroundColor(.primary)
            VStack(alignment: .leading, spacing: 0) {
                Text(sampled ? v.word : "等待采样").font(DS.cap(.semibold)).foregroundColor(sampled ? DS.text.tone(v.tint) : DS.text.secondary)
                Text(sampled ? h.status : "首次读数约 2 秒").font(DS.body(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 4)
            Button { ui.openMain() } label: { Image(systemName: "macwindow").font(DS.body()) }
                .buttonStyle(.plain).foregroundColor(DS.text.secondary).help("打开主窗口").accessibilityIdentifier("panel.open")
            Menu {
                Picker("菜单栏显示", selection: $alerts.settings.menuIndicator) {
                    Text("CPU 占用").tag("cpu"); Text("健康分").tag("score")
                    Text("电池图标").tag("battery"); Text("网速").tag("net")
                    Text("合并状态").tag("trio")
                }
                Toggle("登录时启动", isOn: Binding(get: { ui.login }, set: { Actions.setLogin($0); ui.login = Actions.loginEnabled }))
                Divider()
                Button("设置…") { Nav.shared.sel = .settings; StatusBar.shared.popover.performClose(nil); ui.openMain() }
                Button("隐藏菜单栏图标") { ui.menuBar = false }
                Button("退出 Mac一键优化") { NSApp.terminate(nil) }
            } label: { Image(systemName: "gearshape").font(DS.body()) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18).help("设置")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel.header")
    }

    func chips(_ s: Snapshot) -> some View {
        let items: [(String, String)] = [("cpu", s.chip.isEmpty ? Fmt.dash : s.chip), ("memorychip", s.ramGB > 0 ? "\(s.ramGB) GB" : Fmt.dash),
                                         ("apple.logo", s.osVersion.isEmpty ? "macOS" : s.osVersion),
                                         ("clock", s.uptime > 0 ? "已运行 " + Fmt.uptime(s.uptime) : "已运行 —"),
                                         ("network", s.proxy.isEmpty ? "直连" : s.proxy)]
        return ViewThatFits(in: .horizontal) {
            row(items); row(Array(items.prefix(4))); row(Array(items.prefix(3))); row([items[0], items[2]]); row([items[0]])
        }.accessibilityElement(children: .combine).accessibilityLabel(items.map(\.1).joined(separator: "，"))
    }
    func row(_ items: [(String, String)]) -> some View {
        HStack(spacing: 5) { ForEach(Array(items.enumerated()), id: \.offset) { _, i in Chip(icon: i.0, text: i.1).fixedSize() }; Spacer(minLength: 0) }
    }

    // MARK: 指标卡
    static func tempTint(_ t: Double?) -> Color { guard let t else { return .secondary }; return t >= 90 ? bad : (t >= 75 ? warn : good) }
    static func loadWord(_ cpu: Double) -> String { cpu >= 70 ? "高占用" : (cpu >= 30 ? "中等占用" : "低占用") }

    func cpuTile(_ s: Snapshot) -> some View {
        PanelTile(symbol: "cpu", title: "CPU", tint: DS.metric.cpu,
                  badge: s.cpuTemp.map { String(format: "%.0f°C", $0) }, badgeTint: Self.tempTint(s.cpuTemp),
                  value: m.cpuHist.isEmpty ? nil : String(format: "%.0f", s.cpu), unit: "%",
                  valueColor: s.cpu >= 85 ? bad : (s.cpu >= 60 ? warn : .primary),
                  footer: m.cpuHist.isEmpty ? "等待首次采样" : Self.loadWord(s.cpu) + String(format: " · 负载 %.2f", s.load.first ?? 0),
                  unavailable: "等待首次采样") {
            Spark(values: m.cpuHist, color: DS.metric.cpu, maxValue: 100)
        }
    }
    func gpuTile(_ s: Snapshot) -> some View {
        PanelTile(symbol: "square.stack.3d.up", title: "GPU", tint: DS.metric.gpu,
                  badge: s.gpuTemp.map { String(format: "%.0f°C", $0) }, badgeTint: Self.tempTint(s.gpuTemp),
                  value: s.gpu.map { String(format: "%.0f", $0) }, unit: "%",
                  footer: s.gpu == nil ? "显卡驱动未提供利用率" : (s.gpuCores > 0 ? "\(s.gpuCores) 核图形处理器" : "图形处理器"),
                  unavailable: "显卡驱动未提供利用率") {
            if s.gpu != nil { Spark(values: m.gpuHist, color: DS.metric.gpu, maxValue: 100) } else { Color.clear }
        }
    }
    func memoryTile(_ s: Snapshot) -> some View {
        let p = Fmt.pressure(s.memPressure)
        return PanelTile(symbol: "memorychip", title: "内存", tint: DS.metric.memory,
                         badge: s.memTotalGB > 0 ? "压力" + p.0 : nil, badgeTint: s.memPressure >= 4 ? bad : (s.memPressure >= 2 ? warn : good),
                         value: s.memTotalGB > 0 ? String(format: "%.0f", s.memFraction * 100) : nil, unit: "%",
                         valueColor: s.memPressure >= 4 ? bad : (s.memPressure >= 2 ? warn : .primary),
                         footer: s.memTotalGB > 0 ? String(format: "已用 %.1f GiB · 交换 %.1f GiB", s.memUsedGB, s.swapUsedGB) : "等待首次采样",
                         unavailable: "等待首次采样") {
            if s.memTotalGB > 0 { Bar(frac: s.memFraction, color: DS.metric.memory, height: 4).frame(maxHeight: .infinity) } else { Color.clear }
        }
    }
    func diskTile(_ s: Snapshot) -> some View {
        PanelTile(symbol: "internaldrive", title: "磁盘", tint: DS.metric.disk,
                  badge: s.diskTotalGB > 0 ? String(format: "%.0f GB", s.diskTotalGB) : nil, badgeTint: DS.metric.disk,
                  value: s.diskTotalGB > 0 ? String(format: "%.0f", s.diskUsedFraction * 100) : nil, unit: "% 已用",
                  valueColor: s.diskUsedFraction >= 0.95 ? bad : (s.diskUsedFraction >= 0.85 ? warn : .primary),
                  footer: s.diskTotalGB > 0 ? String(format: "可用 %.0f GB · 启动盘", s.diskFreeGB) : "等待首次采样",
                  unavailable: "等待首次采样") {
            if s.diskTotalGB > 0 { Bar(frac: s.diskUsedFraction, color: DS.metric.disk, height: 4).frame(maxHeight: .infinity) } else { Color.clear }
        }
    }
    func networkTile(_ s: Snapshot) -> some View {
        let parts = Fmt.rate(s.downBps).split(separator: " ", maxSplits: 1).map(String.init)
        return Button { showApps = true } label: {
            PanelTile(symbol: "arrow.up.arrow.down", title: "网络", tint: DS.metric.network,
                      badge: s.netKind.isEmpty ? nil : s.netKind, badgeTint: DS.metric.network,
                      value: s.netIface.isEmpty ? nil : parts.first, unit: s.netIface.isEmpty || parts.count < 2 ? "" : parts[1] + " ↓",
                      footer: s.netIface.isEmpty ? "没有可用网络接口" : "↑ " + Fmt.rate(s.upBps) + " · " + (s.proxy.isEmpty ? "直连" : s.proxy),
                      unavailable: "当前没有可用网络接口") {
                if s.netIface.isEmpty { Color.clear } else { Spark(values: m.downHist, color: DS.metric.network) }
            }
        }
        .buttonStyle(.plain).help("查看正在联网的应用")
        .popover(isPresented: $showApps, arrowEdge: .trailing) { AppTrafficPopover() }
        .accessibilityIdentifier("panel.traffic")
    }
    func fanTile(_ s: Snapshot) -> some View {
        let fans = s.fans ?? []
        let fastest = fans.max()
        return PanelTile(symbol: "fan", title: "风扇", tint: DS.metric.fan,
                         badge: fans.isEmpty ? nil : "\(fans.count) 个", badgeTint: DS.metric.fan,
                         value: fastest.map { String(format: "%.0f", $0) }, unit: fastest == nil ? "" : "RPM",
                         footer: fans.isEmpty ? "无风扇机型或未提供转速" : (fastest == 0 ? "待机 · 由 macOS 调节" : "由 macOS 自动调节（只读）"),
                         unavailable: "无风扇机型或硬件未提供转速") {
            if let fastest, s.fanMax > 0 { Bar(frac: fastest / s.fanMax, color: DS.metric.fan, height: 4).frame(maxHeight: .infinity) } else { Color.clear }
        }
    }

    // MARK: 电池宽卡
    /// 已连接的蓝牙外设（含读不到电量的，用虚线环表示「未取得」）
    var peripherals: [BTDisplay] { bt.displays().filter(\.connected) }
    func batteryCard(_ s: Snapshot) -> some View {
        let flow = PowerFlowCalc.fromSnapshot(s)
        let mins = PowerFlowCalc.minutesToFull(percent: s.battery, fullMah: s.fullMah, voltageV: s.batteryVoltageV, chargeWatts: flow.chargeWatts)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: s.charging ? "battery.100.bolt" : "battery.75").font(DS.cap(.semibold)).accessibilityHidden(true)
                Text("电池").font(DS.sub(.semibold))
                Spacer(minLength: 2)
                if let hh = s.batteryHealth {
                    Text("健康 \(hh)%").font(DS.num(12, .semibold)).foregroundColor(hh < 80 ? DS.text.warn : DS.text.good)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous).fill((hh < 80 ? warn : good).opacity(0.13)))
                }
            }.foregroundColor(DS.metric.battery)
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    if let b = s.battery {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(b)%").font(DS.num(24, .semibold)).foregroundColor(BatteryLevel.of(b).text)
                                .accessibilityLabel(BatterySpeech.label(name: "这台 Mac", percent: b, freshness: .fresh))
                            LowBatteryMark(level: BatteryLevel.of(b))
                            Text(flow.supplyText).font(DS.sub()).foregroundColor(DS.text.secondary).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        Text(powerLine(flow, mins)).font(DS.cap(.regular)).foregroundColor(DS.text.secondary).lineLimit(1).minimumScaleFactor(0.8)
                            .accessibilityIdentifier("panel.battery.compact")
                    } else {
                        Text("这台 Mac 没有内置电池").font(DS.sub()).foregroundColor(DS.text.secondary)
                    }
                }
                Spacer(minLength: 4)
                HStack(spacing: 8) {
                    ForEach(peripherals.prefix(3)) { d in DeviceRing(symbol: d.kind, name: d.name, percent: d.percent, reason: d.reason, freshness: d.freshness, size: 38) }
                }
            }
        }
        .padding(DS.tilePadding).frame(maxWidth: .infinity, alignment: .leading).card()
        .accessibilityElement(children: .contain).accessibilityIdentifier("panel.battery")
    }
    func powerLine(_ f: PowerFlow, _ mins: Double?) -> String {
        if f.charging {
            guard f.chargeWatts != nil else { return "充电功率暂未取得（等待电流读数）" }
            return "充入 " + Fmt.watts(f.chargeWatts) + (mins.map { " · 约 " + fmtMinutes($0).replacingOccurrences(of: "约 ", with: "") + "充满（估算）" } ?? "")
        }
        if f.onAC { return "输入 " + Fmt.watts(f.inputWatts) + " · 系统 " + Fmt.watts(f.systemWatts) + "（估算）" }
        return "放电 " + Fmt.watts(f.dischargeWatts) + (m.s.timeRemaining.map { " · 约剩 \($0 / 60) 小时 \($0 % 60) 分" } ?? "")
    }

    // MARK: 进程（2.13.1 默认展开；用户收起或展开后会记住）
    var processCard: some View {
        let top = m.s.top.max { $0.cpu < $1.cpu }
        return VStack(spacing: 2) {
            Button { withAnimation(.easeOut(duration: DS.motionFast)) { prefs.procExpanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: prefs.procExpanded ? "chevron.down" : "chevron.right").font(DS.cap(.semibold))
                        .foregroundColor(DS.text.secondary).frame(width: 12).accessibilityHidden(true)
                    Text("高占用进程").font(DS.sub(.semibold)).foregroundColor(.primary)
                    Spacer(minLength: 4)
                    if !prefs.procExpanded {
                        if let top {
                            Text(top.name).font(DS.sub()).foregroundColor(DS.text.secondary).lineLimit(1).truncationMode(.middle)
                            Text(String(format: "%.1f%%", top.cpu)).font(DS.num(12, .medium)).foregroundColor(DS.text.tone(ProcessCPU.color(top.cpu)))
                        } else {
                            Text("正在统计").font(DS.sub()).foregroundColor(DS.text.secondary)
                        }
                    }
                }.padding(.horizontal, 6).frame(height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(prefs.procExpanded ? "收起高占用进程" : "展开高占用进程" + (top.map { "，最高 \($0.name)" } ?? ""))
            .accessibilityIdentifier("panel.procs.toggle")
            if prefs.procExpanded {
                ProcList(m: m, limit: 4, selection: sel, onSelect: { sel = $0 }, onMore: { more = $0 })
                HStack(spacing: 6) {
                    Kbd(text: "↑↓"); Text("选择").font(DS.cap()).foregroundColor(DS.text.secondary)
                    Kbd(text: "↵"); Text("处理").font(DS.cap()).foregroundColor(DS.text.secondary)
                    Kbd(text: "⌘K"); Text("更多操作").font(DS.cap()).foregroundColor(DS.text.secondary)
                    Spacer()
                }.padding(.horizontal, 4).padding(.bottom, 2)
            }
        }.padding(6).card()
        .accessibilityElement(children: .contain).accessibilityIdentifier("panel.procs")
    }

    // MARK: 快捷操作（默认 4 个，可编辑）+ 优化记录
    var actionsCard: some View {
        let actions = prefs.selectedActions()
        let rows = (actions.count + 1) / 2
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("快捷操作").font(DS.sub(.semibold)).foregroundColor(DS.text.secondary)
                Spacer()
                QuickActionEditMenu {
                    HStack(spacing: 3) { Image(systemName: "slider.horizontal.3").font(DS.cap()); Text("编辑").font(DS.sub()) }
                        .foregroundColor(DS.text.secondary)
                }.accessibilityIdentifier("panel.actions.edit")
            }.padding(.horizontal, 2)
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(0..<rows, id: \.self) { r in
                    GridRow {
                        ForEach(actions.indices.filter { $0 / 2 == r }, id: \.self) { i in actionButton(actions[i]) }
                    }
                }
            }
            Hairline()
            HStack(spacing: 0) {
                stat("\(st.optimized)", "项已优化"); Divider().frame(height: 18)
                stat("\(st.quitApps)", "个应用已退出"); Divider().frame(height: 18)
                stat(Fmt.mem(st.freedMB), "内存已释放")
            }.accessibilityElement(children: .combine).accessibilityIdentifier("panel.stats")
        }.padding(8).card()
    }
    func actionButton(_ a: QuickAction) -> some View {
        let on = a.isOn()
        let state = a.stateLabel()
        return Button { a.run() } label: {
            HStack(spacing: 6) {
                IconBadge(symbol: a.symbol, tint: on ? good : accent, size: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(a.title).font(DS.sub(.medium)).foregroundColor(.primary).lineLimit(1)
                    Text(state.isEmpty ? a.hint : state).font(DS.cap(.regular)).foregroundColor(on ? DS.text.good : DS.text.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 38)
            .background(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous).fill(on ? good.opacity(0.10) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous).strokeBorder(on ? good.opacity(0.35) : DS.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(a.title + (state.isEmpty ? "（\(a.hint)）" : "：" + state))
        .accessibilityLabel(a.title + (state.isEmpty ? "" : "，" + state))
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(a.id)
    }
    func stat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 0) {
            Text(v).font(DS.num(13, .semibold))
            Text(l).font(DS.cap(.regular)).foregroundColor(DS.text.secondary)
        }.frame(maxWidth: .infinity)
    }
}
