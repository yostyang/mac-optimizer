// 2.4 网络：按应用真实字节、后台流量历史、测速（系统 networkQuality）、网络卡片、TUN 去重；应用卸载（含残留）
// 按应用字节来自系统自带 nettop（只读、无需管理员），总量来自物理网卡 64 位计数器。
// 卸载参考 Mole（GPL-3.0）的思路与路径类别，代码为本项目自写。
import SwiftUI
import AppKit
import Foundation
import CoreWLAN
import SystemConfiguration

// MARK: - 接口计数器（64 位，sysctl NET_RT_IFLIST2）
enum IfCounters {
    static func read() -> [String: (UInt64, UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [:] }
        var out: [String: (UInt64, UInt64)] = [:]
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                let ml = Int(hdr.ifm_msglen)
                if ml <= 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    var nb = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(h2.ifm_index), &nb) != nil {
                        out[String(cString: nb)] = (h2.ifm_data.ifi_ibytes, h2.ifm_data.ifi_obytes)
                    }
                }
                off += ml
            }
        }
        return out
    }
    /// 物理网卡：en*（Wi-Fi/有线/雷雳），不含 utun（VPN 隧道）、桥接、AWDL、回环
    static func isPhysical(_ n: String) -> Bool { n.hasPrefix("en") }
    static func physicalTotal(_ m: [String: (UInt64, UInt64)]) -> (UInt64, UInt64) {
        m.filter { isPhysical($0.key) }.values.reduce((0, 0)) { ($0.0 &+ $1.0, $0.1 &+ $1.1) }
    }
    /// 计数器变小（重启、网卡重建）时这一段记为未知，不补数
    static func delta(_ now: UInt64, _ prev: UInt64) -> UInt64? { now >= prev ? now - prev : nil }
}

// MARK: - TUN 检测：utun 上有非链路本地 IPv4，或默认路由走 utun
enum TunDetect {
    static func active(addrs: [(name: String, ipv4: String)], primary: String) -> Bool {
        if primary.hasPrefix("utun") { return true }
        return addrs.contains { $0.name.hasPrefix("utun") && !$0.ipv4.isEmpty && !$0.ipv4.hasPrefix("169.254.") }
    }
    static func systemAddrs() -> [(name: String, ipv4: String)] {
        var out: [(String, String)] = []
        var ifs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifs) == 0, let first = ifs else { return [] }
        defer { freeifaddrs(first) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            if let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                out.append((String(cString: a.pointee.ifa_name), String(cString: host)))
            }
            p = a.pointee.ifa_next
        }
        return out
    }
    static func primaryInterface() -> String {
        let g = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        return g?["PrimaryInterface"] as? String ?? ""
    }
    static func system() -> Bool { active(addrs: systemAddrs(), primary: primaryInterface()) }
}

// MARK: - nettop 解析与按应用去重
struct ProcBytes: Equatable { var name: String; var pid: Int32; var inB: UInt64; var outB: UInt64 }
enum NetTop {
    /// 解析 `nettop -P -L 1 -n -x -J bytes_in,bytes_out` 输出：「进程名.pid,入,出,」
    static func parse(_ csv: String) -> [Int32: ProcBytes] {
        var out: [Int32: ProcBytes] = [:]
        for line in csv.split(separator: "\n") {
            var f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            while f.last == "" { f.removeLast() }
            guard f.count >= 3, let o = UInt64(f[f.count - 1]), let i = UInt64(f[f.count - 2]) else { continue }
            let ident = f[0..<(f.count - 2)].joined(separator: ",")
            guard let dot = ident.lastIndex(of: "."), let pid = Int32(ident[ident.index(after: dot)...]) else { continue }
            out[pid] = ProcBytes(name: String(ident[..<dot]), pid: pid, inB: i, outB: o)
        }
        return out
    }
    static func run(_ type: String) -> String { sh("/usr/bin/nettop -P -L 1 -n -x -t \(type) -J bytes_in,bytes_out 2>/dev/null") }
    static let vpnNames = ["letsvpn", "鹊桥", "clash", "mihomo", "sing-box", "surge", "stash", "v2ray", "xray", "shadowrocket", "quantumult", "loon", "hiddify", "nekoray", "tailscale", "wireguard", "openvpn"]
    static func looksLikeVPN(_ n: String) -> Bool { let l = n.lowercased(); return vpnNames.contains { l.contains($0) } }
}
struct ProcDelta: Equatable { var key: String; var name: String; var physIn: UInt64 = 0; var physOut: UInt64 = 0; var tunIn: UInt64 = 0; var tunOut: UInt64 = 0
    var inB: UInt64 { physIn + tunIn }; var outB: UInt64 { physOut + tunOut } }
