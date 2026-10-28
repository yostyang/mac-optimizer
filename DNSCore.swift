// DNS 一键修复核心：App 与特权助手共用。只会把 DNS 设为固定的阿里公共 DNS，或恢复之前保存的值，不接受任意输入
import Foundation

enum DNSConst {
    static let ali = ["223.5.5.5", "223.6.6.6"]
}

struct DNSServiceState: Codable, Equatable {
    var service: String
    var device: String
    var servers: [String]      // 空 = 自动（DHCP，networksetup 里的 "Empty"）
}
struct DNSStatus: Codable, Equatable {
    var services: [DNSServiceState] = []
    var backup: [DNSServiceState]? = nil     // 有值 = 已改过，可以恢复
    var lastError: String = ""
}

/// 外部命令执行抽象：只执行固定路径的程序（测试时用模拟实现，不改真实 DNS）
protocol CommandRunner: AnyObject {
    func run(_ path: String, _ args: [String]) -> (code: Int32, out: String)
}
final class RealRunner: CommandRunner {
    func run(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
    }
}

final class DNSFixer {
    static let ns = "/usr/sbin/networksetup"
    let runner: CommandRunner
    let backupURL: URL?
    init(runner: CommandRunner, backupURL: URL?) { self.runner = runner; self.backupURL = backupURL }

    /// 已启用的网络服务（名称 + 设备），按服务顺序
    func services() -> [(name: String, device: String)] {
        let out = runner.run(Self.ns, ["-listnetworkserviceorder"]).out
        var res: [(String, String)] = []; var pending: String?
        for raw in out.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("(*)") { pending = nil; continue }      // 已停用
            if l.hasPrefix("("), let close = l.firstIndex(of: ")"), !l.hasPrefix("(Hardware") {
                let name = l[l.index(after: close)...].trimmingCharacters(in: .whitespaces)
                pending = name.hasPrefix("*") ? nil : name      // * = 已停用
            } else if l.hasPrefix("(Hardware Port:"), let n = pending, let r = l.range(of: "Device: ") {
                let dev = l[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))
                res.append((n, dev)); pending = nil
            }
        }
        return res
    }
    /// 正在使用的服务：设备有 IPv4 地址
    func activeServices() -> [(name: String, device: String)] {
        services().filter { !$0.device.isEmpty && runner.run("/usr/sbin/ipconfig", ["getifaddr", $0.device]).out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }
    func servers(_ svc: String) -> [String] {
        let out = runner.run(Self.ns, ["-getdnsservers", svc]).out
        let ips = out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter(DNSFixer.isIP)
        return ips
    }
    static func isIP(_ s: String) -> Bool {
        var a = in_addr(), b = in6_addr()
        return inet_pton(AF_INET, s, &a) == 1 || inet_pton(AF_INET6, s, &b) == 1
    }
    func loadBackup() -> [DNSServiceState]? {
        guard let u = backupURL, let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode([DNSServiceState].self, from: d)
    }
    func status() -> DNSStatus {
        DNSStatus(services: activeServices().map { DNSServiceState(service: $0.name, device: $0.device, servers: servers($0.name)) }, backup: loadBackup())
    }
    private func set(_ svc: String, _ servers: [String]) -> Bool {
        runner.run(Self.ns, ["-setdnsservers", svc] + (servers.isEmpty ? ["Empty"] : servers)).code == 0
    }
    func flush() {
        _ = runner.run("/usr/bin/dscacheutil", ["-flushcache"])
        _ = runner.run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }
    /// 设为阿里 DNS：第一次改之前保存原值（已经有备份就不覆盖，保证恢复的是最初的设置）
    func setAli() -> (Bool, String) {
        let act = activeServices()
        guard !act.isEmpty else { return (false, "没有正在使用的网络") }
        var backup = loadBackup() ?? []
        for s in act where !backup.contains(where: { $0.service == s.name }) {
            backup.append(DNSServiceState(service: s.name, device: s.device, servers: servers(s.name)))
        }
        if let u = backupURL {
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? JSONEncoder().encode(backup).write(to: u, options: .atomic)) != nil else { return (false, "无法保存原 DNS，已取消修改") }
        }
        var failed: [String] = []
        for s in act where !set(s.name, DNSConst.ali) { failed.append(s.name) }
        flush()
        return failed.isEmpty ? (true, "") : (false, "以下网络设置失败：" + failed.joined(separator: "、"))
    }
    func restore() -> (Bool, String) {
        guard let b = loadBackup() else { return (false, "没有保存的原 DNS") }
        let known = Set(services().map(\.name))
        var failed: [String] = []
        for s in b where known.contains(s.service) && !set(s.service, s.servers) { failed.append(s.service) }
        flush()
        if failed.isEmpty, let u = backupURL { try? FileManager.default.removeItem(at: u) }
        return failed.isEmpty ? (true, "") : (false, "以下网络恢复失败：" + failed.joined(separator: "、"))
    }
}
