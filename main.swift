import SwiftUI
import AppKit
import Combine
import UserNotifications

struct Proc { var pid: Int32 = 0; let cpu: Double; let rss: Double; let comm: String
    var name: String { (comm as NSString).lastPathComponent } }

struct AppUse { let name: String; let cpu: Double; let memGB: Double; let app: NSRunningApplication }

struct Issue: Identifiable { let id = UUID(); let title: String; let detail: String; let action: (() -> Void)?; var on: Bool; var verify: (() -> Bool)? = nil }

struct Row: Identifiable {
    let id = UUID()
    let icon: NSImage?
    let title: String
    let subtitle: String
    let actionTitle: String?
    let action: (() -> Void)?
    var verify: (() -> Bool)? = nil
}

enum LoginItems {
    enum ReadError: Error { case commandFailed, invalidOutput }
    // JSON 保留名称里的逗号、引号和换行；不按 osascript 的逗号分隔显示文本拆名称。
    static let listScript = "function run() { return JSON.stringify(Application('System Events').loginItems.name()); }"
    static let deleteScript = ["-e", "on run argv",
                               "-e", "tell application \"System Events\" to delete login item (item 1 of argv)",
                               "-e", "end run", "--"]

    static func names(using runner: CommandRunner = RealRunner()) -> Result<[String], ReadError> {
        let result = runner.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", listScript])
        guard result.code == 0 else { return .failure(.commandFailed) }
        guard let names = try? JSONDecoder().decode([String].self, from: Data(result.out.utf8)) else {
            return .failure(.invalidOutput)
        }
        return .success(names)
    }

    @discardableResult
    static func remove(_ name: String, using runner: CommandRunner = RealRunner()) -> Int32 {
        runner.run("/usr/bin/osascript", deleteScript + [name]).code
    }

    static func row(_ name: String, using runner: CommandRunner = RealRunner()) -> Row {
        Row(icon: nil, title: name, subtitle: "开机时自动启动", actionTitle: "禁止自启",
            action: { _ = remove(name, using: runner) }, verify: {
                guard case .success(let current) = names(using: runner) else { return false }
                return !current.contains(name)
            })
    }
}

enum Sys {
    static func procs() -> [Proc] {
        ProcessRunner.run("/bin/ps", ["-Axo", "pid=,pcpu=,rss=,comm="]).out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let c = Double(parts[1]), let r = Double(parts[2]) else { return nil }
            return Proc(pid: pid, cpu: c, rss: r, comm: String(parts[3]))
        }
    }
    static func cpu(_ names: [String], _ ps: [Proc]) -> Double { ps.filter { names.contains($0.name) }.reduce(0) { $0 + $1.cpu } }
    static func appUsage(_ ps: [Proc]) -> [AppUse] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { a -> AppUse? in
            guard let path = a.bundleURL?.path else { return nil }
            let mine = ps.filter { $0.comm.hasPrefix(path) }
            return AppUse(name: a.localizedName ?? (path as NSString).lastPathComponent, cpu: mine.reduce(0) { $0 + $1.cpu }, memGB: mine.reduce(0) { $0 + $1.rss } / 1048576, app: a)
        }.sorted { $0.memGB > $1.memGB }
    }
    static let browserWords = ["Chrome", "Edge", "Safari", "Firefox", "Arc", "豆包", "Doubao", "夸克", "Quark", "浏览器", "Browser"]
    static func isBrowser(_ n: String) -> Bool { browserWords.contains { n.contains($0) } && !n.contains("工作") }
    static func isVPN(_ n: String) -> Bool { n.contains("VPN") || n.contains("鹊桥") }
    static func quitClaude() { for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == "com.anthropic.claudefordesktop" { _ = app.terminate() } }
    static func restartSpotlight() { _ = ProcessRunner.run("/usr/bin/killall", ["corespotlightd", "helpd", "mds_stores"]) }
    static func memoryFreePercentage(_ output: String) -> Int? {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.contains("free percentage:") }),
              let value = line.split(separator: ":").last else { return nil }
        return Int(value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: ""))
    }
    static func vpnConflicts(_ apps: [AppUse]) -> [Issue] {
        guard apps.count > 1 else { return [] }
        return apps.map { item in
            let app = item.app
            return Issue(title: "多个 VPN 同时运行：\(item.name)",
                         detail: "请按需要保留客户端；不会自动选择要退出的 VPN", action: { _ = app.terminate() },
                         on: false, verify: { app.isTerminated })
        }
    }
    static let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    static func openAppearance() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Appearance-Settings.extension")!) }
    static func openA11y(_ pane: String) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?" + pane)!) }
    static let vmName = "com.apple.Virtualization.VirtualMachine"
}

