// v1.9 主动提醒与打磨
// 只在异常时提醒，且提醒开关默认关闭（沿用既有打扰型功能默认关闭的原则）。
// 自动执行只做最小版：用户在设置里明确打开的项目才自动执行，每次都记入改动记录。
// 改动恢复要诚实：能一键恢复的才给恢复按钮，恢复不了的只写清楚恢复办法，不假装恢复。
import SwiftUI
import AppKit
import Foundation

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
    // 恢复：DNS 有备份时走 DNSClient 恢复；清理类只能从废纸篓手动恢复，这里不假装一键恢复；
    // 其他类只返回说明，由界面展示。返回 true 表示已执行恢复动作，false 表示需要手动按说明做。
    func restore(_ r: ChangeRecord, dns: DNSClient) -> (done: Bool, note: String) {
        if r.kind == .dns {
            if dns.status?.backup != nil {
                dns.restore()
                remove(r)
                return (true, "已恢复原 DNS")
            }
            return (false, "没有 DNS 备份，无法自动恢复")
        }
        return (false, r.restoreNote)
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
    var autoTrashTemp = false
}
final class V19Store: ObservableObject {
    static let shared = V19Store()
    @Published var settings = V19Settings()
    @Published var lastAlertText = ""
    var settingsURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacOptimizer/v19-settings.json")
    init() {
        if let d = try? Data(contentsOf: settingsURL), let v = try? JSONDecoder().decode(V19Settings.self, from: d) { settings = v }
    }
    func save() {
        if MOTests.active { return }
        try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(settings).write(to: settingsURL)
    }
    // 最小自动执行：只有用户明确打开 autoTrashTemp 时，才把临时文件类条目记入改动记录并返回；
    // 真正移到废纸篓仍由用户在清理页确认，这里不擅自删除任何文件。
    func autoCandidates(items: [CleanItem]) -> [CleanItem] {
        guard settings.autoTrashTemp else { return [] }
        return items.filter { $0.category == "缓存" || $0.category == "日志" }
    }
}

struct ChangesPage: View {
    @ObservedObject var log = ChangeLog.shared
    @ObservedObject var v19 = V19Store.shared
    @ObservedObject var dns = DNSClient.shared
    @ObservedObject var charge = ChargeClient.shared
    @State private var restoreNote = ""
    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("改动与提醒").font(.system(size: 24, weight: .bold))
                        Text("本 App 做过的改动集中在这里看，能恢复的恢复，不能恢复的会写清楚办法").font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                if charge.phase == .ready {
                    Text("充电助手已安装：不会重复索要授权，也不会重复弹安装提示").font(.system(size: 11)).foregroundColor(good).fixedSize(horizontal: false, vertical: true)
                } else {
                    Button("去电池页安装充电助手") { Nav.shared.sel = -3 }.buttonStyle(PillButton(filled: false))
                }
                Card(title: "主动提醒（只在异常时）", icon: "bell") {
                    Toggle("开启异常提醒（默认关闭）", isOn: Binding(get: { v19.settings.alertsOn }, set: { v19.settings.alertsOn = $0; v19.save() })).accessibilityIdentifier("v19.alertsOn")
                    Text("阈值：CPU 连续 5 次采样都高于 90% 才提醒一次，之后 1 小时内不重复弹；磁盘可用低于 10% 或低于 20 GB 提醒；电池健康从 80% 以上掉到 80% 以下提醒。阈值附近抖动不会反复弹。").font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !v19.lastAlertText.isEmpty { Text(v19.lastAlertText).font(.system(size: 11)).foregroundColor(.orange) }
                    Text("提醒开关默认关闭，打开后才会在异常时通知，不会平时打扰你").font(.system(size: 10)).foregroundColor(.secondary)
                }
                Card(title: "自动执行（最小版，需你明确打开）", icon: "gearshape") {
                    Toggle("自动整理临时文件（仅缓存和日志类，执行前仍记入改动记录）", isOn: Binding(get: { v19.settings.autoTrashTemp }, set: { v19.settings.autoTrashTemp = $0; v19.save() })).accessibilityIdentifier("v19.autoTrash")
                    Text("这个开关只是“允许自动整理”，真正移到废纸篓前仍会在清理页给你清单确认，不会擅自删文件；每次自动整理都会记一条改动记录").font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Card(title: "改动记录", icon: "list.clipboard") {
                    if log.records.isEmpty {
                        Text("还没有本 App 做过的改动记录。清理到废纸篓、DNS 改动会在这里出现。").font(.system(size: 11)).foregroundColor(.secondary)
                    } else {
                        ForEach(Array(log.records.suffix(50).reversed())) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(r.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Spacer()
                                    Text(r.kind.rawValue).font(.system(size: 10)).foregroundColor(.secondary)
                                }
                                Text(r.detail).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
                                HStack(spacing: 8) {
                                    if r.reversible && r.kind == .dns {
                                        Button("恢复原 DNS") { let res = log.restore(r, dns: dns); restoreNote = res.note }.buttonStyle(PillButton(filled: false)).accessibilityIdentifier("changes.restore")
                                    } else {
                                        Text(r.restoreNote).font(.system(size: 10)).foregroundColor(.secondary)
                                    }
                                    if r.kind == .clean {
                                        Button("打开废纸篓") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")) }.buttonStyle(PillButton(filled: false))
                                    }
                                }
                            }
                            Divider()
                        }
                    }
                    if !restoreNote.isEmpty { Text(restoreNote).font(.system(size: 11)).foregroundColor(good) }
                    Text("恢复不了的项不会假装恢复：清理类请从废纸篓手动放回，退出应用类请重新打开该应用").font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(28)
        }
    }
}
