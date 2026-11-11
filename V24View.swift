// 2.4 界面：按应用流量、流量历史、测速、网络卡片、卸载应用
import SwiftUI
import AppKit

enum Fmt24 {
    static func bytes(_ b: UInt64) -> String {
        let d = Double(b)
        if d >= 1_073_741_824 { return String(format: "%.2f GB", d / 1_073_741_824) }
        if d >= 1_048_576 { return String(format: "%.1f MB", d / 1_048_576) }
        if d >= 1024 { return String(format: "%.0f KB", d / 1024) }
        return "\(b) B"
    }
    static func mbps(_ v: Double?) -> String { v.map { $0 >= 100 ? String(format: "%.0f", $0) : String(format: "%.1f", $0) } ?? "—" }
    static func ms(_ v: Double?) -> String { v.map { String(format: "%.0f ms", $0) } ?? "未知" }
}

/// 折线图：nil 表示没有记录（画成空档，不连线、不补数）
struct GapChart: View {
    let series: [(down: Double?, up: Double?)]
    var body: some View {
        GeometryReader { g in
            ZStack {
                path(g.size, up: false).stroke(accent2, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                path(g.size, up: true).stroke(accent, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
    }
    func path(_ size: CGSize, up: Bool) -> Path {
        let mx = max(series.compactMap { max($0.down ?? 0, $0.up ?? 0) }.max() ?? 0, 1)
        let n = max(series.count - 1, 1)
        let vals = series.map { up ? $0.up : $0.down }
        var p = Path()
        for (i, v) in vals.enumerated() {
            guard let v else { continue }
            let q = CGPoint(x: series.count == 1 ? size.width / 2 : size.width * CGFloat(i) / CGFloat(n), y: size.height * (1 - CGFloat(v / mx)))
            let prevOK = i > 0 && vals[i - 1] != nil
            let nextOK = i < vals.count - 1 && vals[i + 1] != nil
            if prevOK { p.addLine(to: q) } else { p.move(to: q) }
            if !prevOK && !nextOK { p.addEllipse(in: CGRect(x: q.x - 1.5, y: q.y - 1.5, width: 3, height: 3)); p.move(to: q) }
        }
        return p
    }
}

// MARK: 按应用实时流量（菜单栏面板点网速打开，网络页也用）
struct AppTrafficList: View {
    @ObservedObject var t = AppTraffic.shared
    var limit = 8
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if t.updated == nil || (t.live.isEmpty && t.liveForwarder == nil) {
                StateLine(kind: t.updated == nil ? .loading : .empty,
                          text: t.updated == nil ? "正在采样" : "这 2 秒内没有应用在收发数据",
                          detail: t.updated == nil ? "两次读数相减才有速率，约 2 秒。" : "", id: "apptraffic.state")
            }
            ForEach(t.live.prefix(limit)) { a in
                HStack(spacing: 6) {
                    Text(a.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text("↓ " + Fmt.rate(Double(a.inB))).font(.system(size: 11, weight: .medium)).monospacedDigit().frame(width: 86, alignment: .trailing)
                    Text("↑ " + Fmt.rate(Double(a.outB))).font(.system(size: 11)).foregroundColor(accent).monospacedDigit().frame(width: 80, alignment: .trailing)
                }.accessibilityIdentifier("apptraffic.row")
            }
            if let f = t.liveForwarder {
                HStack(spacing: 6) {
                    Image(systemName: "shield.lefthalf.filled").font(.system(size: 10)).foregroundColor(DS.text.secondary)
                    Text(f.name + "（VPN 转发，已去重）").font(.system(size: 11)).foregroundColor(DS.text.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("↓ " + Fmt.rate(Double(f.inB)) + "  ↑ " + Fmt.rate(Double(f.outB))).font(.system(size: 10)).foregroundColor(DS.text.secondary).monospacedDigit()
                }.help("TUN 模式下应用流量先进隧道，再由 VPN 从物理网卡发出；这一行和上面的应用是同一份数据，不计入合计")
            }
        }
    }
}
struct AppTrafficPopover: View {
    @ObservedObject var t = AppTraffic.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("哪些应用在用网络").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let tot = t.liveTotal { Text("↓ " + Fmt.rate(tot.0) + "  ↑ " + Fmt.rate(tot.1)).font(.system(size: 11, weight: .medium)).monospacedDigit() }
            }
            AppTrafficList(limit: 10)
            Divider()
            Text("实时：每 2 秒按进程读取系统 nettop 的收发字节；" + (t.tunOn ? "检测到 TUN，VPN 转发进程单列不重复计算。" : "未检测到 TUN 隧道。")).font(.system(size: 10)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
            Button("查看 1 分钟～30 天历史") { NetPageLink.openTraffic() }.buttonStyle(PillButton(filled: false)).accessibilityIdentifier("apptraffic.history")
        }
        .padding(14).frame(width: 360)
        .onAppear { t.addLiveViewer() }.onDisappear { t.removeLiveViewer() }
    }
}
enum NetPageLink {
    static func openTraffic() { Nav.shared.sel = .network; Nav.shared.netTab = 2; UIState.shared.openMain() }
}

// MARK: 流量页（第三个标签）
struct TrafficTab24: View {
    @ObservedObject var h = TrafficHistory.shared
    @ObservedObject var t = AppTraffic.shared
    @State var range: TrafficRange = .hour1
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 10) { historyCard }.frame(maxWidth: .infinity)
            VStack(spacing: 10) {
                Card(title: "现在谁在用网络", icon: "app.connected.to.app.below.fill") { AppTrafficList(limit: 6) }
                NetCard24()
            }.frame(maxWidth: .infinity)
        }
        .onAppear { t.addLiveViewer() }.onDisappear { t.removeLiveViewer() }
    }
    var historyCard: some View {
        Card(title: "流量历史", icon: "chart.xyaxis.line") {
            if !h.saveError.isEmpty {
                StateLine(kind: .failed, text: h.saveError, id: "traffic.save.error")
                Button("重试保存") { h.save() }.buttonStyle(PillButton(filled: false)).accessibilityIdentifier("traffic.save.retry")
            }
            Picker("范围", selection: $range) { ForEach(TrafficRange.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("traffic.range")
            let tot = h.totals(range)
            if range == .minute1 {
                GapChart(series: t.liveSeries.map { (Optional($0.0), Optional($0.1)) }).frame(height: 90).accessibilityIdentifier("traffic.chart")
            } else {
                GapChart(series: h.series(range)).frame(height: 90).accessibilityIdentifier("traffic.chart")
            }
            HStack(spacing: 12) {
                Label("下载 " + Fmt24.bytes(tot.inB), systemImage: "arrow.down").foregroundColor(accent2)
                Label("上传 " + Fmt24.bytes(tot.outB), systemImage: "arrow.up").foregroundColor(accent)
                Spacer()
                Text("有记录 \(coverage(tot.coveredMinutes))").foregroundColor(DS.text.secondary)
            }.font(.system(size: 11, weight: .medium)).monospacedDigit()
            let apps = h.apps(range).prefix(5)
            if apps.isEmpty { StateLine(kind: .empty, text: "这段时间还没有按应用的记录", detail: "App 没运行的时段留空，不按 0 计。", id: "traffic.apps.state") }
            ForEach(Array(apps)) { a in
                HStack { Text(a.name).font(.system(size: 11)).lineLimit(1); Spacer(); Text("↓ " + Fmt24.bytes(a.inB) + "  ↑ " + Fmt24.bytes(a.outB)).font(.system(size: 11)).monospacedDigit().foregroundColor(DS.text.secondary) }
            }
            Text((t.enabled ? "后台每分钟记一次（关掉窗口也记），重启后记录还在，30 天外自动删除。" : "后台记录已关闭，只在这个页面打开时记录。") + "没开机或本应用没运行的时段留空，不补数。总量按物理网卡统计，TUN 时不重复。").font(.system(size: 10)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("后台记录流量历史", isOn: $t.enabled).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11)).accessibilityIdentifier("traffic.background")
        }
    }
    func coverage(_ m: Int) -> String { m >= 120 ? "\(m / 60) 小时" : "\(m) 分钟" }
}