final class Model: ObservableObject {
    enum Phase { case idle, scanning, done, fixing }
    @Published var phase: Phase = .idle
    @Published var issues: [Issue] = []
    @Published var score = 100
    @Published var summary = ""
    @Published var log: [String] = []
    @Published var verdict: Verdict?
    var verificationTimeout: TimeInterval = 8

    func scan(keepLog: Bool = false) {
        if !keepLog { log = [] }
        phase = .scanning
        DispatchQueue.global().async {
            let ps = Sys.procs()
            let apps = Sys.appUsage(ps)
            var iss: [Issue] = []; var pen = 0
            let loadStr = ProcessRunner.run("/usr/sbin/sysctl", ["-n", "vm.loadavg"]).out
                .split(separator: " ").dropFirst().first.map(String.init) ?? "0"
            let load = Double(loadStr) ?? 0
            let memFree = Sys.memoryFreePercentage(ProcessRunner.run("/usr/bin/memory_pressure", []).out) ?? 100
            let days = Int(ProcessInfo.processInfo.systemUptime / 86400)
            let cores = Double(ProcessInfo.processInfo.activeProcessorCount)

            let sp = Sys.cpu(["corespotlightd", "helpd", "mds_stores"], ps)
            if sp > 40 { pen += 15; iss.append(Issue(title: "Spotlight 索引卡住", detail: "占用 \(Int(sp))% CPU，重启它不会丢任何数据", action: Sys.restartSpotlight, on: true, verify: { ps.filter { ["corespotlightd", "helpd", "mds_stores"].contains($0.name) }.allSatisfy { !OperationCheck.processExists($0.pid) } })) }

            let vm = ps.filter { $0.name == Sys.vmName }
            if !vm.isEmpty {
                let c = vm.reduce(0) { $0 + $1.cpu }, g = vm.reduce(0) { $0 + $1.rss } / 1048576
                let claudeOn = apps.contains { $0.name.hasPrefix("Claude") }
                if c > 50 { pen += 20 } else { pen += 5 }
                iss.append(Issue(title: "后台虚拟机在运行" + (claudeOn ? "（Claude）" : ""), detail: String(format: "占用 %.0f%% CPU、%.1f GB 内存；没有任务在跑就可以退出", c, g), action: claudeOn ? Sys.quitClaude : nil, on: c > 50 && claudeOn, verify: { !NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.anthropic.claudefordesktop" } }))
            }

            let vpns = apps.filter { Sys.isVPN($0.name) }
            if vpns.count > 1 {
                pen += 10
                iss.append(contentsOf: Sys.vpnConflicts(vpns))
            }
            if ps.contains(where: { $0.comm.contains("鹊桥VPN.app/Contents/MacOS/console") }) {
                pen += 5; iss.append(Issue(title: "鹊桥VPN 控制台窗口", detail: "网页窗口持续占用 CPU，可按需选择处理", action: { for p in ps where p.comm.contains("鹊桥VPN.app/Contents/MacOS/console") && p.pid > 1 && p.pid != getpid() { _ = kill(p.pid, SIGTERM) } }, on: false, verify: { ps.filter { $0.comm.contains("鹊桥VPN.app/Contents/MacOS/console") }.allSatisfy { !OperationCheck.processExists($0.pid) } }))
            }

            let browsers = apps.filter { Sys.isBrowser($0.name) }
            if browsers.count > 1 {
                pen += 10
                for b in browsers { let a = b.app; iss.append(Issue(title: "浏览器：\(b.name)", detail: String(format: "占用 %.1f GB 内存（同时开着 %d 个浏览器）", b.memGB, browsers.count), action: { _ = a.terminate() }, on: false, verify: { a.isTerminated })) }
            }
            for h in apps where h.memGB > 2.5 && !Sys.isBrowser(h.name) && !h.name.contains("Grok") {
                let a = h.app; iss.append(Issue(title: "占内存较多：\(h.name)", detail: String(format: "占用 %.1f GB 内存", h.memGB), action: { _ = a.terminate() }, on: false, verify: { a.isTerminated }))
            }
            if memFree < 20 { pen += 20 } else if memFree < 40 { pen += 8 }
            if load > cores { pen += 10 }
            let ws = Sys.cpu(["WindowServer"], ps)
            if days >= 14 || ws > 60 {
                pen += days >= 14 ? 8 : 5
                iss.append(Issue(title: "系统已连续运行 \(days) 天", detail: String(format: "WindowServer 当前占用 %.0f%% CPU，跑久了会让鼠标、视频变卡，找时间重启一次最有效", ws), action: nil, on: false))
            }
            var memory = Snapshot(); Readers.memory(into: &memory)
            let s = String(format: "开机 %d 天 · 负载 %.1f · 内存压力：%@", days, load, Fmt.pressure(memory.memPressure).0)
            let v = Diagnosis.make(Diagnosis.input(ps, memFreePct: memFree, load: load))
            DispatchQueue.main.async {
                self.issues = iss; self.score = max(0, 100 - pen); self.summary = s; self.verdict = v; self.phase = .done
            }
        }
    }

    /// 用户确认后执行，并等待进程状态核验，不把发出请求当成成功。
    func apply(_ f: Fix) {
        guard phase != .fixing else { return }
        if case .displayTips = f { _ = FixRunner.run(f); return }
        phase = .fixing
        if !FixRunner.perform(f, completion: { _, message in self.log = [message]; self.scan(keepLog: true) }) { phase = .done }
    }

    func fix() {
        guard phase != .fixing else { return }
        let selected = issues.filter { $0.on && $0.action != nil }
        guard !selected.isEmpty, FixRunner.confirm("处理选中的 \(selected.count) 项？", selected.map(\.title).joined(separator: "、") + "。应用只会正常退出，未保存内容可能阻止退出。", "处理") else { return }
        phase = .fixing; log = []
        func next(_ index: Int) {
            guard index < selected.count else { self.scan(keepLog: true); return }
            let issue = selected[index]
            DispatchQueue.global(qos: .userInitiated).async {
                issue.action?()
                DispatchQueue.main.async {
                    guard let verify = issue.verify else {
                        self.log.append("已发起：" + issue.title + "，请手动核对结果"); next(index + 1); return
                    }
                    OperationCheck.wait(timeout: self.verificationTimeout, until: verify) { done in
                        self.log.append(OperationCheck.message(title: issue.title, verified: done))
                        if done { CleanStats.shared.addOptimized(1) }
                        next(index + 1)
                    }
                }
            }
        }
        next(0)
    }

}

enum Loaders {
    static func rows(_ id: ToolKind) -> [Row] {
        let ps = Sys.procs()
        switch id {
        case .resources:
            return Sys.appUsage(ps).prefix(15).map { u in let a = u.app
                return Row(icon: a.icon, title: u.name, subtitle: String(format: "内存 %.1f GB · CPU %.0f%%", u.memGB, u.cpu), actionTitle: u.name.contains("Grok") ? nil : "退出", action: { _ = a.terminate() }, verify: { a.isTerminated }) }
        case .startup:
            switch LoginItems.names() {
            case .success(let names): return names.map { LoginItems.row($0) }
            case .failure:
                return [Row(icon: nil, title: "无法读取登录项", subtitle: "读取失败或未获得系统权限，请检查系统提示后刷新", actionTitle: nil, action: nil)]
            }
        case .browsers:
            return Sys.appUsage(ps).filter { Sys.isBrowser($0.name) }.map { u in let a = u.app
                return Row(icon: a.icon, title: u.name, subtitle: String(format: "占用 %.1f GB 内存", u.memGB), actionTitle: "退出", action: { _ = a.terminate() }, verify: { a.isTerminated }) }
        case .spotlight:
            let sp = Sys.cpu(["corespotlightd", "helpd", "mds_stores"], ps)
            let targets = ps.filter { ["corespotlightd", "helpd", "mds_stores"].contains($0.name) }.map(\.pid)
            return [Row(icon: nil, title: "Spotlight 索引服务", subtitle: String(format: "当前占用 %.0f%% CPU，", sp) + (sp > 40 ? "可能卡住了，建议重启" : "状态正常"), actionTitle: targets.isEmpty ? nil : "重启索引", action: Sys.restartSpotlight,
                        verify: { !targets.isEmpty && targets.allSatisfy { !OperationCheck.processExists($0) } })]
        case .virtualMachines:
            let vm = ps.filter { $0.name == Sys.vmName }
            if vm.isEmpty { return [] }
            let targets = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.anthropic.claudefordesktop" }
            return [Row(icon: nil, title: "虚拟机（Claude 桌面版等）", subtitle: String(format: "占用 %.0f%% CPU、%.1f GB 内存", vm.reduce(0) { $0 + $1.cpu }, vm.reduce(0) { $0 + $1.rss } / 1048576), actionTitle: targets.isEmpty ? nil : "退出 Claude", action: Sys.quitClaude,
                        verify: { !targets.isEmpty && targets.allSatisfy { $0.isTerminated } })]
        case .vpn:
            let v = Sys.appUsage(ps).filter { Sys.isVPN($0.name) }
            return v.map { u in let a = u.app
                return Row(icon: a.icon, title: u.name, subtitle: v.count > 1 ? "⚠️ 同时开着 \(v.count) 个 VPN，建议只留一个" : "运行中", actionTitle: "退出", action: { _ = a.terminate() }, verify: { a.isTerminated }) }
        case .displayPerformance:
            let ws = Sys.cpu(["WindowServer"], ps)
            let tr = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency, mo = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let v = Sys.osMajor
            var r: [Row] = []
            // macOS 26 起有 Liquid Glass：26 是「透明 / 着色」两档，27 起改成「外观」里的滑块
            if v >= 27 {
                r.append(Row(icon: nil, title: "调低 Liquid Glass 透明感", subtitle: "在「外观」里把 Liquid Glass 滑块往右拖，菜单、侧边栏会更不透明，渲染更轻", actionTitle: "去设置", action: Sys.openAppearance))
            } else if v == 26 {
                r.append(Row(icon: nil, title: "Liquid Glass 改为「着色」", subtitle: "在「外观」里把 Liquid Glass 从「透明」改成「着色」，减少玻璃效果", actionTitle: "去设置", action: Sys.openAppearance))
            }
            r.append(Row(icon: nil, title: "降低透明度" + (tr ? "（已开启 ✓）" : ""), subtitle: (v >= 26 ? "比上面那项更彻底，几乎去掉所有透明效果。" : "关掉窗口毛玻璃效果，大屏幕上能明显减轻渲染负担。") + "位置：无障碍 › 显示 › 降低透明度", actionTitle: tr ? nil : "去开启", action: { Sys.openA11y("Display") }))
            // 「减弱动态效果」在 macOS 26 起移到了 无障碍 › 动态效果，之前在 无障碍 › 显示
            r.append(Row(icon: nil, title: "减弱动态效果" + (mo ? "（已开启 ✓）" : ""), subtitle: "减少切换桌面、打开窗口时的动画。位置：" + (v >= 26 ? "无障碍 › 动态效果 › 减弱动态效果" : "无障碍 › 显示 › 减弱动态效果"), actionTitle: mo ? nil : "去开启", action: { Sys.openA11y(v >= 26 ? "Motion" : "Display") }))
            return r + [
                    Row(icon: nil, title: "WindowServer（负责画面渲染）", subtitle: String(format: "当前占用 %.0f%% CPU，已运行 %d 天", ws, Int(ProcessInfo.processInfo.systemUptime / 86400)), actionTitle: nil, action: nil)]
        }
    }
}

// MARK: - 视觉风格（v2.5：中性灰阶 + 品牌紫）
// 品牌紫取自 App 图标那道弧线（浅色 #6B5CFA，深色提亮到 #7C6BFF，保证深色下按钮底色仍压得住白字）。
// 文字用的紫单独一档：深色下用更浅的 #A99BFF，避免对比度不足。
let accent = dyn(NSColor(srgbRed: 0.42, green: 0.36, blue: 0.98, alpha: 1),
                 NSColor(srgbRed: 0.486, green: 0.42, blue: 1.0, alpha: 1))
let accentText = dyn(NSColor(srgbRed: 0.357, green: 0.294, blue: 0.910, alpha: 1),
                     NSColor(srgbRed: 0.663, green: 0.608, blue: 1.0, alpha: 1))
/// 青蓝色只留给图表的数据线，不再和品牌紫抢眼
let accent2 = dyn(NSColor(srgbRed: 0.18, green: 0.70, blue: 0.96, alpha: 1),
                  NSColor(srgbRed: 0.30, green: 0.76, blue: 1.0, alpha: 1))
/// 状态色单独一套：绿 / 橙 / 红只表示正常、注意、危险
let good = dyn(NSColor(srgbRed: 0.055, green: 0.624, blue: 0.431, alpha: 1),
               NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 1))
let warn = dyn(NSColor(srgbRed: 0.698, green: 0.416, blue: 0.0, alpha: 1),
               NSColor(srgbRed: 1.0, green: 0.702, blue: 0.251, alpha: 1))
let bad = dyn(NSColor(srgbRed: 0.851, green: 0.231, blue: 0.231, alpha: 1),
              NSColor(srgbRed: 1.0, green: 0.420, blue: 0.420, alpha: 1))
func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map { [.darkAqua, .vibrantDark].contains($0) } == true ? dark : light })
}
/// 页面和卡片背景：中性灰阶，深色接近图标的深蓝黑
let pageBG = DS.window
let cardBG = DS.card