struct AppBytes: Identifiable, Equatable, Codable { var id: String { name }; var name: String; var inB: UInt64; var outB: UInt64; var total: UInt64 { inB + outB } }
enum TrafficDedup {
    /// TUN 开着时，应用的流量先进 utun，VPN 进程再把同样的数据（加密后）从物理网卡发出去。
    /// 把这个转发进程找出来单列，不计入应用合计，避免同一份流量算两遍。
    static func forwarder(_ ds: [ProcDelta], tun: Bool) -> String? {
        guard tun else { return nil }
        // 已知 VPN 客户端：开 TUN 时它在物理网卡上的流量基本都是替应用转发的
        if let k = ds.filter({ NetTop.looksLikeVPN($0.name) && ($0.physIn + $0.physOut) > 0 && ($0.tunIn + $0.tunOut) * 10 <= ($0.physIn + $0.physOut) })
            .max(by: { ($0.physIn + $0.physOut) < ($1.physIn + $1.physOut) }) { return k.key }
        let tunTotal = ds.reduce(UInt64(0)) { $0 + $1.tunIn + $1.tunOut }
        guard tunTotal > 0 else { return nil }
        let cands = ds.filter { d in
            let phys = d.physIn + d.physOut, t = d.tunIn + d.tunOut
            return phys >= tunTotal / 2 && t * 10 <= phys
        }.sorted { ($0.physIn + $0.physOut) > ($1.physIn + $1.physOut) }
        return cands.first?.key
    }
    static func apps(_ ds: [ProcDelta], tun: Bool) -> (apps: [AppBytes], forwarder: AppBytes?) {
        let f = forwarder(ds, tun: tun)
        var m: [String: AppBytes] = [:]
        var fw: AppBytes?
        for d in ds where d.inB + d.outB > 0 {
            if d.key == f { fw = AppBytes(name: d.name, inB: d.inB, outB: d.outB); continue }
            var a = m[d.name] ?? AppBytes(name: d.name, inB: 0, outB: 0); a.inB += d.inB; a.outB += d.outB; m[d.name] = a
        }
        return (m.values.sorted { $0.total > $1.total }, fw)
    }
}

/// 进程归属：Helper 进程算到所在 App 名下
enum ProcName {
    private static var cache: [Int32: String] = [:]
    static func appName(pid: Int32, fallback: String) -> String {
        if let c = cache[pid] { return c }
        let p = PidPath.path(pid)
        var n = fallback.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if !p.isEmpty { let o = ProcDescribe.owner(path: p); if o.bundlePath != nil { n = o.name } }
        if let a = NSRunningApplication(processIdentifier: pid), a.activationPolicy == .regular, let ln = a.localizedName { n = ProcDescribe.short(ln) }
        if cache.count > 500 { cache = [:] }
        cache[pid] = n; return n
    }
    static func startTime(_ pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard n == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
    }
}

// MARK: - 采样器：一次采样得到按进程增量
struct RawSample { var phys: [Int32: ProcBytes]; var tun: [Int32: ProcBytes]; var ifPhys: (UInt64, UInt64)?; var tunOn: Bool; var at: Date }
struct SampleDelta { var procs: [ProcDelta]; var totalIn: UInt64?; var totalOut: UInt64?; var seconds: Double; var tunOn: Bool; var at: Date }
enum TrafficDiff {
    /// 同一 pid 两次读数相减；新出现的进程如果是上次采样后才启动的，它的全部计数都属于这段时间；
    /// 其余新进程（不知道起点）跳过，不猜。计数变小（pid 复用）也跳过。
    static func diff(prev: RawSample, cur: RawSample, startTime: (Int32) -> Date? = ProcName.startTime, name: (Int32, String) -> String = { ProcName.appName(pid: $0, fallback: $1) }) -> SampleDelta {
        var ds: [Int32: ProcDelta] = [:]
        func add(_ m: [Int32: ProcBytes], _ pm: [Int32: ProcBytes], tun: Bool) {
            for (pid, c) in m {
                var di: UInt64 = 0, dout: UInt64 = 0
                if let p = pm[pid], p.name == c.name {
                    guard c.inB >= p.inB, c.outB >= p.outB else { continue }
                    di = c.inB - p.inB; dout = c.outB - p.outB
                } else if let st = startTime(pid), st >= prev.at {
                    di = c.inB; dout = c.outB
                } else { continue }
                if di == 0 && dout == 0 { continue }
                var d = ds[pid] ?? ProcDelta(key: "\(c.name).\(pid)", name: name(pid, c.name))
                if tun { d.tunIn += di; d.tunOut += dout } else { d.physIn += di; d.physOut += dout }
                ds[pid] = d
            }
        }
        add(cur.phys, prev.phys, tun: false); add(cur.tun, prev.tun, tun: true)
        var ti: UInt64?, to: UInt64?
        if let a = cur.ifPhys, let b = prev.ifPhys { ti = IfCounters.delta(a.0, b.0); to = IfCounters.delta(a.1, b.1) }
        return SampleDelta(procs: Array(ds.values), totalIn: ti, totalOut: to, seconds: max(0.001, cur.at.timeIntervalSince(prev.at)), tunOn: cur.tunOn || prev.tunOn, at: cur.at)
    }
}

