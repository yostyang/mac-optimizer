import SwiftUI
import AppKit

struct Card<C: View>: View {
    let title: String; var icon: String = ""; @ViewBuilder let content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) { if !icon.isEmpty { Image(systemName: icon).foregroundColor(accentText) }; Text(title).font(DS.body(.semibold)) }
            content
        }.padding(DS.titledCardPadding).frame(maxWidth: .infinity, alignment: .topLeading).card()   // 2.12：改用令牌，取值仍为 12（16 会让电池页最小窗口超出 28 pt，等 2.13 改「详情局部滚动」后再统一）
    }
}

struct BatteryPage: View {
    @ObservedObject var m: Monitor
    @ObservedObject var al = BatteryAlerts.shared
    @ObservedObject var en = EnergyTracker.shared
    @ObservedObject var cc = ChargeClient.shared
    @State private var range: EnergyStore.Range = .day
    @State private var tab = 0
    var now = Date()
    var body: some View {
        let s = m.s
        // 2.13：标题、当前结论和标签固定在顶部（摘要），下面的卡片区可局部滚动
        PageScaffold(spacing: 9) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("电池").font(DS.title())
                    // 2.14：有电池时标题下就是「目标 / 实际 / 健康度」，不额外占行；暂停时下面多一句原因
                    if s.battery != nil {
                        ChargeSummaryRow(sum: ChargeSummary.make(phase: cc.phase, st: cc.st, reading: ChargeSummary.reading(s)), health: s.batteryHealth)
                    } else {
                        Text(Self.summaryLine(s)).font(.system(size: 12)).foregroundColor(DS.text.secondary).lineLimit(1)
                            .accessibilityIdentifier("bat.summary")
                    }
                }
                Spacer()
                // v2.0 双标签：功率卡片叠在原页上会超高，拆成两页后每页都放得下（与网络页双标签同款做法）
                SegmentedTrack {
                    Button("电池概览") { tab = 0 }.buttonStyle(PillButton(filled: tab == 0)).accessibilityIdentifier("bat.tab.0")
                    Button("功率与能耗") { tab = 1 }.buttonStyle(PillButton(filled: tab == 1)).accessibilityIdentifier("bat.tab.1")
                }
            }
        } details: {
            if tab == 0 {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 5) { health(s); BTCard(macLevel: s.battery); sounds; limits }.frame(maxWidth: .infinity)
                    VStack(spacing: 8) { energy; alerts }.frame(maxWidth: .infinity)
                }
            } else {
                powerTab(s)
            }
        }.onAppear { m.dashboardShown = true; en.sampleNow() }.onDisappear { m.dashboardShown = false }
    }

    /// 标题下一句：健康度与下方内容提示；电量和供电状态在「目标 / 实际」行（2.14）
    static func summaryLine(_ s: Snapshot) -> String {
        guard s.battery != nil else { return "健康、外设电量、耗电排行和提醒" }
        return (s.batteryHealth.map { "健康度 \($0)% · " } ?? "") + "外设电量、耗电排行和提醒在下方"
    }

    func powerTab(_ s: Snapshot, history: PowerHistory = .shared) -> some View {
        let flow = PowerFlowCalc.fromSnapshot(s)
        let top = PowerFlowCalc.topMW(store: en.store, now: now)
        let stale = s.batteryPowerUpdated.map { now.timeIntervalSince($0) >= 30 } ?? false
        let batteryPowerLabel = !flow.onAC || flow.dischargeWatts != nil ? "电池放电" : "充入电池"
        let batteryPowerValue = flow.dischargeWatts.map { Fmt.watts($0) }
            ?? (!flow.onAC ? "未取得" : (flow.charging ? Fmt.watts(flow.chargeWatts) : "未充电"))
        return HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 14) {
                Card(title: "整机功率", icon: "bolt.fill") {
                    HStack(spacing: 6) { ClayDot(); Text(flow.supplyText).font(DS.sub()).foregroundColor(DS.text.secondary) }
                    HStack(spacing: 18) {
                        reading("充电器输入", flow.onAC ? Fmt.watts(flow.inputWatts) : Fmt.dash)
                        reading(batteryPowerLabel, batteryPowerValue)
                        reading("系统功耗（估算）", Fmt.watts(flow.systemWatts))
                        Spacer(minLength: 0)
                    }
                    if stale {
                        StateLine(kind: .stale, text: "电池读数已超过 30 秒没有更新", detail: "暂不显示估算值，等下一次读数。", actions: [.refresh { Monitor.shared.sampleNow() }], id: "power.stale")
                    }
                    Footnote(text: flow.inputNote + "；" + flow.systemNote + "。输入为进入 Mac 的功率，适配器上报功率单列；不代表插座侧实测，屏幕与外设不单独估算。")
                    if let updated = s.batteryPowerUpdated { UpdatedText(date: updated) }
                }
                PowerTrendCard(history: history)
            }.frame(maxWidth: .infinity)
            VStack(spacing: 14) {
                Card(title: "电池详情", icon: "info.circle") {
                    kv("整机运行时间", fmtUptime(s.uptime))
                    kv("电池电压", flow.voltageV.map { String(format: "%.2f V", $0) } ?? Fmt.dash)
                    kv("电池电流", flow.currentA.map { String(format: "%.2f A", $0) } ?? Fmt.dash)
                    kv("适配器上报功率", flow.adapterRatedWatts.map { String(format: "%.0f W", $0) } ?? Fmt.dash)
                    kv("循环次数", s.cycles.map { "\($0) 次" } ?? Fmt.dash)
                    kv("低电量模式", flow.lowPowerMode.map { $0 ? "开启" : "关闭" } ?? Fmt.dash)
                    Footnote(text: "电压、电流来自电池控制器；电流正值表示充电，负值表示放电。适配器上报功率是额定值，不是实时输入或插座实测。")
                    HStack(spacing: 10) {
                        Button("打开系统电源设置") { SystemPanes.battery() }.buttonStyle(PillButton(filled: false)).accessibilityIdentifier("bat.lowpower.settings")
                        Footnote(text: "低电量模式只展示状态，不在应用内直接改系统设置。")
                    }
                }
                Card(title: "应用能耗（按进程估算）", icon: "cpu") {
                    if top.isEmpty {
                        StateLine(kind: en.store.lastSample == nil ? .loading : .empty,
                                  text: en.store.lastSample == nil ? "还没有应用能耗采样" : "最近一小时没有应用能耗记录",
                                  detail: al.settings.energyTracking ? "每分钟采样一次，几分钟后再看。" : "后台记录已关闭，只在打开电池页时采样。",
                                  id: "energy.top.state")
                    }
                    ForEach(Array(top.enumerated()), id: \.offset) { _, r in
                        HStack { Text(r.app).font(DS.sub()).lineLimit(1); Spacer(); Text(String(format: "%.1f mW", r.mw)).font(DS.num(12)) }
                    }
                    Footnote(text: "口径：最近一完整小时平均（焦耳 ÷ 秒 × 1000），没有上一小时数据时用本小时累计平均。来自 macOS 进程能耗计数，是处理器能耗估算，不含屏幕、外设与充电损耗，不能和左侧整机功率直接相加对比。")
                }
            }.frame(maxWidth: .infinity)
        }
    }
    func reading(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(DS.sub()).foregroundColor(DS.text.secondary)
            Text(value).font(DS.num(17, .semibold)).foregroundColor(value == Fmt.dash ? DS.text.secondary : .primary)
        }.accessibilityElement(children: .combine)
    }

    func kv(_ k: String, _ v: String, _ c: Color = .primary) -> some View {
        HStack { Text(k).font(.system(size: 12)).foregroundColor(DS.text.secondary); Spacer(); Text(v).font(.system(size: 12, weight: .medium)).foregroundColor(c).monospacedDigit() }
    }
    func health(_ s: Snapshot) -> some View {
        Card(title: "电池健康", icon: "heart.text.square") {
            if let b = s.battery {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().stroke(batteryColor(b).opacity(0.15), lineWidth: 7)
                        Circle().trim(from: 0, to: CGFloat(b) / 100).stroke(batteryColor(b), style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
                        VStack(spacing: 0) { Text("\(b)%").font(.system(size: 17, weight: .bold, design: .rounded)); Text(s.charging ? "充电中" : (s.onAC ? "已接电源" : "电池供电")).font(.system(size: 12)).foregroundColor(DS.text.secondary) }
                    }.frame(width: 78, height: 78)
                    VStack(spacing: 4) {
                        kv("容量比（估算）", s.batteryHealth.map { "\($0)%" } ?? Fmt.dash, (s.batteryHealth ?? 100) < 80 ? .orange : .primary)
                        kv("当前最大容量", s.fullMah > 0 ? "\(s.fullMah) mAh" : Fmt.dash)
                        kv("设计容量", s.designMah > 0 ? "\(s.designMah) mAh" : Fmt.dash)
                        kv("循环次数", s.cycles.map { "\($0) 次" } ?? "—")
                        kv("温度", s.batteryTemp.map { String(format: "%.1f°C", $0) } ?? Fmt.dash, (s.batteryTemp ?? 0) > 40 ? .orange : .primary)
                        kv("系统健康状态", s.batteryCondition.isEmpty ? "未取得" : s.batteryCondition)
                    }
                }
                Footnote(text: "容量比为估算；系统状态独立读取；温度：\(s.batteryTempSource.isEmpty ? "未取得" : s.batteryTempSource)。")
                Text(advice(s)).font(.system(size: 12)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
            } else { StateLine(kind: .unknown, text: "未读取到内置电池信息", detail: "可能没有内置电池，或系统暂时未返回数据。", id: "battery.health.unknown") }
        }
    }
    func advice(_ s: Snapshot) -> String {
        if let t = s.batteryTemp, t > 40 { return "⚠️ 电池温度偏高，避免边充电边高负载，放在通风处。" }
        if s.batteryCondition == "建议维修" { return "系统提示电池需要维修，可在系统电池设置中查看详情。" }
        if let h = s.batteryHealth, h < 80 { return "估算容量比低于 80%，可在系统电池设置中核对健康状态。" }
        return s.batteryHealth != nil && s.batteryCondition == "正常" ? "电池状态良好。可在下方管理充电上限。" : "部分健康信息尚未取得，可在系统电池设置中查看。"
    }
    func devices(_ s: Snapshot) -> some View {
        Card(title: "所有设备", icon: "dot.radiowaves.left.and.right") {
            let all = ([s.battery.map { DeviceBattery(name: "这台 Mac", percent: $0, kind: "laptopcomputer") }].compactMap { $0 } + s.devices).sorted { $0.percent < $1.percent }
            ForEach(all) { d in
                HStack(spacing: 10) {
                    Image(systemName: d.kind).frame(width: 18).foregroundColor(accent)
                    Text(d.name).font(.system(size: 12)).lineLimit(1).frame(width: 110, alignment: .leading)
                    Bar(frac: Double(d.percent) / 100, color: batteryColor(d.percent), height: 7)
                    Text("\(d.percent)%").font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 38, alignment: .trailing)
                }
            }
            Text("外设电量取决于设备、固件和连接方式；未取得的读数会标为未知。").font(.system(size: 12)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    var energy: some View {
        let rows = Array(en.store.summary(range, now: now).prefix(6))
        let mx = rows.first?.joules ?? 1
        let cov = EnergyCoverage.compute(en.store, range: range, now: now)
        return Card(title: "应用耗电（按进程估算）", icon: "bolt.fill") {
            HStack(spacing: 10) {
                Picker("", selection: $range) { ForEach(EnergyStore.Range.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                CoverageStrip(buckets: cov.buckets).frame(maxWidth: .infinity).accessibilityIdentifier("energy.coverage.strip")
                    .help("每格一个时间段，空格表示没有采样")
            }
            Text(cov.summary(now: now)).font(DS.cap(.regular)).foregroundColor(DS.text.secondary)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("energy.coverage")
            if !en.live.isEmpty { Text("当前应用能耗最高：" + en.live.prefix(2).map { "\($0.app) " + Fmt.watts($0.watts) }.joined(separator: "、")).font(DS.sub()).foregroundColor(DS.text.secondary).lineLimit(1) }
            if rows.isEmpty {
                StateLine(kind: cov.firstSample == nil ? .loading : .empty,
                          text: cov.firstSample == nil ? "正在收集数据" : "这个时间范围没有应用耗电记录",
                          detail: cov.firstSample == nil ? "每分钟记录一次，几分钟后就有结果。" : "App 没运行或关闭后台记录的时段不会有数据，不按 0 计。",
                          id: "energy.state")
            }
            ForEach(rows) { r in
                HStack(spacing: 10) {
                    Text(r.app).font(DS.sub()).lineLimit(1).frame(width: 120, alignment: .leading)
                    Bar(frac: r.joules / mx, color: accent2, height: 6)
                    Spark(values: r.series, color: accent).frame(width: 64, height: 18)
                    Text(Fmt.energy(r.joules)).font(DS.num(12)).frame(width: 70, alignment: .trailing)
                }
            }
            Toggle("在后台记录耗电（每分钟采样一次，开销极低）", isOn: $al.settings.energyTracking).toggleStyle(.switch).controlSize(.small).font(DS.sub())
                .help("这里是按进程估算的处理器能耗，不是整机功率；整机功率与趋势在「功率与能耗」标签。")
        }
    }
    var alerts: some View {
        Card(title: "电量提醒", icon: "bell.badge") {
            Toggle("开启电量提醒（系统通知）", isOn: $al.settings.alertsOn).toggleStyle(.switch).controlSize(.small).accessibilityIdentifier("bat.alertsOn")
            Group {
                Text("低电量提醒（可多选）").font(.system(size: 12))
                ForEach([[3, 5, 10, 15], [20, 30, 40, 50]], id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(row, id: \.self) { t in
                            let on = al.settings.lowThresholds.contains(t)
                            Button("\(t)%") { if on { al.settings.lowThresholds.removeAll { $0 == t } } else { al.settings.lowThresholds.append(t); al.settings.lowThresholds.sort() } }
                                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).frame(width: 46).padding(.vertical, 3)
                                .background(Capsule().fill(on ? DS.selectionFill : accent.opacity(0.10))).foregroundColor(on ? DS.text.onSelection : accentText)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Toggle("充到", isOn: $al.settings.upperOn)
                    Stepper("\(al.settings.upper)% 时提醒拔电", value: $al.settings.upper, in: 50...99, step: 5).fixedSize()
                }
                HStack(spacing: 14) { Toggle("接通电源", isOn: $al.settings.plugOn); Toggle("断开电源", isOn: $al.settings.unplugOn); Toggle("充满", isOn: $al.settings.fullOn) }
                Toggle("应用耗电异常", isOn: $al.settings.drainAlertsOn)
                Toggle("电量 ≤ \(al.settings.criticalLevel)% 时全屏发光提醒", isOn: $al.settings.criticalGlow)
                Toggle("外设电量 ≤ \(al.settings.deviceLow)% 或充满时提醒", isOn: $al.settings.deviceAlertsOn)
            }.disabled(!al.settings.alertsOn).opacity(al.settings.alertsOn ? 1 : 0.5)
        }.toggleStyle(.checkbox).font(.system(size: 12))
    }
    var sounds: some View {
        Card(title: "提示音", icon: "speaker.wave.2") {
            if !al.settings.alertsOn {
                Text("开启电量提醒后，可设置接电、充满和低电量提示音。").font(.system(size: 12)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    ForEach([[("plug", "接电"), ("unplug", "断电"), ("upper", "上限")], [("full", "充满"), ("low", "低电")]], id: \.first!.0) { row in
                        GridRow {
                            ForEach(row, id: \.0) { k, n in
                                Picker(n, selection: Binding(get: { al.settings.sounds[k] ?? "Pop" }, set: { al.settings.sounds[k] = $0; if $0 != "无声" { NSSound(named: $0)?.play() } })) {
                                    ForEach(BatterySettings.soundChoices, id: \.self) { Text($0).tag($0) }
                                }.frame(width: 118)
                            }
                        }
                    }
                }
            }
        }.font(.system(size: 12))
    }
    var limits: some View { ChargeCard(c: ChargeClient.shared).onAppear { ChargeClient.shared.refresh() } }
}
