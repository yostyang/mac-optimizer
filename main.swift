import SwiftUI
import AppKit

@discardableResult
func sh(_ cmd: String) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", cmd]
    var env = ProcessInfo.processInfo.environment; env["LANG"] = "en_US.UTF-8"; env["LC_ALL"] = "en_US.UTF-8"; p.environment = env
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(data: d, encoding: .utf8) ?? ""
}

struct Proc { let cpu: Double; let rss: Double; let comm: String
    var name: String { (comm as NSString).lastPathComponent } }

struct AppUse { let name: String; let cpu: Double; let memGB: Double; let app: NSRunningApplication }

struct Issue: Identifiable { let id = UUID(); let title: String; let detail: String; let action: (() -> Void)?; var on: Bool }

struct Row: Identifiable { let id = UUID(); let icon: NSImage?; let title: String; let subtitle: String; let actionTitle: String?; let action: (() -> Void)? }

enum Sys {
    static func procs() -> [Proc] {
        sh("ps -Axo pcpu=,rss=,comm=").split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let c = Double(parts[0]), let r = Double(parts[1]) else { return nil }
            return Proc(cpu: c, rss: r, comm: String(parts[2]))
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
    static func quitClaude() { sh("osascript -e 'tell application \"Claude\" to quit'") }
    static func restartSpotlight() { sh("killall corespotlightd helpd mds_stores") }
    static func openDisplaySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Display")!) }
    static let vmName = "com.apple.Virtualization.VirtualMachine"
}

final class Model: ObservableObject {
    enum Phase { case idle, scanning, done, fixing }
    @Published var phase: Phase = .idle
    @Published var issues: [Issue] = []
    @Published var score = 100
    @Published var summary = ""
    @Published var log: [String] = []

    func scan(keepLog: Bool = false) {
        if !keepLog { log = [] }
        phase = .scanning
        DispatchQueue.global().async {
            let ps = Sys.procs()
            let apps = Sys.appUsage(ps)
            var iss: [Issue] = []; var pen = 0
            let loadStr = sh("sysctl -n vm.loadavg").split(separator: " ").dropFirst().first.map(String.init) ?? "0"
            let load = Double(loadStr) ?? 0
            let memFree = Int(sh("memory_pressure | awk -F': ' '/free percentage/{print $2}'").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: "")) ?? 100
            let days = Int(ProcessInfo.processInfo.systemUptime / 86400)
            let cores = Double(ProcessInfo.processInfo.activeProcessorCount)

            let sp = Sys.cpu(["corespotlightd", "helpd", "mds_stores"], ps)
            if sp > 40 { pen += 15; iss.append(Issue(title: "Spotlight 索引卡住", detail: "占用 \(Int(sp))% CPU，重启它不会丢任何数据", action: Sys.restartSpotlight, on: true)) }

            let vm = ps.filter { $0.name == Sys.vmName }
            if !vm.isEmpty {
                let c = vm.reduce(0) { $0 + $1.cpu }, g = vm.reduce(0) { $0 + $1.rss } / 1048576
                let claudeOn = apps.contains { $0.name.hasPrefix("Claude") }
                if c > 50 { pen += 20 } else { pen += 5 }
                iss.append(Issue(title: "后台虚拟机在运行" + (claudeOn ? "（Claude）" : ""), detail: String(format: "占用 %.0f%% CPU、%.1f GB 内存；没有任务在跑就可以退出", c, g), action: claudeOn ? Sys.quitClaude : nil, on: c > 50 && claudeOn))
            }

            let vpns = apps.filter { Sys.isVPN($0.name) }
            if vpns.count > 1 {
                pen += 10
                for v in vpns.dropFirst() { let a = v.app; iss.append(Issue(title: "多个 VPN 同时运行：\(v.name)", detail: "VPN 互相冲突容易让视频卡顿，建议只留一个", action: { _ = a.terminate() }, on: v.name.contains("Lets"))) }
            }
            if ps.contains(where: { $0.comm.contains("鹊桥VPN.app/Contents/MacOS/console") }) {
                pen += 5; iss.append(Issue(title: "鹊桥VPN 控制台窗口", detail: "网页窗口持续占用 CPU，关掉不影响 VPN 连接", action: { sh("pkill -f '鹊桥VPN.app/Contents/MacOS/console'") }, on: true))
            }

            let browsers = apps.filter { Sys.isBrowser($0.name) }
            if browsers.count > 1 {
                pen += 10
                for b in browsers { let a = b.app; iss.append(Issue(title: "浏览器：\(b.name)", detail: String(format: "占用 %.1f GB 内存（同时开着 %d 个浏览器）", b.memGB, browsers.count), action: { _ = a.terminate() }, on: false)) }
            }
            for h in apps where h.memGB > 2.5 && !Sys.isBrowser(h.name) && !h.name.contains("Grok") {
                let a = h.app; iss.append(Issue(title: "占内存较多：\(h.name)", detail: String(format: "占用 %.1f GB 内存", h.memGB), action: { _ = a.terminate() }, on: false))
            }
            if memFree < 20 { pen += 20 } else if memFree < 40 { pen += 8 }
            if load > cores { pen += 10 }
            let ws = Sys.cpu(["WindowServer"], ps)
            if days >= 14 || ws > 60 {
                pen += days >= 14 ? 8 : 5
                iss.append(Issue(title: "系统已连续运行 \(days) 天", detail: String(format: "WindowServer 当前占用 %.0f%% CPU，跑久了会让鼠标、视频变卡，找时间重启一次最有效", ws), action: nil, on: false))
            }
            let s = String(format: "开机 %d 天 · 负载 %.1f · 内存可用 %d%%", days, load, memFree)
            DispatchQueue.main.async {
                self.issues = iss; self.score = max(0, 100 - pen); self.summary = s; self.phase = .done
            }
        }
    }

