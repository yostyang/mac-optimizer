// 充电控制核心：App 与特权助手共用（助手只编译本文件 + ChargeHelper.swift）
import Foundation
import IOKit

enum ChargeConst {
    static let label = "com.yost.macoptimizer.chargehelper"
    static let plistName = "com.yost.macoptimizer.chargehelper.plist"
    static let appID = "com.yost.macoptimizer"
    static let certLeaf = "f84b9654f42df2c8bfdd75f7eaf123a7525d060c"   // 固定自签名证书 SHA-1
    static var clientRequirement: String { "identifier \"\(appID)\" and certificate leaf = H\"\(certLeaf)\"" }
    static let limitRange = 50...100, sailRange = 0...10
    static let hardFloor = 20          // 低于这个电量无条件恢复供电和充电
    static let displayDebounce: TimeInterval = 10   // 外接屏变化后等 10 秒再恢复上限（避免自己切电导致的掉屏来回抖动）
    static let adapterHold: TimeInterval = 45  // 切断 CHIE 最短间隔，避免闪断 USB-C 显示器/扩展坞
    // MagSafe 灯（ACLC）：0 交给系统，3 绿，4 橙
    static let ledSystem: UInt8 = 0, ledGreen: UInt8 = 3, ledOrange: UInt8 = 4
}

// MARK: - SMC 读写抽象（测试用模拟实现）
protocol SMCIO: AnyObject {
    func read(_ k: String) -> [UInt8]?           // nil = 不存在 / 无数据 / 被拒绝
    func write(_ k: String, _ b: [UInt8]) -> Bool
}

final class RealSMC: SMCIO {
    struct KI { var size: UInt32 = 0; var type: UInt32 = 0; var attr: UInt8 = 0; var p1: UInt8 = 0; var p2: UInt8 = 0; var p3: UInt8 = 0 }
    struct KD {
        var key: UInt32 = 0
        var vers = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt16(0))
        var plimit = (UInt16(0), UInt16(0), UInt32(0), UInt32(0), UInt32(0))
        var info = KI(); var result: UInt8 = 0; var status: UInt8 = 0; var data8: UInt8 = 0; var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }
    private var conn: io_connect_t = 0
    init() {
        for name in ["AppleSMCKeysEndpoint", "AppleSMC"] where conn == 0 {
            let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
            if svc != 0 { _ = IOServiceOpen(svc, mach_task_self_, 0, &conn); IOObjectRelease(svc) }
        }
    }
    deinit { if conn != 0 { IOServiceClose(conn) } }
    var available: Bool { conn != 0 }
    static func fourcc(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    private func call(_ i: inout KD) -> Bool {
        var o = KD(); var sz = MemoryLayout<KD>.stride
        let r = IOConnectCallStructMethod(conn, 2, &i, MemoryLayout<KD>.stride, &o, &sz)
        i = o; return r == KERN_SUCCESS && o.result == 0
    }
    private func info(_ k: String) -> KI? {
        guard conn != 0, k.utf8.count == 4 else { return nil }
        var i = KD(); i.key = RealSMC.fourcc(k); i.data8 = 9
        guard call(&i), i.info.size > 0, i.info.size <= 32 else { return nil }   // 0 字节占位键视为不存在
        return i.info
    }
    func read(_ k: String) -> [UInt8]? {
        guard let ki = info(k) else { return nil }
        var j = KD(); j.key = RealSMC.fourcc(k); j.info.size = ki.size; j.data8 = 5
        guard call(&j) else { return nil }
        var b = j.bytes
        return withUnsafeBytes(of: &b) { Array($0.prefix(Int(ki.size))) }
    }
    func write(_ k: String, _ b: [UInt8]) -> Bool {
        guard let ki = info(k), Int(ki.size) == b.count else { return false }
        var j = KD(); j.key = RealSMC.fourcc(k); j.info.size = ki.size; j.data8 = 6
        withUnsafeMutableBytes(of: &j.bytes) { p in for (n, v) in b.enumerated() { p[n] = v } }
        return call(&j)
    }
}

