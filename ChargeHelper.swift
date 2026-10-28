// 特权助手（launchd 守护进程，root）：充电控制 + DNS 一键修复（固定值）；事件驱动 + 60 秒兜底
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

@main
enum HelperMain {
    static let dir = URL(fileURLWithPath: "/Library/Application Support/\(ChargeConst.label)")
    static let file = dir.appendingPathComponent("settings.json")
    static var svc: ChargeService!
    static var rootPort: io_connect_t = 0
    static var notifier: io_object_t = 0
    static var pendingTick: DispatchWorkItem?

    static func main() {
        let smc = RealSMC()
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(ChargeSettings.self, from: $0) } ?? ChargeSettings()
        let ctl = ChargeController(io: smc, settings: saved)
        svc = ChargeService(ctl: ctl, reader: BatteryReading.read) { s in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? JSONEncoder().encode(s).write(to: file, options: .atomic)
        }
        svc.display = { DisplayProbe.externalCount() > 0 }
        svc.dns = DNSFixer(runner: RealRunner(), backupURL: dir.appendingPathComponent("dns-backup.json"))
        watchDisplays()
        watchSelf()
        // 已启用不先 release 再切断（会闪断 USB-C 显示器）；未启用则恢复默认
        if saved.enabled { svc.tick() } else { ctl.release(); svc.tick() }   // 未启用时 tick 只读取电量/外接屏，不会切电
        // 电源事件：合并短时间内的多次通知，避免切断瞬间的 PD 抖动触发反复 tick
        let src = IOPSNotificationCreateRunLoopSource({ _ in
            HelperMain.pendingTick?.cancel()
            let w = DispatchWorkItem { HelperMain.svc.tick() }
            HelperMain.pendingTick = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
        }, nil).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        let t = Timer(timeInterval: 60, repeats: true) { _ in svc.tick() }; t.tolerance = 20; RunLoop.main.add(t, forMode: .default)
        // 睡眠/唤醒
        var port: IONotificationPortRef?
        rootPort = IORegisterForSystemPower(nil, &port, { _, _, type, arg in
            switch type {
            case 0xE000_0270: IOAllowPowerChange(HelperMain.rootPort, Int(bitPattern: arg))
            case 0xE000_0280: HelperMain.svc.ctl.willSleep(); IOAllowPowerChange(HelperMain.rootPort, Int(bitPattern: arg))
            case 0xE000_0300: HelperMain.svc.tick()
            default: break
            }
        }, &notifier)
        if let port { CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode) }
        // 退出（卸载 / 关机）时恢复默认
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { svc.ctl.release(); exit(0) }; term.resume()
        let listener = NSXPCListener(machServiceName: ChargeConst.label)
        listener.delegate = svc; listener.resume()
        withExtendedLifetime((src, t, term, listener)) { RunLoop.main.run() }
    }

    // 外接屏插拔：IOKit 匹配通知（事件驱动，不轮询）。接上立即判断（只会恢复供电），
    // 拔掉后等防抖时间再判断，避免我们切电导致的掉屏/重连来回触发
    static var displayPort: IONotificationPortRef?
    static var displayIters: [io_iterator_t] = []
    static var pendingDisplay: DispatchWorkItem?
    static func displayChanged() {
        svc.tick()
        pendingDisplay?.cancel()
        let w = DispatchWorkItem { HelperMain.svc.tick() }
        pendingDisplay = w
        DispatchQueue.main.asyncAfter(deadline: .now() + ChargeConst.displayDebounce + 0.5, execute: w)
    }
    static func watchDisplays() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        displayPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let cb: IOServiceMatchingCallback = { _, it in
            while case let o = IOIteratorNext(it), o != 0 { IOObjectRelease(o) }
            HelperMain.displayChanged()
        }
        for cls in DisplayProbe.classes {
            for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var it: io_iterator_t = 0
                if IOServiceAddMatchingNotification(port, type, IOServiceMatching(cls), cb, nil, &it) == KERN_SUCCESS {
                    while case let o = IOIteratorNext(it), o != 0 { IOObjectRelease(o) }   // 清空以布防
                    displayIters.append(it)
                }
            }
        }
    }
    // App 升级替换了助手文件：先恢复默认（接通电源），等新文件就位且稳定后再退出，
    // 让 launchd（KeepAlive）直接拉起同一路径下的新版本。不再需要 App 注销/重新注册（那样会丢失用户授权）
    static var selfWatch: DispatchSourceFileSystemObject?
    /// 每秒检查一次：新文件连续 3 秒存在就退出；3 分钟都没出现（被删除/卸载）也退出
    static func waitForReplacementThenExit(_ path: String, stable: Int = 0, waited: Int = 0) {
        let present = FileManager.default.isExecutableFile(atPath: path)
        let st = present ? stable + 1 : 0
        if st >= 3 || waited >= 180 { exit(0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { waitForReplacementThenExit(path, stable: st, waited: waited + 1) }
    }
    static func watchSelf() {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.delete, .rename, .revoke], queue: .main)
        src.setEventHandler { svc.ctl.release(); selfWatch?.cancel(); waitForReplacementThenExit(path) }
        src.setCancelHandler { close(fd) }
        src.resume(); selfWatch = src
    }
}
