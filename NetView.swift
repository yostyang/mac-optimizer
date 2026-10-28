import SwiftUI
import AppKit

struct NetworkPage: View {
    @ObservedObject var nd = NetDiag.shared
    @ObservedObject var dns = DNSClient.shared
    @ObservedObject var charge = ChargeClient.shared
    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("网络诊断").font(.system(size: 24, weight: .bold))
                        Text("延迟、丢包、DNS 检测与一键修复（只在点击时检测）").font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button { nd.run(); dns.refresh() } label: { Label(nd.running ? "诊断中…" : "开始诊断", systemImage: "stethoscope") }.buttonStyle(PillButton()).disabled(nd.running).accessibilityIdentifier("net.run")
                }
                let sm = nd.summary
                HStack(spacing: 8) {
                    Image(systemName: sm.1 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill").foregroundColor(sm.1 ? good : .orange)
                    Text(sm.0).font(.system(size: 13, weight: .medium))
                    Spacer()
                    if let t = nd.lastRun { Text("上次检测 " + t.formatted(date: .omitted, time: .shortened)).font(.system(size: 11)).foregroundColor(.secondary) }
                }.padding(12).frame(maxWidth: .infinity).card()
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 10) { pingCard; fixCard }.frame(maxWidth: .infinity)
                    VStack(spacing: 10) { dnsCard }.frame(maxWidth: .infinity)
                }
            }.padding(28)
        }.onAppear { dns.refresh() }
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
                Text(nd.running ? "正在测试…" : "每个目标发 5 个包，约 2 秒。").font(.system(size: 11)).foregroundColor(.secondary)
            }
            ForEach(nd.targets) { t in
                HStack(spacing: 8) {
                    Circle().fill(color(t.result)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(t.name).font(.system(size: 12, weight: .medium))
                        Text(t.host).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(t.result?.avgMs.map { String(format: "%.0f ms", $0) } ?? "超时").font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 60, alignment: .trailing)
                    Text("丢包 " + String(format: "%.0f%%", t.result?.loss ?? 100)).font(.system(size: 11)).foregroundColor((t.result?.loss ?? 100) > 0 ? .orange : .secondary).monospacedDigit().frame(width: 64, alignment: .trailing)
                }
            }
        }
    }
    var dnsCard: some View {
        Card(title: "DNS 检测", icon: "server.rack") {
            let svcs = dns.status?.services ?? nd.services
            if !svcs.isEmpty {
                ForEach(svcs, id: \.service) { s in
                    HStack { Text(s.service).font(.system(size: 12)); Spacer(); Text(s.servers.isEmpty ? "自动（路由器分配）" : s.servers.joined(separator: ", ")).font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1) }
                }
            }
            if !nd.effective.isEmpty {
                HStack { Text("系统实际使用").font(.system(size: 12)).foregroundColor(.secondary); Spacer(); Text(nd.effective.joined(separator: ", ")).font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1) }
            }
            if !nd.resolves.isEmpty { Divider() }
            ForEach(nd.resolves) { r in
                HStack(spacing: 8) {
                    Image(systemName: r.verdict == .ok ? "checkmark.circle.fill" : (r.verdict == .vpnFake ? "shield.lefthalf.filled" : "exclamationmark.circle.fill"))
                        .foregroundColor(r.verdict == .ok ? good : (r.verdict == .vpnFake ? accent2 : (r.verdict == .slow ? .orange : .red))).font(.system(size: 12))
                    Text(r.host).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text(r.verdict == .ok ? (r.ms.map { String(format: "%.0f ms", $0) } ?? "") : r.verdict.rawValue).font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
            }
            if nd.resolves.isEmpty { Text("诊断时会解析几个常用网站，并用一个不存在的域名检测运营商劫持。").font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
            if nd.resolves.contains(where: { $0.verdict == .vpnFake }) {
                Text("198.18.x.x 是 VPN 的虚拟地址（分流模式的正常现象），不是劫持。").font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    var fixCard: some View {
        Card(title: "DNS 一键修复", icon: "wrench.and.screwdriver") {
            Text("把正在使用的网络的 DNS 改为阿里公共 DNS 223.5.5.5 / 223.6.6.6，并清除 DNS 缓存。修改前会保存原设置，随时可以恢复。").font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if !nd.vpns.isEmpty || !runningVPNs.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.system(size: 11))
                    Text("\((nd.vpns.isEmpty ? runningVPNs : nd.vpns).joined(separator: "、")) 正在运行：VPN 开启时会接管 DNS，改动可能要等 VPN 断开后才生效。").font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                if charge.phase == .ready || dns.direct != nil {
                    Button(dns.isAli ? "已是阿里 DNS" : "一键设为阿里 DNS") { dns.setAli() }.buttonStyle(PillButton()).disabled(dns.busy || dns.isAli).accessibilityIdentifier("dns.ali")
                    if dns.status?.backup != nil { Button("恢复原 DNS") { dns.restore() }.buttonStyle(PillButton(filled: false)).disabled(dns.busy).accessibilityIdentifier("dns.restore") }
                    if dns.busy { ProgressView().controlSize(.small) }
                } else {
                    Text("需要先在「电池 › 充电控制」安装助手（一次授权，充电和 DNS 共用）。").font(.system(size: 11)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !dns.note.isEmpty { Text(dns.note).font(.system(size: 11)).foregroundColor(dns.note.hasPrefix("已") ? good : .red) }
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
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 4) {
                ForEach(items) { it in chip(it) }
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Toggle("低于 \(bt.settings.threshold)% 通知", isOn: $bt.settings.lowAlert).toggleStyle(.switch).controlSize(.mini).font(.system(size: 10)).accessibilityIdentifier("bt.lowAlert")
                if bt.loading { ProgressView().controlSize(.mini) }
                Button { bt.userAsked = true; bt.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }.buttonStyle(.plain).foregroundColor(accent).help("刷新（平时每 5 分钟自动刷新一次）").accessibilityIdentifier("bt.refresh")
            }.padding(.top, 13).padding(.trailing, 14)
        }
        .onAppear { if !bt.userAsked { bt.userAsked = true; bt.refresh() } }
    }
    func chip(_ it: Item) -> some View {
        let c = it.p.map { batteryColor($0) } ?? Color.secondary
        return HStack(spacing: 5) {
            Image(systemName: it.icon).font(.system(size: 11)).foregroundColor(accent).frame(width: 16)
            Text(it.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 2)
            Text(it.p.map { "\($0)%" } ?? "—").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundColor(it.p == nil ? .secondary : .primary)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(GeometryReader { g in ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05))
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(c.opacity(0.22)).frame(width: g.size.width * CGFloat(Double(it.p ?? 0) / 100))
        } })
        .help(it.p == nil ? "\(it.name)：读不到电量（\(it.note)）" : (it.note.isEmpty ? it.name : "\(it.name) · \(it.note)"))
    }
}