struct CardBG: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: DS.r.card, style: .continuous).fill(DS.card)
        )
        .overlay(RoundedRectangle(cornerRadius: DS.r.card, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
    }
}
extension View { func card() -> some View { modifier(CardBG()) } }

struct PillButton: ButtonStyle {
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(DS.body(.medium))
            .foregroundColor(filled ? .white : .primary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous)
                .fill(filled ? AnyShapeStyle(accent) : AnyShapeStyle(Color.primary.opacity(0.06))))
            .overlay(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous)
                .strokeBorder(filled ? Color.clear : DS.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

// MARK: - 概览
struct MetricCard: View {
    let icon: String; let title: String; let value: String; let note: String; let frac: Double; let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                IconBadge(symbol: icon, tint: color, size: 18)
                Text(title).font(DS.sub()).foregroundColor(.secondary)
                Spacer()
            }
            Text(value).font(DS.num(17, .semibold))
            Bar(frac: frac, color: color, height: 3)
            Text(note).font(DS.cap()).foregroundColor(.secondary).lineLimit(1)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).card()
    }
}

struct CheckupCard: View {
    @ObservedObject var m: Model
    @State private var expanded = false
    static let folded = 3
    var busy: Bool { m.phase == .scanning || m.phase == .fixing }
    var selected: Int { m.issues.filter { $0.on && $0.action != nil }.count }
    var levelColor: Color { guard m.phase == .done, let v = m.verdict else { return accent }; return [good, Color.orange, Color.red][v.level.rawValue] }
    var headline: String {
        switch m.phase {
        case .idle: return "一键体检"
        case .scanning: return "正在检查…"
        case .fixing: return "正在处理…"
        case .done: if let v = m.verdict { return v.title + "：" + v.reason }; return m.score >= 80 ? "不卡" : "有点卡"
        }
    }
    var sub: String {
        guard m.phase == .done else { return "打开概览就自动检查：卡不卡、为什么、怎么处理" }
        let note = m.verdict?.note ?? ""
        return "健康分 \(m.score) · " + (note.isEmpty ? "" : note + " · ") + m.summary
    }
    var icon: String {
        guard m.phase == .done, let v = m.verdict else { return "waveform.path.ecg" }
        return ["checkmark.seal.fill", "exclamationmark.triangle.fill", "flame.fill"][v.level.rawValue]
    }
    var fix: Fix { m.phase == .done ? (m.verdict?.fix ?? .none) : .none }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 结论：一行说清卡不卡、为什么
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.r.card, style: .continuous)
                        .fill(levelColor.opacity(0.14)).frame(width: 34, height: 34)
                    if busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundColor(levelColor) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(DS.title()).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("verdict.title")
                    Text(sub).font(DS.sub()).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let t = fix.title {
                    Button(t) { m.apply(fix) }.buttonStyle(PillButton()).accessibilityIdentifier("verdict.fix")
                }
                Button(m.phase == .done ? "重新体检" : "开始体检") { m.scan() }
                    .buttonStyle(PillButton(filled: false)).disabled(busy).opacity(busy ? 0.5 : 1)
                    .accessibilityIdentifier("verdict.rescan")
            }
            // 问题清单：Raycast 列表样式
            if m.phase == .done && !m.issues.isEmpty {
                let shown = min(m.issues.count, expanded ? m.issues.count : Self.folded)
                VStack(spacing: 1) {
                    ForEach(0..<shown, id: \.self) { idx in
                        let i = m.issues[idx]
                        HStack(spacing: 10) {
                            IconBadge(symbol: i.action != nil ? "exclamationmark" : "info",
                                      tint: i.action != nil ? warn : Color(nsColor: .tertiaryLabelColor), size: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(i.title).font(DS.body(.medium))
                                Text(i.detail).font(DS.sub()).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            if i.action != nil {
                                Toggle("", isOn: $m.issues[idx].on).toggleStyle(.switch).controlSize(.small)
                                    .labelsHidden().tint(accent)
                            } else {
                                Text("建议").font(DS.cap()).foregroundColor(accentText)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous).fill(accent.opacity(0.10)))
                            }
                        }.padding(.horizontal, 8).padding(.vertical, 7)
                    }
                }.padding(6).card()
            }
            if m.phase == .done && (m.issues.count > Self.folded || selected > 0) {
                HStack(spacing: 10) {
                    if m.issues.count > Self.folded {
                        Button(expanded ? "收起" : "查看全部 \(m.issues.count) 项") { expanded.toggle() }
                            .buttonStyle(.plain).font(DS.sub(.medium)).foregroundColor(accentText)
                            .accessibilityIdentifier("checkup.more")
                    }
                    Spacer()
                    if selected > 0 {
                        Button("处理所选（\(selected)）") { m.fix() }.buttonStyle(PillButton(filled: false))
                            .accessibilityIdentifier("checkup.fixSelected")
                    }
                }
            }
        }
        // 处理结果不再堆在卡片里，改成底部 Toast
        .onChange(of: m.log) { log in
            guard let last = log.last else { return }
            ToastCenter.shared.show(last.replacingOccurrences(of: "✔ ", with: ""),
                                    symbol: last.hasPrefix("✔") ? "checkmark.circle.fill" : "info.circle.fill",
                                    tint: last.hasPrefix("✔") ? good : warn)
        }
    }
}

