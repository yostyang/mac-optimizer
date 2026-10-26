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

struct Hexagon: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); let c = CGPoint(x: r.midX, y: r.midY); let rad = min(r.width, r.height) / 2
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3 - .pi / 2
            let pt = CGPoint(x: c.x + rad * cos(a), y: c.y + rad * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath(); return p
    }
}

struct Logo: View {
    var spin = false
    @State private var angle = 0.0
    var body: some View {
        ZStack {
            Hexagon().fill(Color.gray.opacity(0.07)).frame(width: 120, height: 120).offset(x: -90, y: -40)
            Hexagon().fill(Color.gray.opacity(0.07)).frame(width: 100, height: 100).offset(x: 85, y: 70)
            Hexagon().stroke(Color.orange.opacity(0.12), lineWidth: 2).frame(width: 236, height: 236)
            Hexagon().stroke(LinearGradient(colors: [Color(red: 1, green: 0.84, blue: 0.35), Color(red: 1, green: 0.62, blue: 0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 26)
                .frame(width: 190, height: 190).rotationEffect(.degrees(angle))
            Image(systemName: "bolt.fill").font(.system(size: 56, weight: .bold))
                .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.8, blue: 0.2), .orange], startPoint: .top, endPoint: .bottom))
        }
        .frame(height: 260)
        .onAppear { if spin { withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { angle = 360 } } }
    }
}

struct GreenButton: ButtonStyle {
    var width: CGFloat = 206
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 22, weight: .medium)).foregroundColor(.white)
            .frame(width: width, height: 58)
            .background(LinearGradient(colors: [Color(red: 0.33, green: 0.86, blue: 0.56), Color(red: 0.08, green: 0.78, blue: 0.56)], startPoint: .leading, endPoint: .trailing))
            .cornerRadius(6).shadow(color: Color.green.opacity(0.28), radius: 7, y: 3)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct ResultView: View {
    @ObservedObject var m: Model
    var scoreColor: Color { m.score >= 80 ? Color(red: 0.1, green: 0.78, blue: 0.5) : (m.score >= 60 ? .orange : .red) }
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.gray.opacity(0.13), lineWidth: 12)
                Circle().trim(from: 0, to: CGFloat(m.score) / 100).stroke(scoreColor, style: StrokeStyle(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90))
                VStack(spacing: 0) { Text("\(m.score)").font(.system(size: 42, weight: .bold)).foregroundColor(scoreColor); Text("健康分").font(.caption).foregroundColor(.secondary) }
            }.frame(width: 132, height: 132).padding(.top, 40)
            Text(m.summary).font(.callout).foregroundColor(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(m.log, id: \.self) { Text($0).font(.caption).foregroundColor(.green) }
                    if m.issues.isEmpty { Text("✅ 没发现明显问题，电脑状态不错").foregroundColor(.secondary).frame(maxWidth: .infinity).padding(.top, 20) }
                    ForEach($m.issues) { $i in
                        HStack(alignment: .top, spacing: 10) {
                            if i.action != nil { Toggle("", isOn: $i.on).toggleStyle(.checkbox).labelsHidden() }
                            else { Image(systemName: "lightbulb.fill").foregroundColor(.orange) }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(i.title).font(.system(size: 13, weight: .medium))
                                Text(i.detail).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }.padding(10).background(Color.gray.opacity(0.06)).cornerRadius(8)
                    }
                }.padding(.horizontal, 26)
            }
            VStack(spacing: 8) {
                if m.issues.contains(where: { $0.on && $0.action != nil }) { Button("一键优化") { m.fix() }.buttonStyle(GreenButton()) }
                Button("重新扫描") { m.scan() }.buttonStyle(.link)
            }.padding(.bottom, 26)
        }
    }
}

