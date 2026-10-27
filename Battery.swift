import Foundation
import AppKit
import UserNotifications
import Darwin

// MARK: - 设置（全部持久化，打扰型功能默认关闭）
struct BatterySettings: Codable, Equatable {
    var alertsOn = false
    var lowThresholds: [Int] = [20, 10]
    var upperOn = true; var upper = 80
    var plugOn = true; var unplugOn = true; var fullOn = true
    var sounds: [String: String] = ["plug": "Pop", "unplug": "Bottle", "upper": "Glass", "full": "Hero", "low": "Sosumi"]
    var criticalGlow = false; var criticalLevel = 5
    var deviceAlertsOn = false; var deviceLow = 15
    var drainAlertsOn = false
    var energyTracking = true
    var menuIndicator = "cpu"   // cpu / score / battery

    static let key = "battery.settings"
    static func load(_ d: UserDefaults = .standard) -> BatterySettings {
        guard let data = d.data(forKey: key), let s = try? JSONDecoder().decode(BatterySettings.self, from: data) else { return BatterySettings() }
        return s
    }
    func save(_ d: UserDefaults = .standard) { if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: BatterySettings.key) } }
    static let soundChoices = ["Pop", "Bottle", "Glass", "Hero", "Ping", "Purr", "Submarine", "Tink", "Sosumi", "Funk", "无声"]
}

enum AlertEvent: Equatable {
    case plugged, unplugged, upper(Int), full, low(Int, critical: Bool)
    case deviceLow(String, Int), deviceFull(String)
    case drain(String, Double)
    var soundKey: String {
        switch self { case .plugged: return "plug"; case .unplugged: return "unplug"; case .upper: return "upper"; case .full: return "full"; case .low, .deviceLow: return "low"; case .deviceFull: return "full"; case .drain: return "low" }
    }
    var text: (String, String) {
        switch self {
        case .plugged: return ("已接通电源", "开始充电")
        case .unplugged: return ("已断开电源", "正在使用电池")
        case .upper(let p): return ("电量已到 \(p)%", "可以拔掉电源，减少电池损耗")
        case .full: return ("电池已充满", "可以拔掉电源了")
        case .low(let p, let c): return (c ? "电量严重不足：\(p)%" : "电量低于 \(p)%", "请尽快接上电源")
        case .deviceLow(let n, let p): return ("\(n) 电量低", "剩余 \(p)%，记得充电")
        case .deviceFull(let n): return ("\(n) 已充满", "电量 100%")
        case .drain(let n, let wh): return ("\(n) 耗电异常", String(format: "过去一小时用了约 %.1f Wh，明显高于平时", wh))
        }
    }
}

/// 纯逻辑：根据电量变化给出提醒；带回差，同一阈值不会反复提醒
struct AlertEngine {
    static let hysteresis = 3
    var armedLow: Set<Int> = []
    var upperArmed = true, fullArmed = true
    var lastAC: Bool? = nil
    var devLowArmed: [String: Bool] = [:], devFullArmed: [String: Bool] = [:]

    mutating func update(level: Int, onAC: Bool, settings s: BatterySettings) -> [AlertEvent] {
        var out: [AlertEvent] = []
        if let was = lastAC, was != onAC {
            if onAC, s.plugOn { out.append(.plugged) }
            if !onAC, s.unplugOn { out.append(.unplugged) }
        }
        let first = lastAC == nil
        lastAC = onAC
        let ts = Set(s.lowThresholds.filter { $0 > 0 && $0 < 100 })
        if first { armedLow = ts.filter { level > $0 }; upperArmed = level < s.upper; fullArmed = level < 100 }
        armedLow.formIntersection(ts)
        // 重新武装：充电中或电量回升到阈值 + 回差以上
        for t in ts where onAC || level >= t + AlertEngine.hysteresis { armedLow.insert(t) }
        if !onAC {
            let crossed = ts.filter { level <= $0 && armedLow.contains($0) }
            if let t = crossed.min() {
                out.append(.low(t, critical: s.criticalGlow && t <= s.criticalLevel))
                armedLow.subtract(ts.filter { level <= $0 })   // 一次跌过多个阈值只提醒最低的那个
            }
        }
        if level <= s.upper - AlertEngine.hysteresis { upperArmed = true }
        if s.upperOn, onAC, level >= s.upper, s.upper < 100, upperArmed { out.append(.upper(s.upper)); upperArmed = false }
        if level <= 100 - 5 { fullArmed = true }
        if s.fullOn, onAC, level >= 100, fullArmed { out.append(.full); fullArmed = false }
        return out
    }
    mutating func devices(_ ds: [DeviceBattery], settings s: BatterySettings) -> [AlertEvent] {
        var out: [AlertEvent] = []
        for d in ds {
            if d.percent >= s.deviceLow + 5 { devLowArmed[d.name] = true }
            if devLowArmed[d.name] == nil { devLowArmed[d.name] = d.percent > s.deviceLow }
            if d.percent <= s.deviceLow, devLowArmed[d.name] == true { out.append(.deviceLow(d.name, d.percent)); devLowArmed[d.name] = false }
            if d.percent <= 95 { devFullArmed[d.name] = true }
            if devFullArmed[d.name] == nil { devFullArmed[d.name] = d.percent < 100 }
            if d.percent >= 100, devFullArmed[d.name] == true { out.append(.deviceFull(d.name)); devFullArmed[d.name] = false }
        }
        return out
    }
}