    func fix() {
        let acts = issues.filter { $0.on }.compactMap { i -> (String, () -> Void)? in
            guard let a = i.action else { return nil }; return (i.title, a) }
        phase = .fixing
        DispatchQueue.global().async {
            for (_, a) in acts { a() }
            Thread.sleep(forTimeInterval: 3)
            DispatchQueue.main.async { self.log = acts.map { "✔ 已处理：\($0.0)" }; self.scan(keepLog: true) }
        }
    }
}

enum Loaders {
    static func rows(_ id: Int) -> [Row] {
        let ps = Sys.procs()
        switch id {
        case 0:
            return Sys.appUsage(ps).prefix(15).map { u in let a = u.app
                return Row(icon: a.icon, title: u.name, subtitle: String(format: "内存 %.1f GB · CPU %.0f%%", u.memGB, u.cpu), actionTitle: u.name.contains("Grok") ? nil : "退出", action: { _ = a.terminate() }) }
        case 1:
            let names = sh("osascript -e 'tell application \"System Events\" to get name of every login item'").trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ", ").filter { !$0.isEmpty }
            return names.map { n in Row(icon: nil, title: n, subtitle: "开机时自动启动", actionTitle: "禁止自启", action: { sh("osascript -e 'tell application \"System Events\" to delete login item \"\(n)\"'") }) }
        case 2:
            return Sys.appUsage(ps).filter { Sys.isBrowser($0.name) }.map { u in let a = u.app
                return Row(icon: a.icon, title: u.name, subtitle: String(format: "占用 %.1f GB 内存", u.memGB), actionTitle: "退出", action: { _ = a.terminate() }) }
        case 3:
            let sp = Sys.cpu(["corespotlightd", "helpd", "mds_stores"], ps)
            return [Row(icon: nil, title: "Spotlight 索引服务", subtitle: String(format: "当前占用 %.0f%% CPU，", sp) + (sp > 40 ? "可能卡住了，建议重启" : "状态正常"), actionTitle: "重启索引", action: Sys.restartSpotlight)]
        case 4:
            let vm = ps.filter { $0.name == Sys.vmName }
            if vm.isEmpty { return [] }
            return [Row(icon: nil, title: "虚拟机（Claude 桌面版等）", subtitle: String(format: "占用 %.0f%% CPU、%.1f GB 内存", vm.reduce(0) { $0 + $1.cpu }, vm.reduce(0) { $0 + $1.rss } / 1048576), actionTitle: "退出 Claude", action: Sys.quitClaude)]
        case 5:
            let v = Sys.appUsage(ps).filter { Sys.isVPN($0.name) }
            return v.map { u in let a = u.app
                return Row(icon: a.icon, title: u.name, subtitle: v.count > 1 ? "⚠️ 同时开着 \(v.count) 个 VPN，建议只留一个" : "运行中", actionTitle: "退出", action: { _ = a.terminate() }) }
        case 6:
            let ws = Sys.cpu(["WindowServer"], ps)
            return [Row(icon: nil, title: "减少透明度和动态效果", subtitle: "在大分辨率屏幕上能明显减轻画面渲染负担", actionTitle: "打开设置", action: Sys.openDisplaySettings),
                    Row(icon: nil, title: "WindowServer（负责画面渲染）", subtitle: String(format: "当前占用 %.0f%% CPU，已运行 %d 天", ws, Int(ProcessInfo.processInfo.systemUptime / 86400)), actionTitle: nil, action: nil)]
        default: return []
        }
    }
}

