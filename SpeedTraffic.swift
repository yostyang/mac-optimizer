// v1.7 网络：测速、按应用流量、网络信息
// 只在用户点击时跑测速和外部请求，不常驻采样。按应用字节数系统没有公开接口，
// 这里不把接口总量冒充成按应用量：按应用一栏显示的是 lsof 的联网连接数，
// 总速率来自系统接口（Monitor 已有的主接口口径），TUN 时只按主接口统计、不重复加总。
import SwiftUI
import AppKit
import Foundation

// MARK: - 纯计算（可单元测试，不依赖网络和硬件）
enum SpeedCalc {
    static func mbps(bytes: Int64, seconds: Double) -> Double {
        guard seconds > 0, bytes > 0 else { return 0 }
        return Double(bytes) * 8 / seconds / 1_000_000
    }
    static func jitter(_ samples: [Double]) -> Double {
        guard samples.count > 1 else { return 0 }
        let avg = samples.reduce(0, +) / Double(samples.count)
        let v = samples.reduce(0) { $0 + ($1 - avg) * ($1 - avg) } / Double(samples.count)
        return v.squareRoot()
    }
    static func avg(_ samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Double(samples.count)
    }
    static func tier(_ downMbps: Double) -> String {
        if downMbps <= 0 { return "未测出速度" }
        if downMbps < 10 { return "基础宽带：日常浏览、标清视频够用" }
        if downMbps < 50 { return "普通宽带：高清视频、多人同时用基本够用" }
        if downMbps < 100 { return "百兆宽带：4K 视频、大文件下载比较顺" }
        if downMbps < 300 { return "高速宽带：多台设备同时 4K 也比较顺" }
        if downMbps < 500 { return "五百兆宽带：大游戏、超大文件下载较快" }
        return "千兆级宽带：带宽已很高，慢多半是对方服务器或 Wi-Fi 链路问题"
    }
}

struct SpeedResult {
    var downMbps = 0.0
    var upMbps = 0.0
    var idleMs: Double?
    var downMs: Double?
    var upMs: Double?
    var jitterMs = 0.0
    var samples: [Double] = []
    var failed = false
    var note = ""
    var tierText: String { SpeedCalc.tier(downMbps) }
}

// MARK: - 测速（用户点击才跑）
final class SpeedTester: ObservableObject {
    static let shared = SpeedTester()
    @Published var result = SpeedResult()
    @Published var running = false
    var downloadURL = URL(string: "https://speed.cloudflare.com/__down?bytes=20000000")!
    var uploadURL = URL(string: "https://speed.cloudflare.com/__up")!
    var smallURL = URL(string: "https://www.apple.com")!
    func run() {
        guard !running else { return }
        running = true
        DispatchQueue.global(qos: .userInitiated).async {
            var lat: [Double] = []
            for _ in 0..<3 {
                let t0 = Date()
                let ok = self.fetch(self.smallURL, timeout: 5, body: nil)
                if ok { lat.append(Date().timeIntervalSince(t0) * 1000) }
            }
            let idle = SpeedCalc.avg(lat)
            let down = self.download()
            let up = self.upload()
            let failed = down.bytes == 0 && up.bytes == 0
            let r = SpeedResult(
                downMbps: SpeedCalc.mbps(bytes: down.bytes, seconds: down.seconds),
                upMbps: SpeedCalc.mbps(bytes: up.bytes, seconds: up.seconds),
                idleMs: idle, downMs: down.ms, upMs: up.ms,
                jitterMs: SpeedCalc.jitter(lat), samples: down.samples,
                failed: failed,
                note: failed ? "测速端点连不上：请检查网络或 VPN 后再试，本次没有谎报速度" : "测速端点为 Cloudflare 公开端点，实际速度受对方服务器和 Wi-Fi 链路影响")
            DispatchQueue.main.async { self.result = r; self.running = false }
        }
    }
    private func fetch(_ url: URL, timeout: TimeInterval, body: Data?) -> Bool {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        if let b = body { req.httpMethod = "POST"; req.httpBody = b }
        var done = false
        var ok = false
        let task = URLSession.shared.dataTask(with: req) { _, resp, err in
            if err == nil, let h = resp as? HTTPURLResponse, h.statusCode < 400 { ok = true }
            done = true
        }
        task.resume()
        let end = Date().addingTimeInterval(timeout + 2)
        while !done, Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        if !done { task.cancel() }
        return ok
    }
    private func download() -> (bytes: Int64, seconds: Double, ms: Double?, samples: [Double]) {
        let t0 = Date()
        var bytes: Int64 = 0
        var done = false
        let task = URLSession.shared.dataTask(with: downloadURL) { data, resp, error in
            if error == nil, let response = resp as? HTTPURLResponse, (200..<300).contains(response.statusCode) {
                bytes = Int64(data?.count ?? 0)
            }
            done = true
        }
        task.resume()
        let end = Date().addingTimeInterval(30)
        while !done, Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        if !done { task.cancel() }
        let sec = Date().timeIntervalSince(t0)
        // 完成后才能取得总字节数，无法据此还原逐秒曲线。
        return (bytes, sec, nil, [])
    }
    private func upload() -> (bytes: Int64, seconds: Double, ms: Double?) {
        let body = Data(repeating: 0, count: 5_000_000)
        var req = URLRequest(url: uploadURL, timeoutInterval: 30)
        req.httpMethod = "POST"; req.httpBody = body
        let t0 = Date()
        var ok = false
        var done = false
        let task = URLSession.shared.dataTask(with: req) { _, resp, err in
            if err == nil, let h = resp as? HTTPURLResponse, h.statusCode < 400 { ok = true }
            done = true
        }
        task.resume()
        let end = Date().addingTimeInterval(32)
        while !done, Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        if !done { task.cancel() }
        let sec = Date().timeIntervalSince(t0)
        return (ok ? Int64(body.count) : 0, sec, nil)
    }
}

