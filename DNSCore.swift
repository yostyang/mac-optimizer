// DNS 一键修复核心：App 与特权助手共用。只会把 DNS 设为固定的阿里公共 DNS，或恢复之前保存的值，不接受任意输入
import Foundation
import Darwin

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
struct CommandResult {
    let code: Int32
    let out: String
    let err: String
    var timedOut = false
    var outputTruncated = false
    var succeeded: Bool { code == 0 && !timedOut }
}

/// App 与助手共用的命令入口：参数不经 shell，两路输出同时排空，等待有上限。
enum ProcessRunner {
    static let outputLimit = 1_048_576       // 每一路最多保留 1 MiB，超过后继续排空，避免内存失控或堵住子进程。
    static let timeoutCode: Int32 = 124

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> CommandResult {
        guard path.hasPrefix("/"), timeout.isFinite, timeout > 0 else {
            return CommandResult(code: -1, out: "", err: "命令路径或超时时间无效")
        }
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        defer {
            try? stdout.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForReading.close()
            try? stderr.fileHandleForWriting.close()
        }
        let outFD = stdout.fileHandleForReading.fileDescriptor
        let errFD = stderr.fileHandleForReading.fileDescriptor
        for fd in [outFD, errFD] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                return CommandResult(code: -1, out: "", err: "无法准备命令输出")
            }
        }
        do { try process.run() } catch {
            return CommandResult(code: -1, out: "", err: error.localizedDescription)
        }
        // 子进程已持有自己的写端；关闭父进程写端才能观察 EOF。
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        var out = Data(), err = Data(), outEOF = false, errEOF = false, truncated = false
        var buffer = [UInt8](repeating: 0, count: 16_384)
        func drain(_ fd: Int32, into data: inout Data, eof: inout Bool) {
            guard !eof else { return }
            // 有限批次，持续输出的程序也不能饿死另一输出流或超时检查。
            for _ in 0..<16 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    let keep = min(count, max(0, outputLimit - data.count))
                    if keep > 0 { data.append(contentsOf: buffer.prefix(keep)) }
                    if keep < count { truncated = true }
                } else if count == 0 {
                    eof = true
                    return
                } else if errno == EINTR {
                    continue
                } else {
                    if errno != EAGAIN && errno != EWOULDBLOCK { eof = true }
                    return
                }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var expiredAt: TimeInterval?, exitedAt: TimeInterval?
        while true {
            drain(outFD, into: &out, eof: &outEOF)
            drain(errFD, into: &err, eof: &errEOF)
            let now = ProcessInfo.processInfo.systemUptime
            if !process.isRunning {
                if exitedAt == nil { exitedAt = now }
                // 后代可能继承管道；不因它一直持有写端而无期限等待 EOF。
                if (outEOF && errEOF) || now - (exitedAt ?? now) >= 0.1 { break }
            } else if now >= deadline {
                if expiredAt == nil {
                    expiredAt = now
                    process.terminate()
                } else if now - (expiredAt ?? now) >= 0.2 {
                    // 只处理本次创建的子进程，不向进程组或用户应用发送信号。
                    _ = kill(process.processIdentifier, SIGKILL)
                }
                if now - (expiredAt ?? now) >= 1 { break }
            }
            var descriptors = [pollfd(fd: outEOF ? -1 : outFD, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: errEOF ? -1 : errFD, events: Int16(POLLIN), revents: 0)]
            _ = descriptors.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), 20) }
        }
        let timedOut = expiredAt != nil
        let code: Int32
        if process.isRunning {
            code = timeoutCode
        } else {
            process.waitUntilExit()
            code = timedOut ? timeoutCode : process.terminationStatus
        }
        return CommandResult(code: code, out: String(decoding: out, as: UTF8.self),
                             err: String(decoding: err, as: UTF8.self), timedOut: timedOut,
                             outputTruncated: truncated)
    }
}

final class RealRunner: CommandRunner {
    let timeout: TimeInterval
    init(timeout: TimeInterval = 10) { self.timeout = timeout }
    func run(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
        let result = ProcessRunner.run(path, args, timeout: timeout)
        return (result.code, result.out)
    }
}

