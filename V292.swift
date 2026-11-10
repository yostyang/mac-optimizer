// 2.9.2：升级后核对充电助手是不是新版，旧版仍在运行时自动切换（只改主程序，不改助手 → 不需要重新授权）
//
// 背景：助手只监视自己的可执行文件被替换/删除。用户把整个旧 App 拖进废纸篓、再拖入新版时，
// 旧助手的文件只是随旧包移动，没有被替换，于是旧助手继续运行，主程序却已是新版。
// 判断方法：助手进程的启动时间早于包内助手文件的 ctime（inode 状态变更时间 = 这份文件放到磁盘上的时间，
// 拷贝/rsync 会保留 mtime，但 ctime 无法保留），就说明正在运行的是安装前的旧进程。
import Foundation
import ServiceManagement
import Darwin

struct HelperProcess: Equatable { let pid: pid_t; let started: Date }

enum HelperFreshness: Equatable {
    case current               // 运行中的助手是本次安装之后启动的
    case stale                 // 本次安装之前就在运行（旧版或旧路径）
    case notRunning
    case unknown(String)       // 读不到对比信息，不做动作
}

protocol HelperProbe {
    func runningHelpers() -> [HelperProcess]
    /// 包内助手文件放到磁盘上的时间（ctime）
    func bundledInstalled() -> Date?
}

/// 注册与连通，抽成协议以便完整模拟升级流程
protocol HelperControl {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func ping() -> Bool
}

enum HelperCheck {
    static let graceSeconds: TimeInterval = 12
    /// 直接从安装包（/Volumes）或系统隔离的临时位置运行时，不自动重新注册助手：否则助手会被注册到一个随时消失的位置
    static func autoRepairAllowed(bundlePath p: String) -> Bool { !p.hasPrefix("/Volumes/") && !p.contains("/AppTranslocation/") }
    /// 2 秒容差：避免文件系统时间精度造成误判
    static func judge(_ running: [HelperProcess], installed: Date?) -> HelperFreshness {
        guard let p = running.max(by: { $0.started < $1.started }) else { return .notRunning }
        guard let installed else { return .unknown("读不到包内助手的安装时间") }
        return p.started < installed.addingTimeInterval(-2) ? .stale : .current
    }

    enum Outcome: Equatable {
        case ok                     // 本来就是新版，未做任何操作
        case repaired               // 已切换到新版
        case needsApproval          // 新版助手需要在「登录项与扩展」里再允许一次
        case failed(String)
        case skipped(String)        // 未注册 / 读不到信息：不动
    }

    /// 核对并在需要时重新注册。同步执行，调用方放在后台队列。
    /// 重新注册时旧助手收到 SIGTERM 会先恢复正常充电再退出；设置存在 /Library/Application Support，新助手启动后自动读取。
    static func run(probe: HelperProbe, control: HelperControl, wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> Outcome {
        guard control.status == .enabled else {
            return control.status == .requiresApproval ? .needsApproval : .skipped("充电助手未安装")
        }
        var first = judge(probe.runningHelpers(), installed: probe.bundledInstalled())
        // 原地升级时旧助手会自己退出、由 launchd 拉起新版（约 3–6 秒）：先等它自己完成，避免重复操作
        var waited: TimeInterval = 0
        while first == .stale || first == .notRunning, waited < graceSeconds {
            wait(1.5); waited += 1.5
            first = judge(probe.runningHelpers(), installed: probe.bundledInstalled())
        }
        switch first {
        case .current: return control.ping() ? .ok : .failed("充电助手在运行但没有响应")
        case .unknown(let why): return .skipped(why)
        case .stale, .notRunning: break
        }
        for _ in 0..<2 {
            try? control.unregister(); wait(3)
            do { try control.register() } catch { continue }
            if control.status == .requiresApproval { return .needsApproval }
            for _ in 0..<8 {
                wait(1.5)
                if judge(probe.runningHelpers(), installed: probe.bundledInstalled()) == .current, control.ping() { return .repaired }
            }
        }
        if control.status == .requiresApproval { return .needsApproval }
        return .failed(first == .stale ? "旧版充电助手仍在运行，切换没有成功" : "新版充电助手没有启动")
    }
}

// MARK: - 系统实现
struct SystemHelperProbe: HelperProbe {
    var bundledPath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MacOptimizerChargeHelper").path
    /// 进程名在内核里截断为 16 字节：MacOptimizerChargeHelper → MacOptimizerChar
    static let comm = "MacOptimizerChar"
    func runningHelpers() -> [HelperProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = procs.count * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / stride).compactMap { p in
            var comm = p.kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
            guard name == Self.comm else { return nil }
            let t = p.kp_proc.p_starttime
            return HelperProcess(pid: p.kp_proc.p_pid, started: Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000))
        }
    }
    func bundledInstalled() -> Date? {
        var s = stat()
        guard stat(bundledPath, &s) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(s.st_ctimespec.tv_sec) + Double(s.st_ctimespec.tv_nsec) / 1_000_000_000)
    }
}

struct SystemHelperControl: HelperControl {
    var service: SMAppService { SMAppService.daemon(plistName: ChargeConst.plistName) }
    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
    func ping() -> Bool { ChargeClient.ping() }
}

// MARK: - 设置备份：新助手意外读到默认设置时，按上次确认过的设置补写一次
enum ChargeSettingsBackup {
    static let key = "chargeSettingsBackup"
    static func save(_ s: ChargeSettings, defaults: UserDefaults = .standard) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        defaults.set(d, forKey: key)
    }
    static func load(defaults: UserDefaults = .standard) -> ChargeSettings? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(ChargeSettings.self, from: $0) }
    }
    static func clear(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
    /// 只有「助手是默认设置、而备份不是默认」时才补写；扩展坞保护由助手自己判断，不从备份恢复
    static func restoreNeeded(current: ChargeSettings, backup: ChargeSettings?) -> ChargeSettings? {
        guard let b = backup else { return nil }
        var plainCurrent = current; plainCurrent.dockProtected = nil
        var plainBackup = b; plainBackup.dockProtected = nil
        let def = ChargeSettings()
        return plainCurrent == def && plainBackup != def ? plainBackup : nil
    }
}

// MARK: - 界面上的助手版本状态
enum HelperUpgradeState: Equatable {
    case none
    case checking
    case repaired
    case needsApproval
    case failed(String)
}