// MARK: - 能力检测
struct ChargeCaps: Codable, Equatable {
    enum Inhibit: String, Codable { case none, chte, ch0bc }
    var inhibit: Inhibit = .none     // 独立的「暂停充电」键
    var adapter = false              // CHIE：断开电源适配器（电池供电 = 放电）
    var led = false                  // ACLC：MagSafe 灯
    var keys: [String] = []
    var any: Bool { inhibit != .none || adapter }
    static func detect(_ io: SMCIO) -> ChargeCaps {
        var c = ChargeCaps()
        if io.read("CHTE")?.count == 4 { c.inhibit = .chte; c.keys.append("CHTE") }
        else if io.read("CH0B")?.count == 1, io.read("CH0C")?.count == 1 { c.inhibit = .ch0bc; c.keys += ["CH0B", "CH0C"] }
        if io.read("CHIE")?.count == 1 { c.adapter = true; c.keys.append("CHIE") }
        if io.read("ACLC")?.count == 1 { c.led = true; c.keys.append("ACLC") }
        return c
    }
    /// 没有独立停充键时，用断开适配器实现上限：到上限后改用电池，降到下沿再恢复
    var adapterMode: Bool { inhibit == .none && adapter }
}

struct ChargeSettings: Codable, Equatable {
    var enabled = false
    var limit = 80
    var sail = 5
    var autoDischarge = true
    var led = true
}

struct ChargeStatus: Codable, Equatable {
    var settings = ChargeSettings()
    var caps = ChargeCaps()
    var topUp = false
    var inhibited = false
    var adapterCut = false
    var level: Int? = nil
    var plugged = false
    var lastError = ""
    var ledWritable: Bool? = nil
    var version = 1
    var externalDisplay: Bool? = nil     // 可选：兼容旧助手返回的 JSON
    var displayPaused: Bool? = nil       // 接了外接屏 → 暂停上限（不切电源）
}

// MARK: - 控制逻辑（纯逻辑 + SMC 写入，可用模拟 SMC 完整测试）
final class ChargeController {
    let io: SMCIO
    private(set) var caps: ChargeCaps
    var settings: ChargeSettings
    private(set) var topUp = false
    private(set) var inhibited = false
    private(set) var adapterCut = false
    private(set) var led: UInt8? = nil
    private(set) var lastError = ""
    private(set) var ledWritable: Bool? = nil
    private(set) var level: Int? = nil
    private(set) var plugged = false
    var now: () -> Date = Date.init
    private var lastCutAt: Date = .distantPast
    /// 睡眠/临时充满结束后允许立刻再次切断（不受防抖限制）
    private var forceNextCut = false
    /// 切断/停充时的上限：上限调高后立即恢复
    private var heldAtLimit = 0
    private(set) var externalDisplay = false
    private var displayChangedAt: Date = .distantPast
    /// 接着外接屏，或刚插拔不到 10 秒：绝不切断电源
    var displayPaused: Bool { externalDisplay || now().timeIntervalSince(displayChangedAt) < ChargeConst.displayDebounce }
    func setExternalDisplay(_ on: Bool) { if on != externalDisplay { externalDisplay = on; displayChangedAt = now() } }

    init(io: SMCIO, settings: ChargeSettings = ChargeSettings()) {
        self.io = io; self.settings = settings; caps = ChargeCaps.detect(io)
    }
    var lower: Int { settings.limit - max(settings.sail, 1) }

    var status: ChargeStatus {
        ChargeStatus(settings: settings, caps: caps, topUp: topUp, inhibited: inhibited, adapterCut: adapterCut, level: level, plugged: plugged, lastError: lastError, ledWritable: ledWritable, externalDisplay: externalDisplay, displayPaused: displayPaused)
    }

    func setTopUp(_ on: Bool) { if topUp && !on { forceNextCut = true }; topUp = on }

    // 原子写入；失败时记录错误
    @discardableResult private func setInhibit(_ on: Bool, force: Bool = false) -> Bool {
        if !force && inhibited == on { return true }
        let ok: Bool
        switch caps.inhibit {
        case .none: inhibited = false; return !on
        case .chte: ok = io.write("CHTE", on ? [1, 0, 0, 0] : [0, 0, 0, 0])
        case .ch0bc: ok = io.write("CH0B", [on ? 2 : 0]) && io.write("CH0C", [on ? 2 : 0])
        }
        if ok { inhibited = on; lastError = ""; if on { heldAtLimit = settings.limit } } else { lastError = "写入停充键失败" }
        return ok
    }
    @discardableResult private func setAdapter(cut: Bool, force: Bool = false) -> Bool {
        if !force && adapterCut == cut && caps.adapter { return true }
        guard caps.adapter else { adapterCut = false; return !cut }
        if cut {
            if displayPaused { return false }     // 外接屏：切电会让显示器掉线
            let forced = force || forceNextCut
            if !forced, now().timeIntervalSince(lastCutAt) < ChargeConst.adapterHold {
                return adapterCut == cut
            }
        }
        let ok = io.write("CHIE", [cut ? 0x08 : 0x00])
        if ok {
            adapterCut = cut
            if cut { lastCutAt = now(); forceNextCut = false; heldAtLimit = settings.limit }
        } else { lastError = "写入 CHIE 失败" }
        return ok
    }
    private func setLED(_ v: UInt8) {
        guard caps.led, led != v else { return }
        let ok = io.write("ACLC", [v]); ledWritable = ok
        led = ok ? v : nil
    }

