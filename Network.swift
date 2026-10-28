// 网络诊断：延迟/丢包（按需）、DNS 检测（服务器、解析耗时、劫持/失败）、DNS 一键修复（经特权助手）
import Foundation
import AppKit

struct PingResult: Equatable { var avgMs: Double?; var loss: Double; var sent: Int }
struct PingTarget: Identifiable, Equatable { var id: String { host }; var name: String; var host: String; var result: PingResult? }
struct ResolveResult: Identifiable, Equatable {
    var id: String { host }
    var host: String; var ms: Double?; var addrs: [String]; var verdict: Verdict
    enum Verdict: String { case ok = "正常", failed = "解析失败", suspicious = "疑似劫持", vpnFake = "VPN 虚拟地址", slow = "较慢" }
}

enum NetParse {
    /// 解析 ping 输出
    static func ping(_ out: String) -> PingResult {
        var loss = 100.0, avg: Double? = nil, sent = 0
        for l in out.components(separatedBy: "\n") {
            if l.contains("packets transmitted") {
                let parts = l.components(separatedBy: ",")
                sent = Int(parts.first?.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "") ?? 0
                if let p = parts.first(where: { $0.contains("packet loss") }) { loss = Double(p.trimmingCharacters(in: .whitespaces).components(separatedBy: "%").first ?? "") ?? 100 }
            }
            if l.contains("round-trip") || l.contains("rtt"), let eq = l.components(separatedBy: "= ").last {
                let v = eq.components(separatedBy: "/"); if v.count >= 2 { avg = Double(v[1]) }
            }
        }
        return PingResult(avgMs: avg, loss: loss, sent: sent)
    }
    static func gateway(_ routeOut: String) -> String? {
        for l in routeOut.components(separatedBy: "\n") where l.contains("gateway:") {
            let g = l.components(separatedBy: "gateway:").last!.trimmingCharacters(in: .whitespaces); if DNSFixer.isIP(g) { return g }
        }
        return nil
    }
    /// scutil --dns 第一个解析器的 nameserver（系统实际在用的）
    static func effectiveDNS(_ scutil: String) -> [String] {
        var out: [String] = []; var inFirst = false
        for l in scutil.components(separatedBy: "\n") {
            if l.hasPrefix("resolver #") { if inFirst { break }; inFirst = l.hasPrefix("resolver #1") }
            if inFirst, l.contains("nameserver["), let v = l.components(separatedBy: ": ").last { out.append(v.trimmingCharacters(in: .whitespaces)) }
        }
        return out
    }
    static func isPrivate(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return ip == "::1" || ip.hasPrefix("fe80") || ip.hasPrefix("fc") || ip.hasPrefix("fd") }
        return p[0] == 10 || p[0] == 127 || p[0] == 0 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 169 && p[1] == 254)
    }
    static func isVPNFake(_ ip: String) -> Bool { let p = ip.split(separator: ".").compactMap { Int($0) }; return p.count == 4 && p[0] == 198 && (p[1] == 18 || p[1] == 19) }
    static func verdict(host: String, ms: Double?, addrs: [String], expectNX: Bool) -> ResolveResult.Verdict {
        if expectNX { return addrs.isEmpty ? .ok : (addrs.allSatisfy(isVPNFake) ? .vpnFake : .suspicious) }           // 不存在的域名却解析出地址 = 被劫持
        if addrs.isEmpty { return .failed }
        if addrs.allSatisfy(isVPNFake) { return .vpnFake }
        if addrs.contains(where: isPrivate) { return .suspicious }
        if let m = ms, m > 300 { return .slow }
        return .ok
    }
}

/// 外部能力（测试时替换）
protocol NetProbe: AnyObject {
    func ping(_ host: String) -> PingResult
    func gateway() -> String?
    func resolve(_ host: String) -> (ms: Double?, addrs: [String])
    func effectiveDNS() -> [String]
    func serviceDNS() -> [DNSServiceState]
    func vpnApps() -> [String]
}
final class RealNetProbe: NetProbe {
    let r = RealRunner()
    func ping(_ host: String) -> PingResult { NetParse.ping(r.run("/sbin/ping", ["-c", "5", "-i", "0.2", "-W", "1000", "-t", "4", host]).out) }
    func gateway() -> String? { NetParse.gateway(r.run("/sbin/route", ["-n", "get", "default"]).out) }
    func resolve(_ host: String) -> (ms: Double?, addrs: [String]) {
        var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let t0 = Date()
        let rc = getaddrinfo(host, nil, &hints, &res)
        let ms = Date().timeIntervalSince(t0) * 1000
        guard rc == 0, let first = res else { return (nil, []) }
        defer { freeaddrinfo(first) }
        var out: [String] = []; var p: UnsafeMutablePointer<addrinfo>? = first
        while let a = p {
            if let sa = a.pointee.ai_addr, a.pointee.ai_family == AF_INET {
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { var ad = $0.pointee.sin_addr; inet_ntop(AF_INET, &ad, &buf, socklen_t(buf.count)) }
                let s = String(cString: buf); if !out.contains(s) { out.append(s) }
            }
            p = a.pointee.ai_next
        }
        return (ms, out)
    }
    func effectiveDNS() -> [String] { NetParse.effectiveDNS(r.run("/usr/sbin/scutil", ["--dns"]).out) }
    func serviceDNS() -> [DNSServiceState] { DNSFixer(runner: r, backupURL: nil).status().services }   // 只读
    func vpnApps() -> [String] { NSWorkspace.shared.runningApplications.compactMap { $0.localizedName }.filter { $0.contains("VPN") || $0.contains("鹊桥") || $0.contains("LetsVPN") } }
}