struct Overview: View {
    @ObservedObject var m: Model
    @ObservedObject var mon: Monitor
    var body: some View {
        let s = mon.s
        let v = (load: s.load[0], cores: Double(ProcessInfo.processInfo.activeProcessorCount), days: Int(s.uptime / 86400))
        PageScroll {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "概览", sub: "状态自动刷新，详细指标可在实时监控中查看")
                CheckupCard(m: m)
                HStack(spacing: 10) {
                    MetricCard(icon: "cpu", title: "CPU 负载", value: String(format: "%.1f", v.load),
                               note: "\(Int(v.cores)) 核 · " + (v.load > v.cores ? "偏高" : "正常"), frac: v.load / max(1, v.cores),
                               color: v.load > v.cores ? warn : accent)
                    MetricCard(icon: "memorychip", title: "内存压力", value: Fmt.pressure(s.memPressure).0,
                               note: String(format: "已用 %.1f / %.0f GB", s.memUsedGB, s.memTotalGB), frac: s.memFraction,
                               color: Fmt.pressure(s.memPressure).1)
                    MetricCard(icon: "clock", title: "连续运行", value: "\(v.days) 天",
                               note: v.days >= 14 ? "跑太久了，有空重启一次" : "正常", frac: Double(v.days) / 14,
                               color: v.days >= 14 ? warn : good)
                }
            }.padding(20)
        }
        .onAppear { if m.phase == .idle { m.scan() } }   // 打开概览就体检
    }
}

