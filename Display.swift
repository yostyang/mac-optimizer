// 显示器：分辨率/刷新率、DDC/CI 硬件调节、软件调光与色温（Gamma）、场景与定时、亮屏时间
import Foundation
import AppKit
import CoreGraphics
import IOKit

// MARK: - 显示模式
struct DMode: Hashable {
    var width: Int; var height: Int; var pixelWidth: Int; var pixelHeight: Int; var refresh: Double
    var hidpi: Bool { pixelWidth > width }
    var label: String { "\(width)×\(height)" }
    var refreshLabel: String { refresh > 0 ? "\(Int(refresh.rounded())) Hz" : "默认" }
}
struct DisplayInfo: Identifiable, Equatable {
    var id: CGDirectDisplayID
    var name: String
    var builtin: Bool
    var current: DMode
    var modes: [DMode]
    var uuid = ""
    var serial: UInt32 = 0
    var vendor: UInt32 = 0
    var model: UInt32 = 0
    var key: String { uuid.isEmpty ? "session-\(id)" : uuid }
    static func == (a: DisplayInfo, b: DisplayInfo) -> Bool { a.id == b.id && a.current == b.current && a.name == b.name && a.modes.count == b.modes.count }
    /// 当前 HiDPI/非 HiDPI 下可选的分辨率（去重、从大到小，最多 8 个，保证一屏放得下）
    func resolutions(hidpi: Bool) -> [DMode] {
        var seen = Set<String>(); var out: [DMode] = []
        for m in modes.sorted(by: { $0.width * $0.height > $1.width * $1.height }) where m.hidpi == hidpi {
            let k = m.label; if seen.insert(k).inserted { out.append(m) }
        }
        if !out.contains(where: { $0.label == current.label }), current.hidpi == hidpi { out.insert(current, at: 0) }
        return Array(out.prefix(8))
    }
    func refreshRates(for m: DMode) -> [Double] {
        Array(Set(modes.filter { $0.width == m.width && $0.height == m.height && $0.hidpi == m.hidpi }.map { $0.refresh.rounded() })).sorted(by: >)
    }
    var hasHiDPIChoice: Bool { modes.contains { $0.hidpi } && modes.contains { !$0.hidpi } }
}

/// 读取/切换显示模式（测试用模拟）
protocol DisplaySystem: AnyObject {
    func displays() -> [DisplayInfo]
    func apply(_ m: DMode, to id: CGDirectDisplayID) -> Bool
}
final class RealDisplaySystem: DisplaySystem {
    private var raw: [CGDirectDisplayID: [CGDisplayMode]] = [:]
    func displays() -> [DisplayInfo] {
        var n: UInt32 = 0; CGGetActiveDisplayList(0, nil, &n)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n)); CGGetActiveDisplayList(n, &ids, &n)
        return ids.compactMap { id in
            guard let cur = CGDisplayCopyDisplayMode(id) else { return nil }
            let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            let all = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] ?? []).filter { $0.isUsableForDesktopGUI() }
            raw[id] = all
            let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?.localizedName ?? (CGDisplayIsBuiltin(id) != 0 ? "内建显示器" : "外接显示器")
            return DisplayInfo(id: id, name: name, builtin: CGDisplayIsBuiltin(id) != 0, current: Self.m(cur), modes: all.map(Self.m), uuid: CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "", serial: CGDisplaySerialNumber(id), vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id))
        }
    }
    static func m(_ c: CGDisplayMode) -> DMode { DMode(width: c.width, height: c.height, pixelWidth: c.pixelWidth, pixelHeight: c.pixelHeight, refresh: c.refreshRate) }
    func apply(_ m: DMode, to id: CGDirectDisplayID) -> Bool {
        guard let target = raw[id]?.first(where: { Self.m($0) == m }) else { return false }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(cfg, id, target, nil)
        return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
    }
}

