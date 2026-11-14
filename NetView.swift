import SwiftUI
import AppKit

struct NetworkPage: View {
    @ObservedObject var nd = NetDiag.shared
    @ObservedObject var dns = DNSClient.shared
    @ObservedObject var charge = ChargeClient.shared
    @ObservedObject var nav = Nav.shared
    @State private var showDetails = false
    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("网络诊断").font(DS.title()).contrastTarget("page.title", .largeText)
                        Text(nav.netTab == 0 ? "延迟、丢包、DNS 检测与一键修复（只在点击时检测）" : (nav.netTab == 1 ? "下载、上传、三种延迟与抖动，打开即测" : "按应用的真实收发字节，实时与 1 分钟～30 天历史")).font(DS.sub()).foregroundColor(DS.text.secondary)
                    }
                    Spacer()
                    // 双标签放在标题行，不另占一行：v1.7 三张新卡片叠在原诊断页上会超高 277 pt，
                    // 拆成两页后每页都能在默认/最小窗口里完整放下，不用滚动。
                    SegmentedTrack {
                        Button("诊断") { nav.netTab = 0 }.buttonStyle(PillButton(filled: nav.netTab == 0)).accessibilityIdentifier("net.tab.0")
                        Button("测速") { nav.netTab = 1 }.buttonStyle(PillButton(filled: nav.netTab == 1)).accessibilityIdentifier("net.tab.1")
                        Button("流量") { nav.netTab = 2 }.buttonStyle(PillButton(filled: nav.netTab == 2)).accessibilityIdentifier("net.tab.2")
                    }
                    if nav.netTab == 0 {
                        Button { nd.run(); dns.refresh(); NetCard.shared.refresh() } label: { Label(nd.running ? "诊断中…" : "开始诊断", systemImage: "stethoscope") }.buttonStyle(PillButton()).disabled(nd.running).accessibilityIdentifier("net.run")
                    }
                }
                if nav.netTab == 0 {
                    NetworkOverview(showDetails: $showDetails)
                } else if nav.netTab == 1 {
                    SpeedTab24()
                } else {
                    TrafficTab24()
                }
            }.padding(20)
        }.onAppear { dns.refresh() }
        .sheet(isPresented: $showDetails) { diagnosticDetails }
    }
    var diagnosticDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("诊断详情与 DNS 修复").font(DS.title()).contrastTarget("page.title", .largeText)
                Spacer()
                Button("完成") { showDetails = false }.buttonStyle(PillButton(filled: false)).accessibilityIdentifier("net.details.close")
            }
            Footnote(text: nd.summary.0)
            ScrollView {
                HStack(alignment: .top, spacing: DS.cardGap) {
                    VStack(spacing: DS.cardGap) { pingCard; fixCard }.frame(maxWidth: .infinity)
                    dnsCard.frame(maxWidth: .infinity)
                }.padding(1)
            }
        }.padding(20).frame(width: 840, height: 600).background(pageBG)
    }
    func color(_ r: PingResult?) -> Color {
        guard let r else { return .secondary }
        if r.loss >= 20 || r.avgMs == nil { return bad }
        if r.loss > 0 || (r.avgMs ?? 0) > 150 { return warn }
        return good
    }
    var pingCard: some View {
        Card(title: "延迟与丢包", icon: "waveform.path") {
            if nd.targets.isEmpty {
                if nd.running { StateLine(kind: .loading, text: "正在测试延迟与丢包", id: "net.ping.state") }
                else { StateLine(kind: .empty, text: "还没有诊断", detail: "每个目标发 5 个包，约 2 秒。", actions: [.refresh { nd.run() }], id: "net.ping.state") }
            }
            ForEach(nd.targets) { t in
                HStack(spacing: 8) {
                    Circle().fill(color(t.result)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(t.name).font(DS.sub(.medium))
                        Text(t.host).font(DS.sub()).foregroundColor(DS.text.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(t.result?.avgMs.map { String(format: "%.0f ms", $0) } ?? "超时").font(DS.sub(.medium)).monospacedDigit().frame(width: 60, alignment: .trailing)
                    Text("丢包 " + String(format: "%.0f%%", t.result?.loss ?? 100)).font(DS.sub()).foregroundColor((t.result?.loss ?? 100) > 0 ? DS.text.warn : DS.text.secondary).monospacedDigit().frame(width: 64, alignment: .trailing)
                }
            }
            if nd.tcpOK == true {
                Text("TCP 能连通：上面 ping 超时 / 丢包可能是 VPN / TUN 拦截了 ICMP，不是网络本身不稳定，丢包结论仅供参考。").font(DS.sub()).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
            } else if nd.vpnActive && nd.targets.contains(where: { ($0.result?.loss ?? 0) >= 20 }) {
                Text("VPN / TUN 正在运行：ping 丢包仅供参考，请以实际使用为准。").font(DS.sub()).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    var dnsCard: some View {
        Card(title: "DNS 检测", icon: "server.rack") {
            let svcs = dns.status?.services ?? nd.services
            if let error = dns.status?.lastError, !error.isEmpty {
                StateLine(kind: .failed, text: error, actions: [.refresh { dns.refresh() }], id: "dns.read.error")
            }
            if !svcs.isEmpty {
                ForEach(svcs, id: \.service) { s in
                    HStack { Text(s.service).font(DS.sub()); Spacer(); Text(s.servers.isEmpty ? "自动（路由器分配）" : s.servers.joined(separator: ", ")).font(DS.sub(.medium)).monospacedDigit().lineLimit(1) }
                }
            }
            if !nd.effective.isEmpty {
                HStack { Text("系统实际使用").font(DS.sub()).foregroundColor(DS.text.secondary); Spacer(); Text(nd.effective.joined(separator: ", ")).font(DS.sub(.medium)).monospacedDigit().lineLimit(1) }
            }
            if !nd.resolves.isEmpty { Divider() }
            ForEach(nd.resolves) { r in
                HStack(spacing: 8) {
                    Image(systemName: r.verdict == .ok ? "checkmark.circle.fill" : (r.verdict == .vpnFake ? "shield.lefthalf.filled" : "exclamationmark.circle.fill"))
                        .foregroundColor(r.verdict == .ok ? DS.text.good : (r.verdict == .vpnFake ? accentText : (r.verdict == .slow ? DS.text.warn : DS.text.bad))).font(DS.sub())
                    Text(r.host).font(DS.sub()).lineLimit(1)
                    Spacer()
                    Text(r.verdict == .ok ? (r.ms.map { String(format: "%.0f ms", $0) } ?? "") : r.verdict.rawValue).font(DS.sub(.medium)).monospacedDigit()
                }
            }
            if nd.resolves.isEmpty { Text("诊断时会解析几个常用网站，并用一个不存在的域名检测运营商劫持。").font(DS.sub()).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true) }
            if nd.resolves.contains(where: { $0.verdict == .vpnFake }) {
                Text("198.18.x.x 是 VPN 的虚拟地址（分流模式的正常现象），不是劫持。").font(DS.sub()).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    var fixCard: some View {
        Card(title: "DNS 一键修复", icon: "wrench.and.screwdriver") {
            Text("把正在使用的网络的 DNS 改为阿里公共 DNS 223.5.5.5 / 223.6.6.6，并清除 DNS 缓存。修改前会保存原设置，随时可以恢复。").font(DS.sub()).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
            if !nd.vpns.isEmpty || !runningVPNs.isEmpty || nd.tun {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(warn).font(.system(size: 12))   // 图标
                    Text("\((nd.vpns.isEmpty ? (runningVPNs.isEmpty ? ["VPN / TUN"] : runningVPNs) : nd.vpns).joined(separator: "、")) 正在运行并可能接管 DNS：先不要用 DNS 一键修复，断开 VPN 后再试，否则改动可能被 VPN 覆盖、无效。").font(DS.sub()).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                if charge.phase == .ready || dns.direct != nil {
                    Button(dns.isAli ? "已是阿里 DNS" : "一键设为阿里 DNS") { dns.setAli() }.buttonStyle(PillButton()).disabled(dns.busy || dns.isAli).accessibilityIdentifier("dns.ali")
                    if dns.status?.backup != nil { Button("恢复原 DNS") { dns.restore() }.buttonStyle(PillButton(filled: false)).disabled(dns.busy).accessibilityIdentifier("dns.restore") }
                    if dns.busy { ProgressView().controlSize(.small) }
                } else {
                    StateLine(kind: .unknown, text: "需要先安装后台助手", detail: "在「电池 › 充电控制」安装一次，充电和 DNS 共用同一次授权。",
                              actions: [StateAction(title: "去电池页", symbol: "arrow.right") { showDetails = false; Nav.shared.sel = .battery }], id: "dns.helper.state")
                }
            }
            if !dns.note.isEmpty {
                StateLine(kind: dns.busy ? .loading : (dns.note.hasPrefix("已") ? .done : .failed), text: dns.note,
                          actions: !dns.busy && !dns.note.hasPrefix("已") ? [.refresh { dns.refresh() }] : [], id: "dns.note")
            }
        }
    }
    var runningVPNs: [String] { NSWorkspace.shared.runningApplications.compactMap { $0.localizedName }.filter { $0.contains("VPN") || $0.contains("鹊桥") } }
}

/// 蓝牙设备电量（电池页）。2.16 N5：每台设备单独显示有效 / 缓存 / 过期 / 未取得，
/// 原因和读取时间可以用鼠标或键盘打开（不只放在悬停提示里）。
struct BTCard: View {
    @ObservedObject var bt = BTBattery.shared
    let macLevel: Int?
    var now: Date? = nil
    var items: [BTDisplay] {
        Array(bt.displays(now: now ?? Date()).filter { $0.connected || $0.percent != nil }.prefix(6))
    }
    var body: some View {
        Card(title: "设备电量", icon: "dot.radiowaves.left.and.right") {
            VStack(spacing: 2) {
                if let m = macLevel { macRow(m) }
                ForEach(items) { d in BTDeviceRow(d: d, bt: bt) }
                if macLevel == nil && items.isEmpty {
                    StateLine(kind: .empty, text: "没有已连接的蓝牙外设", detail: "连接后会在下一次刷新时出现（平时每 5 分钟一次）。", actions: [.refresh { bt.userAsked = true; bt.refresh() }], id: "bt.state")
                }
            }
            HStack {
                if items.contains(where: { $0.keychron && $0.percent == nil }), KeychronHID.access() != .granted {
                    // 文字链接样式：和旁边的说明同高，不把最小窗口下的卡片撑高
                    Button(action: {
                        if MOTests.active { return }
                        // 第一次弹系统授权；已拒绝过就直接打开设置页
                        if KeychronHID.access() == .denied || !KeychronHID.request() { KeychronHID.openSettings() }
                        bt.refresh()
                    }) { Text("读取 Keychron 电量").font(DS.sub(.medium)).foregroundColor(accentText) }
                    .buttonStyle(.plain).accessibilityIdentifier("bt.keychron.read")
                    .help("Keychron 键盘会自己上报电量，但系统不显示。读取它需要「输入监控」权限；本应用只取电量这一项，不记录任何按键。授权后如仍未显示，请退出并重新打开应用。")
                }
                Spacer(minLength: 4)
                // 批次时间写成「尝试」：部分设备失败时，它不是每台设备的成功时间
                if let updated = bt.updated { Text("最近尝试 " + updated.formatted(date: .omitted, time: .shortened)).font(DS.sub()).foregroundColor(DS.text.secondary) }   // 时间
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Toggle("低于 \(bt.settings.threshold)% 通知", isOn: $bt.settings.lowAlert).toggleStyle(.switch).controlSize(.mini).font(DS.sub()).accessibilityIdentifier("bt.lowAlert")
                if bt.loading { ProgressView().controlSize(.mini) }
                Button { bt.userAsked = true; bt.refresh() } label: { Image(systemName: "arrow.clockwise").font(DS.sub()) }
                    .buttonStyle(.plain).foregroundColor(bt.loading ? DS.text.secondary : accentText).disabled(bt.loading)
                    .help(bt.loading ? "正在刷新…" : "刷新（平时每 5 分钟自动刷新一次）").accessibilityLabel(bt.loading ? "正在刷新设备电量" : "刷新设备电量").accessibilityIdentifier("bt.refresh")
            }.padding(.top, 13).padding(.trailing, 14)
        }
        .onAppear { if !bt.userAsked { bt.userAsked = true; bt.refresh() } }
    }
    func macRow(_ p: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "laptopcomputer").font(DS.sub()).foregroundColor(accentText).frame(width: 18).accessibilityHidden(true)
            Text("这台 Mac").font(DS.sub()).lineLimit(1)
            Spacer(minLength: 4)
            BatteryLevelView(name: "这台 Mac", percent: p, freshness: .fresh)
        }.frame(height: 22)
    }
}

/// 外设一行：名称 + 电量（或「— · 未取得 · 查看原因」）+ 详情入口
struct BTDeviceRow: View {
    let d: BTDisplay
    @ObservedObject var bt: BTBattery
    @State private var showDetail = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: d.kind).font(DS.sub()).foregroundColor(accentText).frame(width: 18).accessibilityHidden(true)
            Text(d.name).font(DS.sub()).lineLimit(1).truncationMode(.middle).layoutPriority(1)
            if !d.parts.isEmpty {
                Text(d.parts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)%" }.joined(separator: " ")).font(DS.cap(.regular)).foregroundColor(DS.text.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            BatteryLevelView(name: d.name, percent: d.percent, freshness: d.freshness)
            Button { showDetail = true } label: {
                if d.percent == nil { Text("查看原因").font(DS.sub(.medium)).foregroundColor(accentText) }
                else { Image(systemName: "info.circle").font(DS.sub()).foregroundColor(accentText) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(d.percent == nil ? "查看\(d.name)读不到电量的原因" : "查看\(d.name)电量的来源与时间")
            .accessibilityIdentifier("bt.detail." + d.id)
            .popover(isPresented: $showDetail, arrowEdge: .trailing) { BTReadingDetail(d: d, bt: bt, close: { showDetail = false }) }
        }
        .frame(height: 22)
        .accessibilityElement(children: .contain)
    }
}

/// 一台设备的读数详情：状态、原因、来源、最近尝试与最近成功读取，以及能执行的下一步
struct BTReadingDetail: View {
    let d: BTDisplay
    @ObservedObject var bt: BTBattery
    let close: () -> Void
    static func time(_ t: Date?) -> String { t.map { $0.formatted(date: .omitted, time: .shortened) + "（" + Fmt.ago($0) + "）" } ?? "还没有" }
    var statusText: String {
        switch d.freshness {
        case .fresh: return "有效读数"
        case .cached: return "缓存：这次没有读到，显示的是最近一次成功读取的值（\(Int(BTBattery.cacheWindow / 60)) 分钟内有效）"
        case .expired: return "已过期：最近一次成功读取已超过 \(Int(BTBattery.cacheWindow / 60)) 分钟，不再当作当前电量"
        case .unknown: return d.connected ? "未取得" : "未连接"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(d.name).font(DS.body(.semibold))
            Text(statusText).font(DS.sub()).fixedSize(horizontal: false, vertical: true)
            if let k = d.reasonKind {
                HStack(alignment: .top, spacing: 6) {
                    Text("原因").font(DS.sub()).foregroundColor(DS.text.secondary).frame(width: 72, alignment: .leading)
                    Text(k.title + (d.reason.isEmpty || d.reason == k.title ? "" : "：" + d.reason)).font(DS.sub()).fixedSize(horizontal: false, vertical: true)
                }
            }
            row("来源", d.source.isEmpty ? "—" : d.source)
            row("最近尝试", Self.time(d.lastAttemptAt))
            row("最近成功读取", d.lastSuccessAt == nil ? "还没有成功读取" : "读取于 " + Self.time(d.lastSuccessAt))
            if let p = d.lastPercent, d.freshness == .expired || d.freshness == .cached { row("最近成功值", "\(p)%") }
            if let rep = d.sourceReportedAt { row("设备上报于", Self.time(rep)) }   // 只有来源真的给出时间才显示
            if d.keychron {
                Footnote(text: "Keychron 电量来自键盘自报（HID 3 号报告）。已核对的型号与固件有限；没有在同一台键盘上取得两次不同电量的对照之前，不能据一次读数认定该型号可靠。")
            }
            HStack(spacing: 8) {
                ForEach(actions, id: \.0) { title, run in
                    Button(title) { run() }.buttonStyle(PillButton(filled: false)).disabled(bt.loading)
                }
                Spacer()
                Button("关闭") { close() }.buttonStyle(PillButton(filled: false)).keyboardShortcut(.cancelAction)
            }
        }
        .padding(14).frame(width: 340)
        .accessibilityElement(children: .contain).accessibilityIdentifier("bt.detail.panel")
    }
    func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(k).font(DS.sub()).foregroundColor(DS.text.secondary).frame(width: 72, alignment: .leading)
            Text(v).font(DS.sub()).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }
    }
    /// 每种原因给实际能做的下一步：刷新、打开对应的系统设置；不支持的读取路径只给说明（上面的文字），不给假按钮
    var actions: [(String, () -> Void)] {
        let refresh: (String, () -> Void) = (bt.loading ? "正在刷新…" : "刷新", { bt.userAsked = true; bt.refresh() })
        switch d.reasonKind {
        case .notConnected?: return [("打开蓝牙设置", { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!) }), refresh]
        case .unauthorized?:
            if d.keychron { return [("打开输入监控设置", { KeychronHID.openSettings() }), refresh] }
            return [("打开蓝牙权限设置", { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!) }), refresh]
        case .unsupported?: return [refresh]
        case .readFailed?, .noReport?, nil: return [refresh]
        }
    }
}