// MARK: - 工具页（列表 + 详情）
struct ToolPage: View {
    let feature: Feature
    @StateObject private var operation = ToolOperation()
    @State private var rows: [Row] = []
    @State private var loading = true
    @State private var sel = 0
    var current: Row? { rows.indices.contains(sel) ? rows[sel] : nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: feature.title, sub: feature.sub) {
                Button { loading = true; reload() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .buttonStyle(PillButton(filled: false))
                    .disabled(operation.busy)
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                EmptyState(symbol: "checkmark.seal.fill", title: "一切正常", sub: "没有需要处理的项目")
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 1) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, r in
                                ListRow(icon: r.icon, symbol: feature.icon, title: r.title, subtitle: r.subtitle,
                                        selected: sel == idx, action: { sel = idx }) {
                                    if let t = r.actionTitle {
                                        Text(t).font(DS.cap()).foregroundColor(sel == idx ? Color.white.opacity(0.85) : .secondary)
                                    }
                                }
                            }
                        }.padding(6)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).card()
                    detail.frame(width: 280)
                }
            }
        }
        .padding(20)
        .onAppear {
            reload()
            Shell.shared.listHandler = { e in
                guard !rows.isEmpty else { return false }
                switch e.keyCode {
                case Key.down: sel = min(sel + 1, rows.count - 1); return true
                case Key.up: sel = max(0, sel - 1); return true
                case Key.enter, Key.keypadEnter: run(rows[min(sel, rows.count - 1)]); return true
                default: return false
                }
            }
        }
        .onDisappear { Shell.shared.listHandler = nil }
    }
    var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let r = current {
                HStack(spacing: 8) {
                    RowIcon(icon: r.icon, symbol: feature.icon, size: 26)
                    Text(r.title).font(DS.body(.semibold)).lineLimit(2)
                }
                Text(r.subtitle).font(DS.sub()).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Hairline()
                if let t = r.actionTitle, r.action != nil {
                    Button(operation.busy ? "正在核对…" : t) { run(r) }.buttonStyle(PillButton()).frame(maxWidth: .infinity)
                        .disabled(operation.busy)
                    HStack(spacing: 6) { Kbd(text: "↵"); Text("主操作").font(DS.cap()).foregroundColor(.secondary) }
                } else {
                    Text("这项不需要处理").font(DS.sub()).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                if !operation.note.isEmpty {
                    Text(operation.note).font(DS.sub()).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("tool.operation.status")
                }
                Text("列表共 \(rows.count) 项 · ↑↓ 选择").font(DS.cap()).foregroundColor(.secondary)
            } else {
                EmptyState(symbol: feature.icon, title: "选择一项")
            }
        }
        .padding(12).frame(maxHeight: .infinity, alignment: .topLeading).card()
    }
    func run(_ r: Row) {
        guard !operation.busy, let t = r.actionTitle, r.action != nil else { return }
        guard FixRunner.confirm(t + "？", r.title + "。操作后会重新读取列表；未确认的结果不会计入优化统计。", t) else { return }
        ToastCenter.shared.show("正在执行：" + r.title, symbol: "clock", tint: accent)
        operation.perform(r) { verified, message in
            ToastCenter.shared.show(message, symbol: verified ? "checkmark.circle" : "info.circle", tint: verified ? good : accent)
            reload()
        }
    }
    func reload() {
        let id = feature.id
        DispatchQueue.global().async {
            let r = Loaders.rows(id)
            DispatchQueue.main.async { rows = r; loading = false; sel = min(sel, max(0, r.count - 1)) }
        }
    }
}