// MARK: - DDC/CI（Apple 芯片：IOAVService；按需读写，不轮询）
enum VCP: UInt8 { case brightness = 0x10, contrast = 0x12, volume = 0x62, input = 0x60, colorPreset = 0x14, displayMode = 0xDC }
struct DDCCaps: Equatable {
    var vcps: Set<UInt8> = []
    var inputs: [UInt8] = []
    var model = ""
    var values: [UInt8: [UInt8]] = [:]
    /// 解析能力字符串，例如 vcp(02 10 12 60( 11 0F 10) ...)
    static func parse(_ s: String) -> DDCCaps {
        var c = DDCCaps()
        if let r = s.range(of: "model(") { c.model = String(s[r.upperBound...].prefix { $0 != ")" }) }
        guard let r = s.range(of: "vcp(") else { return c }
        var depth = 1, i = r.upperBound, tok = "", cur: UInt8? = nil
        var sub: [UInt8: [UInt8]] = [:]
        func flush() { if let v = UInt8(tok, radix: 16) { if depth == 1 { c.vcps.insert(v); cur = v } else if depth == 2, let k = cur { sub[k, default: []].append(v) } }; tok = "" }
        while i < s.endIndex, depth > 0 {
            let ch = s[i]
            if ch == "(" { flush(); depth += 1 } else if ch == ")" { flush(); depth -= 1 } else if ch.isWhitespace { flush() } else { tok.append(ch) }
            i = s.index(after: i)
        }
        c.values = sub
        c.inputs = sub[VCP.input.rawValue] ?? []
        return c
    }
    static func colorName(_ value: UInt8) -> String {
        switch value {
        case 1: return "sRGB"; case 2: return "原生色彩"
        case 3: return "4000 K"; case 4: return "5000 K"; case 5: return "6500 K"; case 6: return "7500 K"
        case 7: return "8200 K"; case 8: return "9300 K"; case 9: return "10000 K"; case 10: return "11500 K"
        case 11: return "用户预设 1"; case 12: return "用户预设 2"; case 13: return "用户预设 3"
        default: return String(format: "预设 0x%02X", value)
        }
    }
    static func inputName(_ v: UInt8) -> String {
        switch v { case 0x01, 0x02: return "VGA"; case 0x03, 0x04: return "DVI"; case 0x0F: return "DP 1 / USB-C"; case 0x10: return "DP 2"; case 0x11: return "HDMI 1"; case 0x12: return "HDMI 2"; case 0x1B: return "USB-C"; default: return String(format: "输入 0x%02X", v) }
    }
}
protocol DDCChannel: AnyObject {
    func read(_ code: UInt8) -> (value: Int, max: Int)?
    func write(_ code: UInt8, _ value: Int) -> Bool
    func capabilities() -> String
}
final class AVServiceDDC: DDCChannel {
    typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias CopyEDID = @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn
    typealias RW = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private static let h = dlopen(nil, RTLD_NOW)
    private static let createF = dlsym(h, "IOAVServiceCreateWithService").map { unsafeBitCast($0, to: Create.self) }
    private static let copyEDID = dlsym(h, "IOAVServiceCopyEDID").map { unsafeBitCast($0, to: CopyEDID.self) }
    private static let readF = dlsym(h, "IOAVServiceReadI2C").map { unsafeBitCast($0, to: RW.self) }
    private static let writeF = dlsym(h, "IOAVServiceWriteI2C").map { unsafeBitCast($0, to: RW.self) }
    let svc: CFTypeRef
    private let lock = NSLock()
    var productName = ""
    var displayUUID = ""
    var vendor: UInt32 = 0
    var model: UInt32 = 0
    var serial: UInt32 = 0
    init(_ s: CFTypeRef) { svc = s }
    static func identity(_ entry: io_service_t, channel: AVServiceDDC) {
        guard let copy = copyEDID else { return }
        var raw: Unmanaged<CFData>?
        guard copy(channel.svc, &raw) == 0, let data = raw?.takeRetainedValue() as Data?, data.count >= 128 else { return }
        let bytes = Array(data)
        guard Array(bytes.prefix(8)) == [0, 255, 255, 255, 255, 255, 255, 0], bytes.prefix(128).reduce(UInt8(0), &+) == 0 else { return }
        channel.vendor = UInt32(bytes[8]) << 8 | UInt32(bytes[9])
        channel.model = UInt32(bytes[10]) | UInt32(bytes[11]) << 8
        channel.serial = UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24
        for offset in stride(from: 54, through: 108, by: 18) where bytes[offset] == 0 && bytes[offset + 1] == 0 && bytes[offset + 3] == 0xFC {
            channel.productName = String(decoding: bytes[(offset + 5)..<(offset + 18)], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    /// 外接屏的 AV 服务（Apple 芯片），按 IORegistry 顺序
    static func externals() -> [AVServiceDDC] {
        guard let create = createF, readF != nil, writeF != nil else { return [] }
        var it: io_iterator_t = 0; var out: [AVServiceDDC] = []
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it) == KERN_SUCCESS else { return [] }
        while case let o = IOIteratorNext(it), o != 0 {
            if (IORegistryEntryCreateCFProperty(o, "Location" as CFString, nil, 0)?.takeRetainedValue() as? String) == "External", let s = create(nil, o)?.takeRetainedValue() { let channel = AVServiceDDC(s); identity(o, channel: channel); out.append(channel) }
            IOObjectRelease(o)
        }
        IOObjectRelease(it); return out
    }
    // 有的显示器空闲后会丢第一包：每包发两次
    private func send(_ payload: [UInt8]) -> Bool {
        var pk = [0x80 | UInt8(payload.count)] + payload
        var sum: UInt8 = 0x6E ^ 0x51; for b in pk { sum ^= b }; pk.append(sum)
        var ok = false
        for _ in 0..<2 { usleep(10_000); if Self.writeF!(svc, 0x37, 0x51, &pk, UInt32(pk.count)) == 0 { ok = true } }
        return ok
    }
    private func receive(_ n: Int) -> [UInt8]? {
        usleep(50_000)
        var b = [UInt8](repeating: 0, count: n)
        guard Self.readF!(svc, 0x37, 0x51, &b, UInt32(n)) == 0 else { return nil }
        let len = Int(b[1] & 0x7F); guard len >= 1, len + 2 < n else { return nil }
        var sum: UInt8 = 0x50; for x in b[..<(2 + len)] { sum ^= x }
        return sum == b[2 + len] ? b : nil
    }
    func read(_ code: UInt8) -> (value: Int, max: Int)? {
        lock.lock(); defer { lock.unlock() }
        for _ in 0..<3 {
            if send([0x01, code]), let r = receive(11), r[2] == 0x02, r[4] == code {
                if r[3] != 0 { return nil }
                return (Int(r[8]) << 8 | Int(r[9]), Int(r[6]) << 8 | Int(r[7]))
            }
            usleep(20_000)
        }
        return nil
    }
    func write(_ code: UInt8, _ value: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return send([0x03, code, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]) }
    func capabilities() -> String {
        lock.lock(); defer { lock.unlock() }
        var caps: [UInt8] = []
        while caps.count < 2048 {
            let off = caps.count
            guard send([0xF3, UInt8(off >> 8), UInt8(off & 0xFF)]), let r = receive(38), r[2] == 0xE3 else { break }
            let end = 2 + Int(r[1] & 0x7F); if end <= 5 { break }
            let chunk = Array(r[5..<end]); caps += chunk
            if chunk.contains(0) { break }
        }
        return String(decoding: caps.filter { $0 != 0 }, as: UTF8.self)
    }
}

struct DDCState: Equatable {
    var available = false
    var caps = DDCCaps()
    var brightness: Int?; var brightnessMax = 100
    var contrast: Int?; var contrastMax = 100
    var volume: Int?; var volumeMax = 100
    var input: UInt8?
    var colorPreset: Int?
    var displayMode: Int?
    func value(_ code: VCP) -> Int? {
        switch code { case .brightness: return brightness; case .contrast: return contrast; case .volume: return volume; case .input: return input.map(Int.init); case .colorPreset: return colorPreset; case .displayMode: return displayMode }
    }
    mutating func set(_ code: VCP, _ value: Int?) {
        switch code { case .brightness: brightness = value; case .contrast: contrast = value; case .volume: volume = value; case .input: input = value.flatMap(UInt8.init(exactly:)); case .colorPreset: colorPreset = value; case .displayMode: displayMode = value }
    }
}

// MARK: - 软件调光与色温（Gamma 表）
enum ColorTemp {
    /// 色温 → RGB 系数（以 6500K 为 1，近似黑体曲线）
    static func rgb(_ k: Double) -> (Double, Double, Double) {
        let t = max(1900, min(6500, k)) / 100
        func clamp(_ v: Double) -> Double { max(0, min(255, v)) / 255 }
        let r = t <= 66 ? 1.0 : clamp(329.698727446 * pow(t - 60, -0.1332047592))
        let g = t <= 66 ? clamp(99.4708025861 * log(t) - 161.1195681661) : clamp(288.1221695283 * pow(t - 60, -0.0755148492))
        let b = t >= 66 ? 1.0 : (t <= 19 ? 0 : clamp(138.5177312231 * log(t - 10) - 305.0447927307))
        let w = (1.0, clamp(99.4708025861 * log(65) - 161.1195681661), clamp(138.5177312231 * log(55) - 305.0447927307))
        return (min(1, r / w.0), min(1, g / w.1), min(1, b / w.2))
    }
}
protocol GammaSystem: AnyObject {
    func set(_ id: CGDirectDisplayID, r: Double, g: Double, b: Double) -> Bool
    func restore()
    func restore(_ id: CGDirectDisplayID) -> Bool
    func forget(_ id: CGDirectDisplayID)
}
extension GammaSystem { func forget(_ id: CGDirectDisplayID) {} }
final class RealGamma: GammaSystem {
    struct Table { var r: [CGGammaValue]; var g: [CGGammaValue]; var b: [CGGammaValue]; var count: UInt32 }
    private var originals: [CGDirectDisplayID: Table] = [:]
    func set(_ id: CGDirectDisplayID, r: Double, g: Double, b: Double) -> Bool {
        if originals[id] == nil {
            var R = [CGGammaValue](repeating: 0, count: 4096), G = R, B = R; var count: UInt32 = 0
            guard CGGetDisplayTransferByTable(id, 4096, &R, &G, &B, &count) == .success, count > 0 else { return false }
            originals[id] = Table(r: Array(R.prefix(Int(count))), g: Array(G.prefix(Int(count))), b: Array(B.prefix(Int(count))), count: count)
        }
        guard let base = originals[id] else { return false }
        var R = base.r.map { $0 * Float(r) }, G = base.g.map { $0 * Float(g) }, B = base.b.map { $0 * Float(b) }
        return CGSetDisplayTransferByTable(id, base.count, &R, &G, &B) == .success
    }
    func restore(_ id: CGDirectDisplayID) -> Bool {
        guard var table = originals[id] else { return true }
        guard CGSetDisplayTransferByTable(id, table.count, &table.r, &table.g, &table.b) == .success else { return false }
        originals.removeValue(forKey: id); return true
    }
    func restore() { for id in Array(originals.keys) { _ = restore(id) } }
    func forget(_ id: CGDirectDisplayID) { originals.removeValue(forKey: id) }
}

struct DScene: Identifiable, Equatable {
    let id: String; let name: String; let icon: String; let dim: Double; let kelvin: Double; let ddcBrightness: Int
    static let all = [
        DScene(id: "day", name: "日间", icon: "sun.max", dim: 1.0, kelvin: 6500, ddcBrightness: 80),
        DScene(id: "read", name: "阅读", icon: "book", dim: 0.92, kelvin: 5200, ddcBrightness: 60),
        DScene(id: "movie", name: "观影", icon: "film", dim: 1.0, kelvin: 6200, ddcBrightness: 90),
        DScene(id: "night", name: "夜间", icon: "moon.stars", dim: 0.75, kelvin: 3600, ddcBrightness: 30),
    ]
}

struct DisplaySettings: Codable, Equatable {
    var gammaOn = false           // 软件调光/色温：默认关闭（避免与 MonitorBar 等工具冲突）
    var dim = 1.0                 // 0.3 ... 1
    var kelvin = 6500.0           // 2700 ... 6500
    var scene = ""
    var autoSwitch = false        // 按时间自动切换日间/夜间
    var dayStart = 7 * 60, nightStart = 22 * 60    // 分钟
    var sceneDDC = true           // 场景同时调硬件亮度（显示器支持时）
    static let key = "display.settings"
    static func load(_ d: UserDefaults = .standard) -> DisplaySettings { d.data(forKey: key).flatMap { try? JSONDecoder().decode(DisplaySettings.self, from: $0) } ?? DisplaySettings() }
    func save(_ d: UserDefaults = .standard) { d.set(try? JSONEncoder().encode(self), forKey: Self.key) }
    /// 某一时刻（当天分钟数）应处于的场景
    func scheduled(minute m: Int) -> String {
        let inDay = dayStart <= nightStart ? (m >= dayStart && m < nightStart) : !(m >= nightStart && m < dayStart)
        return inDay ? "day" : "night"
    }
    /// 距下一个切换点的秒数（只在切换点触发一次，不轮询）
    func secondsToNextSwitch(from d: Date, cal: Calendar = .current) -> TimeInterval {
        let c = cal.dateComponents([.hour, .minute, .second], from: d)
        let now = Double((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0))
        let pts = [Double(dayStart * 60), Double(nightStart * 60)].map { $0 > now ? $0 - now : $0 + 86400 - now }
        return max(1, pts.min() ?? 3600)
    }
}

// MARK: - 亮屏时间（事件驱动：屏幕睡眠/唤醒、锁屏/解锁时记账，不轮询）
struct UsageStore: Codable, Equatable {
    var days: [String: Double] = [:]      // yyyy-MM-dd → 秒
    static func dayKey(_ d: Date, _ cal: Calendar = .current) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d); return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    /// 记一段亮屏时间，跨午夜时拆到两天
    mutating func add(from a: Date, to b: Date, cal: Calendar = .current) {
        guard b > a else { return }
        var s = a
        while s < b {
            let next = cal.startOfDay(for: s).addingTimeInterval(86400 + 1).addingTimeInterval(-1)
            let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: s)) ?? next
            let e = min(b, midnight)
            days[Self.dayKey(s, cal), default: 0] += e.timeIntervalSince(s)
            s = e
        }
    }
    mutating func prune(now: Date, keep: Int = 14, cal: Calendar = .current) {
        let keys = Set((0..<keep).map { Self.dayKey(cal.date(byAdding: .day, value: -$0, to: now)!, cal) })
        days = days.filter { keys.contains($0.key) }
    }
    func last7(now: Date, cal: Calendar = .current) -> [(String, Double)] {
        (0..<7).reversed().map { i in let d = cal.date(byAdding: .day, value: -i, to: now)!; let k = Self.dayKey(d, cal)
            let wd = ["日", "一", "二", "三", "四", "五", "六"][cal.component(.weekday, from: d) - 1]
            return (i == 0 ? "今天" : "周" + wd, days[k] ?? 0) }
    }
}
final class ScreenTime: ObservableObject {
    static let shared = ScreenTime()
    @Published private(set) var store = UsageStore()
    private var since: Date?
    private var obs: [NSObjectProtocol] = []
    private var flushTimer: Timer?
    var fileURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacOptimizer/screentime.json")
    var now: () -> Date = Date.init
    init() {}
    func start() {
        store = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(UsageStore.self, from: $0) } ?? UsageStore()
        since = now()
        let ws = NSWorkspace.shared.notificationCenter
        let off: [Notification.Name] = [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification]
        let on: [Notification.Name] = [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification]
        for n in off { obs.append(ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.pause() }) }
        for n in on { obs.append(ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.resume() }) }
        for n in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            obs.append(DistributedNotificationCenter.default().addObserver(forName: .init(n), object: nil, queue: .main) { [weak self] _ in n.hasSuffix("Locked") ? self?.pause() : self?.resume() })
        }
        // 每 10 分钟落盘一次（防止异常退出丢数据），容差大，几乎不唤醒 CPU
        let t = Timer(timeInterval: 600, repeats: true) { [weak self] _ in self?.checkpoint() }; t.tolerance = 120
        RunLoop.main.add(t, forMode: .common); flushTimer = t
    }
    func stop() { checkpoint(); obs.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); DistributedNotificationCenter.default().removeObserver($0) }; obs = []; flushTimer?.invalidate() }
    func pause() { if let s = since { store.add(from: s, to: now()) }; since = nil; save() }
    func resume() { if since == nil { since = now() } }
    func checkpoint() { if let s = since { let n = now(); store.add(from: s, to: n); since = n }; save() }
    private func save() {
        store.prune(now: now())
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(store).write(to: fileURL, options: .atomic)
    }
    /// 今天（含正在进行的这一段）
    var today: Double { var s = store; if let a = since { s.add(from: a, to: now()) }; return s.days[UsageStore.dayKey(now())] ?? 0 }
    var week: [(String, Double)] { var s = store; if let a = since { s.add(from: a, to: now()) }; return s.last7(now: now()) }
    func inject(_ s: UsageStore, now n: Date) { store = s; since = nil; now = { n } }
}