final class DNSFixer {
    enum ReadError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
    }
    static let ns = "/usr/sbin/networksetup"
    let runner: CommandRunner
    let backupURL: URL?
    init(runner: CommandRunner, backupURL: URL?) { self.runner = runner; self.backupURL = backupURL }

    /// 已启用的网络服务（名称 + 设备），按服务顺序
    func services() throws -> [(name: String, device: String)] {
        let result = runner.run(Self.ns, ["-listnetworkserviceorder"])
        guard result.code == 0, !result.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReadError.failed("无法读取网络服务，未修改 DNS")
        }
        let out = result.out
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
    func activeServices() throws -> [(name: String, device: String)] {
        try services().filter {
            guard !$0.device.isEmpty else { return false }
            let address = runner.run("/usr/sbin/ipconfig", ["getifaddr", $0.device])
            return address.code == 0 && Self.isIP(address.out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    func servers(_ svc: String) throws -> [String] {
        let result = runner.run(Self.ns, ["-getdnsservers", svc])
        guard result.code == 0 else { throw ReadError.failed("无法读取 \(svc) 的原 DNS，未修改设置") }
        let out = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out == "There aren't any DNS Servers set on \(svc)." { return [] }
        let ips = out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !ips.isEmpty, ips.allSatisfy(Self.isIP) else { throw ReadError.failed("\(svc) 的 DNS 返回格式异常，未修改设置") }
        return ips
    }
    static func isIP(_ s: String) -> Bool {
        var a = in_addr(), b = in6_addr()
        return inet_pton(AF_INET, s, &a) == 1 || inet_pton(AF_INET6, s, &b) == 1
    }
    func loadBackup() -> [DNSServiceState]? {
        try? readBackup()
    }
    private func readBackup() throws -> [DNSServiceState]? {
        guard let u = backupURL else { return nil }
        do {
            let d = try Data(contentsOf: u)
            return try JSONDecoder().decode([DNSServiceState].self, from: d)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        catch { throw ReadError.failed("无法读取 DNS 备份，原文件已保留：\(error.localizedDescription)") }
    }
    private func saveBackup(_ backup: [DNSServiceState]) throws {
        guard let u = backupURL else { throw ReadError.failed("无法保存原 DNS，已取消修改") }
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(backup).write(to: u, options: .atomic)
    }
    func status() -> DNSStatus {
        do {
            let current = try activeServices().map { DNSServiceState(service: $0.name, device: $0.device, servers: try servers($0.name)) }
            return DNSStatus(services: current, backup: try readBackup())
        } catch { return DNSStatus(backup: loadBackup(), lastError: error.localizedDescription) }
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
        do {
            let act = try activeServices()
            guard !act.isEmpty else { return (false, "没有正在使用的网络") }
            var backup = try readBackup() ?? []
            for s in act where !backup.contains(where: { $0.service == s.name }) {
                backup.append(DNSServiceState(service: s.name, device: s.device, servers: try servers(s.name)))
            }
            try saveBackup(backup)
            var failed: [String] = []
            for s in act where !set(s.name, DNSConst.ali) { failed.append(s.name) }
            flush()
            return failed.isEmpty ? (true, "") : (false, "以下网络设置失败：" + failed.joined(separator: "、"))
        } catch { return (false, error.localizedDescription) }
    }
    func restore() -> (Bool, String) {
        do {
            guard let b = try readBackup(), !b.isEmpty else { return (false, "没有保存的原 DNS") }
            let known = Set(try services().map(\.name))
            var remaining: [DNSServiceState] = []
            for s in b {
                guard known.contains(s.service), set(s.service, s.servers),
                      let actual = try? servers(s.service), actual == s.servers else { remaining.append(s); continue }
            }
            flush()
            if remaining.isEmpty, let u = backupURL { try FileManager.default.removeItem(at: u) }
            else { try saveBackup(remaining) }
            return remaining.isEmpty ? (true, "") : (false, "以下网络尚未恢复，备份已保留：" + remaining.map(\.service).joined(separator: "、"))
        } catch { return (false, error.localizedDescription) }
    }
}
