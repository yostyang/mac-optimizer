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
                        Text("网络诊断").font(DS.title())
                        Text(nav.netTab == 0 ? "延迟、丢包、DNS 检测与一键修复（只在点击时检测）" : (nav.netTab == 1 ? "下载、上传、三种延迟与抖动，打开即测" : "按应用的真实收发字节，实时与 1 分钟～30 天历史")).font(.system(size: 12)).foregroundColor(DS.text.secondary)
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
                Text("诊断详情与 DNS 修复").font(DS.title())
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
        if r.loss >= 20 || r.avgMs == nil { return .red }
        if r.loss > 0 || (r.avgMs ?? 0) > 150 { return .orange }
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
                        Text(t.name).font(.system(size: 12, weight: .medium))
                        Text(t.host).font(.system(size: 12)).foregroundColor(DS.text.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(t.result?.avgMs.map { String(format: "%.0f ms", $0) } ?? "超时").font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 60, alignment: .trailing)
                    Text("丢包 " + String(format: "%.0f%%", t.result?.loss ?? 100)).font(.system(size: 12)).foregroundColor((t.result?.loss ?? 100) > 0 ? DS.text.warn : DS.text.secondary).monospacedDigit().frame(width: 64, alignment: .trailing)
                }
            }
            if nd.tcpOK == true {
                Text("TCP 能连通：上面 ping 超时 / 丢包可能是 VPN / TUN 拦截了 ICMP，不是网络本身不稳定，丢包结论仅供参考。").font(.system(size: 12)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
            } else if nd.vpnActive && nd.targets.contains(where: { ($0.result?.loss ?? 0) >= 20 }) {
                Text("VPN / TUN 正在运行：ping 丢包仅供参考，请以实际使用为准。").font(.system(size: 12)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
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
                    HStack { Text(s.service).font(.system(size: 12)); Spacer(); Text(s.servers.isEmpty ? "自动（路由器分配）" : s.servers.joined(separator: ", ")).font(.system(size: 12, weight: .medium)).monospacedDigit().lineLimit(1) }
                }
            }
            if !nd.effective.isEmpty {
                HStack { Text("系统实际使用").font(.system(size: 12)).foregroundColor(DS.text.secondary); Spacer(); Text(nd.effective.joined(separator: ", ")).font(.system(size: 12, weight: .medium)).monospacedDigit().lineLimit(1) }
            }
            if !nd.resolves.isEmpty { Divider() }
            ForEach(nd.resolves) { r in
                HStack(spacing: 8) {
                    Image(systemName: r.verdict == .ok ? "checkmark.circle.fill" : (r.verdict == .vpnFake ? "shield.lefthalf.filled" : "exclamationmark.circle.fill"))
                        .foregroundColor(r.verdict == .ok ? DS.text.good : (r.verdict == .vpnFake ? accentText : (r.verdict == .slow ? DS.text.warn : DS.text.bad))).font(.system(size: 12))
                    Text(r.host).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text(r.verdict == .ok ? (r.ms.map { String(format: "%.0f ms", $0) } ?? "") : r.verdict.rawValue).font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
            }
            if nd.resolves.isEmpty { Text("诊断时会解析几个常用网站，并用一个不存在的域名检测运营商劫持。").font(.system(size: 12)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true) }
            if nd.resolves.contains(where: { $0.verdict == .vpnFake }) {
                Text("198.18.x.x 是 VPN 的虚拟地址（分流模式的正常现象），不是劫持。").font(.system(size: 12)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    var fixCard: some View {
        Card(title: "DNS 一键修复", icon: "wrench.and.screwdriver") {
            Text("把正在使用的网络的 DNS 改为阿里公共 DNS 223.5.5.5 / 223.6.6.6，并清除 DNS 缓存。修改前会保存原设置，随时可以恢复。").font(.system(size: 12)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
            if !nd.vpns.isEmpty || !runningVPNs.isEmpty || nd.tun {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.system(size: 12))
                    Text("\((nd.vpns.isEmpty ? (runningVPNs.isEmpty ? ["VPN / TUN"] : runningVPNs) : nd.vpns).joined(separator: "、")) 正在运行并可能接管 DNS：先不要用 DNS 一键修复，断开 VPN 后再试，否则改动可能被 VPN 覆盖、无效。").font(.system(size: 12)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
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

/// 蓝牙设备电量（电池页）：紧凑的 3 列小卡片，读不到的设备悬停可看原因
struct BTCard: View {
    @ObservedObject var bt = BTBattery.shared
    let macLevel: Int?
    struct Item: Identifiable { let id: String; let icon: String; let name: String; let p: Int?; let note: String }
    var items: [Item] {
        var a: [Item] = []
        if let m = macLevel { a.append(Item(id: "mac", icon: "laptopcomputer", name: "这台 Mac", p: m, note: "")) }
        for d in bt.devices where d.connected || d.percent != nil {
            a.append(Item(id: d.id, icon: d.kind, name: d.name, p: d.percent, note: d.percent == nil ? d.reason : (d.parts.isEmpty ? d.source : d.parts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)%" }.joined(separator: " "))))
        }
        return Array(a.prefix(6))
    }
    var body: some View {
        Card(title: "设备电量", icon: "dot.radiowaves.left.and.right") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 6)], spacing: 4) {
                ForEach(items) { it in chip(it) }
            }
            HStack {
                let unknown = bt.devices.filter { $0.connected && $0.percent == nil }
                if !unknown.isEmpty {
                    Text("电量未知：" + unknown.map(\.name).joined(separator: "、")).font(.system(size: 12)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
                        .help(unknown.map { $0.name + "：" + $0.reason }.joined(separator: "\n"))
                }
                if unknown.contains(where: KeychronHID.candidate), KeychronHID.access() != .granted {
                    // 文字链接样式：和旁边的说明同高，不把最小窗口下的卡片撑高
                    Button(action: {
                        if MOTests.active { return }
                        // 第一次弹系统授权；已拒绝过就直接打开设置页
                        if KeychronHID.access() == .denied || !KeychronHID.request() { KeychronHID.openSettings() }
                        bt.refresh()
                    }) { Text("读取 Keychron 电量").font(.system(size: 12, weight: .medium)).foregroundColor(accent) }
                    .buttonStyle(.plain).accessibilityIdentifier("bt.keychron.read")
                    .help("Keychron 键盘会自己上报电量，但系统不显示。读取它需要「输入监控」权限；本应用只取电量这一项，不记录任何按键。授权后如仍未显示，请退出并重新打开应用。")
                }
                Spacer(minLength: 4)
                if let updated = bt.updated { Text("更新 " + updated.formatted(date: .omitted, time: .shortened)).font(.system(size: 12)).foregroundColor(DS.text.secondary) }
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Toggle("低于 \(bt.settings.threshold)% 通知", isOn: $bt.settings.lowAlert).toggleStyle(.switch).controlSize(.mini).font(.system(size: 12)).accessibilityIdentifier("bt.lowAlert")
                if bt.loading { ProgressView().controlSize(.mini) }
                Button { bt.userAsked = true; bt.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 12)) }.buttonStyle(.plain).foregroundColor(accent).help("刷新（平时每 5 分钟自动刷新一次）").accessibilityIdentifier("bt.refresh")
            }.padding(.top, 13).padding(.trailing, 14)
        }
        .onAppear { if !bt.userAsked { bt.userAsked = true; bt.refresh() } }
    }
    func chip(_ it: Item) -> some View {
        let c = it.p.map { batteryColor($0) } ?? Color.secondary
        return HStack(spacing: 5) {
            Image(systemName: it.icon).font(.system(size: 12)).foregroundColor(accent).frame(width: 16)
            Text(it.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 2)
            Text(it.p.map { "\($0)%" } ?? "—").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundColor(it.p == nil ? DS.text.secondary : .primary)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(GeometryReader { g in ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05))
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(c.opacity(0.22)).frame(width: g.size.width * CGFloat(Double(it.p ?? 0) / 100))
        } })
        .help(it.p == nil ? "\(it.name)：读不到电量（\(it.note)）" : (it.note.isEmpty ? it.name : "\(it.name) · \(it.note)"))
    }
}