// MARK: - 管理器
final class DisplayManager: ObservableObject {
    static var shared = DisplayManager()
    @Published var displays: [DisplayInfo] = []
    @Published var ddc: [CGDirectDisplayID: DDCState] = [:]
    @Published var selectedID: CGDirectDisplayID = 0
    @Published var settings = DisplaySettings() { didSet { saveSettings() } }
    @Published var pending: (id: CGDirectDisplayID, old: DMode, until: Date)?
    @Published var conflict = ""
    @Published var probing = false
    @Published var gammaNotes: [CGDirectDisplayID: String] = [:]
    @Published var ddcNotes: [CGDirectDisplayID: String] = [:]
    /// 2.8：最近一次硬件写入（失败后「重试」用）
    var lastDDCAttempt: [CGDirectDisplayID: (code: VCP, value: Int)] = [:]
    @Published var profileStates: [CGDirectDisplayID: DisplayProfileState] = [:]
    @Published var profileNotes: [CGDirectDisplayID: String] = [:]
    @Published var profilesLoading = false
    @Published var profileBusy: Set<CGDirectDisplayID> = []
    @Published private(set) var ddcPending: [DDCOperationKey: Int] = [:]
    @Published private(set) var originalDDC: [String: [UInt8: Int]] = [:]
    @Published private(set) var originalProfiles: [String: DisplayProfileState] = [:]
    var sys: DisplaySystem
    var gamma: GammaSystem
    var profileSystem: DisplayProfileSystem = ColorSyncProfiles()
    var channels: (DisplayInfo) -> DDCChannel? = { _ in nil }
    var offline = false
    private var realChannels: [CGDirectDisplayID: AVServiceDDC] = [:]
    private var saved: [String: DisplaySettings] = [:]
    private var loadingSettings = false
    private var legacy = DisplaySettings.load()
    private var selectedKey = ""
    private var epoch = UUID()
    private var probeToken = UUID()
    private var profileTokens: [CGDirectDisplayID: UUID] = [:]
    private var ddcTokens: [DDCOperationKey: UUID] = [:]
    private var ddcWork: [DDCOperationKey: DispatchWorkItem] = [:]
    private let ddcQueue = DispatchQueue(label: "display.ddc.operations", qos: .userInitiated)
    private let profileQueue = DispatchQueue(label: "display.profiles", qos: .utility)
    private var revertWork: DispatchWorkItem?
    private var schedTimer: Timer?
    private var reconfigRegistered = false
    static let settingsKey = "display.per-device.v23"
    init(sys: DisplaySystem = RealDisplaySystem(), gamma: GammaSystem = RealGamma()) {
        self.sys = sys; self.gamma = gamma
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey), let values = try? JSONDecoder().decode([String: DisplaySettings].self, from: data) { saved = values }
        channels = { [weak self] d in self?.realChannels[d.id] }
    }
    private func saveSettings() {
        guard !loadingSettings, let display = displays.first(where: { $0.id == selectedID }) else { return }
        saved[display.key] = settings
        guard !offline, let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }
    func select(_ id: CGDirectDisplayID) {
        guard let display = displays.first(where: { $0.id == id }) else { return }
        guard selectedID != id || selectedKey != display.key else { return }
        let initial = selectedID == 0 ? settings : DisplaySettings()
        selectedID = id; selectedKey = display.key
        loadingSettings = true; settings = saved[display.key] ?? initial; loadingSettings = false
    }
    static let gammaApps = ["MonitorBar", "Lunar", "f.lux", "BetterDisplay", "Flux", "Iris"]
    func detectConflict() {
        conflict = NSWorkspace.shared.runningApplications.compactMap { $0.localizedName }.first { n in Self.gammaApps.contains { n.localizedCaseInsensitiveContains($0) } } ?? ""
    }
    func refresh() {
        epoch = UUID(); probeToken = UUID(); probing = false
        for key in ddcPending.keys { ddcNotes[key.display] = "显示配置已变化，请刷新核对" }
        ddcWork.values.forEach { $0.cancel() }; ddcWork = [:]; ddcTokens = [:]; ddcPending = [:]
        let previous = displays
        displays = sys.displays()
        for old in previous where !displays.contains(where: { $0.id == old.id && $0.key == old.key }) { gamma.forget(old.id) }
        ddc = ddc.filter { id, _ in displays.contains { display in display.id == id && previous.contains { $0.id == id && $0.key == display.key } } }
        for id in profileBusy { profileNotes[id] = "显示配置已变化，请核对刷新后的描述文件" }
        profileBusy = []; profileTokens = [:]
        if !offline {
            let services = AVServiceDDC.externals()
            realChannels = [:]
            for display in displays where !display.builtin { realChannels[display.id] = DDCIdentity.match(display, in: services, displays: displays) }
            if saved.isEmpty, let first = displays.first(where: { !$0.builtin }) { saved[first.key] = legacy }
        }
        if let match = displays.first(where: { $0.key == selectedKey }) ?? displays.first(where: { !$0.builtin }) ?? displays.first { select(match.id) }
        detectConflict()
        if !offline { refreshProfiles() }
        if !reconfigRegistered && !offline {
            reconfigRegistered = true
            CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
                guard !flags.contains(.beginConfigurationFlag) else { return }
                DispatchQueue.main.async {
                    DisplayManager.shared.refresh()
                    DisplayManager.shared.applyAllGamma()
                    DisplayManager.shared.scheduleAuto()
                }
            }, nil)
        }
    }
    func refreshProfiles() {
        let snapshot = displays, system = profileSystem, revision = epoch
        profilesLoading = true
        profileQueue.async {
            let states = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, system.read($0.id)) })
            DispatchQueue.main.async { guard self.epoch == revision else { return }; self.profileStates = states; self.profilesLoading = false }
        }
    }
    func setProfile(_ id: CGDirectDisplayID, url: URL?, restoring: Bool = false) {
        guard let display = displays.first(where: { $0.id == id }), !profileBusy.contains(id),
              let old = profileStates[id], old.current != nil else { return }
        if let url, !restoring && !old.choices.contains(where: { DisplayProfile.sameURL($0.url, url) }) { return }
        let revision = epoch, system = profileSystem, token = UUID()
        let expected = url ?? (restoring ? originalProfiles[display.key]?.current : old.factoryDefault)
        profileTokens[id] = token
        if originalProfiles[display.key] == nil { originalProfiles[display.key] = old }
        profileBusy.insert(id); profileNotes[id] = "正在切换并核对…"
        guard gamma.restore(id) else {
            profileBusy.remove(id); profileTokens.removeValue(forKey: id)
            profileNotes[id] = "未能恢复当前软件色温，未切换ICC；请重试关闭软件调光"
            return
        }
        profileQueue.async {
            let stillConnected = DispatchQueue.main.sync { self.epoch == revision && self.displays.contains { $0.id == id && $0.key == display.key } }
            guard stillConnected else { return }
            let ok = system.apply(id, url: url)
            var actual = system.read(id)
            for _ in 0..<8 where ok && !DisplayProfile.sameURL(actual.current, expected) { usleep(100_000); actual = system.read(id) }
            let verified = ok && DisplayProfile.sameURL(actual.current, expected)
            DispatchQueue.main.async {
                guard self.epoch == revision, self.profileTokens[id] == token else { return }
                self.profileTokens.removeValue(forKey: id)
                self.profileStates[id] = actual; self.profileBusy.remove(id)
                self.profileNotes[id] = verified ? "已核对色彩描述文件" : "未确认切换成功，请刷新或恢复原描述文件"
                self.applyGamma(id)
                if verified && restoring { self.originalProfiles.removeValue(forKey: display.key) }
            }
        }
    }
    func restoreProfile(_ id: CGDirectDisplayID) {
        guard let display = displays.first(where: { $0.id == id }), let old = originalProfiles[display.key] else { return }
        setProfile(id, url: DisplayProfile.sameURL(old.current, old.factoryDefault) ? nil : old.current, restoring: true)
    }
    func probeDDC(done: (() -> Void)? = nil) {
        guard !probing else { done?(); return }
        let pairs = displays.filter { !$0.builtin }.compactMap { display -> (DisplayInfo, DDCChannel)? in channels(display).map { (display, $0) } }
        let revision = epoch, token = UUID(); probeToken = token; probing = true
        ddcQueue.async {
            var result: [CGDirectDisplayID: DDCState] = [:]
            for (display, channel) in pairs {
                var state = DDCState(); state.caps = DDCCaps.parse(channel.capabilities())
                for code in [VCP.brightness, .contrast, .volume, .input, .colorPreset, .displayMode] {
                    guard state.caps.vcps.isEmpty || state.caps.vcps.contains(code.rawValue) else { continue }
                    if let read = channel.read(code.rawValue) {
                        state.set(code, read.value)
                        switch code { case .brightness: state.brightnessMax = max(1, read.max); case .contrast: state.contrastMax = max(1, read.max); case .volume: state.volumeMax = max(1, read.max); default: break }
                    }
                }
                state.available = state.brightness != nil || state.contrast != nil || state.volume != nil || state.colorPreset != nil || state.displayMode != nil
                result[display.id] = state
            }
            DispatchQueue.main.async {
                guard self.epoch == revision, self.probeToken == token else { done?(); return }
                self.ddc = result; self.probing = false; done?()
            }
        }
    }
    func displayedValue(_ id: CGDirectDisplayID, _ code: VCP) -> Int? { ddcPending[DDCOperationKey(display: id, code: code.rawValue)] ?? ddc[id]?.value(code) }
    func setDDC(_ id: CGDirectDisplayID, _ code: VCP, _ value: Int) {
        guard (0...65535).contains(value), let display = displays.first(where: { $0.id == id }), let channel = channels(display) else { ddcNotes[id] = "未匹配到可用的显示器通道，请刷新"; return }
        if [.colorPreset, .displayMode].contains(code), !(ddc[id]?.caps.values[code.rawValue]?.contains(UInt8(clamping: value)) ?? false), originalDDC[display.key]?[code.rawValue] != value { return }
        let key = DDCOperationKey(display: id, code: code.rawValue), token = UUID(), revision = epoch
        ddcWork[key]?.cancel(); ddcTokens[key] = token; ddcPending[key] = value; ddcNotes[id] = "正在应用并核对…"
        lastDDCAttempt[id] = (code, value)
        let work = DispatchWorkItem {
            let valid = DispatchQueue.main.sync { self.epoch == revision && self.ddcTokens[key] == token }
            guard valid else { return }
            let old = channel.read(code.rawValue)?.value
            let ready = DispatchQueue.main.sync { () -> Bool in
                guard self.epoch == revision && self.ddcTokens[key] == token else { return false }
                if let old, self.originalDDC[display.key]?[code.rawValue] == nil { self.originalDDC[display.key, default: [:]][code.rawValue] = old }
                return true
            }
            guard ready else { return }
            let sent = channel.write(code.rawValue, value)
            var actual: Int?
            if sent {
                for _ in 0..<5 { usleep(120_000); actual = channel.read(code.rawValue)?.value; if actual == value { break } }
            } else { actual = channel.read(code.rawValue)?.value }
            DispatchQueue.main.async {
                guard self.epoch == revision else { return }
                guard self.ddcTokens[key] == token else { return }
                self.ddcPending.removeValue(forKey: key); self.ddcTokens.removeValue(forKey: key); self.ddcWork.removeValue(forKey: key)
                self.ddc[id]?.set(code, actual)
                if sent && actual == value { self.ddcNotes[id] = "已核对显示器读数" }
                else if sent && code == .input { self.ddcNotes[id] = "已发送输入切换，无法回读确认；请在显示器上核对" }
                else { self.ddcNotes[id] = "未确认修改成功，已显示可读取的实际值；可重试或恢复" }
            }
        }
        ddcWork[key] = work
        ddcQueue.asyncAfter(deadline: .now() + (code == .input ? 0 : 0.12), execute: work)
    }
    func restoreColor(_ id: CGDirectDisplayID) {
        guard let display = displays.first(where: { $0.id == id }) else { return }
        for code in [VCP.colorPreset, .displayMode] { if let value = originalDDC[display.key]?[code.rawValue] { setDDC(id, code, value) } }
    }
    static let confirmSeconds: TimeInterval = 15
    func switchMode(_ id: CGDirectDisplayID, to mode: DMode) {
        guard let display = displays.first(where: { $0.id == id }), display.current != mode else { return }
        if pending != nil { revert() }
        let old = display.current
        guard sys.apply(mode, to: id) else { return }
        displays = sys.displays(); pending = (id, old, Date().addingTimeInterval(Self.confirmSeconds))
        revertWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.revert() }; revertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmSeconds, execute: work)
    }
    func keep() { revertWork?.cancel(); pending = nil }
    func revert() {
        revertWork?.cancel(); guard let value = pending else { return }
        _ = sys.apply(value.old, to: value.id); pending = nil; displays = sys.displays()
    }
    private func deviceSettings(_ id: CGDirectDisplayID) -> DisplaySettings {
        if id == selectedID { return settings }
        return displays.first(where: { $0.id == id }).flatMap { saved[$0.key] } ?? DisplaySettings()
    }
    func applyGamma(_ id: CGDirectDisplayID) {
        let value = deviceSettings(id)
        guard value.gammaOn else { return }
        let rgb = ColorTemp.rgb(value.kelvin), dim = max(0.3, min(1, value.dim))
        gammaNotes[id] = gamma.set(id, r: rgb.0 * dim, g: rgb.1 * dim, b: rgb.2 * dim) ? "软件调光已应用于当前屏幕" : "软件色温未生效，请刷新后重试"
    }
    func applyGamma() { if selectedID == 0, let first = displays.first { select(first.id) }; applyGamma(selectedID) }
    private func applyAllGamma() { for display in displays { applyGamma(display.id) } }
    func setGamma(on: Bool) {
        if on { settings.gammaOn = true; applyGamma() }
        else if gamma.restore(selectedID) { settings.gammaOn = false; gammaNotes[selectedID] = "已恢复当前屏幕原曲线" }
        else { gammaNotes[selectedID] = "未能恢复原曲线，设置保持开启，请重试关闭" }
    }
    func setDim(_ value: Double) { settings.dim = value; settings.scene = ""; applyGamma() }
    func setKelvin(_ value: Double) { settings.kelvin = value; settings.scene = ""; applyGamma() }
    func apply(scene: DScene) { apply(scene: scene, to: selectedID == 0 ? displays.first?.id ?? 0 : selectedID) }
    private func apply(scene: DScene, to id: CGDirectDisplayID) {
        guard let display = displays.first(where: { $0.id == id }) else { return }
        var value = deviceSettings(id)
        value.scene = scene.id; value.dim = scene.dim; value.kelvin = scene.kelvin
        if !value.gammaOn && conflict.isEmpty { value.gammaOn = true }
        saved[display.key] = value
        if id == selectedID { settings = value }
        else if !offline, let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
        applyGamma(id)
        if value.sceneDDC, let state = ddc[id], state.brightness != nil { setDDC(id, .brightness, scene.ddcBrightness * state.brightnessMax / 100) }
    }
    func scheduleAuto(now: Date = Date()) {
        schedTimer?.invalidate(); schedTimer = nil
        let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        var next: TimeInterval?
        for display in displays {
            let value = deviceSettings(display.id); guard value.autoSwitch else { continue }
            let scene = value.scheduled(minute: minute)
            if value.scene != scene, let target = DScene.all.first(where: { $0.id == scene }) { apply(scene: target, to: display.id) }
            let delay = value.secondsToNextSwitch(from: now)
            next = min(next ?? delay, delay)
        }
        guard !offline, let next else { return }
        let timer = Timer(timeInterval: next + 1, repeats: false) { [weak self] _ in self?.scheduleAuto() }
        timer.tolerance = 30; RunLoop.main.add(timer, forMode: .common); schedTimer = timer
    }
    func startIfNeeded() { refresh(); applyAllGamma(); scheduleAuto() }
    func shutdown() { schedTimer?.invalidate(); gamma.restore() }
}