final class NetDiag: ObservableObject {
    static var shared = NetDiag()
    @Published var targets: [PingTarget] = []
    @Published var resolves: [ResolveResult] = []
    @Published var effective: [String] = []
    @Published var services: [DNSServiceState] = []
    @Published var vpns: [String] = []
    @Published var running = false
    @Published var lastRun: Date?
    var probe: NetProbe = RealNetProbe()
    static let sites: [(String, String)] = [("阿里 DNS", "223.5.5.5"), ("百度", "www.baidu.com"), ("淘宝", "www.taobao.com"), ("Apple", "www.apple.com"), ("GitHub", "github.com")]
    static let resolveHosts = ["www.baidu.com", "www.qq.com", "www.apple.com", "github.com"]
    /// 只在用户点「开始诊断」时运行，不常驻
    func run(done: (() -> Void)? = nil) {
        guard !running else { return }
        running = true
        let p = probe
        DispatchQueue.global(qos: .userInitiated).async {
            var ts: [PingTarget] = []
            if let g = p.gateway() { ts.append(PingTarget(name: "路由器（网关）", host: g)) }
            ts += Self.sites.map { PingTarget(name: $0.0, host: $0.1) }
            let lock = NSLock(); let grp = DispatchGroup()
            for i in ts.indices { grp.enter(); DispatchQueue.global().async { let r = p.ping(ts[i].host); lock.lock(); ts[i].result = r; lock.unlock(); grp.leave() } }
            var rs: [ResolveResult] = []
            let nx = "mo-\(UUID().uuidString.prefix(8).lowercased())-check.com"
            for h in Self.resolveHosts + [nx] {
                let r = p.resolve(h)
                rs.append(ResolveResult(host: h == nx ? "不存在的域名（劫持检测）" : h, ms: r.ms, addrs: r.addrs, verdict: NetParse.verdict(host: h, ms: r.ms, addrs: r.addrs, expectNX: h == nx)))
            }
            let eff = p.effectiveDNS(), svc = p.serviceDNS(), v = p.vpnApps()
            grp.wait()
            DispatchQueue.main.async {
                self.targets = ts; self.resolves = rs; self.effective = eff; self.services = svc; self.vpns = v
                self.running = false; self.lastRun = Date(); done?()
            }
        }
    }
    var summary: (String, Bool) {
        guard lastRun != nil else { return ("还没有诊断，点「开始诊断」检测一次（约 3 秒）", true) }
        if resolves.contains(where: { $0.verdict == .suspicious }) { return ("DNS 疑似被劫持，建议一键改用阿里 DNS", false) }
        if resolves.contains(where: { $0.verdict == .failed }) { return ("有域名解析失败，建议一键改用阿里 DNS", false) }
        if let g = targets.first, g.name.hasPrefix("路由器"), (g.result?.loss ?? 100) >= 40 { return ("连路由器都丢包严重，请检查 Wi-Fi 信号或网线", false) }
        if targets.contains(where: { ($0.result?.loss ?? 0) >= 20 }) { return ("部分网站丢包较多，网络不太稳定", false) }
        return ("网络正常", true)
    }
}

/// DNS 修复：经特权助手（与充电控制同一个助手、同样的签名校验），没有任何可传入的参数
final class DNSClient: ObservableObject {
    static var shared = DNSClient()
    @Published var status: DNSStatus?
    @Published var busy = false
    @Published var note = ""
    var offline = false
    var helperReady: () -> Bool = { ChargeClient.shared.phase == .ready }
    /// 测试注入：直接调用服务对象（模拟助手）
    var direct: ChargeHelperProtocol?
    private func withProxy(_ f: @escaping (ChargeHelperProtocol) -> Void, onError: @escaping (String) -> Void) {
        if let d = direct { f(d); return }
        guard !offline else { return }
        let c = NSXPCConnection(machServiceName: ChargeConst.label, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: ChargeHelperProtocol.self)
        if #available(macOS 13.0, *) { c.setCodeSigningRequirement("identifier \"\(ChargeConst.label)\" and certificate leaf = H\"\(ChargeConst.certLeaf)\"") }
        c.resume()
        guard let p = c.remoteObjectProxyWithErrorHandler({ e in DispatchQueue.main.async { onError(e.localizedDescription) }; c.invalidate() }) as? ChargeHelperProtocol else { return }
        f(p)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { c.invalidate() }
    }
    func refresh() {
        guard direct != nil || (!offline && helperReady()) else { return }
        withProxy({ p in p.dnsStatus { d in let s = try? JSONDecoder().decode(DNSStatus.self, from: d); DispatchQueue.main.async { self.status = s } } }, onError: { self.note = "无法连接助手：\($0)" })
    }
    private func act(_ f: @escaping (ChargeHelperProtocol, @escaping (Bool, String) -> Void) -> Void, ok: String) {
        busy = true; note = ""
        withProxy({ p in f(p) { success, msg in DispatchQueue.main.async { self.busy = false; self.note = success ? ok : msg; self.refresh(); NetDiag.shared.lastRun = nil } } },
                  onError: { self.busy = false; self.note = "无法连接助手：\($0)" })
    }
    func setAli() { act({ $0.setAliDNS($1) }, ok: "已改为阿里 DNS 并清除了 DNS 缓存") }
    func restore() { act({ $0.restoreDNS($1) }, ok: "已恢复原来的 DNS") }
    var isAli: Bool { guard let s = status, !s.services.isEmpty else { return false }; return s.services.allSatisfy { $0.servers == DNSConst.ali } }
}
