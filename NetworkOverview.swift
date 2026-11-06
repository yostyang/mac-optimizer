import SwiftUI

/// 首屏读数的来源边界：公网为固定目标 ICMP，DNS 为真实域名解析耗时。
enum NetworkSummary {
    static func latency(targets: [PingTarget], resolves: [ResolveResult]) -> (publicMS: Double?, routerMS: Double?, dnsMS: Double?, loss: Double?) {
        let internet = targets.first { $0.host == "223.5.5.5" }?.result
        let router = targets.first { $0.name.hasPrefix("路由器") }?.result
        let dns = resolves.first { $0.host == "www.baidu.com" }
        return (internet?.avgMs, router?.avgMs, dns.flatMap { $0.verdict == .failed ? nil : $0.ms }, internet.flatMap { $0.sent > 0 ? $0.loss : nil })
    }
    /// 与按应用排行使用相同的小时桶，避免将分钟覆盖量与小时排行放在一起比较。
    static func hourlyTotals(_ hours: [THour], range: TrafficRange, now: Date = Date()) -> (inB: UInt64, outB: UInt64, buckets: Int) {
        let start = Int64(now.timeIntervalSince1970 / 3600) - Int64(range.rawValue / 60)
        let selected = hours.filter { $0.t > start }
        return (selected.reduce(0) { $0 + $1.i }, selected.reduce(0) { $0 + $1.o }, selected.count)
    }
    static func rate(_ value: Double) -> (value: String, unit: String) {
        value >= 1_048_576 ? (String(format: "%.1f", value / 1_048_576), "MiB/s") : (String(format: "%.0f", value / 1024), "KiB/s")
    }
    static func bytes(_ value: UInt64) -> (value: String, unit: String) {
        if value >= 1_073_741_824 { return (String(format: "%.2f", Double(value) / 1_073_741_824), "GiB") }
        if value >= 1_048_576 { return (String(format: "%.1f", Double(value) / 1_048_576), "MiB") }
        if value >= 1024 { return (String(format: "%.0f", Double(value) / 1024), "KiB") }
        return (String(value), "B")
    }
    static func size(_ value: UInt64) -> String { let x = bytes(value); return x.value + " " + x.unit }
}