// MARK: - 窗口
/// 页面容器：默认尺寸和最小尺寸下内容都能完整放下（由测试保证），极端情况下才滚动且不显示滚动条
/// v2.0 滚动渐隐：只有内容高于视口时，才在顶部/底部加渐隐（放得下的页不加）；渐隐是覆盖层，不进滚动文档，不影响 fits 检查。
struct PageScrollContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
struct PageScroll<C: View>: View {
    @ViewBuilder let content: C
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                ScrollView(.vertical, showsIndicators: false) {
                    content.background(GeometryReader { p in Color.clear.preference(key: PageScrollContentHeightKey.self, value: p.size.height) })
                }
                .onPreferenceChange(PageScrollContentHeightKey.self) { contentHeight = $0 }
                .onAppear { viewportHeight = geo.size.height }
                if CDS.shouldFade(contentHeight: contentHeight, viewportHeight: viewportHeight) {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [pageBG, pageBG.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 24)
                        Spacer()
                        LinearGradient(colors: [pageBG.opacity(0), pageBG], startPoint: .top, endPoint: .bottom).frame(height: 24)
                    }.allowsHitTesting(false)
                }
            }
        }
    }
}
enum Layout {
    static let minSize = NSSize(width: 1080, height: 720)
    static let idealSize = NSSize(width: 1180, height: 780)
    /// 默认窗口大小：理想尺寸，但不超过屏幕可用区域
    static func defaultSize(for screen: NSScreen?) -> NSSize {
        let vf = screen?.visibleFrame.size ?? idealSize
        return NSSize(width: max(min(idealSize.width, vf.width - 40), min(minSize.width, vf.width)), height: max(min(idealSize.height, vf.height - 40), min(minSize.height, vf.height)))
    }
}
final class Nav: ObservableObject { static let shared = Nav(); @Published var sel: Page = .overview; @Published var netTab = 0 }
struct RootView: View {
    @StateObject private var m = Model()
    @ObservedObject var mon = Monitor.shared
    @ObservedObject var nav = Nav.shared
    @ObservedObject var shell = Shell.shared
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(sel: $nav.sel)
            VStack(spacing: 0) {
                TopBar()
                ZStack {
                    page.background(Vibrancy(material: .underWindowBackground, solid: DS.window))
                    if shell.searching {
                        SearchResults().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .background(Vibrancy(material: .underWindowBackground, solid: DS.window))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                BottomBar()
            }
        }
        .background(Vibrancy(material: .underWindowBackground, solid: DS.window))
        .overlay(alignment: .bottom) { ToastHost() }
        .overlay { if shell.actionsFor != nil { ActionPanel() } }
        .background(KeyRouter())
        .onAppear { shell.model = m }
        .frame(minWidth: Layout.minSize.width, maxWidth: .infinity, minHeight: Layout.minSize.height, maxHeight: .infinity)
        .ignoresSafeArea()
    }
    @ViewBuilder var page: some View {
        Group {
            switch nav.sel {
            case .overview: Overview(m: m, mon: mon)
            case .monitor: DashboardView(m: mon)
            case .battery: BatteryPage(m: mon)
            case .display: DisplayPage()
            case .network: NetworkPage()
            case .clean: CleanPage()
            case .changes: ChangesPage()
            case .settings: SettingsPage()
            case .split: SplitPage()
            case .tool(let kind):
                if let feature = features.first(where: { $0.id == kind }) {
                    ToolPage(feature: feature).id(kind)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments
        if args.contains("--read-capabilities") { HardwareCapabilities.printSnapshot(); exit(0) }
        if args.contains("--read-classic-batteries") { RealBTSource.printClassicSnapshot(); exit(0) }
        if !args.contains("--selftest") && !args.contains("--uitest") && !args.contains("--snapshot") { _ = SplitController.shared.tracker }
        if let i = args.firstIndex(of: "--charge") { exit(ChargeCLI.run(Array(args[(i + 1)...]))) }
        if args.contains("--selftest") { exit(MOTests.selftest() ? 0 : 1) }
        if !args.contains("--snapshot") && !args.contains("--uitest") { ChargeClient.shared.repairAfterUpdate() }
        let size = Layout.defaultSize(for: NSScreen.main)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.contentMinSize = NSSize(width: min(Layout.minSize.width, size.width), height: min(Layout.minSize.height, size.height))
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.title = "Mac 一键优化"
        w.isReleasedWhenClosed = false; w.isRestorable = false; w.center()
        // 毛玻璃：窗口本身透明，由 SwiftUI 里的 NSVisualEffectView 提供材质
        w.isOpaque = false; w.backgroundColor = .clear
        window = w
        let mon = Monitor.shared
        mon.mainWindowVisible = { [weak w] in guard let w else { return false }; return w.isVisible && w.occlusionState.contains(.visible) && !w.isMiniaturized }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { _ in DispatchQueue.main.async { mon.reschedule() } }
        }
        // 窗口关闭后释放界面，避免隐藏的 SwiftUI 视图继续跟着数据刷新
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            DispatchQueue.main.async { w.contentView = NSView(); if UIState.shared.menuBar { NSApp.setActivationPolicy(.accessory) } }
        }
        UIState.shared.openMain = { [weak self] in self?.showMain() }
        mon.onSample = { BatteryAlerts.shared.handle($0); V19Store.shared.handle($0) }
        EnergyTracker.shared.onDrain = { BatteryAlerts.shared.drain($0, $1) }
        if args.contains("--snapshot") || args.contains("--uitest") { w.contentView = NSHostingView(rootView: RootView()); MOTests.runUI(args: args, window: w); return }
        UNUserNotificationCenter.current().delegate = self
        mon.alertsEnabled = V19Store.shared.settings.alertsOn
        mon.start()
        AppTraffic.shared.start()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in AppTraffic.shared.flush() }
        DisplayManager.shared.startIfNeeded(); ScreenTime.shared.start(); BTBattery.shared.start()
        StatusBar.shared.setup()
        CommandPalette.shared.installHotKey()
        LaunchRestore.run(keepAwake: KeepAwake.shared, dock: DockMode.shared)
        if BatteryAlerts.shared.settings.energyTracking { EnergyTracker.shared.start() }
        BatteryAlerts.shared.$settings.map(\.energyTracking).removeDuplicates().dropFirst().sink { $0 ? EnergyTracker.shared.start() : EnergyTracker.shared.stop() }.store(in: &subs)
        if args.contains("--background") && UIState.shared.menuBar { NSApp.setActivationPolicy(.accessory) } else { showMain() }
        if args.contains("--open-panel"), let b = StatusBar.shared.item?.button { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { StatusBar.shared.show(from: b) } }
    }
    var subs: Set<AnyCancellable> = []
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            if let page = Page.notificationPage(response.notification.request.content.userInfo["page"]), [Page.monitor, .clean, .battery].contains(page) { Nav.shared.sel = page }
            self.showMain(); completionHandler()
        }
    }
    func showMain() {
        NSApp.setActivationPolicy(.regular)
        if !(window.contentView is NSHostingView<RootView>) { window.contentView = NSHostingView(rootView: RootView()) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); Monitor.shared.reschedule()
    }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool { showMain(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !UIState.shared.menuBar }
    func applicationWillTerminate(_ n: Notification) { AppTraffic.shared.flush(); EnergyTracker.shared.stop(); KeepAwake.shared.stop(); DockMode.shared.stop(); DisplayManager.shared.shutdown(); ScreenTime.shared.stop() }
}

@main
struct MacOptimizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}
