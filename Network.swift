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
    func tcp(_ host: String) -> Bool?
    func tunActive() -> Bool
}
extension NetProbe {
    /// 旧模拟探针没实现时默认“没测过”，而不是“测了不通”，避免把没证据当成断网。
    func tcp(_ host: String) -> Bool? { nil }
    func tunActive() -> Bool { false }
}
final class RealNetProbe: NetProbe {
    let r = RealRunner()
    func ping(_ host: String) -> PingResult { NetParse.ping(r.run("/sbin/ping", ["-c", "5", "-i", "0.2", "-W", "1000", "-t", "4", host]).out) }
    /// TCP 佐证：只在 ping 丢包时才跑。VPN / TUN 常拦截 ICMP 但放行 TCP，
    /// 能连通 443 就说明网络本身没断，ping 丢包不能当成“不稳定”的证据。
    /// 单次最多 2 秒，在诊断的后台队列上跑，不常驻、不改任何设置。
    func tcp(_ host: String) -> Bool? {
        var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &res) == 0, let first = res else { return false }
        defer { freeaddrinfo(first) }
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let a = p {
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd >= 0 {
                var tv = timeval(tv_sec: 2, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                if let sa = a.pointee.ai_addr, connect(fd, sa, a.pointee.ai_addrlen) == 0 { close(fd); return true }
                close(fd)
            }
            p = a.pointee.ai_next
        }
        return false
    }
    /// TUN 模式不一定有可见的 VPN 应用名，但系统里会多出 utun / tun 接口。
    func tunActive() -> Bool {
        var ifs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifs) == 0, let first = ifs else { return false }
        defer { freeifaddrs(first) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            let name = String(cString: a.pointee.ifa_name)
            if name.hasPrefix("utun") || name.hasPrefix("tun") { return true }
            p = a.pointee.ifa_next
        }
        return false
    }
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
    @Published var tun = false
    /// TCP 佐证结果：nil = 没跑过（ping 正常时不跑），true = 至少一个 443 能连通，false = 都连不通。
    @Published var tcpOK: Bool?
    /// VPN 应用在运行，或系统里有 TUN 接口，都算“可能拦截 ICMP / 接管 DNS”。
    var vpnActive: Bool { !vpns.isEmpty || tun }
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
            let eff = p.effectiveDNS(), svc = p.serviceDNS(), v = p.vpnApps(), tun = p.tunActive()
            grp.wait()
            // 只有 ping 丢包时才做 TCP 佐证：平时不跑，不增加诊断耗时和流量。
            let lossHigh = ts.contains { ($0.result?.loss ?? 0) >= 20 }
            var tcp: Bool? = nil
            if lossHigh {
                let results = ["www.baidu.com", "www.apple.com", "github.com"].map { p.tcp($0) }
                if results.contains(true) { tcp = true } else if results.contains(false) { tcp = false }
            }
            DispatchQueue.main.async {
                self.targets = ts; self.resolves = rs; self.effective = eff; self.services = svc; self.vpns = v; self.tun = tun; self.tcpOK = tcp
                self.running = false; self.lastRun = Date(); done?()
            }
        }
    }
    var summary: (String, Bool) {
        guard lastRun != nil else { return ("还没有诊断，点「开始诊断」检测一次（约 3 秒）", true) }
        if resolves.contains(where: { $0.verdict == .suspicious }) { return ("DNS 疑似被劫持，建议一键改用阿里 DNS", false) }
        if resolves.contains(where: { $0.verdict == .failed }) { return ("有域名解析失败，建议一键改用阿里 DNS", false) }
        let lossHigh = targets.contains { ($0.result?.loss ?? 0) >= 20 }
        let gatewayLossHigh = targets.first.map { $0.name.hasPrefix("路由器") && ($0.result?.loss ?? 100) >= 40 } ?? false
        // TCP 能连通时，ping 丢包很可能是 VPN / TUN 拦截 ICMP，不是网络本身不稳定：
        // 不再报“不稳定”，只给仅供参考的结论。TCP 也连不通时，仍按原来的丢包结论报。
        if tcpOK == true && (lossHigh || gatewayLossHigh) {
            return ("TCP 能连通，ping 丢包可能是 VPN / TUN 拦截了 ICMP，网络不一定不稳定（丢包结论仅供参考）", false)
        }
        if vpnActive && tcpOK == nil && (lossHigh || gatewayLossHigh) {
            return ("VPN / TUN 正在运行，ping 丢包仅供参考，请以实际使用为准", false)
        }
        if gatewayLossHigh { return ("连路由器都丢包严重，请检查 Wi-Fi 信号或网线", false) }
        if lossHigh { return ("部分网站丢包较多，网络不太稳定", false) }
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
    private var revision = 0
    private func withProxy(_ f: @escaping (ChargeHelperProtocol) -> Void, onError: @escaping (String) -> Void) {
        if let d = direct { f(d); return }
        guard !offline else { onError("助手未连接"); return }
        let c = NSXPCConnection(machServiceName: ChargeConst.label, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: ChargeHelperProtocol.self)
        if #available(macOS 13.0, *) { c.setCodeSigningRequirement("identifier \"\(ChargeConst.label)\" and certificate leaf = H\"\(ChargeConst.certLeaf)\"") }
        c.resume()
        guard let p = c.remoteObjectProxyWithErrorHandler({ e in DispatchQueue.main.async { onError(e.localizedDescription) }; c.invalidate() }) as? ChargeHelperProtocol else { onError("无法创建助手连接"); c.invalidate(); return }
        f(p)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { c.invalidate() }
    }
    func refresh() {
        guard !busy, direct != nil || (!offline && helperReady()) else { return }
        revision += 1; let requestRevision = revision
        withProxy({ proxy in proxy.dnsStatus { data in
            DispatchQueue.main.async {
                guard requestRevision == self.revision, !self.busy else { return }
                self.status = try? JSONDecoder().decode(DNSStatus.self, from: data)
            }
        } }, onError: { error in
            guard requestRevision == self.revision, !self.busy else { return }
            self.note = "无法连接助手：" + error
        })
    }

    var requestTimeout: TimeInterval = 15
    private var actionID: UUID?
    private func act(restoring: Bool, completion: ((Bool, String) -> Void)?) {
        guard !busy else { completion?(false, "已有 DNS 操作正在进行，请等待核对结果"); return }
        guard direct != nil || (!offline && helperReady()) else {
            note = "助手尚未连接，请先到电池页检查授权"; completion?(false, note); return
        }
        revision += 1
        let id = UUID(); actionID = id; busy = true; note = "正在执行并核对 DNS…"
        func finish(_ success: Bool, _ message: String) {
            guard self.actionID == id else { return }
            self.actionID = nil; self.busy = false; self.note = message
            if success {
                NetDiag.shared.lastRun = nil
                ChangeLog.shared.add(kind: .dns, title: message, detail: "已读取系统 DNS 并核对操作结果", reversible: !restoring,
                                     restoreNote: "在网络诊断或改动记录中恢复原 DNS")
            }
            completion?(success, message)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) {
            finish(false, "未在时限内确认 DNS 结果，请刷新状态后再试")
        }
        withProxy({ proxy in
            func perform(backup: [DNSServiceState]?) {
                let reply: (Bool, String) -> Void = { success, error in
                    DispatchQueue.main.async {
                        guard self.actionID == id else { return }
                        guard success else { finish(false, error.isEmpty ? "DNS 操作失败，原记录已保留" : error); return }
                        proxy.dnsStatus { data in
                            DispatchQueue.main.async {
                                guard self.actionID == id else { return }
                                guard let current = try? JSONDecoder().decode(DNSStatus.self, from: data), current.lastError.isEmpty else {
                                    finish(false, "操作已发起，但无法读取 DNS 结果，请刷新后核对"); return
                                }
                                self.status = current
                                let verified: Bool
                                if restoring, let backup {
                                    verified = current.backup == nil && !backup.isEmpty && backup.allSatisfy { old in
                                        current.services.contains { $0.service == old.service && $0.servers == old.servers }
                                    }
                                } else {
                                    verified = !current.services.isEmpty && current.backup != nil && current.services.allSatisfy { $0.servers == DNSConst.ali }
                                }
                                finish(verified, verified ? (restoring ? "已恢复并核对原 DNS" : "已设置并核对阿里 DNS") : "操作已返回，但 DNS 状态与预期不一致，请刷新后检查")
                            }
                        }
                    }
                }
                if restoring { proxy.restoreDNS(reply) } else { proxy.setAliDNS(reply) }
            }
            if restoring {
                proxy.dnsStatus { data in
                    let useStatus = {
                        guard self.actionID == id else { return }
                        guard let current = try? JSONDecoder().decode(DNSStatus.self, from: data) else {
                            finish(false, "无法读取最新 DNS 状态，未执行恢复"); return
                        }
                        self.status = current
                        guard let backup = current.backup, !backup.isEmpty else {
                            finish(false, "没有 DNS 备份，无法恢复"); return
                        }
                        perform(backup: backup)
                    }
                    if Thread.isMainThread { useStatus() } else { DispatchQueue.main.async(execute: useStatus) }
                }
            } else { perform(backup: nil) }
        }, onError: { finish(false, "无法连接助手：" + $0) })
    }
    func setAli(completion: ((Bool, String) -> Void)? = nil) { act(restoring: false, completion: completion) }
    func restore(completion: ((Bool, String) -> Void)? = nil) { act(restoring: true, completion: completion) }
    var isAli: Bool { guard let s = status, s.lastError.isEmpty, !s.services.isEmpty else { return false }; return s.services.allSatisfy { $0.servers == DNSConst.ali } }
}