// MARK: - 流量历史（分钟桶，JSON 持久化，30 天外删除，上限 43200 条）
struct TrafficBucket: Codable, Equatable {
    var minute: Int64
    var downAvg: Double
    var upAvg: Double
    var count: Int
    var tun: Bool
}
struct TrafficApp: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var connections: Int
}
enum TrafficParse {
    static func bucketKey(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 / 60) }
    static func parseLsof(_ out: String) -> [TrafficApp] {
        var counts: [String: Int] = [:]
        for line in out.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0] != "COMMAND" else { continue }
            let name = String(parts[0])
            counts[name, default: 0] += 1
        }
        return counts.map { TrafficApp(name: $0.key, connections: $0.value) }.sorted { $0.connections > $1.connections }
    }
    static func tunActive() -> Bool {
        var ifs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifs) == 0, let first = ifs else { return false }
        defer { freeifaddrs(first) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            let n = String(cString: a.pointee.ifa_name)
            if n.hasPrefix("utun") || n.hasPrefix("tun") { return true }
            p = a.pointee.ifa_next
        }
        return false
    }
}
final class TrafficStore: ObservableObject {
    static let shared = TrafficStore()
    @Published var buckets: [TrafficBucket] = []
    @Published var apps: [TrafficApp] = []
    @Published var appsNote = ""
    var fileURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacOptimizer/traffic.json")
    var maxBuckets = 43200
    private var timer: Timer?
    init() { load() }
    func load() {
        guard let d = try? Data(contentsOf: fileURL), let v = try? JSONDecoder().decode([TrafficBucket].self, from: d) else { return }
        buckets = v
    }
    func save() {
        if MOTests.active { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(buckets).write(to: fileURL)
    }
    func add(downBps: Double, upBps: Double, tun: Bool, date: Date = Date()) {
        let key = TrafficParse.bucketKey(date)
        if let i = buckets.firstIndex(where: { $0.minute == key }) {
            let b = buckets[i]
            let n = Double(b.count + 1)
            buckets[i] = TrafficBucket(minute: key, downAvg: (b.downAvg * Double(b.count) + downBps) / n, upAvg: (b.upAvg * Double(b.count) + upBps) / n, count: b.count + 1, tun: b.tun || tun)
        } else {
            buckets.append(TrafficBucket(minute: key, downAvg: downBps, upAvg: upBps, count: 1, tun: tun))
        }
        prune(now: date)
        save()
    }
    func prune(now: Date = Date()) {
        let cutoff = Int64(now.timeIntervalSince1970 / 60) - 30 * 24 * 60
        buckets = buckets.filter { $0.minute >= cutoff }
        if buckets.count > maxBuckets { buckets = Array(buckets.suffix(maxBuckets)) }
        buckets.sort { $0.minute < $1.minute }
    }
    func inRange(_ days: Double, now: Date = Date()) -> [TrafficBucket] {
        let cutoff = Int64(now.timeIntervalSince1970 / 60) - Int64(days * 24 * 60)
        return buckets.filter { $0.minute >= cutoff }
    }
    func summary(_ days: Double, now: Date = Date()) -> (avgDown: Double, avgUp: Double, maxDown: Double) {
        let rs = inRange(days, now: now)
        guard !rs.isEmpty else { return (0, 0, 0) }
        return (rs.map(\.downAvg).reduce(0, +) / Double(rs.count), rs.map(\.upAvg).reduce(0, +) / Double(rs.count), rs.map(\.downAvg).max() ?? 0)
    }
    func startMinuteTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            let s = Monitor.shared.s
            TrafficStore.shared.add(downBps: s.downBps, upBps: s.upBps, tun: TrafficParse.tunActive())
        }
    }
    func stopMinuteTimer() { timer?.invalidate(); timer = nil }
    func refreshApps() {
        DispatchQueue.global().async {
            let out = ProcessRunner.run("/usr/sbin/lsof", ["-i", "-P", "-n"]).out
            let apps = TrafficParse.parseLsof(out)
            DispatchQueue.main.async {
                self.apps = apps
                self.appsNote = "口径说明：按应用一栏是联网连接数，不是按应用字节数（系统没有公开按应用字节接口）；总速率来自系统主接口，TUN 时只按主接口统计、不重复加总。"
            }
        }
    }
}