// MARK: - 流量历史（分钟总量 24 小时、分钟按应用 60 分钟、小时按应用 30 天）
struct TMinute: Codable, Equatable { var t: Int64; var i: UInt64; var o: UInt64; var tun: Bool = false }
struct THour: Codable, Equatable { var t: Int64; var i: UInt64; var o: UInt64; var apps: [String: [UInt64]] }
struct TMinuteApps: Codable, Equatable { var t: Int64; var apps: [String: [UInt64]] }
struct TrafficRecent: Codable { var minutes: [TMinute] = []; var minuteApps: [TMinuteApps] = []; var currentHour: THour? }
enum TrafficRange: Int, CaseIterable, Identifiable {
    case minute1 = 1, hour1 = 60, day1 = 1440, day7 = 10080, day30 = 43200
    var id: Int { rawValue }
    var title: String { switch self { case .minute1: return "1 分钟"; case .hour1: return "1 小时"; case .day1: return "24 小时"; case .day7: return "7 天"; case .day30: return "30 天" } }
}
final class TrafficHistory: ObservableObject {
    static var shared = TrafficHistory()
    @Published private(set) var minutes: [TMinute] = []
    @Published private(set) var minuteApps: [TMinuteApps] = []
    @Published private(set) var hours: [THour] = []
    var dir: URL
    var lastSave = Date.distantPast
    var dirty = false
    static let maxAppsPerMinute = 12, maxAppsPerHour = 30
    init(dir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacOptimizer")) {
        self.dir = dir; load()
    }
    var recentURL: URL { dir.appendingPathComponent("traffic-recent.json") }
    var hoursURL: URL { dir.appendingPathComponent("traffic-hours.json") }
    func load() {
        if let d = try? Data(contentsOf: recentURL), let r = try? JSONDecoder().decode(TrafficRecent.self, from: d) {
            minutes = r.minutes; minuteApps = r.minuteApps
            if let h = r.currentHour { hours.append(h) }
        }
        if let d = try? Data(contentsOf: hoursURL), let h = try? JSONDecoder().decode([THour].self, from: d) {
            let cur = hours; hours = h.filter { x in !cur.contains { $0.t == x.t } } + cur
            hours.sort { $0.t < $1.t }
        }
    }
    func save(force: Bool = true) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cur = hours.last
        let r = TrafficRecent(minutes: minutes, minuteApps: minuteApps, currentHour: cur)
        try? JSONEncoder().encode(r).write(to: recentURL, options: .atomic)
        try? JSONEncoder().encode(Array(hours.dropLast())).write(to: hoursURL, options: .atomic)
        lastSave = Date(); dirty = false
    }
    static func trim(_ apps: [String: [UInt64]], max n: Int) -> [String: [UInt64]] {
        guard apps.count > n else { return apps }
        let sorted = apps.sorted { ($0.value[0] + $0.value[1]) > ($1.value[0] + $1.value[1]) }
        var out = Dictionary(uniqueKeysWithValues: sorted.prefix(n).map { ($0.key, $0.value) })
        var other = out["其他"] ?? [0, 0]
        for (k, v) in sorted.dropFirst(n) where k != "其他" { other[0] += v[0]; other[1] += v[1] }
        out["其他"] = other; return out
    }
    /// 记一笔：总量用物理网卡计数（TUN 时不会把隧道和物理网卡重复相加），按应用用去重后的进程增量
    func add(totalIn: UInt64?, totalOut: UInt64?, apps: [AppBytes], tun: Bool, at: Date) {
        let m = Int64(at.timeIntervalSince1970 / 60), h = m / 60
        if let ti = totalIn, let to = totalOut {
            if let k = minutes.lastIndex(where: { $0.t == m }) { minutes[k].i += ti; minutes[k].o += to; minutes[k].tun = minutes[k].tun || tun }
            else { minutes.append(TMinute(t: m, i: ti, o: to, tun: tun)); minutes.sort { $0.t < $1.t } }
        }
        var ma = minuteApps.last(where: { $0.t == m }) ?? TMinuteApps(t: m, apps: [:])
        var hr = hours.last(where: { $0.t == h }) ?? THour(t: h, i: 0, o: 0, apps: [:])
        hr.i += totalIn ?? 0; hr.o += totalOut ?? 0
        for a in apps where a.total > 0 {
            var v = ma.apps[a.name] ?? [0, 0]; v[0] += a.inB; v[1] += a.outB; ma.apps[a.name] = v
            var w = hr.apps[a.name] ?? [0, 0]; w[0] += a.inB; w[1] += a.outB; hr.apps[a.name] = w
        }
        ma.apps = Self.trim(ma.apps, max: Self.maxAppsPerMinute); hr.apps = Self.trim(hr.apps, max: Self.maxAppsPerHour)
        if let k = minuteApps.lastIndex(where: { $0.t == m }) { minuteApps[k] = ma } else { minuteApps.append(ma); minuteApps.sort { $0.t < $1.t } }
        let rolled = hours.last.map { $0.t != h } ?? false
        if let k = hours.lastIndex(where: { $0.t == h }) { hours[k] = hr } else { hours.append(hr); hours.sort { $0.t < $1.t } }
        prune(now: at); dirty = true
        if !MOTests.active && (rolled || at.timeIntervalSince(lastSave) >= 600) { save() }
    }
    func prune(now: Date) {
        let m = Int64(now.timeIntervalSince1970 / 60)
        minutes.removeAll { $0.t <= m - 1440 }
        minuteApps.removeAll { $0.t <= m - 60 }
        hours.removeAll { $0.t <= m / 60 - 720 }
    }
    /// 图表：每个点是该时段平均速率（字节/秒）；没有记录的时段为 nil（画成空档，不补线）
    func series(_ r: TrafficRange, now: Date = Date()) -> [(down: Double?, up: Double?)] {
        let m = Int64(now.timeIntervalSince1970 / 60)
        switch r {
        case .minute1, .hour1:
            let idx = Dictionary(minutes.map { ($0.t, $0) }, uniquingKeysWith: { a, _ in a })
            let n = r == .minute1 ? 1 : 60
            return ((m - Int64(n) + 1)...m).map { t in idx[t].map { (Double($0.i) / 60, Double($0.o) / 60) } ?? (nil, nil) }
        case .day1:
            let idx = Dictionary(minutes.map { ($0.t, $0) }, uniquingKeysWith: { a, _ in a })
            return stride(from: m - 1439, through: m, by: 10).map { start in
                let xs = (start..<(start + 10)).compactMap { idx[$0] }
                return xs.isEmpty ? (nil, nil) : (Double(xs.reduce(0) { $0 + $1.i }) / Double(xs.count * 60), Double(xs.reduce(0) { $0 + $1.o }) / Double(xs.count * 60))
            }
        case .day7, .day30:
            let h = m / 60, n = Int64(r.rawValue / 60)
            let idx = Dictionary(hours.map { ($0.t, $0) }, uniquingKeysWith: { a, _ in a })
            return ((h - n + 1)...h).map { t in idx[t].map { (Double($0.i) / 3600, Double($0.o) / 3600) } ?? (nil, nil) }
        }
    }
    func totals(_ r: TrafficRange, now: Date = Date()) -> (inB: UInt64, outB: UInt64, coveredMinutes: Int) {
        let m = Int64(now.timeIntervalSince1970 / 60)
        if r.rawValue <= 1440 {
            let xs = minutes.filter { $0.t > m - Int64(r.rawValue) }
            return (xs.reduce(0) { $0 + $1.i }, xs.reduce(0) { $0 + $1.o }, xs.count)
        }
        let xs = hours.filter { $0.t > m / 60 - Int64(r.rawValue / 60) }
        return (xs.reduce(0) { $0 + $1.i }, xs.reduce(0) { $0 + $1.o }, xs.count * 60)
    }
    func apps(_ r: TrafficRange, now: Date = Date()) -> [AppBytes] {
        let m = Int64(now.timeIntervalSince1970 / 60)
        var acc: [String: [UInt64]] = [:]
        let src: [[String: [UInt64]]] = r.rawValue <= 60
            ? minuteApps.filter { $0.t > m - Int64(r.rawValue) }.map(\.apps)
            : hours.filter { $0.t > m / 60 - Int64(max(1, r.rawValue / 60)) }.map(\.apps)
        for d in src { for (k, v) in d { var a = acc[k] ?? [0, 0]; a[0] += v[0]; a[1] += v[1]; acc[k] = a } }
        return acc.map { AppBytes(name: $0.key, inB: $0.value[0], outB: $0.value[1]) }.sorted { $0.total > $1.total }
    }
    func recentTrend(_ n: Int = 30, now: Date = Date()) -> [Double] {
        series(.hour1, now: now).suffix(n).map { $0.down ?? 0 }
    }
    var hasData: Bool { !minutes.isEmpty || !hours.isEmpty }
    func inject(minutes: [TMinute], minuteApps: [TMinuteApps], hours: [THour]) { self.minutes = minutes; self.minuteApps = minuteApps; self.hours = hours }
}