// MARK: - 视觉风格
let accent = Color(red: 0.42, green: 0.36, blue: 0.98)
let accent2 = Color(red: 0.18, green: 0.70, blue: 0.96)
let good = Color(red: 0.16, green: 0.72, blue: 0.52)
let pageBG = Color(red: 0.958, green: 0.960, blue: 0.978)

struct CardBG: ViewModifier {
    func body(content: Content) -> some View {
        content.background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white).shadow(color: .black.opacity(0.06), radius: 10, y: 3))
    }
}
extension View { func card() -> some View { modifier(CardBG()) } }

struct PillButton: ButtonStyle {
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .foregroundColor(filled ? .white : accent)
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(Capsule().fill(filled ? AnyShapeStyle(LinearGradient(colors: [accent2, accent], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(accent.opacity(0.10))))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

// MARK: - 实时指标
struct Metrics { var load = 0.0; var cores = 1.0; var memFree = 100; var days = 0 }
final class Live: ObservableObject {
    @Published var v = Metrics()
    private var timer: Timer?
    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func refresh() {
        DispatchQueue.global().async {
            var x = Metrics()
            x.load = Double(sh("sysctl -n vm.loadavg").split(separator: " ").dropFirst().first.map(String.init) ?? "0") ?? 0
            x.cores = Double(ProcessInfo.processInfo.activeProcessorCount)
            x.memFree = Int(sh("memory_pressure | awk -F': ' '/free percentage/{print $2}'").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: "")) ?? 100
            x.days = Int(ProcessInfo.processInfo.systemUptime / 86400)
            DispatchQueue.main.async { self.v = x }
        }
    }
}

// MARK: - 侧边栏
struct Feature: Identifiable { let id: Int; let icon: String; let title: String; let sub: String }
let features = [
    Feature(id: 0, icon: "chart.bar.xaxis", title: "资源排行", sub: "看看谁最占内存和 CPU"),
    Feature(id: 1, icon: "power", title: "开机启动", sub: "关掉不需要的开机自启"),
    Feature(id: 2, icon: "globe", title: "浏览器", sub: "同时开太多浏览器会拖慢系统"),
    Feature(id: 3, icon: "magnifyingglass", title: "Spotlight", sub: "索引卡住时一键重启"),
    Feature(id: 4, icon: "shippingbox", title: "虚拟机", sub: "Claude 等应用的后台虚拟机"),
    Feature(id: 5, icon: "network", title: "网络与 VPN", sub: "多个 VPN 同时运行会互相冲突"),
    Feature(id: 6, icon: "display", title: "显示性能", sub: "减轻大屏幕的渲染负担"),
]

struct Sidebar: View {
    @Binding var sel: Int
    func item(_ id: Int, _ icon: String, _ title: String) -> some View {
        Button { sel = id } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 18)
                Text(title).font(.system(size: 13, weight: sel == id ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(sel == id ? 0.16 : 0)))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(LinearGradient(colors: [accent2, accent], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 34, height: 34)
                    Image(systemName: "speedometer").font(.system(size: 17, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mac 一键优化").font(.system(size: 14, weight: .semibold))
                    Text("让 Mac 重新轻快").font(.system(size: 10)).opacity(0.6)
                }
            }.padding(.horizontal, 16).padding(.top, 46).padding(.bottom, 24)
            Group {
                item(-1, "square.grid.2x2", "概览")
                Text("工具").font(.system(size: 10, weight: .semibold)).opacity(0.45).padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
                ForEach(features) { f in item(f.id, f.icon, f.title) }
            }.padding(.horizontal, 8)
            Spacer()
            Label("不会删除你的任何文件", systemImage: "lock.shield").font(.system(size: 10)).opacity(0.55).padding(16)
        }
        .foregroundColor(.white)
        .frame(width: 212).frame(maxHeight: .infinity)
        .background(LinearGradient(colors: [Color(red: 0.10, green: 0.10, blue: 0.22), Color(red: 0.21, green: 0.15, blue: 0.40)], startPoint: .top, endPoint: .bottom))
    }
}

// MARK: - 概览
struct MetricCard: View {
    let icon: String; let title: String; let value: String; let note: String; let frac: Double; let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) { Image(systemName: icon).foregroundColor(color); Text(title).font(.system(size: 12)).foregroundColor(.secondary); Spacer() }
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.14))
                    Capsule().fill(color).frame(width: max(6, g.size.width * CGFloat(min(1, max(0, frac)))))
                }
            }.frame(height: 6).animation(.easeOut(duration: 0.6), value: frac)
            Text(note).font(.system(size: 11)).foregroundColor(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).card()
    }
}