// MARK: - 网络信息（Wi-Fi、公网 IP、ChatGPT）
enum NetInfoParse {
    static func airport(_ out: String) -> (ssid: String, rssi: String, channel: String, tx: String) {
        var ssid = "", rssi = "", channel = "", tx = ""
        for line in out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("SSID:") { ssid = t.dropFirst(5).trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("agrCtlRSSI:") { rssi = t.dropFirst(11).trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("channel:") { channel = t.dropFirst(8).trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("lastTxRate:") { tx = t.dropFirst(11).trimmingCharacters(in: .whitespaces) }
        }
        return (ssid, rssi, channel, tx)
    }
}
final class NetInfo: ObservableObject {
    static let shared = NetInfo()
    @Published var wifi = "未读取"
    @Published var publicIP = "未读取"
    @Published var chatGPT = "未检测"
    @Published var running = false
    func refresh() {
        guard !running else { return }
        running = true
        DispatchQueue.global().async {
            let a = NetInfoParse.airport(ProcessRunner.run("/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport", ["-I"]).out)
            let wifi = a.ssid.isEmpty ? "未连接 Wi-Fi 或读不到" : "\(a.ssid) · 信号 \(a.rssi) dBm · 信道 \(a.channel) · 速率 \(a.tx) Mbps"
            var ip = "不可读"
            var chat = "连不上"
            let g = DispatchGroup()
            g.enter()
            URLSession.shared.dataTask(with: URL(string: "https://api.ipify.org")!) { d, _, _ in
                if let d, let s = String(data: d, encoding: .utf8), !s.isEmpty { ip = s }
                g.leave()
            }.resume()
            g.enter()
            var req = URLRequest(url: URL(string: "https://chatgpt.com")!, timeoutInterval: 8)
            req.httpMethod = "HEAD"
            URLSession.shared.dataTask(with: req) { _, resp, err in
                if err == nil, let h = resp as? HTTPURLResponse, h.statusCode < 400 { chat = "能连上" }
                g.leave()
            }.resume()
            _ = g.wait(timeout: .now() + 10)
            DispatchQueue.main.async { self.wifi = wifi; self.publicIP = ip; self.chatGPT = chat; self.running = false }
        }
    }
}

// MARK: - 界面卡片
struct SpeedCard: View {
    @ObservedObject var t = SpeedTester.shared
    var body: some View {
        Card(title: "测速", icon: "speedometer") {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("下载").font(.system(size: 11)).foregroundColor(.secondary)
                    Text(String(format: "%.1f", t.result.downMbps)).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("Mbps").font(.system(size: 11)).foregroundColor(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("上传").font(.system(size: 11)).foregroundColor(.secondary)
                    Text(String(format: "%.1f", t.result.upMbps)).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("Mbps").font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                Button(t.running ? "测速中…" : "开始测速") { t.run() }.buttonStyle(PillButton()).disabled(t.running).accessibilityIdentifier("speed.run")
            }
            Text("显示整次传输的平均速度，暂不提供逐秒曲线").font(.system(size: 10)).foregroundColor(.secondary)
            HStack(spacing: 12) {
                Text("空闲延迟：" + (t.result.idleMs.map { String(format: "%.0f ms", $0) } ?? "—")).font(.system(size: 11)).foregroundColor(.secondary)
                Text("抖动：" + String(format: "%.1f ms", t.result.jitterMs)).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Text(t.result.failed ? t.result.note : t.result.tierText).font(.system(size: 11)).foregroundColor(t.result.failed ? .red : .secondary).fixedSize(horizontal: false, vertical: true)
            Text("只在你点开始测速时跑，不常驻测速").font(.system(size: 10)).foregroundColor(.secondary)
        }
    }
}
struct TrafficCard: View {
    @ObservedObject var store = TrafficStore.shared
    @ObservedObject var mon = Monitor.shared
    @State private var rangeDays = 1.0
    var body: some View {
        Card(title: "联网应用与速率历史", icon: "arrow.up.arrow.down") {
            HStack(spacing: 10) {
                Text("当前：" + Fmt.rate(mon.s.downBps) + " ↓ · " + Fmt.rate(mon.s.upBps) + " ↑").font(.system(size: 11, weight: .medium)).monospacedDigit()
                Spacer()
                Button("刷新联网应用") { store.refreshApps() }.buttonStyle(PillButton(filled: false)).accessibilityIdentifier("traffic.apps.run")
            }
            Picker("范围", selection: $rangeDays) {
                Text("1 分钟").tag(1.0 / 1440)
                Text("1 小时").tag(1.0 / 24)
                Text("24 小时").tag(1.0)
                Text("30 天").tag(30.0)
            }.pickerStyle(.segmented)
            let sm = store.summary(rangeDays)
            Text("这段平均下载 " + Fmt.rate(sm.avgDown) + " · 上传 " + Fmt.rate(sm.avgUp) + " · 下载峰值 " + Fmt.rate(sm.maxDown)).font(.system(size: 11)).foregroundColor(.secondary)
            if store.buckets.contains(where: { $0.tun }) {
                Text("检测到 TUN 接口：总速率只按主接口统计，不重复加总 TUN 与物理接口").font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if store.apps.isEmpty {
                Text("点“刷新联网应用”查看当前连接数；此列表不表示应用流量大小。").font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                ForEach(store.apps.prefix(10)) { a in
                    HStack { Text(a.name).font(.system(size: 11)).lineLimit(1); Spacer(); Text("\(a.connections) 个连接").font(.system(size: 11)).foregroundColor(.secondary) }
                }
            }
            if !store.appsNote.isEmpty { Text(store.appsNote).font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
            Text("打开网络诊断页时每分钟记一笔流量，重启后记录仍在，30 天外自动删除").font(.system(size: 10)).foregroundColor(.secondary)
        }
        .onAppear { store.startMinuteTimer(); let s = mon.s; store.add(downBps: s.downBps, upBps: s.upBps, tun: TrafficParse.tunActive()) }
        .onDisappear { store.stopMinuteTimer() }
    }
}
struct NetInfoCard: View {
    @ObservedObject var info = NetInfo.shared
    var body: some View {
        Card(title: "网络信息", icon: "wifi") {
            HStack { Text("Wi-Fi").font(.system(size: 11)); Spacer(); Text(info.wifi).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1) }
            HStack { Text("公网 IP").font(.system(size: 11)); Spacer(); Text(info.publicIP).font(.system(size: 11, weight: .medium)).monospacedDigit() }
            HStack { Text("ChatGPT").font(.system(size: 11)); Spacer(); Text(info.chatGPT).font(.system(size: 11, weight: .medium)).foregroundColor(info.chatGPT == "能连上" ? good : .secondary) }
            Button(info.running ? "检测中…" : "刷新网络信息") { info.refresh() }.buttonStyle(PillButton(filled: false)).disabled(info.running).accessibilityIdentifier("netinfo.refresh")
            Text("公网 IP 与 ChatGPT 只在你点刷新时检测一次，读不到会写不可读，不会谎报").font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