// MARK: - 后台采样器（默认每 60 秒一次；按应用面板打开时每 2 秒一次）
final class AppTraffic: ObservableObject {
    static var shared = AppTraffic()
    @Published private(set) var live: [AppBytes] = []          // 每秒字节（速率）
    @Published private(set) var liveForwarder: AppBytes?
    @Published private(set) var liveTotal: (Double, Double)?   // 物理网卡每秒字节
    @Published private(set) var tunOn = false
    @Published private(set) var updated: Date?
    @Published private(set) var liveSeries: [(Double, Double)] = []
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "traffic.background"); reschedule() } }
    var history: TrafficHistory { TrafficHistory.shared }
    var reader: () -> RawSample = AppTraffic.systemRead
    private var prev: RawSample?
    private var liveViewers = 0
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval = 0
    private let q = DispatchQueue(label: "mo.traffic", qos: .utility)
    static let backgroundInterval: TimeInterval = 60, liveInterval: TimeInterval = 2
    private(set) var sampleCount = 0
    init() { enabled = UserDefaults.standard.object(forKey: "traffic.background") as? Bool ?? true }
    static func systemRead() -> RawSample {
        let tun = TunDetect.system()
        let phys = NetTop.parse(NetTop.run("external"))
        let t = tun ? NetTop.parse(NetTop.run("undefined")) : [:]
        let c = IfCounters.read()
        return RawSample(phys: phys, tun: t, ifPhys: c.isEmpty ? nil : IfCounters.physicalTotal(c), tunOn: tun, at: Date())
    }
    func start() { reschedule() }
    func addLiveViewer() { liveViewers += 1; reschedule(); if !MOTests.active { q.async { self.tick() } } }
    func removeLiveViewer() { liveViewers = max(0, liveViewers - 1); reschedule() }
    func reschedule() {
        if MOTests.active { timer?.cancel(); timer = nil; interval = 0; return }   // 测试里不跑真实采样，界面用注入数据
        let want: TimeInterval = liveViewers > 0 ? Self.liveInterval : (enabled ? Self.backgroundInterval : 0)
        if want == interval && (timer != nil || want == 0) { return }
        timer?.cancel(); timer = nil; interval = want
        guard want > 0 else { prev = nil; return }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + (prev == nil ? 0 : want), repeating: want, leeway: .milliseconds(Int(want * 100)))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t; t.resume()
    }
    /// 采样一次（在后台队列）；第一次只建立基线
    func tick() {
        let cur = reader()
        guard let p = prev else { prev = cur; return }
        prev = cur
        let d = TrafficDiff.diff(prev: p, cur: cur)
        apply(d)
    }
    func apply(_ d: SampleDelta) {
        let r = TrafficDedup.apps(d.procs, tun: d.tunOn)
        DispatchQueue.main.async {
            self.sampleCount += 1
            self.history.add(totalIn: d.totalIn, totalOut: d.totalOut, apps: r.apps, tun: d.tunOn, at: d.at)
            let s = d.seconds
            func rate(_ a: AppBytes) -> AppBytes { AppBytes(name: a.name, inB: UInt64(Double(a.inB) / s), outB: UInt64(Double(a.outB) / s)) }
            self.live = r.apps.map(rate).filter { $0.total >= 512 }; self.liveForwarder = r.forwarder.map(rate)
            if let ti = d.totalIn, let to = d.totalOut {
                self.liveTotal = (Double(ti) / s, Double(to) / s)
                if s < 10 { self.liveSeries.append((Double(ti) / s, Double(to) / s)); if self.liveSeries.count > 30 { self.liveSeries.removeFirst(self.liveSeries.count - 30) } }
            } else { self.liveTotal = nil }
            self.tunOn = d.tunOn; self.updated = d.at
        }
    }
    func flush() { if history.dirty && !MOTests.active { history.save() } }
    /// 测试注入
    func injectLive(_ apps: [AppBytes], forwarder: AppBytes?, total: (Double, Double)?, tun: Bool, series: [(Double, Double)]) {
        live = apps; liveForwarder = forwarder; liveTotal = total; tunOn = tun; liveSeries = series; updated = Date()
    }
}

