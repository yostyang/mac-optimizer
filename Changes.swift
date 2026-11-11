// v1.9 主动提醒与打磨
// 只在异常时提醒，且提醒开关默认关闭（沿用既有打扰型功能默认关闭的原则）。
// 未接通的自动整理入口已移除；文件移动始终由用户在清理页确认。
// 改动恢复要诚实：能一键恢复的才给恢复按钮，恢复不了的只写清楚恢复办法，不假装恢复。
import SwiftUI
import AppKit
import Foundation
import UserNotifications

enum ChangeKind: String, Codable {
    case dns = "DNS"
    case clean = "清理"
    case quitApp = "退出应用"
    case charge = "充电"
    case auto = "自动执行"
    case other = "其他"
}
struct ChangeRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var kind: ChangeKind
    var title: String
    var detail: String
    var reversible: Bool
    var restoreNote: String
}
final class ChangeLog: ObservableObject {
    static let shared = ChangeLog()
    @Published var records: [ChangeRecord] = []
    var fileURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacOptimizer/changes.json")
    init() {
        if let d = try? Data(contentsOf: fileURL), let v = try? JSONDecoder().decode([ChangeRecord].self, from: d) { records = v }
    }
    func add(kind: ChangeKind, title: String, detail: String, reversible: Bool, restoreNote: String) {
        records.append(ChangeRecord(kind: kind, title: title, detail: detail, reversible: reversible, restoreNote: restoreNote))
        if records.count > 500 { records = Array(records.suffix(500)) }
        save()
    }
    func save() {
        if MOTests.active { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(records).write(to: fileURL)
    }
    func remove(_ r: ChangeRecord) {
        records.removeAll { $0.id == r.id }
        save()
    }
    // DNS 经异步执行和状态核对后再移除待恢复记录；失败和超时保留记录。
    func restore(_ r: ChangeRecord, dns: DNSClient, completion: @escaping (Bool, String) -> Void) {
        if r.kind == .dns {
            dns.restore { success, note in
                if success { self.remove(r) }
                completion(success, note)
            }
            return
        }
        completion(false, r.restoreNote)
    }
}

// MARK: - 提醒判断（纯函数，可测试）
enum AlertCheck {
    // CPU：最近 N 个样本都高于阈值，且距上次提醒超过冷却时间，才提醒一次
    static func cpuSustained(samples: [Double], threshold: Double, minSamples: Int, lastAlert: Date?, now: Date, cooldown: TimeInterval) -> Bool {
        guard samples.count >= minSamples else { return false }
        let recent = samples.suffix(minSamples)
        guard recent.allSatisfy({ $0 >= threshold }) else { return false }
        if let last = lastAlert, now.timeIntervalSince(last) < cooldown { return false }
        return true
    }
    static func diskAlmostFull(freeFraction: Double, freeGB: Double) -> Bool {
        freeFraction < 0.10 || freeGB < 20
    }
    static func batteryHealthDrop(oldHealth: Int?, newHealth: Int?) -> Bool {
        guard let o = oldHealth, let n = newHealth else { return false }
        return o >= 80 && n < 80
    }
    static func debounceChanged(_ value: Bool, lastValue: Bool, stableCount: Int, required: Int) -> Bool {
        // 阈值附近抖动：连续 required 次同值才算真正变化，否则不重复提醒
        if value == lastValue { return false }
        return stableCount >= required
    }
}
struct V19Settings: Codable, Equatable {
    var alertsOn = false
    var cpuThreshold = 90.0
}

enum SystemAlertEvent: String {
    case cpu, disk, battery
    var title: String {
        switch self {
        case .cpu: return "CPU 持续高占用"
        case .disk: return "磁盘可用空间不足"
        case .battery: return "电池健康度下降"
        }
    }
    var page: Page { self == .cpu ? .monitor : (self == .disk ? .clean : .battery) }
}

struct SystemAlertEngine {
    var cpuSamples: [Double] = []
    var diskLowCount = 0
    var diskLow = false
    var batteryHealth: Int?
    var lastSent: [String: Date] = [:]