struct CheckupCard: View {
    @ObservedObject var m: Model
    var busy: Bool { m.phase == .scanning || m.phase == .fixing }
    var selected: Int { m.issues.filter { $0.on && $0.action != nil }.count }
    var scoreColor: Color { m.score >= 80 ? good : (m.score >= 60 ? .orange : .red) }
    var headline: String {
        switch m.phase {
        case .idle: return "智能体检"
        case .scanning: return "正在检查…"
        case .fixing: return "正在优化…"
        case .done: return m.score >= 80 ? "状态不错" : (m.score >= 60 ? "有点负担" : "需要处理一下")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(m.phase == .done ? scoreColor.opacity(0.12) : accent.opacity(0.10)).frame(width: 60, height: 60)
                    if busy { ProgressView().controlSize(.small) }
                    else if m.phase == .done { Text("\(m.score)").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundColor(scoreColor) }
                    else { Image(systemName: "waveform.path.ecg").font(.system(size: 24, weight: .medium)).foregroundColor(accent) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline).font(.system(size: 17, weight: .semibold))
                    Text(m.phase == .done ? "健康分 \(m.score) · " + m.summary : "找出让 Mac 变卡的原因，几秒钟就好").font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer()
                if m.phase == .done {
                    Button("重新体检") { m.scan() }.buttonStyle(PillButton(filled: selected == 0))
                    if selected > 0 { Button("修复所选（\(selected)）") { m.fix() }.buttonStyle(PillButton()) }
                } else {
                    Button("开始体检") { m.scan() }.buttonStyle(PillButton()).disabled(busy).opacity(busy ? 0.5 : 1)
                }
            }
            if m.phase == .done {
                Divider()
                ForEach(m.log, id: \.self) { Label($0.replacingOccurrences(of: "✔ ", with: ""), systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundColor(good) }
                if m.issues.isEmpty {
                    Label("没发现明显问题，这台 Mac 状态很好", systemImage: "checkmark.seal.fill").font(.system(size: 13)).foregroundColor(good).padding(.vertical, 6)
                }
                ForEach($m.issues) { $i in
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: i.action != nil ? "exclamationmark.circle.fill" : "info.circle.fill")
                            .font(.system(size: 16)).foregroundColor(i.action != nil ? .orange : accent2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(i.title).font(.system(size: 13, weight: .medium))
                            Text(i.detail).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if i.action != nil { Toggle("", isOn: $i.on).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(accent) }
                        else { Text("建议").font(.system(size: 10, weight: .medium)).foregroundColor(accent2).padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(accent2.opacity(0.12))) }
                    }.padding(.vertical, 4)
                }
            }
        }.padding(20).card()
    }
}