// MARK: - 网络卡片数据：Wi-Fi（CoreWLAN）、公网 IP、ChatGPT
struct WiFiState: Equatable { var connected: Bool; var ssid: String?; var rssi: Int?; var noise: Int?; var txRate: Double?; var channel: Int?; var band: String?; var iface: String? }
enum WiFiRead {
    static func system() -> WiFiState {
        guard let i = CWWiFiClient.shared().interface() else { return WiFiState(connected: false) }
        let rssi = i.rssiValue(), tx = i.transmitRate()
        guard i.powerOn(), rssi != 0 else { return WiFiState(connected: false, iface: i.interfaceName) }
        var band: String?
        if let ch = i.wlanChannel() {
            switch ch.channelBand { case .band2GHz: band = "2.4 GHz"; case .band5GHz: band = "5 GHz"; case .band6GHz: band = "6 GHz"; default: band = nil }
        }
        return WiFiState(connected: true, ssid: i.ssid(), rssi: rssi, noise: i.noiseMeasurement() == 0 ? nil : i.noiseMeasurement(), txRate: tx > 0 ? tx : nil, channel: i.wlanChannel()?.channelNumber, band: band, iface: i.interfaceName)
    }
    /// 信号等级只按 RSSI 的通用分段描述，不做排名
    static func signalText(_ rssi: Int?) -> String {
        guard let r = rssi else { return "未知" }
        let q = r >= -55 ? "很好" : (r >= -67 ? "良好" : (r >= -75 ? "一般" : "较弱"))
        return "\(r) dBm（\(q)）"
    }
}
enum Reach: Equatable { case unknown, checking, ok(code: Int, ms: Int), fail(String)
    var text: String {
        switch self {
        case .unknown: return "未检测"; case .checking: return "检测中…"
        case .ok(let c, let ms): return "能连上 · HTTP \(c) · \(ms) ms"
        case .fail(let e): return "连不上 · " + e
        }
    }
    var isOK: Bool { if case .ok = self { return true }; return false }
}
enum ReachClassify {
    /// 服务器回了任何 HTTP 状态（含 403 人机验证）都说明网络能到达；只有超时/连接错误才算连不上
    static func classify(status: Int?, error: Error?, ms: Int) -> Reach {
        if let s = status, s > 0 { return .ok(code: s, ms: ms) }
        if let e = error as? URLError {
            switch e.code {
            case .timedOut: return .fail("超时")
            case .cannotFindHost, .dnsLookupFailed: return .fail("域名解析失败")
            case .cannotConnectToHost: return .fail("无法建立连接")
            case .secureConnectionFailed, .serverCertificateUntrusted: return .fail("TLS 握手失败")
            case .notConnectedToInternet: return .fail("没有网络")
            case .networkConnectionLost: return .fail("连接中断")
            default: return .fail("错误 \(e.code.rawValue)")
            }
        }
        return .fail(error.map { ($0 as NSError).localizedDescription } ?? "无响应")
    }
    static func validIP(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var a4 = in_addr(), a6 = in6_addr()
        return inet_pton(AF_INET, t, &a4) == 1 || inet_pton(AF_INET6, t, &a6) == 1
    }
}
final class NetCard: ObservableObject {
    static var shared = NetCard()
    @Published var wifi: WiFiState?
    @Published var publicIP: String?
    @Published var ipNote = "未检测"
    @Published var chatGPT: Reach = .unknown
    @Published var updated: Date?
    @Published var running = false
    var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 8; c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: c)
    }()
    func refreshIfStale() { if MOTests.active { return }; if updated == nil || Date().timeIntervalSince(updated!) > 300 { refresh() } }
    func refresh() {
        guard !running, !MOTests.active else { return }
        running = true; chatGPT = .checking
        DispatchQueue.global(qos: .utility).async {
            let w = WiFiRead.system()
            DispatchQueue.main.async { self.wifi = w }
        }
        let g = DispatchGroup()
        var ip: String?, note = "读不到"
        g.enter()
        fetchIP(["https://api.ipify.org", "https://4.ipw.cn"]) { v, src in ip = v; note = v == nil ? "读不到（两个查询服务都没有返回）" : "来源 \(src)"; g.leave() }
        var reach: Reach = .unknown
        g.enter()
        var req = URLRequest(url: URL(string: "https://chatgpt.com/")!, timeoutInterval: 8); req.httpMethod = "HEAD"
        let t0 = Date()
        session.dataTask(with: req) { _, resp, err in
            reach = ReachClassify.classify(status: (resp as? HTTPURLResponse)?.statusCode, error: err, ms: Int(Date().timeIntervalSince(t0) * 1000)); g.leave()
        }.resume()
        g.notify(queue: .main) {
            self.publicIP = ip; self.ipNote = note; self.chatGPT = reach; self.updated = Date(); self.running = false
        }
    }
    private func fetchIP(_ urls: [String], done: @escaping (String?, String) -> Void) {
        guard let u = urls.first, let url = URL(string: u) else { done(nil, ""); return }
        session.dataTask(with: url) { d, _, _ in
            if let d, let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), ReachClassify.validIP(s) { done(s, url.host ?? u) }
            else { self.fetchIP(Array(urls.dropFirst()), done: done) }
        }.resume()
    }
}