    mutating func update(_ s: Snapshot, enabled: Bool, threshold: Double, now: Date) -> [SystemAlertEvent] {
        let previousHealth = batteryHealth
        if let health = s.batteryHealth { batteryHealth = health }
        guard enabled else { cpuSamples = []; diskLowCount = 0; diskLow = false; return [] }
        var events: [SystemAlertEvent] = []
        func cooled(_ event: SystemAlertEvent) -> Bool {
            lastSent[event.rawValue].map { now.timeIntervalSince($0) >= 3600 } ?? true
        }
        if s.cpu.isFinite && (0...100).contains(s.cpu) {
            cpuSamples.append(s.cpu); cpuSamples = Array(cpuSamples.suffix(5))
            if AlertCheck.cpuSustained(samples: cpuSamples, threshold: threshold, minSamples: 5,
                                      lastAlert: lastSent["cpu"], now: now, cooldown: 3600) { events.append(.cpu) }
        } else { cpuSamples = [] }
        if s.diskTotalGB > 0 && s.diskFreeGB >= 0 {
            let fraction = s.diskFreeGB / s.diskTotalGB
            if AlertCheck.diskAlmostFull(freeFraction: fraction, freeGB: s.diskFreeGB) {
                diskLowCount += 1
                if diskLowCount >= 3 && !diskLow {
                    diskLow = true
                    if cooled(.disk) { events.append(.disk) }
                }
            } else {
                diskLowCount = 0
                // 留出恢复区间，避免阈值附近反复通知。
                if fraction >= 0.12 && s.diskFreeGB >= 22 { diskLow = false }
            }
        }
        if AlertCheck.batteryHealthDrop(oldHealth: previousHealth, newHealth: s.batteryHealth), cooled(.battery) {
            events.append(.battery)
        }
        for event in events { lastSent[event.rawValue] = now }
        return events
    }
}

private struct SystemAlertHistory: Codable {
    var lastSent: [String: Date]
    var batteryHealth: Int?
}

final class V19Store: ObservableObject {
    static let shared = V19Store()
    @Published var settings = V19Settings()
    @Published var lastAlertText = ""
    @Published var permissionText = "通知权限尚未读取"
    var engine = SystemAlertEngine()
    var sink: ((SystemAlertEvent) -> Void)?
    var permissionStatus: UNAuthorizationStatus = .notDetermined
    var settingsURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacOptimizer/v19-settings.json")
    init() {
        if let d = try? Data(contentsOf: settingsURL), let v = try? JSONDecoder().decode(V19Settings.self, from: d) { settings = v }
        if let data = try? Data(contentsOf: historyURL) {
            if let history = try? JSONDecoder().decode(SystemAlertHistory.self, from: data) {
                engine.lastSent = history.lastSent; engine.batteryHealth = history.batteryHealth
            } else if let legacy = try? JSONDecoder().decode([String: Date].self, from: data) { engine.lastSent = legacy }
        }
    }
    var historyURL: URL { settingsURL.deletingLastPathComponent().appendingPathComponent("system-alert-history.json") }
    func save() {
        if MOTests.active { return }
        try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(settings).write(to: settingsURL)
    }
    func setAlertsEnabled(_ enabled: Bool) {
        settings.alertsOn = enabled; save()
        if !enabled { engine.cpuSamples = []; engine.diskLowCount = 0; engine.diskLow = false }
        Monitor.shared.alertsEnabled = enabled
        guard !MOTests.active else { return }
        if enabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in self.refreshPermission() }
        } else { refreshPermission() }
    }
    func refreshPermission() {
        guard !MOTests.active else { permissionText = "开启提醒时再申请通知权限"; return }
        UNUserNotificationCenter.current().getNotificationSettings { status in
            DispatchQueue.main.async {
                self.permissionStatus = status.authorizationStatus
                switch status.authorizationStatus {
                case .authorized, .provisional: self.permissionText = "系统通知已允许"
                case .denied: self.permissionText = "系统通知未允许，异常仍会记在这里"
                case .notDetermined: self.permissionText = "开启提醒时再申请通知权限"
                @unknown default: self.permissionText = "通知权限未知，请检查系统设置"
                }
            }
        }
    }
    func handle(_ s: Snapshot, now: Date = Date()) {
        guard !MOTests.active || sink != nil else { return }
        let previousHealth = engine.batteryHealth
        let events = engine.update(s, enabled: settings.alertsOn, threshold: settings.cpuThreshold, now: now)
        for event in events {
            lastAlertText = event.title
            if let sink { sink(event); continue }
            let content = UNMutableNotificationContent()
            content.title = event.title; content.body = "点此查看当前状态和处理建议。"
            content.userInfo = ["page": event.page.storageKey]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "system-" + event.rawValue, content: content, trigger: nil)) { error in
                if let error { DispatchQueue.main.async { self.lastAlertText = event.title + "（系统通知未送达：" + error.localizedDescription + "）" } }
            }
            refreshPermission()
        }
        if (!events.isEmpty || previousHealth != engine.batteryHealth) && !MOTests.active {
            try? FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(SystemAlertHistory(lastSent: engine.lastSent, batteryHealth: engine.batteryHealth)).write(to: historyURL, options: .atomic)
        }
    }
}