struct NetCard24: View {
    @ObservedObject var n = NetCard.shared
    @ObservedObject var t = AppTraffic.shared
    var body: some View {
        Card(title: "网络卡片", icon: "wifi") {
            row("Wi-Fi 信号", n.wifi.map { $0.connected ? WiFiRead.signalText($0.rssi) : "未连接 Wi-Fi" } ?? "未读取")
            row("链路速率", n.wifi.map { w in w.connected ? (w.txRate.map { String(format: "%.0f Mbps", $0) } ?? "未知") + [w.band, w.channel.map { "信道 \($0)" }].compactMap { $0 }.map { " · " + $0 }.joined() : "—" } ?? "未读取")
            row("公网 IP", n.publicIP ?? (n.running ? "检测中…" : n.ipNote))
            HStack { Text("ChatGPT").font(.system(size: 11)); Spacer(); Text(n.chatGPT.text).font(.system(size: 11, weight: .medium)).foregroundColor(n.chatGPT.isOK ? DS.text.good : (n.chatGPT == .unknown || n.chatGPT == .checking ? DS.text.secondary : DS.text.warn)).lineLimit(1) }.accessibilityIdentifier("netcard.chatgpt")
            HStack {
                Button(n.running ? "检测中…" : "重新检测") { n.refresh() }.buttonStyle(PillButton(filled: false)).disabled(n.running).accessibilityIdentifier("netcard.refresh")
                Spacer()
                if let u = n.updated { Text("更新 " + u.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundColor(DS.text.secondary) }
            }
            Text("打开本页时检测一次（5 分钟内不重复）。" + (t.tunOn ? "VPN 开着时公网 IP 是 VPN 出口。" : "") + "Wi-Fi 名称需要定位权限，这里不读取。").font(.system(size: 10)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
        }.onAppear { n.refreshIfStale() }
    }
    func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(.system(size: 11)); Spacer(); Text(v).font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1) }
    }
}

