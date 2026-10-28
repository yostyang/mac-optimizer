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
            return DisplayInfo(id: id, name: name, builtin: CGDisplayIsBuiltin(id) != 0, current: Self.m(cur), modes: all.map(Self.m))
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
enum VCP: UInt8 { case brightness = 0x10, contrast = 0x12, volume = 0x62, input = 0x60 }
struct DDCCaps: Equatable {
    var vcps: Set<UInt8> = []
    var inputs: [UInt8] = []
    var model = ""
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
            if ch == "(" { flush(); depth += 1 } else if ch == ")" { flush(); depth -= 1 } else if ch == " " { flush() } else { tok.append(ch) }
            i = s.index(after: i)
        }
        c.inputs = sub[VCP.input.rawValue] ?? []
        return c
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
    typealias RW = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private static let h = dlopen(nil, RTLD_NOW)
    private static let createF = dlsym(h, "IOAVServiceCreateWithService").map { unsafeBitCast($0, to: Create.self) }
    private static let readF = dlsym(h, "IOAVServiceReadI2C").map { unsafeBitCast($0, to: RW.self) }
    private static let writeF = dlsym(h, "IOAVServiceWriteI2C").map { unsafeBitCast($0, to: RW.self) }
    let svc: CFTypeRef
    private let lock = NSLock()
    init(_ s: CFTypeRef) { svc = s }
    /// 外接屏的 AV 服务（Apple 芯片），按 IORegistry 顺序
    static func externals() -> [AVServiceDDC] {
        guard let create = createF, readF != nil, writeF != nil else { return [] }
        var it: io_iterator_t = 0; var out: [AVServiceDDC] = []
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it) == KERN_SUCCESS else { return [] }
        while case let o = IOIteratorNext(it), o != 0 {
            if (IORegistryEntryCreateCFProperty(o, "Location" as CFString, nil, 0)?.takeRetainedValue() as? String) == "External", let s = create(nil, o)?.takeRetainedValue() { out.append(AVServiceDDC(s)) }
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
}
final class RealGamma: GammaSystem {
    func set(_ id: CGDirectDisplayID, r: Double, g: Double, b: Double) -> Bool {
        let n = 256
        var R = [CGGammaValue](repeating: 0, count: n), G = R, B = R
        for i in 0..<n { let v = Float(i) / Float(n - 1); R[i] = v * Float(r); G[i] = v * Float(g); B[i] = v * Float(b) }
        return CGSetDisplayTransferByTable(id, UInt32(n), R, G, B) == .success
    }
    func restore() { CGDisplayRestoreColorSyncSettings() }
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
    @Published var settings = DisplaySettings.load() { didSet { if !offline { settings.save() } } }
    @Published var pending: (id: CGDirectDisplayID, old: DMode, until: Date)?
    @Published var conflict = ""                     // 检测到的其他调 Gamma 的软件
    @Published var probing = false
    var sys: DisplaySystem
    var gamma: GammaSystem
    var channels: (DisplayInfo) -> DDCChannel? = { _ in nil }
    var offline = false
    private var revertWork: DispatchWorkItem?
    private var schedTimer: Timer?
    private var reconfigRegistered = false
    init(sys: DisplaySystem = RealDisplaySystem(), gamma: GammaSystem = RealGamma()) {
        self.sys = sys; self.gamma = gamma
        // 外接屏按顺序对应 AV 服务（本 App 主要面向单台外接屏）
        var cache: [AVServiceDDC]? = nil
        channels = { [weak self] d in
            guard !d.builtin, let self else { return nil }
            if cache == nil { cache = AVServiceDDC.externals() }
            let ext = self.displays.filter { !$0.builtin }.map(\.id)
            guard let i = ext.firstIndex(of: d.id), i < cache!.count else { return nil }
            return cache![i]
        }
    }
    static let gammaApps = ["MonitorBar", "Lunar", "f.lux", "BetterDisplay", "Flux", "Iris"]
    func detectConflict() {
        conflict = NSWorkspace.shared.runningApplications.compactMap { $0.localizedName }.first { n in Self.gammaApps.contains { n.localizedCaseInsensitiveContains($0) } } ?? ""
    }
    func refresh() {
        displays = sys.displays()
        detectConflict()
        if !reconfigRegistered && !offline {
            reconfigRegistered = true
            // 显示器插拔/分辨率变化：系统会重置 Gamma，这里按设置重新套用（事件驱动）
            CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
                guard !flags.contains(.beginConfigurationFlag) else { return }
                DispatchQueue.main.async { DisplayManager.shared.displays = DisplayManager.shared.sys.displays(); DisplayManager.shared.applyGamma() }
            }, nil)
        }
    }
    /// 读取 DDC（后台线程，只在打开页面/点刷新时）
    func probeDDC(done: (() -> Void)? = nil) {
        let ds = displays.filter { !$0.builtin }
        probing = true
        DispatchQueue.global(qos: .utility).async {
            var res: [CGDirectDisplayID: DDCState] = [:]
            for d in ds {
                guard let ch = self.channels(d) else { continue }
                var st = DDCState()
                let caps = DDCCaps.parse(ch.capabilities()); st.caps = caps
                if let b = ch.read(VCP.brightness.rawValue) { st.brightness = b.value; st.brightnessMax = max(1, b.max) }
                if caps.vcps.isEmpty || caps.vcps.contains(VCP.contrast.rawValue), let c = ch.read(VCP.contrast.rawValue) { st.contrast = c.value; st.contrastMax = max(1, c.max) }
                if caps.vcps.isEmpty || caps.vcps.contains(VCP.volume.rawValue), let v = ch.read(VCP.volume.rawValue) { st.volume = v.value; st.volumeMax = max(1, v.max) }
                if let i = ch.read(VCP.input.rawValue) { st.input = UInt8(i.value & 0xFF) }
                st.available = st.brightness != nil || st.contrast != nil || st.volume != nil
                res[d.id] = st
            }
            DispatchQueue.main.async { self.ddc = res; self.probing = false; done?() }
        }
    }
    func setDDC(_ id: CGDirectDisplayID, _ code: VCP, _ value: Int) {
        guard let d = displays.first(where: { $0.id == id }) else { return }
        switch code {
        case .brightness: ddc[id]?.brightness = value
        case .contrast: ddc[id]?.contrast = value
        case .volume: ddc[id]?.volume = value
        case .input: ddc[id]?.input = UInt8(value)
        }
        guard let ch = channels(d) else { return }
        // 拖动滑块时合并写入：120ms 内只发最后一个值
        ddcWork[code.rawValue]?.cancel()
        let w = DispatchWorkItem { _ = ch.write(code.rawValue, value) }
        ddcWork[code.rawValue] = w
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (code == .input ? 0 : 0.12), execute: w)
    }
    private var ddcWork: [UInt8: DispatchWorkItem] = [:]

    // 分辨率：切换后 15 秒内不确认就自动还原（防止黑屏/看不清）
    static let confirmSeconds: TimeInterval = 15
    func switchMode(_ id: CGDirectDisplayID, to m: DMode) {
        guard let d = displays.first(where: { $0.id == id }), d.current != m else { return }
        let old = d.current
        guard sys.apply(m, to: id) else { return }
        displays = sys.displays()
        pending = (id, old, Date().addingTimeInterval(Self.confirmSeconds))
        revertWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.revert() }
        revertWork = w; DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmSeconds, execute: w)
    }
    func keep() { revertWork?.cancel(); pending = nil }
    func revert() {
        revertWork?.cancel()
        guard let p = pending else { return }
        _ = sys.apply(p.old, to: p.id); pending = nil; displays = sys.displays()
    }

    // Gamma
    func applyGamma() {
        guard settings.gammaOn else { return }
        let c = ColorTemp.rgb(settings.kelvin); let k = max(0.3, min(1, settings.dim))
        for d in displays { _ = gamma.set(d.id, r: c.0 * k, g: c.1 * k, b: c.2 * k) }
    }
    func setGamma(on: Bool) { settings.gammaOn = on; if on { applyGamma() } else { gamma.restore() } }
    func setDim(_ v: Double) { settings.dim = v; settings.scene = ""; applyGamma() }
    func setKelvin(_ v: Double) { settings.kelvin = v; settings.scene = ""; applyGamma() }
    func apply(scene s: DScene) {
        settings.scene = s.id; settings.dim = s.dim; settings.kelvin = s.kelvin
        if !settings.gammaOn && conflict.isEmpty { settings.gammaOn = true }
        applyGamma()
        if settings.sceneDDC {
            for (id, st) in ddc where st.brightness != nil { setDDC(id, .brightness, s.ddcBrightness * st.brightnessMax / 100) }
        }
    }
    // 定时：只在下一个切换点触发一次
    func scheduleAuto(now: Date = Date()) {
        schedTimer?.invalidate(); schedTimer = nil
        guard settings.autoSwitch else { return }
        let cal = Calendar.current; let c = cal.dateComponents([.hour, .minute], from: now)
        let want = settings.scheduled(minute: (c.hour ?? 0) * 60 + (c.minute ?? 0))
        if settings.scene != want, let s = DScene.all.first(where: { $0.id == want }) { apply(scene: s) }
        guard !offline else { return }
        let t = Timer(timeInterval: settings.secondsToNextSwitch(from: now) + 1, repeats: false) { [weak self] _ in self?.scheduleAuto() }
        t.tolerance = 30; RunLoop.main.add(t, forMode: .common); schedTimer = t
    }
    /// App 启动：只有用户开过软件调光/定时才会动 Gamma
    func startIfNeeded() {
        refresh()      // 只读：显示器列表（菜单栏面板显示分辨率）
        guard settings.gammaOn || settings.autoSwitch else { return }
        applyGamma(); scheduleAuto()
    }
    func shutdown() { if settings.gammaOn { gamma.restore() } }
}