    /// 恢复系统默认：允许充电、接通电源、灯交给系统。总是对两个键都写一次（不信任缓存状态）
    func release() {
        if caps.inhibit != .none, !setInhibit(false, force: true) { setInhibit(false, force: true) }
        if caps.adapter, !setAdapter(cut: false, force: true) { setAdapter(cut: false, force: true) }
        if caps.led { led = nil; setLED(ChargeConst.ledSystem) }
    }
    func resetDefaults() { settings = ChargeSettings(); topUp = false; release() }

    /// 根据电量/电源状态决定动作。level == nil（读取失败）一律恢复默认
    func evaluate(level lv: Int?, plugged pl: Bool, charging: Bool = false) {
        level = lv
        // 拔掉电源（且不是我们断开的）→ 结束临时充满
        if !pl && !adapterCut { if topUp { topUp = false } }
        plugged = pl || adapterCut
        guard let l = lv else { release(); lastError = "读不到电量，已恢复默认"; return }
        if topUp && l >= 100 { topUp = false; forceNextCut = true }
        guard settings.enabled, caps.any, !topUp, settings.limit < 100, l > ChargeConst.hardFloor else {
            if inhibited || adapterCut { release() }
            if caps.led { setLED(settings.enabled && settings.led && topUp && pl ? ChargeConst.ledOrange : ChargeConst.ledSystem) }
            return
        }
        let lim = settings.limit
        // 上限调高到当前电量之上：立即恢复，不用等降到下沿
        if l < lim && lim > heldAtLimit {
            if adapterCut { setAdapter(cut: false) }
            if inhibited { setInhibit(false) }
        }
        let paused = displayPaused
        if paused && adapterCut { setAdapter(cut: false, force: true); forceNextCut = true }
        if caps.adapterMode && paused {
            // 接着外接屏：暂停上限，正常充电
        } else if caps.adapterMode {
            // 只有断电源这一种手段：到上限断开，降到下沿恢复
            if l >= lim { setAdapter(cut: true) } else if l <= lower { setAdapter(cut: false) }
            if adapterCut && l <= lower { setAdapter(cut: false) }
        } else {
            if l >= lim { setInhibit(true) } else if l <= lower { setInhibit(false) }
            if caps.adapter {
                if settings.autoDischarge && l > lim && !paused { setAdapter(cut: true) }
                else if adapterCut && (l <= lim || !settings.autoDischarge || paused) { setAdapter(cut: false) }
            }
        }
        // 兜底：低于下沿时绝不保持停充/断电
        if l <= lower { if inhibited { setInhibit(false) }; if adapterCut { setAdapter(cut: false) } }
        if settings.led && caps.led {
            if inhibited || adapterCut { setLED(ChargeConst.ledGreen) } else if plugged { setLED(ChargeConst.ledOrange) } else { setLED(ChargeConst.ledSystem) }
        } else if caps.led { setLED(ChargeConst.ledSystem) }
    }

    /// 睡眠前：断电源模式下恢复供电，避免睡眠期间一直耗电
    func willSleep() { if adapterCut { setAdapter(cut: false, force: true); forceNextCut = true } }
}

// MARK: - XPC 白名单协议（只有这些方法，没有任意命令）
@objc(MOChargeHelperProtocol) protocol ChargeHelperProtocol {
    func status(_ reply: @escaping (Data) -> Void)
    func setLimit(_ limit: Int, enabled: Bool, reply: @escaping (Bool, String) -> Void)
    func setSailing(_ range: Int, reply: @escaping (Bool, String) -> Void)
    func setAutoDischarge(_ on: Bool, reply: @escaping (Bool, String) -> Void)
    func setTopUp(_ on: Bool, reply: @escaping (Bool, String) -> Void)
    func setLED(_ on: Bool, reply: @escaping (Bool, String) -> Void)
    func resetDefaults(_ reply: @escaping (Bool, String) -> Void)
}

enum ChargeValidate {
    static func limit(_ v: Int) -> Bool { ChargeConst.limitRange.contains(v) }
    static func sail(_ v: Int) -> Bool { ChargeConst.sailRange.contains(v) }
    static let allowedSelectors: Set<String> = ["status:", "setLimit:enabled:reply:", "setSailing:reply:", "setAutoDischarge:reply:", "setTopUp:reply:", "setLED:reply:", "resetDefaults:"]
}