// MARK: 测速页（第二个标签）
struct SpeedTab24: View {
    @ObservedObject var s = SpeedTest24.shared
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Card(title: "测速", icon: "speedometer") {
                big("下载", value: s.phase == .running ? s.down.last : s.result?.downMbps, series: s.down, color: accent2, id: "speed.down")
                big("上传", value: s.phase == .running ? s.up.last : s.result?.upMbps, series: s.up, color: accent, id: "speed.up")
                HStack {
                    if s.phase == .running {
                        ProgressView().controlSize(.small)
                        Text(String(format: "测速中 %.0f 秒（最长 %d 秒）", s.elapsed, SpeedTest24.maxRuntime)).font(.system(size: 11)).foregroundColor(DS.text.secondary)
                        Spacer()
                        Button("取消") { s.cancel() }.buttonStyle(PillButton(filled: false)).accessibilityIdentifier("speed.cancel")
                    } else {
                        Text(s.finished.map { "上次 " + $0.formatted(date: .omitted, time: .shortened) } ?? "打开本页自动开始").font(.system(size: 11)).foregroundColor(DS.text.secondary)
                        Spacer()
                        Button("重新测速") { s.start() }.buttonStyle(PillButton()).accessibilityIdentifier("speed.run")
                    }
                }
            }.frame(maxWidth: .infinity)
            VStack(spacing: 10) {
                Card(title: "延迟", icon: "timer") {
                    lat("空闲时", s.result?.idleMs)
                    lat("下载时", s.result?.downMs)
                    lat("上传时", s.result?.upMs)
                    HStack { Text("抖动").font(.system(size: 11)); Spacer(); Text(s.result?.jitterMs.map { String(format: "%.1f ms", $0) } ?? "未知").font(.system(size: 13, weight: .semibold)).monospacedDigit() }
                    if let r = s.result, r.jitterMs != nil { Text("抖动按 \(r.jitterSamples) 次空闲延迟相邻差值平均").font(.system(size: 10)).foregroundColor(DS.text.secondary) }
                }
                Card(title: "带宽档位", icon: "gauge.with.dots.needle.67percent") {
                    if let e = s.result?.error { Text(e).font(.system(size: 11)).foregroundColor(DS.text.warn).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("speed.error") }
                    Text(s.result.map { NQParse.tier(down: $0.downMbps, up: $0.upMbps) } ?? "测完后按实测速度给出用途参考，不做排名").font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Text("测速用 macOS 自带的 networkQuality（Apple 测速服务器\(s.result.map { $0.endpoint.isEmpty ? "" : "：" + $0.endpoint } ?? "")）；曲线是测速期间主网卡\(s.result.map { $0.iface.isEmpty ? "" : " " + $0.iface } ?? "")每 0.5 秒的实测速率，包含同时段其他应用的流量；大数字是测速工具的最终结果。").font(.system(size: 10)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity)
        }.onAppear { s.startIfStale() }
    }
    func big(_ title: String, value: Double?, series: [Double], color: Color, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: title == "下载" ? "arrow.down.circle.fill" : "arrow.up.circle.fill").foregroundColor(color)
                Text(title).font(.system(size: 11)).foregroundColor(DS.text.secondary)
                Text(Fmt24.mbps(value)).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit().accessibilityIdentifier(id)
                Text("Mbps").font(.system(size: 11)).foregroundColor(DS.text.secondary)
            }
            Spark(values: series, color: color).frame(height: 54).opacity(series.isEmpty ? 0.25 : 1)
        }
    }
    func lat(_ k: String, _ v: Double?) -> some View {
        HStack { Text(k).font(.system(size: 11)); Spacer(); Text(Fmt24.ms(v)).font(.system(size: 13, weight: .semibold)).monospacedDigit() }
    }
}

