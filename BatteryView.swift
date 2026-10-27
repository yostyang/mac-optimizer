import SwiftUI
import AppKit

struct Card<C: View>: View {
    let title: String; var icon: String = ""; @ViewBuilder let content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) { if !icon.isEmpty { Image(systemName: icon).foregroundColor(accent) }; Text(title).font(.system(size: 13, weight: .semibold)) }
            content
        }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading).card()
    }
}

struct BatteryPage: View {
    @ObservedObject var m: Monitor
    @ObservedObject var al = BatteryAlerts.shared
    @ObservedObject var en = EnergyTracker.shared
    @State private var range: EnergyStore.Range = .day
    var now = Date()
    var body: some View {
        let s = m.s
        PageScroll {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("电池").font(.system(size: 24, weight: .bold))
                    Text("健康、外设电量、耗电排行和提醒").font(.system(size: 12)).foregroundColor(.secondary)
                }
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 14) { health(s); devices(s); sounds; limits }.frame(maxWidth: .infinity)
                    VStack(spacing: 14) { energy; alerts }.frame(maxWidth: .infinity)
                }
            }.padding(28)
        }.onAppear { m.dashboardShown = true; en.sampleNow() }.onDisappear { m.dashboardShown = false }
    }

    func kv(_ k: String, _ v: String, _ c: Color = .primary) -> some View {
        HStack { Text(k).font(.system(size: 12)).foregroundColor(.secondary); Spacer(); Text(v).font(.system(size: 12, weight: .medium)).foregroundColor(c).monospacedDigit() }
    }
    func health(_ s: Snapshot) -> some View {
        Card(title: "电池健康", icon: "heart.text.square") {
            if let b = s.battery {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().stroke(batteryColor(b).opacity(0.15), lineWidth: 7)
                        Circle().trim(from: 0, to: CGFloat(b) / 100).stroke(batteryColor(b), style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
                        VStack(spacing: 0) { Text("\(b)%").font(.system(size: 18, weight: .bold, design: .rounded)); Text(s.charging ? "充电中" : (s.onAC ? "已接电源" : "电池供电")).font(.system(size: 9)).foregroundColor(.secondary) }
                    }.frame(width: 78, height: 78)
                    VStack(spacing: 6) {
                        kv("健康度", s.batteryHealth.map { "\($0)%" } ?? "不可读", (s.batteryHealth ?? 100) < 80 ? .orange : good)
                        kv("容量", s.fullMah > 0 ? "\(s.fullMah) / \(s.designMah) mAh" : "—")
                        kv("循环次数", s.cycles.map { "\($0) 次" } ?? "—")
                        kv("温度", s.batteryTemp.map { String(format: "%.1f°C", $0) } ?? "不可读", (s.batteryTemp ?? 0) > 40 ? .orange : .primary)
                        kv("状况", s.batteryCondition)
                    }
                }
                Text(advice(s)).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            } else { Text("这台 Mac 没有内置电池").foregroundColor(.secondary) }
        }
    }
    func advice(_ s: Snapshot) -> String {
        if let t = s.batteryTemp, t > 40 { return "⚠️ 电池温度偏高，避免边充电边高负载，放在通风处。" }
        if let h = s.batteryHealth, h < 80 || s.batteryCondition == "建议维修" { return "电池容量已低于 80%，可以考虑到 Apple 授权服务商检测或更换。" }
        return "电池状态良好。长期插电使用时，可在系统设置里开启「充电上限」减少损耗。"
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
            Text("显示系统公开电量的设备（苹果键鼠、AirPods 等）。罗技、Keychron 等第三方蓝牙设备的电量 macOS 不对外提供，读不到时不显示。").font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    var energy: some View {
        let rows = Array(en.store.summary(range, now: now).prefix(6))
        let mx = rows.first?.joules ?? 1
        return Card(title: "应用耗电", icon: "bolt.fill") {
            HStack {
                Picker("", selection: $range) { ForEach(EnergyStore.Range.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
                Spacer()
            }
            if !en.live.isEmpty { HStack { Text("当前最耗电：" + en.live.prefix(2).map { "\($0.app) " + String(format: "%.1f W", $0.watts) }.joined(separator: "、")).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1) } }
            if rows.isEmpty { Text("正在收集数据（每分钟记录一次，几分钟后就有结果）").font(.system(size: 12)).foregroundColor(.secondary).padding(.vertical, 6) }
            ForEach(rows) { r in
                HStack(spacing: 10) {
                    Text(r.app).font(.system(size: 12)).lineLimit(1).frame(width: 120, alignment: .leading)
                    Bar(frac: r.joules / mx, color: accent2, height: 6)
                    Spark(values: r.series, color: accent).frame(width: 64, height: 18)
                    Text(Fmt.energy(r.joules)).font(.system(size: 11, weight: .medium)).monospacedDigit().frame(width: 70, alignment: .trailing)
                }
            }
            Toggle("在后台记录耗电（每分钟采样一次，开销极低）", isOn: $al.settings.energyTracking).toggleStyle(.switch).controlSize(.small).font(.system(size: 11))
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
                                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).frame(width: 46).padding(.vertical, 3)
                                .background(Capsule().fill(on ? accent : accent.opacity(0.10))).foregroundColor(on ? .white : accent)
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
        }.disabled(!al.settings.alertsOn).opacity(al.settings.alertsOn ? 1 : 0.5).font(.system(size: 12))
    }
    var limits: some View {
        Card(title: "充电控制", icon: "bolt.batteryblock") {
            Text("充电上限、航行模式、自动放电、一键充满、MagSafe 灯控制都需要写入 SMC，必须安装管理员权限的后台助手。为了安全本应用不安装任何特权组件，因此不提供这些开关。macOS 自带的「充电上限」和「低电量模式」可以在系统设置里直接调整：").font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { SystemPanes.battery() } label: { Label("打开系统设置 › 电池", systemImage: "gear") }.buttonStyle(PillButton(filled: false))
        }
    }
}