/// 助手里的服务对象：所有调用转到主线程，参数严格校验后才改设置
final class ChargeService: NSObject, NSXPCListenerDelegate, ChargeHelperProtocol {
    let ctl: ChargeController
    var requirement: String? = ChargeConst.clientRequirement
    var reader: () -> (level: Int?, plugged: Bool, charging: Bool)
    var persist: (ChargeSettings) -> Void
    /// 外接显示器检测（助手里用 IOKit；测试用模拟）
    var display: () -> Bool = { false }
    init(ctl: ChargeController, reader: @escaping () -> (level: Int?, plugged: Bool, charging: Bool), persist: @escaping (ChargeSettings) -> Void) {
        self.ctl = ctl; self.reader = reader; self.persist = persist
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        guard let req = requirement else { return false }      // 没有要求就拒绝
        if #available(macOS 13.0, *) { c.setCodeSigningRequirement(req) } else { return false }
        c.exportedInterface = NSXPCInterface(with: ChargeHelperProtocol.self)
        c.exportedObject = self
        c.resume(); return true
    }
    func tick() { ctl.setExternalDisplay(display()); let r = reader(); ctl.evaluate(level: r.level, plugged: r.plugged, charging: r.charging) }
    private func onMain<T>(_ f: () -> T) -> T { Thread.isMainThread ? f() : DispatchQueue.main.sync(execute: f) }
    private func change(_ ok: Bool, _ why: String, _ reply: (Bool, String) -> Void, _ f: () -> Void) {
        guard ok else { reply(false, why); return }
        onMain { f(); persist(ctl.settings); tick() }
        reply(true, "")
    }
    func status(_ reply: @escaping (Data) -> Void) { let s = onMain { ctl.status }; reply((try? JSONEncoder().encode(s)) ?? Data()) }
    func setLimit(_ limit: Int, enabled: Bool, reply: @escaping (Bool, String) -> Void) {
        change(ChargeValidate.limit(limit), "上限超出 50–100", reply) { ctl.settings.limit = limit; ctl.settings.enabled = enabled; if !enabled { ctl.setTopUp(false); ctl.release() } }
    }
    func setSailing(_ range: Int, reply: @escaping (Bool, String) -> Void) { change(ChargeValidate.sail(range), "航行范围超出 0–10", reply) { ctl.settings.sail = range } }
    func setAutoDischarge(_ on: Bool, reply: @escaping (Bool, String) -> Void) { change(true, "", reply) { ctl.settings.autoDischarge = on } }
    func setTopUp(_ on: Bool, reply: @escaping (Bool, String) -> Void) { change(true, "", reply) { ctl.setTopUp(on) } }
    func setLED(_ on: Bool, reply: @escaping (Bool, String) -> Void) { change(true, "", reply) { ctl.settings.led = on } }
    func resetDefaults(_ reply: @escaping (Bool, String) -> Void) { onMain { ctl.resetDefaults(); persist(ctl.settings) }; reply(true, "") }
}

// MARK: - 电池读数（IORegistry，只读）
enum BatteryReading {
    static func read() -> (level: Int?, plugged: Bool, charging: Bool) {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return (nil, false, false) }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS, let d = props?.takeRetainedValue() as? [String: Any] else { return (nil, false, false) }
        var lv: Int? = nil
        if let c = d["CurrentCapacity"] as? Int, let m = d["MaxCapacity"] as? Int, m > 0 { lv = m == 100 ? c : Int((Double(c) / Double(m) * 100).rounded()) }
        if let ui = d["UISoc"] as? Int { lv = ui }
        let plugged = (d["ExternalConnected"] as? Bool) ?? false
        return (lv.map { min(100, max(0, $0)) }, plugged, (d["IsCharging"] as? Bool) ?? false)
    }
}

// MARK: - 外接显示器检测（IORegistry，root 守护进程可用，不依赖 WindowServer）
/// Apple 芯片：每接一台外接屏，系统会为对应 DCP 创建一个 Location = "External" 的 DCPAVServiceProxy，拔掉即移除。
/// Intel：IODisplayConnect 多于 1 个（内建屏之外）视为接了外接屏。
enum DisplayProbe {
    static let classes = ["DCPAVServiceProxy", "IODisplayConnect"]
    static func externalCount() -> Int {
        var n = 0, intel = 0
        for cls in classes {
            var it: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { continue }
            while case let o = IOIteratorNext(it), o != 0 {
                if cls == "DCPAVServiceProxy" {
                    if let loc = IORegistryEntryCreateCFProperty(o, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String, loc == "External" { n += 1 }
                } else { intel += 1 }
                IOObjectRelease(o)
            }
            IOObjectRelease(it)
        }
        return n + max(0, intel - 1)
    }
}