// MARK: 卸载应用
struct UninstallTab: View {
    @ObservedObject var u = Uninstaller.shared
    @State private var confirm = false
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Card(title: "卸载应用（连同残留）", icon: "xmark.bin") {
                HStack {
                    Text(u.appName.isEmpty ? "先选一个应用，会列出它的残留文件，确认后才动" : u.appName + (u.bundleID.isEmpty ? "" : " · " + u.bundleID)).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer()
                    Button("选择应用…") { u.choose() }.buttonStyle(PillButton(filled: false)).disabled(u.busy).accessibilityIdentifier("uninstall.choose")
                }
                if !u.note.isEmpty { Text(u.note).font(.system(size: 11)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("uninstall.note") }
                if !u.saveError.isEmpty {
                    StateLine(kind: .failed, text: u.saveError, id: "uninstall.save.error")
                    Button("重试保存") { u.saveLog() }.buttonStyle(PillButton(filled: false)).accessibilityIdentifier("uninstall.save.retry")
                }
                ForEach(u.items.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $u.items[i].selected).toggleStyle(.switch).controlSize(.mini).labelsHidden().disabled(u.busy)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(u.items[i].kind).font(.system(size: 11, weight: .medium))
                            Text(u.items[i].path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 10)).foregroundColor(DS.text.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(CleanLogic.fmtSize(u.items[i].size)).font(.system(size: 11)).monospacedDigit()
                    }
                }
                if !u.items.isEmpty {
                    Button("移到废纸篓（\(u.items.filter(\.selected).count) 项，\(CleanLogic.fmtSize(u.selectedSize))）") { confirm = true }.buttonStyle(PillButton()).disabled(u.busy || u.items.allSatisfy { !$0.selected }).accessibilityIdentifier("uninstall.trash")
                        .alert("卸载 \(u.appName)？", isPresented: $confirm) {
                            Button("移到废纸篓", role: .destructive) { u.trashSelected() }
                            Button("取消", role: .cancel) {}
                        } message: { Text("所选项只会移到废纸篓，不会直接删除；之后可以在右侧记录里一键恢复。") }
                }
                Text("只按 Bundle ID 精确匹配残留；共享的 Group Containers 不列入；系统应用、本应用、白名单里的应用不能卸载；应用在运行时请先自己退出。").font(.system(size: 10)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity)
            Card(title: "卸载记录", icon: "clock.arrow.circlepath") {
                if u.records.isEmpty { StateLine(kind: .empty, text: "暂无卸载记录", id: "uninstall.state") }
                ForEach(u.records.suffix(6).reversed()) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(r.app).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Text(r.date.formatted(date: .abbreviated, time: .shortened) + " · \(r.entries.count) 项").font(.system(size: 10)).foregroundColor(DS.text.secondary)
                        }
                        Spacer()
                        if r.restored { Text("已恢复").font(.system(size: 11)).foregroundColor(DS.text.good) }
                        else { Button("恢复") { u.restore(r) }.buttonStyle(PillButton(filled: false)).accessibilityIdentifier("uninstall.restore") }
                    }
                }
                Text("恢复会把废纸篓里的项放回原位置；原位置已有同名文件时不覆盖。清空废纸篓后无法恢复。").font(.system(size: 10)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity)
        }
    }
}