// MARK: - 应用耗电记录（每分钟采样一次 proc_pid_rusage 的 ri_energy_nj，按小时汇总存盘）
struct EnergyStore: Codable, Equatable {
    /// 小时序号（epoch/3600） -> 应用 -> 焦耳
    var hours: [Int: [String: Double]] = [:]
    static let keepHours = 31 * 24
    mutating func add(_ app: String, joules: Double, at date: Date) {
        guard joules > 0 else { return }
        let h = Int(date.timeIntervalSince1970 / 3600)
        hours[h, default: [:]][app, default: 0] += joules
    }
    mutating func prune(now: Date) {
        let cut = Int(now.timeIntervalSince1970 / 3600) - EnergyStore.keepHours
        hours = hours.filter { $0.key > cut }
        // 每小时只保留前 30 个应用，控制文件大小
        for (h, m) in hours where m.count > 30 { hours[h] = Dictionary(uniqueKeysWithValues: m.sorted { $0.value > $1.value }.prefix(30).map { ($0.key, $0.value) }) }
    }
    enum Range: String, CaseIterable { case day = "24 小时", week = "7 天", month = "30 天" }
    struct Row: Identifiable, Equatable { var id: String { app }; let app: String; let joules: Double; let series: [Double] }
    /// 汇总：24 小时按小时 24 个点，7/30 天按天
    func summary(_ r: Range, now: Date) -> [Row] {
        let nowH = Int(now.timeIntervalSince1970 / 3600)
        let (buckets, size): (Int, Int) = r == .day ? (24, 1) : (r == .week ? 7 : 30, 24)
        let start = nowH - buckets * size + 1
        var per: [String: [Double]] = [:]
        for (h, m) in hours where h >= start && h <= nowH {
            let idx = (h - start) / size
            for (a, j) in m { per[a, default: [Double](repeating: 0, count: buckets)][idx] += j }
        }
        return per.map { Row(app: $0.key, joules: $0.value.reduce(0, +), series: $0.value) }.sorted { $0.joules > $1.joules }
    }
    /// 异常耗电：上一个完整小时 > 3 × 近 7 天小时平均，且超过 0.5 Wh
    func abnormal(now: Date) -> [(String, Double)] {
        let last = Int(now.timeIntervalSince1970 / 3600) - 1
        guard let m = hours[last] else { return [] }
        var out: [(String, Double)] = []
        for (a, j) in m where j > 1800 {
            let prior = (last - 168..<last).compactMap { hours[$0]?[a] }
            let avg = prior.reduce(0, +) / 168
            if prior.count >= 6, j > avg * 3 { out.append((a, j / 3600)) }
        }
        return out
    }
}