struct Overview: View {
    @ObservedObject var m: Model
    @ObservedObject var live: Live
    var body: some View {
        let v = live.v
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("概览").font(.system(size: 24, weight: .bold))
                    Text("下面的数字每 4 秒自动刷新").font(.system(size: 12)).foregroundColor(.secondary)
                }
                HStack(spacing: 14) {
                    MetricCard(icon: "cpu", title: "CPU 负载", value: String(format: "%.1f", v.load),
                               note: "\(Int(v.cores)) 核 · " + (v.load > v.cores ? "偏高" : "正常"), frac: v.load / max(1, v.cores),
                               color: v.load > v.cores ? .orange : accent2)
                    MetricCard(icon: "memorychip", title: "内存可用", value: "\(v.memFree)%",
                               note: v.memFree < 20 ? "很紧张" : (v.memFree < 40 ? "一般" : "充足"), frac: Double(100 - v.memFree) / 100,
                               color: v.memFree < 20 ? .red : (v.memFree < 40 ? .orange : accent))
                    MetricCard(icon: "clock", title: "连续运行", value: "\(v.days) 天",
                               note: v.days >= 14 ? "跑太久了，有空重启一次" : "正常", frac: Double(v.days) / 14,
                               color: v.days >= 14 ? .orange : good)
                }
                CheckupCard(m: m)
            }.padding(28)
        }
    }
}

// MARK: - 工具页
struct ToolPage: View {
    let feature: Feature
    @State private var rows: [Row] = []
    @State private var loading = true
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(feature.title).font(.system(size: 24, weight: .bold))
                    Text(feature.sub).font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer()
                Button { loading = true; reload() } label: { Label("刷新", systemImage: "arrow.clockwise") }.buttonStyle(PillButton(filled: false))
            }
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if rows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundColor(good)
                    Text("一切正常，没有需要处理的项目").foregroundColor(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, r in
                            HStack(spacing: 12) {
                                if let ic = r.icon { Image(nsImage: ic).resizable().frame(width: 30, height: 30) }
                                else {
                                    ZStack { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent.opacity(0.10)).frame(width: 30, height: 30)
                                        Image(systemName: feature.icon).font(.system(size: 13)).foregroundColor(accent) }
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.title).font(.system(size: 13, weight: .medium))
                                    Text(r.subtitle).font(.system(size: 11)).foregroundColor(.secondary)
                                }
                                Spacer()
                                if let t = r.actionTitle, let act = r.action {
                                    Button(t) { DispatchQueue.global().async { act(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { reload() } } }
                                        .buttonStyle(PillButton(filled: false))
                                }
                            }.padding(.horizontal, 16).padding(.vertical, 11)
                            if idx < rows.count - 1 { Divider().padding(.leading, 58) }
                        }
                    }.card().padding(2)
                }
            }
        }
        .padding(28)
        .onAppear { reload() }
    }
    func reload() {
        let id = feature.id
        DispatchQueue.global().async { let r = Loaders.rows(id); DispatchQueue.main.async { rows = r; loading = false } }
    }
}

// MARK: - 窗口
struct RootView: View {
    @StateObject private var m = Model()
    @StateObject private var live = Live()
    @State private var sel = -1
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(sel: $sel)
            Group {
                if sel < 0 { Overview(m: m, live: live) }
                else { ToolPage(feature: features[sel]).id(sel) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(pageBG)
        }
        .frame(width: 980, height: 640).ignoresSafeArea().preferredColorScheme(.light)
        .onAppear { live.start() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MacOptimizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("Mac 一键优化") { RootView() }
            .windowStyle(.hiddenTitleBar).windowResizability(.contentSize)
    }
}