struct ChangesPage: View {
    @ObservedObject var log = ChangeLog.shared
    @ObservedObject var v19 = V19Store.shared
    @ObservedObject var dns = DNSClient.shared
    @ObservedObject var charge = ChargeClient.shared
    @State private var restoreNote = ""
    @State private var restoreSucceeded = false
    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("改动与提醒").font(DS.title())
                        Text("本 App 做过的改动集中在这里看，能恢复的恢复，不能恢复的会写清楚办法").font(.system(size: 11)).foregroundColor(DS.text.secondary)
                    }
                    Spacer()
                }
                if charge.phase == .ready {
                    Text("充电助手已安装：不会重复索要授权，也不会重复弹安装提示").font(.system(size: 11)).foregroundColor(DS.text.good).fixedSize(horizontal: false, vertical: true)
                } else {
                    Button("去电池页安装充电助手") { Nav.shared.sel = .battery }.buttonStyle(PillButton(filled: false))
                }
                Card(title: "主动提醒（只在异常时）", icon: "bell") {
                    Toggle("开启异常提醒（默认关闭）", isOn: Binding(get: { v19.settings.alertsOn }, set: { v19.setAlertsEnabled($0) })).accessibilityIdentifier("v19.alertsOn")
                    Text("阈值：CPU 连续 5 次采样都高于 90% 才提醒一次，之后 1 小时内不重复弹；磁盘可用低于 10% 或低于 20 GB 提醒；电池健康从 80% 以上掉到 80% 以下提醒。阈值附近抖动不会反复弹。").font(.system(size: 11)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
                    if !v19.lastAlertText.isEmpty { Text(v19.lastAlertText).font(.system(size: 11)).foregroundColor(DS.text.warn) }
                    HStack {
                        Text(v19.permissionText).font(.system(size: 11)).foregroundColor(DS.text.secondary).accessibilityIdentifier("v22.notificationPermission")
                        if v19.permissionStatus == .denied {
                            Button("打开通知设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }.buttonStyle(PillButton(filled: false))
                        }
                    }
                    Text("提醒开启后，关闭窗口仍会监测；磁盘连续 3 次不足才提醒，恢复后才重新判断。清理始终由你预览并确认。").font(.system(size: 10)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Card(title: "改动记录", icon: "list.clipboard") {
                    if log.records.isEmpty {
                        StateLine(kind: .empty, text: "还没有本 App 做过的改动记录", detail: "清理到废纸篓、DNS 改动会在这里出现。", id: "changes.state")
                    } else {
                        ForEach(Array(log.records.suffix(50).reversed())) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(r.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                    Spacer()
                                    Text(r.kind.rawValue).font(.system(size: 10)).foregroundColor(DS.text.secondary)
                                }
                                Text(r.detail).font(.system(size: 10)).foregroundColor(DS.text.secondary).lineLimit(2)
                                HStack(spacing: 8) {
                                    if r.reversible && r.kind == .dns {
                                        Button("恢复原 DNS") {
                                            restoreSucceeded = false; restoreNote = "正在恢复并核对 DNS…"
                                            log.restore(r, dns: dns) { success, note in restoreSucceeded = success; restoreNote = note }
                                        }.buttonStyle(PillButton(filled: false)).disabled(dns.busy).accessibilityIdentifier("changes.restore")
                                    } else {
                                        Text(r.restoreNote).font(.system(size: 10)).foregroundColor(DS.text.secondary)
                                    }
                                    if r.kind == .clean {
                                        Button("打开废纸篓") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")) }.buttonStyle(PillButton(filled: false))
                                    }
                                }
                            }
                            Divider()
                        }
                    }
                    if !restoreNote.isEmpty { Text(restoreNote).font(.system(size: 11)).foregroundColor(restoreSucceeded ? DS.text.good : DS.text.warn) }
                    Text("恢复不了的项不会假装恢复：清理类请从废纸篓手动放回，退出应用类请重新打开该应用").font(.system(size: 10)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(28)
        }.onAppear { v19.refreshPermission() }
    }
}