final class EnergyTracker: ObservableObject {
    static let shared = EnergyTracker()
    @Published private(set) var store = EnergyStore()
    @Published private(set) var live: [(app: String, watts: Double)] = []
    private var prev: [Int32: UInt64] = [:]; private var prevT = Date()
    private var names: [Int32: String] = [:]
    private var timer: DispatchSourceTimer?
    private let q = DispatchQueue(label: "energy", qos: .background)
    private var lastSave = Date(), lastHourChecked = 0
    var onDrain: ((String, Double) -> Void)?
    static var fileURL: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacOptimizer")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("energy.json")
    }()
    private static let respFn: (@convention(c) (Int32) -> Int32)? = {
        dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid").map { unsafeBitCast($0, to: (@convention(c) (Int32) -> Int32).self) }
    }()

    func start(interval: TimeInterval = 60) {
        guard timer == nil else { return }
        if let d = try? Data(contentsOf: EnergyTracker.fileURL), let s = try? JSONDecoder().decode(EnergyStore.self, from: d) { store = s }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: interval, leeway: .seconds(10))
        t.setEventHandler { [weak self] in self?.sample() }
        timer = t; t.resume()
    }
    func stop() { timer?.cancel(); timer = nil; save() }
    func sampleNow() { q.async { self.sample() } }
    func save() {
        let s = Thread.isMainThread ? store : DispatchQueue.main.sync { self.store }
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: EnergyTracker.fileURL, options: .atomic) }
    }
    private func appName(_ pid: Int32) -> String {
        if let n = names[pid] { return n }
        let owner = EnergyTracker.respFn?(pid) ?? pid
        var n = ""
        if let a = NSRunningApplication(processIdentifier: owner > 0 ? owner : pid), let ln = a.localizedName { n = ln }
        if n.isEmpty { var b = [CChar](repeating: 0, count: 256); proc_name(owner > 0 ? owner : pid, &b, 256); n = String(cString: b) }
        if n.isEmpty { n = "pid \(pid)" }
        names[pid] = n; return n
    }
    private func sample() {
        let n = proc_listallpids(nil, 0); guard n > 0 else { return }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let got = Int(proc_listallpids(&pids, Int32(pids.count * 4)))
        let now = Date(); let dt = now.timeIntervalSince(prevT)
        var cur: [Int32: UInt64] = [:]; var perApp: [String: Double] = [:]
        for pid in pids.prefix(max(0, got)) where pid > 0 {
            var ri = rusage_info_v6()
            let r = withUnsafeMutablePointer(to: &ri) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) } }
            guard r == 0 else { continue }
            cur[pid] = ri.ri_energy_nj
            if let p = prev[pid], ri.ri_energy_nj > p + 1_000_000 { perApp[appName(pid), default: 0] += Double(ri.ri_energy_nj - p) / 1e9 }   // 只为有耗电的进程解析名称
        }
        names = names.filter { cur[$0.key] != nil }
        let hadPrev = !prev.isEmpty
        prev = cur; prevT = now
        guard hadPrev, dt > 0 else { return }
        let liveRows = perApp.map { (app: $0.key, watts: $0.value / dt) }.sorted { $0.watts > $1.watts }.prefix(8)
        DispatchQueue.main.async {
            for (a, j) in perApp { self.store.add(a, joules: j, at: now) }
            self.store.prune(now: now)
            self.live = Array(liveRows)
            let h = Int(now.timeIntervalSince1970 / 3600)
            if h != self.lastHourChecked { if self.lastHourChecked != 0 { for (a, wh) in self.store.abnormal(now: now) { self.onDrain?(a, wh) } }; self.lastHourChecked = h }
        }
        if now.timeIntervalSince(lastSave) > 600 { lastSave = now; save() }
    }
}

// MARK: - 提醒发送
final class BatteryAlerts: ObservableObject {
    static let shared = BatteryAlerts()
    @Published var settings = BatterySettings.load() { didSet { settings.save(); if settings.alertsOn && !oldValue.alertsOn { requestAuth() } } }
    var engine = AlertEngine()
    private var drainLast: [String: Date] = [:]
    var sink: ((AlertEvent) -> Void)?    // 测试用

    func requestAuth() { guard !MOTests.active, Bundle.main.bundleIdentifier != nil else { return }; UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } }
    func handle(_ x: Snapshot) {
        let s = settings
        guard s.alertsOn else { return }
        var evs: [AlertEvent] = []
        if let lvl = x.battery { evs += engine.update(level: lvl, onAC: x.onAC, settings: s) }
        if s.deviceAlertsOn { evs += engine.devices(x.devices, settings: s) }
        evs.forEach(fire)
    }
    func drain(_ app: String, _ wh: Double) {
        guard settings.alertsOn, settings.drainAlertsOn else { return }
        if let d = drainLast[app], Date().timeIntervalSince(d) < 6 * 3600 { return }
        drainLast[app] = Date(); fire(.drain(app, wh))
    }
    func fire(_ e: AlertEvent) {
        if let sink { sink(e); return }
        guard Bundle.main.bundleIdentifier != nil else { return }
        let (t, b) = e.text
        let c = UNMutableNotificationContent(); c.title = t; c.body = b
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        if let snd = settings.sounds[e.soundKey], snd != "无声" { NSSound(named: snd)?.play() }
        if case .low(let p, true) = e { Overlay.showGlow(level: p) }
    }
}

enum SystemPanes {
    static func battery() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!) }
}