@MainActor struct NetworkOverview: View {
    @Binding var showDetails: Bool
    @ObservedObject var mon = Monitor.shared
    @ObservedObject var nd = NetDiag.shared
    @ObservedObject var history = TrafficHistory.shared
    @ObservedObject var traffic = AppTraffic.shared
    @ObservedObject var card = NetCard.shared
    @State private var range: TrafficRange = .day1
    private var readings: (publicMS: Double?, routerMS: Double?, dnsMS: Double?, loss: Double?) {
        NetworkSummary.latency(targets: nd.targets, resolves: nd.resolves)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: DS.cardGap) {
            KPIStrip(items: [
                MetricStat("网络 / 接口", mon.s.netIface.isEmpty ? "等待采样" : mon.s.netKind + " · " + mon.s.netIface),
                MetricStat("代理 / VPN", nd.vpnActive || traffic.tunOn ? "VPN / TUN 已启用" : (mon.s.proxy.isEmpty ? "未取得状态" : mon.s.proxy)),
                MetricStat("系统 DNS", nd.effective.isEmpty ? "诊断后显示" : nd.effective.joined(separator: "、")),
                MetricStat("外网 IP", card.publicIP ?? (card.running ? "检测中…" : "点击开始诊断"))
            ])
            HStack(spacing: DS.cardGap) {
                latencyTile
                rateTile(upload: true)
                rateTile(upload: false)
            }
            HStack(alignment: .top, spacing: DS.cardGap) {
                totalsCard
                appsCard
            }
            HStack(alignment: .center, spacing: 12) {
                Footnote(text: "延迟与外网 IP 仅点击时检测；DNS 为百度域名解析耗时。网卡与应用均按小时记录，缺记录不补零；VPN 转发与完整排行见「流量」。")
                Spacer(minLength: 0)
                Button("诊断详情与 DNS 修复") { showDetails = true }
                    .buttonStyle(PillButton(filled: false)).accessibilityIdentifier("net.details")
            }
        }
        .onAppear { mon.sampleNow(); traffic.addLiveViewer() }
        .onDisappear { traffic.removeLiveViewer() }
    }
    private var latencyTile: some View {
        let r = readings
        let loss = r.loss.map { String(format: "丢包 %.0f%%", $0) } ?? "未检测"
        let time = nd.lastRun.map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
        return MetricTile(title: "公网延迟", symbol: "waveform.path", tint: DS.metric.network,
                          value: r.publicMS.map { String(format: "%.0f", $0) }, unit: "ms", note: loss + " " + time,
                          stats: [MetricStat("路由器", r.routerMS.map { String(format: "%.0f ms", $0) } ?? "—"),
                                  MetricStat("DNS · 百度", r.dnsMS.map { String(format: "%.0f ms", $0) } ?? "—")],
                          unavailableReason: nd.lastRun == nil ? "点击开始诊断，检测 ICMP 至 223.5.5.5" : "ICMP 至 223.5.5.5 未返回延迟；VPN 可能拦截 ICMP")
    }
    private func rateTile(upload: Bool) -> some View {
        let current = traffic.liveTotal.map { upload ? $0.1 : $0.0 }
        let samples = traffic.liveSeries.map { upload ? $0.1 : $0.0 }
        let formatted = current.map(NetworkSummary.rate)
        let peak = (samples + (current.map { [$0] } ?? [])).max().map { NetworkSummary.rate($0) }
        return MetricTile(title: upload ? "上行" : "下行", symbol: upload ? "arrow.up" : "arrow.down", tint: DS.metric.network,
                          value: formatted?.value, unit: formatted?.unit ?? "KiB/s", note: "物理网卡",
                          series: samples,
                          stats: [MetricStat("记录内峰值", peak.map { $0.value + " " + $0.unit } ?? "—"),
                                  MetricStat("更新", traffic.updated.map { $0.formatted(date: .omitted, time: .shortened) } ?? "等待采样")],
                          unavailableReason: "尚无连续两次物理网卡计数；已复用按应用流量采样器")
    }
    private var totalsCard: some View {
        let totals = NetworkSummary.hourlyTotals(history.hours, range: range)
        let size = NetworkSummary.bytes(totals.inB + totals.outB)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("总流量").font(DS.label()).foregroundColor(DS.metric.network)
                Spacer()
                InlineSegment(items: [("24 小时", TrafficRange.day1), ("30 天", .day30)], selection: $range)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if totals.buckets > 0 { Text(size.value).font(DS.hero()); Text(size.unit).font(DS.unit()).foregroundColor(.secondary) }
                else { Unavailable(reason: "此时段尚无流量记录").font(DS.hero()) }
            }
            SubStats(items: [MetricStat("下行", totals.buckets > 0 ? NetworkSummary.size(totals.inB) : "—"),
                             MetricStat("上行", totals.buckets > 0 ? NetworkSummary.size(totals.outB) : "—")])
            Footnote(text: "已记录 \(totals.buckets) 个小时段 · 当前时段尚未结束")
        }.padding(DS.cardPadding).frame(maxWidth: .infinity, minHeight: 206, maxHeight: 206, alignment: .topLeading).card()
    }
    private var appsCard: some View {
        let apps = Array(history.apps(range).prefix(4))
        let highest = apps.first?.total ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("按应用").font(DS.label()).foregroundColor(DS.metric.network)
                Spacer()
                Text(range.title + " · 小时记录").font(DS.cap()).foregroundColor(.secondary)
            }
            if apps.isEmpty {
                Text("暂无应用流量记录").font(DS.body()).foregroundColor(.secondary)
                Footnote(text: "有采样记录后显示；未记录的应用不记为 0。")
            } else {
                BarList(items: apps.map { BarListItem(name: $0.name, value: NetworkSummary.size($0.total), fraction: highest > 0 ? Double($0.total) / Double(highest) : 0) })
            }
        }.padding(DS.cardPadding).frame(maxWidth: .infinity, minHeight: 206, maxHeight: 206, alignment: .topLeading).card()
    }
}