// MARK: - 测速：调用系统自带 networkQuality（Apple 测速服务器），曲线来自同时段网卡计数器的真实采样
struct NQResult: Equatable {
    var downMbps: Double?; var upMbps: Double?
    var idleMs: Double?; var downMs: Double?; var upMs: Double?
    var jitterMs: Double?; var jitterSamples = 0
    var endpoint = ""; var iface = ""; var error: String?
}
enum NQParse {
    static func median(_ xs: [Double]) -> Double? {
        let s = xs.filter { $0 > 0 && $0.isFinite }.sorted(); guard !s.isEmpty else { return nil }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
    /// 抖动：相邻两次空闲延迟之差的平均值（常见测速页的算法）；少于 2 次为未知
    static func jitter(_ xs: [Double]) -> Double? {
        guard xs.count >= 2 else { return nil }
        return zip(xs.dropFirst(), xs).map { abs($0 - $1) }.reduce(0, +) / Double(xs.count - 1)
    }
    static func nums(_ v: Any?) -> [Double] { (v as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? [] }
    static func loaded(_ j: [String: Any], _ dir: String) -> Double? {
        // 负载下延迟：优先用测速中实际测到的请求往返样本；没有就用 RPM（每分钟往返次数）换算
        let keys = j.keys.filter { $0.hasPrefix("lud_") && $0.contains("_\(dir)_") && ($0.contains("req_resp") || $0.contains("h2")) }.sorted()
        let xs = keys.flatMap { nums(j[$0]) }
        if let m = median(xs) { return m }
        if let rpm = (j["\(dir)_responsiveness"] as? NSNumber)?.doubleValue, rpm > 0 { return 60_000 / rpm }
        return nil
    }
    static func parse(_ data: Data) -> NQResult {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return NQResult(error: "测速工具没有返回可读结果") }
        var r = NQResult()
        r.endpoint = j["test_endpoint"] as? String ?? ""; r.iface = j["interface_name"] as? String ?? ""
        if let d = (j["dl_throughput"] as? NSNumber)?.doubleValue, d > 0 { r.downMbps = d / 1_000_000 }
        if let u = (j["ul_throughput"] as? NSNumber)?.doubleValue, u > 0 { r.upMbps = u / 1_000_000 }
        let idle = nums(j["il_h2_req_resp"])
        if let b = (j["base_rtt"] as? NSNumber)?.doubleValue, b > 0 { r.idleMs = b } else { r.idleMs = median(idle) }
        r.jitterMs = jitter(idle); r.jitterSamples = idle.count
        r.downMs = loaded(j, "dl"); r.upMs = loaded(j, "ul")
        if let code = j["error_code"] as? NSNumber {
            r.error = "测速没有完成（networkQuality 错误 \(code.intValue)）" + (r.downMbps == nil && r.upMbps == nil ? "，本次没有速度结果" : "，下面只显示已测到的部分")
        } else if r.downMbps == nil && r.upMbps == nil { r.error = "测速没有测出速度" }
        return r
    }
    static func tier(down: Double?, up: Double?) -> String {
        guard let d = down else { return "没有测出下载速度" }
        var s = d < 10 ? "低于 10 Mbps：网页、标清视频可以，高清视频容易卡"
            : d < 50 ? "10–50 Mbps：高清视频、视频会议够用"
            : d < 100 ? "50–100 Mbps：单路 4K 视频够用"
            : d < 300 ? "100–300 Mbps：几台设备同时看高清/4K 比较顺"
            : d < 1000 ? "300 Mbps–1 Gbps：大文件下载快，多台设备同时 4K 也够用"
            : "1 Gbps 以上：带宽很充足，慢通常是对方服务器或 Wi-Fi 链路"
        if let u = up { s += String(format: "；上传 %.0f Mbps", u) + (u >= 50 ? "，视频会议、上传大文件都够用" : (u >= 10 ? "，视频会议够用" : "，上传大文件会慢")) }
        return s
    }
}
final class SpeedTest24: ObservableObject {
    static var shared = SpeedTest24()
    enum Phase: Equatable { case idle, running, done, failed }
    @Published var phase: Phase = .idle
    @Published var down: [Double] = []   // Mbps，每 0.5 秒一点，同时段主网卡入方向实测
    @Published var up: [Double] = []
    @Published var result: NQResult?
    @Published var finished: Date?
    @Published var elapsed = 0.0
    private var proc: Process?
    private var timer: Timer?
    static let sampleInterval = 0.5, maxRuntime = 25
    func startIfStale() { if MOTests.active { return }; if phase != .running && (finished == nil || Date().timeIntervalSince(finished!) > 600) { start() } }
    func start() {
        guard phase != .running, !MOTests.active else { return }
        down = []; up = []; result = nil; elapsed = 0; phase = .running
        let iface = TunDetect.primaryInterface()
        var last = IfCounters.read()[iface]; var lastT = Date(); let t0 = Date()
        timer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date(), c = IfCounters.read()[iface]
            if let a = c, let b = last, let di = IfCounters.delta(a.0, b.0), let du = IfCounters.delta(a.1, b.1) {
                let s = now.timeIntervalSince(lastT)
                self.down.append(Double(di) * 8 / s / 1e6); self.up.append(Double(du) * 8 / s / 1e6)
            }
            last = c; lastT = now; self.elapsed = now.timeIntervalSince(t0)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
        p.arguments = ["-s", "-c", "-M", "\(Self.maxRuntime)"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let r = NQParse.parse(data)
            DispatchQueue.main.async { self?.finish(r) }
        }
        do { try p.run(); proc = p } catch { finish(NQResult(error: "无法启动系统测速工具 networkQuality")) }
    }
    func finish(_ r: NQResult) {
        timer?.invalidate(); timer = nil; proc = nil
        result = r; finished = Date(); phase = (r.downMbps == nil && r.upMbps == nil) ? .failed : .done
    }
    /// 取消：只结束本应用自己启动的测速子进程
    func cancel() { if let p = proc, p.isRunning { p.terminate() } }
    func inject(_ r: NQResult?, down: [Double], up: [Double], phase: Phase) { result = r; self.down = down; self.up = up; self.phase = phase; finished = Date() }
}

// MARK: - 卸载应用（含残留）
struct UninstallItem: Identifiable, Equatable { var id: String { path }; var path: String; var kind: String; var size: Int64; var selected = true }
struct UninstallEntry: Codable, Equatable { var original: String; var trashed: String? }
struct UninstallRecord: Codable, Identifiable, Equatable { var id = UUID(); var date: Date; var app: String; var bundleID: String; var entries: [UninstallEntry]; var restored = false }
enum UninstallLogic {
    /// 返回不能卸载的原因；nil 表示可以
    static func blockReason(bundleID: String, path: String, whitelist: [String]) -> String? {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        if bundleID.isEmpty { return "读不到这个应用的标识（Bundle ID），为避免误删不处理" }
        if bundleID.hasPrefix("com.apple.") || p.hasPrefix("/System/") { return "系统自带应用，不提供卸载" }
        if bundleID == "com.yost.macoptimizer" { return "不能卸载本应用自己" }
        if CleanLogic.isWhitelisted(p, whitelist: whitelist) { return "该应用在白名单里" }
        if !p.hasSuffix(".app") { return "不是应用包" }
        return nil
    }
    /// 残留路径类别（参考 Mole 的思路自写）：只按 Bundle ID 精确匹配；应用名只用于少数常见目录且名称足够具体。
    /// 共享的 Group Containers 不默认归属某个应用，不列入。
    static func candidates(bundleID: String, name: String, home: String) -> [(String, String)] {
        let L = home + "/Library"
        var out: [(String, String)] = [
            (L + "/Application Support/" + bundleID, "应用数据"), (L + "/Caches/" + bundleID, "缓存"),
            (L + "/Preferences/" + bundleID + ".plist", "偏好设置"), (L + "/Saved Application State/" + bundleID + ".savedState", "窗口状态"),
            (L + "/Containers/" + bundleID, "沙盒容器"), (L + "/Application Scripts/" + bundleID, "应用脚本"),
            (L + "/HTTPStorages/" + bundleID, "网络存储"), (L + "/HTTPStorages/" + bundleID + ".binarycookies", "Cookie"),
            (L + "/Cookies/" + bundleID + ".binarycookies", "Cookie"), (L + "/WebKit/" + bundleID, "网页数据"),
            (L + "/Logs/" + bundleID, "日志"), (L + "/Caches/com.crashlytics.data/" + bundleID, "崩溃数据")
        ]
        let generic: Set<String> = ["app", "apps", "helper", "update", "updater", "data", "cache", "google", "microsoft", "apple", "adobe", "mac", "macos"]
        if name.count >= 4, !generic.contains(name.lowercased()) {
            out += [(L + "/Application Support/" + name, "应用数据"), (L + "/Caches/" + name, "缓存"), (L + "/Logs/" + name, "日志")]
        }
        let fm = FileManager.default
        for (dir, kind) in [(L + "/Preferences/ByHost", "偏好设置"), (L + "/LaunchAgents", "登录启动项")] {
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasPrefix(bundleID + ".") && f.hasSuffix(".plist") { out.append((dir + "/" + f, kind)) }
        }
        return out
    }
    static func size(_ path: String) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0 }
        return CleanLogic.scanDirSize(path)
    }
    static func scan(appPath: String, bundleID: String, name: String, home: String, whitelist: [String]) -> [UninstallItem] {
        var seen = Set<String>(), items: [UninstallItem] = []
        items.append(UninstallItem(path: appPath, kind: "应用本体", size: size(appPath)))
        seen.insert(appPath)
        for (p, k) in candidates(bundleID: bundleID, name: name, home: home) {
            let std = URL(fileURLWithPath: p).standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: std), seen.insert(std).inserted else { continue }
            guard !CleanLogic.isWhitelisted(std, whitelist: whitelist) else { continue }
            items.append(UninstallItem(path: std, kind: k, size: size(std)))
        }
        return items
    }
}
final class Uninstaller: ObservableObject {
    static var shared = Uninstaller()
    @Published var appPath = ""; @Published var appName = ""; @Published var bundleID = ""
    @Published var items: [UninstallItem] = []
    @Published var note = ""
    @Published var busy = false
    @Published var records: [UninstallRecord] = []
    var home = NSHomeDirectory()
    var whitelist: () -> [String] = { CleanStore.shared.whitelist }
    var isRunning: (String) -> Bool = { bid in !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty }
    var moveToTrash: (URL) throws -> URL? = { url in var r: NSURL?; try FileManager.default.trashItem(at: url, resultingItemURL: &r); return r as URL? }
    var logURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacOptimizer/uninstall-log.json")
    init() { if let d = try? Data(contentsOf: logURL), let v = try? JSONDecoder().decode([UninstallRecord].self, from: d) { records = v } }
    func saveLog() {
        if MOTests.active { return }
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(records).write(to: logURL, options: .atomic)
    }
    func choose() {
        let p = NSOpenPanel(); p.directoryURL = URL(fileURLWithPath: "/Applications"); p.allowedContentTypes = [.applicationBundle]; p.canChooseDirectories = false
        p.message = "选择要卸载的应用（只会先列出清单，确认后才移到废纸篓）"
        if p.runModal() == .OK, let u = p.url { load(u.path) }
    }
    func load(_ path: String) {
        let b = Bundle(path: path)
        bundleID = b?.bundleIdentifier ?? ""
        appName = (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (b?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        appPath = path; items = []
        if let r = UninstallLogic.blockReason(bundleID: bundleID, path: path, whitelist: whitelist()) { note = r; return }
        busy = true; note = "正在列出残留…"
        let (bid, name, home, wl) = (bundleID, ((path as NSString).lastPathComponent as NSString).deletingPathExtension, self.home, whitelist())
        DispatchQueue.global(qos: .userInitiated).async {
            let xs = UninstallLogic.scan(appPath: path, bundleID: bid, name: name, home: home, whitelist: wl)
            DispatchQueue.main.async { self.items = xs; self.busy = false; self.note = "找到 \(xs.count - 1) 处残留，确认后连同应用一起移到废纸篓" }
        }
    }
    var selectedSize: Int64 { items.filter(\.selected).reduce(0) { $0 + $1.size } }
    /// 只移到废纸篓；应用正在运行时不处理（不强制退出，请用户自己退出）
    func trashSelected(completion: (() -> Void)? = nil) {
        guard !busy else { return }
        let sel = items.filter(\.selected)
        guard !sel.isEmpty else { note = "请先勾选要移到废纸篓的项"; return }
        if isRunning(bundleID) { note = "\(appName) 正在运行：请先自己退出它，再点卸载（本应用不会强制退出其他应用）"; return }
        if let r = UninstallLogic.blockReason(bundleID: bundleID, path: appPath, whitelist: whitelist()) { note = r; return }
        busy = true; note = "正在移到废纸篓…"
        let move = moveToTrash, wl = whitelist()
        DispatchQueue.global(qos: .userInitiated).async {
            var entries: [UninstallEntry] = [], fails: [String] = []
            for it in sel {
                if CleanLogic.isWhitelisted(it.path, whitelist: wl) || (it.kind != "应用本体" && CleanLogic.isProtected(it.path) && !it.path.hasPrefix(self.home + "/Library/")) { fails.append(it.path); continue }
                do { let t = try move(URL(fileURLWithPath: it.path)); entries.append(UninstallEntry(original: it.path, trashed: t?.path)) }
                catch { fails.append(it.path) }
            }
            DispatchQueue.main.async {
                if !entries.isEmpty {
                    self.records.append(UninstallRecord(date: Date(), app: self.appName, bundleID: self.bundleID, entries: entries)); self.saveLog()
                    ChangeLog.shared.add(kind: .clean, title: "卸载到废纸篓：" + self.appName, detail: "\(entries.count) 项（应用与残留）", reversible: true, restoreNote: "在「清理预览 › 卸载应用」的记录里点恢复")
                }
                let moved = Set(entries.map(\.original)); self.items.removeAll { moved.contains($0.path) }
                self.note = "已移到废纸篓 \(entries.count) 项" + (fails.isEmpty ? "，可在下方记录里恢复" : "；\(fails.count) 项没有移动（可能需要管理员权限或受保护），已保留")
                self.busy = false; completion?()
            }
        }
    }
    /// 恢复：把废纸篓里的项移回原位置；原位置已有同名文件时不覆盖
    @discardableResult func restore(_ rec: UninstallRecord) -> (ok: Int, skipped: Int) {
        let fm = FileManager.default
        var ok = 0, skipped = 0
        for e in rec.entries {
            guard let t = e.trashed, fm.fileExists(atPath: t), !fm.fileExists(atPath: e.original) else { skipped += 1; continue }
            do { try fm.createDirectory(atPath: (e.original as NSString).deletingLastPathComponent, withIntermediateDirectories: true); try fm.moveItem(atPath: t, toPath: e.original); ok += 1 } catch { skipped += 1 }
        }
        if let i = records.firstIndex(where: { $0.id == rec.id }) { records[i].restored = skipped == 0; saveLog() }
        note = "已恢复 \(ok) 项" + (skipped > 0 ? "；\(skipped) 项没有恢复（废纸篓里已不在，或原位置已有同名文件，未覆盖）" : "")
        return (ok, skipped)
    }
}