struct LeftPanel: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(spacing: 12) {
            switch m.phase {
            case .idle:
                Spacer()
                Logo()
                Text("畅快运行，轻快一下").font(.system(size: 28, weight: .semibold)).padding(.top, 20)
                Text("欢迎使用 Mac 一键优化").foregroundColor(.secondary)
                Spacer()
                Button("开始扫描") { m.scan() }.buttonStyle(GreenButton())
                Spacer().frame(height: 70)
            case .scanning, .fixing:
                Spacer()
                Logo(spin: true)
                Text(m.phase == .scanning ? "正在体检…" : "正在优化…").font(.system(size: 20, weight: .medium)).padding(.top, 20)
                Text("马上就好").foregroundColor(.secondary)
                Spacer()
            case .done:
                ResultView(m: m)
            }
        }
        .frame(width: 384).frame(maxHeight: .infinity).background(Color.white)
    }
}

struct Feature: Identifiable { let id: Int; let icon: String; let title: String; let sub: String }
let features = [
    Feature(id: 0, icon: "chart.bar.xaxis", title: "资源占用排行", sub: "查看最占内存和 CPU 的应用"),
    Feature(id: 1, icon: "power", title: "开机启动项管理", sub: "快速禁用开机自启应用"),
    Feature(id: 2, icon: "globe", title: "浏览器管理", sub: "退出多余的浏览器"),
    Feature(id: 3, icon: "magnifyingglass", title: "Spotlight 修复", sub: "解决索引卡住导致的卡顿"),
    Feature(id: 4, icon: "shippingbox", title: "后台虚拟机", sub: "Claude 等应用的虚拟机占用"),
    Feature(id: 5, icon: "network", title: "网络与 VPN", sub: "检查多个 VPN 冲突"),
    Feature(id: 6, icon: "display", title: "显示性能优化", sub: "减轻带鱼屏的渲染负担"),
    Feature(id: 7, icon: "stethoscope", title: "系统体检", sub: "全面检查卡顿原因"),
]

struct FeatureSheet: View {
    let feature: Feature
    @Environment(\.dismiss) var dismiss
    @State private var rows: [Row] = []
    @State private var loading = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: feature.icon).font(.title2).foregroundColor(.gray)
                VStack(alignment: .leading) { Text(feature.title).font(.title3.weight(.semibold)); Text(feature.sub).font(.caption).foregroundColor(.secondary) }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(20)
            Divider()
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if rows.isEmpty { Text("一切正常，没有需要处理的项目 ✅").foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                List(rows) { r in
                    HStack(spacing: 12) {
                        if let ic = r.icon { Image(nsImage: ic).resizable().frame(width: 28, height: 28) }
                        VStack(alignment: .leading, spacing: 2) { Text(r.title).font(.system(size: 13, weight: .medium)); Text(r.subtitle).font(.caption).foregroundColor(.secondary) }
                        Spacer()
                        if let t = r.actionTitle, let act = r.action {
                            Button(t) { DispatchQueue.global().async { act(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { reload() } } }
                        }
                    }.padding(.vertical, 4)
                }
            }
        }
        .frame(width: 580, height: 470)
        .onAppear { reload() }
    }
    func reload() {
        let id = feature.id
        DispatchQueue.global().async { let r = Loaders.rows(id); DispatchQueue.main.async { rows = r; loading = false } }
    }
}

struct RightPanel: View {
    @ObservedObject var m: Model
    @State private var open: Feature?
    let cols = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]
    var body: some View {
        VStack {
            Spacer()
            LazyVGrid(columns: cols, spacing: 50) {
                ForEach(features) { f in
                    Button { if f.id == 7 { m.scan() } else { open = f } } label: {
                        HStack(spacing: 14) {
                            Image(systemName: f.icon).font(.system(size: 30, weight: .light))
                                .foregroundStyle(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.62)], startPoint: .top, endPoint: .bottom)).frame(width: 44)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(f.title).font(.system(size: 15, weight: .medium)).foregroundColor(Color(white: 0.15))
                                Text(f.sub).font(.system(size: 12)).foregroundColor(.gray)
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 64)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(white: 0.985))
        .sheet(item: $open) { f in FeatureSheet(feature: f) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MacOptimizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var m = Model()
    var body: some Scene {
        WindowGroup("Mac 一键优化") {
            HStack(spacing: 0) { LeftPanel(m: m); Divider(); RightPanel(m: m) }
                .frame(width: 1000, height: 620).ignoresSafeArea().preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar).windowResizability(.contentSize)
    }
}
